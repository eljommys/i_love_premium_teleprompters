import PrompterCore
import SwiftUI

/// Donde se escribe el guion y se decide cómo se ve en el cristal.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Borrador local mientras se teclea. Sin él, cada patch que llega de otro
    /// aparato movería el cursor de sitio a mitad de frase.
    @State private var draft = ""
    @State private var draftTask: Task<Void, Never>?
    @State private var isEditing = false
    @State private var showsSettings = false
    @FocusState private var textFocused: Bool

    private var session: any TeleprompterSession { model.session }
    private var state: TeleprompterState { session.state }

    private var compact: Bool {
        #if os(macOS)
            return false
        #else
            return sizeClass == .compact
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            scriptField
            if compact {
                compactControls
            } else {
                settingsGrid
            }
            transport
        }
        .background(Ink.ink950)
        .onAppear { draft = state.text }
        .onChange(of: state.text) { _, incoming in
            // El servidor manda salvo mientras se teclea: al soltar el teclado,
            // el borrador cede.
            if !isEditing { draft = incoming }
        }
        .onChange(of: draft) { _, text in scheduleTextSave(text) }
        .sheet(isPresented: $showsSettings) {
            EditorSettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Ink.ink900)
        }
    }

    // -------------------------------------------------------------- texto

    private var scriptField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .focused($textFocused)
                .font(.system(size: 15))
                .foregroundStyle(Ink.ink100)
                .scrollContentBackground(.hidden)
                .background(Ink.ink900)
                .padding(12)
                .onChange(of: textFocused) { _, focused in
                    isEditing = focused
                    // Al soltar el foco se adopta lo que hubiera llegado
                    // mientras tanto.
                    if !focused, draft == state.text { draft = state.text }
                }

            if draft.isEmpty {
                Text("Escribe aquí el guion…")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.ink700)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// El estado de la sesión y los ajustes, en su propia fila.
    private var editorHeader: some View {
        HStack(spacing: 10) {
            Spacer()
            SessionStatusCapsule()
            if compact {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.ink300)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Ajustes"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // ------------------------------------------------------------ ajustes

    private var settingsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
            spacing: 16
        ) {
            EditorSliders()
            EditorMirrors()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Ink.ink900)
    }

    private var compactControls: some View {
        HStack(spacing: 14) {
            Label("\(wordCount)", systemImage: "text.word.spacing")
                .font(.counter(12))
                .foregroundStyle(Ink.ink500)
            Spacer()
            Text(durationText)
                .font(.counter(12))
                .foregroundStyle(Ink.ink500)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Ink.ink900)
    }

    // ---------------------------------------------------------- transporte

    private var transport: some View {
        VStack(spacing: 10) {
            TPProgressBar(progress: min(1, max(0, session.livePosition)))

            HStack(spacing: 12) {
                Button(state.playing ? "Pausar" : "Reproducir") {
                    session.togglePlaying()
                }
                .buttonStyle(AccentButtonStyle())

                Button("Volver al inicio") { session.rewind() }
                    .buttonStyle(GhostButtonStyle())

                Spacer()

                if !compact {
                    Text("\(wordCount) palabras")
                        .font(.counter(12))
                        .foregroundStyle(Ink.ink500)
                    Text(durationText)
                        .font(.counter(12))
                        .foregroundStyle(Ink.ink500)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Ink.ink850)
    }

    // ------------------------------------------------------------- lógica

    /// Se espera a que pare de teclear antes de mandar el guion: cada pulsación
    /// difundiría el texto entero a todos los aparatos.
    private func scheduleTextSave(_ text: String) {
        guard text != state.text else { return }
        draftTask?.cancel()
        draftTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            session.update(TeleprompterPatch(text: text))
        }
    }

    private var wordCount: Int {
        draft.split(whereSeparator: \.isWhitespace).count
    }

    private var durationText: String {
        guard let total = state.estimatedDuration else {
            return String(localized: "conecta el visor para estimar")
        }
        let seconds = Int(total.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// ------------------------------------------------------------- piezas

/// Los cuatro ajustes numéricos del visor. Se comparten con todos los aparatos.
struct EditorSliders: View {
    @Environment(AppModel.self) private var model
    private var session: any TeleprompterSession { model.session }

    var body: some View {
        TPSlider(
            title: "Velocidad",
            value: binding(\.speed) { TeleprompterPatch(speed: $0) },
            bounds: Limits.speed)

        TPSlider(
            title: "Tamaño de letra",
            value: binding(\.fontSize) { TeleprompterPatch(fontSize: $0) },
            bounds: Limits.fontSize)

        TPSlider(
            title: "Interlineado",
            value: binding(\.lineHeight) { TeleprompterPatch(lineHeight: $0) },
            bounds: Limits.lineHeight,
            format: { String(format: "%.2f", $0) })

        TPSlider(
            title: "Márgenes",
            value: binding(\.margin) { TeleprompterPatch(margin: $0) },
            bounds: Limits.margin,
            format: { "\(Int($0.rounded())) %" })

        ReadingSettings()
    }

    private func binding<Value>(
        _ keyPath: KeyPath<TeleprompterState, Value>,
        patch: @escaping (Value) -> TeleprompterPatch
    ) -> Binding<Value> {
        Binding(
            get: { session.state[keyPath: keyPath] },
            set: { session.update(patch($0)) })
    }
}

struct EditorMirrors: View {
    @Environment(AppModel.self) private var model
    private var session: any TeleprompterSession { model.session }

    var body: some View {
        TPCardToggle(
            "Espejo horizontal",
            subtitle: "Para leer a través del cristal",
            isOn: Binding(
                get: { session.state.mirrorH },
                set: { session.update(TeleprompterPatch(mirrorH: $0)) }))

        TPCardToggle(
            "Espejo vertical",
            subtitle: "Para el visor colocado del revés",
            isOn: Binding(
                get: { session.state.mirrorV },
                set: { session.update(TeleprompterPatch(mirrorV: $0)) }))
    }
}

/// En el móvil los mismos ajustes, pero en una hoja: la pantalla es para el
/// guion.
private struct EditorSettingsSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EditorSliders()
                EditorMirrors()
            }
            .padding(20)
        }
        .background(Ink.ink900)
    }
}
