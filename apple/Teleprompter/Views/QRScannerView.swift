import AVFoundation
import PrompterClient
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Leer con la cámara el QR que enseña el anfitrión.
///
/// Se usa AVFoundation y no el escáner de VisionKit porque este tiene que
/// funcionar igual en las tres máquinas, y `DataScannerViewController` no existe
/// en el Mac. El QR trae el código dentro, así que apuntar es todo el trámite.
struct QRScannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var failure: String?
    /// Lo último leído, para no intentar unirse cincuenta veces mientras el
    /// código sigue delante del objetivo.
    @State private var handled = false

    var body: some View {
        ZStack {
            Ink.ink950.ignoresSafeArea()

            switch authorization {
            case .authorized:
                camera
            case .notDetermined:
                permissionPrompt
            default:
                deniedNotice
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(GhostButtonStyle())
                        .padding(16)
                }
                Spacer()
            }
        }
        .task {
            if authorization == .notDetermined { await requestAccess() }
        }
    }

    // ------------------------------------------------------------- capas

    private var camera: some View {
        ZStack {
            CameraPreview(onCode: handle)
                .ignoresSafeArea()

            // Un marco para saber dónde apuntar. La lectura no está limitada a
            // este recuadro: es una guía, no un recorte.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Ink.accentBright.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)

            VStack {
                Spacer()
                Text(failure ?? String(localized: "Apunta al código QR del otro aparato"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(failure == nil ? Ink.ink100 : .orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(.bottom, 40)
            }
        }
    }

    private var permissionPrompt: some View {
        notice(
            symbol: "camera",
            title: String(localized: "Hace falta la cámara"),
            detail: String(localized: "Solo se usa para leer el código QR de la sesión."))
    }

    private var deniedNotice: some View {
        VStack(spacing: 14) {
            notice(
                symbol: "camera.fill",
                title: String(localized: "La cámara está denegada"),
                detail: String(
                    localized:
                        "Puedes darle permiso en Ajustes, o unirte escribiendo la dirección a mano."
                ))
            #if os(iOS)
                Button("Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(AccentButtonStyle())
            #endif
        }
    }

    private func notice(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Ink.ink700)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Ink.ink100)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Ink.ink500)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // ------------------------------------------------------------ lectura

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = granted ? .authorized : .denied
    }

    /// Un código leído. Solo se atiende al primero que sea una invitación
    /// nuestra: los demás QR del mundo no dicen nada de esta aplicación.
    private func handle(_ text: String) {
        guard !handled else { return }
        guard let url = URL(string: text), let link = JoinLink(url: url) else {
            failure = String(localized: "Ese código no es de Universal Teleprompter")
            return
        }
        handled = true
        model.join(link: link)
        model.selectAfterJoining()
        dismiss()
    }
}
