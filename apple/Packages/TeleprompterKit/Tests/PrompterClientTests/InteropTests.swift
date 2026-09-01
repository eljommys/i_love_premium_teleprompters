import Foundation
import Testing

@testable import PrompterClient
@testable import PrompterCore

/// Fuera de la suite y sin aislar: las condiciones de `@Test` se evalúan antes
/// de entrar en el actor principal.
enum Interop {
    static var endpoint: HostEndpoint? {
        guard let raw = ProcessInfo.processInfo.environment["TELEPROMPTER_INTEROP"] else {
            return nil
        }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return .address(host: String(parts[0]), port: port)
    }

    static let reason: Comment = "define TELEPROMPTER_INTEROP=host:puerto"
}

/// Prueba contra el servidor de verdad, el de la versión web, que hace de
/// anfitrión de referencia. No se ejecuta sola: hay que levantar el servidor y
/// apuntar a él.
///
///     cd /Users/jommys/GitHub/teleprompter && npm start
///     TELEPROMPTER_INTEROP=127.0.0.1:3000 swift test --filter Interop
///
/// Es la prueba que valida la decisión de usar `NWConnection`: si el handshake
/// no encajara con el `ws` de Node, se vería aquí y no en producción.
@MainActor
@Suite("Interoperabilidad con el servidor web")
struct InteropTests {

    /// Espera a que se cumpla una condición sin dormir de más.
    private func wait(
        timeout: Duration = .seconds(5),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test(
        "un cliente nativo se conecta, recibe el estado y sincroniza en los dos sentidos",
        .enabled(if: Interop.endpoint != nil, Interop.reason)
    )
    func talksToTheNodeServer() async throws {
        let endpoint = try #require(Interop.endpoint)

        // Dos clientes a la vez: uno hace de visor y otro de mando, igual que
        // en una sesión real.
        let viewer = RemoteSession(endpoint: endpoint, role: .prompter)
        let remote = RemoteSession(endpoint: endpoint, role: .remote)
        defer {
            viewer.stop()
            remote.stop()
        }

        viewer.start()
        remote.start()

        #expect(
            await wait { viewer.connection == .online && remote.connection == .online },
            "no se pudo conectar con el servidor web")

        // El servidor manda el estado completo nada más conectar.
        #expect(await wait { viewer.state.speed > 0 }, "no llegó el estado inicial")

        // Y cuenta los aparatos por papel.
        #expect(
            await wait { viewer.clients.prompter >= 1 && viewer.clients.remote >= 1 },
            "los recuentos no reflejan los dos clientes: \(viewer.clients)")

        // Un cambio del mando llega al visor, pero NO vuelve a quien lo mandó.
        let nuevaVelocidad = viewer.state.speed == 55.0 ? 66.0 : 55.0
        remote.update(TeleprompterPatch(speed: nuevaVelocidad))
        #expect(
            await wait { viewer.state.speed == nuevaVelocidad },
            "el cambio del mando no llegó al visor")

        // El visor es quien mide: publica su recorrido y el mando lo adopta.
        viewer.update(TeleprompterPatch(docHeight: 12480))
        #expect(await wait { remote.state.docHeight == 12480 }, "el recorrido no llegó al mando")

        // Las posiciones viajan por su camino y no repintan la interfaz.
        var recibidas: [Double] = []
        viewer.onIncomingPosition = { recibidas.append($0) }
        remote.update(TeleprompterPatch(position: 0.375))
        #expect(await wait { recibidas.contains(0.375) }, "la posición no llegó al visor")
    }

    @Test(
        "el servidor web acota los valores fuera de rango",
        .enabled(if: Interop.endpoint != nil, Interop.reason)
    )
    func serverClampsOutOfRangeValues() async throws {
        let endpoint = try #require(Interop.endpoint)
        let testigo = RemoteSession(endpoint: endpoint, role: .editor)
        let emisor = RemoteSession(endpoint: endpoint, role: .remote)
        defer {
            testigo.stop()
            emisor.stop()
        }
        testigo.start()
        emisor.start()
        #expect(await wait { testigo.connection == .online && emisor.connection == .online })

        // El cliente ya lo acota antes de mandarlo; esto comprueba que las dos
        // implementaciones acotan igual y el testigo ve el mismo número.
        emisor.update(TeleprompterPatch(fontSize: 999))
        #expect(
            await wait { testigo.state.fontSize == Limits.fontSize.max },
            "el tope de cuerpo de letra no coincide: \(testigo.state.fontSize)")
    }

    @Test(
        "el saludo con código de emparejamiento no molesta al servidor web",
        .enabled(if: Interop.endpoint != nil, Interop.reason)
    )
    func pairingCodeIsIgnoredByTheWebServer() async throws {
        let endpoint = try #require(Interop.endpoint)
        // La clave `code` es de más para el servidor web, que solo lee `role`.
        // Si la rechazara, un aparato nativo no podría unirse a una sesión web.
        let session = RemoteSession(endpoint: endpoint, role: .prompter, code: "4821")
        defer { session.stop() }
        session.start()

        #expect(await wait { session.connection == .online })
        #expect(await wait { session.state.speed > 0 }, "el servidor no respondió al saludo")
        #expect(session.rejection == nil)
    }
}
