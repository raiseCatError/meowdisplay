package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ScrollMomentum.swift.

import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** Tunable thresholds for remote-scroll momentum/inertia. Grouped so tests and the real recognizer share one source of truth. */
object ScrollMomentumConfig {
    /**
     * Below this release-velocity magnitude (points/sec), momentum never starts - a slow
     * drag-then-release stops dead, matching a real trackpad.
     */
    const val minReleaseVelocity: CGFloat = 60.0

    /** Release velocity is clamped to this magnitude so an extreme swipe can't produce an absurdly long coast. */
    const val maxReleaseVelocity: CGFloat = 4000.0

    /**
     * Exponential decay time constant (seconds). A physical time constant (not a per-frame
     * multiplier) so the feel stays identical regardless of the driving timer's frame rate.
     */
    const val decayTau: TimeInterval = 0.325

    /** Momentum ends once velocity decays below this magnitude (points/sec). */
    const val stopVelocity: CGFloat = 12.0

    /**
     * How far back from release to look when estimating release velocity - averaging a short
     * recent window absorbs sensor jitter and coalesced-touch noise right at the moment of lift.
     */
    const val velocitySampleWindow: TimeInterval = 0.1
}

/** One (dx, dy, time) scroll sample recorded while a live two-finger remote-scroll sequence is active. */
data class ScrollVelocitySample(val dx: CGFloat, val dy: CGFloat, val time: TimeInterval)

/**
 * Accumulates scroll samples during a live two-finger scroll drag and estimates the release
 * velocity from a recent window of them, rather than just the last frame.
 */
class ScrollVelocityTracker {
    var samples: List<ScrollVelocitySample> = emptyList()
        private set

    /**
     * Records one live scroll delta. Old samples outside several times `velocitySampleWindow` are
     * dropped so this never grows unbounded across a long scroll drag.
     */
    fun record(dx: CGFloat, dy: CGFloat, time: TimeInterval) {
        val cutoff = time - ScrollMomentumConfig.velocitySampleWindow * 4
        samples = (samples + ScrollVelocitySample(dx, dy, time)).filter { !(it.time < cutoff) }
    }

    fun reset() {
        samples = emptyList()
    }

    /**
     * Estimated instantaneous velocity (points/sec) at [releaseTime], summed over whatever samples
     * fall within the recent window and divided by the true elapsed span to that release - null if
     * there's nothing usable to estimate from, or the estimate doesn't clear `minReleaseVelocity`.
     */
    fun releaseVelocity(releaseTime: TimeInterval): CGVector? {
        val windowStart = releaseTime - ScrollMomentumConfig.velocitySampleWindow
        val recent = samples.filter { it.time >= windowStart && it.time <= releaseTime }
        val earliest = recent.firstOrNull()?.time ?: return null
        val span = releaseTime - earliest
        if (!(span > 0)) return null
        val sumDx = recent.fold(0.0) { acc, s -> acc + s.dx }
        val sumDy = recent.fold(0.0) { acc, s -> acc + s.dy }
        val vx = sumDx / span
        val vy = sumDy / span
        val magnitude = hypot(vx, vy)
        if (!(magnitude.isFinite() && magnitude >= ScrollMomentumConfig.minReleaseVelocity)) return null
        val clampedMagnitude = min(magnitude, ScrollMomentumConfig.maxReleaseVelocity)
        val scale = clampedMagnitude / magnitude
        return CGVector(vx * scale, vy * scale)
    }
}

/** Result of [ScrollMomentumSession.tick]. */
data class ScrollMomentumTick(val delta: CGVector, val alive: Boolean)

/**
 * A live, decaying remote-scroll momentum phase - one instance per completed scroll release,
 * entirely separate from the pointer/click state machine and from viewport pan (momentum applies
 * only to remote Mac scroll).
 *
 * Exponential-friction decay: `velocity(t) = v0 * exp(-t/tau)`. Each `tick(now)` integrates that
 * continuously over the actual elapsed time since the last tick, so the emitted deltas stay
 * correct regardless of the driving timer's frame rate or jitter.
 */
class ScrollMomentumSession private constructor(
    initialVelocity: CGVector,
    private var lastTime: TimeInterval,
) {
    var velocity: CGVector = initialVelocity
        private set

    /**
     * Advances the simulation to [now]. Returns the scroll delta to send for this tick and whether
     * momentum is still alive afterward - once `alive` is false, the caller MUST stop ticking and
     * discard the session.
     */
    fun tick(now: TimeInterval): ScrollMomentumTick {
        val dt = max(0.0, now - lastTime)
        lastTime = now
        if (!(dt > 0)) return ScrollMomentumTick(CGVector.zero, isAlive)
        val tau = ScrollMomentumConfig.decayTau
        val decay = exp(-dt / tau)
        // Integral of v0*exp(-t/tau) from 0 to dt = v0*tau*(1-decay) - the exact displacement over
        // this tick, so variable tick intervals still produce the physically correct total distance.
        val dx = velocity.dx * tau * (1 - decay)
        val dy = velocity.dy * tau * (1 - decay)
        velocity = CGVector(velocity.dx * decay, velocity.dy * decay)
        return ScrollMomentumTick(CGVector(dx, dy), isAlive)
    }

    private val isAlive: Boolean
        get() = hypot(velocity.dx, velocity.dy) >= ScrollMomentumConfig.stopVelocity

    companion object {
        /**
         * Null if [initialVelocity] doesn't clear `minReleaseVelocity` - no session should ever be
         * created for a slow release; the caller just stops normally instead.
         * (Swift: failable `init?(initialVelocity:at:)`; a factory because a Kotlin constructor can't return null.)
         */
        fun create(initialVelocity: CGVector, time: TimeInterval): ScrollMomentumSession? {
            if (!(hypot(initialVelocity.dx, initialVelocity.dy) >= ScrollMomentumConfig.minReleaseVelocity)) return null
            return ScrollMomentumSession(initialVelocity, time)
        }
    }
}
