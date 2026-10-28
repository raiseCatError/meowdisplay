package com.raisecaterror.meowdisplay.android.receiver

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import com.raisecaterror.meowdisplay.android.controls.ReceiverControlStore
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ControlActionOperation
import com.raisecaterror.meowdisplay.core.controls.ControlActionPlan
import com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent
import com.raisecaterror.meowdisplay.core.controls.ControlHapticPolicy
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.InputAutoRequestPolicy
import com.raisecaterror.meowdisplay.core.controls.KeyboardChordEvent
import com.raisecaterror.meowdisplay.core.controls.ManualViewportState
import com.raisecaterror.meowdisplay.core.controls.ReceiverGesture
import com.raisecaterror.meowdisplay.core.controls.ReceiverGestureTarget
import com.raisecaterror.meowdisplay.core.controls.ReceiverInputPrompt
import com.raisecaterror.meowdisplay.core.controls.ReceiverSurfaceEffects
import com.raisecaterror.meowdisplay.core.controls.ReceiverSurfaceInput
import com.raisecaterror.meowdisplay.core.controls.ReceiverUIPreferenceUpdate
import com.raisecaterror.meowdisplay.core.controls.RemoteKeyboardBridge
import com.raisecaterror.meowdisplay.core.controls.RemoteViewportCalculator
import com.raisecaterror.meowdisplay.core.controls.RemoteViewportTransform
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.SmartTouchFeedback
import com.raisecaterror.meowdisplay.core.controls.SmartTouchHapticPolicy
import com.raisecaterror.meowdisplay.core.controls.SmartTouchTarget
import com.raisecaterror.meowdisplay.core.controls.SurfaceInputConfig
import com.raisecaterror.meowdisplay.core.controls.VideoOffSurfaceGeometry
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/** What the receiver screen draws besides the controls. Geometry in dp. */
data class ReceiverViewState(
    val transform: RemoteViewportTransform = RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), CGRect.zero),
    val videoSize: CGSize = CGSize.zero,
    val videoEnabled: Boolean = true,
    val paused: Boolean = false,
    val cursor: CursorState = CursorState(),
    val inputState: InputWireState = InputWireState.Off,
    val inputAllowed: Boolean = false,
    val senderPV: Int = 0,
    val prompt: ReceiverInputPrompt.Kind? = null,
    val keyboardRequested: Boolean = false,
    val inputResetGeneration: Int = 0,
)

data class CursorState(val x: Double = 0.5, val y: Double = 0.5, val visible: Boolean = false, val sprite: CursorSprite? = null)

/** `cursorImg`: the sprite and its size normalized to the display, anchor normalized within itself. */
data class CursorSprite(val bitmap: Bitmap, val normalizedWidth: Double, val normalizedHeight: Double, val anchorX: Double, val anchorY: Double)

sealed interface ReceiverHaptic {
    data class Control(val event: ControlHapticEvent) : ReceiverHaptic
    data class SmartTouch(val feedback: SmartTouchFeedback) : ReceiverHaptic
    data object RotationSnap : ReceiverHaptic
}

/**
 * The receiver surface's brain on Android (the roles of iOS ReceiverScreen,
 * VideoView's coordinator and ReceiverControlOverlay's session hooks): it
 * feeds the touch dispatcher and keyboard bridge, mirrors the Mac's input
 * state, and releases held input whenever it must. Main thread only;
 * session events are hopped onto it.
 */
class ReceiverController(
    private val media: MediaController,
    val store: ReceiverControlStore,
    /** The decoded picture's size in pixels, once known. */
    private val decodedSize: StateFlow<Pair<Int, Int>?>,
) {
    private val main = Handler(Looper.getMainLooper())
    private val session: ReceiverSession get() = media.session
    private val state = MutableStateFlow(ReceiverViewState())
    val view: StateFlow<ReceiverViewState> = state.asStateFlow()
    private val haptics = MutableSharedFlow<ReceiverHaptic>(extraBufferCapacity = 16)
    val hapticEvents: SharedFlow<ReceiverHaptic> = haptics.asSharedFlow()

    private var chord: Set<ControlModifier> = emptySet()
    private val prompt = ReceiverInputPrompt()
    private val promptTick = Runnable { tickPrompt() }
    private var retainedVideo: CGSize? = null
    private var runnerGeneration = 0

    /** Set by the screen: the input view whose timers the dispatcher drives. */
    var inputView: ReceiverInputView? = null

    val surface: ReceiverSurfaceInput = ReceiverSurfaceInput(session.input, object : ReceiverSurfaceEffects {
        override fun viewportChanged(state: ManualViewportState, animated: Boolean) {
            publishTransform()
        }
        override fun pollRequested(delaySeconds: Double?) {
            inputView?.schedulePoll(delaySeconds)
        }
        override fun momentumRunning(running: Boolean) {
            inputView?.setMomentumRunning(running)
        }
        override fun smartTouchFeedback(feedback: SmartTouchFeedback) {
            val p = store.current
            if (p.hapticsEnabled && SmartTouchHapticPolicy.isEnabled(p.hapticsEnabled, p.smartTouchLongPressHapticEnabled)) haptics.tryEmit(ReceiverHaptic.SmartTouch(feedback))
        }
        override fun rotationSnapped() {
            if (store.current.hapticsEnabled) haptics.tryEmit(ReceiverHaptic.RotationSnap)
        }
        override fun activityBegan() = store.beginAutoHideActivity()
        override fun activityEnded() = store.scheduleAutoHide()
        override fun blockedAttempt(maximumTouchCount: Int) = noteBlockedAttempt()
    })

    val keyboard = RemoteKeyboardBridge(session.input) { chord }

    init {
        media.controlEvents = { event -> main.post { onSessionEvent(event) } }
        store.onInputResetRequested = { releaseHeldInput() }
        refreshConfig()
    }

    // MARK: - Session

    private fun onSessionEvent(event: SessionEvent) {
        when (event) {
            is SessionEvent.InputState -> {
                store.applySessionInputState(event.state)
                prompt.inputStateChanged(event.state, now())
                if (!event.allowed) {
                    keyboard.releaseHeldKeys()
                    setKeyboardRequested(false)
                }
                update { it.copy(inputState = event.state) }
                refreshConfig()
                schedulePromptTick()
            }
            SessionEvent.InputReset -> update { it.copy(inputResetGeneration = it.inputResetGeneration + 1) }
            is SessionEvent.Admitted -> {
                prompt.setSessionLive(true)
                store.resetAutoHide()
                refreshConfig()
            }
            is SessionEvent.Connected, is SessionEvent.Disconnected, SessionEvent.AdmissionWithdrawn -> {
                prompt.setSessionLive(false)
                surface.cancelAll()
                keyboard.releaseHeldKeys()
                store.setMoveViewActive(false)
                retainedVideo = null
                setKeyboardRequested(false)
                update { it.copy(cursor = CursorState(), prompt = null, inputResetGeneration = it.inputResetGeneration + 1) }
                refreshConfig()
            }
            is SessionEvent.VideoState -> {
                if (event.width != null && event.height != null) retainedVideo = CGSize(event.width!!.toDouble(), event.height!!.toDouble())
                update { it.copy(videoEnabled = event.enabled) }
                if (!event.enabled) store.setMoveViewActive(false)
                refreshConfig()
            }
            is SessionEvent.DisplayPaused -> {
                if (event.paused) {
                    surface.cancelAll()
                    store.setMoveViewActive(false)
                }
                update { it.copy(paused = event.paused) }
                refreshConfig()
            }
            is SessionEvent.Cursor -> update { it.copy(cursor = it.cursor.copy(x = event.x, y = event.y, visible = event.visible)) }
            is SessionEvent.Control -> onControl(event)
            else -> Unit
        }
    }

    private fun onControl(event: SessionEvent.Control) {
        val body = event.body
        when (event.type) {
            "receiverUI" -> ReceiverUIPreferenceUpdate.parse(body)?.let { store.applyRemote(it); refreshConfig() }
            "smartTouchProbeResult" -> {
                val id = (body["id"] as? JsonPrimitive)?.intOrNull ?: return
                val target = when {
                    (body["scrollable"] as? JsonPrimitive)?.booleanOrNull == true -> SmartTouchTarget.Scroll
                    (body["windowDrag"] as? JsonPrimitive)?.booleanOrNull == true -> SmartTouchTarget.WindowDrag
                    else -> null
                }
                surface.resolveSmartTouchProbe(id, target)
            }
            "cursorImg" -> decodeSprite(body)?.let { sprite -> update { it.copy(cursor = it.cursor.copy(sprite = sprite)) } }
        }
    }

    private fun decodeSprite(body: kotlinx.serialization.json.JsonObject): CursorSprite? {
        fun num(key: String) = (body[key] as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() }
        val png = (body["png"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        if (png.length > MAX_CURSOR_BASE64) return null
        val bytes = runCatching { Base64.decode(png, Base64.DEFAULT) }.getOrNull() ?: return null
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val nw = num("nw")?.takeIf { it > 0 && it <= 1 } ?: return null
        val nh = num("nh")?.takeIf { it > 0 && it <= 1 } ?: return null
        return CursorSprite(bitmap, nw, nh, (num("ax") ?: 0.0).coerceIn(0.0, 1.0), (num("ay") ?: 0.0).coerceIn(0.0, 1.0))
    }

    // MARK: - Configuration and geometry

    /** Rebuilds what the dispatcher reads from preferences, the session and transient state. */
    fun refreshConfig() {
        val p = store.current
        val t = store.transient.value
        val allowed = session.inputAllowed && p.allowInput
        surface.updateConfig(
            SurfaceInputConfig(
                allowsInput = allowed,
                senderPV = session.senderProtocolVersion ?: 0,
                videoEnabled = state.value.videoEnabled,
                inputMode = p.inputMode,
                trackpadSensitivity = p.trackpadSensitivity,
                smartTouchEnabled = p.smartTouchEnabled,
                localNavigationAllowed = p.allowLocalViewNavigation,
                pinchTarget = p.pinchTarget,
                // A SurfaceView can't rotate the picture, so the view never rotates on Android
                // (App rotation still sends its key chords). See the parity notes.
                rotateTarget = if (p.rotateTarget == ReceiverGestureTarget.Viewport) ReceiverGestureTarget.Disabled else p.rotateTarget,
                snapRotation = p.snapRotation,
                invertVerticalScroll = p.invertVerticalScroll,
                invertHorizontalScroll = p.invertHorizontalScroll,
                appGestureCommands = p.appGestureCommands,
                moveViewActive = t.moveViewActive,
                screenReaderRunning = screenReaderRunning,
            ),
        )
        update { it.copy(inputAllowed = allowed, senderPV = session.senderProtocolVersion ?: 0) }
    }

    var screenReaderRunning = false
        set(value) {
            if (field != value) {
                field = value
                refreshConfig()
            }
        }

    /**
     * New placement inputs from the screen: the window (dp), where the picture
     * may go (the Strip canvas or the whole window), the keyboard, and what
     * the video-off surface must avoid.
     */
    fun layout(
        window: CGRect,
        canvas: CGRect,
        keyboardVisibleRect: CGRect?,
        safeInsets: ControlSafeInsets,
        occupiedControlFrames: List<CGRect>,
        divisions: List<CGRect>,
    ) {
        val video = videoSize()
        val base = when {
            video.width <= 0 || canvas.isEmpty -> RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), CGRect.zero)
            !state.value.videoEnabled -> RemoteViewportTransform(
                CGRect(0.0, 0.0, 1.0, 1.0),
                VideoOffSurfaceGeometry.interactionRect(
                    window, safeInsets, occupiedControlFrames, window.height > window.width, store.current.inputMode, video, divisions,
                ),
            )
            keyboardVisibleRect != null -> RemoteViewportCalculator.keyboardOpen(canvas, video, keyboardVisibleRect, null, zoomEnabled = true)
            else -> RemoteViewportCalculator.normal(canvas, video)
        }
        surface.updateBase(base, video)
        publishTransform()
    }

    private fun videoSize(): CGSize = decodedSize.value?.let { CGSize(it.first.toDouble(), it.second.toDouble()) } ?: retainedVideo ?: CGSize.zero

    private fun publishTransform(): Unit = update { it.copy(transform = surface.currentTransform, videoSize = surface.videoSize) }

    // MARK: - Controls

    /** Runs a one-tap action (iOS OneTapActionRunner): immediate unless it has pauses, every step re-checking input. */
    fun perform(item: ShortcutItem) {
        val operations = ControlActionPlan.operations(item.action)
        if (operations.isEmpty() || !session.inputAllowed) return
        val generation = runnerGeneration
        var delay = 0L
        for (operation in operations) {
            if (operation is ControlActionOperation.Pause) {
                delay += operation.milliseconds
                continue
            }
            val run = Runnable { if (generation == runnerGeneration && session.inputAllowed) performOperation(operation) }
            if (delay == 0L) run.run() else main.postDelayed(run, delay)
        }
    }

    private fun performOperation(operation: ControlActionOperation) {
        val input = session.input
        when (operation) {
            is ControlActionOperation.Press -> input.keyboardPress(operation.usage, operation.modifiers)
            is ControlActionOperation.Key ->
                if (operation.event.phase == KeyboardChordEvent.Phase.Down) input.keyboardDown(operation.event.usage, operation.event.modifiers)
                else input.keyboardUp(operation.event.usage, operation.event.modifiers)
            is ControlActionOperation.Gesture -> if (ReceiverGesture.of(operation.name) != null) input.gesture(operation.name)
            is ControlActionOperation.Pause -> Unit
        }
    }

    fun modifier(name: String, down: Boolean) {
        session.input.modifier(name, down)
    }

    fun chordChanged(modifiers: Set<ControlModifier>) {
        chord = modifiers
        store.projectChord(modifiers)
    }

    fun haptic(event: ControlHapticEvent) {
        if (ControlHapticPolicy.shouldPlay(event, store.current.hapticsEnabled)) haptics.tryEmit(ReceiverHaptic.Control(event))
    }

    fun setKeyboardRequested(requested: Boolean) {
        val wanted = requested && session.inputAllowed && (session.senderProtocolVersion ?: 0) >= 4
        inputView?.keyboardRequested = wanted
        update { it.copy(keyboardRequested = wanted) }
    }

    fun toggleMoveView() {
        store.setMoveViewActive(!store.transient.value.moveViewActive)
        refreshConfig()
    }

    fun resetViewport() = surface.resetViewport()

    /**
     * Releases everything held for a local reason (tray off, a profile or
     * pointer-model change, input turned off, backgrounding): pending one-tap
     * steps stop, the engine lets go, physical keys come up, then the sender
     * releases the rest and sends `keyboard cancel`.
     */
    fun releaseHeldInput() {
        runnerGeneration++
        surface.cancelAll()
        keyboard.releaseHeldKeys()
        session.input.releaseAll()
        update { it.copy(inputResetGeneration = it.inputResetGeneration + 1) }
        refreshConfig()
    }

    /** The sender the input view's mouse wheel uses; everything still passes the session gate. */
    fun surfaceSender() = session.input

    /** The overlay's requests, routed to the session gate, the store and the screen. */
    fun overlayActions(onOpenSettings: () -> Unit, onOccupied: (List<CGRect>) -> Unit, onCanvas: (CGRect?) -> Unit): OverlayActions =
        object : OverlayActions {
            override fun modifier(name: String, down: Boolean) = this@ReceiverController.modifier(name, down)
            override fun perform(item: ShortcutItem) = this@ReceiverController.perform(item)
            override fun press(usage: Int) = keyboard.press(usage)
            override fun toggleKeyboard() = setKeyboardRequested(!state.value.keyboardRequested)
            override fun dismissKeyboard() = setKeyboardRequested(false)
            override fun openSettings() {
                releaseHeldInput()
                onOpenSettings()
            }
            override fun toggleMoveView() = this@ReceiverController.toggleMoveView()
            override fun resetViewport() = this@ReceiverController.resetViewport()
            override fun haptic(event: ControlHapticEvent) = this@ReceiverController.haptic(event)
            override fun occupiedFramesChanged(frames: List<CGRect>) = onOccupied(frames)
            override fun canvasChanged(canvas: CGRect?) = onCanvas(canvas)
            override fun chordChanged(modifiers: Set<ControlModifier>) = this@ReceiverController.chordChanged(modifiers)
        }

    // MARK: - Input prompt

    private fun noteBlockedAttempt() {
        val effects = prompt.blockedAttempt(now(), store.transient.value.userTurnedOffInput, InputAutoRequestPolicy.shouldAutoRequest(peerOptedIn = false))
        performPromptEffects(effects)
        schedulePromptTick()
    }

    fun requestInputTapped() {
        performPromptEffects(prompt.requestTapped(now()))
        schedulePromptTick()
    }

    /** Settings → Input: ask for control (or give it back). The Mac decides; nothing is granted locally. */
    fun requestInput(allowed: Boolean) {
        store.noteInputTurnedOffByUser(!allowed)
        if (!allowed) releaseHeldInput()
        session.requestAllowInput(allowed)
    }

    private fun performPromptEffects(effects: List<ReceiverInputPrompt.Effect>) {
        if (effects.contains(ReceiverInputPrompt.Effect.SendRequest)) {
            store.noteInputTurnedOffByUser(false)
            session.requestAllowInput(true)
        }
    }

    private fun schedulePromptTick() {
        update { it.copy(prompt = prompt.kind.takeIf { prompt.isVisible(now()) }) }
        main.removeCallbacks(promptTick)
        if (prompt.kind != null) main.postDelayed(promptTick, ((prompt.visibleUntil - now()) * 1000).toLong().coerceAtLeast(50) + 50)
    }

    private fun tickPrompt() {
        prompt.tick(now())
        schedulePromptTick()
    }

    private fun update(change: (ReceiverViewState) -> ReceiverViewState) {
        state.value = change(state.value)
    }

    private fun now(): Double = SystemClock.uptimeMillis() / 1000.0

    companion object {
        /** `cursorImg.png` is kept under 24000 bytes before encoding (PROTOCOL.md 6.2). */
        const val MAX_CURSOR_BASE64 = 64_000
    }
}
