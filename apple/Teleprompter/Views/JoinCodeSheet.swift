import PrompterClient
import SwiftUI

/// El paso del código, cuando el anfitrión pide uno.
///
/// Existe porque intentar entrar a ciegas solo consigue que te echen, y el
/// mensaje que quedaba entonces era un genérico «se perdió la conexión» que no
/// decía nada de lo que pasaba de verdad.
///
/// Escanear el QR del anfitrión evita este paso: lleva el código dentro.
struct JoinCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let host: DiscoveredHost
    @State private var code = ""
    @FocusState private var focused: Bool

    private var isWrongCode: Bool {
        model.joinError == .rejected(.badCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unirse a la sesión")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Ink.ink100)
                Text(verbatim: host.name)
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.ink500)
            }

            Text("Teclea el código que aparece en ese aparato, o escanea su QR para entrar sin teclear nada.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.ink300)
                .fixedSize(horizontal: false, vertical: true)

            TextField("0000", text: $code)
                .font(.counter(34, weight: .bold))
                .multilineTextAlignment(.center)
                .kerning(8)
                .focused($focused)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.ink850)
                )
                .onChange(of: code) { _, value in
                    // Solo cifras y como mucho cuatro: así no hace falta ni
                    // validar ni explicar nada.
                    let digits = value.filter(\.isNumber).prefix(4)
                    if String(digits) != value { code = String(digits) }
                }

            if isWrongCode {
                Text("Ese código no es. Míralo otra vez en el otro aparato.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button("Cancelar") {
                    model.pendingJoin = nil
                    dismiss()
                }
                .buttonStyle(GhostButtonStyle())

                Button("Unirse") {
                    model.join(host, code: code)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(code.count != 4)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.ink900)
        .onAppear { focused = true }
    }
}
