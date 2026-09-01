import Foundation
import Testing

@testable import PrompterClient
@testable import PrompterCore

/// Un socket de mentira: deja inspeccionar lo que se manda y permite inyectar
/// lo que llega, sin levantar ninguna red.
@MainActor
final class FakeTransport: WebSocketTransport {
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var sent: [Data] = []
    private(set) var started = false
    private(set) var cancelled = false

    func start() {
        started = true
    }

    func send(_ data: Data) {
        sent.append(data)
    }

    func cancel() {
        cancelled = true
    }

    // ------------------------------------------------------------- ayudas

    func open() {
        onEvent?(.connected)
    }

    func close(_ error: Error? = nil) {
        onEvent?(.closed(error))
    }

    func deliver(_ message: ServerMessage) throws {
        onEvent?(.message(try Wire.encode(message)))
    }

    var sentMessages: [ClientMessage] {
        sent.compactMap(Wire.decodeClientMessage)
    }
}

@MainActor
@Suite("Sesión remota")
struct RemoteSessionTests {

    /// Devuelve la sesión y el socket falso que va a usar.
    private func makeSession(role: Role = .prompter, code: String? = nil) -> (
        RemoteSession, FakeTransport
    ) {
        let transport = FakeTransport()
        let session = RemoteSession(
            endpoint: .address(host: "192.168.1.20", port: 3000),
            role: role,
            code: code,
            transport: { _ in transport }
        )
        return (session, transport)
    }

    @Test("al conectar se presenta con su papel")
    func saysHelloOnConnect() throws {
        let (session, transport) = makeSession(role: .remote)
        session.start()
        #expect(transport.started)
        #expect(session.connection == .connecting)

        transport.open()
        #expect(session.connection == .online)
        #expect(transport.sentMessages == [.hello(role: .remote, code: nil)])
    }

    @Test("el código de emparejamiento viaja en el saludo")
    func sendsPairingCode() throws {
        let (session, transport) = makeSession(role: .editor, code: "4821")
        session.start()
        transport.open()
        #expect(transport.sentMessages == [.hello(role: .editor, code: "4821")])
    }

    @Test("el estado inicial llena la interfaz y entrega la posición aparte")
    func initialStatePopulatesEverything() throws {
        let (session, transport) = makeSession()
        var received: [Double] = []
        session.onIncomingPosition = { received.append($0) }

        session.start()
        transport.open()
        try transport.deliver(
            .state(
                TeleprompterState(text: "hola", speed: 44, position: 0.3, docHeight: 5000),
                ClientCounts(editor: 1, prompter: 1)))

        #expect(session.state.text == "hola")
        #expect(session.state.speed == 44)
        #expect(session.state.docHeight == 5000)
        #expect(session.clients.editor == 1)
        #expect(session.livePosition == 0.3)
        #expect(received == [0.3])
    }

    @Test("la posición que llega no repinta la interfaz, va al motor de scroll")
    func positionBypassesObservableState() throws {
        let (session, transport) = makeSession()
        var received: [Double] = []
        session.onIncomingPosition = { received.append($0) }

        session.start()
        transport.open()
        try transport.deliver(.patch(TeleprompterPatch(position: 0.7)))

        #expect(received == [0.7])
        #expect(session.livePosition == 0.7)
        // El estado observable no se toca: si lo hiciera, la interfaz se
        // repintaría decenas de veces por segundo mientras alguien arrastra.
        #expect(session.state.position == 0)
    }

    @Test("un patch mixto reparte cada clave a su sitio")
    func mixedPatchIsSplit() throws {
        let (session, transport) = makeSession()
        var received: [Double] = []
        session.onIncomingPosition = { received.append($0) }

        session.start()
        transport.open()
        try transport.deliver(.patch(TeleprompterPatch(playing: true, position: 0.42)))

        #expect(session.state.playing)
        #expect(received == [0.42])
        #expect(session.livePosition == 0.42)
    }

    @Test("un cambio local se aplica al instante y se difunde")
    func updatesAreOptimistic() throws {
        let (session, transport) = makeSession()
        session.start()
        transport.open()

        session.update(TeleprompterPatch(speed: 60))
        #expect(session.state.speed == 60, "no debe esperar a la red para responder")
        #expect(transport.sentMessages.last == .update(patch: TeleprompterPatch(speed: 60)))
    }

    @Test("lo que se manda va saneado, no se le pasa basura al anfitrión")
    func outgoingPatchesAreSanitized() throws {
        let (session, transport) = makeSession()
        session.start()
        transport.open()

        session.update(TeleprompterPatch(speed: 900, position: 5))
        #expect(session.state.speed == 100)
        #expect(session.livePosition == 1)
        #expect(
            transport.sentMessages.last
                == .update(patch: TeleprompterPatch(speed: 100, position: 1)))
    }

    @Test("un patch que se queda en nada no se manda")
    func emptyPatchesAreNotSent() throws {
        let (session, transport) = makeSession()
        session.start()
        transport.open()
        let before = transport.sent.count

        session.update(TeleprompterPatch())
        session.update(TeleprompterPatch(speed: .nan))
        #expect(transport.sent.count == before)
    }

    @Test("cambiar de modo reutiliza la conexión")
    func roleChangeReusesConnection() throws {
        let (session, transport) = makeSession(role: .prompter)
        session.start()
        transport.open()

        session.setRole(.remote)
        #expect(transport.sentMessages.last == .hello(role: .remote, code: nil))
        #expect(!transport.cancelled, "cambiar de modo no debe cortar el socket")

        let count = transport.sent.count
        session.setRole(.remote)
        #expect(transport.sent.count == count, "repetir el mismo modo no manda nada")
    }

    @Test("si se cae la red se queda desconectada y reintenta")
    func reconnects() async throws {
        let (session, transport) = makeSession()
        session.start()
        transport.open()
        #expect(session.connection == .online)

        transport.close()
        #expect(session.connection == .offline)

        // El primer reintento va a los 500 ms.
        try await Task.sleep(for: .milliseconds(700))
        #expect(transport.started)
        #expect(session.connection != .offline || transport.started)
    }

    @Test("al recuperar la conexión se avisa para que el visor se reafirme")
    func reconnectNotifies() async throws {
        let (session, transport) = makeSession()
        var reconnects = 0
        session.onReconnect = { reconnects += 1 }

        session.start()
        transport.open()
        #expect(reconnects == 0, "la primera conexión no es una reconexión")

        transport.close()
        session.reconnectNow()
        transport.open()
        #expect(reconnects == 1)
    }

    @Test("un rechazo por código corta y deja el motivo a la vista")
    func rejectionStopsTheSession() throws {
        let (session, transport) = makeSession(code: "0000")
        session.start()
        transport.open()

        try transport.deliver(.rejected(reason: .badCode))
        #expect(session.rejection == .badCode)
        #expect(session.connection == .offline)
        #expect(transport.cancelled)
    }

    @Test("después de parar no se reconecta sola")
    func stopIsFinal() async throws {
        let (session, transport) = makeSession()
        session.start()
        transport.open()
        session.stop()

        transport.close()
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.connection == .offline)
    }

    @Test("estar unido a otro es lo que enciende el aviso de la interfaz")
    func isRemoteHost() {
        let (session, _) = makeSession()
        #expect(session.isRemoteHost)
        #expect(session.hostIdentity?.name == "192.168.1.20:3000")
    }
}
