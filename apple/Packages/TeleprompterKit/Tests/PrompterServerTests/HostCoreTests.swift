import Foundation
import Testing

@testable import PrompterCore
@testable import PrompterServer

/// Un aparato de mentira que apunta todo lo que le mandan.
@MainActor
final class SpyPeer: HostPeer {
    var role: Role
    var isAuthenticated = false
    let remoteIdentifier: String
    private(set) var received: [ServerMessage] = []
    private(set) var disconnected = false

    init(role: Role = .home, identifier: String = UUID().uuidString) {
        self.role = role
        self.remoteIdentifier = identifier
    }

    func send(_ message: ServerMessage) {
        received.append(message)
    }

    func disconnect() {
        disconnected = true
    }

    var patches: [TeleprompterPatch] {
        received.compactMap { if case let .patch(patch) = $0 { patch } else { nil } }
    }

    var lastCounts: ClientCounts? {
        received.reversed().compactMap {
            switch $0 {
            case let .clients(counts): counts
            case let .state(_, counts): counts
            default: nil
            }
        }.first
    }
}

@MainActor
@Suite("Núcleo del anfitrión")
struct HostCoreTests {

    @Test("quien se conecta recibe el estado completo")
    func newPeerGetsState() {
        let core = HostCore()
        let peer = SpyPeer()
        core.attach(peer)

        guard case let .state(state, _)? = peer.received.first else {
            Issue.record("no recibió el estado inicial")
            return
        }
        #expect(state.speed == TeleprompterState.initial.speed)
        #expect(peer.isAuthenticated)
    }

    @Test("un cambio llega a todos menos a quien lo hizo")
    func broadcastExcludesSender() {
        let core = HostCore()
        let emisor = SpyPeer(role: .remote)
        let visor = SpyPeer(role: .prompter)
        let editor = SpyPeer(role: .editor)
        [emisor, visor, editor].forEach(core.attach)

        core.receive(.update(patch: TeleprompterPatch(speed: 70)), from: emisor)

        #expect(emisor.patches.isEmpty, "devolvérselo al emisor provoca saltos")
        #expect(visor.patches == [TeleprompterPatch(speed: 70)])
        #expect(editor.patches == [TeleprompterPatch(speed: 70)])
        #expect(core.state.speed == 70)
    }

    @Test("lo que llega se sanea antes de repartirlo")
    func incomingPatchesAreSanitized() {
        let core = HostCore()
        let emisor = SpyPeer()
        let testigo = SpyPeer()
        core.attach(emisor)
        core.attach(testigo)

        core.receive(.update(patch: TeleprompterPatch(speed: 5000, margin: -9)), from: emisor)

        #expect(core.state.speed == Limits.speed.max)
        #expect(core.state.margin == Limits.margin.min)
        #expect(testigo.patches == [TeleprompterPatch(speed: 100, margin: 0)])
    }

    @Test("un patch que se queda en nada no se reparte")
    func emptyPatchesAreIgnored() {
        let core = HostCore()
        let emisor = SpyPeer()
        let testigo = SpyPeer()
        core.attach(emisor)
        core.attach(testigo)
        let antes = testigo.received.count

        core.receive(.update(patch: TeleprompterPatch()), from: emisor)
        core.receive(.update(patch: TeleprompterPatch(speed: .nan)), from: emisor)

        #expect(testigo.received.count == antes)
    }

    @Test("la posición va aparte para no repintar la interfaz")
    func positionStaysOutOfObservableState() {
        let core = HostCore()
        let emisor = SpyPeer()
        core.attach(emisor)

        core.apply(TeleprompterPatch(position: 0.66), from: emisor)

        #expect(core.livePosition == 0.66)
        #expect(core.state.position == 0, "el estado observable no debe moverse con la posición")
        #expect(core.snapshot.position == 0.66, "pero el estado completo sí la lleva")
    }

    @Test("los recuentos siguen a los papeles y llegan a todos")
    func clientCounts() {
        let core = HostCore()
        let visor = SpyPeer()
        let mando = SpyPeer()
        core.attach(visor)
        core.attach(mando)

        core.receive(.hello(role: .prompter, code: nil), from: visor)
        core.receive(.hello(role: .remote, code: nil), from: mando)

        #expect(core.clients == ClientCounts(prompter: 1, remote: 1))
        #expect(visor.lastCounts == ClientCounts(prompter: 1, remote: 1))

        core.detach(mando)
        #expect(core.clients == ClientCounts(prompter: 1))
    }

    @Test("cambiar de papel no reconecta a nadie")
    func roleChangeUpdatesCounts() {
        let core = HostCore()
        let peer = SpyPeer()
        core.attach(peer)

        core.receive(.hello(role: .editor, code: nil), from: peer)
        #expect(core.clients == ClientCounts(editor: 1))

        core.receive(.hello(role: .prompter, code: nil), from: peer)
        #expect(core.clients == ClientCounts(prompter: 1))
        #expect(!peer.disconnected)
    }

    @Test("un mensaje desconocido no tumba la conexión")
    func unknownMessagesAreIgnored() {
        let core = HostCore()
        let peer = SpyPeer()
        core.attach(peer)
        core.receive(.unknown(type: "vete-a-saber"), from: peer)
        #expect(!peer.disconnected)
    }

    // ---------------------------------------------------- emparejamiento

    @Test("con código, el guion no se enseña hasta que se acierta")
    func pairingWithholdsStateUntilAccepted() {
        let core = HostCore(pairingCode: "4821")
        let peer = SpyPeer()
        core.attach(peer)

        #expect(peer.received.isEmpty, "sin entrar no se ve nada")
        #expect(!peer.isAuthenticated)

        core.receive(.hello(role: .prompter, code: "4821"), from: peer)
        #expect(peer.isAuthenticated)
        guard case .state = peer.received.first else {
            Issue.record("tras acertar debería llegar el estado")
            return
        }
        #expect(core.clients == ClientCounts(prompter: 1))
    }

    @Test("un código equivocado echa al aparato")
    func wrongCodeIsRejected() {
        let core = HostCore(pairingCode: "4821")
        let peer = SpyPeer()
        core.attach(peer)

        core.receive(.hello(role: .prompter, code: "0000"), from: peer)

        #expect(peer.received == [.rejected(reason: .badCode)])
        #expect(peer.disconnected)
        #expect(!peer.isAuthenticated)
        #expect(core.clients.total == 0)
    }

    @Test("sin código tampoco se entra")
    func missingCodeIsRejected() {
        let core = HostCore(pairingCode: "4821")
        let peer = SpyPeer()
        core.attach(peer)
        core.receive(.hello(role: .prompter, code: nil), from: peer)
        #expect(peer.received == [.rejected(reason: .badCode)])
    }

    @Test("un aparato que no ha entrado no puede tocar el guion")
    func unauthenticatedPeersCannotWrite() {
        let core = HostCore(pairingCode: "4821")
        let intruso = SpyPeer()
        core.attach(intruso)

        core.receive(.update(patch: TeleprompterPatch(text: "he entrado")), from: intruso)
        #expect(core.state.text == "")
    }

    @Test("tras varios fallos desde el mismo sitio se corta en seco")
    func pairingAttemptsAreRateLimited() {
        let core = HostCore(pairingCode: "4821")

        // Cada reconexión trae un objeto nuevo, así que los intentos se cuentan
        // por origen y no por conexión.
        for _ in 0..<HostCore.maxPairingAttempts {
            let peer = SpyPeer(identifier: "192.168.1.55")
            core.attach(peer)
            core.receive(.hello(role: .remote, code: "0000"), from: peer)
            core.detach(peer)
        }

        let siguiente = SpyPeer(identifier: "192.168.1.55")
        core.attach(siguiente)
        core.receive(.hello(role: .remote, code: "0000"), from: siguiente)
        #expect(siguiente.received == [.rejected(reason: .tooManyAttempts)])

        // Y otro aparato distinto no paga por los pecados del primero.
        let otro = SpyPeer(identifier: "192.168.1.99")
        core.attach(otro)
        core.receive(.hello(role: .remote, code: "4821"), from: otro)
        #expect(otro.isAuthenticated)
    }

    @Test("acertar borra los fallos anteriores")
    func successfulPairingClearsAttempts() {
        let core = HostCore(pairingCode: "4821")
        let peer = SpyPeer(identifier: "192.168.1.55")
        core.attach(peer)
        core.receive(.hello(role: .remote, code: "0000"), from: peer)

        let reintento = SpyPeer(identifier: "192.168.1.55")
        core.attach(reintento)
        core.receive(.hello(role: .remote, code: "4821"), from: reintento)
        #expect(reintento.isAuthenticated)

        // Cinco fallos más deben volver a caber: el contador se puso a cero.
        for _ in 0..<(HostCore.maxPairingAttempts - 1) {
            let fallo = SpyPeer(identifier: "192.168.1.55")
            core.attach(fallo)
            core.receive(.hello(role: .remote, code: "1111"), from: fallo)
        }
        let ultimo = SpyPeer(identifier: "192.168.1.55")
        core.attach(ultimo)
        core.receive(.hello(role: .remote, code: "1111"), from: ultimo)
        #expect(ultimo.received == [.rejected(reason: .badCode)])
    }

    @Test("un código generado tiene cuatro cifras")
    func generatedCodes() {
        for _ in 0..<50 {
            let code = PairingCode.generate()
            #expect(code.count == 4)
            #expect(PairingCode.isValid(code))
        }
        #expect(!PairingCode.isValid("12a4"))
        #expect(!PairingCode.isValid("123"))
    }

    @Test("con código, el mando de otro aparato sigue moviendo al anfitrión")
    func pairingDoesNotLockOutTheHostItself() {
        // El fallo que esto vigila: al encender el emparejamiento, la interfaz
        // del propio anfitrión se adjuntaba como no autenticada y quedaba fuera
        // del reparto. El resultado era que el anfitrión mandaba sobre los
        // demás pero nadie mandaba sobre él: con el Mac de anfitrión y visor,
        // el mando del iPhone no lo movía.
        let core = HostCore(pairingCode: "2307")

        let local = LocalPeer(role: .prompter)
        var delivered: [TeleprompterPatch] = []
        local.onMessage = { message in
            if case let .patch(patch) = message { delivered.append(patch) }
        }
        core.attach(local)
        #expect(local.isAuthenticated, "el anfitrión no tiene que emparejarse consigo mismo")

        let phone = SpyPeer(role: .remote)
        core.attach(phone)
        #expect(!phone.isAuthenticated)
        core.receive(.hello(role: .remote, code: "2307"), from: phone)
        #expect(phone.isAuthenticated)

        core.receive(.update(patch: TeleprompterPatch(playing: true, position: 0.42)), from: phone)

        #expect(delivered.count == 1)
        #expect(delivered.first?.playing == true)
        #expect(delivered.first?.position == 0.42)
        #expect(core.state.playing)
        #expect(core.livePosition == 0.42)
    }

    @Test("el anfitrión se cuenta a sí mismo entre los aparatos")
    func hostCountsItself() {
        let core = HostCore(pairingCode: "2307")
        core.attach(LocalPeer(role: .prompter))
        #expect(core.clients[.prompter] == 1)
    }
}
