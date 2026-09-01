import Foundation
import PrompterCore

/// Guarda el guion y los ajustes en disco.
///
/// Un fichero JSON y no una base de datos: es un único bloque de datos, se
/// puede leer con cualquier editor cuando algo va mal, y tiene exactamente la
/// misma forma que el `state.json` de la versión de línea de comandos, así que
/// se puede copiar de una a otra.
public struct StatePersistence: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Carpeta de la aplicación. Se crea si no existe.
    public static func applicationSupport(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "teleprompter"
    ) -> StatePersistence {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        let folder = base.appending(path: bundleIdentifier, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return StatePersistence(url: folder.appending(path: "state.json"))
    }

    public func load() -> TeleprompterState {
        guard let data = try? Data(contentsOf: url) else {
            return TeleprompterState()  // Primer arranque: valen los defectos.
        }

        guard let patch = try? JSONDecoder().decode(TeleprompterPatch.self, from: data) else {
            // Un fichero ilegible se aparta en vez de sobrescribirse a la
            // primera: dentro puede estar el único guion que había.
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return TeleprompterState()
        }

        return TeleprompterState().applying(patch.sanitized() ?? TeleprompterPatch())
    }

    /// Escritura atómica: un corte a media escritura deja intacto el guion
    /// anterior en vez de un fichero a medias.
    public func save(_ state: TeleprompterState) {
        guard let data = try? JSONEncoder().encode(state.persistablePatch) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Igual, pero fuera del hilo principal: un guion largo no debe hacer
    /// tropezar al bucle de fotogramas del visor.
    public func saveInBackground(_ state: TeleprompterState) {
        let snapshot = state
        let persistence = self
        Task.detached(priority: .utility) {
            persistence.save(snapshot)
        }
    }
}
