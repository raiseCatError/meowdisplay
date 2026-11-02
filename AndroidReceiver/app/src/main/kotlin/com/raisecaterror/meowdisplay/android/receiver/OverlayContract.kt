package com.raisecaterror.meowdisplay.android.receiver

import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent
import com.raisecaterror.meowdisplay.core.controls.ControlReservedRegion
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.LandscapeTraySide
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.session.InputWireState

/**
 * Everything the control overlay (iOS ReceiverControlOverlay) reads about the
 * screen and session. All geometry is in dp (= iOS points), in the overlay's
 * own coordinates (origin top-left of the full receiver window).
 */
data class OverlayEnvironment(
    val containerSize: CGSize,
    val safeInsets: ControlSafeInsets,
    /** The side a display cutout sits on in landscape, if any (ControlTrayGeometry `notchSide`). */
    val notchSide: LandscapeTraySide? = null,
    /** Hinge/fold (Division) and cutout (Occlusion) regions. */
    val reservedRegions: List<ControlReservedRegion> = emptyList(),
    /** The area above a docked software keyboard, or null when it is hidden. */
    val keyboardVisibleRect: CGRect? = null,
    /** The iPad-style presentation (Strip / Overlay / Custom) instead of the iPhone tray. */
    val expanded: Boolean = false,
    /** The Mac's protocol version (modifiers need ≥ 6). */
    val senderPV: Int = 0,
    /** Keyboard button is offered: input reaches the Mac and it speaks the keyboard wire. */
    val keyboardAvailable: Boolean = false,
    val videoEnabled: Boolean = true,
    /** The Mac-confirmed input state, for the prompt and Settings. */
    val inputState: InputWireState = InputWireState.Off,
    /** Screen reader on (TalkBack): controls stay fully accessible and never auto-hide visually. */
    val screenReaderRunning: Boolean = false,
    val reduceMotion: Boolean = false,
)

/** What the overlay asks the receiver to do. Every remote effect goes through the session's input gate. */
interface OverlayActions {
    /** A synthetic modifier going down or up on the Mac (`keyboard modifierDown/modifierUp`). */
    fun modifier(name: String, down: Boolean)

    /** A one-tap action (palette key, Function button, Return): runs it through OneTapActionRunner. */
    fun perform(item: ShortcutItem)

    /** Escape / Tab one-shot presses from the tray and keyboard bar. */
    fun press(usage: Int)

    fun toggleKeyboard()
    fun dismissKeyboard()
    fun openSettings()
    fun toggleMoveView()
    fun resetViewport()
    fun haptic(event: ControlHapticEvent)

    /** The frames controls occupy, so the surface can keep its video-off rect and prompts clear of them. */
    fun occupiedFramesChanged(frames: List<CGRect>)

    /** iPad Strip: the canvas left for the Mac picture beside the rails (null = the whole window). */
    fun canvasChanged(canvas: CGRect?)

    /** The on-screen chord changed: the software keyboard types under it (SoftwareKeyboardChordPolicy). */
    fun chordChanged(modifiers: Set<com.raisecaterror.meowdisplay.core.controls.ControlModifier>)
}
