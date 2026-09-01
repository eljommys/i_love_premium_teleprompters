import Foundation

/// La invitación que el anfitrión enseña como QR. Lleva el código dentro, así
/// que escanearla une sin teclear nada; los datos sueltos siguen ahí para poder
/// unirse a mano si la cámara no es una opción.
public struct JoinLink: Equatable, Sendable {
    /// Nombre visible del anfitrión, y también su nombre de servicio Bonjour.
    public var name: String
    /// Dirección en el momento de generar el código. Puede quedar obsoleta si
    /// el anfitrión cambia de red; por eso se guarda también el nombre.
    public var host: String?
    public var port: UInt16?
    public var code: String?

    public init(name: String, host: String? = nil, port: UInt16? = nil, code: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.code = code
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = PrompterService.urlScheme
        components.host = "join"
        var items = [URLQueryItem(name: "name", value: name)]
        if let host { items.append(URLQueryItem(name: "host", value: host)) }
        if let port { items.append(URLQueryItem(name: "port", value: String(port))) }
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        components.queryItems = items
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == PrompterService.urlScheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // `uprompter://join?…` deja «join» en host, y `uprompter:join?…` en la
        // ruta. Se aceptan las dos formas porque según quién genere el QR sale
        // una u otra.
        let action = components.host ?? components.path.trimmingCharacters(in: ["/"])
        guard action == "join" else { return nil }

        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard let name = value("name") else { return nil }
        self.name = name
        self.host = value("host")
        self.port = value("port").flatMap(UInt16.init)
        self.code = value("code")
    }

    /// Por dónde intentar la conexión. La dirección directa va primero: si el
    /// QR se escanea al momento es la vía más rápida y no depende del mDNS.
    public var endpoints: [HostEndpoint] {
        var endpoints: [HostEndpoint] = []
        if let host, let port { endpoints.append(.address(host: host, port: port)) }
        endpoints.append(.service(name: name, type: PrompterService.type, domain: nil))
        return endpoints
    }
}
