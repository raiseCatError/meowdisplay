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

extension FrameRateLimiter {
    /// When the next frame may be admitted; nil when one would be admitted now.
    var nextAdmission: TimeInterval? { nextDeadline }

    /// One frame interval at the current rate.
    var frameInterval: TimeInterval { interval }
}

/// Frame admission for one stream: the rate limit plus its trailing edge (#123).
///
/// The limit turns away a frame that comes too soon. While the picture keeps
/// changing that's right, because a newer frame follows within an interval.
/// When the picture stops, the frame turned away was the last change and
/// nothing follows it: ScreenCaptureKit sends no frame for an unchanged
/// screen, and Window view composes only when a window changed. The receiver
/// then shows a stale picture until something else moves. Measured on an M2
/// with a 60 Hz display (2026-11-05): at 30 FPS, 16 of 40 animations ended
/// with their final frame turned away.
///
/// So a frame turned away is held. If nothing newer goes out by one frame
/// interval after the limit's next deadline, the picture has stopped and the
/// held frame goes out then. During continuous motion a newer frame always
/// arrives before that, so pacing and latency stay as they were.
struct FrameAdmission {
    enum Decision: Equatable {
        /// Encode the frame now.
        case send
        /// Keep the frame as the latest one. `retryAt`: arm a retry for that
        /// time (the same clock as `now`); nil when one is already armed.
        case hold(retryAt: TimeInterval?)
    }

    private var limiter: FrameRateLimiter
    /// When the held frame goes out if nothing newer does; nil when nothing is held.
    private(set) var retryAt: TimeInterval?

    init(fps: Int) {
        limiter = FrameRateLimiter(fps: fps)
    }

    var isHolding: Bool { retryAt != nil }

    /// A rate change: the limit resyncs (see `FrameRateLimiter.reconfigure`).
    /// A held frame stays held; its retry admits it at the new rate.
    mutating func reconfigure(fps: Int) {
        limiter.reconfigure(fps: fps)
    }

    /// A new frame, or a held one whose retry came due.
    mutating func offer(now: TimeInterval) -> Decision {
        if limiter.shouldAdmit(now: now) {
            retryAt = nil
            return .send
        }
        return hold(now: now)
    }

    /// The limit admitted a frame but the encoder was too busy to take it:
    /// hold it like one the limit turned away.
    mutating func encoderBusy(now: TimeInterval) -> Decision {
        hold(now: now)
    }

    /// A retry fired: whether a frame is still held. Either way nothing is
    /// held afterwards; offer the frame again to send it (or hold it anew).
    mutating func retryFired() -> Bool {
        defer { retryAt = nil }
        return retryAt != nil
    }

    /// The latest frame went out some other way (a replay), or nothing may go
    /// out any more.
    mutating func clearHold() {
        retryAt = nil
    }

    private mutating func hold(now: TimeInterval) -> Decision {
        guard retryAt == nil else { return .hold(retryAt: nil) }
        let at = max(limiter.nextAdmission ?? now, now) + limiter.frameInterval
        retryAt = at
        return .hold(retryAt: at)
    }
}
