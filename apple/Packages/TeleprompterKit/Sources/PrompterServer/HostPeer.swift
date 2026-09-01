import Foundation
import PrompterCore

/// Un aparato conectado al anfitrión, venga por un socket o desde este mismo
/// proceso. El núcleo no distingue entre unos y otros: así la interfaz del
/// propio anfitrión pasa por las mismas reglas que cualquier iPad de la red.
@MainActor
public protocol HostPeer: AnyObject {
    var role: Role { get set }
    /// Ha superado el emparejamiento y puede recibir el guion.
    var isAuthenticated: Bool { get set }
    /// ¿Hay que pedirle el código?
    ///
    /// La interfaz del propio anfitrión no: no viene de la red y no tiene a
    /// quién demostrarle nada. Sin esta distinción, encender el emparejamiento
    /// dejaba fuera del reparto al mismo aparato que aloja la sesión.
    var needsPairing: Bool { get }
    /// Con qué se le identifica para contar intentos fallidos de código.
    var remoteIdentifier: String { get }
    func send(_ message: ServerMessage)
    func disconnect()
}

extension HostPeer {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    /// Por defecto sí: cualquiera que llegue por la red tiene que traer código.
    public var needsPairing: Bool { true }
}

/// El aparato que aloja la sesión, conectado a su propio núcleo sin pasar por
/// la red.
///
/// Va por dentro y no por un `ws://127.0.0.1` a propósito: el visor del
/// anfitrión no puede quedarse «sin conexión» consigo mismo, no hace falta
/// permiso de red local para verse a uno mismo, y el camino de más frecuencia
/// —arrastrar el mando del propio aparato— no serializa nada.
@MainActor
public final class LocalPeer: HostPeer {
    public var role: Role
    public var isAuthenticated: Bool = true
    public let remoteIdentifier = "local"
    public let needsPairing = false
    /// A dónde van los mensajes del núcleo. Ya vienen tipados.
    public var onMessage: ((ServerMessage) -> Void)?

    public init(role: Role = .home) {
        self.role = role
    }

    public func send(_ message: ServerMessage) {
        onMessage?(message)
    }

    public func disconnect() {
        // El anfitrión no se echa a sí mismo.
    }
}
