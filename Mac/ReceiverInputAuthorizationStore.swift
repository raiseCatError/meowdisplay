import Foundation

/// Permanent, per-peer authorization for a receiver to enable Mac input
/// from its own UI (an `allowInputRequest`) without a fresh Mac
/// confirmation on every request — see the gate in
/// `SenderController`'s `onAllowInputRequest` wiring. This is deliberately
/// NOT the global Allow Input master gate (`InputPolicy`/
/// `SenderController.allowInput`): it only ever narrows what a specific
/// peer may ask for, and can never itself widen or bypass the master gate.
///
/// Mirrors `WakeMetadataStore`'s pattern exactly: keyed by the same stable
/// peer install ID `TrustStore` uses, one UserDefaults dictionary, nothing
/// keyed by display name/IP/session. A peer never appears in this store
/// just by connecting — it is added only by an explicit Mac-user toggle
/// (Input settings / device detail), and `ForgetDeviceAction` removes it
/// alongside trust so a revoked or re-paired identity never inherits it.
enum ReceiverInputAuthorizationStore {
    private static let defaultsKey = "receiverInputAuthorization.v1"

    private static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func save(_ peerIDs: Set<String>) {
        UserDefaults.standard.set(Array(peerIDs), forKey: defaultsKey)
    }

    static func isAuthorized(peerID: String) -> Bool {
        load().contains(peerID)
    }

    static func setAuthorized(_ authorized: Bool, peerID: String) {
        var peerIDs = load()
        if authorized {
            peerIDs.insert(peerID)
        } else {
            peerIDs.remove(peerID)
        }
        save(peerIDs)
    }

    static func removeAuthorization(peerID: String) {
        var peerIDs = load()
        peerIDs.remove(peerID)
        save(peerIDs)
    }

    static func allAuthorizedPeerIDs() -> Set<String> {
        load()
    }
}
