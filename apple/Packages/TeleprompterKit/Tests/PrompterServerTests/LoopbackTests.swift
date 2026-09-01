import Foundation
import Testing

@testable import PrompterClient
@testable import PrompterCore
@testable import PrompterServer

/// Anfitrión de verdad, con su `NWListener`, y clientes de verdad conectándose
/// por un socket. Es lo que comprueba que las dos mitades encajan: el peer que
/// va por dentro y el que viene de la red tienen que ver lo mismo.
@MainActor
@Suite("Anfitrión y clientes de verdad", .serialized)
struct LoopbackTests {

    private func wait(
        timeout: Duration = .seconds(8),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Levanta un anfitrión y espera a que esté escuchando.
    private func startHost(code: String? = nil) async throws -> (HostCore, HostServer, UInt16) {
        let core = HostCore(pairingCode: code)
        let server = HostServer(core: core, serviceName: "Pruebas \(UUID().uuidString.prefix(4))")
        server.start()
        #expect(await wait { server.port != nil }, "el anfitrión no llegó a escuchar")
        let port = try #require(server.port)
        return (core, server, port)
    }

    @Test("un cliente de la red se conecta y sincroniza en los dos sentidos")
    func realClientSyncs() async throws {
        let (core, server, port) = try await startHost()
        defer { server.stop() }

        let anfitrion = LocalSession(core: core, role: .editor)
        let cliente = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .prompter)
        defer { cliente.stop() }
        cliente.start()

        #expect(await wait { cliente.connection == .online }, "no conectó")

        // El anfitrión escribe y el cliente lo ve.
        anfitrion.update(TeleprompterPatch(text: "guion de prueba", speed: 66))
        #expect(await wait { cliente.state.text == "guion de prueba" })
        #expect(cliente.state.speed == 66)

        // Y al revés: el cliente mide y el anfitrión lo adopta.
        cliente.update(TeleprompterPatch(docHeight: 8400))
        #expect(await wait { anfitrion.state.docHeight == 8400 })

        // Los recuentos ven a los dos, cada uno con su papel.
        #expect(await wait { core.clients == ClientCounts(editor: 1, prompter: 1) })
        #expect(await wait { cliente.clients.editor == 1 && cliente.clients.prompter == 1 })
        #expect(core.remotePeerCount == 1)
    }

    @Test("el peer local y el de la red reciben exactamente el mismo flujo")
    func localAndSocketPeersAgree() async throws {
        let (core, server, port) = try await startHost()
        defer { server.stop() }

        let anfitrion = LocalSession(core: core, role: .prompter)
        var posicionesLocales: [Double] = []
        anfitrion.onIncomingPosition = { posicionesLocales.append($0) }

        let mando = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .remote)
        defer { mando.stop() }
        mando.start()
        #expect(await wait { mando.connection == .online })

        // Un tercero mira desde la red lo mismo que mira el anfitrión.
        let testigo = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .editor)
        defer { testigo.stop() }
        var posicionesRemotas: [Double] = []
        testigo.onIncomingPosition = { posicionesRemotas.append($0) }
        testigo.start()
        #expect(await wait { testigo.connection == .online })

        mando.update(TeleprompterPatch(playing: true, position: 0.25))

        #expect(await wait { posicionesLocales.contains(0.25) }, "no llegó al anfitrión")
        #expect(await wait { posicionesRemotas.contains(0.25) }, "no llegó al testigo")
        #expect(anfitrion.state.playing)
        #expect(await wait { testigo.state.playing })
    }

    @Test("con emparejamiento, el código correcto entra y el equivocado no")
    func pairingOverTheWire() async throws {
        let (_, server, port) = try await startHost(code: "4821")
        defer { server.stop() }

        let intruso = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .remote, code: "0000")
        defer { intruso.stop() }
        intruso.start()
        #expect(await wait { intruso.rejection == .badCode }, "debería haberle echado")
        #expect(intruso.state.text.isEmpty, "no debería haber visto el guion")

        let invitado = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .prompter, code: "4821")
        defer { invitado.stop() }
        invitado.start()
        #expect(await wait { invitado.connection == .online })
        #expect(await wait { invitado.clients.prompter == 1 }, "no llegó a entrar")
        #expect(invitado.rejection == nil)
    }

    @Test("cuando se cae el anfitrión, el cliente reconecta solo")
    func clientReconnectsAfterHostRestart() async throws {
        let (core, server, port) = try await startHost()
        defer { server.stop() }
        core.apply(TeleprompterPatch(text: "sigue aquí"), from: nil)

        let cliente = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .prompter)
        defer { cliente.stop() }
        var reconexiones = 0
        cliente.onReconnect = { reconexiones += 1 }
        cliente.start()
        #expect(await wait { cliente.state.text == "sigue aquí" })

        // Se corta el servicio y se vuelve a levantar, como al volver del
        // segundo plano en iOS.
        server.stop()
        #expect(await wait { cliente.connection == .offline })
        server.start()
        #expect(await wait { server.port != nil })

        #expect(await wait { cliente.connection == .online }, "no reconectó")
        #expect(reconexiones >= 1, "debería avisar para que el visor se reafirme")
    }

    @Test("dos anfitriones a la vez no se pelean por el puerto")
    func portScanFindsAFreePort() async throws {
        let (_, primero, puertoA) = try await startHost()
        defer { primero.stop() }
        let (_, segundo, puertoB) = try await startHost()
        defer { segundo.stop() }

        #expect(puertoA != puertoB)
        #expect(puertoA >= HostServer.defaultFirstPort)
        #expect(puertoB >= HostServer.defaultFirstPort)
    }

    @Test("al parar el anfitrión se sueltan todos los aparatos")
    func stoppingReleasesPeers() async throws {
        let (core, server, port) = try await startHost()

        let cliente = RemoteSession(
            endpoint: .address(host: "127.0.0.1", port: port), role: .remote)
        defer { cliente.stop() }
        cliente.start()
        #expect(await wait { core.remotePeerCount == 1 })

        server.stop()
        #expect(core.remotePeerCount == 0)
        #expect(server.status == .stopped)
    }
}
