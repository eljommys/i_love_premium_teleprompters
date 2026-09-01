import Foundation
import Observation
import PrompterCore

/// El estado compartido y las reglas de reparto, sin saber nada de sockets.
///
/// Es la traducción del servidor de la versión web: mismo saneado, misma regla
/// de difusión y mismos plazos de guardado. Que un aparato esté al otro lado de
/// la Wi-Fi o dentro de este mismo proceso no cambia ninguna de esas reglas.
@MainActor
@Observable
public final class HostCore {
    /// Lo que cambia a ritmo humano y mueve la interfaz. Su campo `position`
    /// no se mantiene al día a propósito: mírala en `livePosition`.
    public private(set) var state: TeleprompterState
    public private(set) var clients = ClientCounts()

    /// Posición viva. Va aparte porque cambia decenas de veces por segundo
    /// mientras alguien lee o arrastra, y repintar la interfaz a ese ritmo no
    /// aporta nada.
    @ObservationIgnored public private(set) var livePosition: Double

    /// Código de emparejamiento. Con `nil` la sesión está abierta a cualquiera
    /// de la red local, como en la versión web.
    @ObservationIgnored public var pairingCode: String?

    @ObservationIgnored private var peers: [ObjectIdentifier: any HostPeer] = [:]
    @ObservationIgnored private let persistence: StatePersistence?
    @ObservationIgnored private var saver: DebounceScheduler?
    /// Intentos fallidos de código por origen, para que nadie pruebe los diez
    /// mil a base de reconectar.
    @ObservationIgnored private var failedAttempts: [String: Int] = [:]

    public static let maxPairingAttempts = 5

    public init(persistence: StatePersistence? = nil, pairingCode: String? = nil) {
        self.persistence = persistence
        self.pairingCode = pairingCode

        var restored = persistence?.load() ?? TeleprompterState()
        // El guion vuelve donde lo dejaste, pero en pausa: nadie quiere que la
        // app arranque leyendo sola.
        restored.playing = false
        // Y sin recorrido medido: lo mide el visor de esta sesión, no el de la
        // anterior, que a lo mejor era otra pantalla.
        restored.docHeight = 0

        livePosition = restored.position
        state = restored

        saver = DebounceScheduler { [weak self] in
            guard let self, let persistence = self.persistence else { return }
            persistence.saveInBackground(self.snapshot)
        }
    }

    /// El estado completo y al día, con la posición viva puesta en su sitio.
    /// Es lo que se manda a quien acaba de entrar y lo que se guarda en disco.
    public var snapshot: TeleprompterState {
        var full = state
        full.position = livePosition
        return full
    }

    // --------------------------------------------------------- conexiones

    public func attach(_ peer: any HostPeer) {
        peers[peer.id] = peer

        if pairingCode == nil || !peer.needsPairing {
            // Sin emparejamiento se da por bueno al conectar, igual que hace el
            // servidor web: el estado sale antes incluso del saludo. La
            // interfaz de este mismo aparato entra siempre por aquí: pedirse el
            // código a uno mismo la dejaba fuera del reparto, y entonces el
            // mando de otro aparato movía a todos menos al anfitrión.
            peer.isAuthenticated = true
            peer.send(.state(snapshot, clients))
        } else {
            // Con emparejamiento no sale nada hasta que llegue un saludo con el
            // código correcto: el guion no se le enseña a quien no ha entrado.
            peer.isAuthenticated = false
        }

        recount()
    }

    public func detach(_ peer: any HostPeer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        recount()
    }

    public var peerCount: Int { peers.count }

    /// Aparatos de la red que han entrado, sin contar la interfaz de este mismo
    /// aparato: es lo que decide si hay alguien a quien mantener despierto.
    public var remotePeerCount: Int {
        peers.values.filter { !($0 is LocalPeer) && $0.isAuthenticated }.count
    }

    // ----------------------------------------------------------- mensajes

    public func receive(_ message: ClientMessage, from peer: any HostPeer) {
        switch message {
        case let .hello(role, code):
            handleHello(role: role, code: code, from: peer)

        case let .update(patch):
            // Un aparato que no ha entrado no toca el guion de nadie.
            guard peer.isAuthenticated else { return }
            apply(patch, from: peer)

        case .unknown:
            break  // Se ignora sin cerrar la conexión.
        }
    }

    private func handleHello(role: Role, code: String?, from peer: any HostPeer) {
        if let expected = pairingCode, !peer.isAuthenticated {
            let attempts = failedAttempts[peer.remoteIdentifier] ?? 0
            guard attempts < Self.maxPairingAttempts else {
                peer.send(.rejected(reason: .tooManyAttempts))
                peer.disconnect()
                return
            }
            guard code == expected else {
                failedAttempts[peer.remoteIdentifier] = attempts + 1
                peer.send(.rejected(reason: .badCode))
                peer.disconnect()
                return
            }
            failedAttempts.removeValue(forKey: peer.remoteIdentifier)
            peer.isAuthenticated = true
            peer.role = role
            peer.send(.state(snapshot, clients))
            recount()
            return
        }

        // Repetir el saludo sirve para cambiar de modo sin reconectar.
        peer.role = role
        recount()
    }

    /// Aplica un cambio y lo reparte.
    ///
    /// El emisor queda fuera del reparto porque ya lo aplicó en local;
    /// devolvérselo solo serviría para provocar un salto cuando el mensaje
    /// llega tarde.
    public func apply(_ patch: TeleprompterPatch, from sender: (any HostPeer)?) {
        guard let clean = patch.sanitized() else { return }

        var coarse = clean
        coarse.position = nil
        if !coarse.isEmpty { state.apply(coarse) }
        if let position = clean.position { livePosition = position }

        let senderID = sender?.id
        for peer in peers.values where peer.id != senderID && peer.isAuthenticated {
            peer.send(.patch(clean))
        }

        scheduleSave(for: clean)
    }

    private func scheduleSave(for patch: TeleprompterPatch) {
        guard persistence != nil else { return }
        let persisted = patch.keys.intersection(TeleprompterState.persistedKeys)
        guard !persisted.isEmpty else { return }

        if persisted.subtracting(TeleprompterState.liveKeys).isEmpty {
            // Solo la posición: cambia decenas de veces por segundo mientras se
            // lee, y reescribir el guion entero a ese ritmo no aporta nada.
            saver?.schedule(after: .seconds(5))
        } else {
            saver?.schedule(after: .milliseconds(500))
        }
    }

    /// Vuelca ya lo que hubiera pendiente, al irse la app a segundo plano: la
    /// posición espera cinco segundos y no vale la pena perderla por eso.
    public func flushPendingSave() {
        saver?.flush()
    }

    // ---------------------------------------------------------- recuentos

    private func recount() {
        var counts = ClientCounts()
        for peer in peers.values where peer.isAuthenticated {
            counts[peer.role] += 1
        }
        guard counts != clients else { return }
        clients = counts
        for peer in peers.values where peer.isAuthenticated {
            peer.send(.clients(counts))
        }
    }
}
