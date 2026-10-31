import Foundation

/// Which kinds of reported tailnet address automatic Remote Access may dial on a path (Android:
/// AutomaticRemoteRoutes.kt). A family is turned on for a path only once it has been verified on
/// real devices; a typed address is never limited by this.
struct TailnetFamilies: Equatable, Sendable {
    var ipv4: Bool
    var ipv6: Bool
    var names: Bool

    static let none = TailnetFamilies(ipv4: false, ipv6: false, names: false)

    /// The Mac dialing an Android device (9001) after its knock over Tailscale IPv4: verified live
    /// over LTE + Tailscale (handoff-2.0/COMPLETION-MATRIX.md, "Android Remote devices"). IPv6 and
    /// MagicDNS names have not been verified on this path.
    static let android = TailnetFamilies(ipv4: true, ipv6: false, names: false)

    /// The Mac dialing a receiver that said `device` in its hello. iPhone, iPad and Mac receivers
    /// accepting connections over the tailnet have not been verified on devices yet.
    static func macDialing(device: String?) -> TailnetFamilies {
        device == "Android" ? .android : .none
    }

    /// An iPhone, iPad or Mac receiver knocking its Mac (9003) over the tailnet: not verified yet.
    static let appleReceiverKnocking = TailnetFamilies.none
}

enum AutomaticRemoteRoutes {
    /// The address to use from a report, or nil: a MagicDNS name first (it survives address
    /// changes), then IPv4, then IPv6, each only where `families` allows it.
    static func host(names: [String], ips: [String], families: TailnetFamilies) -> String? {
        if families.names, let name = names.first { return name }
        if families.ipv4, let v4 = ips.first(where: { !$0.contains(":") }) { return v4 }
        if families.ipv6, let v6 = ips.first(where: { $0.contains(":") }) { return v6 }
        return nil
    }

    /// Where the Mac dials `peerID`'s media listener: its typed address, else what it reported,
    /// on a verified path only and only while automatic Remote Access is on.
    static func macMediaEndpoint(forPeerID peerID: String, pin: Data?, now: Date = Date()) -> (host: String, port: UInt16, automatic: Bool)? {
        if let typed = RemoteEndpointStore.mediaEndpoint(forPeerID: peerID, role: .sender) {
            return (typed.host, typed.port, false)
        }
        guard AutomaticRemoteAccessPreference.isEnabled(.sender),
              let entry = AutomaticRemoteEndpointStore(role: .sender).entry(forPeerID: peerID, currentPin: pin, now: now),
              let host = host(names: entry.names, ips: entry.ips, families: .macDialing(device: entry.device)) else { return nil }
        return (host, WireCrypto.tlsPort, true)
    }
}
