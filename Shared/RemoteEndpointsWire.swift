import CryptoKit
import Foundation

/// `remoteEndpoints` (PROTOCOL.md 6.17; Android: RemoteEndpointsWire.kt): after admission, each side
/// tells the other where it can be reached over Tailscale, so automatic Remote Access needs no typed
/// address. Additive and capability-gated: the Mac lists `welcomeFeature` in `welcome.features`, a
/// receiver sends `hello.remoteEndpoints: 1`, and neither sends the message unless the other said so.
///
/// A report is a routing hint about the sender itself: no ports, no peer field, never anyone else's
/// address. It is filtered (`TailnetEndpointFilter`), kept apart from typed addresses
/// (`AutomaticRemoteEndpointStore`), and only ever dialed through the same pinned handshake.
enum RemoteEndpointsWire {
    static let type = "remoteEndpoints"
    static let welcomeFeature = "remoteEndpoints"
    static let helloField = "remoteEndpoints"
    static let helloVersion = 1

    /// A larger frame is dropped whole.
    static let maxFrameBytes = 1024
    /// More values than this in either list drops the message (the filter keeps fewer still).
    static let maxListedValues = 8
    static let maxValueLength = 253
    /// A side sends at most one report per this interval, and ignores reports closer together.
    static let minInterval: TimeInterval = 10

    struct Report: Equatable, Sendable {
        var names: [String] = []
        var ips: [String] = []

        /// Nothing to report (no Tailscale, or automatic Remote Access turned off): the receiving
        /// side forgets what it learned from this peer.
        var isEmpty: Bool { names.isEmpty && ips.isEmpty }
    }

    static func message(_ report: Report) -> [String: Any] {
        ["type": type, "names": report.names, "ips": report.ips]
    }

    /// The report in a control frame, filtered, or nil when the frame is dropped.
    static func decode(frame: Data, tailnet: String? = nil) -> Report? {
        guard frame.count <= maxFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              object["type"] as? String == type,
              let names = list(object["names"]), let ips = list(object["ips"]) else { return nil }
        let kept = TailnetEndpointFilter.filter(names: names, addresses: ips, tailnet: tailnet)
        return Report(names: kept.names, ips: kept.addresses)
    }

    private static func list(_ value: Any?) -> [String]? {
        guard let value else { return [] }
        // JSONSerialization reads `[5]` as [NSNumber]; only real strings pass.
        guard let array = value as? [Any], array.count <= maxListedValues else { return nil }
        var out: [String] = []
        for element in array {
            guard let string = element as? String, !(element is NSNumber),
                  string.utf8.count <= maxValueLength else { return nil }
            out.append(string)
        }
        return out
    }

    /// The pin a stored report is bound to: SHA-256 of the peer's pinned SPKI, hex.
    static func pinDigest(_ spki: Data) -> String {
        SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }
}

/// One report per `RemoteEndpointsWire.minInterval` from a peer; the rest are ignored.
struct RemoteEndpointsRateGate: Equatable {
    private(set) var lastAccepted: TimeInterval?

    mutating func admit(now: TimeInterval) -> Bool {
        if let lastAccepted, now - lastAccepted < RemoteEndpointsWire.minInterval, now >= lastAccepted { return false }
        lastAccepted = now
        return true
    }
}

extension RemoteEndpointsWire {
    /// What this side reports: its tunnel addresses, or nothing when automatic Remote Access is off.
    static func ownReport(_ role: RolePreferences) -> Report {
        AutomaticRemoteAccessPreference.isEnabled(role) ? Report(ips: TailnetInterfaces.current()) : Report()
    }
}

/// This side's own reports: once per connection, and never two within the peer's rate limit (a
/// report the limit would drop is not sent; the next connection sends it).
struct RemoteEndpointsOutbox: Equatable {
    private(set) var lastSentAt: TimeInterval?
    private(set) var lastConnection: UInt64?

    mutating func shouldSend(connection: UInt64, now: TimeInterval) -> Bool {
        if lastConnection == connection { return false }
        if let lastSentAt, now >= lastSentAt, now - lastSentAt < RemoteEndpointsWire.minInterval { return false }
        lastConnection = connection
        lastSentAt = now
        return true
    }
}
