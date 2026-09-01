import Foundation

public enum SpeedMath {
    /// Puntos por segundo para una velocidad y un cuerpo de letra dados.
    ///
    /// Escala con el tamaño de fuente: así la velocidad percibida, que se mide
    /// en líneas por segundo, no cambia al agrandar la letra.
    public static func pointsPerSecond(speed: Double, fontSize: Double) -> Double {
        (speed / 100) * fontSize * 4
    }

    /// Velocidad en fracción de guion por segundo, la única unidad que
    /// significa lo mismo en el iPad y en el móvil. Es 0 mientras el visor no
    /// haya medido su recorrido, porque solo él sabe cuánto ocupa el guion.
    public static func scrollRate(speed: Double, fontSize: Double, docHeight: Double) -> Double {
        guard docHeight > 0 else { return 0 }
        let rate = pointsPerSecond(speed: speed, fontSize: fontSize) / docHeight
        return rate.isFinite ? rate : 0
    }
}

extension TeleprompterState {
    public var pointsPerSecond: Double {
        SpeedMath.pointsPerSecond(speed: speed, fontSize: fontSize)
    }

    public var scrollRate: Double {
        SpeedMath.scrollRate(speed: speed, fontSize: fontSize, docHeight: docHeight)
    }

    /// Duración del guion entero, o nil si aún no hay visor que lo haya medido.
    public var estimatedDuration: TimeInterval? {
        let rate = scrollRate
        guard rate > 0 else { return nil }
        return 1 / rate
    }

    /// Lo que queda desde la posición actual.
    public var remainingDuration: TimeInterval? {
        let rate = scrollRate
        guard rate > 0 else { return nil }
        return (1 - position) / rate
    }

    /// Cuánta fracción de guion son unos segundos, para los botones de salto.
    public func fraction(forSeconds seconds: TimeInterval) -> Double {
        scrollRate * seconds
    }
}
