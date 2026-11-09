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
    /// the type's security invariant above. Also clears the device's Lock
    /// Screen Control restriction, so Forget leaves nothing behind (a re-paired
    /// identity starts at Ask, with no control at all).
    static func removePolicy(peerID: String, defaults: UserDefaults = .standard) {
        var policies = load(defaults: defaults)
        policies.removeValue(forKey: peerID)
        save(policies, defaults: defaults)
        var lockScreen = lockScreenValues(defaults)
        if lockScreen.removeValue(forKey: peerID) != nil { defaults.set(lockScreen, forKey: lockScreenKey) }
    }

    // MARK: Lock Screen Control (SECURITY.md "Lock screen control")

    /// Derived from the input policy, not a second grant: a device that may control this Mac may
    /// also operate its lock screen (`LockScreenEligibility` still requires the policy and grant:
    /// Always Allow, or Ask with control granted before the lock; never Never Allow), unless the
    /// owner turned Lock Screen Control off for that device. That explicit "off" is the only thing
    /// stored (`false`); nothing stored means it follows the input policy.
    ///
    /// Migration (2.1): this key never shipped in a release, so every device from 2.0 has nothing
    /// stored and its Always Allow carries lock screen control with no new step or prompt. In
    /// pre-release QA builds both values were written only by the owner's own toggle (opt-in
    /// days): a stored `false` stays an explicit restriction; a stored `true` means the same as
    /// nothing stored and is dropped on the next write. Removed by Forget.
    private static let lockScreenKey = "receiverLockScreenControl.v1"

    private static func lockScreenValues(_ defaults: UserDefaults) -> [String: Bool] {
        defaults.dictionary(forKey: lockScreenKey) as? [String: Bool] ?? [:]
    }

    /// The owner turned Lock Screen Control off for this device.
    static func lockScreenControlRestricted(peerID: String, defaults: UserDefaults = .standard) -> Bool {
        lockScreenValues(defaults)[peerID] == false
    }

    /// Not restricted: lock screen control follows the device's input policy.
    static func lockScreenControlAllowed(peerID: String, defaults: UserDefaults = .standard) -> Bool {
        !lockScreenControlRestricted(peerID: peerID, defaults: defaults)
    }

    /// Turning it off is always permitted and stored as an explicit restriction. Lifting a
    /// restriction widens what a device may do, so it's refused while any session has effective
    /// input (the same invariant as `.alwaysAllow`); with no restriction it changes nothing.
    @discardableResult
    static func setLockScreenControlAllowed(_ allowed: Bool, peerID: String, anySessionHasEffectiveInput: Bool,
                                            defaults: UserDefaults = .standard) -> Bool {
        var values = lockScreenValues(defaults)
        if allowed {
            guard values[peerID] == false else {
                // Already follows the policy; drop a legacy explicit `true`.
                if values.removeValue(forKey: peerID) != nil { defaults.set(values, forKey: lockScreenKey) }
                return true
            }
            guard !anySessionHasEffectiveInput else { return false }
            values.removeValue(forKey: peerID)
        } else {
            values[peerID] = false
        }
        defaults.set(values, forKey: lockScreenKey)
        return true
    }

    static func allPolicies(defaults: UserDefaults = .standard) -> [String: PeerInputRequestPolicy] {
        load(defaults: defaults).compactMapValues(PeerInputRequestPolicy.init(rawValue:))
    }
}
