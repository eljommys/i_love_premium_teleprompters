import CoreImage
import CoreImage.CIFilterBuiltins
import PrompterClient
import PrompterCore
import PrompterServer
import SwiftUI

/// El único sitio de la aplicación donde existe la distinción entre alojar y
/// unirse. Todo lo demás es indiferente a eso.
///
/// Es un modo más, al lado del editor, el visor y el mando. Antes esto vivía en
/// un cartel permanente en el borde de arriba, y estar ofreciendo una sesión
/// todo el rato solo servía para robarle sitio al guion.
struct SessionPanel: View {
    @Environment(AppModel.self) private var model

    @State private var manualHost = ""
    @State private var manualPort = "3000"
    @State private var manualCode = ""
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isJoined {
                    joinedSection
                } else {
                    hostingSection
                    webSection
                    scanSection
                    nearbySection
                    manualSection
                }
            }
            // Márgenes al ritmo del resto de la app —los otros modos usan
            // 14-18— y aire de sobra arriba y abajo: esto ya no es una hoja
            // pequeña, es una pantalla entera, y el selector de modo flota
            // sobre el final.
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 40)
            // En el Mac y el iPad la ventana es mucho más ancha de lo que se
            // lee cómodo. La columna se queda a un ancho de lectura y se centra
            // en vez de estirarse de un borde al otro.
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Ink.ink900)
        // Una franja del mismo fondo detrás de la barra de estado: al desplazar,
        // el contenido pasaba por debajo del reloj y se leían los dos a la vez.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Ink.ink900)
                .frame(height: 0)
                .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $scanning) {
            QRScannerView()
        }
    }

    // ------------------------------------------------------------ unido

    private var joinedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Estás en la sesión de otro aparato")

            HStack(spacing: 10) {
                ConnectionDot(connection: model.session.connection)
                Text(model.session.hostIdentity?.name ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.ink100)
            }

            Text("El borde de la pantalla te lo recuerda mientras dure.")
                .font(.system(size: 12))
                .foregroundStyle(Ink.ink500)

            deviceCounts

            Button("Abandonar la sesión") {
                model.leaveSession()
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // --------------------------------------------------------- alojando

    private var hostingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Esta es tu sesión")

            switch model.hostServer.status {
            case let .running(port):
                Text("Otros aparatos pueden unirse desde la misma red.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.ink500)

                if let address = LocalAddresses.preferred {
                    LabeledValue("Dirección", "\(address):\(port)")
                }

            case .failed(.localNetworkDenied):
                Notice("Sin permiso de red local no puede unirse nadie. Actívalo en Ajustes; el resto de la aplicación funciona igual.")

            case .failed:
                Notice(
                    "No se pudo abrir la sesión en red. Puedes seguir usando este aparato solo.")

            case .starting, .stopped:
                ProgressView().controlSize(.small)
            }

            pairingSection

            if case .running = model.hostServer.status {
                qrInvitation
            }

            deviceCounts
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TPCardToggle(
                "Pedir código para entrar",
                subtitle: "Nadie de tu red se une sin él",
                isOn: Binding(
                    get: { model.requiresPairing },
                    set: { model.requiresPairing = $0 })
            )

            if model.requiresPairing {
                HStack(spacing: 12) {
                    Text(model.pairingCode)
                        .font(.counter(30, weight: .bold))
                        .kerning(6)
                        .foregroundStyle(Ink.accentBright)
                    Spacer()
                    Button("Cambiar") { model.regeneratePairingCode() }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.ink850))
            }
        }
    }

    /// Escanear el QR une directamente: lleva dentro la dirección y el código,
    /// así que no hay que teclear nada.
    private var qrInvitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Unirse escaneando")
            HStack(alignment: .top, spacing: 16) {
                if let url = model.joinLink.url, let image = QRCode.image(for: url.absoluteString) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                }
                Text("Apunta con la cámara del otro aparato. Lleva el código dentro, así que entra sin teclear nada.")
                .font(.system(size: 12))
                .foregroundStyle(Ink.ink500)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Código QR para unirse a esta sesión"))
    }

    // ----------------------------------------------------------- cercanos

    /// Dejar entrar desde un navegador, sin instalar nada.
    private var webSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Desde un navegador")

            TPCardToggle(
                "Abrir en el navegador",
                subtitle: "Quien no tenga la app entra escribiendo una dirección",
                isOn: Binding(
                    get: { model.webAccessEnabled },
                    set: { model.webAccessEnabled = $0 }))

            if model.webAccessEnabled {
                if let address = model.webAddress {
                    LabeledValue("Dirección", address)
                    if let join = model.webJoinURL, let image = QRCode.image(for: join) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(decorative: image, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                            Text(
                                model.requiresPairing
                                    ? "Este código lleva dentro el de la sesión: quien lo escanee entra sin teclearlo."
                                    : "Escanéalo para abrir la página directamente."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Notice("Buscando sitio para la página…")
                }
                Text("Desde el navegador se puede leer y mandar, pero no alojar.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.ink500)
            }
        }
    }

    /// Unirse leyendo con la cámara el QR que enseña el anfitrión. Es la vía
    /// más corta que hay: ni elegir de una lista ni teclear un código.
    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Unirse con la cámara")

            Button {
                scanning = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Escanear el código de otro aparato")
                    Spacer()
                }
            }
            .buttonStyle(AccentButtonStyle())
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Sesiones cerca")

            if model.browser.access == .denied {
                Notice("Sin permiso de red local no se pueden ver otras sesiones. Puedes activarlo en Ajustes o escribir la dirección a mano.")
            } else if model.otherHosts.isEmpty {
                Text("Ninguna por ahora.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.ink500)
            } else {
                ForEach(model.otherHosts) { host in
                    Button {
                        model.join(host)
                        model.selectAfterJoining()
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Ink.accent)
                            Text(verbatim: host.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Ink.ink100)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.ink500)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Ink.ink850))
                    }
                    .buttonStyle(.plain)
                }
            }

            TPCardToggle(
                "Volver a unirme sola",
                subtitle: "A la última sesión, en cuanto aparezca",
                isOn: Binding(
                    get: { model.autoJoinEnabled }, set: { model.autoJoinEnabled = $0 })
            )
        }
    }

    /// Para redes donde el descubrimiento automático está capado.
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("O escribe la dirección")
            HStack(spacing: 8) {
                TextField("192.168.1.20", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                TextField("3000", text: $manualPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 74)
            }
            TextField("Código, si lo pide", text: $manualCode)
                .textFieldStyle(.roundedBorder)

            Button("Unirse") {
                guard let port = UInt16(manualPort), !manualHost.isEmpty else { return }
                model.join(
                    endpoint: .address(host: manualHost, port: port),
                    code: manualCode.isEmpty ? nil : manualCode)
                model.selectAfterJoining()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(manualHost.isEmpty || UInt16(manualPort) == nil)
        }
    }

    private var deviceCounts: some View {
        let clients = model.session.clients
        return HStack(spacing: 16) {
            CountBadge(symbol: "square.and.pencil", count: clients.editor)
            CountBadge(symbol: "play.rectangle", count: clients.prompter)
            CountBadge(symbol: "slider.horizontal.below.rectangle", count: clients.remote)
        }
    }
}

// ------------------------------------------------------------- piezas

private struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(Ink.ink500)
    }
}

private struct LabeledValue: View {
    let label: LocalizedStringKey
    let value: String
    init(_ label: LocalizedStringKey, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Ink.ink500)
            Spacer()
            Text(value)
                .font(.counter(13))
                .foregroundStyle(Ink.ink100)
                .textSelection(.enabled)
        }
    }
}

private struct Notice: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Ink.ink300)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
            )
    }
}

private struct CountBadge: View {
    let symbol: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(count > 0 ? Ink.accent : Ink.ink700)
            Text("\(count)")
                .font(.counter(13, weight: .semibold))
                .foregroundStyle(count > 0 ? Ink.ink100 : Ink.ink700)
        }
    }
}

enum QRCode {
    private static let context = CIContext()

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Sin escalar el QR sale de unos pocos píxeles y se ve borroso al
        // estirarlo; se amplía antes de rasterizar.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
