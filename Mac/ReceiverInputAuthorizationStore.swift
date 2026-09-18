import Foundation

/// Permanent, per-peer policy for how the Mac responds to a receiver's
/// control-request (`allowInputRequest`) — see `PeerInputRequestPolicy` and
/// the request flow in `SenderController.handleInputControlRequested`. This
/// is deliberately NOT a live grant: it only ever decides whether a future
/// request gets a Mac prompt, is auto-granted, or is auto-denied. It can
/// never itself turn a session's input on — every new logical session still
/// starts with effective input OFF regardless of this policy, and the Mac-
/// wide master (`InputPolicy`/`SenderController.allowInput`) still gates on
/// top of it unconditionally.
///
/// Mirrors `WakeMetadataStore`'s pattern exactly: keyed by the same stable
/// peer install ID `TrustStore` uses, one UserDefaults dictionary, nothing
/// keyed by display name/IP/session. A peer never appears in this store
/// just by connecting — an entry is created only by an explicit Mac-owner
/// action (a Settings/device-detail picker, or resolving a control-request
/// prompt with "Never Allow Requests"/"Always Allow This Device"), and
/// `ForgetDeviceAction` removes it alongside trust so a revoked or re-paired
/// identity never inherits it.
///
/// SECURITY INVARIANT (unchanged from the pre-milestone boolean store, now
/// generalized from the single global gate to "any live session"): while
/// ANY connected session currently has effective input, a remote peer could
/// use that session's own screen control to click whatever Mac UI element
/// would otherwise WIDEN a peer's permanent policy to `.alwaysAllow` — there
/// is no user-present gesture that distinguishes "the Mac's owner clicked
/// Always Allow" from "a remote peer's own input clicked it," for ANY peer's
/// row, not only the requesting peer's own. So `setPolicy` refuses to widen
/// to `.alwaysAllow` while `anySessionHasEffectiveInput` is true, enforced
/// here at the store layer (not only by disabling the UI control or the Mac
/// prompt's own button) so no other call site can bypass it. Narrowing
/// (`.ask`/`.neverAllow`) and `removePolicy` are always permitted — they
/// only ever reduce capability, exactly like relinquishing a live session,
/// and must always be free to happen (e.g. Forget, or an owner revoking
/// mid-session).
enum ReceiverInputAuthorizationStore {
    private static let defaultsKey = "receiverInputAuthorization.v2"

    private static func load(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func save(_ policies: [String: String], defaults: UserDefaults) {
        defaults.set(policies, forKey: defaultsKey)
    }

    static func policy(peerID: String, defaults: UserDefaults = .standard) -> PeerInputRequestPolicy {
        guard let raw = load(defaults: defaults)[peerID],
              let policy = PeerInputRequestPolicy(rawValue: raw) else { return .ask }
        return policy
    }

    /// Returns whether the change was actually applied. Fails (without
    /// touching storage) only when widening to `.alwaysAllow` while
    /// `anySessionHasEffectiveInput` is true — see the type's security
    /// invariant above.
    @discardableResult
    static func setPolicy(_ policy: PeerInputRequestPolicy, peerID: String,
                           anySessionHasEffectiveInput: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard policy != .alwaysAllow || !anySessionHasEffectiveInput else { return false }
        var policies = load(defaults: defaults)
        if policy == .ask {
            policies.removeValue(forKey: peerID)
        } else {
            policies[peerID] = policy.rawValue
        }
        save(policies, defaults: defaults)
        return true
    }

    /// Always permitted regardless of any session's effective input — see
    /// the type's security invariant above.
    static func removePolicy(peerID: String, defaults: UserDefaults = .standard) {
        var policies = load(defaults: defaults)
        policies.removeValue(forKey: peerID)
        save(policies, defaults: defaults)
    }

    static func allPolicies(defaults: UserDefaults = .standard) -> [String: PeerInputRequestPolicy] {
        load(defaults: defaults).compactMapValues(PeerInputRequestPolicy.init(rawValue:))
    }
}
