import Foundation
import Network
import PrompterCore

/// A dónde nos conectamos.
public enum HostEndpoint: Sendable, Equatable, Hashable {
    /// Un anfitrión descubierto por Bonjour. Conectar por servicio y no por IP
    /// evita resolver direcciones a mano: las link-local IPv6 llevan sufijo de
    /// interfaz (`fe80::1%en0`) y montar una URL con eso es pedir problemas.
    case service(name: String, type: String, domain: String?)
    /// Dirección tecleada a mano, para redes donde el mDNS está capado.
    case address(host: String, port: UInt16)

    /// El servidor de la versión web solo acepta el upgrade en `/ws`; el
    /// anfitrión nativo acepta cualquier ruta, así que este camino sirve para
    /// los dos.
    var nwEndpoint: NWEndpoint? {
        switch self {
        case let .service(name, type, domain):
            return .service(name: name, type: type, domain: domain ?? "local.", interface: nil)
        case let .address(host, port):
            guard let url = URL(string: "ws://\(host):\(port)/ws") else { return nil }
            return .url(url)
        }
    }

    public var displayName: String {
        switch self {
        case let .service(name, _, _): name
        case let .address(host, port): "\(host):\(port)"
        }
    }

    /// Clave estable con la que recordar el emparejamiento de este anfitrión.
    public var identityKey: String {
        switch self {
        case let .service(name, type, _): "service:\(type):\(name)"
        case let .address(host, port): "address:\(host):\(port)"
        }
    }
}

public enum TransportEvent: Sendable {
    case connected
    case message(Data)
    /// La conexión se ha ido. Nil si se cerró limpiamente.
    case closed(Error?)
}

/// Lo mínimo que necesita la sesión de un socket.
///
/// Es un protocolo y no una clase concreta para poder cambiar de implementación
/// sin tocar nada más: si `NWConnection` diera algún problema de handshake
/// contra el `ws` de Node, entra aquí una versión con `URLSessionWebSocketTask`
/// y la sesión ni se entera.
@MainActor
public protocol WebSocketTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func cancel()
}

/// Implementación sobre `Network.framework`, la misma pila que usa el anfitrión.
@MainActor
public final class NWWebSocketTransport: WebSocketTransport {
    public var onEvent: ((TransportEvent) -> Void)?

    private let endpoint: HostEndpoint
    private var connection: NWConnection?
    private var finished = false

    public init(endpoint: HostEndpoint) {
        self.endpoint = endpoint
    }

    public static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        // Contestar solo a los pings del anfitrión: son su forma de saber que
        // seguimos vivos cuando el iPad se duerme o el móvil cambia de red.
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    public func start() {
        guard connection == nil, let nwEndpoint = endpoint.nwEndpoint else {
            if endpoint.nwEndpoint == nil { finish(nil) }
            return
        }

        let connection = NWConnection(to: nwEndpoint, using: Self.parameters())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onEvent?(.connected)
                    self.receiveNext()
                case let .failed(error):
                    self.finish(error)
                case .cancelled:
                    self.finish(nil)
                default:
                    break
                }
            }
        }

        // En la cola principal: los mensajes son pocos y así el arrastre del
        // mando no paga un salto de hilo por fotograma.
        connection.start(queue: .main)
    }

    public func send(_ data: Data) {
        guard let connection, !finished else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "texto", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated { self?.finish(error) }
            }
        )
    }

    public func cancel() {
        finished = true
        connection?.cancel()
        connection = nil
        onEvent = nil
    }

    private func receiveNext() {
        connection?.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }

                if let error {
                    self.finish(error)
                    return
                }

                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata

                switch metadata?.opcode {
                case .close:
                    self.finish(nil)
                    return
                case .text, .binary:
                    if let content { self.onEvent?(.message(content)) }
                default:
                    break  // ping, pong y demás los gestiona la pila.
                }

                self.receiveNext()
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        onEvent?(.closed(error))
    }
}
