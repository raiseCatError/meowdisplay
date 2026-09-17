import Foundation

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
}
