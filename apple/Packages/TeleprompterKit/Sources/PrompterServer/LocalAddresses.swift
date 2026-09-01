import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Direcciones IPv4 de este aparato en la red local, para poder meterlas en el
/// QR de invitación y enseñarlas a quien tenga que teclearlas.
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var found: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }

            let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
            if !text.isEmpty, !found.contains(text) { found.append(text) }
        }

        // Las 192.168.x son las de casa y las de la mayoría de plató: si hay
        // varias interfaces, esa es casi siempre la buena.
        return found.sorted { lhs, rhs in
            let lhsHome = lhs.hasPrefix("192.168.")
            let rhsHome = rhs.hasPrefix("192.168.")
            if lhsHome != rhsHome { return lhsHome }
            return lhs < rhs
        }
    }

    public static var preferred: String? { ipv4().first }
}
