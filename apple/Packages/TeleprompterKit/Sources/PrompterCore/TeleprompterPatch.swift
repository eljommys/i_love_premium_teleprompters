import Foundation

/// Un cambio parcial del estado compartido. Solo viajan las claves que cambian,
/// así que **una clave ausente y una clave a cero significan cosas distintas**:
/// la primera no se toca y la segunda se escribe. De ahí que todo sea opcional
/// y que la codificación tenga que omitir los nil en vez de escribir `null`.
public struct TeleprompterPatch: Codable, Equatable, Sendable {
    public var text: String?
    public var playing: Bool?
    public var speed: Double?
    public var fontSize: Double?
    public var lineHeight: Double?
    public var margin: Double?
    public var mirrorH: Bool?
    public var mirrorV: Bool?
    public var position: Double?
    public var readLine: Double?
    public var readStyle: ReadStyle?
    public var docHeight: Double?

    public init(
        text: String? = nil,
        playing: Bool? = nil,
        speed: Double? = nil,
        fontSize: Double? = nil,
        lineHeight: Double? = nil,
        margin: Double? = nil,
        mirrorH: Bool? = nil,
        mirrorV: Bool? = nil,
        position: Double? = nil,
        readLine: Double? = nil,
        readStyle: ReadStyle? = nil,
        docHeight: Double? = nil
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

    public var isEmpty: Bool {
        text == nil && playing == nil && speed == nil && fontSize == nil && lineHeight == nil
            && margin == nil && mirrorH == nil && mirrorV == nil && position == nil
            && readLine == nil && readStyle == nil && docHeight == nil
    }

    /// Nombres de las claves presentes, para decidir con qué prisa se guarda.
    public var keys: Set<String> {
        var keys: Set<String> = []
        if text != nil { keys.insert("text") }
        if playing != nil { keys.insert("playing") }
        if speed != nil { keys.insert("speed") }
        if fontSize != nil { keys.insert("fontSize") }
        if lineHeight != nil { keys.insert("lineHeight") }
        if margin != nil { keys.insert("margin") }
        if mirrorH != nil { keys.insert("mirrorH") }
        if mirrorV != nil { keys.insert("mirrorV") }
        if position != nil { keys.insert("position") }
        if readLine != nil { keys.insert("readLine") }
        if readStyle != nil { keys.insert("readStyle") }
        if docHeight != nil { keys.insert("docHeight") }
        return keys
    }

    /// Filtra y acota el patch para que un cliente no pueda meter basura en el
    /// estado compartido. Devuelve nil si no queda nada aplicable.
    ///
    /// Las claves con el tipo cambiado ya se cayeron al decodificar; aquí se
    /// descartan además los números imposibles y se acotan los rangos.
    public func sanitized() -> TeleprompterPatch? {
        var clean = TeleprompterPatch()
        clean.text = text
        clean.playing = playing
        clean.mirrorH = mirrorH
        clean.mirrorV = mirrorV
        clean.speed = finite(speed).map(Limits.speed.clamp)
        clean.fontSize = finite(fontSize).map(Limits.fontSize.clamp)
        clean.lineHeight = finite(lineHeight).map(Limits.lineHeight.clamp)
        clean.margin = finite(margin).map(Limits.margin.clamp)
        clean.position = finite(position).map(Limits.position.clamp)
        clean.readLine = finite(readLine).map(Limits.readLine.clamp)
        // El estilo ya se validó al decodificar: si no era uno de los conocidos
        // llegó a nil y aquí no se toca nada.
        clean.readStyle = readStyle
        clean.docHeight = finite(docHeight).map(Limits.docHeight.clamp)
        return clean.isEmpty ? nil : clean
    }

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

extension TeleprompterPatch {
    /// Una clave desconocida, o conocida pero con otro tipo, no puede tumbar el
    /// mensaje entero: se ignora y el resto del patch se aplica igual.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }

        text = value(.text, String.self)
        playing = value(.playing, Bool.self)
        speed = value(.speed, Double.self)
        fontSize = value(.fontSize, Double.self)
        lineHeight = value(.lineHeight, Double.self)
        margin = value(.margin, Double.self)
        mirrorH = value(.mirrorH, Bool.self)
        mirrorV = value(.mirrorV, Bool.self)
        position = value(.position, Double.self)
        readLine = value(.readLine, Double.self)
        readStyle = value(.readStyle, ReadStyle.self)
        docHeight = value(.docHeight, Double.self)
    }
}
