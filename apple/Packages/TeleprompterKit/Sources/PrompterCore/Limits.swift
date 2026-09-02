import Foundation

/// Rangos válidos de los ajustes. Son los mismos que aplica el servidor de la
/// versión web al sanear cada patch, y los mismos que usan los sliders: si aquí
/// y allí no coincidieran, un aparato vería su propio ajuste rebotar.
public enum Limits {
    public struct Bounds: Sendable, Equatable {
        public let min: Double
        public let max: Double
        /// Salto del slider. No interviene en el saneado.
        public let step: Double

        public init(min: Double, max: Double, step: Double) {
            self.min = min
            self.max = max
            self.step = step
        }

        public func clamp(_ value: Double) -> Double {
            Swift.min(max, Swift.max(min, value))
        }

        public var closedRange: ClosedRange<Double> { min...max }
    }

    public static let speed = Bounds(min: 1, max: 100, step: 1)
    public static let fontSize = Bounds(min: 24, max: 160, step: 2)
    public static let lineHeight = Bounds(min: 1, max: 2.5, step: 0.05)
    public static let margin = Bounds(min: 0, max: 30, step: 1)
    public static let position = Bounds(min: 0, max: 1, step: 0)
    /// Dónde cae la línea de lectura, en fracción del alto. No se deja llegar a
    /// los bordes: pegada arriba no queda texto que leer por delante, y pegada
    /// abajo no se ve lo que viene.
    public static let readLine = Bounds(min: 0.15, max: 0.85, step: 0.01)
    /// Diez millones de puntos de recorrido: un tope absurdo a propósito, solo
    /// para que un cliente no pueda meter un infinito disfrazado.
    public static let docHeight = Bounds(min: 0, max: 1e7, step: 0)
}

/// Constantes de tiempo del movimiento del guion. Están juntas porque son un
/// conjunto afinado: tocar una sola descuadra la sensación de las demás.
public enum Timing {
    /// Segundos que tarda el seguimiento en recorrer el 63 % de lo que falta.
    public static let followTau: Double = 0.09
    /// Por debajo de esta diferencia se da por alcanzada la posición pedida.
    public static let settled: Double = 0.0002
    /// Cuánto se ignora la red después de mandar una posición propia. Los
    /// informes que aún viajaban traen la posición ANTERIOR y aplicarlos daría
    /// un salto atrás.
    public static let holdAfterPublish: Double = 0.4
    /// Cada cuánto informa el visor de por dónde va mientras reproduce.
    public static let viewerReportInterval: Double = 0.2
    /// Movimiento mínimo que merece un informe del visor.
    public static let viewerReportThreshold: Double = 0.0005
    /// Tope de envíos del mando mientras el dedo arrastra (~30 por segundo).
    public static let remotePublishInterval: Double = 0.033
    /// Píxeles que hay que mover antes de que un toque cuente como arrastre.
    public static let dragSlop: Double = 10
    /// Salto de los botones de avance y retroceso.
    public static let jumpSeconds: Double = 5
    /// Un fotograma perdido no debe teletransportar el guion.
    public static let maxFrameDelta: Double = 0.1
    /// Cuánto tarda en esconderse la botonera del visor.
    public static let chromeAutoHide: Double = 4
    /// Latido para detectar aparatos que se han ido sin cerrar el socket.
    public static let heartbeatInterval: Double = 30
}

/// Geometría del guion, idéntica en el visor y en el mando.
public enum Geometry {
    /// Dónde cae la línea de lectura por defecto, en fracción del alto.
    public static let defaultReadLine: Double = 0.4

    /// Relleno bajo el texto para una línea de lectura dada.
    ///
    /// Los dos rellenos suman siempre el alto entero del hueco, y por eso el
    /// recorrido medido es exactamente la altura del texto: (rH + T + (1−r)H) −
    /// H = T, sea cual sea H y sea cual sea r. Gracias a eso `position`
    /// significa lo mismo en el iPad a pantalla completa que en el panel del
    /// móvil, y **subir o bajar la línea de lectura no mueve el guion de sitio**
    /// ni descuadra lo que ya habían medido los demás aparatos.
    public static func tailPadding(readLine: Double) -> Double { 1 - readLine }

    /// A cuántos puntos hay que desplazar el guion para una posición dada.
    ///
    /// Devuelve nil si el resultado no es un número finito, y ese es el motivo
    /// de que esto exista como función aparte en vez de escrito en cada vista:
    /// a mitad de maquetación TextKit puede dar un recorrido infinito, y con la
    /// posición en cero sale `0 × ∞`, o sea NaN. Ese NaN llegaba al origen del
    /// scroll, y AppKit no valida esa geometría: mata la aplicación con
    /// «Invalid view geometry». Mejor no pintar ese fotograma.
    public static func paintOffset(
        readLine: Double, viewportHeight: Double, position: Double, travel: Double
    ) -> Double? {
        let offset = -readLine * viewportHeight + position * travel
        return offset.isFinite ? offset : nil
    }
}
