import Foundation
import Observation
import PrompterCore

/// La sesión de otro aparato, vista desde este. Mantiene el estado compartido
/// sincronizado y reconecta sola si se cae la red.
///
/// `update` aplica el cambio aquí al instante y luego lo difunde: la interfaz
/// nunca espera a la red para responder a un dedo.
@MainActor
@Observable
public final class RemoteSession: TeleprompterSession {

    // Valores que mueven la interfaz. La posición NO está aquí: cambia en cada
    // fotograma y repintar la interfaz a esa frecuencia no tiene ningún sentido.
    public private(set) var state = TeleprompterState()
    public private(set) var connection: ConnectionStatus = .connecting
    public private(set) var clients = ClientCounts()
    public private(set) var hostIdentity: SessionIdentity?
    /// Por qué nos ha echado el anfitrión, si nos ha echado.
    public private(set) var rejection: RejectionReason?

    public var isRemoteHost: Bool { true }

    @ObservationIgnored public private(set) var livePosition: Double = 0
    @ObservationIgnored public var onIncomingPosition: ((Double) -> Void)?
    /// Se avisa al recuperar la conexión: el visor aprovecha para volver a
    /// publicar su posición y su recorrido, que son cosas que solo sabe él.
    @ObservationIgnored public var onReconnect: (() -> Void)?

    @ObservationIgnored private let endpoint: HostEndpoint
    @ObservationIgnored private let code: String?
    @ObservationIgnored private let makeTransport: (HostEndpoint) -> any WebSocketTransport
    @ObservationIgnored private var transport: (any WebSocketTransport)?
    @ObservationIgnored private var role: Role
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var hasBeenOnline = false
    @ObservationIgnored private var stopped = false

    public init(
        endpoint: HostEndpoint,
        role: Role,
        code: String? = nil,
        transport: @escaping (HostEndpoint) -> any WebSocketTransport = {
            NWWebSocketTransport(endpoint: $0)
        }
    ) {
        self.endpoint = endpoint
        self.role = role
        self.code = code
        self.makeTransport = transport
        self.hostIdentity = SessionIdentity(
            name: endpoint.displayName, key: endpoint.identityKey)
    }

    deinit {
        retryTask?.cancel()
    }

    // ------------------------------------------------------------ conexión

    public func start() {
        guard !stopped, transport == nil else { return }
        connection = .connecting
        let transport = makeTransport(endpoint)
        transport.onEvent = { [weak self] event in self?.handle(event) }
        self.transport = transport
        transport.start()
    }

    public func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        transport?.cancel()
        transport = nil
        connection = .offline
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            retryAttempt = 0
            connection = .online
            send(.hello(role: role, code: code))
            if hasBeenOnline { onReconnect?() }
            hasBeenOnline = true

        case let .message(data):
            guard let message = Wire.decodeServerMessage(data) else { return }
            apply(message)

        case .closed:
            transport = nil
            guard !stopped else { return }
            connection = .offline
            scheduleRetry()
        }
    }

    /// Reintento con espera creciente, hasta un tope de cinco segundos: un
    /// anfitrión que tarda en volver no merece que le machaquemos a intentos,
    /// pero tampoco queremos esperar medio minuto cuando vuelve enseguida.
    private func scheduleRetry() {
        retryAttempt += 1
        let delay = min(0.5 * pow(2, Double(retryAttempt - 1)), 5)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Al volver del segundo plano no tiene sentido esperar a que venza el
    /// reintento: la red casi siempre está lista antes.
    public func reconnectNow() {
        guard !stopped, transport == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        start()
    }

    // ------------------------------------------------------------- estado

    private func apply(_ message: ServerMessage) {
        switch message {
        case let .state(incoming, counts):
            var coarse = incoming
            coarse.position = state.position  // la posición va por su camino
            state = coarse
            clients = counts
            adopt(position: incoming.position)

        case let .patch(patch):
            applyIncoming(patch)

        case let .clients(counts):
            clients = counts

        case let .rejected(reason):
            rejection = reason
            stop()

        case .unknown:
            break
        }
    }

    /// Separa la posición del resto: lo demás repinta la interfaz, la posición
    /// se la queda el motor de scroll para acercarse a ella poco a poco.
    private func applyIncoming(_ patch: TeleprompterPatch) {
        var coarse = patch
        coarse.position = nil
        if !coarse.isEmpty { state.apply(coarse) }
        if let position = patch.position { adopt(position: position) }
    }

    private func adopt(position: Double) {
        livePosition = position
        onIncomingPosition?(position)
    }

    // ------------------------------------------------------------- salida

    public func setRole(_ role: Role) {
        guard role != self.role else { return }
        self.role = role
        // El anfitrión acepta un `hello` nuevo sobre la misma conexión, así que
        // cambiar de modo no obliga a reconectar.
        if connection == .online { send(.hello(role: role, code: code)) }
    }

    public func update(_ patch: TeleprompterPatch) {
        guard let clean = patch.sanitized() else { return }

        var coarse = clean
        coarse.position = nil
        if !coarse.isEmpty { state.apply(coarse) }
        if let position = clean.position { livePosition = position }

        send(.update(patch: clean))
    }

    private func send(_ message: ClientMessage) {
        guard let data = try? Wire.encode(message) else { return }
        transport?.send(data)
    }
}
