import Foundation

/// El código que el anfitrión enseña para que nadie de la red se cuele en la
/// sesión sin querer. Cuatro cifras: suficiente contra el despiste del vecino
/// de plató, y corto de teclear en un móvil. Contra un ataque de verdad lo que
/// protege es que todo esto no sale de la red local.
public enum PairingCode {
    public static let length = 4

    public static func generate() -> String {
        (0..<length).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Solo dígitos y de la longitud exacta.
    public static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy(\.isNumber)
    }
}
