import Foundation

/// Papel que declara cada aparato al conectarse. Solo sirve para contar quién
/// hay al otro lado: ninguna regla del protocolo depende del papel.
public enum Role: String, Codable, Sendable, CaseIterable {
    case editor
    case prompter
    case remote
    case home
}

/// Estado compartido de la sesión. Plano y sin historia: gana el último que
/// escribe. Los nombres de las propiedades son los nombres del protocolo, y no
/// se pueden cambiar sin romper la compatibilidad con la versión web.
public struct TeleprompterState: Codable, Equatable, Sendable {
    /// Guion completo.
    public var text: String
    /// Auto-scroll activo.
    public var playing: Bool
    /// Velocidad 1-100 (se mapea a px/s en el visor).
    public var speed: Double
    /// Tamaño de fuente del visor, en puntos.
    public var fontSize: Double
    /// Interlineado (multiplicador).
    public var lineHeight: Double
    /// Margen horizontal del visor en % del ancho.
    public var margin: Double
    /// Espejo horizontal (el habitual en cristales de teleprompter).
    public var mirrorH: Bool
    /// Espejo vertical.
    public var mirrorV: Bool
    /// Posición de scroll normalizada 0..1.
    public var position: Double
    /// Dónde cae la línea de lectura, en fracción del alto del hueco.
    public var readLine: Double
    /// Cómo se marca la zona por la que toca leer.
    public var readStyle: ReadStyle
    /// Recorrido total del guion, tal y como lo mide el visor. Permite al mando
    /// traducir un arrastre del dedo a un desplazamiento proporcional y estimar
    /// el tiempo restante.
    public var docHeight: Double

    public init(
        text: String = "",
        playing: Bool = false,
        speed: Double = 30,
        fontSize: Double = 64,
        lineHeight: Double = 1.5,
        margin: Double = 8,
        mirrorH: Bool = false,
        mirrorV: Bool = false,
        position: Double = 0,
        readLine: Double = Geometry.defaultReadLine,
        readStyle: ReadStyle = .default,
        docHeight: Double = 0
    ) {
        self.text = text
        self.playing = playing
        self.speed = speed
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.margin = margin
        self.mirrorH = mirrorH
        self.mirrorV = mirrorV
        self.position = position
        self.readLine = readLine
        self.readStyle = readStyle
        self.docHeight = docHeight
    }

    public static let initial = TeleprompterState()

    /// Claves que se guardan en disco, para no perder el guion ni por dónde
    /// ibas. `playing` y `docHeight` quedan fuera a propósito: uno no debe
    /// sobrevivir a un reinicio y el otro lo vuelve a medir el visor.
    public static let persistedKeys: Set<String> = [
        "text", "speed", "fontSize", "lineHeight", "margin", "mirrorH", "mirrorV", "position",
        "readLine", "readStyle",
    ]

    /// Claves que cambian muchas veces por segundo mientras se lee o se
    /// arrastra. Se guardan igual, pero con mucha menos prisa.
    public static let liveKeys: Set<String> = ["position"]

    /// Aplica un patch encima. El patch ya viene saneado del borde de la red.
    public mutating func apply(_ patch: TeleprompterPatch) {
        if let value = patch.text { text = value }
        if let value = patch.playing { playing = value }
        if let value = patch.speed { speed = value }
        if let value = patch.fontSize { fontSize = value }
        if let value = patch.lineHeight { lineHeight = value }
        if let value = patch.margin { margin = value }
        if let value = patch.mirrorH { mirrorH = value }
        if let value = patch.mirrorV { mirrorV = value }
        if let value = patch.position { position = value }
        if let value = patch.readLine { readLine = value }
        if let value = patch.readStyle { readStyle = value }
        if let value = patch.docHeight { docHeight = value }
    }

    public func applying(_ patch: TeleprompterPatch) -> TeleprompterState {
        var copy = self
        copy.apply(patch)
        return copy
    }

    /// Solo lo que se persiste, listo para escribir en disco con la misma forma
    /// que el `state.json` de la versión de línea de comandos.
    public var persistablePatch: TeleprompterPatch {
        TeleprompterPatch(
            text: text,
            speed: speed,
            fontSize: fontSize,
            lineHeight: lineHeight,
            margin: margin,
            mirrorH: mirrorH,
            mirrorV: mirrorV,
            position: position,
            readLine: readLine,
            readStyle: readStyle
        )
    }
}

extension TeleprompterState {
    /// Un estado que llega incompleto se completa con los valores por defecto,
    /// igual que el `{...DEFAULT_STATE, ...}` del servidor. Una clave con el
    /// tipo cambiado tampoco tumba el mensaje entero: se ignora y se queda el
    /// valor por defecto.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TeleprompterState()

        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }

        text = value(.text, String.self) ?? fallback.text
        playing = value(.playing, Bool.self) ?? fallback.playing
        speed = value(.speed, Double.self) ?? fallback.speed
        fontSize = value(.fontSize, Double.self) ?? fallback.fontSize
        lineHeight = value(.lineHeight, Double.self) ?? fallback.lineHeight
        margin = value(.margin, Double.self) ?? fallback.margin
        mirrorH = value(.mirrorH, Bool.self) ?? fallback.mirrorH
        mirrorV = value(.mirrorV, Bool.self) ?? fallback.mirrorV
        position = value(.position, Double.self) ?? fallback.position
        readLine = value(.readLine, Double.self) ?? fallback.readLine
        readStyle = value(.readStyle, ReadStyle.self) ?? fallback.readStyle
        docHeight = value(.docHeight, Double.self) ?? fallback.docHeight
    }
}
