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
///
/// SECURITY INVARIANT: while `InputPolicy.allowsInput()` is true, a remote
/// peer already controls the Mac's screen (per current session/per-peer
/// authorization) and could otherwise drive this exact toggle itself —
/// there is no user-present gesture that distinguishes "the Mac's owner
/// clicked Always Allow" from "the remote peer's own input clicked it". So
/// `setAuthorized` refuses to grant or revoke a *permanent* record while
/// remote input capability is on, enforced here at the store layer (not
/// only by disabling the UI control) so no other call site can bypass it.
/// This never blocks `removeAuthorization`: revoking a permanent grant only
/// narrows capability, exactly like relinquishing a live session, and must
/// always be free to happen (e.g. Forget, or an owner revoking mid-session).
enum ReceiverInputAuthorizationStore {
    private static let defaultsKey = "receiverInputAuthorization.v1"

    private static func load(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func save(_ peerIDs: Set<String>, defaults: UserDefaults) {
        defaults.set(Array(peerIDs), forKey: defaultsKey)
    }

    static func isAuthorized(peerID: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains(peerID)
    }

    /// Returns whether the change was actually applied. Fails (without
    /// touching storage) whenever `InputPolicy.allowsInput(defaults:)` is
    /// true — see the type's security invariant above.
    @discardableResult
    static func setAuthorized(_ authorized: Bool, peerID: String, defaults: UserDefaults = .standard) -> Bool {
        guard !InputPolicy.allowsInput(defaults: defaults) else { return false }
        var peerIDs = load(defaults: defaults)
        if authorized {
            peerIDs.insert(peerID)
        } else {
            peerIDs.remove(peerID)
        }
        save(peerIDs, defaults: defaults)
        return true
    }

    /// Always permitted regardless of Allow Input state — see the type's
    /// security invariant above.
    static func removeAuthorization(peerID: String, defaults: UserDefaults = .standard) {
        var peerIDs = load(defaults: defaults)
        peerIDs.remove(peerID)
        save(peerIDs, defaults: defaults)
    }

    static func allAuthorizedPeerIDs(defaults: UserDefaults = .standard) -> Set<String> {
        load(defaults: defaults)
    }
}
