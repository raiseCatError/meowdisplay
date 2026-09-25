// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral — the same model
// drives the Mac Sender picker, the iOS picker, and (eventually) a Mac
// Receiver capability, per PROTOCOL.md's `extendShapeRequest`/`extendShapeState`.

import Foundation

/// User-facing Extend virtual-display shape choices. One shared model for
/// both apps — do NOT fork this into separate Mac/iOS enums.
///
/// There is deliberately no custom width x height editor: the user picks a
/// SHAPE, and `ExtendDisplaySizing` chooses sensible pixel dimensions that
/// preserve it.
enum ExtendDisplayShape: String, Codable, CaseIterable, Identifiable {
    case automatic
    case r16x10 = "16:10"
    case r16x9 = "16:9"
    case r3x2 = "3:2"
    case r4x3 = "4:3"
    case r5x4 = "5:4"
    case r21x9 = "21:9"
    case r32x9 = "32:9"
    case r1x1 = "1:1"

    var id: String { rawValue }

    var title: String {
        self == .automatic ? String(localized: "Automatic") : rawValue
    }

    /// width/height for every explicit ratio; `nil` for `.automatic`, whose
    /// aspect depends on the "Use Full Display" toggle — see
    /// `ExtendDisplayShapePreference.resolvedAspect`.
    var explicitAspect: Double? {
        switch self {
        case .automatic: return nil
        case .r16x10: return 16.0 / 10.0
        case .r16x9: return 16.0 / 9.0
        case .r3x2: return 3.0 / 2.0
        case .r4x3: return 4.0 / 3.0
        case .r5x4: return 5.0 / 4.0
        case .r21x9: return 21.0 / 9.0
        case .r32x9: return 32.0 / 9.0
        case .r1x1: return 1.0
        }
    }

    /// Automatic + Use Full Display OFF resolves here — the default,
    /// Mac-like Extend experience.
    static let defaultAutomaticAspect = 16.0 / 10.0
}

/// The full Extend shape setting: a shape plus Automatic's one dependent
/// option. Kept as a single value (never two independently-persisted
/// booleans/enums) so it travels atomically through persistence and the wire
/// — see PROTOCOL.md's `extendShapeRequest`/`extendShapeState`.
struct ExtendDisplayShapePreference: Codable, Equatable {
    var shape: ExtendDisplayShape
    /// Only meaningful while `shape == .automatic`.
    var useFullDisplay: Bool

    /// Automatic + Use Full Display OFF: the default for every peer that has
    /// never made an explicit choice.
    static let standard = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: false)

    init(shape: ExtendDisplayShape, useFullDisplay: Bool) {
        self.shape = shape
        self.useFullDisplay = useFullDisplay
    }

    /// The aspect ratio (width / height) MEOW should build the Extend
    /// virtual display at, given the receiver's own physical panel aspect
    /// (from `hello.pixelsWide/High`) when it is known.
    func resolvedAspect(receiverPhysicalAspect: Double?) -> Double {
        if let explicit = shape.explicitAspect { return explicit }
        if useFullDisplay, let receiverPhysicalAspect,
           receiverPhysicalAspect.isFinite, receiverPhysicalAspect > 0 {
            return receiverPhysicalAspect
        }
        return ExtendDisplayShape.defaultAutomaticAspect
    }

    /// Decodes an `extendShapeRequest`/`extendShapeState` wire payload.
    /// Fails safe: an unrecognized/malformed `shape` yields `nil` rather
    /// than propagating a value neither end can act on consistently — the
    /// caller keeps whatever it already had.
    init?(message: [String: Any]) {
        guard let rawShape = message["shape"] as? String,
              let shape = ExtendDisplayShape(rawValue: rawShape) else { return nil }
        self.shape = shape
        useFullDisplay = (message["useFullDisplay"] as? Bool) ?? false
    }

    /// Merged into a `{"type": ...}` dict by the caller before sending.
    var wireFields: [String: Any] {
        ["shape": shape.rawValue, "useFullDisplay": useFullDisplay]
    }
}

/// Chooses the Extend virtual display's point dimensions from the
/// receiver's announced physical panel and the resolved aspect ratio. Pure
/// and deterministic — same inputs always produce the same size, so a
/// reconnect (or the periodic HiDPI-mode enforcement in
/// `Mac/VirtualDisplay.swift`) never drifts.
enum ExtendDisplaySizing {
    /// `receiverPixelsWide/High` are `hello.pixelsWide/High` verbatim
    /// (physical pixels, current orientation). Returns points, rounded to
    /// even (the encoder wants even dimensions).
    ///
    /// When `aspect` equals the receiver's own physical aspect (Automatic +
    /// Use Full Display), this reproduces the pre-existing Extend sizing
    /// exactly — halving each axis independently — so today's only Extend
    /// behavior is unchanged, not merely approximated. For any other shape,
    /// the long edge of the receiver's own panel sets the overall scale (so
    /// picking a different ratio doesn't also make the desktop dramatically
    /// bigger or smaller) and the short edge is derived from the ratio.
    static func pointSize(receiverPixelsWide: Int, receiverPixelsHigh: Int, aspect: Double) -> (wide: Int, high: Int) {
        guard receiverPixelsWide > 0, receiverPixelsHigh > 0, aspect.isFinite, aspect > 0 else {
            return (960, 600)   // never reached in practice; a safe 16:10 fallback
        }
        let physicalAspect = Double(receiverPixelsWide) / Double(receiverPixelsHigh)
        if abs(aspect - physicalAspect) < 0.0005 {
            let wide = max((receiverPixelsWide / 2) & ~1, 2)
            let high = max((receiverPixelsHigh / 2) & ~1, 2)
            return (wide, high)
        }
        let longEdge = max(receiverPixelsWide, receiverPixelsHigh)
        let wide = max((longEdge / 2) & ~1, 2)
        let high = max((Int((Double(wide) / aspect).rounded()) & ~1), 2)
        return (wide, high)
    }
}

/// Receiver-side request bookkeeping for Extend shape changes — same shape
/// as `DisplayModeRequestState`: the Mac's state message always wins, and
/// the boolean `confirm` return identifies the single reply that should
/// produce user feedback.
struct ExtendShapeRequestState: Equatable {
    private(set) var confirmed: ExtendDisplayShapePreference?
    private(set) var pending: ExtendDisplayShapePreference?
    /// Bumped for every accepted request so a late expiry can only retire
    /// the request it was armed for, never a newer one.
    private(set) var pendingGeneration = 0

    mutating func request(_ preference: ExtendDisplayShapePreference) -> Bool {
        guard pending == nil, preference != confirmed else { return false }
        pending = preference
        pendingGeneration &+= 1
        return true
    }

    mutating func confirm(_ preference: ExtendDisplayShapePreference) -> Bool {
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

    /// Session teardown: nothing about the Mac's shape is known across a
    /// deliberate session reset, and no stale request may outlive it.
    mutating func reset() {
        confirmed = nil
        pending = nil
    }
}

/// Per-peer persistence for Extend shape, keyed by the receiver's stable
/// install id (`hello.id` / Bonjour TXT `id`) — the same cross-transport
/// identity `Mac/DisplayArrangement.swift` keys arrangement memory on, so
/// each physical device keeps its own shape across reconnects, transports,
/// and other peers (iPhone A -> 16:10, an iPad -> Full Display, etc.)
/// without one global preference bleeding between them.
enum ExtendDisplayShapeStore {
    static func load(peerID: String) -> ExtendDisplayShapePreference? {
        guard let raw = UserDefaults.standard.dictionary(forKey: key(peerID)),
              let rawShape = raw["shape"] as? String,
              let shape = ExtendDisplayShape(rawValue: rawShape) else { return nil }
        return ExtendDisplayShapePreference(shape: shape, useFullDisplay: raw["useFullDisplay"] as? Bool ?? false)
    }

    static func save(_ preference: ExtendDisplayShapePreference, peerID: String) {
        UserDefaults.standard.set(["shape": preference.shape.rawValue,
                                    "useFullDisplay": preference.useFullDisplay], forKey: key(peerID))
    }

    private static func key(_ peerID: String) -> String { "extendShape.\(peerID)" }
}
