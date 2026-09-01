import Foundation

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case online
    case offline
}

/// Identidad de una sesión, para saber a quién nos estamos uniendo y poder
/// recordar su código de emparejamiento.
public struct SessionIdentity: Equatable, Sendable, Hashable {
    /// Nombre visible del aparato anfitrión.
    public var name: String
    /// Clave estable con la que se recuerda el emparejamiento.
    public var key: String

    public init(name: String, key: String) {
        self.name = name
        self.key = key
    }
}

/// Lo que una vista necesita de la sesión, sea la de este aparato o la de otro.
///
/// Las tres vistas se escriben una sola vez contra este protocolo: que el
/// estado venga de un socket o de un anfitrión que corre en este mismo proceso
/// no cambia nada de lo que hacen.
@MainActor
public protocol TeleprompterSession: AnyObject {
    /// Valores que cambian a ritmo humano. Mueven la interfaz.
    var state: TeleprompterState { get }
    var connection: ConnectionStatus { get }
    var clients: ClientCounts { get }

    /// ¿Estamos en la sesión de otro aparato? Es lo único que distingue la
    /// interfaz de un aparato unido de la de uno que aloja la sesión.
    var isRemoteHost: Bool { get }
    /// Quién aloja la sesión, si no somos nosotros.
    var hostIdentity: SessionIdentity? { get }

    /// Posición viva. Va aparte del resto del estado porque cambia en cada
    /// fotograma y no debe repintar la interfaz.
    var livePosition: Double { get }
    /// Se llama cuando llega una posición de otro aparato. El motor de scroll
    /// la usa como objetivo al que acercarse, nunca como un salto.
    var onIncomingPosition: ((Double) -> Void)? { get set }

    func setRole(_ role: Role)
    /// Aplica el cambio aquí al instante y lo difunde al resto.
    func update(_ patch: TeleprompterPatch)
}

extension TeleprompterSession {
    /// Atajo para el caso más repetido: tocar una sola cosa.
    public func update(_ build: (inout TeleprompterPatch) -> Void) {
        var patch = TeleprompterPatch()
        build(&patch)
        update(patch)
    }

    public func togglePlaying() {
        update(TeleprompterPatch(playing: !state.playing))
    }

    public func rewind() {
        update(TeleprompterPatch(playing: false, position: 0))
    }
}
