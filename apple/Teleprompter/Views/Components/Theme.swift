import SwiftUI

/// La paleta de la versión web, traducida.
///
/// Una escala de grises verdosos y un solo acento turquesa. Todo oscuro: el
/// visor lo es por obligación —va detrás de un cristal, delante de una cámara—
/// y que el resto de la aplicación cambie de humor no aportaría nada.
enum Ink {
    static let ink950 = Color(hex: 0x070B0B)
    static let ink900 = Color(hex: 0x0D1213)
    static let ink850 = Color(hex: 0x131A1B)
    static let ink800 = Color(hex: 0x1A2224)
    static let ink700 = Color(hex: 0x263134)
    static let ink500 = Color(hex: 0x5B6B6E)
    static let ink300 = Color(hex: 0x9AABAE)
    static let ink100 = Color(hex: 0xE6EDED)

    static let accent = Color(hex: 0x14B8A6)
    static let accentBright = Color(hex: 0x2DD4BF)
    static let accentDim = Color(hex: 0x0F766E)

    /// Negro de verdad, no ink950: es lo que hay detrás del cristal del
    /// teleprompter, y en una pantalla OLED la diferencia se nota.
    static let viewerBackground = Color.black
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// Para cifras que cambian sin parar —tiempos, porcentajes, contadores— y
    /// que bailarían con anchos variables.
    static func counter(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

// ------------------------------------------------------------ botones

struct AccentButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Ink.ink950 : Ink.ink100)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? Ink.accentBright : Ink.ink800)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Ink.ink300)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Ink.ink900)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Ink.ink700, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
