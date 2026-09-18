import CoreGraphics

/// A snapshot of the CoreGraphics-reported state for one display ID, plain
/// data so the usability decision below is pure and unit-testable without
/// a live display.
struct DisplayReading: Equatable {
    let id: CGDirectDisplayID
    let isOnline: Bool
    let isActive: Bool
    let boundsEmpty: Bool
    let hasValidMode: Bool
    /// Tri-state mirror of `CGDisplayIsInMirrorSet`'s `boolean_t` (Int32):
    /// 1 = mirrored, 0 = not mirrored, anything else (notably -1 for a
    /// released/nonexistent display) is `.unknown` — see PR #250's fix and
    /// the identical strict check already in `VirtualDisplay.ensureNotMirrored`.
    let mirrorState: MirrorState

    enum MirrorState: Equatable {
        case mirrored
        case notMirrored
        case unknown
    }
}

/// Centralized answer to "is this display (virtual or physical) actually
/// usable right now" — the question upstream PR #219 showed cannot be
/// answered by bounds alone: a torn-down/offline CGVirtualDisplay can keep
/// non-empty bounds while `CGDisplayIsOnline`/`CGDisplayIsActive` are false,
/// and ScreenCaptureKit never sees it. Pure decision logic lives in
/// `evaluate(_:)`; only `reading(for:)`/`isUsable(_:)` touch CoreGraphics.
enum DisplayUsability: Equatable {
    case usable
    case stale(reason: String)

    static func evaluate(_ reading: DisplayReading) -> DisplayUsability {
        guard reading.isOnline else { return .stale(reason: "CGDisplayIsOnline=false") }
        guard reading.isActive else { return .stale(reason: "CGDisplayIsActive=false") }
        guard !reading.boundsEmpty else { return .stale(reason: "bounds empty") }
        guard reading.hasValidMode else { return .stale(reason: "no valid display mode") }
        // `.unknown` (CGDisplayIsInMirrorSet == -1) is a released/unregistered
        // display ID in practice, which the other checks above already catch;
        // it is deliberately NOT treated as "mirrored" here (that would be
        // exactly the #250 regression: an unrelated stale display trips a
        // mirror-set rejection it never actually earned).
        guard reading.mirrorState != .mirrored else { return .stale(reason: "in a system mirror set") }
        return .usable
    }
}

enum DisplayHealth {
    static func reading(for id: CGDirectDisplayID) -> DisplayReading {
        // boolean_t (Int32): 1 = mirrored, 0 = not mirrored, -1 = unknown/
        // unregistered display ID — see the strict `== 1` check this mirrors
        // in `VirtualDisplay.ensureNotMirrored` and PR #250's fix.
        let mirrorState: DisplayReading.MirrorState
        switch CGDisplayIsInMirrorSet(id) {
        case 1: mirrorState = .mirrored
        case 0: mirrorState = .notMirrored
        default: mirrorState = .unknown
        }
        return DisplayReading(
            id: id,
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            boundsEmpty: CGDisplayBounds(id).isEmpty,
            hasValidMode: CGDisplayCopyDisplayMode(id) != nil,
            mirrorState: mirrorState
        )
    }

    static func isUsable(_ id: CGDirectDisplayID) -> Bool {
        DisplayUsability.evaluate(reading(for: id)) == .usable
    }
}
