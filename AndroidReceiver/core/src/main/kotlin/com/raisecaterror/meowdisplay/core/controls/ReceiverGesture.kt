package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ReceiverGesture.swift.

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Additive semantic receiver gestures understood by supported senders. */
enum class ReceiverGesture(val raw: String) {
    MissionControl("missionControl"),
    AppExpose("appExpose"),
    NextSpace("nextSpace"),
    PreviousSpace("previousSpace"),
    ShowDesktop("showDesktop"),
    Launchpad("launchpad"),
    Spotlight("spotlight"),

    /** macOS Control Center — a one-tap semantic action (no gesture maps to it). */
    ControlCenter("controlCenter"),

    /** Reveals and focuses the Mac's menu bar. Momentary; one-tap only. */
    MenuBar("menuBar");

    companion object {
        fun of(raw: String?): ReceiverGesture? = entries.firstOrNull { it.raw == raw }

        const val swipeMinimumDistance = 80.0
        const val swipeDominanceRatio = 1.5
        const val threeFingerTapMaximumMovement = 12.0
        const val spreadMinimumChange = 36.0
        const val spreadMinimumRatio = 1.2

        fun swipe(translationX: Double, translationY: Double): ReceiverGesture? {
            val x = abs(translationX)
            val y = abs(translationY)
            if (y >= swipeMinimumDistance && y >= x * swipeDominanceRatio) {
                return if (translationY < 0) MissionControl else AppExpose
            }
            if (x >= swipeMinimumDistance && x >= y * swipeDominanceRatio) {
                return if (translationX < 0) NextSpace else PreviousSpace
            }
            return null
        }

        fun threeFingerTap(touchCount: Int, maximumMovement: Double): ReceiverGesture? {
            if (touchCount != 3 || !maximumMovement.isFinite() || maximumMovement < 0 || maximumMovement > threeFingerTapMaximumMovement) return null
            return Spotlight
        }

        fun spreadGesture(start: Double, current: Double): ReceiverGesture? {
            val change = current - start
            if (abs(change) < spreadMinimumChange || max(start, current) < min(start, current) * spreadMinimumRatio) return null
            return if (change > 0) ShowDesktop else Launchpad
        }

        fun shouldRoute(name: String, inputAllowed: Boolean): Boolean = inputAllowed && of(name) != null
    }
}

/** The receiver surface's custom direct-touch multi-finger recognizers. */
enum class ReceiverMultiFingerRecognizer {
    /** Two-finger remote scroll and local viewport pinch/zoom/pan/rotation. */
    TwoFingerViewport,

    /** Two-finger double-tap viewport reset/restore. */
    ViewportDoubleTap,

    /** Three-finger swipe: Mission Control, App Exposé, Spaces. */
    ThreeFingerSwipe,

    /** Three-finger tap: Spotlight. */
    ThreeFingerTap,

    /** Four/five-finger pinch/spread: Launchpad, Show Desktop. */
    PinchSpread,
}

/**
 * Whether the multi-finger recognizers may run. The screen reader (TalkBack
 * on Android, VoiceOver on iOS) owns multi-finger gestures, so every
 * recognizer steps aside while it runs. Move View also parks them. Remote-only
 * recognizers also need Allow Input; the viewport double tap needs Local View
 * Navigation; the two-finger recognizer needs either.
 */
data class ReceiverMultiFingerGestureGate(
    var voiceOverRunning: Boolean,
    var viewportNavigationActive: Boolean = false,
    var remoteInputAllowed: Boolean = true,
    var localNavigationAllowed: Boolean = true,
) {
    val recognizersEnabled: Boolean get() = !voiceOverRunning && !viewportNavigationActive

    /** Returns whether availability changed. */
    fun update(remoteInputAllowed: Boolean, localNavigationAllowed: Boolean): Boolean {
        if (remoteInputAllowed == this.remoteInputAllowed && localNavigationAllowed == this.localNavigationAllowed) return false
        this.remoteInputAllowed = remoteInputAllowed
        this.localNavigationAllowed = localNavigationAllowed
        return true
    }

    /** Returns whether availability changed. */
    fun updateViewportNavigationActive(viewportNavigationActive: Boolean): Boolean {
        if (viewportNavigationActive == this.viewportNavigationActive) return false
        this.viewportNavigationActive = viewportNavigationActive
        return true
    }

    fun isEnabled(recognizer: ReceiverMultiFingerRecognizer): Boolean {
        if (!recognizersEnabled) return false
        return when (recognizer) {
            ReceiverMultiFingerRecognizer.TwoFingerViewport -> remoteInputAllowed || localNavigationAllowed
            ReceiverMultiFingerRecognizer.ViewportDoubleTap -> localNavigationAllowed
            ReceiverMultiFingerRecognizer.ThreeFingerSwipe, ReceiverMultiFingerRecognizer.ThreeFingerTap,
            ReceiverMultiFingerRecognizer.PinchSpread -> remoteInputAllowed
        }
    }

    /** Returns whether availability changed (the screen reader toggled at runtime). */
    fun updateVoiceOverRunning(voiceOverRunning: Boolean): Boolean {
        if (voiceOverRunning == this.voiceOverRunning) return false
        this.voiceOverRunning = voiceOverRunning
        return true
    }
}

/**
 * Screen-edge system gestures are claimed (Android: system gesture exclusion
 * rects) only while the remote surface is shown, input may reach the Mac,
 * Prefer MeowDisplay Gestures is on, and the screen reader is off.
 */
object ReceiverScreenEdgePolicy {
    fun defersScreenEdges(
        surfaceShown: Boolean,
        inputAllowed: Boolean,
        preferMeowDisplayGestures: Boolean = true,
        voiceOverRunning: Boolean = false,
    ): Boolean = surfaceShown && inputAllowed && preferMeowDisplayGestures && !voiceOverRunning
}

/** Prefer MeowDisplay Gestures' effect on the platform's three-finger editing interactions over the surface. */
object ReceiverEditingInteractionPolicy {
    fun suppressesEditingInteractions(preferMeowDisplayGestures: Boolean): Boolean = preferMeowDisplayGestures
}

/** The mean of every fingertip pair: a symmetric pinch/spread measure that doesn't assume a thumb. */
object ReceiverGestureGeometry {
    fun meanPairwiseDistance(points: List<Pair<Double, Double>>): Double? {
        if (points.size !in 4..5) return null
        var total = 0.0
        var pairs = 0
        for (first in points.indices) {
            for (second in first + 1 until points.size) {
                val dx = points[first].first - points[second].first
                val dy = points[first].second - points[second].second
                total += sqrt(dx * dx + dy * dy)
                pairs += 1
            }
        }
        return total / pairs
    }
}

/**
 * Tracks one pinch/spread across 4↔5 contact changes. Each contact-count
 * segment has its own baseline so adding or lifting a finger doesn't look
 * like a sudden spread change.
 */
class ReceiverGestureSpreadSession {
    var activeTouchCount: Int? = null
        private set
    var hasEmitted = false
        private set
    var isCancelled = false
        private set
    private var segmentStartSpread: Double? = null
    private var lastSpread: Double? = null
    private var accumulatedChange = 0.0
    private var accumulatedLogRatio = 0.0

    fun update(touchCount: Int, spread: Double): ReceiverGesture? {
        if (isCancelled) return null
        if (touchCount !in 4..5 || !spread.isFinite() || spread < 0) {
            if (activeTouchCount != null || touchCount > 5) isCancelled = true
            activeTouchCount = null
            return null
        }
        if (hasEmitted) {
            activeTouchCount = touchCount
            return null
        }
        val active = activeTouchCount
        val segmentStart = segmentStartSpread
        val last = lastSpread
        if (active == null || segmentStart == null || last == null) {
            activeTouchCount = touchCount
            segmentStartSpread = spread
            lastSpread = spread
            return null
        }
        if (active != touchCount) {
            accumulate(segmentStart, last)
            activeTouchCount = touchCount
            segmentStartSpread = spread
            lastSpread = spread
            return null
        }
        lastSpread = spread
        val totalChange = accumulatedChange + spread - segmentStart
        val totalLogRatio = accumulatedLogRatio + logRatio(segmentStart, spread)
        val minimumLogRatio = ln(ReceiverGesture.spreadMinimumRatio)
        if (abs(totalChange) < ReceiverGesture.spreadMinimumChange) return null
        if (totalChange > 0 && totalLogRatio >= minimumLogRatio) {
            hasEmitted = true
            return ReceiverGesture.ShowDesktop
        }
        if (totalChange < 0 && totalLogRatio <= -minimumLogRatio) {
            hasEmitted = true
            return ReceiverGesture.Launchpad
        }
        return null
    }

    fun reset() {
        activeTouchCount = null
        hasEmitted = false
        isCancelled = false
        segmentStartSpread = null
        lastSpread = null
        accumulatedChange = 0.0
        accumulatedLogRatio = 0.0
    }

    private fun accumulate(start: Double, end: Double) {
        accumulatedChange += end - start
        accumulatedLogRatio += logRatio(start, end)
    }

    // Spread can be zero only when every contact coincides; clamping keeps the ratio finite.
    private fun logRatio(start: Double, end: Double): Double = ln(max(end, 0.001) / max(start, 0.001))
}

class GestureEmissionGate {
    var hasEmitted = false
        private set

    fun claim(): Boolean {
        if (hasEmitted) return false
        hasEmitted = true
        return true
    }

    fun reset() {
        hasEmitted = false
    }
}

enum class ReceiverTouchOwnershipAction { SendCancellation, DiscardPendingPress }

object ReceiverTouchOwnership {
    /** Release a posted synthetic down before discarding local pending state. */
    fun cancellationActions(downWasSent: Boolean): List<ReceiverTouchOwnershipAction> =
        if (downWasSent) {
            listOf(ReceiverTouchOwnershipAction.SendCancellation, ReceiverTouchOwnershipAction.DiscardPendingPress)
        } else {
            listOf(ReceiverTouchOwnershipAction.DiscardPendingPress)
        }
}
