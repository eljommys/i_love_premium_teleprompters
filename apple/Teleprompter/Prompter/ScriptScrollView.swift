import PrompterCore
import SwiftUI

/// El guion desplazándose, con su línea de lectura. Lo usan igual el visor y el
/// mando: cambian el cuerpo de letra y el marco, no la mecánica.
struct ScriptScrollView: View {
    let text: String
    let fontSize: Double
    let lineHeight: Double
    let marginFraction: Double
    let engine: ScriptScrollEngine
    /// Dónde cae la línea de lectura, en fracción del alto.
    var readLine: Double = Geometry.defaultReadLine
    var readStyle: ReadStyle = .default
    var showsReadingLine = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                PrompterTextView(
                    text: text,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    marginFraction: marginFraction,
                    engine: engine,
                    viewportSize: geometry.size,
                    readLine: readLine
                )

                if showsReadingLine {
                    // La banda de resaltado se dibuja del alto de un renglón,
                    // para que abrace la línea que toca leer y no una franja
                    // arbitraria.
                    ReadingLine(style: readStyle, bandHeight: fontSize * lineHeight)
                        .offset(y: geometry.size.height * readLine)
                }
            }
        }
        .clipped()
    }
}

/// Un guion vacío no debe verse como una avería.
struct EmptyScriptHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Ink.ink700)
            Text("Todavía no hay guion")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Ink.ink500)
            Text("Escríbelo en el editor, desde este aparato o desde otro.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.ink700)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
