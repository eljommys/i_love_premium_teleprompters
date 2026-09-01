import Observation
import PrompterClient
import PrompterCore
import PrompterServer
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// El estado de la aplicación: en qué modo estamos y de quién es la sesión.
///
/// El modelo mental es uno solo en las tres máquinas: **siempre hay una sesión y
/// este aparato siempre está dentro**. Los tres modos son formas de mirar la
/// misma sesión, no aplicaciones distintas. La única pregunta es de quién es:
/// mía (alojo, con o sin acompañantes) o de otro (me he unido).
///
/// Trabajar en solitario no es un modo aparte: es alojar sin que se haya unido
/// nadie. Por eso la aplicación es utilizable entera en un aparato suelto, que
/// además es como la va a probar quien la revise en Apple.
@MainActor
@Observable
final class AppModel {

    enum Mode: String, CaseIterable, Identifiable {
        case editor
        case prompter
        case remote
        /// Con quién se comparte la sesión. Es un modo más y no un aviso
        /// permanente arriba: unir aparatos se hace al montar, no cada dos
        /// minutos, y no tiene por qué robar sitio al guion el resto del rato.
        case connect

        var id: String { rawValue }

        var role: Role {
            switch self {
            case .editor: .editor
            case .prompter: .prompter
            case .remote: .remote
            // El mismo papel que tenía la portada en la versión web: mira la
            // sesión pero no manda sobre el guion.
            case .connect: .home
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .editor: "Editor"
            case .prompter: "Visor"
            case .remote: "Mando"
            case .connect: "Conectar"
            }
        }

        var symbol: String {
            switch self {
            case .editor: "square.and.pencil"
            case .prompter: "play.rectangle"
            case .remote: "slider.horizontal.below.rectangle"
            case .connect: "antenna.radiowaves.left.and.right"
            }
        }
    }

    // ------------------------------------------------------------- sesión

    private(set) var mode: Mode
    private(set) var hostCore: HostCore
    private(set) var hostServer: HostServer
    private(set) var localSession: LocalSession
    /// La sesión de otro aparato, cuando nos hemos unido a una.
    private(set) var joinedSession: RemoteSession?

    let browser = BonjourBrowser()

    /// La sesión que miran las vistas. Es la de otro si nos hemos unido.
    var session: any TeleprompterSession { joinedSession ?? localSession }
    var isJoined: Bool { joinedSession != nil }

    /// Las sesiones a las que tiene sentido unirse: todas menos la propia. Un
    /// aparato ve su propio anuncio en la red, y ofrecerle unirse a sí mismo
    /// sería absurdo.
    var otherHosts: [DiscoveredHost] {
        guard let mine = hostServer.advertisedName else { return browser.hosts }
        return browser.hosts.filter { $0.name != mine }
    }

    /// ¿Hay un aviso ocupando el borde superior?
    ///
    /// Solo quedan los que no pueden esperar: que nos hayan echado, o que el
    /// anfitrión se haya caído a media toma. Encontrar una sesión a la que
    /// unirse ya no avisa desde arriba —se ve en el modo Conectar—, porque eso
    /// estaba puesto todo el rato tapando el guion.
    var showsTopBanner: Bool {
        if joinError != nil { return true }
        return isJoined && session.connection != .online
    }

    /// Cuántas sesiones ajenas se ven ahora mismo, para avisarlo discretamente
    /// en el selector de modo en vez de con un cartel.
    var discoveredCount: Int { otherHosts.count }

    // ------------------------------------------------------- ajustes propios

    private(set) var deviceName: String
    /// Con emparejamiento, quien se une tiene que traer el código.
    var requiresPairing: Bool {
        didSet {
            hostCore.pairingCode = requiresPairing ? pairingCode : nil
            Preferences.requiresPairing = requiresPairing
        }
    }
    private(set) var pairingCode: String
    var autoJoinEnabled: Bool {
        didSet { Preferences.autoJoin = autoJoinEnabled }
    }

    /// Servir la página con la que alguien se une desde el navegador, sin
    /// instalar nada. Va apagado de partida: es una puerta más a la sesión y
    /// abrirla tiene que ser una decisión, no un descuido.
    var webAccessEnabled: Bool {
        didSet {
            Preferences.webAccess = webAccessEnabled
            if webAccessEnabled { hostServer.startWeb() } else { hostServer.stopWeb() }
        }
    }

    /// La dirección que se teclea en el navegador de quien no tiene la app.
    var webAddress: String? {
        guard webAccessEnabled, let port = hostServer.webPort,
            let host = LocalAddresses.preferred
        else { return nil }
        return "http://\(host):\(port)"
    }

    /// La misma dirección con el código dentro, para el QR: escanearlo abre el
    /// navegador ya dentro de la sesión.
    var webJoinURL: String? {
        guard let address = webAddress else { return nil }
        return requiresPairing ? "\(address)/?code=\(pairingCode)" : address
    }

    /// Sube cada vez que hay que volver a decir lo que solo sabe este aparato.
    /// El visor lo vigila para republicar su posición y su recorrido en cuanto
    /// vuelve la conexión: el anfitrión que reaparece trae una posición vieja y
    /// no tiene ni idea de cuánto mide el guion en esta pantalla.
    private(set) var reassertToken = 0

    /// Cuándo se perdió el anfitrión, para poder ofrecer seguir en solitario
    /// cuando ya está claro que no vuelve.
    private(set) var offlineSince: Date?
    private(set) var joinError: JoinError?

    enum JoinError: Equatable {
        case rejected(RejectionReason)
        case unreachable
    }

    // ---------------------------------------------------------- arranque

    init() {
        let name = DeviceName.current
        deviceName = name

        let persistence = StatePersistence.applicationSupport()
        let code = Preferences.pairingCode ?? PairingCode.generate()
        Preferences.pairingCode = code
        let pairing = Preferences.requiresPairing

        let core = HostCore(persistence: persistence, pairingCode: pairing ? code : nil)
        let startingMode =
            Preferences.lastMode.flatMap(Mode.init(rawValue:)) ?? Mode.defaultForThisDevice

        hostCore = core
        hostServer = HostServer(core: core, serviceName: name)
        pairingCode = code
        requiresPairing = pairing
        autoJoinEnabled = Preferences.autoJoin
        webAccessEnabled = Preferences.webAccess
        mode = startingMode
        localSession = LocalSession(core: core, role: startingMode.role)

        // Primer arranque: un guion de ejemplo, para que los tres modos hagan
        // algo desde el primer segundo sin tener que escribir nada.
        if core.state.text.isEmpty {
            core.apply(TeleprompterPatch(text: Self.sampleScript), from: nil)
        }
    }

    func start() {
        // Se aloja desde el principio, sin preguntar. Si el servicio no puede
        // abrirse —sin permiso de red local, por ejemplo— la aplicación sigue
        // siendo utilizable entera: solo deja de poder acompañarla otro aparato.
        hostServer.start()
        if webAccessEnabled { hostServer.startWeb() }
        browser.start()
    }

    // ------------------------------------------------------------- modos

    func select(_ mode: Mode) {
        guard mode != self.mode else { return }
        if mode == .connect { modeBeforeConnecting = self.mode }
        self.mode = mode
        Preferences.lastMode = mode.rawValue
        // Un saludo nuevo por la misma conexión: cambiar de modo no reconecta.
        session.setRole(mode.role)
    }

    /// Adónde ir después de unirse a una sesión.
    ///
    /// Quedarse mirando la pantalla de conexión sería un callejón: lo que
    /// quiere quien acaba de unir el aparato es usarlo. Se vuelve al modo que
    /// este aparato traía antes de venir a conectar.
    func selectAfterJoining() {
        guard mode == .connect else { return }
        select(modeBeforeConnecting ?? Mode.defaultForThisDevice)
    }

    /// El modo del que se venía al entrar en Conectar.
    private var modeBeforeConnecting: Mode?

    // ------------------------------------------------------------- unirse

    /// Anfitrión al que queremos unirnos pero que todavía nos tiene que dejar
    /// entrar. Mientras esté puesto, la interfaz pide el código.
    var pendingJoin: DiscoveredHost?

    /// Un toque en «Unirse». Si ya nos emparejamos con este anfitrión alguna
    /// vez, se entra directamente; si no, hay que pedir el código, porque
    /// intentarlo a ciegas solo consigue que nos echen.
    func requestJoin(_ host: DiscoveredHost) {
        if let saved = Preferences.savedCode(for: host.endpoint) {
            join(endpoint: host.endpoint, code: saved)
        } else {
            pendingJoin = host
        }
    }

    func join(_ host: DiscoveredHost, code: String? = nil) {
        pendingJoin = nil
        join(endpoint: host.endpoint, code: code ?? Preferences.savedCode(for: host.endpoint))
    }

    /// El código no valía: se olvida para no reintentarlo solo y se vuelve a
    /// pedir.
    func retryPairing() {
        guard let joined = joinedSession, let host = lastAttemptedHost else { return }
        joined.stop()
        joinedSession = nil
        Preferences.forgetCode(for: host.endpoint)
        joinError = nil
        hostServer.start()
        pendingJoin = host
    }

    @ObservationIgnored private var lastAttemptedHost: DiscoveredHost?

    func join(link: JoinLink) {
        guard let endpoint = link.endpoints.first else { return }
        join(endpoint: endpoint, code: link.code)
    }

    func join(endpoint: HostEndpoint, code: String?) {
        lastAttemptedHost = DiscoveredHost(name: endpoint.displayName, endpoint: endpoint)
        leaveSession()

        // Alojar y estar unido a la vez no significa nada: mientras seguimos a
        // otro, este aparato deja de ofrecerse.
        hostServer.stop()

        let remote = RemoteSession(endpoint: endpoint, role: mode.role, code: code)
        remote.onReconnect = { [weak self] in
            self?.offlineSince = nil
            self?.reassertToken += 1
        }
        joinedSession = remote
        joinError = nil
        offlineSince = nil
        remote.start()

        if let code { Preferences.saveCode(code, for: endpoint) }
        Preferences.lastJoinedKey = endpoint.identityKey
    }

    /// Vuelve a alojar la sesión de este aparato, con el guion que tenía.
    func leaveSession() {
        guard let joined = joinedSession else { return }
        joined.stop()
        joinedSession = nil
        offlineSince = nil
        joinError = nil
        Preferences.lastJoinedKey = nil
        localSession.setRole(mode.role)
        hostServer.start()
    }

    /// El anfitrión no vuelve y hay que seguir grabando: este aparato adopta el
    /// último estado conocido y pasa a alojar la sesión desde donde iba.
    func continueSolo() {
        guard let joined = joinedSession else { return }
        var adopted = joined.state
        adopted.position = joined.livePosition
        adopted.playing = false
        hostCore.apply(
            TeleprompterPatch(
                text: adopted.text,
                playing: false,
                speed: adopted.speed,
                fontSize: adopted.fontSize,
                lineHeight: adopted.lineHeight,
                margin: adopted.margin,
                mirrorH: adopted.mirrorH,
                mirrorV: adopted.mirrorV,
                position: adopted.position
            ),
            from: nil
        )
        leaveSession()
    }

    /// La cuenta atrás para ofrecer «continuar en solitario». La llama la vista
    /// cuando cambia el estado de la conexión.
    func connectionChanged(to status: ConnectionStatus) {
        switch status {
        case .offline where offlineSince == nil:
            offlineSince = Date()
        case .online:
            offlineSince = nil
        default:
            break
        }
        if let rejection = joinedSession?.rejection {
            joinError = .rejected(rejection)
        }
    }

    var offlineSeconds: TimeInterval {
        guard let offlineSince else { return 0 }
        return Date().timeIntervalSince(offlineSince)
    }

    // ---------------------------------------------------- emparejamiento

    func regeneratePairingCode() {
        pairingCode = PairingCode.generate()
        Preferences.pairingCode = pairingCode
        if requiresPairing { hostCore.pairingCode = pairingCode }
    }

    /// La invitación que se enseña como QR: escanearla une sin teclear nada.
    var joinLink: JoinLink {
        JoinLink(
            name: deviceName,
            host: LocalAddresses.preferred,
            port: hostServer.port,
            code: requiresPairing ? pairingCode : nil
        )
    }

    // ------------------------------------------------------ ciclo de vida

    func didBecomeActive() {
        if isJoined {
            // Al volver del segundo plano la red suele estar lista antes de que
            // venza el reintento.
            joinedSession?.reconnectNow()
        } else if case .running = hostServer.status {
            // Nada que hacer: seguía escuchando.
        } else {
            // En iOS el sistema cierra el servicio al pasar a segundo plano.
            hostServer.restart()
        }
        browser.start()
    }

    func willResignActive() {
        hostCore.flushPendingSave()
    }

    /// Si la botonera del visor está a la vista.
    ///
    /// Vive aquí y no dentro del visor porque el selector de modo se dibuja
    /// fuera de él y tiene que esconderse y volver con ella.
    var viewerChromeVisible = true

    /// El selector de modo se aparta solo mientras se lee en el visor. En
    /// cualquier otro caso está puesto: desde cualquier vista hay que poder ir
    /// a las demás.
    var showsModeSwitcher: Bool {
        mode != .prompter || viewerChromeVisible
    }

    /// La pantalla no debe apagarse con el visor delante, ni mientras este
    /// aparato aloja la sesión de otros.
    var shouldStayAwake: Bool {
        mode == .prompter || hostCore.remotePeerCount > 0
    }
}

// ----------------------------------------------------------- preferencias

/// Lo que recuerda cada aparato por su cuenta y no se comparte con nadie.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var lastMode: String? {
        get { defaults.string(forKey: "teleprompter.mode") }
        set { defaults.set(newValue, forKey: "teleprompter.mode") }
    }

    static var pairingCode: String? {
        get { defaults.string(forKey: "teleprompter.pairingCode") }
        set { defaults.set(newValue, forKey: "teleprompter.pairingCode") }
    }

    static var requiresPairing: Bool {
        get { defaults.object(forKey: "teleprompter.requiresPairing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "teleprompter.requiresPairing") }
    }

    static var webAccess: Bool {
        get { defaults.object(forKey: "teleprompter.webAccess") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "teleprompter.webAccess") }
    }

    static var autoJoin: Bool {
        get { defaults.object(forKey: "teleprompter.autoJoin") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "teleprompter.autoJoin") }
    }

    static var lastJoinedKey: String? {
        get { defaults.string(forKey: "teleprompter.lastJoined") }
        set { defaults.set(newValue, forKey: "teleprompter.lastJoined") }
    }

    /// El código se guarda por anfitrión: emparejar una vez basta, y los
    /// montajes de siempre vuelven a unirse sin que nadie teclee nada.
    static func savedCode(for endpoint: HostEndpoint) -> String? {
        defaults.string(forKey: "teleprompter.code.\(endpoint.identityKey)")
    }

    static func saveCode(_ code: String, for endpoint: HostEndpoint) {
        defaults.set(code, forKey: "teleprompter.code.\(endpoint.identityKey)")
    }

    static func forgetCode(for endpoint: HostEndpoint) {
        defaults.removeObject(forKey: "teleprompter.code.\(endpoint.identityKey)")
    }
}

extension AppModel.Mode {
    /// Cada máquina abre por donde casi siempre se la usa: el Mac a escribir,
    /// el iPad al cristal y el móvil al mando. Cero toques para el caso normal.
    @MainActor
    static var defaultForThisDevice: AppModel.Mode {
        #if os(macOS)
            return .editor
        #else
            return UIDevice.current.userInterfaceIdiom == .pad ? .prompter : .remote
        #endif
    }
}

enum DeviceName {
    @MainActor
    static var current: String {
        #if os(macOS)
            return Host.current().localizedName ?? "Mac"
        #else
            return UIDevice.current.name
        #endif
    }
}

extension AppModel {
    /// Guion de ejemplo del primer arranque. Enseña de qué va esto sin pedir
    /// que nadie escriba nada, que es justo lo que necesita quien revisa la app
    /// con un solo aparato.
    static var sampleScript: String {
        String(
            localized: """
                Bienvenido a Universal Teleprompter.

                Este es un guion de ejemplo. Bórralo y escribe el tuyo desde el editor.

                Pulsa sobre el texto para empezar a leer y vuelve a pulsar para parar.

                En el mando, arrastra el dedo sobre el guion para moverte por él: es como sujetar el papel con la mano.

                Para acompañar este aparato con otro, abre la misma aplicación en él y únete a esta sesión.
                """)
    }
}
