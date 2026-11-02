// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Pure, platform-neutral, clock-only — kept separate from `MacSender` so
// it's directly unit-testable without VideoToolbox/ScreenCaptureKit.

import Foundation

/// Gates actual `VTCompressionSessionEncodeFrame` submissions to at most
/// `effectiveFPS` per second — the missing piece the black-screen regression
/// exposed: `SCStreamConfiguration.minimumFrameInterval` and VideoToolbox's
/// `kVTCompressionPropertyKey_ExpectedFrameRate` are both requests/hints, not
/// admission control. MEOW deliberately asks ScreenCaptureKit for roughly
/// double the target rate (capture headroom — see `MacSender.startCapture`),
/// so without this, a fast source can submit encode calls at up to ~2x the
/// intended rate, which is exactly the throughput this whole system exists
/// to stay under.
///
/// A deadline-based fractional limiter, not frame-count modulo/skipping:
/// modulo needs an integer frame count per source cadence to divide evenly,
/// which breaks the moment the target is an arbitrary codec-safe integer FPS
/// (118, 106, 55, ...) rather than a clean divisor of the source rate.
struct FrameRateLimiter {
    private var fps: Int
    private var nextDeadline: TimeInterval?

    init(fps: Int) {
        self.fps = max(fps, 1)
    }

    private var interval: TimeInterval { 1.0 / Double(fps) }

    /// Changes the target rate. Always resyncs (drops any pending deadline)
    /// rather than rescaling it — a rate change means the caller just
    /// rebuilt the encoder at the new rate (`setupEncoder`), so the next
    /// admitted frame should be judged against the NEW interval starting
    /// now, never a deadline computed under the old one.
    mutating func reconfigure(fps: Int) {
        self.fps = max(fps, 1)
        nextDeadline = nil
    }

    /// Forces the next call to admit and resync, with no memory of prior
    /// timing — a new capture generation/reconnect has no continuity with
    /// whatever cadence came before it.
    mutating func reset() {
        nextDeadline = nil
    }

    /// `now`: a monotonic clock reading in seconds (e.g.
    /// `ProcessInfo.processInfo.systemUptime`, the same clock MEOW's other
    /// throttled-log policies already key off) — never a frame/presentation
    /// timestamp, which can repeat, jump, or run on a different clock than
    /// admission is paced on.
    mutating func shouldAdmit(now: TimeInterval) -> Bool {
        guard let deadline = nextDeadline else {
            nextDeadline = now + interval
            return true
        }
        guard now >= deadline else { return false }
        // Advance from the deadline just met, not from `now` — keeps the
        // long-term rate accurate rather than drifting slower every time
        // encode work eats into the gap between admissions. BUT cap the
        // catch-up: after a gap longer than one interval (idle capture,
        // paused video, a slow stall), resync to `now` instead of admitting
        // a burst of "owed" frames back-to-back.
        nextDeadline = (now - deadline > interval) ? now + interval : deadline + interval
        return true
    }
}
