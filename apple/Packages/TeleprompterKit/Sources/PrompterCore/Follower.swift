import Foundation

/// Acerca `position` a `target` de forma exponencial e independiente de los
/// fotogramas por segundo, para que un iPhone a 120 Hz no corrija al doble de
/// velocidad que un iPad a 60 Hz. `tau` es el tiempo en segundos que tarda en
/// recorrer el 63 % de la distancia que falta.
public func converge(_ position: Double, toward target: Double, delta: Double, tau: Double)
    -> Double
{
    position + (target - position) * (1 - exp(-delta / tau))
}

/// Sigue una posición que llega por la red acercándose a ella poco a poco, en
/// vez de saltar: es lo que convierte el arrastre del móvil en un movimiento
/// continuo en el iPad aunque las posiciones lleguen a golpes.
///
/// El reloj se pasa desde fuera en vez de leerlo aquí para que las pruebas
/// puedan medir la ventana de silencio sin esperar de verdad.
public struct Follower: Sendable, Equatable {
    private var target: Double?
    private var holdUntil: TimeInterval = -.infinity
    private let tau: Double

    public init(tau: Double = Timing.followTau) {
        self.tau = tau
    }

    /// Fija la posición a la que hay que llegar.
    public mutating func aim(_ target: Double) {
        self.target = target
    }

    /// Deja de hacer caso a la red durante un rato y descarta lo que hubiera
    /// pendiente. Se usa al mandar una posición propia.
    public mutating func hold(
        _ duration: TimeInterval = Timing.holdAfterPublish,
        now: TimeInterval
    ) {
        target = nil
        holdUntil = now + duration
    }

    /// ¿Está alcanzando una posición pedida por otro aparato?
    public var isBusy: Bool { target != nil }

    public func isHolding(now: TimeInterval) -> Bool { now < holdUntil }

    /// Un paso de seguimiento. Devuelve la posición corregida, o nil si no hay
    /// nada que corregir.
    ///
    /// Mientras se reproduce, el objetivo envejece al mismo ritmo que la
    /// lectura. Sin eso el objetivo se queda quieto mientras la posición avanza
    /// sola, la diferencia se estabiliza en `rate * tau` y nunca baja del
    /// umbral: el seguimiento no termina nunca y la vista se congela.
    public mutating func step(
        position: Double,
        delta: TimeInterval,
        rate: Double,
        playing: Bool,
        blocked: Bool,
        now: TimeInterval
    ) -> Double? {
        guard let current = target else { return nil }

        if blocked || now < holdUntil {
            target = nil
            return nil
        }

        var aged = current
        if playing, rate > 0 {
            aged = Swift.min(1, aged + rate * delta)
            target = aged
        }

        if abs(aged - position) < Timing.settled {
            target = nil
            return aged
        }

        return converge(position, toward: aged, delta: delta, tau: tau)
    }
}
