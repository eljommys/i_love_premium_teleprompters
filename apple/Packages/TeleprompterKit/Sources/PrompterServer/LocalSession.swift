import Foundation
import Observation
import PrompterCore

/// La sesión de este mismo aparato, cuando es él quien la aloja.
///
/// No duplica nada del núcleo: lee de él y escribe en él. Pasar por el núcleo y
/// no por un atajo es lo que hace que la interfaz del anfitrión se comporte
/// exactamente igual que la de un iPad conectado por Wi-Fi, saneado y recuentos
/// incluidos.
@MainActor
@Observable
public final class LocalSession: TeleprompterSession {

    public var state: TeleprompterState { core.state }
    public var clients: ClientCounts { core.clients }
    /// Alojar la sesión no es algo que se pueda perder: no hay red de por medio.
    public var connection: ConnectionStatus { .online }
    public var isRemoteHost: Bool { false }
    public var hostIdentity: SessionIdentity? { nil }
    public var livePosition: Double { core.livePosition }

    @ObservationIgnored public var onIncomingPosition: ((Double) -> Void)?

    @ObservationIgnored public let core: HostCore
    @ObservationIgnored private let peer: LocalPeer

    public init(core: HostCore, role: Role = .home) {
        self.core = core
        self.peer = LocalPeer(role: role)

        peer.onMessage = { [weak self] message in
            self?.receive(message)
        }
        core.attach(peer)
    }

    deinit {
        MainActor.assumeIsolated { core.detach(peer) }
    }

    private func receive(_ message: ServerMessage) {
        // Solo interesa la posición: el resto del estado ya se lee del núcleo,
        // que es el mismo objeto.
        switch message {
        case let .state(state, _):
            onIncomingPosition?(state.position)
        case let .patch(patch):
            if let position = patch.position { onIncomingPosition?(position) }
        default:
            break
        }
    }

    public func setRole(_ role: Role) {
        guard role != peer.role else { return }
        core.receive(.hello(role: role, code: nil), from: peer)
    }

    public func update(_ patch: TeleprompterPatch) {
        core.apply(patch, from: peer)
    }
}
