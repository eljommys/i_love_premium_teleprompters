import Foundation
import Testing

@testable import PrompterCore
@testable import PrompterServer

@MainActor
@Suite("Sesión del propio anfitrión")
struct LocalSessionTests {

    @Test("la interfaz del anfitrión ve el estado del núcleo sin copiarlo")
    func readsThroughToTheCore() {
        let core = HostCore()
        let session = LocalSession(core: core, role: .editor)

        session.update(TeleprompterPatch(text: "hola", speed: 42))
        #expect(session.state.text == "hola")
        #expect(session.state.speed == 42)
        #expect(core.state.text == "hola")
    }

    @Test("alojar la sesión no es algo que se pueda perder")
    func hostIsAlwaysOnline() {
        let core = HostCore()
        let session = LocalSession(core: core)
        #expect(session.connection == .online)
        #expect(!session.isRemoteHost, "el aviso de borde solo sale estando unido a otro")
        #expect(session.hostIdentity == nil)
    }

    @Test("lo que manda el anfitrión sale saneado, igual que lo de fuera")
    func localUpdatesGoThroughTheSameRules() {
        let core = HostCore()
        let session = LocalSession(core: core)

        session.update(TeleprompterPatch(fontSize: 9999))
        #expect(session.state.fontSize == Limits.fontSize.max)
    }

    @Test("el anfitrión cuenta como un aparato más, con su papel")
    func localPeerCounts() {
        let core = HostCore()
        let session = LocalSession(core: core, role: .prompter)
        #expect(core.clients == ClientCounts(prompter: 1))

        session.setRole(.remote)
        #expect(core.clients == ClientCounts(remote: 1))
    }

    @Test("pero no cuenta como aparato de la red")
    func localPeerIsNotARemotePeer() {
        let core = HostCore()
        _ = LocalSession(core: core, role: .prompter)
        #expect(core.remotePeerCount == 0, "no hay a quién mantener despierto todavía")

        let remoto = SpyPeer(role: .remote)
        core.attach(remoto)
        #expect(core.remotePeerCount == 1)
    }

    @Test("la posición de otro aparato llega al motor de scroll, no a la interfaz")
    func incomingPositionGoesToTheEngine() {
        let core = HostCore()
        let session = LocalSession(core: core, role: .prompter)
        var recibidas: [Double] = []
        session.onIncomingPosition = { recibidas.append($0) }

        let mando = SpyPeer(role: .remote)
        core.attach(mando)
        core.receive(.update(patch: TeleprompterPatch(position: 0.8)), from: mando)

        #expect(recibidas == [0.8])
        #expect(session.livePosition == 0.8)
        #expect(session.state.position == 0, "el estado observable no se mueve con la posición")
    }

    @Test("lo que hace el anfitrión no le vuelve como un eco")
    func ownUpdatesDoNotEcho() {
        let core = HostCore()
        let session = LocalSession(core: core, role: .remote)
        var recibidas: [Double] = []
        session.onIncomingPosition = { recibidas.append($0) }

        session.update(TeleprompterPatch(position: 0.33))
        #expect(recibidas.isEmpty, "aplicarse el propio eco es lo que provoca los saltos")
        #expect(session.livePosition == 0.33)
    }

    @Test("un aparato de la red y el propio anfitrión ven exactamente lo mismo")
    func localAndRemotePeersSeeTheSameStream() {
        // El peer local va por dentro y el de red por un socket. Si no vieran
        // lo mismo, habría dos comportamientos que mantener en vez de uno.
        let core = HostCore()
        let anfitrion = LocalSession(core: core, role: .editor)
        let iPad = SpyPeer(role: .prompter)
        core.attach(iPad)

        let mando = SpyPeer(role: .remote)
        core.attach(mando)

        core.receive(.update(patch: TeleprompterPatch(playing: true, speed: 80)), from: mando)

        #expect(iPad.patches == [TeleprompterPatch(playing: true, speed: 80)])
        #expect(anfitrion.state.playing)
        #expect(anfitrion.state.speed == 80)
        #expect(mando.patches.isEmpty, "tampoco al emisor de la red")
    }

    @Test("los atajos de la sesión hacen lo que dicen")
    func conveniences() {
        let core = HostCore()
        let session = LocalSession(core: core)

        session.togglePlaying()
        #expect(session.state.playing)

        session.update(TeleprompterPatch(position: 0.9))
        session.rewind()
        #expect(!session.state.playing)
        #expect(session.livePosition == 0)
    }
}
