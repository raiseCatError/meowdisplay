import Foundation

/// The destructive part of the Mac Forget action, kept independent of UI so
/// the stable peer ID and all per-peer cleanup calls can be regression-tested.
enum ForgetDeviceAction {
    static func perform(
        peerID: String,
        forgetTrust: (String) -> Void,
        removeRemoteEndpoint: (String) -> Void,
        removeWakeMetadata: (String) -> Void,
        removeInputAuthorization: (String) -> Void = { _ in }
    ) {
        forgetTrust(peerID)
        removeRemoteEndpoint(peerID)
        removeWakeMetadata(peerID)
        // Security-sensitive: a permanent "may enable input" grant must
        // never survive trust removal — a different device (or the same
        // one re-paired with a new key) must re-earn it explicitly.
        removeInputAuthorization(peerID)
    }
}
