import Foundation

/// Cómo se marca en pantalla la zona por la que toca leer.
///
/// Viaja por la red como cadena, no como número: un valor desconocido —una
/// versión más nueva al otro lado— se ignora y se queda el que hubiera, en vez
/// de convertirse en un estilo equivocado.
public enum ReadStyle: String, Codable, Sendable, CaseIterable {
    /// Solo el rombo, en medio.
    case dot
    /// Rombo con línea a los lados. El de siempre.
    case lineDot
    /// Una línea limpia de lado a lado.
    case line
    /// Una banda tenue del alto de un renglón.
    case highlight
    /// Banda y línea.
    case highlightLine

    public static let `default` = ReadStyle.lineDot

    /// ¿Lleva banda de resaltado?
    public var hasBand: Bool { self == .highlight || self == .highlightLine }
    /// ¿Lleva línea de lado a lado?
    public var hasLine: Bool { self == .line || self == .lineDot || self == .highlightLine }
    /// ¿Lleva rombo?
    public var hasDot: Bool { self == .dot || self == .lineDot }
}
