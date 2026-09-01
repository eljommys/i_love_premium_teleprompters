import Foundation

/// Cuántos aparatos hay conectados con cada papel.
public struct ClientCounts: Codable, Equatable, Sendable {
    public var editor: Int
    public var prompter: Int
    public var remote: Int
    public var home: Int

    public init(editor: Int = 0, prompter: Int = 0, remote: Int = 0, home: Int = 0) {
        self.editor = editor
        self.prompter = prompter
        self.remote = remote
        self.home = home
    }

    public subscript(role: Role) -> Int {
        get {
            switch role {
            case .editor: editor
            case .prompter: prompter
            case .remote: remote
            case .home: home
            }
        }
        set {
            switch role {
            case .editor: editor = newValue
            case .prompter: prompter = newValue
            case .remote: remote = newValue
            case .home: home = newValue
            }
        }
    }

    public var total: Int { editor + prompter + remote + home }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func count(_ key: CodingKeys) -> Int {
            ((try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0
        }

        editor = count(.editor)
        prompter = count(.prompter)
        remote = count(.remote)
        home = count(.home)
    }
}

/// Por qué un anfitrión ha rechazado una conexión.
public enum RejectionReason: String, Codable, Sendable {
    case badCode = "bad-code"
    case tooManyAttempts = "too-many-attempts"
}

/// Lo que manda un aparato al anfitrión.
public enum ClientMessage: Equatable, Sendable {
    /// Se anuncia con su papel. Puede repetirse sobre la misma conexión para
    /// cambiar de modo sin reconectar.
    ///
    /// `code` es el código de emparejamiento. Va como clave extra a propósito:
    /// el servidor de la versión web lo ignora al leer solo `role`, así que un
    /// aparato nativo puede unirse a una sesión web sin cambios.
    case hello(role: Role, code: String?)
    case update(patch: TeleprompterPatch)
    /// Algo con un `type` que no conocemos. Se ignora sin cerrar la conexión.
    case unknown(type: String)
}

/// Lo que manda el anfitrión a los aparatos.
public enum ServerMessage: Equatable, Sendable {
    /// Estado completo. Solo al conectar.
    case state(TeleprompterState, ClientCounts)
    /// Cambio de otro aparato.
    case patch(TeleprompterPatch)
    case clients(ClientCounts)
    /// Emparejamiento fallido. La conexión se cierra a continuación.
    case rejected(reason: RejectionReason)
    case unknown(type: String)
}

// ----------------------------------------------------------------- códecs

private enum MessageKey: String, CodingKey {
    case type
    case role
    case code
    case patch
    case state
    case clients
    case error
}

private enum MessageType {
    static let hello = "hello"
    static let update = "update"
    static let state = "state"
    static let patch = "patch"
    static let clients = "clients"
    static let error = "error"
}

/// Un mensaje que no se puede representar en el protocolo. Solo puede pasar si
/// se intenta reenviar un mensaje que llegó ya como desconocido.
public struct UnencodableMessage: Error {
    public let type: String
}

extension ClientMessage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKey.self)
        let type = ((try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil) ?? ""

        switch type {
        case MessageType.hello:
            // Un papel que no existe deja el mensaje inservible: el anfitrión
            // lo ignora, igual que hace el servidor web.
            guard let raw = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? nil,
                  let role = Role(rawValue: raw)
            else {
                self = .unknown(type: type)
                return
            }
            let code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
            self = .hello(role: role, code: code)

        case MessageType.update:
            let patch =
                ((try? container.decodeIfPresent(TeleprompterPatch.self, forKey: .patch)) ?? nil)
                ?? TeleprompterPatch()
            self = .update(patch: patch)

        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MessageKey.self)
        switch self {
        case let .hello(role, code):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(code, forKey: .code)
        case let .update(patch):
            try container.encode(MessageType.update, forKey: .type)
            try container.encode(patch, forKey: .patch)
        case let .unknown(type):
            throw UnencodableMessage(type: type)
        }
    }
}

extension ServerMessage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKey.self)
        let type = ((try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil) ?? ""

        switch type {
        case MessageType.state:
            let state =
                ((try? container.decodeIfPresent(TeleprompterState.self, forKey: .state)) ?? nil)
                ?? TeleprompterState()
            let clients =
                ((try? container.decodeIfPresent(ClientCounts.self, forKey: .clients)) ?? nil)
                ?? ClientCounts()
            self = .state(state, clients)

        case MessageType.patch:
            let patch =
                ((try? container.decodeIfPresent(TeleprompterPatch.self, forKey: .patch)) ?? nil)
                ?? TeleprompterPatch()
            self = .patch(patch)

        case MessageType.clients:
            let clients =
                ((try? container.decodeIfPresent(ClientCounts.self, forKey: .clients)) ?? nil)
                ?? ClientCounts()
            self = .clients(clients)

        case MessageType.error:
            let raw = (try? container.decodeIfPresent(String.self, forKey: .error)) ?? nil
            self = .rejected(reason: raw.flatMap(RejectionReason.init(rawValue:)) ?? .badCode)

        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MessageKey.self)
        switch self {
        case let .state(state, clients):
            try container.encode(MessageType.state, forKey: .type)
            try container.encode(state, forKey: .state)
            try container.encode(clients, forKey: .clients)
        case let .patch(patch):
            try container.encode(MessageType.patch, forKey: .type)
            try container.encode(patch, forKey: .patch)
        case let .clients(clients):
            try container.encode(MessageType.clients, forKey: .type)
            try container.encode(clients, forKey: .clients)
        case let .rejected(reason):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(reason, forKey: .error)
        case let .unknown(type):
            throw UnencodableMessage(type: type)
        }
    }
}

// ------------------------------------------------------- codificación JSON

/// El JSON del protocolo. Sin claves ordenadas ni espacios: son mensajes, no
/// ficheros que vaya a leer nadie.
public enum Wire {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encode(_ message: ClientMessage) throws -> Data {
        try encoder.encode(message)
    }

    public static func encode(_ message: ServerMessage) throws -> Data {
        try encoder.encode(message)
    }

    public static func decodeClientMessage(_ data: Data) -> ClientMessage? {
        try? decoder.decode(ClientMessage.self, from: data)
    }

    public static func decodeServerMessage(_ data: Data) -> ServerMessage? {
        try? decoder.decode(ServerMessage.self, from: data)
    }
}
