package com.raisecaterror.meowdisplay.core.controls

// The receiver surface's touch arbitration, from iOS/OpenSidecarPhoneApp.swift
// (VideoView, its five gesture recognizers and their delegate rules). UIKit
// runs those recognizers in parallel with the raw touch stream and arbitrates
// through delegate callbacks; Android has no recognizer framework, so this
// one dispatcher reproduces the same outcomes over plain touch batches.
// Platform-free so the JVM tests drive it with synthetic sequences.

import com.raisecaterror.meowdisplay.core.session.ReceiverInputSender
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max

/** One contact in view points (y down). */
data class SurfaceTouch(
    val id: Int,
    val point: CGPoint,
    val kind: Kind = Kind.Finger,
    val pressure: Double = 1.0,
    /** Stylus azimuth and altitude in radians (altitude π/2 = perpendicular). */
    val azimuth: Double = 0.0,
    val altitude: Double = Math.PI / 2,
) {
    enum class Kind { Finger, Stylus, Mouse }
}

enum class SurfaceTouchPhase { Began, Moved, Ended, Cancelled }

/** What the surface asks of its host besides input: local view changes, timers, feedback. */
interface ReceiverSurfaceEffects {
    fun viewportChanged(state: ManualViewportState, animated: Boolean) {}
    fun pollRequested(delaySeconds: Double?) {}
    fun momentumRunning(running: Boolean) {}
    fun smartTouchFeedback(feedback: SmartTouchFeedback) {}
    fun rotationSnapped() {}
    fun activityBegan() {}
    fun activityEnded() {}

    /** A touch sequence meant for the Mac was dropped because input isn't allowed. */
    fun blockedAttempt(maximumTouchCount: Int) {}

    /** Three fingers came down: call [ReceiverSurfaceInput.threeFingerHoldDue] after [delaySeconds]. */
    fun threeFingerHoldArmed(delaySeconds: Double) {}
}

/** Everything the dispatcher reads from preferences and the session, refreshed by the host. */
data class SurfaceInputConfig(
    val allowsInput: Boolean = false,
    val senderPV: Int = 0,
    val videoEnabled: Boolean = true,
    val inputMode: PointerInputMode = PointerInputMode.Direct,
    val trackpadSensitivity: Double = PointerGestureConfig.defaultTrackpadSensitivity,
    val smartTouchEnabled: Boolean = true,
    val localNavigationAllowed: Boolean = true,
    val pinchTarget: ReceiverGestureTarget = ReceiverGestureTarget.Viewport,
    val rotateTarget: ReceiverGestureTarget = ReceiverGestureTarget.Disabled,
    val snapRotation: Boolean = true,
    val invertVerticalScroll: Boolean = true,
    val invertHorizontalScroll: Boolean = true,
    val appGestureCommands: AppGestureCommands = AppGestureCommands(),
    val moveViewActive: Boolean = false,
    val screenReaderRunning: Boolean = false,
)

class ReceiverSurfaceInput(private val input: ReceiverInputSender, private val effects: ReceiverSurfaceEffects) {
    var config = SurfaceInputConfig()
        private set

    /** The un-zoomed picture placement (letterbox, keyboard-open or video-off rect). */
    var baseTransform: RemoteViewportTransform = RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), CGRect.zero)
        private set
    var videoSize: CGSize = CGSize.zero
        private set
    var manualZoom: ManualViewportState = ManualViewportState.identity
        private set
    private var manualZoomMemory: ManualViewportState? = null

    /** The transform every touch, the picture and the cursor use. */
    val currentTransform: RemoteViewportTransform
        get() = VideoInteractionPolicy.viewportTransform(baseTransform, manualZoom, config.videoEnabled)

    private val engine = PointerGestureEngine()
    private val admission = SurfaceTouchAdmission<Int>()
    private val fingers = LinkedHashMap<Int, SurfaceTouch>()
    private val ownedBySystemGesture = mutableSetOf<Int>()
    private var maximumFingerCount = 0
    private var blockedSequence = false

    // R1: two-finger scroll / viewport / App Gesture Commands.
    private var twoFinger: TwoFingerState? = null
    private var twoFingerScrolling = false
    private var lastPan = CGPoint.zero
    private val velocity = ScrollVelocityTracker()
    private var momentum: ScrollMomentumSession? = null
    private var gestureStartZoom = ManualViewportState.identity
    private var gestureBase = CGRect.zero
    private var engagedSnapQuarter: Int? = null
    private var appMagnify = false
    private var appRotate = false
    private var lastAppScale = 1.0
    private var lastAppRotation = 0.0
    private val pinchAccumulator = AppGestureCommandRouting.makePinchAccumulator()
    private val rotationAccumulator = AppGestureCommandRouting.makeRotationAccumulator()

    // R2: two-finger double tap.
    private var twoFingerTap: TapCandidate? = null
    private var lastTwoFingerTapEnd: Pair<Double, CGPoint>? = null

    // R3/R4/R5: system gestures, one emission per gesture.
    private var threeFingerStart: CGPoint? = null
    private val threeFingerOrigins = mutableMapOf<Int, CGPoint>()
    private var threeFingerMaxMovement = 0.0
    private var threeFingerTapPossible = false
    private var threeFingerHoldArmedAt: Double? = null
    private val holdOrigins = mutableMapOf<Int, CGPoint>()
    private var holdMaxMovement = 0.0

    /** Window mode: a stationary three-finger hold opens the window overview instead of reaching the Mac. */
    var threeFingerHoldEnabled = false

    /**
     * True once three fingers have been held still for [THREE_FINGER_HOLD_SECONDS]: the sequence is
     * claimed (no three-finger tap or swipe follows), anything the pointer engine held is released,
     * and the fingers stay local until they lift. The host opens the window overview.
     */
    fun threeFingerHoldDue(now: Double): Boolean {
        val armed = threeFingerHoldArmedAt ?: return false
        if (!threeFingerHoldEnabled || fingers.size != 3 || emission.hasEmitted ||
            holdMaxMovement > ReceiverGesture.threeFingerTapMaximumMovement
        ) {
            threeFingerHoldArmedAt = null
            return false
        }
        if (now - armed < THREE_FINGER_HOLD_SECONDS - 1e-6) return false
        threeFingerHoldArmedAt = null
        if (!emission.claim()) return false
        cancelPointerState()
        fingers.keys.forEach(ownedBySystemGesture::add)
        threeFingerTapPossible = false
        threeFingerStart = null
        return true
    }
    private val spread = ReceiverGestureSpreadSession()
    private val emission = GestureEmissionGate()

    // Move View.
    private val navigation = ViewportNavigationSession()
    private val navigationTouches = LinkedHashMap<Int, SurfaceTouch>()

    // Stylus.
    private var penDown: Int? = null

    private data class TwoFingerState(
        val ids: Pair<Int, Int>,
        val initialMidpoint: CGPoint,
        val initialDistance: Double,
        val initialAngle: Double,
        val session: TwoFingerGestureSession = TwoFingerGestureSession(),
        var began: Boolean = false,
        var midpoint: CGPoint = initialMidpoint,
        var scaleRatio: Double = 1.0,
        var rotationDelta: Double = 0.0,
    )

    private data class TapCandidate(val start: Double, val origins: Map<Int, CGPoint>, var maxMovement: Double = 0.0, var count: Int)

    // MARK: - Host state

    fun updateConfig(next: SurfaceInputConfig) {
        val previous = config
        config = next
        engine.trackpadSensitivity = next.trackpadSensitivity
        engine.smartTouchEnabled = next.smartTouchEnabled && next.senderPV >= SMART_TOUCH_PV
        if (previous.inputMode != next.inputMode) dispatch(engine.setInputMode(next.inputMode))
        if (previous.allowsInput && !next.allowsInput) cancelAll()
        if (previous.videoEnabled != next.videoEnabled) cancelAll()
        if (previous.moveViewActive != next.moveViewActive) {
            navigationTouches.clear()
            navigation.end()
            if (next.moveViewActive) cancelAll()
        }
        requestPoll(0.0)
    }

    /** New geometry for the un-zoomed picture (layout, rotation, keyboard, video size). */
    fun updateBase(base: RemoteViewportTransform, video: CGSize) {
        baseTransform = base
        videoSize = video
    }

    fun resetViewport(animated: Boolean = true) {
        if (manualZoom.isIdentity) return
        manualZoomMemory = manualZoom
        setZoom(ManualViewportState.identity, animated)
        navigation.end()
    }

    /** The Mac's answer to a Smart Touch probe. */
    fun resolveSmartTouchProbe(id: Int, target: SmartTouchTarget?) {
        dispatch(engine.resolveSmartTouchProbe(id, target))
        requestPoll(0.0)
    }

    fun poll(now: Double) {
        dispatch(engine.poll(now))
        requestPoll(now)
    }

    /** One display frame of scroll momentum. */
    fun momentumTick(now: Double) {
        val session = momentum ?: return
        val scale = pointsPerRemotePixel()
        val tick = session.tick(now)
        if (scale == null || videoSize.width <= 0.0) return cancelMomentum()
        if (tick.delta.dx != 0.0 || tick.delta.dy != 0.0) sendScroll(tick.delta.dx / scale, tick.delta.dy / scale)
        if (!tick.alive) cancelMomentum()
    }

    /**
     * Cancels every in-flight interaction and releases what the engine holds
     * (iOS `clearInputStateForPause`): Move View, video on/off, input off,
     * backgrounding. Held keys and modifiers are the input sender's to release.
     */
    fun cancelAll() {
        cancelPointerState()
        twoFinger = null
        twoFingerScrolling = false
        endAppGestures()
        fingers.keys.forEach(ownedBySystemGesture::add)
        penDown?.let { id ->
            penDown = null
            ownedBySystemGesture += id
        }
    }

    // MARK: - Touches

    fun touches(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, time: Double) {
        if (phase == SurfaceTouchPhase.Began) {
            cancelMomentum()
            effects.activityBegan()
        }
        if (config.moveViewActive || (phase != SurfaceTouchPhase.Began && changed.any { it.id in navigationTouches })) {
            routeNavigation(phase, changed)
            if (phase.isEnd && navigationTouches.isEmpty()) effects.activityEnded()
            return
        }
        trackBlockedSequence(phase, changed)
        val ended = phase.isEnd
        for (touch in changed) {
            if (phase == SurfaceTouchPhase.Began) admission.begin(touch.id, admits(touch.point))
        }
        val routed = changed.filter { admission.contains(it.id) }
        val pens = routed.filter { it.kind == SurfaceTouch.Kind.Stylus }
        val fingerTouches = routed.filter { it.kind != SurfaceTouch.Kind.Stylus }

        updateFingerSet(phase, changed.filter { it.kind == SurfaceTouch.Kind.Finger })
        if (config.allowsInput) {
            pens.forEach { handlePen(phase, it) }
            if (penDown == null) {
                val pointerFingers = fingerTouches.filter { it.id !in ownedBySystemGesture }
                handlePointerFingers(phase, pointerFingers, time)
            }
        }
        recognizeMultiFinger(phase, changed.filter { it.kind == SurfaceTouch.Kind.Finger }, time)
        if (ended) {
            changed.forEach { admission.end(it.id) }
            changed.forEach { fingers.remove(it.id) }
            if (fingers.isEmpty()) {
                ownedBySystemGesture.clear()
                emission.reset()
                maximumFingerCount = 0
                effects.activityEnded()
            }
        }
        requestPoll(time)
    }

    /** Stylus hover (no contact): `pencil hover` plus proximity enter/leave. */
    /** A view point (dp) on the Mac's picture, normalized; null outside it. */
    fun remotePoint(view: CGPoint): CGPoint? = currentTransform.remotePoint(view)?.takeIf { it.x in 0.0..1.0 && it.y in 0.0..1.0 }

    fun hover(entering: Boolean?, point: CGPoint) {
        if (!config.allowsInput || config.senderPV < PENCIL_PV) return
        val norm = currentTransform.remotePoint(point) ?: return
        when (entering) {
            true -> input.proximity(true, norm.x, norm.y)
            false -> input.proximity(false, norm.x, norm.y)
            null -> input.pencil("hover", norm.x, norm.y, 0.0, 0.0, Math.PI / 2)
        }
    }

    // MARK: - Admission and blocked attempts

    private fun admits(point: CGPoint): Boolean =
        (config.videoEnabled && config.inputMode != PointerInputMode.Direct) || currentTransform.containsViewPoint(point)

    private fun trackBlockedSequence(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>) {
        if (phase == SurfaceTouchPhase.Began) {
            if (fingers.isEmpty()) blockedSequence = !config.allowsInput
            maximumFingerCount = max(maximumFingerCount, fingers.size + changed.size)
        }
        if (phase.isEnd && blockedSequence && fingers.size <= changed.size) {
            blockedSequence = false
            if (BlockedInputAttemptPolicy.isRemoteIntent(maximumFingerCount, config.moveViewActive)) effects.blockedAttempt(maximumFingerCount)
        }
    }

    private fun updateFingerSet(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>) {
        for (touch in changed) if (!phase.isEnd || touch.id in fingers) fingers[touch.id] = touch
    }

    // MARK: - Pointer engine (pv >= 5)

    private fun handlePointerFingers(phase: SurfaceTouchPhase, touches: List<SurfaceTouch>, time: Double) {
        val samplePhase = when (phase) {
            SurfaceTouchPhase.Began -> PointerTouchSample.Phase.Began
            SurfaceTouchPhase.Moved -> PointerTouchSample.Phase.Moved
            SurfaceTouchPhase.Ended -> PointerTouchSample.Phase.Ended
            SurfaceTouchPhase.Cancelled -> PointerTouchSample.Phase.Cancelled
        }
        for (touch in touches) {
            val norm = currentTransform.remotePoint(touch.point)
            dispatch(engine.handle(PointerTouchSample(touch.id, samplePhase, touch.point, norm, time)))
        }
    }

    private fun dispatch(commands: List<PointerCommand>) {
        for (command in commands) {
            when (command) {
                is PointerCommand.MoveAbsolute -> input.pointerMove(command.x, command.y)
                is PointerCommand.MoveRelative -> pointsPerRemotePixel()?.let { input.pointerMoveRelative(command.dx / it, command.dy / it) }
                is PointerCommand.MouseDown -> {
                    input.pointerDown(command.button.wireValue, command.clickCount)
                    // A right-click chord can't also become a scroll or pinch.
                    if (command.button == PointerButton.Right) twoFinger = null
                }
                is PointerCommand.MouseUp -> input.pointerUp(command.button.wireValue, command.clickCount)
                is PointerCommand.ProbeScrollTarget -> {
                    velocity.reset()
                    if (config.senderPV >= SMART_TOUCH_PV) input.smartTouchProbe(command.id, command.x, command.y)
                }
                is PointerCommand.Scroll -> pointsPerRemotePixel()?.let {
                    sendScroll(command.dx / it, command.dy / it)
                    velocity.record(command.dx, command.dy, lastTime)
                }
                is PointerCommand.ScrollEnded -> if (command.momentum) beginMomentum(lastTime) else {
                    cancelMomentum()
                    velocity.reset()
                }
                is PointerCommand.SmartTouchFeedback -> effects.smartTouchFeedback(command.feedback)
            }
        }
    }

    private var lastTime = 0.0

    private fun requestPoll(now: Double) {
        if (now > 0) lastTime = now
        effects.pollRequested(engine.pollDelay(lastTime))
    }

    /** The engine owns the touches: no recognizer may begin (iOS `pointerEngineOwnsAnchor`). */
    private val pointerEngineOwnsAnchor: Boolean
        get() = engine.mode in OWNING_MODES || (engine.mode == PointerEngineMode.TwoFingerPending && engine.isChordContinuation)

    private fun cancelPointerState() {
        dispatch(engine.reset())
        cancelMomentum()
    }

    /** A system gesture took the touches: they stay consumed until they lift. */
    private fun takeOwnershipAndSend(gesture: ReceiverGesture) {
        if (!config.allowsInput) return
        twoFinger = null
        twoFingerScrolling = false
        ownedBySystemGesture += fingers.keys
        cancelPointerState()
        input.gesture(gesture.raw)
    }

    // MARK: - Multi-finger recognizers

    private fun recognizeMultiFinger(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, time: Double) {
        if (config.screenReaderRunning || changed.isEmpty()) return
        val count = fingers.size
        val systemOwned = ownedBySystemGesture.isNotEmpty()
        recognizeTwoFinger(phase, changed, count, systemOwned, time)
        recognizeTwoFingerDoubleTap(phase, changed, count, systemOwned, time)
        // Local, so it works View Only too; resolved before any three-finger gesture can reach the Mac.
        trackThreeFingerHold(phase, changed, count, time)
        if (!config.allowsInput) return
        recognizeThreeFinger(phase, changed, count)
        recognizeSpread(phase, count)
    }

    private fun recognizeTwoFinger(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, count: Int, systemOwned: Boolean, time: Double) {
        val state = twoFinger
        if (phase == SurfaceTouchPhase.Began) {
            if (state != null) {
                // A third finger: an active gesture is cancelled, an undecided one fails.
                finishTwoFinger(ended = false, time)
                return
            }
            if (count == 2 && !pointerEngineOwnsAnchor && !systemOwned && (config.allowsInput || config.localNavigationAllowed)) {
                val ids = fingers.keys.toList()
                val p0 = fingers.getValue(ids[0]).point
                val p1 = fingers.getValue(ids[1]).point
                twoFinger = TwoFingerState(ids[0] to ids[1], midpoint(p0, p1), hypot(p1.x - p0.x, p1.y - p0.y), atan2(p1.y - p0.y, p1.x - p0.x))
            }
            return
        }
        state ?: return
        if (phase.isEnd) {
            finishTwoFinger(ended = phase == SurfaceTouchPhase.Ended && state.began, time)
            return
        }
        val p0 = fingers[state.ids.first]?.point ?: return
        val p1 = fingers[state.ids.second]?.point ?: return
        val distance = hypot(p1.x - p0.x, p1.y - p0.y)
        state.midpoint = midpoint(p0, p1)
        state.scaleRatio = if (state.initialDistance > 0) distance / state.initialDistance else 1.0
        state.rotationDelta = ManualViewportState.normalizedAngle(atan2(p1.y - p0.y, p1.x - p0.x) - state.initialAngle)
        if (systemOwned) return
        if (!state.began) {
            val intent = state.session.update(state.initialDistance, distance, state.initialMidpoint, state.midpoint, state.rotationDelta)
            if (intent == TwoFingerGestureIntent.Undecided) return
            state.began = true
            beginTwoFinger(state, time)
        } else {
            changeTwoFinger(state, time)
        }
    }

    private fun routes(state: TwoFingerState) = TwoFingerRoutingPolicy.routes(
        state.session.intent, config.allowsInput, config.localNavigationAllowed, config.videoEnabled, config.pinchTarget, config.rotateTarget,
    )

    private fun beginTwoFinger(state: TwoFingerState, time: Double) {
        val routes = routes(state)
        when (state.session.intent) {
            TwoFingerGestureIntent.Scroll -> if (TwoFingerRoute.RemoteScroll in routes) beginScroll(state)
            TwoFingerGestureIntent.ViewportZoomPan -> {
                beginViewportManipulation()
                if (TwoFingerRoute.Viewport in routes) applyViewportPinch(state)
                if (TwoFingerRoute.AppCommands in routes) beginAppGestures(state)
            }
            TwoFingerGestureIntent.Undecided -> Unit
        }
        if (state.session.intent == TwoFingerGestureIntent.Scroll) changeTwoFinger(state, time)
    }

    private fun changeTwoFinger(state: TwoFingerState, time: Double) {
        val routes = routes(state)
        when (state.session.intent) {
            TwoFingerGestureIntent.Scroll -> if (twoFingerScrolling) continueScroll(state, time)
            TwoFingerGestureIntent.ViewportZoomPan -> {
                if (TwoFingerRoute.Viewport in routes) applyViewportPinch(state)
                if (TwoFingerRoute.AppCommands in routes) updateAppGestures(state)
            }
            TwoFingerGestureIntent.Undecided -> Unit
        }
    }

    private fun finishTwoFinger(ended: Boolean, time: Double) {
        val wasScrolling = twoFingerScrolling && twoFinger?.session?.intent == TwoFingerGestureIntent.Scroll
        twoFinger = null
        twoFingerScrolling = false
        if (ended && wasScrolling) beginMomentum(time) else cancelMomentum()
        endAppGestures()
    }

    private fun beginScroll(state: TwoFingerState) {
        if (videoSize.width <= 0.0) return
        cancelMomentum()
        velocity.reset()
        twoFingerScrolling = true
        lastPan = CGPoint.zero
        // Direct Touch places the Mac cursor over the scroll target once; Trackpad never moves it.
        if (config.inputMode.seedsAbsoluteScrollTarget) {
            currentTransform.remotePoint(state.initialMidpoint)?.let { input.touch("moved", it.x, it.y) }
        }
    }

    private fun continueScroll(state: TwoFingerState, time: Double) {
        val scale = pointsPerRemotePixel() ?: return
        val total = CGPoint(state.midpoint.x - state.initialMidpoint.x, state.midpoint.y - state.initialMidpoint.y)
        val step = CGPoint(total.x - lastPan.x, total.y - lastPan.y)
        sendScroll(step.x / scale, step.y / scale)
        velocity.record(step.x, step.y, time)
        lastPan = total
    }

    private fun sendScroll(dx: Double, dy: Double) {
        val (x, y) = ScrollDirectionPolicy.apply(dx, dy, config.invertVerticalScroll, config.invertHorizontalScroll)
        input.scroll(x, y)
    }

    private fun beginMomentum(time: Double) {
        val v = velocity.releaseVelocity(time)
        velocity.reset()
        momentum = v?.let { ScrollMomentumSession.create(it, time) }
        effects.momentumRunning(momentum != null)
    }

    private fun cancelMomentum() {
        if (momentum != null) {
            momentum = null
            effects.momentumRunning(false)
        }
    }

    private fun beginViewportManipulation() {
        twoFingerScrolling = false
        cancelPointerState()
        gestureStartZoom = manualZoom.copy()
        gestureBase = baseTransform.displayedRect
        engagedSnapQuarter = null
    }

    private fun applyViewportPinch(state: TwoFingerState) {
        if (!config.videoEnabled || gestureBase.isEmpty) return
        val scaleRatio = if (config.pinchTarget == ReceiverGestureTarget.Viewport) state.scaleRatio else 1.0
        val rotation = if (config.rotateTarget == ReceiverGestureTarget.Viewport) state.rotationDelta else 0.0
        val next = ManualViewportState.pinching(gestureStartZoom, gestureBase, state.initialMidpoint, state.midpoint, scaleRatio, rotation)
        if (config.rotateTarget == ReceiverGestureTarget.Viewport) {
            val snap = ViewportRotationSnap.snappedAngle(next.rotationRadians, config.snapRotation)
            next.rotationRadians = snap.angle
            val quarter = snap.targetQuarter
            if (quarter == null) {
                engagedSnapQuarter = null
            } else if (quarter != engagedSnapQuarter) {
                engagedSnapQuarter = quarter
                effects.rotationSnapped()
            }
        }
        setZoom(next, animated = false)
    }

    private fun beginAppGestures(state: TwoFingerState) {
        lastAppScale = state.scaleRatio
        lastAppRotation = state.rotationDelta
        if (VideoInteractionPolicy.effectiveTarget(config.pinchTarget, config.videoEnabled) == ReceiverGestureTarget.App) {
            appMagnify = true
            pinchAccumulator.reset()
        }
        if (VideoInteractionPolicy.effectiveTarget(config.rotateTarget, config.videoEnabled) == ReceiverGestureTarget.App) {
            appRotate = true
            rotationAccumulator.reset()
        }
    }

    /** App Gesture Commands: discrete key chords, like iOS (never `nativeAppGesture`). */
    private fun updateAppGestures(state: TwoFingerState) {
        if (appMagnify) {
            val fires = pinchAccumulator.advance(ln(state.scaleRatio / max(lastAppScale, 0.0001)))
            fireAppCommand(if (fires > 0) AppGestureCommandKind.ZoomIn else AppGestureCommandKind.ZoomOut, abs(fires))
            lastAppScale = state.scaleRatio
        }
        if (appRotate) {
            val fires = rotationAccumulator.advance(ManualViewportState.normalizedAngle(state.rotationDelta - lastAppRotation))
            fireAppCommand(if (fires > 0) AppGestureCommandKind.RotateRight else AppGestureCommandKind.RotateLeft, abs(fires))
            lastAppRotation = state.rotationDelta
        }
    }

    private fun fireAppCommand(kind: AppGestureCommandKind, times: Int) {
        val shortcut = config.appGestureCommands.shortcut(kind)
        repeat(times) { input.keyboardPress(shortcut.usage, ControlModifier.ordered(shortcut.modifiers.modifiers).map { it.raw }) }
    }

    private fun endAppGestures() {
        appMagnify = false
        appRotate = false
        pinchAccumulator.reset()
        rotationAccumulator.reset()
    }

    private fun recognizeTwoFingerDoubleTap(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, count: Int, systemOwned: Boolean, time: Double) {
        when (phase) {
            SurfaceTouchPhase.Began -> {
                // Fingers may land together in one batch or one after the other.
                val fresh = fingers.size == changed.size
                val candidate = twoFingerTap
                twoFingerTap = when {
                    count > 2 -> null
                    fresh -> TapCandidate(time, fingers.mapValues { it.value.point }, count = count)
                    candidate != null -> candidate.copy(origins = candidate.origins + changed.associate { it.id to it.point }, count = count)
                    else -> null
                }
            }
            SurfaceTouchPhase.Moved -> twoFingerTap?.let { tap ->
                for (touch in changed) tap.origins[touch.id]?.let { tap.maxMovement = max(tap.maxMovement, distance(it, touch.point)) }
                if (tap.maxMovement > TAP_MAX_MOVEMENT) twoFingerTap = null
            }
            SurfaceTouchPhase.Cancelled -> {
                twoFingerTap = null
                lastTwoFingerTapEnd = null
            }
            SurfaceTouchPhase.Ended -> {
                val tap = twoFingerTap ?: return
                if (fingers.size > changed.size) return
                twoFingerTap = null
                if (tap.count != 2 || time - tap.start > TAP_MAX_DURATION) {
                    lastTwoFingerTapEnd = null
                    return
                }
                val center = centroid(tap.origins.values)
                val previous = lastTwoFingerTapEnd
                if (previous != null && time - previous.first <= DOUBLE_TAP_WINDOW && distance(previous.second, center) <= DOUBLE_TAP_DISTANCE) {
                    lastTwoFingerTapEnd = null
                    if (!systemOwned && config.videoEnabled && config.localNavigationAllowed) toggleViewportResetRestore()
                } else {
                    lastTwoFingerTapEnd = time to center
                }
            }
        }
    }

    private fun toggleViewportResetRestore() {
        val result = ViewportResetRestorePolicy.toggled(manualZoom, manualZoomMemory, baseTransform.displayedRect) ?: return
        manualZoomMemory = result.memory
        setZoom(result.current, animated = true)
    }

    private fun trackThreeFingerHold(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, count: Int, time: Double) {
        if (!threeFingerHoldEnabled) return
        if (phase == SurfaceTouchPhase.Began) {
            if (fingers.size == changed.size) { holdOrigins.clear(); holdMaxMovement = 0.0 }
            changed.forEach { holdOrigins[it.id] = it.point }
            threeFingerHoldArmedAt = if (count == 3 && !emission.hasEmitted) {
                effects.threeFingerHoldArmed(THREE_FINGER_HOLD_SECONDS)
                time
            } else null
            return
        }
        for (touch in changed) holdOrigins[touch.id]?.let { holdMaxMovement = max(holdMaxMovement, distance(it, touch.point)) }
        if (phase.isEnd || count != 3 || holdMaxMovement > ReceiverGesture.threeFingerTapMaximumMovement) threeFingerHoldArmedAt = null
    }

    private fun recognizeThreeFinger(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>, count: Int) {
        if (phase == SurfaceTouchPhase.Began) {
            if (fingers.size == changed.size) {
                threeFingerOrigins.clear()
                threeFingerMaxMovement = 0.0
                threeFingerTapPossible = true
            }
            changed.forEach { threeFingerOrigins[it.id] = it.point }
            if (count > 3) threeFingerTapPossible = false
            threeFingerStart = if (count == 3 && !pointerEngineOwnsAnchor) centroid(fingers.values.map { it.point }) else null
            return
        }
        for (touch in changed) threeFingerOrigins[touch.id]?.let { threeFingerMaxMovement = max(threeFingerMaxMovement, distance(it, touch.point)) }
        if (threeFingerMaxMovement > ReceiverGesture.threeFingerTapMaximumMovement) threeFingerTapPossible = false
        val start = threeFingerStart
        if (phase == SurfaceTouchPhase.Moved && start != null && count == 3) {
            val now = centroid(fingers.values.map { it.point })
            ReceiverGesture.swipe(now.x - start.x, now.y - start.y)?.let { if (emission.claim()) takeOwnershipAndSend(it) }
        }
        if (phase.isEnd && fingers.size <= changed.size) {
            val tapCount = threeFingerOrigins.size
            if (threeFingerTapPossible && phase == SurfaceTouchPhase.Ended && !emission.hasEmitted) {
                ReceiverGesture.threeFingerTap(tapCount, threeFingerMaxMovement)?.let { if (emission.claim()) takeOwnershipAndSend(it) }
            }
            threeFingerStart = null
            threeFingerTapPossible = false
        } else if (phase.isEnd) {
            threeFingerStart = null
        }
    }

    private fun recognizeSpread(phase: SurfaceTouchPhase, count: Int) {
        if (pointerEngineOwnsAnchor && spread.activeTouchCount == null) return
        val points = fingers.values.map { it.point.x to it.point.y }
        val value = ReceiverGestureGeometry.meanPairwiseDistance(points)
        if (value != null) {
            spread.update(count, value)?.let { if (emission.claim()) takeOwnershipAndSend(it) }
        } else if (spread.activeTouchCount != null || count > 5) {
            spread.update(count, Double.NaN)
        }
        if (phase.isEnd && fingers.size <= 1) spread.reset()
    }

    // MARK: - Move View

    private fun routeNavigation(phase: SurfaceTouchPhase, changed: List<SurfaceTouch>) {
        for (touch in changed) if (phase.isEnd) navigationTouches.remove(touch.id) else navigationTouches[touch.id] = touch
        if (!config.videoEnabled || !config.localNavigationAllowed || navigationTouches.isEmpty()) {
            navigation.end()
            return
        }
        val points = navigationTouches.entries.sortedBy { it.key }.take(2).map { it.value.point }
        val allowsRotation = config.rotateTarget == ReceiverGestureTarget.Viewport
        val next = navigation.update(points, manualZoom, baseTransform.displayedRect, allowsZoom = true, allowsRotation = allowsRotation)
        if (allowsRotation) next.rotationRadians = ViewportRotationSnap.snappedAngle(next.rotationRadians, config.snapRotation).angle
        if (next != manualZoom) setZoom(next, animated = false)
    }

    // MARK: - Stylus (pv >= 3; below that it drives the pointer like a finger)

    private fun handlePen(phase: SurfaceTouchPhase, touch: SurfaceTouch) {
        if (config.senderPV < PENCIL_PV) return
        val norm = currentTransform.remotePoint(touch.point) ?: return
        val wirePhase = when (phase) {
            SurfaceTouchPhase.Began -> "down".also { penDown = touch.id }
            SurfaceTouchPhase.Moved -> if (penDown == touch.id) "move" else return
            SurfaceTouchPhase.Ended, SurfaceTouchPhase.Cancelled -> if (penDown == touch.id) "up".also { penDown = null } else return
        }
        input.pencil(wirePhase, norm.x, norm.y, touch.pressure.coerceIn(0.0, 1.0), touch.azimuth, touch.altitude)
    }

    // MARK: - Geometry

    /** View points per Mac pixel under the current zoom (rotation excluded, like iOS). */
    fun pointsPerRemotePixel(): Double? {
        val t = currentTransform
        if (!t.isValid || videoSize.width <= 0.0 || t.remoteCrop.width <= 0.0) return null
        return t.displayedRect.width / (t.remoteCrop.width * videoSize.width)
    }

    private fun setZoom(state: ManualViewportState, animated: Boolean) {
        if (state == manualZoom) return
        manualZoom = state
        effects.viewportChanged(state, animated)
    }

    private val SurfaceTouchPhase.isEnd get() = this == SurfaceTouchPhase.Ended || this == SurfaceTouchPhase.Cancelled

    companion object {
        /** Stationary three-finger hold that opens the window overview (tuned against swipes and taps). */
        const val THREE_FINGER_HOLD_SECONDS = 0.5
        const val SMART_TOUCH_PV = 20
        const val PENCIL_PV = 3
        const val TAP_MAX_MOVEMENT = 10.0
        const val TAP_MAX_DURATION = 0.35
        const val DOUBLE_TAP_WINDOW = 0.35
        const val DOUBLE_TAP_DISTANCE = 40.0

        private val OWNING_MODES = setOf(
            PointerEngineMode.AbsolutePointer, PointerEngineMode.RelativePointerSession, PointerEngineMode.LeftDragHeld,
            PointerEngineMode.ChordPending, PointerEngineMode.RightDragHeld, PointerEngineMode.SmartScroll,
        )

        private fun midpoint(a: CGPoint, b: CGPoint) = CGPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
        private fun distance(a: CGPoint, b: CGPoint) = hypot(a.x - b.x, a.y - b.y)
        private fun centroid(points: Collection<CGPoint>): CGPoint =
            if (points.isEmpty()) CGPoint.zero else CGPoint(points.sumOf { it.x } / points.size, points.sumOf { it.y } / points.size)
    }
}
