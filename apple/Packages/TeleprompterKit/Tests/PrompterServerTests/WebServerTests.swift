import Foundation
import Testing

@testable import PrompterServer

@MainActor
@Suite("Página para navegadores")
struct WebServerTests {

    private func server(wsPort: UInt16? = 3000) -> HTTPServer {
        HTTPServer(
            firstPort: 8080,
            page: Data("<!doctype html><head><title>x</title></head><body>hola</body>".utf8),
            webSocketPort: { wsPort })
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test("la raíz devuelve la página")
    func servesThePage() {
        let reply = text(server().response(for: "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        #expect(reply.contains("text/html"))
        #expect(reply.contains("hola"))
    }

    @Test("el puerto del protocolo va dentro de la página")
    func injectsTheWebSocketPort() {
        // La página se sirve en un puerto y el protocolo vive en otro: si el
        // número no viajara dentro, el navegador no sabría a dónde conectarse.
        let reply = text(server(wsPort: 3007).response(for: "GET / HTTP/1.1\r\n\r\n"))
        #expect(reply.contains("window.__WS_PORT__=3007"))
        // Y va dentro del <head>, antes de que corra ningún script de la página.
        let injected = try! #require(reply.range(of: "__WS_PORT__"))
        let title = try! #require(reply.range(of: "<title>"))
        #expect(injected.lowerBound < title.lowerBound)
    }

    @Test("sin protocolo levantado el puerto sale nulo y no rompe la página")
    func toleratesMissingPort() {
        let reply = text(server(wsPort: nil).response(for: "GET / HTTP/1.1\r\n\r\n"))
        #expect(reply.contains("window.__WS_PORT__=null"))
    }

    @Test("una ruta cualquiera es un 404, no la página")
    func unknownRouteIs404() {
        let reply = text(server().response(for: "GET /admin HTTP/1.1\r\n\r\n"))
        #expect(reply.hasPrefix("HTTP/1.1 404"))
        #expect(!reply.contains("hola"))
    }

    @Test("la query no cambia la ruta")
    func queryIsIgnoredForRouting() {
        // El QR lleva el código en la query: si eso hiciera 404, unirse desde
        // el navegador escaneando no funcionaría.
        let reply = text(server().response(for: "GET /?code=2307 HTTP/1.1\r\n\r\n"))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test("HEAD contesta la cabecera pero no el cuerpo")
    func headHasNoBody() {
        let reply = text(server().response(for: "HEAD / HTTP/1.1\r\n\r\n"))
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!reply.contains("hola"))
        // Pero el tamaño anunciado sigue siendo el de la página entera: un HEAD
        // que dijera cero engañaría a quien lo use para comprobar si hay algo.
        #expect(reply.contains("Content-Length: 0\r\n") == false)
    }

    @Test("un método que no toca se rechaza")
    func rejectsOtherMethods() {
        let reply = text(server().response(for: "POST / HTTP/1.1\r\n\r\n"))
        #expect(reply.hasPrefix("HTTP/1.1 405"))
    }

    @Test("una petición vacía o rota no tumba nada")
    func survivesGarbage() {
        for junk in ["", "\r\n", "no soy http", "GET", "GET\r\n"] {
            let reply = text(server().response(for: junk))
            #expect(reply.hasPrefix("HTTP/1.1 4"))
        }
    }

    @Test("la página que se empaqueta con la app existe y trae el cliente")
    func bundledPageIsReal() {
        let page = String(decoding: HTTPServer.bundledPage(), as: UTF8.self)
        #expect(page.contains("<!doctype html>"))
        #expect(page.contains("__WS_PORT__"), "la página tiene que leer el puerto inyectado")
        #expect(page.contains("\"hello\""), "y hablar el protocolo de la sesión")
    }

    @Test("la página lee los mensajes con los nombres del protocolo")
    func pageSpeaksTheRealWireNames() {
        // Esto se me escapó una vez: la página buscaba un mensaje «rejected»
        // que no existe —en el protocolo el rechazo viaja como «error» con la
        // razón dentro— y quien entraba a una sesión con código se quedaba
        // reconectando sin que nadie le pidiera nada.
        let page = String(decoding: HTTPServer.bundledPage(), as: UTF8.self)
        #expect(page.contains("\"error\""), "el rechazo llega como type: error")
        #expect(page.contains("too-many-attempts"), "y las razones van en kebab-case")
        #expect(!page.contains("\"rejected\""), "«rejected» no es un tipo del protocolo")
        // Los que sí tiene que entender o mandar. `clients` no está a
        // propósito: la página no enseña recuentos de aparatos.
        for tipo in ["\"state\"", "\"patch\"", "\"hello\"", "\"update\""] {
            #expect(page.contains(tipo), "falta \(tipo) en el cliente web")
        }
    }

    @Test("desde el navegador se llega a los tres modos y a todos los ajustes")
    func webClientIsComplete() {
        // El navegador es un aparato más de la sesión: lo único que no puede
        // hacer es alojarla. Todo lo demás —los tres modos y cada ajuste
        // compartido— tiene que estar, o quien entre sin la app se queda a
        // medias sin saber por qué.
        let page = String(decoding: HTTPServer.bundledPage(), as: UTF8.self)

        for modo in ["prompter", "remote", "editor"] {
            #expect(page.contains("data-mode=\"\(modo)\""), "falta el modo \(modo)")
        }
        #expect(!page.contains("data-mode=\"connect\""), "el navegador no puede alojar")

        for ajuste in ["speed", "fontSize", "lineHeight", "margin", "readLine"] {
            #expect(page.contains("id=\"\(ajuste)\""), "falta el ajuste \(ajuste)")
        }
        for marca in ["dot", "lineDot", "line", "highlight", "highlightLine"] {
            #expect(page.contains("\"\(marca)\""), "falta la marca \(marca)")
        }
        for control in ["mirrorH", "mirrorV", "gear", "text", "play", "home"] {
            #expect(page.contains("id=\"\(control)\""), "falta el control \(control)")
        }
    }

    @Test("la página se traduce sola para quien no navegue en español")
    func webClientSpeaksEnglishToo() {
        // Un invitado abre un enlace: no debería toparse con un idioma que no
        // habla solo porque el anfitrión sea de aquí.
        let page = String(decoding: HTTPServer.bundledPage(), as: UTF8.self)
        #expect(page.contains("navigator.language"), "hay que mirar el idioma del navegador")
        for pareja in ["\"Conectado\":\"Connected\"", "\"Visor\":\"Viewer\"",
                       "\"Mando\":\"Remote\"", "\"Reproducir\":\"Play\"",
                       "\"Línea de lectura\":\"Reading line\""] {
            #expect(page.contains(pareja), "falta la traducción \(pareja)")
        }
    }
}
