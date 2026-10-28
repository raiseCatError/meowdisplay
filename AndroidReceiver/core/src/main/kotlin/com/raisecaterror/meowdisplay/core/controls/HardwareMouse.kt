package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.session.ReceiverInputSender
import kotlin.math.hypot

/**
 * A physical mouse or touchpad pointer (Android TOOL_TYPE_MOUSE): an absolute
 * pointer with real buttons, unlike touch, which goes through the gesture
 * engine. Positions are normalized to the Mac's picture; null means outside
 * it. Every press is matched by a release, here or in [releaseAll].
 *
 * Buttons come from the platform's button state as a bit set, diffed against
 * the last state, so it works whichever event (down, button press, move)
 * reports a change first. Middle and extra buttons are never sent: the Mac
 * side has no middle button, and Back/Forward must not act on the Mac or on
 * this app.
 */
class HardwareMouse(private val input: ReceiverInputSender) {
    enum class Button(val bit: Int, val wire: String?) {
        Primary(1, "left"), Secondary(2, "right"), Tertiary(4, null), Back(8, null), Forward(16, null);
    }

    private var state = 0
    private var last: CGPoint? = null
    private var lastPress: Triple<Button, Double, CGPoint>? = null
    private var clicks = 1
    private val pressedCount = mutableMapOf<Button, Int>()

    val holdsButton: Boolean get() = pressedCount.isNotEmpty()

    /**
     * One pointer event: [point] normalized (null = outside the picture), [buttons]
     * the platform button state, [time] seconds. Returns true when it was the Mac's.
     */
    fun event(point: CGPoint?, buttons: Int, time: Double): Boolean {
        val held = holdsButton
        val p = when {
            point != null -> point
            held -> last   // a drag that leaves the picture stays at its last point
            else -> null
        }
        if (p != null && p != last) {
            input.pointerMove(p.x.coerceIn(0.0, 1.0), p.y.coerceIn(0.0, 1.0))
            last = p
        }
        val changed = buttons xor state
        for (b in Button.entries) {
            if (changed and b.bit == 0) continue
            val down = buttons and b.bit != 0
            val wire = b.wire ?: continue
            if (down) {
                if (p == null) continue   // a press outside the picture isn't the Mac's
                val prev = lastPress
                clicks = if (prev != null && prev.first == b && time - prev.second <= DOUBLE_CLICK_SECONDS &&
                    hypot(p.x - prev.third.x, p.y - prev.third.y) <= DOUBLE_CLICK_DISTANCE) (clicks % 3) + 1 else 1
                lastPress = Triple(b, time, p)
                if (input.pointerDown(wire, clicks)) pressedCount[b] = clicks
            } else {
                pressedCount.remove(b)?.let { input.pointerUp(wire, it) }
            }
        }
        state = buttons
        return p != null || held
    }

    /** Focus lost, input off, disconnect, source change: let go of every button. */
    fun releaseAll() {
        for ((b, count) in pressedCount.toMap()) b.wire?.let { input.pointerUp(it, count) }
        pressedCount.clear()
        state = 0
        lastPress = null
    }

    companion object {
        const val DOUBLE_CLICK_SECONDS = 0.4
        /** Normalized distance (about 6 pt on a 1000 pt picture). */
        const val DOUBLE_CLICK_DISTANCE = 0.006
    }
}
