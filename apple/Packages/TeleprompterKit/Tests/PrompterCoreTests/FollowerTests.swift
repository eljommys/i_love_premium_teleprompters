import Foundation
import Testing

@testable import PrompterCore

@Suite("Seguimiento de posición")
struct FollowerTests {

    @Test("sin objetivo no corrige nada")
    func idleFollowerDoesNothing() {
        var follower = Follower()
        #expect(!follower.isBusy)
        let corrected = follower.step(
            position: 0.3, delta: 1 / 60, rate: 0, playing: false, blocked: false, now: 0)
        #expect(corrected == nil)
    }

    @Test("corrige igual a 60 Hz que a 120 Hz")
    func convergenceIsFrameRateIndependent() {
        // La corrección exponencial se compone: partir el mismo intervalo en
        // más trozos no puede acelerarla. Si esto se rompiera, un iPhone a
        // 120 Hz alcanzaría al iPad al doble de velocidad que otro a 60.
        func run(frames: Int, total: Double) -> Double {
            var follower = Follower()
            follower.aim(1)
            var position = 0.0
            let delta = total / Double(frames)
            for frame in 0..<frames {
                let now = delta * Double(frame)
                if let corrected = follower.step(
                    position: position, delta: delta, rate: 0, playing: false, blocked: false,
                    now: now)
                {
                    position = corrected
                }
            }
            return position
        }

        let sixty = run(frames: 3, total: 0.05)
        let hundredTwenty = run(frames: 6, total: 0.05)
        #expect(abs(sixty - hundredTwenty) < 1e-12)
        // Y de verdad se ha acercado: 0,05 s son algo más de media tau.
        #expect(abs(sixty - (1 - exp(-0.05 / Timing.followTau))) < 1e-12)
    }

    @Test("al alcanzar el objetivo se engancha y se suelta")
    func settlingSnapsAndClears() {
        var follower = Follower()
        follower.aim(0.5)
        let corrected = follower.step(
            position: 0.5 - Timing.settled / 2, delta: 1 / 60, rate: 0, playing: false,
            blocked: false, now: 0)
        #expect(corrected == 0.5)
        #expect(!follower.isBusy)
    }

    @Test("mientras se reproduce, el objetivo envejece y el seguimiento termina")
    func agingTargetLetsFollowingFinish() {
        // Sin envejecimiento la diferencia se estabiliza en rate*tau y el
        // seguidor no suelta nunca: la vista se queda pegada a un objetivo
        // viejo mientras el guion avanza solo.
        var follower = Follower()
        let rate = 0.01
        let delta = 1.0 / 60
        var position = 0.5
        follower.aim(0.52)

        var frames = 0
        while follower.isBusy, frames < 600 {
            position = min(1, position + rate * delta)  // el guion avanza solo
            if let corrected = follower.step(
                position: position, delta: delta, rate: rate, playing: true, blocked: false,
                now: delta * Double(frames))
            {
                position = corrected
            }
            frames += 1
        }

        #expect(!follower.isBusy, "el seguimiento no terminó en 10 segundos")
        #expect(frames < 120, "tardó demasiado en enganchar: \(frames) fotogramas")
    }

    @Test("tras mandar una posición propia se ignora la red 400 ms")
    func holdIgnoresTheNetwork() {
        var follower = Follower()
        follower.aim(0.9)
        follower.hold(now: 0)
        #expect(!follower.isBusy, "el objetivo pendiente se descarta al silenciar")

        // Un informe que aún viajaba trae la posición ANTERIOR: aplicarlo daría
        // un salto atrás, así que durante la ventana no se hace caso.
        follower.aim(0.1)
        let duringHold = follower.step(
            position: 0.9, delta: 1 / 60, rate: 0, playing: false, blocked: false, now: 0.2)
        #expect(duringHold == nil)
        #expect(!follower.isBusy)

        // Pasada la ventana vuelve a seguir.
        follower.aim(0.1)
        let afterHold = follower.step(
            position: 0.9, delta: 1 / 60, rate: 0, playing: false, blocked: false,
            now: Timing.holdAfterPublish + 0.01)
        #expect(afterHold != nil)
        #expect(afterHold! < 0.9)
    }

    @Test("la ventana de silencio dura exactamente lo pedido")
    func holdWindowLength() {
        var follower = Follower()
        follower.hold(now: 10)
        #expect(follower.isHolding(now: 10.399))
        #expect(!follower.isHolding(now: 10.401))
    }

    @Test("con el dedo puesto no se sigue a nadie")
    func blockedDiscardsTarget() {
        var follower = Follower()
        follower.aim(0.8)
        let corrected = follower.step(
            position: 0.2, delta: 1 / 60, rate: 0, playing: false, blocked: true, now: 0)
        #expect(corrected == nil)
        #expect(!follower.isBusy)
    }

    @Test("el objetivo envejecido nunca pasa del final")
    func agedTargetIsClamped() {
        var follower = Follower()
        follower.aim(0.999)
        var position = 0.9
        for frame in 0..<200 {
            if let corrected = follower.step(
                position: position, delta: 1 / 60, rate: 1, playing: true, blocked: false,
                now: Double(frame) / 60)
            {
                position = corrected
            }
            #expect(position <= 1)
        }
    }
}
