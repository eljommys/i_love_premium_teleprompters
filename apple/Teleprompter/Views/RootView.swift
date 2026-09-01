import PrompterClient
import PrompterCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        modeContent
            .background(Ink.ink950)
            #if os(macOS)
                .toolbar { ModeToolbar() }
            #endif
            .modifier(RemoteSessionHalo(session: model.session))
            .onChange(of: model.session.connection) { _, status in
                model.connectionChanged(to: status)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.pendingJoin != nil },
                    set: { if !$0 { model.pendingJoin = nil } })
            ) {
                if let host = model.pendingJoin {
                    JoinCodeSheet(host: host)
                        .presentationDetents([.height(340)])
                        .presentationBackground(Ink.ink900)
                }
            }
            .wakeLock(model.shouldStayAwake)
    }

    /// El mismo selector en las tres máquinas.
    ///
    /// En el Mac también, y no solo el segmentado de la barra de herramientas:
    /// esa barra se esconde sola con la ventana a pantalla completa, que es
    /// justo como se usa el visor. Un control propio no depende de eso.
    ///
    /// Va como añadido al área segura, así el editor y el mando colocan su
    /// contenido por encima de él sin taparse. El guion del visor no se entera,
    /// porque se dibuja ignorando el área segura; si no fuera así, esconder el
    /// selector cambiaría el alto útil y con él la medida del guion.
    private var modeContent: some View {
        currentMode
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.showsModeSwitcher {
                    ModeSwitcher()
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: model.showsModeSwitcher)
    }

    @ViewBuilder
    private var currentMode: some View {
        view(for: model.mode)
    }

    /// El aviso de sesión va DENTRO del modo, no encima de todo.
    ///
    /// En el iPad la barra de pestañas flota arriba en el centro, que es
    /// exactamente donde caía el aviso: lo tapaba entero y dejaba al visor sin
    /// manera de ir a los otros modos. Metido en el contenido, el sistema lo
    /// coloca por debajo de la barra en cada aparato.
    private func view(for mode: AppModel.Mode) -> some View {
        modeView(for: mode)
            .overlay(alignment: .top) { SessionBanners() }
    }

    @ViewBuilder
    private func modeView(for mode: AppModel.Mode) -> some View {
        switch mode {
        case .editor: EditorView()
        case .prompter: ViewerView()
        case .remote: RemoteView()
        case .connect: SessionPanel()
        }
    }
}

#if os(macOS)
    /// En el Mac la barra de herramientas lleva el estado de la sesión. Los
    /// modos no: los cambia el mismo selector que en el iPad y el iPhone.
    struct ModeToolbar: ToolbarContent {
        @Environment(AppModel.self) private var model

        var body: some ToolbarContent {
            ToolbarItem(placement: .primaryAction) {
                SessionStatusCapsule()
            }
        }
    }
#endif

/// El aviso de que este aparato está siguiendo la sesión de otro.
///
/// Es lo único que distingue la interfaz de un aparato unido de la de uno que
/// aloja. Va **por encima de todo y fuera de la transformación de espejo**, como
/// la barra de servicio del visor: aunque un borde uniforme se ve igual del
/// derecho que del revés, lo que no puede es acabar dentro del cristal.
///
/// Quieto y al 25 %: tiene que convivir con una toma de veinte minutos sin
/// llamar la atención de quien lee.
struct RemoteSessionHalo: ViewModifier {
    let session: any TeleprompterSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var isReconnecting: Bool {
        session.isRemoteHost && session.connection != .online
    }

    func body(content: Content) -> some View {
        content.overlay {
            // Alojando o en solitario no se dibuja nada en absoluto.
            if session.isRemoteHost {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isReconnecting ? Color.orange : Ink.accent,
                        lineWidth: 3
                    )
                    .opacity(opacity)
                    .animation(
                        isReconnecting && !reduceMotion
                            ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            : .default,
                        value: pulsing
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { pulsing = isReconnecting && !reduceMotion }
                    .onChange(of: isReconnecting) { _, value in
                        pulsing = value && !reduceMotion
                    }
            }
        }
    }

    private var opacity: Double {
        guard isReconnecting else { return 0.25 }
        return pulsing ? 0.3 : 0.6
    }
}

// -------------------------------------------------------------- avisos

/// Los avisos que aparecen sobre cualquier modo. Solo los que no pueden
/// esperar: que nos hayan echado, o que el anfitrión se haya ido a media toma.
/// Encontrar una sesión nueva ya no avisa desde aquí: se ve en el modo Conectar.
struct SessionBanners: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            if model.joinError != nil {
                rejectedBanner
            } else if model.isJoined, model.session.connection != .online {
                reconnectBanner
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: model.isJoined)
        .onReceive(tick) { now = $0 }
    }

    private var rejectedBanner: some View {
        Banner(tint: .orange) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.joinError == .rejected(.tooManyAttempts)
                        ? "Demasiados intentos con el código"
                        : "El código no era ese"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.ink100)
                Text("Míralo en el otro aparato, o escanea su QR.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.ink300)
            }
        } action: {
            Button("Reintentar") { model.retryPairing() }
                .buttonStyle(AccentButtonStyle())
        }
    }

    private var reconnectBanner: some View {
        Banner(tint: .orange) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Se perdió la conexión con el anfitrión")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.ink100)
                Text(model.session.connection == .connecting ? "Reconectando…" : "Buscando…")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.ink300)
            }
        } action: {
            // Pasados quince segundos ya no es un parpadeo de la red: hay que
            // poder seguir grabando desde este aparato.
            if model.offlineSeconds > 15 {
                Button("Continuar en solitario") { model.continueSolo() }
                    .buttonStyle(AccentButtonStyle())
            } else {
                ProgressView().controlSize(.small).tint(Ink.ink300)
            }
        }
        .id(Int(model.offlineSeconds) > 15)
    }
}

private struct Banner<Content: View, Action: View>: View {
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 12) {
            content
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Ink.ink850)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        )
        .frame(maxWidth: 520)
    }
}
