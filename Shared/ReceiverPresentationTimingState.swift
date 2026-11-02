import Foundation

/// Receiver Swift6: narrow, lock-free owner for `clockOffsetMs` and
/// `photonWindow` — state that used to live directly on `StreamReceiver`.
/// `StreamReceiver.recordPresented`'s per-frame `@Sendable` closure needs
/// both without capturing `self` (the non-Sendable `StreamReceiver`); this
/// class gives them a stable, Sendable-safe home so that closure captures
/// it directly instead — see `recordPresented`'s call site for the same
/// "captured once, locally" pattern already used for `uiSink`/`pipeline`
/// elsewhere in that file.
///
/// A plain synchronous class, not an actor and not lock-backed: unlike
/// `ReceiverVideoTelemetry`, nothing here is written from off `StreamReceiver.
/// queue`, so a lock would be pure per-frame overhead with no correctness
/// benefit. This class changes nothing about either field's existing
/// thread-safety profile — it is not a new isolation invariant, just new
/// storage for the same one:
///
/// - `clockOffsetMs` is written only from `queue` (the "pong" handler in
///   `handleVideoChannelJSON`) but read from both `queue` and `@MainActor`
///   (`sendTouch`/`sendPencil`) with no hop today — an existing benign race
///   on a value that only nudges a few times a session. Moving its storage
///   here does not add or remove that race.
/// - `photonWindow` is exclusively `queue`-confined on every side
///   (`recordPresented`'s append, `resetStreamState`'s reset, and the ~1s/5s
///   stats-window reads/resets in the frame-timing report).
final class ReceiverPresentationTimingState: @unchecked Sendable {
    var clockOffsetMs: Double?
    private var photonWindow: [Double] = []

    /// `queue`-confined: append one photon-latency sample (ms).
    func appendPhoton(_ ms: Double) {
        photonWindow.append(ms)
    }

    /// `queue`-confined: non-destructive read of the current window, for
    /// `percentile(_:_:)` — mirrors the old inline `percentile(photonWindow, _)`.
    func snapshotPhotonWindow() -> [Double] {
        photonWindow
    }

    /// `queue`-confined: clears the rolling window — same cadence as the old
    /// `photonWindow.removeAll(keepingCapacity: true)` call sites (new
    /// session, and the periodic 5s Mac-facing stats report).
    func resetPhotonWindow() {
        photonWindow.removeAll(keepingCapacity: true)
    }
}
