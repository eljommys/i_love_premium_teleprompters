import Foundation
import Testing

@testable import PrompterCore

@Suite("Protocolo")
struct CodecTests {

    // ------------------------------------------------ cliente -> servidor

    @Test("hello se decodifica y se vuelve a escribir igual")
    func helloRoundTrip() throws {
        let raw = try Fixture.data("hello")
        let message = try #require(Wire.decodeClientMessage(raw))
        #expect(message == .hello(role: .prompter, code: nil))
        try expectSameJSON(try Wire.encode(message), raw)
    }

    @Test("hello con código lleva la clave extra, y sin código no la lleva")
    func helloPairingCode() throws {
        let withCode = try Wire.encode(ClientMessage.hello(role: .remote, code: "4821"))
        #expect(try jsonKeys(withCode) == ["type", "role", "code"])

        let without = try Wire.encode(ClientMessage.hello(role: .remote, code: nil))
        #expect(try jsonKeys(without) == ["type", "role"])
        #expect(Wire.decodeClientMessage(withCode) == .hello(role: .remote, code: "4821"))
    }

    @Test("un patch parcial viaja con las claves que trae y ninguna más")
    func updateRoundTrip() throws {
        let raw = try Fixture.data("update-partial")
        let message = try #require(Wire.decodeClientMessage(raw))
        #expect(message == .update(patch: TeleprompterPatch(playing: true)))
        try expectSameJSON(try Wire.encode(message), raw)
    }

    @Test("el informe de posición del visor incluye el recorrido medido")
    func updatePositionRoundTrip() throws {
        let raw = try Fixture.data("update-position")
        let message = try #require(Wire.decodeClientMessage(raw))
        #expect(message == .update(patch: TeleprompterPatch(position: 0.4213, docHeight: 12480)))
        try expectSameJSON(try Wire.encode(message), raw)
    }

    // ------------------------------------------------ servidor -> cliente

    @Test("un estado de la versión web se lee entero y estrena los ajustes nuevos")
    func stateRoundTrip() throws {
        let raw = try Fixture.data("state")
        let message = try #require(Wire.decodeServerMessage(raw))
        guard case let .state(state, clients) = message else {
            Issue.record("no se decodificó como estado")
            return
        }
        #expect(state.text == "Hola\nmundo")
        #expect(state.position == 0.5)
        #expect(state.speed == 30)
        #expect(state.fontSize == 64)
        #expect(state.lineHeight == 1.5)
        #expect(state.margin == 8)
        #expect(state.playing == false)
        #expect(clients == ClientCounts(editor: 1, prompter: 2, remote: 0, home: 0))

        // Un anfitrión de la versión web no manda la línea de lectura ni su
        // marca, así que quedan en sus valores por defecto en vez de en cero.
        #expect(state.readLine == Geometry.defaultReadLine)
        #expect(state.readStyle == .lineDot)

        // Y al devolverlo, lo que la versión web entiende sigue igual: los dos
        // ajustes nuestros viajan de más y ella los descarta al sanear.
        try expectCompatible(
            try Wire.encode(message), extending: raw, extras: ["readLine", "readStyle"])
    }

    @Test("la marca de lectura viaja como texto y una desconocida no se aplica")
    func readStyleWire() throws {
        let raw = Data(#"{"type":"patch","patch":{"readStyle":"highlight","readLine":0.62}}"#.utf8)
        let message = try #require(Wire.decodeServerMessage(raw))
        #expect(message == .patch(TeleprompterPatch(readLine: 0.62, readStyle: .highlight)))

        // Una marca que no conocemos —una versión más nueva al otro lado— se
        // ignora y se queda la que hubiera, en vez de convertirse en otra.
        let unknown = Data(#"{"type":"patch","patch":{"readStyle":"neon","speed":45}}"#.utf8)
        #expect(Wire.decodeServerMessage(unknown) == .patch(TeleprompterPatch(speed: 45)))
    }

    @Test("patch y clients van y vuelven sin perder nada")
    func patchAndClientsRoundTrip() throws {
        let patchRaw = try Fixture.data("patch")
        let patch = try #require(Wire.decodeServerMessage(patchRaw))
        #expect(patch == .patch(TeleprompterPatch(speed: 45, mirrorH: true)))
        try expectSameJSON(try Wire.encode(patch), patchRaw)

        let clientsRaw = try Fixture.data("clients")
        let clients = try #require(Wire.decodeServerMessage(clientsRaw))
        #expect(clients == .clients(ClientCounts(editor: 1, prompter: 2)))
        try expectSameJSON(try Wire.encode(clients), clientsRaw)
    }

    // ------------------------------------------------------- tolerancia

    @Test("un patch vacío se codifica sin ninguna clave")
    func emptyPatchHasNoKeys() throws {
        let data = try Wire.encoder.encode(TeleprompterPatch())
        #expect(try jsonKeys(data).isEmpty)
    }

    @Test("false y cero se escriben; lo ausente se calla")
    func falsyValuesAreNotDropped() throws {
        let data = try Wire.encoder.encode(TeleprompterPatch(playing: false, position: 0))
        #expect(try jsonKeys(data) == ["playing", "position"])
    }

    @Test("un tipo de mensaje desconocido se ignora sin romper nada")
    func unknownMessageType() throws {
        let raw = Data(#"{"type":"quePasaAqui","cosa":1}"#.utf8)
        #expect(Wire.decodeServerMessage(raw) == .unknown(type: "quePasaAqui"))
        #expect(Wire.decodeClientMessage(raw) == .unknown(type: "quePasaAqui"))
    }

    @Test("una clave con el tipo cambiado no tumba el resto del patch")
    func wrongTypedKeyIsSkipped() throws {
        let raw = Data(#"{"type":"patch","patch":{"speed":"rapido","fontSize":80}}"#.utf8)
        let message = try #require(Wire.decodeServerMessage(raw))
        #expect(message == .patch(TeleprompterPatch(fontSize: 80)))
    }

    @Test("una clave que no existe en el protocolo se descarta")
    func unknownPatchKeyIsIgnored() throws {
        let raw = Data(#"{"type":"patch","patch":{"chorrada":true,"margin":12}}"#.utf8)
        #expect(Wire.decodeServerMessage(raw) == .patch(TeleprompterPatch(margin: 12)))
    }

    @Test("un hello con un papel inventado se ignora")
    func helloWithBogusRole() throws {
        let raw = Data(#"{"type":"hello","role":"jefe"}"#.utf8)
        #expect(Wire.decodeClientMessage(raw) == .unknown(type: "hello"))
    }

    @Test("un estado incompleto se completa con los valores por defecto")
    func partialStateFallsBackToDefaults() throws {
        let raw = Data(#"{"type":"state","state":{"text":"solo esto"},"clients":{}}"#.utf8)
        let message = try #require(Wire.decodeServerMessage(raw))
        guard case let .state(state, clients) = message else {
            Issue.record("no se decodificó como estado")
            return
        }
        #expect(state.text == "solo esto")
        #expect(state.speed == TeleprompterState.initial.speed)
        #expect(state.fontSize == TeleprompterState.initial.fontSize)
        #expect(clients.total == 0)
    }

    @Test("el rechazo por código incorrecto viaja como error")
    func rejection() throws {
        let data = try Wire.encode(ServerMessage.rejected(reason: .badCode))
        #expect(Wire.decodeServerMessage(data) == .rejected(reason: .badCode))
        #expect(String(decoding: data, as: UTF8.self).contains("bad-code"))
    }

    @Test("un mensaje desconocido no se puede reenviar")
    func unknownIsNotEncodable() {
        #expect(throws: UnencodableMessage.self) {
            try Wire.encode(ServerMessage.unknown(type: "loQueSea"))
        }
    }
}
