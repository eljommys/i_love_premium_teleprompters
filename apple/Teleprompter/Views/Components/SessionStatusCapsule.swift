import PrompterCore
import SwiftUI

/// El estado de la sesión, siempre en el mismo sitio de los modos: punto de
/// conexión y de quién es la sesión. Al tocarla se va al modo Conectar, que es
/// donde vive todo lo de unir aparatos.
struct SessionStatusCapsule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.select(.connect)
        } label: {
            HStack(spacing: 8) {
                ConnectionDot(connection: model.session.connection)
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.isJoined ? Ink.accentBright : Ink.ink300)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Ink.ink850)
                    .overlay(Capsule().strokeBorder(Ink.ink700, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sesión"))
        .accessibilityValue(Text(summary))
        .accessibilityHint(Text("Abre las opciones de sesión"))
    }

    private var summary: String {
        if let host = model.session.hostIdentity {
            return String(localized: "Conectado a \(host.name)")
        }
        let others = model.hostCore.remotePeerCount
        if others == 0 { return String(localized: "Solo") }
        return String(localized: "Anfitrión · ^[\(others) aparato](inflect: true)")
    }
}
