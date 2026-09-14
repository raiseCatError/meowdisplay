// Compiled into the iOS target (presentation) and the hostless Mac test
// target (pure-logic coverage — see MacTests/ScrollMomentumTests.swift).
// CoreGraphics + Foundation only, so it stays platform-neutral and UIKit-free.

import CoreGraphics
import Foundation

/// Tunable thresholds for remote-scroll momentum/inertia. Grouped so tests
/// and the real recognizer share one source of truth — see
/// `iOS/OpenSidecarPhoneApp.swift`'s `VideoView` for how this is driven
/// from a live two-finger scroll.
enum ScrollMomentumConfig {
    /// Below this release-velocity magnitude (points/sec), momentum never
    /// starts — a slow drag-then-release stops dead, matching a real
    /// trackpad (PRODUCT RULE: "slow drag + release -> little or no
    /// momentum").
    static let minReleaseVelocity: CGFloat = 60
    /// Release velocity is clamped to this magnitude so an extreme swipe
    /// can't produce an absurdly long coast.
    static let maxReleaseVelocity: CGFloat = 4000
    /// Exponential decay time constant (seconds): how quickly momentum
    /// velocity falls off. Expressed as a physical time constant (not a
    /// per-frame multiplier) so the feel stays identical regardless of the
    /// driving timer's frame rate — see `ScrollMomentumSession.tick`.
    /// Chosen to feel similar to normal trackpad/`UIScrollView` coasting:
    /// noticeable but not floaty or exaggerated.
    static let decayTau: TimeInterval = 0.325
    /// Momentum ends once velocity decays below this magnitude
    /// (points/sec) — the coast has become imperceptible.
    static let stopVelocity: CGFloat = 12
    /// How far back from release to look when estimating release
    /// velocity — averaging a short recent window (rather than just the
    /// final frame) absorbs sensor jitter and coalesced-touch noise right
    /// at the moment of lift.
    static let velocitySampleWindow: TimeInterval = 0.1
}

/// One (dx, dy, time) scroll sample recorded while a live two-finger
/// remote-scroll sequence is active.
struct ScrollVelocitySample: Equatable {
    let dx: CGFloat
    let dy: CGFloat
    let time: TimeInterval
}

/// Accumulates scroll samples during a live two-finger scroll drag and
/// estimates the release velocity from a recent window of them, rather
/// than just the last frame — a single noisy/coalesced sample right at
/// release would otherwise dominate a last-frame-only estimate.
struct ScrollVelocityTracker {
    private(set) var samples: [ScrollVelocitySample] = []

    /// Records one live scroll delta. Old samples outside several times
    /// `velocitySampleWindow` are dropped so this never grows unbounded
    /// across a long scroll drag — only the recent window ever matters
    /// for the eventual release-velocity estimate.
    mutating func record(dx: CGFloat, dy: CGFloat, at time: TimeInterval) {
        samples.append(ScrollVelocitySample(dx: dx, dy: dy, time: time))
        let cutoff = time - ScrollMomentumConfig.velocitySampleWindow * 4
        samples.removeAll { $0.time < cutoff }
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// Estimated instantaneous velocity (points/sec) at `releaseTime`,
    /// summed over whatever samples fall within the recent window and
    /// divided by the true elapsed span to that release — `nil` if there's
    /// nothing usable to estimate from, or the estimate doesn't clear
    /// `minReleaseVelocity` (PRODUCT RULE: a minimum threshold so tiny
    /// movements never coast).
    func releaseVelocity(at releaseTime: TimeInterval) -> CGVector? {
        let windowStart = releaseTime - ScrollMomentumConfig.velocitySampleWindow
        let recent = samples.filter { $0.time >= windowStart && $0.time <= releaseTime }
        guard let earliest = recent.first?.time else { return nil }
        let span = releaseTime - earliest
        guard span > 0 else { return nil }
        let sumDx = recent.reduce(CGFloat(0)) { $0 + $1.dx }
        let sumDy = recent.reduce(CGFloat(0)) { $0 + $1.dy }
        let vx = sumDx / CGFloat(span)
        let vy = sumDy / CGFloat(span)
        let magnitude = hypot(vx, vy)
        guard magnitude.isFinite, magnitude >= ScrollMomentumConfig.minReleaseVelocity else { return nil }
        let clampedMagnitude = min(magnitude, ScrollMomentumConfig.maxReleaseVelocity)
        let scale = clampedMagnitude / magnitude
        return CGVector(dx: vx * scale, dy: vy * scale)
    }
}

/// A live, decaying remote-scroll momentum phase — one instance per
/// completed scroll release, entirely separate from the pointer/click
/// state machine (`PointerGestureEngine`) and from viewport pan (PRODUCT
/// RULE: momentum applies only to remote Mac scroll, never to the local
/// viewport pinch/pan).
///
/// Physically simple exponential-friction decay: `velocity(t) = v0 *
/// exp(-t/tau)`. Each `tick(now:)` integrates that continuously over the
/// actual elapsed wall time since the last tick, so the emitted deltas stay
/// correct regardless of the driving timer's frame rate or jitter — no
/// fixed-refresh-rate assumption anywhere in this type.
final class ScrollMomentumSession {
    private(set) var velocity: CGVector
    private var lastTime: TimeInterval

    /// `nil` if `initialVelocity` doesn't clear `minReleaseVelocity` — no
    /// session should ever be created for a slow release; the caller just
    /// stops normally instead.
    init?(initialVelocity: CGVector, at time: TimeInterval) {
        guard hypot(initialVelocity.dx, initialVelocity.dy) >= ScrollMomentumConfig.minReleaseVelocity else { return nil }
        velocity = initialVelocity
        lastTime = time
    }

    /// Advances the simulation to `now`. Returns the scroll delta to send
    /// for this tick and whether momentum is still alive afterward — once
    /// `alive` is `false`, the caller MUST stop ticking and discard the
    /// session (see `PointerGestureEngine`'s analogous one-shot-then-done
    /// contract for `poll`/state transitions).
    @discardableResult
    func tick(now: TimeInterval) -> (delta: CGVector, alive: Bool) {
        let dt = max(0, now - lastTime)
        lastTime = now
        guard dt > 0 else { return (.zero, isAlive) }
        let tau = ScrollMomentumConfig.decayTau
        let decay = CGFloat(exp(-dt / tau))
        // Integral of v0*exp(-t/tau) from 0 to dt = v0*tau*(1-decay) — the
        // exact displacement over this tick, not a discrete-step
        // approximation, so variable tick intervals (a dropped frame, a
        // slow timer) still produce the physically correct total distance.
        let dx = velocity.dx * CGFloat(tau) * (1 - decay)
        let dy = velocity.dy * CGFloat(tau) * (1 - decay)
        velocity = CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay)
        return (CGVector(dx: dx, dy: dy), isAlive)
    }

    private var isAlive: Bool {
        hypot(velocity.dx, velocity.dy) >= ScrollMomentumConfig.stopVelocity
    }
}
