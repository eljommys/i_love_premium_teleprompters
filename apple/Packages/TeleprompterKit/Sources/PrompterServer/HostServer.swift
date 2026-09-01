import Foundation
import Network
import Observation
import PrompterCore

public enum HostStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    /// No se pudo abrir el servicio. La app sigue siendo utilizable en
    /// solitario: solo deja de poder acompañarla otro aparato.
    case failed(reason: HostFailure)
}

public enum HostFailure: Equatable, Sendable {
    case noFreePort
    case localNetworkDenied
    case other(String)
}

/// Escucha en la red local y anuncia la sesión por Bonjour.
///
/// El puerto concreto da igual: viaja en el anuncio y en el QR, así que quien
/// se une nunca tiene que saberlo.
@MainActor
@Observable
public final class HostServer {
    public private(set) var status: HostStatus = .stopped
    public private(set) var port: UInt16?
    /// El nombre con el que Bonjour ha acabado anunciando la sesión.
    ///
    /// Puede no ser el pedido: si en la red ya hay un «iPad de Jommy», el
    /// sistema anuncia «iPad de Jommy (2)». Hace falta saberlo para no
    /// ofrecerle a nadie unirse a su propia sesión.
    public private(set) var advertisedName: String?

    @ObservationIgnored private let core: HostCore
    @ObservationIgnored private let serviceName: String
    @ObservationIgnored private let serviceType: String
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var socketPeers: [ObjectIdentifier: SocketPeer] = [:]
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private let firstPort: UInt16
    @ObservationIgnored private var attemptedPort: UInt16

    /// El servidor de la página para navegadores. Va aparte porque el escucha
    /// del protocolo solo habla WebSocket.
    @ObservationIgnored public private(set) var web: HTTPServer?
    /// Puerto donde se sirve la página, si está levantada.
    public var webPort: UInt16? { web?.port }

    /// Se empieza a buscar aquí para coincidir con la versión de línea de
    /// comandos; si está ocupado se prueba el siguiente.
    public static let defaultFirstPort: UInt16 = 3000
    public static let portAttempts = 50

    public init(
        core: HostCore,
        serviceName: String,
        serviceType: String = "_uprompter._tcp",
        firstPort: UInt16 = HostServer.defaultFirstPort
    ) {
        self.core = core
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.firstPort = firstPort
        self.attemptedPort = firstPort
    }

    deinit {
        heartbeat?.cancel()
    }

    // ---------------------------------------------------------- arranque

    /// Levanta también la página del navegador. Se busca sitio a partir del
    /// puerto siguiente al del protocolo, así la dirección que se enseña es la
    /// de al lado y se recuerda fácil.
    public func startWeb() {
        guard web == nil else { return }
        let base = (port ?? firstPort) &+ 1
        let server = HTTPServer(firstPort: base) { [weak self] in self?.port }
        web = server
        server.start()
    }

    public func stopWeb() {
        web?.stop()
        web = nil
    }

    public func start() {
        guard listener == nil else { return }
        status = .starting
        attemptedPort = firstPort
        listen(on: attemptedPort)
    }

    public func stop() {
        stopWeb()
        heartbeat?.cancel()
        heartbeat = nil
        for peer in socketPeers.values {
            core.detach(peer)
            peer.disconnect()
        }
        socketPeers.removeAll()
        listener?.cancel()
        listener = nil
        port = nil
        advertisedName = nil
        status = .stopped
    }

    /// Al volver del segundo plano en iOS el sistema ha cerrado el servicio.
    /// Se levanta otra vez y los aparatos que estaban unidos reconectan solos.
    public func restart() {
        stop()
        start()
    }

    private func listen(on port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed(reason: .noFreePort)
            return
        }

        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            tryNextPort(after: error)
            return
        }

        // El nombre del anuncio es el del aparato, no el de la app: en la lista
        // de sesiones lo que hay que reconocer es «el Mac del salón».
        listener.service = NWListener.Service(name: serviceName, type: serviceType)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue ?? port
                    self.status = .running(port: self.port ?? port)
                    self.startHeartbeat()
                case let .failed(error):
                    self.listener?.cancel()
                    self.listener = nil
                    self.tryNextPort(after: error)
                case let .waiting(error):
                    // Sin permiso de red local el listener espera en vez de
                    // fallar; hay que mirar el error para poder avisar.
                    if Self.isPolicyDenied(error) {
                        self.status = .failed(reason: .localNetworkDenied)
                    }
                default:
                    break
                }
            }
        }

        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                guard case let .add(endpoint) = change,
                    case let .service(name, _, _, _) = endpoint
                else { return }
                self?.advertisedName = name
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }

        listener.start(queue: .main)
    }

    private func tryNextPort(after error: Error) {
        if let nwError = error as? NWError, Self.isPolicyDenied(nwError) {
            status = .failed(reason: .localNetworkDenied)
            return
        }

        let next = attemptedPort + 1
        guard next < firstPort + UInt16(Self.portAttempts) else {
            status = .failed(reason: .noFreePort)
            return
        }
        attemptedPort = next
        listen(on: next)
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EPERM || code == .EACCES
        }
        return false
    }

    // -------------------------------------------------------- conexiones

    private func accept(_ connection: NWConnection) {
        let peer = SocketPeer(connection: connection)
        socketPeers[ObjectIdentifier(peer)] = peer

        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.core.receive(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.socketPeers.removeValue(forKey: ObjectIdentifier(peer))
            self.core.detach(peer)
        }

        core.attach(peer)
        peer.start()
    }

    /// Se manda un ping a cada aparato y, si no ha contestado para la ronda
    /// siguiente, se le desconecta.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Timing.heartbeatInterval))
                guard !Task.isCancelled else { return }
                self?.sweep()
            }
        }
    }

    private func sweep() {
        for peer in socketPeers.values {
            guard peer.isAlive else {
                peer.disconnect()
                continue
            }
            peer.isAlive = false
            peer.ping()
        }
    }
}
