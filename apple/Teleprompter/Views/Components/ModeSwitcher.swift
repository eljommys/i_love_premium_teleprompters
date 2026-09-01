import SwiftUI

/// El paso de un modo a otro: Editor, Visor y Mando, siempre los tres a la vista.
///
/// Es un control propio y no la barra de pestañas del sistema por dos razones.
/// La primera es que el sistema la coloca abajo en el iPhone y flotando arriba
/// en el iPad, y aquí la interacción tiene que ser la misma en los tres
/// aparatos. La segunda es que en iPad no llegaba a dibujarse, y quedarse sin
/// manera de salir del visor no es un detalle estético: es una vista sin salida.
struct ModeSwitcher: View {
    @Environment(AppModel.self) private var model

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var widthClass
        /// Cuatro rótulos no caben en el ancho de un móvil. Se queda el del modo
        /// activo, que es el que dice dónde estás; los demás se reconocen por el
        /// icono y tienen su nombre para VoiceOver.
        private var labelsEverywhere: Bool { widthClass != .compact }
    #else
        private var labelsEverywhere: Bool { true }
    #endif

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Mode.allCases) { mode in
                segment(for: mode)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Ink.ink850)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Ink.ink700, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Modo"))
    }

    private func segment(for mode: AppModel.Mode) -> some View {
        let selected = model.mode == mode
        return Button {
            model.select(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        // Un punto en vez de un cartel: que haya sesiones cerca
                        // se dice sin quitarle sitio al guion.
                        if mode == .connect, model.discoveredCount > 0, !model.isJoined {
                            Circle()
                                .fill(Ink.accentBright)
                                .frame(width: 6, height: 6)
                                .offset(x: 4, y: -3)
                        }
                    }
                if selected || labelsEverywhere {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(selected ? Ink.ink950 : Ink.ink300)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Ink.accentBright : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
