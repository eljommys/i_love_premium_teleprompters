import Foundation
import Network
import PrompterCore

/// Un aparato conectado por la red.
@MainActor
final class SocketPeer: HostPeer {
    var role: Role = .home
    var isAuthenticated = false
    let remoteIdentifier: String
    /// Ha dado señales de vida desde el último latido.
    var isAlive = true

    private let connection: NWConnection
    private var closed = false
    /// Se ha pedido cerrar y solo falta que salga lo que había encolado.
    private var closing = false
    var onMessage: ((ClientMessage) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
        // La dirección, sin el puerto de origen: así los intentos fallidos de
        // código se cuentan por aparato y no por conexión, que cambia cada vez
        // que reconecta.
        self.remoteIdentifier = Self.identifier(for: connection.endpoint)
    }

    private static func identifier(for endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return String(describing: host)
        }
        return String(describing: endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveNext()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: ServerMessage) {
        guard !closed, !closing, let data = try? Wire.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "texto", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                MainActor.assumeIsolated { self?.finish() }
            }
        )
    }

    /// Cierra, pero después de que salga lo ya encolado.
    ///
    /// Cortar el socket a secas se comía el mensaje de rechazo: quien metía mal
    /// el código no veía «código incorrecto» sino una conexión caída, y su
    /// aparato se ponía a reconectar en bucle con el mismo código malo.
    /// Network entrega en orden, así que un cierre encolado detrás del mensaje
    /// garantiza que el mensaje llega primero.
    func disconnect() {
        guard !closed, !closing else { return }
        closing = true

        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(
            identifier: "cierre", isFinal: true, metadata: [metadata])
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        )
    }

    /// Le manda un ping y apunta si contesta. Un aparato que desaparece sin
    /// cerrar el socket —el iPad se duerme, el móvil se va de la Wi-Fi— dejaría
    /// su conexión colgada para siempre y el recuento mentiría.
    func ping() {
        guard !closed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAlive = true }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(
            content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }

                if error != nil {
                    self.finish()
                    return
                }

                self.isAlive = true

                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata

                switch metadata?.opcode {
                case .close:
                    self.finish()
                    return
                case .text, .binary:
                    if let content, let message = Wire.decodeClientMessage(content) {
                        self.onMessage?(message)
                    }
                default:
                    break
                }

                self.receiveNext()
            }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onMessage = nil
        onClose?()
        onClose = nil
    }
}
