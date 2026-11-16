import Foundation

/// Plain-value facts about an established connection's live path, taken
/// from its `NWPath` (see `ConnectionPathEvidence+NWPath.swift`) so the
/// wording rules below are testable without Network.framework.
struct ConnectionPathEvidence: Equatable, Sendable {
    /// `NWPath.availableInterfaces` names, in the path's order.
    var interfaceNames: [String]
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesLoopback: Bool
    /// The remote address is link-local (fe80::/10 or 169.254/16).
    var remoteIsLinkLocal: Bool
    /// The interface a scoped remote address names (`fe80::1%bridge0` →
    /// `bridge0`); nil when the remote address carries no zone.
    var remoteScopeInterface: String?
    /// The far end is a Mac: the only peer that can sit on a Thunderbolt
    /// host-to-host link with this product.
    var peerIsMac: Bool
}

/// Answers whether a network interface is one end of a direct host-to-host
/// cable. On macOS: a Thunderbolt IP port, or a bridge made only of such
/// ports (Thunderbolt Bridge). Tests inject a fake.
protocol HostToHostCableInterfaceChecking: Sendable {
    func isHostToHostCableInterface(_ name: String) -> Bool
}

/// No interface is ever a host-to-host cable (iOS, and any platform where
/// the check is unavailable): every path keeps its route label.
struct NoHostToHostCableInterfaces: HostToHostCableInterfaceChecking {
    func isHostToHostCableInterface(_ name: String) -> Bool { false }
}

/// The user-facing wording for an established connection. Display only:
/// the route itself (`ConnectionRoute`, its `rawValue` in diagnostics,
/// arbitration tiers and overrides) is unchanged by it. A LAN connection
/// that verifiably rides a direct Mac-to-Mac Thunderbolt cable reads
/// "Direct Cable"; everything else, including anything not verified, reads
/// as its route ("USB" stays the iPhone/iPad usbmux transport).
struct ConnectionPathDescription: Equatable, Sendable {
    static let directCableLabel = "Direct Cable"

    let route: ConnectionRoute
    let isDirectCable: Bool

    /// The plain route wording, with no path evidence.
    init(route: ConnectionRoute) {
        self.route = route
        self.isDirectCable = false
    }

    init(route: ConnectionRoute, evidence: ConnectionPathEvidence?,
         cableInterfaces: HostToHostCableInterfaceChecking) {
        self.route = route
        self.isDirectCable = evidence.map {
            Self.isVerifiedDirectCable(route: route, evidence: $0, cableInterfaces: cableInterfaces)
        } ?? false
    }

    var label: String {
        isDirectCable ? Self.directCableLabel : route.rawValue
    }

    /// What a surface shows for `route` given the last published wording:
    /// the wording only while it describes that same route (a description
    /// left over from another route never shows), else the route's label.
    static func label(route: ConnectionRoute?, description: ConnectionPathDescription?) -> String? {
        guard let route else { return nil }
        if let description, description.route == route { return description.label }
        return route.rawValue
    }

    /// All of: a LAN route to a Mac; no Wi-Fi, cellular, loopback,
    /// peer-to-peer or tunnel interface on the path; a link-local remote;
    /// and the carrying interface (every listed interface, when the remote
    /// address names none) is a host-to-host cable interface. A
    /// link-local peer on wired Ethernet alone proves nothing (Bonjour often
    /// resolves to fe80 on an ordinary switched LAN), so the interface check
    /// is what decides.
    static func isVerifiedDirectCable(route: ConnectionRoute, evidence: ConnectionPathEvidence,
                                      cableInterfaces: HostToHostCableInterfaceChecking) -> Bool {
        guard route == .lan, evidence.peerIsMac,
              !evidence.usesWiFi, !evidence.usesCellular, !evidence.usesLoopback,
              evidence.remoteIsLinkLocal else { return false }
        let names = evidence.interfaceNames + (evidence.remoteScopeInterface.map { [$0] } ?? [])
        guard !names.contains(where: { name in
            ConnectionRoute.isPeerToPeerInterface(name) || ConnectionRoute.isTunnelInterface(name)
                || name.lowercased().hasPrefix("lo")
        }) else { return false }
        // A scoped remote names the interface that carries the connection.
        // Without a zone nothing says which listed interface does, so every
        // one of them must be a cable interface.
        if let zone = evidence.remoteScopeInterface, !zone.isEmpty {
            return cableInterfaces.isHostToHostCableInterface(zone)
        }
        return !evidence.interfaceNames.isEmpty
            && evidence.interfaceNames.allSatisfy(cableInterfaces.isHostToHostCableInterface)
    }

    // MARK: - Endpoint text helpers (for endpoints Network.framework could
    // not type as an IP address, e.g. a scope it did not resolve)

    /// True for fe80::/10 and 169.254/16 literals, bracketed or not.
    static func isLinkLocalAddressText(_ text: String) -> Bool {
        var host = text.lowercased()
        if host.hasPrefix("[") { host.removeFirst() }
        if host.hasPrefix("169.254.") { return true }
        guard host.count >= 4 else { return false }
        // fe80::/10 is fe80 through febf.
        let prefix = host.prefix(4)
        guard prefix.hasPrefix("fe"), let third = prefix.dropFirst(2).first else { return false }
        return "89ab".contains(third) && (host.count == 4 || host.dropFirst(4).first == ":")
    }

    /// The zone of a scoped address (`fe80::1%bridge0`, `[fe80::1%en1]:7000`,
    /// `fe80::1%bridge0.7000`): the interface name after `%`, nil if none.
    static func scopeZone(inEndpointText text: String) -> String? {
        guard let percent = text.firstIndex(of: "%") else { return nil }
        let zone = text[text.index(after: percent)...].prefix { $0.isLetter || $0.isNumber }
        return zone.isEmpty ? nil : String(zone)
    }
}
