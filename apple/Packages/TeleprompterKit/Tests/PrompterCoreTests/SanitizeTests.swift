import Foundation
import Testing

@testable import PrompterCore

@Suite("Saneado de patches")
struct SanitizeTests {

    /// Cada caso trae la entrada cruda y lo que devolvió el servidor web con
    /// ella. Si Swift no coincide, es Swift quien está mal.
    struct Case: Decodable {
        let name: String
        let input: TeleprompterPatch
        let output: TeleprompterPatch
    }

    @Test("coincide con el servidor web caso por caso")
    func matchesReferenceImplementation() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Fixture.data("sanitize"))
        #expect(cases.count == 6, "los fixtures se han quedado cortos")

        for testCase in cases {
            let sanitized = testCase.input.sanitized() ?? TeleprompterPatch()
            #expect(sanitized == testCase.output, "caso «\(testCase.name)»")
        }
    }

    @Test("un patch que se queda sin nada aplicable devuelve nil")
    func emptyBecomesNil() {
        #expect(TeleprompterPatch().sanitized() == nil)
        // Todo del tipo equivocado: al decodificar ya no queda nada.
        let raw = Data(#"{"text":42,"playing":"si","speed":"rapido"}"#.utf8)
        let decoded = try? JSONDecoder().decode(TeleprompterPatch.self, from: raw)
        #expect(decoded?.sanitized() == nil)
    }

    @Test("los números imposibles se descartan en vez de propagarse")
    func nonFiniteValuesAreDropped() {
        let patch = TeleprompterPatch(
            speed: .nan,
            fontSize: .infinity,
            lineHeight: -.infinity,
            position: .nan,
            docHeight: .nan
        )
        #expect(patch.sanitized() == nil)
    }

    @Test("un valor imposible no arrastra a los buenos que le acompañan")
    func goodValuesSurviveBadCompany() throws {
        let patch = TeleprompterPatch(playing: true, speed: .nan, fontSize: 90)
        let sanitized = try #require(patch.sanitized())
        #expect(sanitized == TeleprompterPatch(playing: true, fontSize: 90))
    }

    @Test("el texto pasa tal cual, por largo o raro que sea")
    func textIsNotTouched() throws {
        let text = String(repeating: "guion muy largo\n", count: 4000)
        let sanitized = try #require(TeleprompterPatch(text: text).sanitized())
        #expect(sanitized.text == text)
    }

    @Test("las claves presentes se pueden consultar para decidir el guardado")
    func keysReflectPresence() {
        #expect(TeleprompterPatch(position: 0.5).keys == ["position"])
        #expect(TeleprompterPatch(text: "a", playing: true).keys == ["text", "playing"])
        #expect(TeleprompterPatch().keys.isEmpty)
    }

    @Test("aplicar un patch solo toca lo que trae")
    func applyOnlyTouchesPresentKeys() {
        var state = TeleprompterState(text: "original", speed: 30, position: 0.5)
        state.apply(TeleprompterPatch(speed: 70))
        #expect(state.speed == 70)
        #expect(state.text == "original")
        #expect(state.position == 0.5)
    }

    @Test("lo que se guarda en disco excluye playing y docHeight")
    func persistableExcludesEphemeralKeys() {
        let state = TeleprompterState(playing: true, position: 0.3, docHeight: 9999)
        let keys = state.persistablePatch.keys
        #expect(keys == TeleprompterState.persistedKeys)
        #expect(!keys.contains("playing"))
        #expect(!keys.contains("docHeight"))
    }

    @Test("la línea de lectura se acota lejos de los bordes")
    func readLineClamped() {
        #expect(TeleprompterPatch(readLine: 0).sanitized()?.readLine == Limits.readLine.min)
        #expect(TeleprompterPatch(readLine: 1).sanitized()?.readLine == Limits.readLine.max)
        #expect(TeleprompterPatch(readLine: 0.62).sanitized()?.readLine == 0.62)
        #expect(TeleprompterPatch(readLine: .nan).sanitized() == nil)
    }

    @Test("mover la línea de lectura no cambia el recorrido del guion")
    func readLineKeepsTravel() {
        // Los dos rellenos suman siempre el alto entero, así que el recorrido
        // medido —(rH + T + (1−r)H) − H— es la altura del texto sea cual sea la
        // línea elegida. Si esto dejara de cumplirse, subir la línea movería el
        // guion en los demás aparatos y descuadraría las posiciones ya medidas.
        let height = 1000.0
        let textHeight = 4321.0
        for readLine in stride(from: Limits.readLine.min, through: Limits.readLine.max, by: 0.05) {
            let top = height * readLine
            let bottom = height * Geometry.tailPadding(readLine: readLine)
            let travel = (top + textHeight + bottom) - height
            #expect(abs(travel - textHeight) < 0.0001)
        }
    }
}
