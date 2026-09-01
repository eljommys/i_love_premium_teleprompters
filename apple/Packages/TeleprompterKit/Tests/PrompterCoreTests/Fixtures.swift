import Foundation
import Testing

/// Los fixtures salen de ejecutar la lógica del servidor web (`lib/state.ts`),
/// así que comparar contra ellos es comparar contra la implementación original,
/// no contra lo que creemos recordar de ella.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "falta el fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }
}

/// Compara dos JSON por valor y no por bytes: el orden de las claves no forma
/// parte del protocolo, y 45 y 45.0 son el mismo número para JavaScript.
func expectSameJSON(_ produced: Data, _ expected: Data, _ comment: Comment? = nil) throws {
    let a = try JSONSerialization.jsonObject(with: produced)
    let b = try JSONSerialization.jsonObject(with: expected)
    #expect(
        NSDictionary(dictionary: a as? [String: Any] ?? [:])
            .isEqual(to: b as? [String: Any] ?? [:]),
        comment ?? "\(String(decoding: produced, as: UTF8.self)) != \(String(decoding: expected, as: UTF8.self))"
    )
}

func jsonKeys(_ data: Data) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return Set(object.keys)
}

/// Comprueba que un mensaje nuestro sigue siendo legible por la versión web:
/// todas las claves que ella conoce tienen que estar y valer lo mismo. Las
/// nuestras de más le dan igual, porque sanea con lista blanca y las descarta.
func expectCompatible(_ produced: Data, extending expected: Data, extras: Set<String>) throws {
    func state(_ data: Data) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return root["state"] as? [String: Any] ?? [:]
    }

    let ours = try state(produced)
    let theirs = try state(expected)

    for (key, value) in theirs {
        #expect(
            NSDictionary(dictionary: [key: ours[key] ?? NSNull()])
                .isEqual(to: [key: value]),
            "la clave \(key) ya no coincide con la versión web")
    }
    #expect(Set(ours.keys) == Set(theirs.keys).union(extras))
}
