import Foundation

/// This device's own Tailscale addresses, for its `remoteEndpoints` report. No Tailscale API: the
/// tunnel is a `utun` interface carrying an address in the tailnet ranges. Requiring `utun` matters
/// for IPv4: a carrier's CGNAT can hand the cellular interface (`pdp_ip`) a 100.64.0.0/10 address
/// that is no tailnet address at all.
enum TailnetInterfaces {
    struct Candidate: Equatable {
        var interface: String
        var up: Bool
        var address: String
    }

    /// The tailnet addresses among `candidates`, IPv4 first, normalized and capped as a report is.
    static func select(_ candidates: [Candidate]) -> [String] {
        let tunnel = candidates.filter { $0.up && $0.interface.hasPrefix("utun") }.map(\.address)
        let kept = TailnetEndpointFilter.filter(names: [], addresses: tunnel.filter { !$0.contains(":") } + tunnel.filter { $0.contains(":") })
        return kept.addresses
    }

    static func current() -> [String] {
        var candidates: [Candidate] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let end = host.firstIndex(of: 0) ?? host.count
            var address = String(decoding: host[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            let flags = Int32(ifa.ifa_flags)
            candidates.append(Candidate(interface: String(cString: ifa.ifa_name),
                                        up: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0, address: address))
        }
        return select(candidates)
    }
}
