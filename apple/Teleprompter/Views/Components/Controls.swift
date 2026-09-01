import PrompterCore
import SwiftUI

/// Slider con etiqueta y valor, el mismo en el editor y en la hoja de ajustes
/// del mando.
struct TPSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let bounds: Limits.Bounds
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.ink300)
                Spacer()
                Text(format(value))
                    .font(.counter(13, weight: .semibold))
                    .foregroundStyle(Ink.accentBright)
            }
            Slider(
                value: $value,
                in: bounds.closedRange,
                step: bounds.step > 0 ? bounds.step : 0.01,
                onEditingChanged: { editing in if !editing { onCommit() } }
            )
            .tint(Ink.accentBright)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(format(value))
    }
}

/// Interruptor con cuerpo de tarjeta: en el plató se busca con el dedo y de
/// reojo, así que tiene que ser grande y decir su estado con el color.
struct TPCardToggle: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? Ink.accentBright : Ink.ink100)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.ink500)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Ink.accentBright : Ink.ink700)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Ink.accent.opacity(0.1) : Ink.ink900)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isOn ? Ink.accent : Ink.ink700, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Punto de estado de la conexión. Verde fijo cuando todo va, gris latiendo
/// mientras busca, rojo cuando no hay nadie.
struct ConnectionDot: View {
    let connection: ConnectionStatus
    var label: LocalizedStringKey?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private var color: Color {
        switch connection {
        case .online: Ink.accentBright
        case .connecting: Ink.ink500
        case .offline: Color(hex: 0xF87171)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(dim ? 0.35 : 1)
                .animation(
                    connection == .connecting && !reduceMotion
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                    value: dim
                )
                .onAppear { dim = connection == .connecting && !reduceMotion }
                .onChange(of: connection) { _, new in dim = new == .connecting && !reduceMotion }
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.ink300)
            }
        }
    }
}

/// Barra de progreso de lectura. Sin animación implícita: la mueve el motor de
/// scroll y cualquier interpolación de más se vería como un retraso.
struct TPProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.ink800)
                Capsule()
                    .fill(Ink.accent)
                    .frame(width: max(0, min(1, progress)) * geometry.size.width)
            }
        }
        .frame(height: 4)
        .animation(nil, value: progress)
        .accessibilityHidden(true)
    }
}

/// La misma barra, en el canto del visor, donde no estorba a la lectura.
struct VerticalProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Capsule().fill(Ink.ink800.opacity(0.6))
                Capsule()
                    .fill(Ink.accent.opacity(0.85))
                    .frame(height: max(0, min(1, progress)) * geometry.size.height)
            }
        }
        .frame(width: 3)
        .animation(nil, value: progress)
        .accessibilityHidden(true)
    }
}

/// Marca de la línea de lectura: dos filos y un rombo, al 40 % del alto.
/// Discreta, porque va a estar delante de los ojos veinte minutos seguidos.
struct ReadingLine: View {
    var style: ReadStyle = .default
    /// Alto de un renglón, para que la banda abrace justo la línea que se lee.
    var bandHeight: Double = 0

    var body: some View {
        ZStack {
            if style.hasBand {
                Rectangle()
                    .fill(Ink.accent.opacity(0.14))
                    .frame(height: max(24, bandHeight))
            }

            if style.hasLine || style.hasDot {
                HStack(spacing: 0) {
                    if style.hasLine {
                        Rectangle()
                            .fill(Ink.accent.opacity(0.25))
                            .frame(height: 1)
                    }
                    if style.hasDot {
                        Rectangle()
                            .fill(Ink.accent.opacity(0.6))
                            .frame(width: 10, height: 10)
                            .rotationEffect(.degrees(45))
                            .padding(.horizontal, 6)
                    }
                    if style.hasLine {
                        Rectangle()
                            .fill(Ink.accent.opacity(0.25))
                            .frame(height: 1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension ReadStyle {
    var title: LocalizedStringKey {
        switch self {
        case .dot: "Punto"
        case .lineDot: "Línea y punto"
        case .line: "Línea"
        case .highlight: "Resaltado"
        case .highlightLine: "Resaltado y línea"
        }
    }
}
