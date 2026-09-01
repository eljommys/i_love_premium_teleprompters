import Foundation
import Testing

@testable import PrompterCore

@Suite("Velocidad")
struct SpeedMathTests {

    struct Case: Decodable {
        let speed: Double
        let fontSize: Double
        let docHeight: Double
        let pxPerSecond: Double
        let rate: Double
    }

    @Test("los puntos por segundo y el ritmo coinciden con el servidor web")
    func matchesReferenceImplementation() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Fixture.data("speed"))

        for testCase in cases {
            let points = SpeedMath.pointsPerSecond(
                speed: testCase.speed, fontSize: testCase.fontSize)
            #expect(points == testCase.pxPerSecond)

            let rate = SpeedMath.scrollRate(
                speed: testCase.speed, fontSize: testCase.fontSize, docHeight: testCase.docHeight)
            #expect(rate == testCase.rate)
        }
    }

    @Test("sin visor que mida, el ritmo es cero y no hay duración estimada")
    func rateIsZeroWithoutMeasurement() {
        let state = TeleprompterState(docHeight: 0)
        #expect(state.scrollRate == 0)
        #expect(state.estimatedDuration == nil)
        #expect(state.remainingDuration == nil)
    }

    @Test("la duración estimada es el inverso del ritmo")
    func duration() throws {
        let state = TeleprompterState(speed: 30, fontSize: 64, position: 0.25, docHeight: 12480)
        let total = try #require(state.estimatedDuration)
        let remaining = try #require(state.remainingDuration)
        #expect(abs(total - 162.5) < 0.01)
        #expect(abs(remaining - total * 0.75) < 0.001)
    }

    @Test("la velocidad percibida no cambia al agrandar la letra")
    func perceivedSpeedIsFontIndependent() {
        // El doble de cuerpo recorre el doble de puntos por segundo, así que
        // las líneas por segundo se mantienen.
        let small = SpeedMath.pointsPerSecond(speed: 50, fontSize: 40)
        let large = SpeedMath.pointsPerSecond(speed: 50, fontSize: 80)
        #expect(large == small * 2)
    }

    @Test("los saltos de cinco segundos se traducen a fracción de guion")
    func jumpFraction() {
        let state = TeleprompterState(speed: 30, fontSize: 64, docHeight: 12480)
        let jump = state.fraction(forSeconds: Timing.jumpSeconds)
        #expect(abs(jump - state.scrollRate * 5) < 1e-12)
        // Cinco segundos de un guion de 162,5 s son algo más del 3 %.
        #expect(abs(jump - 0.030769) < 0.0001)
    }
}
