package com.raisecaterror.meowdisplay.android.receiver

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.Choreographer
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.os.Build
import android.view.InputDevice
import android.view.PointerIcon
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.HardwareMouse
import com.raisecaterror.meowdisplay.core.controls.RemoteKeyboardBridge
import com.raisecaterror.meowdisplay.core.controls.ReceiverSurfaceInput
import com.raisecaterror.meowdisplay.core.controls.SurfaceTouch
import com.raisecaterror.meowdisplay.core.controls.SurfaceTouchPhase
import com.raisecaterror.meowdisplay.core.session.ReceiverInputSender
import kotlin.math.PI

/**
 * The receiver surface's input layer, over the picture (iOS VideoView's raw
 * touches and keyboard responder). Everything is measured in dp, the
 * Android counterpart of iOS points, so the ported thresholds (10 pt slop,
 * 12 pt three-finger tap, …) mean the same physical distance.
 *
 * It decides nothing itself: touches go to [ReceiverSurfaceInput], typing to
 * [RemoteKeyboardBridge], and both send only through the session's gate.
 */
@SuppressLint("ViewConstructor")
class ReceiverInputView(
    context: Context,
    private val surface: ReceiverSurfaceInput,
    private val keyboard: RemoteKeyboardBridge,
    private val sender: ReceiverInputSender,
    private val inputAllowed: () -> Boolean,
    /** Hide Android's pointer over the picture (the Mac's cursor is drawn). Off in Window mode: one workspace pointer. */
    private val hideSystemPointer: () -> Boolean = inputAllowed,
) : View(context) {
    private val density get() = resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())
    private val pollRunnable = Runnable { surface.poll(now()) }
    private var momentumRunning = false
    private val momentumFrame = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!momentumRunning) return
            surface.momentumTick(now())
            if (momentumRunning) Choreographer.getInstance().postFrameCallback(this)
        }
    }

    /** True while the software keyboard is wanted; the IME connection exists only then. */
    var keyboardRequested = false
        set(value) {
            if (field == value) return
            field = value
            val imm = context.getSystemService(InputMethodManager::class.java)
            if (value) {
                requestFocus()
                imm.restartInput(this)
                imm.showSoftInput(this, 0)
            } else {
                imm.hideSoftInputFromWindow(windowToken, 0)
                keyboard.releaseHeldKeys()
            }
        }

    /** A physical mouse or touchpad: absolute pointer and real buttons (HID-A). */
    private val mouse = HardwareMouse(sender)
    private val heldModifierKeys = mutableSetOf<String>()

    /** Called with each hardware pointer position (normalized, null = outside the picture): the workspace's hover. */
    var onHardwarePointer: ((CGPoint?) -> Unit)? = null

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    // A physical keyboard types into the Mac without the on-screen keyboard: the
    // surface holds focus whenever it is on screen.
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (hasWindowFocus) requestFocus() else releaseHardwareInput()
    }

    /** Let go of every hardware key, modifier and button (focus lost, input off, Home). */
    fun releaseHardwareInput() {
        mouse.releaseAll()
        for (name in heldModifierKeys) sender.modifier(name, false)
        heldModifierKeys.clear()
        keyboard.releaseHeldKeys()
    }

    private fun isMouse(event: MotionEvent) =
        event.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE || event.isFromSource(InputDevice.SOURCE_MOUSE) && event.getToolType(0) != MotionEvent.TOOL_TYPE_FINGER

    private fun handleMouse(event: MotionEvent): Boolean {
        val point = surface.remotePoint(CGPoint(event.x / density.toDouble(), event.y / density.toDouble()))
        onHardwarePointer?.invoke(point)
        if (!inputAllowed()) {
            mouse.releaseAll()
            return point != null
        }
        return mouse.event(point, event.buttonState, event.eventTime / 1000.0) || point != null
    }

    // While the Mac is being controlled the Mac's own cursor is drawn; Android's
    // pointer would be a second one over the picture.
    override fun onResolvePointerIcon(event: MotionEvent, pointerIndex: Int): PointerIcon? =
        if (hideSystemPointer() && surface.remotePoint(CGPoint(event.x / density.toDouble(), event.y / density.toDouble())) != null)
            PointerIcon.getSystemIcon(context, PointerIcon.TYPE_NULL)
        else super.onResolvePointerIcon(event, pointerIndex)

    // MARK: - Timers requested by the dispatcher

    fun schedulePoll(delaySeconds: Double?) {
        handler.removeCallbacks(pollRunnable)
        if (delaySeconds != null) handler.postDelayed(pollRunnable, (delaySeconds * 1000).toLong().coerceAtLeast(0))
    }

    fun setMomentumRunning(running: Boolean) {
        if (momentumRunning == running) return
        momentumRunning = running
        if (running) Choreographer.getInstance().postFrameCallback(momentumFrame) else Choreographer.getInstance().removeFrameCallback(momentumFrame)
    }

    // MARK: - Touches

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (isMouse(event)) {
            if (event.actionMasked == MotionEvent.ACTION_CANCEL) mouse.releaseAll() else handleMouse(event)
            return true
        }
        val time = event.eventTime / 1000.0
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
                surface.touches(SurfaceTouchPhase.Began, listOf(touch(event, event.actionIndex)), time)
            MotionEvent.ACTION_MOVE ->
                surface.touches(SurfaceTouchPhase.Moved, (0 until event.pointerCount).map { touch(event, it) }, time)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val phase = if (event.flags and MotionEvent.FLAG_CANCELED != 0) SurfaceTouchPhase.Cancelled else SurfaceTouchPhase.Ended
                surface.touches(phase, listOf(touch(event, event.actionIndex)), time)
            }
            MotionEvent.ACTION_CANCEL ->
                surface.touches(SurfaceTouchPhase.Cancelled, (0 until event.pointerCount).map { touch(event, it) }, time)
            else -> return false
        }
        return true
    }

    /** Stylus hover: proximity and `pencil hover` (iOS UIHoverGestureRecognizer). */
    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (isMouse(event)) return handleMouse(event)
        val tool = event.getToolType(0)
        if (tool != MotionEvent.TOOL_TYPE_STYLUS && tool != MotionEvent.TOOL_TYPE_ERASER) return super.onHoverEvent(event)
        val point = CGPoint(event.x / density.toDouble(), event.y / density.toDouble())
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER -> surface.hover(true, point)
            MotionEvent.ACTION_HOVER_MOVE -> surface.hover(null, point)
            MotionEvent.ACTION_HOVER_EXIT -> surface.hover(false, point)
        }
        return true
    }

    /** A mouse wheel or trackpad scroll scrolls the Mac: about 10 points per line, like the Mac Receiver. */
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        // Mouse buttons (including Back/Forward, which must never act as Back here).
        if (event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS || event.actionMasked == MotionEvent.ACTION_BUTTON_RELEASE) {
            if (isMouse(event)) handleMouse(event)
            return true
        }
        // Touchpad two-finger swipe (Android 14+ touchpads): scroll, not a drag.
        if (Build.VERSION.SDK_INT >= 34 && event.classification == MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE) {
            if (!inputAllowed()) return true
            val scale = surface.pointsPerRemotePixel() ?: return true
            val dx = -event.getAxisValue(MotionEvent.AXIS_GESTURE_SCROLL_X_DISTANCE) / density / scale
            val dy = -event.getAxisValue(MotionEvent.AXIS_GESTURE_SCROLL_Y_DISTANCE) / density / scale
            if (dx != 0.0 || dy != 0.0) sender.scroll(dx, dy)
            return true
        }
        if (event.actionMasked != MotionEvent.ACTION_SCROLL || !inputAllowed()) return super.onGenericMotionEvent(event)
        val scale = surface.pointsPerRemotePixel() ?: return true
        // Scroll where the pointer is: the Mac pointer moves there first (in Window mode that picks the tile).
        if (isMouse(event)) handleMouse(event)
        val dx = -event.getAxisValue(MotionEvent.AXIS_HSCROLL) * LINE_POINTS / scale
        val dy = event.getAxisValue(MotionEvent.AXIS_VSCROLL) * LINE_POINTS / scale
        if (dx != 0.0 || dy != 0.0) sender.scroll(dx, dy)
        return true
    }

    private fun touch(event: MotionEvent, index: Int): SurfaceTouch {
        val kind = when (event.getToolType(index)) {
            MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> SurfaceTouch.Kind.Stylus
            MotionEvent.TOOL_TYPE_MOUSE -> SurfaceTouch.Kind.Mouse
            else -> SurfaceTouch.Kind.Finger
        }
        // Android tilt: 0 = perpendicular; iOS altitude: π/2 = perpendicular.
        val tilt = event.getAxisValue(MotionEvent.AXIS_TILT, index).toDouble()
        return SurfaceTouch(
            id = event.getPointerId(index),
            point = CGPoint(event.getX(index) / density.toDouble(), event.getY(index) / density.toDouble()),
            kind = kind,
            pressure = event.getPressure(index).toDouble().coerceIn(0.0, 1.0),
            azimuth = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, index).toDouble(),
            altitude = (PI / 2 - tilt).coerceIn(0.0, PI / 2),
        )
    }

    // MARK: - Keyboard

    override fun onCheckIsTextEditor(): Boolean = keyboardRequested

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        if (!keyboardRequested) return null
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return RemoteInputConnection()
    }

    /**
     * Committed text and deletions only: composing (marked) text never leaves
     * the device. A commit that replaces composing text sends only the result.
     */
    private inner class RemoteInputConnection : BaseInputConnection(this@ReceiverInputView, false) {
        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
            keyboard.commitText(text.toString())
            return true
        }

        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean = super.setComposingText(text, newCursorPosition)

        override fun finishComposingText(): Boolean {
            val composing = editable?.let { e ->
                val start = getComposingSpanStart(e)
                val end = getComposingSpanEnd(e)
                if (start in 0 until end) e.subSequence(start, end).toString() else null
            }
            super.finishComposingText()
            editable?.clear()
            composing?.let(keyboard::commitText)
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            if (beforeLength > 0) keyboard.backspace(beforeLength)
            if (afterLength > 0) keyboard.forwardDelete(afterLength)
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) handleKeyDown(event) else if (event.action == KeyEvent.ACTION_UP) handleKeyUp(event)
            return true
        }

        override fun performEditorAction(editorAction: Int): Boolean {
            keyboard.returnKey()
            return true
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        // A mouse's Back button arrives as KEYCODE_BACK from a mouse: swallow it.
        if (keyCode == KeyEvent.KEYCODE_BACK && event.isFromSource(InputDevice.SOURCE_MOUSE)) return true
        return handleKeyDown(event) || super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && event.isFromSource(InputDevice.SOURCE_MOUSE)) return true
        return handleKeyUp(event) || super.onKeyUp(keyCode, event)
    }

    /** Physical and IME key events: the rules of RemoteKeyboardInputView, plus modified hardware shortcuts. */
    private fun handleKeyDown(event: KeyEvent): Boolean {
        if (!inputAllowed()) return false
        // Modifier keys on their own (Shift-click, Option to reveal, ⌘ held while clicking): named modifiers.
        HidKeyMap.modifierKeyName(event.keyCode)?.let { name ->
            if (event.repeatCount == 0 && heldModifierKeys.add(name)) sender.modifier(name, true)
            return true
        }
        val usage = HidKeyMap.usage(event.keyCode) ?: return false
        val modifiers = HidKeyMap.modifierNames(event.metaState)
        if (keyboard.keyDown(usage, modifiers)) return true
        if (event.repeatCount > 0 && usage != RemoteKeyboardBridge.BACKSPACE) return true
        when {
            usage == RemoteKeyboardBridge.BACKSPACE -> keyboard.backspace()
            usage == RemoteKeyboardBridge.RETURN -> keyboard.returnKey()
            // Command/Control/Option + key is a shortcut for the Mac, sent as one press.
            HidKeyMap.isShortcut(event.metaState) -> keyboard.shortcut(usage, modifiers)
            else -> {
                val character = event.getUnicodeChar(event.metaState)
                if (character == 0) keyboard.shortcut(usage, modifiers) else keyboard.commitText(String(Character.toChars(character)))
            }
        }
        return true
    }

    private fun handleKeyUp(event: KeyEvent): Boolean {
        HidKeyMap.modifierKeyName(event.keyCode)?.let { name ->
            if (heldModifierKeys.remove(name)) sender.modifier(name, false)
            return true
        }
        val usage = HidKeyMap.usage(event.keyCode) ?: return false
        return keyboard.keyUp(usage, HidKeyMap.modifierNames(event.metaState)) || inputAllowed()
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: android.graphics.Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        if (!gainFocus) releaseHardwareInput()
    }

    override fun onDetachedFromWindow() {
        handler.removeCallbacks(pollRunnable)
        setMomentumRunning(false)
        releaseHardwareInput()
        super.onDetachedFromWindow()
    }

    companion object {
        const val LINE_POINTS = 10.0

        /** The dispatcher's clock: the same base as MotionEvent.eventTime. */
        fun now(): Double = SystemClock.uptimeMillis() / 1000.0
    }
}
