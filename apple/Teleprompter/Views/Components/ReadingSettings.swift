import PrompterCore
import SwiftUI

/// Los ajustes de la zona de lectura: a qué altura cae y cómo se marca.
///
/// Es el mismo control en el editor, en el visor y en el mando: son ajustes de
/// la sesión, no de un aparato, así que se ven y se cambian desde cualquiera.
struct ReadingSettings: View {
    @Environment(AppModel.self) private var model
    private var session: any TeleprompterSession { model.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TPSlider(
                title: "Línea de lectura",
                value: Binding(
                    get: { session.state.readLine },
                    set: { session.update(TeleprompterPatch(readLine: $0)) }),
                bounds: Limits.readLine,
                // Se enseña como porcentaje del alto: «40 %» dice mucho más que
                // «0,40» a quien está colocando el cristal.
                format: { "\(Int(($0 * 100).rounded())) %" }
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Marca de lectura")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.ink300)

                // Cinco muestras que dibujan la marca de verdad en vez de
                // nombrarla. Los rótulos no cabían en el ancho de un móvil, y
                // además «línea y punto» se entiende antes viéndolo.
                HStack(spacing: 8) {
                    ForEach(ReadStyle.allCases, id: \.self) { style in
                        ReadStyleSwatch(
                            style: style,
                            isOn: session.state.readStyle == style
                        ) {
                            session.update(TeleprompterPatch(readStyle: style))
                        }
                    }
                }
            }
        }
    }
}

/// Una muestra tocable de una marca de lectura, con un renglón de ejemplo
/// detrás para que se vea cómo queda sobre el guion.
private struct ReadStyleSwatch: View {
    let style: ReadStyle
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Ink.viewerBackground)
                // Dos rayas grises hacen de renglones: sin nada detrás, la
                // banda de resaltado no se distingue de un rectángulo vacío.
                VStack(spacing: 7) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(Ink.ink700).frame(height: 3)
                    }
                }
                .padding(.horizontal, 10)
                ReadingLine(style: style, bandHeight: 14)
            }
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? Ink.accentBright : Ink.ink700, lineWidth: isOn ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(style.title))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

