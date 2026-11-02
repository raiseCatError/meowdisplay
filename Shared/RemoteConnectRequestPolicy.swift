import Foundation
import Network

/// Bounds how often an authenticated remote connect-request "knock" (see
/// `WireCrypto.remoteRequestPort`) from a given peer is allowed to trigger a
/// fresh dial-back. Pure logic — no networking, no Keychain — so it can be
/// unit tested the same way as `ReconnectPolicy`/`AutoConnectPolicy`.
///
/// This is a nuisance/DoS bound, not an authentication mechanism: identity
/// is already established by the pinned-mutual-TLS handshake before this
/// policy ever runs. Its only job is to stop an already-pinned-but-buggy or
/// compromised peer from forcing repeated dial attempts.
enum RemoteConnectRequestPolicy {
    /// Minimum spacing between two accepted requests from the same peer.
    static let minimumInterval: TimeInterval = 5.0

    /// Whether a knock from `peerID` arriving at `now` should be handled,
    /// given the last-accepted time recorded for that peer (if any).
    static func shouldHandle(peerID: String, now: Date, lastAccepted: [String: Date]) -> Bool {
        guard let last = lastAccepted[peerID] else { return true }
        return now.timeIntervalSince(last) >= minimumInterval
    }

    /// A route the Mac can answer a knock on.
    enum DialRoute: Equatable {
        /// The receiver's Bonjour result on the local network.
        case localBonjour
        /// The address saved for the receiver in Remote Access settings.
        case savedHint
        /// The address the knock came from, on the media port.
        case observedSource
    }

    /// The order the Mac tries routes in to answer a knock. A knock that
    /// arrived over a tunnel (Tailscale or another VPN) proves the receiver
    /// is reachable there right now, while its Bonjour result may be stale: a
    /// phone that left the Wi-Fi without a goodbye stays listed, and a dial to
    /// its old address never fails fast, so it would shadow the route that
    /// works. Routing only — every route still ends in the pinned handshake.
    /// Whether a knock came in over a tunnel (Tailscale's or another VPN's
    /// utun/ipsec interface) rather than the local Wi-Fi or Ethernet, judged
    /// by the interface the connection actually uses. (`NWPath.usesInterfaceType(.wifi)`
    /// is also true for a tunnel carried over Wi-Fi, so it can't tell them apart.)
    static func arrivedOverTunnel(interfaceType: NWInterface.InterfaceType?, interfaceName: String?) -> Bool {
        guard interfaceType == .other, let name = interfaceName else { return false }
        return name.hasPrefix("utun") || name.hasPrefix("ipsec")
    }

    static func dialOrder(arrivedOverTunnel: Bool) -> [DialRoute] {
        arrivedOverTunnel
            ? [.observedSource, .savedHint, .localBonjour]
            : [.localBonjour, .savedHint, .observedSource]
    }
}

/// The intent a remote connect-request knock declares. The knocking
/// receiver sends exactly one length-prefixed JSON frame on the already
/// pinned-mutual-TLS knock connection, so the value is as authenticated as
/// the knock itself. It only ever narrows what the Mac does: a knock with
/// no frame (an older receiver), a malformed frame, or an unknown value is
/// `automatic`, which can never raise an approval prompt on the Mac. Only a
/// receiver-side explicit user action may declare `manual` — automatic
/// recovery must never be upgraded into manual user intent.
enum RemoteConnectRequestIntent {
    static let messageType = "remoteConnectRequest"
    /// Upper bound on the one frame the Mac reads from a knock.
    static let maximumFrameBytes = 256

    /// 4-byte big-endian length followed by the JSON body — the same
    /// framing as the control channel.
    static func frame(for intent: SessionInvitationIntent) -> Data {
        let body = Data("{\"type\":\"\(messageType)\",\"intent\":\"\(intent.rawValue)\"}".utf8)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Parses the bytes read from a knock. Anything that is not exactly one
    /// well-formed frame declaring a known intent resolves to `automatic`.
    static func intent(fromFrame data: Data?) -> SessionInvitationIntent {
        guard let data, data.count > 4, data.count <= maximumFrameBytes else { return .automatic }
        let bytes = [UInt8](data)
        let length = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard length > 0, length == bytes.count - 4,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes[4...])) as? [String: Any],
              object["type"] as? String == messageType,
              let raw = object["intent"] as? String,
              let intent = SessionInvitationIntent(rawValue: raw) else { return .automatic }
        return intent
    }
}
