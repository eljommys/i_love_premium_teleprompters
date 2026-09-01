import Foundation
import Network
import Observation
import PrompterCore

/// Un anfitrión visto en la red local.
public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    public let name: String
    public let endpoint: HostEndpoint

    public var id: String { endpoint.identityKey }

    public init(name: String, endpoint: HostEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

/// Estado del permiso de red local. Denegarlo no rompe la app: solo deja de
/// encontrar anfitriones, y este aparato sigue siendo utilizable en solitario.
public enum LocalNetworkAccess: Equatable, Sendable {
    case unknown
    case allowed
    case denied
}

/// Busca anfitriones por Bonjour para que unirse sea un toque y no teclear una
/// dirección.
@MainActor
@Observable
public final class BonjourBrowser {
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var access: LocalNetworkAccess = .unknown

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private let serviceType: String

    public init(serviceType: String = PrompterService.type) {
        self.serviceType = serviceType
    }

    deinit {
        MainActor.assumeIsolated { browser?.cancel() }
    }

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.access = .allowed
                case let .waiting(error):
                    // Sin permiso de red local el navegador se queda esperando
                    // para siempre en vez de fallar: hay que mirar el error
                    // para poder decírselo al usuario.
                    self.access = Self.isPolicyDenied(error) ? .denied : .unknown
                case let .failed(error):
                    self.access = Self.isPolicyDenied(error) ? .denied : .unknown
                    self.restart()
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.hosts = Self.hosts(from: results)
            }
        }

        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    private static func hosts(from results: Set<NWBrowser.Result>) -> [DiscoveredHost] {
        results
            .compactMap { result -> DiscoveredHost? in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return DiscoveredHost(
                    name: name,
                    endpoint: .service(name: name, type: type, domain: domain))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EPERM || code == .EACCES
        }
        return false
    }
}

/// Identidad del servicio en la red. Un tipo propio y no un `_teleprompter._tcp`
/// genérico: así la lista de anfitriones no se llena de otras aplicaciones.
public enum PrompterService {
    public static let type = "_uprompter._tcp"
    public static let urlScheme = "uprompter"
}
