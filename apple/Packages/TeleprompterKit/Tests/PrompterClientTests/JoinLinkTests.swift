import Foundation
import Testing

@testable import PrompterClient

@Suite("Invitación por QR")
struct JoinLinkTests {

    @Test("la invitación va y vuelve entera")
    func roundTrip() throws {
        let link = JoinLink(name: "MacBook de Jommy", host: "192.168.1.20", port: 3000, code: "4821")
        let url = try #require(link.url)
        #expect(try #require(JoinLink(url: url)) == link)
    }

    @Test("los nombres con espacios y acentos sobreviven")
    func escapesNames() throws {
        let link = JoinLink(name: "iPad de Jommy — salón", code: "0042")
        let url = try #require(link.url)
        let parsed = try #require(JoinLink(url: url))
        #expect(parsed.name == "iPad de Jommy — salón")
        #expect(parsed.code == "0042")
    }

    @Test("un enlace sin código sigue valiendo para unirse a mano")
    func codeIsOptional() throws {
        let url = try #require(URL(string: "uprompter://join?name=Mac&host=10.0.0.5&port=3100"))
        let link = try #require(JoinLink(url: url))
        #expect(link.code == nil)
        #expect(link.port == 3100)
    }

    @Test("se prueba primero la dirección directa y luego el nombre Bonjour")
    func endpointOrder() throws {
        let link = JoinLink(name: "Mac", host: "10.0.0.5", port: 3000, code: "1234")
        #expect(link.endpoints.first == .address(host: "10.0.0.5", port: 3000))
        #expect(link.endpoints.count == 2)

        let onlyName = JoinLink(name: "Mac")
        #expect(onlyName.endpoints.count == 1)
        #expect(onlyName.endpoints.first == .service(name: "Mac", type: "_uprompter._tcp", domain: nil))
    }

    @Test("un enlace de otra app o de otra acción no se acepta")
    func rejectsForeignLinks() {
        #expect(JoinLink(url: URL(string: "https://ejemplo.com/join?name=Mac")!) == nil)
        #expect(JoinLink(url: URL(string: "uprompter://borrar?name=Mac")!) == nil)
        #expect(JoinLink(url: URL(string: "uprompter://join")!) == nil, "sin nombre no hay nada que hacer")
    }

    @Test("cada anfitrión tiene una clave estable con la que recordarlo")
    func identityKeys() {
        let service = HostEndpoint.service(name: "Mac", type: "_uprompter._tcp", domain: nil)
        let address = HostEndpoint.address(host: "10.0.0.5", port: 3000)
        #expect(service.identityKey == "service:_uprompter._tcp:Mac")
        #expect(address.identityKey == "address:10.0.0.5:3000")
        #expect(service.identityKey != address.identityKey)
    }

    @Test("la dirección manual apunta a /ws, que es lo que exige el servidor web")
    func addressEndpointUsesWebSocketPath() throws {
        let endpoint = HostEndpoint.address(host: "192.168.1.20", port: 3000)
        guard case let .url(url)? = endpoint.nwEndpoint else {
            Issue.record("no se construyó un endpoint de URL")
            return
        }
        #expect(url.absoluteString == "ws://192.168.1.20:3000/ws")
    }
}
