import PrompterClient
import PrompterCore
import SwiftUI

@main
struct TeleprompterApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.start() }
                .onOpenURL { url in
                    // El QR de invitación trae dentro el código, así que
                    // escanearlo une sin teclear nada.
                    if let link = JoinLink(url: url) { model.join(link: link) }
                }
        }
        .commands { PlaybackCommands(model: model) }
        #if os(macOS)
            .defaultSize(width: 900, height: 720)
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .inactive, .background: model.willResignActive()
            @unknown default: break
            }
        }
    }
}

/// Menús y atajos. Están en el Mac, pero los hereda cualquier iPad con teclado.
struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // Botones con atajo y no un Picker: así cambiar de modo tiene
            // ⌘1/⌘2/⌘3, que es la vía rápida con teclado y además una manera
            // más de llegar a los otros modos si la ventana está a pantalla
            // completa.
            ForEach(Array(AppModel.Mode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.select(mode) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Divider()
        }

        CommandMenu("Reproducción") {
            Button(model.session.state.playing ? "Pausar" : "Reproducir") {
                model.session.togglePlaying()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Volver al inicio") { model.session.rewind() }
                .keyboardShortcut(.upArrow, modifiers: .command)

            Divider()

            Button("Atrás 5 segundos") { jump(-Timing.jumpSeconds) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Adelante 5 segundos") { jump(Timing.jumpSeconds) }
                .keyboardShortcut(.downArrow, modifiers: [])

            Divider()

            Button("Más rápido") { nudgeSpeed(+5) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Más lento") { nudgeSpeed(-5) }
                .keyboardShortcut("[", modifiers: .command)
        }

        CommandMenu("Visor") {
            Button("Espejo horizontal") {
                model.session.update(TeleprompterPatch(mirrorH: !model.session.state.mirrorH))
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Espejo vertical") {
                model.session.update(TeleprompterPatch(mirrorV: !model.session.state.mirrorV))
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button("Letra más grande") { nudgeFontSize(+4) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Letra más pequeña") { nudgeFontSize(-4) }
                .keyboardShortcut("-", modifiers: .command)
        }
    }

    private func jump(_ seconds: Double) {
        let state = model.session.state
        let delta = state.fraction(forSeconds: seconds)
        guard delta > 0 else { return }
        let target = min(1, max(0, model.session.livePosition + delta))
        model.session.update(TeleprompterPatch(position: target))
    }

    private func nudgeSpeed(_ delta: Double) {
        model.session.update(TeleprompterPatch(speed: model.session.state.speed + delta))
    }

    private func nudgeFontSize(_ delta: Double) {
        model.session.update(TeleprompterPatch(fontSize: model.session.state.fontSize + delta))
    }
}
