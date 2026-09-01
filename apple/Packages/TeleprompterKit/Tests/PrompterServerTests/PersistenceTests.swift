import Foundation
import Testing

@testable import PrompterCore
@testable import PrompterServer

@MainActor
@Suite("Guardado en disco")
struct PersistenceTests {

    private func temporaryStore() -> StatePersistence {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return StatePersistence(url: folder.appending(path: "state.json"))
    }

    @Test("lo que se guarda vuelve tal cual")
    func roundTrip() {
        let store = temporaryStore()
        let state = TeleprompterState(
            text: "un guion\ncon dos líneas", speed: 55, fontSize: 90, lineHeight: 1.8, margin: 12,
            mirrorH: true, position: 0.42)
        store.save(state)

        let loaded = store.load()
        #expect(loaded.text == state.text)
        #expect(loaded.speed == 55)
        #expect(loaded.fontSize == 90)
        #expect(loaded.mirrorH)
        #expect(loaded.position == 0.42)
    }

    @Test("no se guarda ni si estaba en marcha ni cuánto medía la pantalla")
    func ephemeralKeysAreNotPersisted() throws {
        let store = temporaryStore()
        store.save(TeleprompterState(playing: true, docHeight: 9999))

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url))
        let keys = Set((raw as? [String: Any] ?? [:]).keys)
        #expect(keys == TeleprompterState.persistedKeys)
    }

    @Test("un fichero que no existe deja los valores por defecto")
    func missingFile() {
        #expect(temporaryStore().load() == TeleprompterState())
    }

    @Test("un fichero ilegible se aparta en vez de sobrescribirse")
    func corruptFileIsMovedAside() throws {
        let store = temporaryStore()
        try Data("esto no es JSON ni de lejos".utf8).write(to: store.url)

        #expect(store.load() == TeleprompterState())

        let backup = store.url.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(
            try String(contentsOf: backup, encoding: .utf8) == "esto no es JSON ni de lejos",
            "dentro podía estar el único guion que había")
    }

    @Test("lo que se lee del disco también se acota")
    func loadedValuesAreSanitized() throws {
        let store = temporaryStore()
        try Data(#"{"speed":9000,"fontSize":-3,"position":7}"#.utf8).write(to: store.url)

        let loaded = store.load()
        #expect(loaded.speed == Limits.speed.max)
        #expect(loaded.fontSize == Limits.fontSize.min)
        #expect(loaded.position == 1)
    }

    @Test("al arrancar, el guion vuelve donde estaba pero en pausa")
    func restoredSessionStartsPaused() {
        let store = temporaryStore()
        store.save(TeleprompterState(text: "hola", position: 0.7))

        let core = HostCore(persistence: store)
        #expect(core.state.text == "hola")
        #expect(core.livePosition == 0.7)
        #expect(!core.state.playing, "nadie quiere que la app arranque leyendo sola")
        #expect(core.state.docHeight == 0, "el recorrido lo mide el visor de esta sesión")
    }

    // ------------------------------------------------------- aplazamiento

    @Test("un guardado urgente pendiente no lo retrasa uno perezoso")
    func urgentSaveIsNotPostponed() async {
        var disparos = 0
        let scheduler = DebounceScheduler { disparos += 1 }

        scheduler.schedule(after: .milliseconds(150))  // urgente
        scheduler.schedule(after: .seconds(5))  // perezoso, llega después

        try? await Task.sleep(for: .milliseconds(400))
        #expect(disparos == 1, "el perezoso se tragó al urgente")
    }

    @Test("un guardado urgente sí adelanta a uno perezoso pendiente")
    func urgentSaveOvertakesLazyOne() async {
        var disparos = 0
        let scheduler = DebounceScheduler { disparos += 1 }

        scheduler.schedule(after: .seconds(5))
        scheduler.schedule(after: .milliseconds(150))

        try? await Task.sleep(for: .milliseconds(400))
        #expect(disparos == 1)
    }

    @Test("al cerrar se vuelca lo que quedara pendiente")
    func flushWritesPendingWork() {
        var disparos = 0
        let scheduler = DebounceScheduler { disparos += 1 }

        scheduler.schedule(after: .seconds(5))
        #expect(scheduler.isPending)
        scheduler.flush()
        #expect(disparos == 1)
        #expect(!scheduler.isPending)

        scheduler.flush()
        #expect(disparos == 1, "sin nada pendiente no se escribe de más")
    }

    @Test("la posición se guarda con calma y el texto enseguida")
    func saveTiersFollowTheKeys() async throws {
        let store = temporaryStore()
        let core = HostCore(persistence: store)
        let peer = SpyPeer()
        core.attach(peer)

        core.apply(TeleprompterPatch(position: 0.5), from: peer)
        try await Task.sleep(for: .milliseconds(700))
        #expect(
            !FileManager.default.fileExists(atPath: store.url.path),
            "la posición sola no merece escribir el guion entero")

        core.apply(TeleprompterPatch(text: "cambio de verdad"), from: peer)
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.load().text == "cambio de verdad")
        #expect(store.load().position == 0.5, "y de paso se lleva la posición")
    }
}
