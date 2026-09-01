import Foundation
import Network
import Observation

/// Sirve la página con la que cualquiera se une desde un navegador, sin
/// instalar nada.
///
/// Va en su propio puerto y no en el del protocolo porque el escucha de la
/// sesión está montado sobre `NWProtocolWebSocket`: acepta el upgrade y punto,
/// no sabe responder a un `GET /`. Montar los dos en el mismo puerto obligaría
/// a implementar a mano el enmarcado de WebSocket, que es justo lo que da hecho
/// el framework. Dos escuchas cuestan una conexión ociosa; reescribir el
/// protocolo cuesta mucho más y se rompe más fácil.
///
/// La página conecta al WebSocket por el puerto que se le inyecta al servirla.
@MainActor
@Observable
public final class HTTPServer {
    public private(set) var port: UInt16?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let webSocketPort: () -> UInt16?
    @ObservationIgnored private let firstPort: UInt16
    @ObservationIgnored private var attemptedPort: UInt16
    @ObservationIgnored private let page: Data

    public static let portAttempts = 50

    /// - Parameters:
    ///   - firstPort: por dónde se empieza a buscar sitio.
    ///   - webSocketPort: se consulta al servir, no al arrancar: el puerto del
    ///     protocolo puede no estar decidido todavía cuando esto se monta.
    public init(
        firstPort: UInt16,
        page: Data = HTTPServer.bundledPage(),
        webSocketPort: @escaping () -> UInt16?
    ) {
        self.firstPort = firstPort
        self.attemptedPort = firstPort
        self.page = page
        self.webSocketPort = webSocketPort
    }

    /// La página que va dentro de la app.
    public static func bundledPage() -> Data {
        guard let url = Bundle.module.url(forResource: "web-client", withExtension: "html"),
            let data = try? Data(contentsOf: url)
        else { return Data("<!doctype html><title>Sin página</title>".utf8) }
        return data
    }

    // ------------------------------------------------------------ arranque

    public func start() {
        guard listener == nil else { return }
        attemptedPort = firstPort
        listen(on: attemptedPort)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func listen(on candidate: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: parameters, on: nwPort) else {
            tryNextPort()
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue ?? candidate
                case .failed:
                    // Puerto ocupado: se prueba el siguiente, igual que hace el
                    // escucha del protocolo.
                    listener.cancel()
                    self.listener = nil
                    self.tryNextPort()
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }

        listener.start(queue: .main)
    }

    private func tryNextPort() {
        let next = attemptedPort + 1
        guard next < firstPort &+ UInt16(Self.portAttempts) else {
            port = nil
            return
        }
        attemptedPort = next
        listen(on: next)
    }

    // -------------------------------------------------------------- servir

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Con leer el primer trozo basta: solo se atiende la línea de petición
        // y no hay cuerpos que recibir.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                connection.send(
                    content: self.response(for: request),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// Una respuesta para lo poco que hay que servir: la página, y un 404 para
    /// todo lo demás. Se cierra la conexión en cada respuesta —sin keep-alive—
    /// porque son cuatro peticiones contadas por visita.
    func response(for request: String) -> Data {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        // Una línea de petición es «MÉTODO destino versión». Sin destino no
        // hay nada que interpretar: es basura, no una visita a la raíz.
        guard parts.count >= 2 else {
            return Self.reply(status: "400 Bad Request", body: Data(), type: "text/plain")
        }
        let method = String(parts[0])
        let route = parts[1].split(separator: "?").first.map(String.init) ?? "/"

        guard method == "GET" || method == "HEAD" else {
            return Self.reply(status: "405 Method Not Allowed", body: Data(), type: "text/plain")
        }
        guard route == "/" || route == "/index.html" else {
            return Self.reply(status: "404 Not Found", body: Data("No hay nada aquí.".utf8),
                              type: "text/plain; charset=utf-8")
        }

        let body = method == "HEAD" ? Data() : pageWithPort()
        return Self.reply(status: "200 OK", body: body, type: "text/html; charset=utf-8",
                          length: pageWithPort().count)
    }

    /// La página con el puerto del protocolo dentro. Se inyecta al servir y no
    /// se guarda en el fichero porque el puerto se decide al arrancar.
    private func pageWithPort() -> Data {
        let wsPort = webSocketPort().map(String.init) ?? "null"
        let script = Data("<script>window.__WS_PORT__=\(wsPort)</script>\n".utf8)
        guard let head = page.range(of: Data("<head>".utf8)) else { return script + page }
        var out = page
        out.replaceSubrange(head.upperBound..<head.upperBound, with: script)
        return out
    }

    static func reply(status: String, body: Data, type: String, length: Int? = nil) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(length ?? body.count)\r\n"
        // Nada de caché: el guion y los ajustes cambian, y una página vieja
        // apuntando a un puerto viejo no conecta con nada.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
