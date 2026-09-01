import Foundation
import PrompterCore
import PrompterServer

/// Anfitrión sin interfaz, para poder someterlo al mismo guion de pruebas que
/// al servidor de la versión web. No forma parte de la aplicación: es la mitad
/// que le falta a `Tools/interop/exercise-host.mjs` para poder comprobar que
/// las dos implementaciones se comportan igual.
///
///     swift run prompter-host --port 3500 [--code 4821] [--web]
@MainActor
func run() async throws {
    var port: UInt16 = 3500
    var code: String?
    var web = false
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--port": port = arguments.next().flatMap(UInt16.init) ?? port
        case "--code": code = arguments.next()
        case "--web": web = true
        default: break
        }
    }

    // Sin persistencia: cada arranque empieza limpio, que es lo que quiere una
    // prueba.
    let core = HostCore(pairingCode: code)
    let server = HostServer(
        core: core, serviceName: "prompter-host", firstPort: port)
    server.start()

    while true {
        try await Task.sleep(for: .milliseconds(100))
        if case let .running(puerto) = server.status {
            print("escuchando en \(puerto)")
            if web {
                server.startWeb()
                while server.web?.port == nil { try await Task.sleep(for: .milliseconds(50)) }
                print("página en http://localhost:\(server.web?.port ?? 0)")
            }
            break
        }
        if case let .failed(reason) = server.status {
            FileHandle.standardError.write(Data("no se pudo arrancar: \(reason)\n".utf8))
            exit(1)
        }
    }

    while true {
        try await Task.sleep(for: .seconds(60))
    }
}

try await run()
