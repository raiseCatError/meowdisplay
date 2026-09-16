import Foundation

/// The physical route carrying an established OpenDisplay connection.
/// Discovery targets remain USB or Bonjour; AWDL and LAN are distinguished
/// only after Network.framework has selected the live path.
enum ConnectionRoute: String, Equatable {
    case usb = "USB"
    case awdl = "AWDL"
    case lan = "LAN"
    case remote = "Remote"

    static func classify(
        isUSB: Bool,
        interfaceNames: [String],
        remoteEndpointDescription: String?
    ) -> ConnectionRoute {
        if isUSB { return .usb }

        let names = interfaceNames.map { $0.lowercased() }
        if remoteEndpointDescription.map(hasPeerToPeerScope) == true {
            return .awdl
        }

        // Tailscale (and other WireGuard-based overlay networks on macOS/iOS)
        // present as a `utun*` interface carrying a CGNAT tailnet address
        // (100.64.0.0/10) or a tailnet IPv6 ULA (fd7a:115c:a1e0::/48). Check
        // this before the AWDL/LAN split below since a `utun` interface is
        // never peer-to-peer Wi-Fi.
        if names.contains(where: isTunnelInterface) ||
            remoteEndpointDescription.map(hasTailscaleAddress) == true {
            return .remote
        }

        // `availableInterfaces` can contain an ordinary LAN interface and
        // AWDL simultaneously. Without a scoped endpoint, classify AWDL only
        // when every non-loopback interface is peer-to-peer.
        let relevantNames = names.filter { !$0.hasPrefix("lo") }
        if !relevantNames.isEmpty,
           relevantNames.allSatisfy(isPeerToPeerInterface) {
            return .awdl
        }
        return .lan
    }

    static func isPeerToPeerInterface(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("awdl") || lowercased.hasPrefix("llw")
    }

    static func isTunnelInterface(_ name: String) -> Bool {
        name.lowercased().hasPrefix("utun") || name.lowercased() == "tailscale0"
    }

    private static func hasPeerToPeerScope(_ endpoint: String) -> Bool {
        let lowercased = endpoint.lowercased()
        return lowercased.contains("%awdl") || lowercased.contains("%llw")
    }

    /// Labels a route hint only — this is never used to grant trust. TLS
    /// pinning in `TLSConfigurator` remains the sole source of peer identity.
    private static func hasTailscaleAddress(_ endpoint: String) -> Bool {
        var host = endpoint
            .split(separator: "%").first.map(String.init) ?? endpoint
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasPrefix("100.") {
            // CGNAT range 100.64.0.0/10: second octet 64...127.
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return true
            }
        }
        return host.lowercased().contains("fd7a:115c:a1e0")
    }
}
