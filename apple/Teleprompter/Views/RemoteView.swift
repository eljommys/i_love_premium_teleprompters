import PrompterCore
import SwiftUI

/// El mando. Enseña el mismo guion sincronizado y deja moverlo con el dedo.
///
/// El gesto es el del papel: tocar arranca y para; arrastrar mueve el guion uno
/// a uno con el dedo y, mientras lo sujetas, la lectura se detiene. Al soltar,
/// sigue por donde lo dejaste.
struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var engine = ScriptScrollEngine()
    @State private var reporter = PositionReporter(interval: Timing.remotePublishInterval)
    @State private var showsSettings = false

    // Estado del gesto.
    @State private var isDragging = false
    @State private var anchorPosition: Double = 0
    @State private var anchorTranslation: Double = 0

    /// Tamaño de letra de ESTE aparato. No se comparte: el mando es para quien
    /// lo tiene en la mano, no para el cristal.
    @AppStorage("teleprompter:remoteFontSize") private var monitorFontSize: Double = 19

    private static let fontSizes: [Double] = [16, 19, 22, 26, 30]

    private var session: any TeleprompterSession { model.session }
    private var state: TeleprompterState { session.state }

    /// Solo manda la vista que está delante. Ver `ViewerView.isActive`.
    private var isActive: Bool { model.mode == .remote }

    var body: some View {
        VStack(spacing: 0) {
            header
            script
            footer
        }
        .background(Ink.ink950)
        .onAppear { attach() }
        .onChange(of: model.mode) { _, _ in attach() }
        .onChange(of: state.playing) { _, playing in engine.playing = playing }
        .onChange(of: state.speed) { _, _ in refreshRate() }
        .onChange(of: state.fontSize) { _, _ in refreshRate() }
        .onChange(of: state.docHeight) { _, _ in refreshRate() }
        .onChange(of: monitorFontSize) { _, _ in refreshRate() }
        .sheet(isPresented: $showsSettings) {
            RemoteSettingsSheet(monitorFontSize: $monitorFontSize, sizes: Self.fontSizes)
                .presentationDetents([.medium, .large])
                .presentationBackground(Ink.ink900)
        }
    }

    // ------------------------------------------------------------ cabecera

    private var header: some View {
        HStack(spacing: 10) {
            SessionStatusCapsule()
            Spacer()
            Text(state.playing ? "En marcha" : "En pausa")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.playing ? Ink.accentBright : Ink.ink500)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // -------------------------------------------------------------- guion

    private var script: some View {
        ZStack {
            if state.text.isEmpty {
                EmptyScriptHint()
            } else {
                ScriptScrollView(
                    text: state.text,
                    fontSize: monitorFontSize,
                    lineHeight: state.lineHeight,
                    marginFraction: 0.06,
                    engine: engine,
                    readLine: state.readLine,
                    readStyle: state.readStyle
                )
                // Difuminar los bordes deja claro dónde está la línea de
                // lectura sin tener que dibujar nada más.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel(Text("Guion"))
        .accessibilityValue(Text(state.playing ? "En marcha" : "En pausa"))
        .accessibilityHint(Text("Pulsa dos veces para reproducir o pausar"))
        .accessibilityAdjustableAction { direction in
            // Arrastrar no lo descubre nadie con VoiceOver: los mismos saltos
            // que los botones, pero por gesto.
            jump(direction == .increment ? Timing.jumpSeconds : -Timing.jumpSeconds)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let travelled = abs(value.translation.height)

                if !isDragging {
                    // Por debajo del margen de holgura sigue siendo un toque:
                    // un dedo nunca cae del todo quieto.
                    guard travelled > Timing.dragSlop else { return }
                    isDragging = true
                    engine.isGrabbed = true
                    // Se ancla AQUÍ y no donde se posó el dedo: si no, el guion
                    // daría un tirón del tamaño de la holgura al empezar.
                    anchorPosition = engine.position
                    anchorTranslation = value.translation.height
                    // Sujetar el papel para el papel.
                    if state.playing { session.update(TeleprompterPatch(playing: false)) }
                }

                let travel = engine.travel
                guard travel > 0 else { return }
                let delta = (value.translation.height - anchorTranslation) / travel
                let target = min(1, max(0, anchorPosition - delta))
                engine.setPosition(target)
                publish(target)
            }
            .onEnded { _ in
                defer {
                    isDragging = false
                    engine.isGrabbed = false
                }

                guard isDragging else {
                    // No llegó a moverse: era un toque.
                    togglePlaying()
                    return
                }

                publish(engine.position, force: true)
                // Y silencio un momento: los informes que aún viajaban traen la
                // posición anterior y aplicarlos daría un salto atrás.
                engine.hold()
            }
    }

    // -------------------------------------------------------------- botones

    private var footer: some View {
        VStack(spacing: 10) {
            TPProgressBar(progress: engine.progress)
                .padding(.horizontal, 18)

            HStack(spacing: 12) {
                JumpButton(symbol: "chevron.up", label: "5 s atrás") {
                    jump(-Timing.jumpSeconds)
                }

                Button {
                    togglePlaying()
                } label: {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Ink.ink950)
                        .frame(width: 74, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Ink.accentBright))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(state.playing ? "Pausar" : "Reproducir"))

                JumpButton(symbol: "chevron.down", label: "5 s adelante") {
                    jump(Timing.jumpSeconds)
                }

                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Ink.ink300)
                        .frame(width: 52, height: 56)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Ajustes"))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    // ------------------------------------------------------------- lógica

    private func attach() {
        guard isActive else { return }

        engine.playing = state.playing
        engine.setPosition(session.livePosition)
        refreshRate()

        // El mando no publica su medida: su pantalla no es el cristal, y el
        // recorrido que vale para todos es el del visor. Pero sí la usa para
        // saber a qué ritmo mover SU panel cuando no hay visor ninguno.
        engine.onMeasure = { _ in refreshRate() }
        engine.onEnd = {
            guard state.playing else { return }
            session.update(TeleprompterPatch(playing: false))
        }

        session.onIncomingPosition = { position in
            guard !isDragging, !reporter.isOwnEcho(position) else { return }
            engine.aim(position)
        }
    }

    /// Manda el recorrido del visor, que es el que significa lo mismo para
    /// todos. Pero un móvil suelto no tiene visor que mida, y pulsar Reproducir
    /// no movería nada: entonces se mide a sí mismo.
    private func refreshRate() {
        if state.docHeight > 0 {
            engine.rate = state.scrollRate
        } else {
            engine.rate = SpeedMath.scrollRate(
                speed: state.speed, fontSize: monitorFontSize, docHeight: engine.travel)
        }
    }

    private func togglePlaying() {
        if !state.playing, engine.position >= 1 {
            engine.setPosition(0)
            reporter.forget()
            session.update(TeleprompterPatch(playing: true, position: 0))
        } else {
            session.update(TeleprompterPatch(playing: !state.playing))
        }
    }

    private func jump(_ seconds: Double) {
        let delta = state.fraction(forSeconds: seconds)
        guard delta > 0 else { return }
        let target = min(1, max(0, engine.position + delta))
        engine.setPosition(target)
        publish(target, force: true)
        engine.hold()
    }

    private func publish(_ position: Double, force: Bool = false) {
        guard isActive,
            reporter.shouldReport(
                position, now: ProcessInfo.processInfo.systemUptime, force: force)
        else { return }
        session.update(TeleprompterPatch(position: position))
    }
}

private struct JumpButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                Text("5 s")
                    .font(.counter(11, weight: .semibold))
            }
            .foregroundStyle(Ink.ink300)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Ink.ink850))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Los ajustes del mando. Los del visor viajan a todos los aparatos; el tamaño
/// de letra de este panel se queda aquí.
private struct RemoteSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var monitorFontSize: Double
    let sizes: [Double]

    private var session: any TeleprompterSession { model.session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    TPSlider(
                        title: "Velocidad",
                        value: binding(\.speed) { TeleprompterPatch(speed: $0) },
                        bounds: Limits.speed)

                    TPSlider(
                        title: "Letra del visor",
                        value: binding(\.fontSize) { TeleprompterPatch(fontSize: $0) },
                        bounds: Limits.fontSize)

                    TPSlider(
                        title: "Interlineado",
                        value: binding(\.lineHeight) { TeleprompterPatch(lineHeight: $0) },
                        bounds: Limits.lineHeight,
                        format: { String(format: "%.2f", $0) })

                    TPSlider(
                        title: "Márgenes del visor",
                        value: binding(\.margin) { TeleprompterPatch(margin: $0) },
                        bounds: Limits.margin,
                        format: { "\(Int($0.rounded())) %" })
                }

                ReadingSettings()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Letra de este mando")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.ink300)
                    Picker("Letra de este mando", selection: $monitorFontSize) {
                        ForEach(sizes, id: \.self) { size in
                            Text("\(Int(size))").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                TPCardToggle(
                    "Espejo horizontal",
                    subtitle: "Para leer a través del cristal",
                    isOn: binding(\.mirrorH) { TeleprompterPatch(mirrorH: $0) })

                TPCardToggle(
                    "Espejo vertical",
                    subtitle: "Para el visor colocado del revés",
                    isOn: binding(\.mirrorV) { TeleprompterPatch(mirrorV: $0) })

                Button("Volver al inicio") {
                    session.rewind()
                    dismiss()
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(20)
        }
        .background(Ink.ink900)
    }

    private func binding<Value>(
        _ keyPath: KeyPath<TeleprompterState, Value>,
        patch: @escaping (Value) -> TeleprompterPatch
    ) -> Binding<Value> {
        Binding(
            get: { session.state[keyPath: keyPath] },
            set: { session.update(patch($0)) }
        )
    }
}
