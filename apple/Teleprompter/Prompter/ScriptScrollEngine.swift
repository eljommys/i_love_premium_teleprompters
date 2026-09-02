import Observation
import PrompterCore
import SwiftUI

/// La mecánica de desplazamiento del guion: avanza, sigue a quien mande y
/// decide cuándo contar por dónde va.
///
/// La posición se guarda **siempre normalizada**, nunca en puntos. Así una
/// posición que llega antes de haber medido no se pierde: se pinta en cuanto se
/// conoce el recorrido. Guardarla en puntos la multiplicaba por un recorrido de
/// cero.
///
/// El motor no sabe nada de la red. Quién manda, quién sigue y quién informa lo
/// decide cada vista.
@MainActor
@Observable
final class ScriptScrollEngine {

    /// Progreso para la interfaz, en pasos de 1/500. Cuantizado a propósito:
    /// repintar una barra a 120 fotogramas por segundo es tirar batería para
    /// mover dos píxeles.
    private(set) var progressStep: Int = 0

    /// Posición viva. Fuera de la observación porque cambia en cada fotograma.
    @ObservationIgnored private(set) var position: Double = 0
    /// Recorrido en puntos de ESTA pantalla. Convierte dedo en fracción.
    @ObservationIgnored private(set) var travel: Double = 0

    @ObservationIgnored var playing = false
    /// Avance en fracción de guion por segundo. 0 = no avanzar solo.
    @ObservationIgnored var rate: Double = 0
    /// Mientras el dedo está puesto no se sigue a nadie ni se avanza solo.
    @ObservationIgnored var isGrabbed = false

    /// Pintar. Lo instala la vista de texto, que es quien sabe mover píxeles.
    @ObservationIgnored var onPaint: ((Double) -> Void)?
    /// Una sola vez al llegar al final estando en marcha.
    @ObservationIgnored var onEnd: (() -> Void)?
    /// Al cambiar el recorrido medido, en puntos de esta pantalla.
    @ObservationIgnored var onMeasure: ((Double) -> Void)?

    @ObservationIgnored private var follower = Follower()
    @ObservationIgnored private var lastFrame: TimeInterval?

    var progress: Double { Double(progressStep) / 500 }

    // ------------------------------------------------------------ posición

    /// Coloca la posición sin pasar por el seguimiento. Para cuando manda el
    /// propio aparato: un dedo arrastrando o un salto de cinco segundos.
    func setPosition(_ value: Double) {
        position = clamp01(value)
        paint()
    }

    /// Fija una posición que ha llegado de otro aparato. No se salta a ella: se
    /// va hacia ella, que es lo que hace que un arrastre a golpes en el móvil se
    /// vea como un movimiento continuo en el iPad.
    func aim(_ target: Double) {
        follower.aim(clamp01(target))
    }

    /// Deja de hacer caso a la red un rato, tras haber mandado una posición
    /// propia: los informes que aún viajaban traen la posición ANTERIOR y
    /// aplicarlos daría un salto atrás.
    func hold(_ duration: TimeInterval = Timing.holdAfterPublish) {
        follower.hold(duration, now: now)
    }

    var isFollowing: Bool { follower.isBusy }

    // ------------------------------------------------------------ medida

    /// La vista de texto avisa de cuánto ocupa el guion en esta pantalla.
    ///
    /// Una medida que no sea un número finito se descarta entera. A mitad de
    /// maquetación TextKit puede devolver un infinito, y de ahí sale un NaN
    /// —`0 × ∞`— que acaba en el origen del scroll: AppKit no valida esa
    /// geometría y mata la aplicación.
    func measured(travel value: Double) {
        guard value.isFinite else { return }
        let changed = abs(value - travel) > 1
        travel = max(0, value)
        paint()
        // Las medidas llegan de más al redimensionar; solo se avisa de las
        // que cambian algo.
        if changed { onMeasure?(travel) }
    }

    // ------------------------------------------------- bucle de fotogramas

    func tick(at timestamp: TimeInterval) {
        let delta = min(timestamp - (lastFrame ?? timestamp), Timing.maxFrameDelta)
        lastFrame = timestamp
        advance(by: delta)
    }

    /// Separado del reloj para poder probarlo sin pantalla.
    func advance(by delta: TimeInterval) {
        if playing, rate > 0, !isGrabbed {
            // Avisar del final también cuando ya se estaba allí: si no, pulsar
            // Reproducir con el guion terminado dejaría `playing` encendido
            // para siempre sin que se mueva nada.
            if position >= 1 {
                onEnd?()
            } else {
                position = clamp01(position + rate * delta)
                if position >= 1 { onEnd?() }
            }
        }

        if let corrected = follower.step(
            position: position,
            delta: delta,
            rate: rate,
            playing: playing,
            blocked: isGrabbed,
            now: now
        ) {
            position = clamp01(corrected)
        }

        paint()
        publishProgress()
    }

    private func paint() {
        onPaint?(position)
    }

    private func publishProgress() {
        let step = Int((position * 500).rounded())
        if step != progressStep { progressStep = step }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func clamp01(_ value: Double) -> Double {
        value < 0 ? 0 : (value > 1 ? 1 : value)
    }
}

/// Decide cuándo toca contarle al resto por dónde vamos.
///
/// El visor informa a un ritmo suave mientras lee; el mando, mucho más a menudo
/// mientras el dedo arrastra. Los dos se callan si lo que iban a decir es lo
/// mismo que dijeron la última vez.
@MainActor
struct PositionReporter {
    private var lastReported: Double = -1
    private var lastSentAt: TimeInterval = -.infinity

    let interval: TimeInterval
    let threshold: Double

    init(interval: TimeInterval, threshold: Double = Timing.settled) {
        self.interval = interval
        self.threshold = threshold
    }

    /// ¿Toca informar de esta posición?
    mutating func shouldReport(_ position: Double, now: TimeInterval, force: Bool = false) -> Bool {
        if !force {
            guard now - lastSentAt >= interval else { return false }
            guard abs(position - lastReported) >= threshold else { return false }
        }
        lastReported = position
        lastSentAt = now
        return true
    }

    /// Lo último que dijimos. Sirve para reconocer nuestro propio eco cuando
    /// vuelve por la red.
    var reported: Double { lastReported }

    /// ¿Esta posición que llega es el eco de la nuestra?
    func isOwnEcho(_ position: Double) -> Bool {
        abs(position - lastReported) < threshold
    }

    mutating func forget() {
        lastReported = -1
    }
}
