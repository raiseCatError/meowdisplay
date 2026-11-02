// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Same per-peer request/confirm/persistence shape as `ExtendDisplayShape.swift`
// — see PROTOCOL.md's `maxFPSRequest`/`maxFPSState`.

import Foundation

/// A receiver's own enforced maximum-FPS preference (PART 2). `enabled ==
/// false` means "defer entirely to profile/receiver-capability/encoder
/// ceilings" — `maxFPS` is only consulted while `enabled`, exactly like
/// `ExtendDisplayShapePreference.useFullDisplay` is only consulted while
/// `shape == .automatic`.
struct ReceiverMaxFPSPreference: Codable, Equatable {
    var enabled: Bool
    var maxFPS: Int

    /// Off, with a starting value of the most conservative real tier
    /// (`60`) so that turning it on without picking anything new still
    /// lands somewhere sane.
    static let standard = ReceiverMaxFPSPreference(enabled: false, maxFPS: 60)

    init(enabled: Bool, maxFPS: Int) {
        self.enabled = enabled
        self.maxFPS = maxFPS
    }

    /// `StreamingFPSPolicy.effectiveFPS`'s `userMaxFPS` argument: `nil`
    /// while disabled, so the caller never has to re-check `enabled` itself.
    var userCeilingFPS: Int? {
        enabled ? maxFPS : nil
    }

    /// Decodes a `maxFPSRequest`/`maxFPSState` wire payload. Fails safe: a
    /// malformed payload yields `nil` rather than propagating a value
    /// neither end can act on consistently — the caller keeps whatever it
    /// already had.
    init?(message: [String: Any]) {
        guard let enabled = message["enabled"] as? Bool,
              let maxFPS = message["maxFPS"] as? Int, maxFPS > 0 else { return nil }
        self.enabled = enabled
        self.maxFPS = maxFPS
    }

    /// Merged into a `{"type": ...}` dict by the caller before sending.
    var wireFields: [String: Any] {
        ["enabled": enabled, "maxFPS": maxFPS]
    }
}

/// What every Maximum FPS picker offers and shows: the Mac's own per-device
/// control, the iPhone app and the Mac receiver. The offered tiers are
/// filtered to what the device can reach right now, while the preference
/// keeps whatever was chosen — 120 stays stored after an Extend shape
/// change makes 120 unreachable, and a value from the wire need not be a
/// tier at all — so the picker's selection is derived, never the raw value.
enum MaxFPSPicker {
    /// The tiers a receiver-side picker offers: the Mac's `maxFPSState`
    /// `availableTiers`, or every tier until it reports some (an empty
    /// report would leave a picker with nothing to select).
    static func tiers(reported: [Int]?) -> [Int] {
        guard let reported, !reported.isEmpty else { return EncoderCapability.supportedFPSTiers }
        return reported
    }

    /// The tag a picker over `tiers` shows for `preference` — always one of
    /// `tiers` when there are any. Display only: the preference itself is
    /// untouched until the user actually picks a tier.
    static func selection(_ preference: ReceiverMaxFPSPreference, among tiers: [Int]) -> Int {
        PickerSelection.ceiling(preference.maxFPS, among: tiers)
    }
}

/// Receiver-side request bookkeeping for max-FPS changes — identical shape
/// to `ExtendShapeRequestState`/`DisplayModeRequestState`: the Mac's state
/// message always wins, and the boolean `confirm` return identifies the
/// single reply that should produce user feedback.
struct MaxFPSRequestState: Equatable {
    private(set) var confirmed: ReceiverMaxFPSPreference?
    private(set) var pending: ReceiverMaxFPSPreference?
    /// Bumped for every accepted request so a late expiry can only retire
    /// the request it was armed for, never a newer one.
    private(set) var pendingGeneration = 0

    mutating func request(_ preference: ReceiverMaxFPSPreference) -> Bool {
        guard pending == nil, preference != confirmed else { return false }
        pending = preference
        pendingGeneration &+= 1
        return true
    }

    mutating func confirm(_ preference: ReceiverMaxFPSPreference) -> Bool {
        let confirmsReceiverRequest = pending == preference
        confirmed = preference
        pending = nil
        return confirmsReceiverRequest
    }

    /// Retires a request the Mac never answered. The last confirmed value
    /// (the real one) is kept.
    mutating func expirePending(generation: Int) -> Bool {
        guard pending != nil, pendingGeneration == generation else { return false }
        pending = nil
        return true
    }

    /// Session teardown: nothing about the Mac's max-FPS state is known
    /// across a deliberate session reset, and no stale request may outlive
    /// it.
    mutating func reset() {
        confirmed = nil
        pending = nil
    }
}

/// Per-peer persistence for the max-FPS preference, keyed by the receiver's
/// stable install id — same convention as `ExtendDisplayShapeStore`, and
/// deliberately a separate UserDefaults key space from it (PART 3: never
/// mixed with Extend shape or TrustStore/security state) so each physical
/// device keeps its own enforcement choice independent of its Extend shape.
enum ReceiverMaxFPSStore {
    static func load(peerID: String) -> ReceiverMaxFPSPreference? {
        guard let raw = UserDefaults.standard.dictionary(forKey: key(peerID)),
              let enabled = raw["enabled"] as? Bool,
              let maxFPS = raw["maxFPS"] as? Int, maxFPS > 0 else { return nil }
        return ReceiverMaxFPSPreference(enabled: enabled, maxFPS: maxFPS)
    }

    static func save(_ preference: ReceiverMaxFPSPreference, peerID: String) {
        UserDefaults.standard.set(["enabled": preference.enabled,
                                    "maxFPS": preference.maxFPS], forKey: key(peerID))
    }

    private static func key(_ peerID: String) -> String { "receiverMaxFPS.\(peerID)" }
}
