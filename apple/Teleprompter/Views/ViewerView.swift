import PrompterCore
import SwiftUI

/// El cristal. Pantalla completa, negra, sin nada que distraiga.
///
/// Es además **la autoridad de medición**: solo él sabe cuánto ocupa el guion en
/// su pantalla, así que es quien publica `docHeight`. Sin ese dato el resto de
/// aparatos no puede convertir velocidad en tiempo ni un dedo en desplazamiento.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @State private var engine = ScriptScrollEngine()
    @State private var reporter = PositionReporter(
        interval: Timing.viewerReportInterval, threshold: Timing.viewerReportThreshold)
    @State private var chromeTask: Task<Void, Never>?
    @State private var showingSettings = false

    private var session: any TeleprompterSession { model.session }

    /// La botonera y el selector de modo se esconden y vuelven juntos, así que
    /// el estado vive en el modelo y no aquí.
    private var chromeVisible: Bool { model.viewerChromeVisible }
    private var state: TeleprompterState { session.state }

    /// Las tres vistas existen a la vez dentro de las pestañas, pero solo la que
    /// está delante manda: si no, el visor de fondo seguiría informando de su
    /// posición mientras el mando lo mueve, y se pelearían por el guion.
    private var isActive: Bool { model.mode == .prompter }

    var body: some View {
        ZStack {
            Ink.viewerBackground.ignoresSafeArea()

            if state.text.isEmpty {
                EmptyScriptHint()
            } else {
                mirrored
            }

            // La barra de servicio va SIN espejar: es para quien maneja el
            // aparato, no para quien lee a través del cristal.
            if chromeVisible {
                topScrim
                    .transition(.opacity)
                bottomScrim
                    .transition(.opacity)
                serviceBar
                    .transition(.opacity)
            } else {
                // Un rincón invisible para volver a sacarla sin tener que
                // adivinar dónde tocar.
                cornerHotspot
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { togglePlaying() }
        #if os(iOS)
            // La barra de pestañas se va con la botonera: mientras se lee, el
            // cristal es toda la pantalla. En pausa vuelve, que es lo que
            // garantiza que desde aquí siempre se pueda ir a los otros modos.
            .statusBarHidden(!chromeVisible)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Guion"))
        .accessibilityValue(Text(state.playing ? "En marcha" : "En pausa"))
        .accessibilityHint(Text("Pulsa dos veces para reproducir o pausar"))
        .animation(.easeInOut(duration: 0.5), value: chromeVisible)
        .onAppear { attach() }
        .onChange(of: model.mode) { _, _ in attach() }
        .onChange(of: model.reassertToken) { _, _ in
            guard isActive else { return }
            republishAuthority()
        }
        .onDisappear {
            chromeTask?.cancel()
            model.viewerChromeVisible = true
        }
        .onChange(of: state.playing) { _, playing in
            engine.playing = playing
            // Al parar reaparece todo; al arrancar se va sola a los pocos
            // segundos.
            showChrome()
        }
        .onChange(of: state.speed) { _, _ in refreshRate() }
        .onChange(of: state.fontSize) { _, _ in refreshRate() }
        .onChange(of: state.docHeight) { _, _ in refreshRate() }
        .onChange(of: session.connection) { _, status in
            // Mientras no haya conexión la botonera se queda fija: es la única
            // pista de que algo va mal.
            if status != .online { showChrome(autoHide: false) }
        }
        .task(id: reportTick) { reportPositionIfDue() }
        .onChange(of: showingSettings) { _, open in
            showChrome(autoHide: open ? false : nil)
        }
        .sheet(isPresented: $showingSettings) {
            ViewerSettingsSheet()
        }
    }

    // -------------------------------------------------------------- capas

    private var mirrored: some View {
        ZStack(alignment: .top) {
            ScriptScrollView(
                text: state.text,
                fontSize: state.fontSize,
                lineHeight: state.lineHeight,
                marginFraction: state.margin / 100,
                engine: engine,
                readLine: state.readLine,
                readStyle: state.readStyle
            )

            HStack {
                Spacer()
                VerticalProgressBar(progress: engine.progress)
                    .padding(.trailing, 6)
                    .padding(.vertical, 20)
            }
        }
        // Espejo horizontal para el cristal, vertical para el iPad cabeza abajo.
        // Se aplica a todo lo que hay que leer: texto, línea y progreso.
        .scaleEffect(
            x: state.mirrorH ? -1 : 1,
            y: state.mirrorV ? -1 : 1,
            anchor: .center
        )
        .ignoresSafeArea()
    }

    /// Las bandas oscuras detrás de la botonera.
    ///
    /// El guion pasa por debajo de los controles, y sin nada en medio se
    /// entremezclan hasta que no se lee ni una cosa ni la otra. Cada banda es
    /// negro macizo justo donde hay botones y se difumina hacia el guion, para
    /// que no parezca una franja pegada encima.
    private func scrim(solid: Double, fade: Double, from edge: Edge) -> some View {
        VStack(spacing: 0) {
            if edge == .bottom { Spacer(minLength: 0) }

            let gradient = LinearGradient(
                colors: [Color.black.opacity(0), Color.black],
                startPoint: edge == .top ? .bottom : .top,
                endPoint: edge == .top ? .top : .bottom
            )

            if edge == .top {
                Color.black.frame(height: solid)
                gradient.frame(height: fade)
            } else {
                gradient.frame(height: fade)
                Color.black.frame(height: solid)
            }

            if edge == .top { Spacer(minLength: 0) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Arriba: la barra de estado, el aviso de sesión si lo hay, y los botones.
    private var topScrim: some View {
        scrim(solid: model.showsTopBanner ? 215 : 130, fade: 70, from: .top)
    }

    /// Abajo: la fila de estado y la barra de pestañas, que flota por encima del
    /// guion y dejaba el texto asomando por los lados de la cápsula.
    private var bottomScrim: some View {
        scrim(solid: 110, fade: 130, from: .bottom)
    }

    private var serviceBar: some View {
        VStack {
            HStack(spacing: 10) {
                SessionStatusCapsule()

                Spacer()

                ChromeButton(
                    symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    label: "Espejo H",
                    isOn: state.mirrorH
                ) {
                    session.update(TeleprompterPatch(mirrorH: !state.mirrorH))
                    showChrome()
                }

                ChromeButton(
                    symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    label: "Espejo V",
                    isOn: state.mirrorV
                ) {
                    session.update(TeleprompterPatch(mirrorV: !state.mirrorV))
                    showChrome()
                }

                ChromeButton(symbol: "backward.end.fill", label: "Inicio", isOn: false) {
                    session.rewind()
                    showChrome()
                }

                ChromeButton(symbol: "slider.horizontal.3", label: "Ajustes", isOn: false) {
                    showingSettings = true
                    showChrome()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Los avisos de sesión viven en el borde de arriba y taparían estos
            // botones; cuando hay uno, se les deja sitio.
            .padding(.top, model.showsTopBanner ? 70 : 0)

            Spacer()

            HStack {
                Text(remainingText)
                    .font(.counter(13))
                    .foregroundStyle(Ink.ink300)
                Spacer()
                Text(state.playing ? "En marcha" : "En pausa")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.playing ? Ink.accentBright : Ink.ink300)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var cornerHotspot: some View {
        VStack {
            HStack {
                Spacer()
                Color.clear
                    .frame(width: 96, height: 56)
                    .contentShape(Rectangle())
                    .onTapGesture { showChrome() }
                    .accessibilityLabel(Text("Mostrar controles"))
                    .accessibilityAddTraits(.isButton)
            }
            Spacer()
        }
    }

    // ------------------------------------------------------------ lógica

    private func attach() {
        guard isActive else { return }

        engine.playing = state.playing
        engine.setPosition(session.livePosition)
        refreshRate()

        engine.onMeasure = { travel in
            // Solo el visor publica el recorrido: es su medida y nadie más la
            // tiene.
            session.update(TeleprompterPatch(docHeight: travel))
        }
        // La vista de texto suele medir antes de que esta vista aparezca, y una
        // medida que no cambia no vuelve a avisar: sin esto el recorrido no
        // llegaba a publicarse nunca y el resto de aparatos se quedaban a
        // velocidad cero.
        republishAuthority()

        engine.onEnd = {
            guard state.playing else { return }
            session.update(TeleprompterPatch(playing: false))
        }

        session.onIncomingPosition = { position in
            // Lo que vuelve es nuestro propio informe: aplicarlo sería seguirse
            // a uno mismo con retraso.
            guard !reporter.isOwnEcho(position) else { return }
            engine.aim(position)
        }

        showChrome()
    }

    /// Vuelve a decir lo que solo sabe el visor: por dónde va y cuánto mide el
    /// guion en su pantalla. Se usa al empezar y cada vez que se recupera la
    /// conexión, porque el recorrido no se guarda en ningún sitio y el
    /// anfitrión que vuelve trae una posición vieja.
    private func republishAuthority() {
        var patch = TeleprompterPatch()
        if engine.travel > 0 { patch.docHeight = engine.travel }
        patch.position = engine.position
        session.update(patch)
        refreshRate()
    }

    private func refreshRate() {
        engine.rate = state.scrollRate
    }

    private func togglePlaying() {
        if !state.playing, engine.position >= 1 {
            // Pulsar Reproducir con el guion terminado tiene que rebobinar; si
            // no, se quedaría encendido sin que se mueva nada.
            engine.setPosition(0)
            reporter.forget()
            session.update(TeleprompterPatch(playing: true, position: 0))
        } else {
            session.update(TeleprompterPatch(playing: !state.playing))
        }
        // La botonera la mueve el cambio de `playing`, venga de este toque o
        // del mando de otro aparato.
    }

    /// Un identificador que cambia cinco veces por segundo, para colgar de él el
    /// informe de posición sin meter un temporizador a mano.
    private var reportTick: Int { engine.progressStep / 2 }

    private func reportPositionIfDue() {
        // Mientras se está alcanzando la posición de otro no se informa: sería
        // devolverle su propio mensaje y estorbar.
        guard isActive, !engine.isFollowing else { return }
        let position = engine.position
        guard reporter.shouldReport(position, now: ProcessInfo.processInfo.systemUptime) else {
            return
        }
        session.update(TeleprompterPatch(position: position))
    }

    /// Enseña la botonera y decide si vuelve a esconderse.
    ///
    /// **Solo se esconde mientras se está leyendo.** En pausa se queda puesta,
    /// porque con ella se va la barra de pestañas, y quedarse sin manera visible
    /// de salir del visor no es una pantalla limpia: es una pantalla sin salida.
    /// Estando en marcha, un toque en cualquier sitio pausa y la devuelve.
    private func showChrome(autoHide: Bool? = nil) {
        model.viewerChromeVisible = true
        chromeTask?.cancel()
        chromeTask = nil

        guard autoHide ?? state.playing else { return }
        chromeTask = Task {
            try? await Task.sleep(for: .seconds(Timing.chromeAutoHide))
            guard !Task.isCancelled else { return }
            model.viewerChromeVisible = false
        }
    }

    private var remainingText: String {
        guard let remaining = state.remainingDuration else {
            return String(localized: "sin medir todavía")
        }
        return String(localized: "quedan \(format(remaining))")
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ChromeButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var widthClass
        /// En el ancho de un móvil no caben cinco botones con su rótulo: las
        /// palabras se partían en columnas de dos letras. El icono se basta, y
        /// el rótulo sigue estando para quien use VoiceOver.
        private var showsLabel: Bool { widthClass != .compact }
    #else
        private var showsLabel: Bool { true }
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                if showsLabel {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isOn ? Ink.ink950 : Ink.ink300)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(isOn ? Ink.accentBright : Ink.ink850)
                    .overlay(Capsule().strokeBorder(Ink.ink700, lineWidth: isOn ? 0 : 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Los ajustes del visor. Los mismos de la sesión que se ven desde el editor y
/// desde el mando: aquí hacen falta porque el visor es a menudo el único
/// aparato al alcance de la mano mientras se coloca el cristal.
private struct ViewerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ReadingSettings()
                    EditorSliders()
                    EditorMirrors()
                }
                .padding(20)
            }
            .background(Ink.ink900)
            .navigationTitle(Text("Ajustes"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Ink.ink900)
    }
}
