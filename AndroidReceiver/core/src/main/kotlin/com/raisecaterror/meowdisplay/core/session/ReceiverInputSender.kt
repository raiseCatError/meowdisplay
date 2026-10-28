package com.raisecaterror.meowdisplay.core.session

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The two input channels a sender gate needs: the session's own gate and its clock. */
interface InputChannel {
    /** Sends [message] only while the Mac's grant stands on the admitted connection and it speaks [minimumPV]. */
    fun sendInput(message: JsonObject, minimumPV: Int = WireProtocol.ALLOW_INPUT): Boolean

    /** Sender clock − receiver clock, once known (PROTOCOL.md 8.1). */
    val clockOffsetMs: Double?
}

/** What a release pass did, for tests and diagnostics. */
data class InputReleaseReport(val released: List<String>, val cancelSent: Boolean)

/**
 * Every remote input message the receiver sends (Shared/StreamReceiver.swift
 * `send*`, PROTOCOL.md 6.1), built in exactly the iOS JSON shapes.
 *
 * Nothing here decides whether input may leave the device: each message goes
 * through [InputChannel.sendInput], which refuses unless the Mac granted
 * input on the current admitted, unpaused connection (pv ≥ 8). A sender that
 * predates the grant (pv < 8) therefore never receives input from Android.
 *
 * It remembers everything it put down — mouse buttons, keys, synthetic
 * modifiers, touch and pencil contacts, foreground-app gesture lifecycles —
 * so [releaseAll] can send the matching releases and `keyboard cancel`, and
 * [forget] can drop them when the connection or grant is already gone (the
 * Mac releases held input itself on revocation and session loss). Only a
 * message that was actually sent is remembered.
 */
class ReceiverInputSender(
    private val channel: InputChannel,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
    /** Shared with the session, so the two can never take their locks in opposite orders. */
    private val lock: Any = Any(),
) {
    private val heldButtons = LinkedHashMap<String, Int>()
    private val heldKeys = LinkedHashMap<Int, List<String>>()
    private val heldModifiers = LinkedHashSet<String>()
    private val activeAppGestures = LinkedHashSet<String>()
    private var touchDown: Pair<Double, Double>? = null
    private var pencilDown: Pair<Double, Double>? = null

    /** True while anything this device put down is still held on the Mac. */
    val holdsInput: Boolean
        get() = locked { heldButtons.isNotEmpty() || heldKeys.isNotEmpty() || heldModifiers.isNotEmpty() ||
            activeAppGestures.isNotEmpty() || touchDown != null || pencilDown != null }

    fun heldModifierNames(): Set<String> = locked { heldModifiers.toSet() }
    fun heldKeyUsages(): Set<Int> = locked { heldKeys.keys.toSet() }
    fun heldButtonNames(): Set<String> = locked { heldButtons.keys.toSet() }

    // MARK: - Public, under the shared lock (each documented at its implementation below)

    fun touch(phase: String, x: Double, y: Double): Boolean = locked { touchLocked(phase, x, y) }
    fun scroll(dx: Double, dy: Double): Boolean = locked { scrollLocked(dx, dy) }
    fun gesture(name: String): Boolean = locked { gestureLocked(name) }
    fun nativeAppGesture(kind: String, phase: String, delta: Double): Boolean = locked { nativeAppGestureLocked(kind, phase, delta) }
    fun pointerMove(x: Double, y: Double): Boolean = locked { pointerMoveLocked(x, y) }
    fun pointerMoveRelative(dx: Double, dy: Double): Boolean = locked { pointerMoveRelativeLocked(dx, dy) }
    fun pointerDown(button: String, clickCount: Int): Boolean = locked { pointerDownLocked(button, clickCount) }
    fun pointerUp(button: String, clickCount: Int): Boolean = locked { pointerUpLocked(button, clickCount) }
    fun smartTouchProbe(id: Int, x: Double, y: Double): Boolean = locked { smartTouchProbeLocked(id, x, y) }
    fun pencil(phase: String, x: Double, y: Double, pressure: Double, azimuth: Double, altitude: Double): Boolean = locked { pencilLocked(phase, x, y, pressure, azimuth, altitude) }
    fun proximity(entering: Boolean, x: Double, y: Double): Boolean = locked { proximityLocked(entering, x, y) }
    fun keyboardText(text: String): Boolean = locked { keyboardTextLocked(text) }
    /** The on-screen keyboard opened or closed, so the Mac can follow its text caret (PROTOCOL.md 6.11). */
    fun keyboardState(open: Boolean): Boolean = locked { keyboardStateLocked(open) }
    fun keyboardPress(usage: Int, modifiers: List<String> = emptyList()): Boolean = locked { keyboardPressLocked(usage, modifiers) }
    fun keyboardDown(usage: Int, modifiers: List<String>, isRepeat: Boolean = false): Boolean = locked { keyboardDownLocked(usage, modifiers, isRepeat) }
    fun keyboardUp(usage: Int, modifiers: List<String>): Boolean = locked { keyboardUpLocked(usage, modifiers) }
    fun modifier(name: String, down: Boolean): Boolean = locked { modifierLocked(name, down) }
    fun releaseAll(): InputReleaseReport = locked { releaseAllLocked() }
    fun forget() = locked { forgetLocked() }

    // MARK: - Touch, scroll, gestures

    /** Legacy finger input (pv 1): normalized video coordinates, `t` in the sender's clock once known. */
    private fun touchLocked(phase: String, x: Double, y: Double): Boolean {
        if (phase !in TOUCH_PHASES) return false
        val sent = send(buildJsonObject {
            put("type", "touch")
            put("phase", phase)
            put("x", x)
            put("y", y)
            senderTime()?.let { put("t", it) }
        })
        if (sent) touchDown = if (phase == "began" || phase == "moved") x to y else null
        return sent
    }

    /** Two-finger scroll in video pixels, natural-scrolling sign. */
    private fun scrollLocked(dx: Double, dy: Double): Boolean = send(buildJsonObject {
        put("type", "scroll")
        put("dx", dx)
        put("dy", dy)
    })

    /** A semantic receiver gesture (`missionControl`, `spotlight`, …). */
    private fun gestureLocked(name: String): Boolean = send(buildJsonObject {
        put("type", "gesture")
        put("name", name)
    })

    /** A foreground-app pinch/rotate lifecycle (pv 10). A `changed`/terminal phase needs an active `began`. */
    private fun nativeAppGestureLocked(kind: String, phase: String, delta: Double): Boolean {
        if (kind !in APP_GESTURE_KINDS || phase !in APP_GESTURE_PHASES) return false
        if (phase != "began" && kind !in activeAppGestures) return false
        val sent = send(buildJsonObject {
            put("type", "nativeAppGesture")
            put("kind", kind)
            put("phase", phase)
            put("delta", delta)
        }, WireProtocol.NATIVE_APP_GESTURE)
        if (sent) {
            if (phase == "began") activeAppGestures += kind else if (phase == "ended" || phase == "cancelled") activeAppGestures -= kind
        }
        return sent
    }

    // MARK: - Pointer (pv 5)

    private fun pointerMoveLocked(x: Double, y: Double): Boolean = send(buildJsonObject {
        put("type", "pointer")
        put("action", "move")
        put("x", x)
        put("y", y)
    }, WireProtocol.POINTER)

    private fun pointerMoveRelativeLocked(dx: Double, dy: Double): Boolean = send(buildJsonObject {
        put("type", "pointer")
        put("action", "moveRelative")
        put("dx", dx)
        put("dy", dy)
    }, WireProtocol.POINTER)

    /** A button down at the Mac's current cursor; every down is matched by [pointerUp] or [releaseAll]. */
    private fun pointerDownLocked(button: String, clickCount: Int): Boolean {
        if (button !in BUTTONS) return false
        val sent = send(pointerButton("down", button, clickCount), WireProtocol.POINTER)
        if (sent) heldButtons[button] = clickCount
        return sent
    }

    private fun pointerUpLocked(button: String, clickCount: Int): Boolean {
        if (button !in BUTTONS) return false
        val sent = send(pointerButton("up", button, clickCount), WireProtocol.POINTER)
        heldButtons.remove(button)
        return sent
    }

    /** Smart Touch: is the element under this point scrollable (pv 20)? The reply arrives as `smartTouchProbeResult`. */
    private fun smartTouchProbeLocked(id: Int, x: Double, y: Double): Boolean = send(buildJsonObject {
        put("type", "smartTouchProbe")
        put("id", id)
        put("x", x)
        put("y", y)
    }, WireProtocol.SMART_TOUCH)

    // MARK: - Stylus (pv 3)

    /** `down`/`move`/`up`/`hover`; azimuth and altitude in radians, rotation always 0 like iOS. */
    private fun pencilLocked(phase: String, x: Double, y: Double, pressure: Double, azimuth: Double, altitude: Double): Boolean {
        if (phase !in PENCIL_PHASES) return false
        val sent = send(buildJsonObject {
            put("type", "pencil")
            put("phase", phase)
            put("x", x)
            put("y", y)
            put("pressure", pressure)
            put("azimuth", azimuth)
            put("altitude", altitude)
            put("rotation", 0)
            senderTime()?.let { put("t", it) }
        }, WireProtocol.PENCIL)
        if (sent) {
            when (phase) {
                "down" -> pencilDown = x to y
                "move" -> if (pencilDown != null) pencilDown = x to y
                "up" -> pencilDown = null
            }
        }
        return sent
    }

    private fun proximityLocked(entering: Boolean, x: Double, y: Double): Boolean = send(buildJsonObject {
        put("type", "proximity")
        put("entering", entering)
        put("x", x)
        put("y", y)
    }, WireProtocol.PENCIL)

    // MARK: - Keyboard (pv 4; modifiers and cancel pv 6)

    /** Committed text only — never marked/IME-intermediate text. */
    private fun keyboardStateLocked(open: Boolean): Boolean = send(buildJsonObject {
        put("type", "keyboardState")
        put("open", open)
    }, WireProtocol.KEYBOARD)

    private fun keyboardTextLocked(text: String): Boolean {
        if (text.isEmpty()) return false
        return send(buildJsonObject {
            put("type", "keyboard")
            put("action", "text")
            put("text", text)
        }, WireProtocol.KEYBOARD)
    }

    /** One atomic key with no lifecycle to track. */
    private fun keyboardPressLocked(usage: Int, modifiers: List<String>): Boolean {
        if (!isValidUsage(usage)) return false
        return send(keyMessage("press", usage, modifiers), WireProtocol.KEYBOARD)
    }

    /** A held key; [isRepeat] marks this device's own key repeat for a key it already sent down. */
    private fun keyboardDownLocked(usage: Int, modifiers: List<String>, isRepeat: Boolean): Boolean {
        if (!isValidUsage(usage)) return false
        // A repeat only ever follows a down that reached the Mac.
        if (isRepeat && usage !in heldKeys) return false
        val message = keyMessage("down", usage, modifiers, isRepeat)
        val sent = send(message, WireProtocol.KEYBOARD)
        if (sent) heldKeys[usage] = modifiers.filter { it in MODIFIER_NAMES }
        return sent
    }

    private fun keyboardUpLocked(usage: Int, modifiers: List<String>): Boolean {
        if (!isValidUsage(usage)) return false
        val sent = send(keyMessage("up", usage, modifiers), WireProtocol.KEYBOARD)
        heldKeys.remove(usage)
        return sent
    }

    /** A synthetic modifier held from the on-screen controls (`command`, `option`, `control`, `shift`). */
    private fun modifierLocked(name: String, down: Boolean): Boolean {
        if (name !in SYNTHETIC_MODIFIERS) return false
        val sent = send(buildJsonObject {
            put("type", "keyboard")
            put("action", if (down) "modifierDown" else "modifierUp")
            put("modifier", name)
        }, WireProtocol.RECEIVER_CONTROLS)
        if (down) {
            if (sent) heldModifiers += name
        } else {
            heldModifiers -= name
        }
        return sent
    }

    // MARK: - Never stuck

    /**
     * Sends the matching release for everything held, then `keyboard cancel`
     * as the safety net, and forgets it all. Used for local reasons while the
     * grant may still stand: backgrounding, a mode or profile change, Move
     * View, a cancelled gesture. Sends that the gate refuses are harmless: the
     * Mac has already released on revocation or loss.
     */
    private fun releaseAllLocked(): InputReleaseReport {
        val released = mutableListOf<String>()
        for (kind in activeAppGestures) {
            send(buildJsonObject {
                put("type", "nativeAppGesture")
                put("kind", kind)
                put("phase", "cancelled")
                put("delta", 0)
            }, WireProtocol.NATIVE_APP_GESTURE)
            released += "gesture:$kind"
        }
        for ((button, clickCount) in heldButtons) {
            send(pointerButton("up", button, clickCount), WireProtocol.POINTER)
            released += "button:$button"
        }
        for ((usage, modifiers) in heldKeys.entries.reversed()) {
            send(keyMessage("up", usage, modifiers), WireProtocol.KEYBOARD)
            released += "key:$usage"
        }
        for (name in SYNTHETIC_MODIFIERS.filter { it in heldModifiers }) {
            send(buildJsonObject {
                put("type", "keyboard")
                put("action", "modifierUp")
                put("modifier", name)
            }, WireProtocol.RECEIVER_CONTROLS)
            released += "modifier:$name"
        }
        pencilDown?.let { (x, y) ->
            send(buildJsonObject {
                put("type", "pencil")
                put("phase", "up")
                put("x", x)
                put("y", y)
                put("pressure", 0)
                put("azimuth", 0)
                put("altitude", Math.PI / 2)
                put("rotation", 0)
            }, WireProtocol.PENCIL)
            released += "pencil"
        }
        touchDown?.let { (x, y) ->
            send(buildJsonObject {
                put("type", "touch")
                put("phase", "cancelled")
                put("x", x)
                put("y", y)
            })
            released += "touch"
        }
        val cancelSent = send(buildJsonObject {
            put("type", "keyboard")
            put("action", "cancel")
        }, WireProtocol.RECEIVER_CONTROLS)
        clear()
        return InputReleaseReport(released, cancelSent)
    }

    /**
     * Drops held state without sending: the connection or the grant is already
     * gone, and the Mac releases everything itself (PROTOCOL.md 6.1). A
     * reconnect then starts with nothing held.
     */
    private fun forgetLocked() = clear()

    private inline fun <T> locked(block: () -> T): T = synchronized(lock, block)

    private fun clear() {
        heldButtons.clear()
        heldKeys.clear()
        heldModifiers.clear()
        activeAppGestures.clear()
        touchDown = null
        pencilDown = null
    }

    // MARK: - Building

    private fun send(message: JsonObject, minimumPV: Int = WireProtocol.ALLOW_INPUT): Boolean =
        channel.sendInput(message, maxOf(minimumPV, WireProtocol.ALLOW_INPUT))

    private fun senderTime(): Double? = channel.clockOffsetMs?.let { nowMs() + it }

    private fun pointerButton(action: String, button: String, clickCount: Int) = buildJsonObject {
        put("type", "pointer")
        put("action", action)
        put("button", button)
        put("clickCount", clickCount)
    }

    private fun keyMessage(action: String, usage: Int, modifiers: List<String>, isRepeat: Boolean = false) = buildJsonObject {
        put("type", "keyboard")
        put("action", action)
        put("usage", usage)
        put("modifiers", buildJsonArray { modifiers.forEach { add(JsonPrimitive(it)) } })
        if (isRepeat) put("repeat", true)
    }

    companion object {
        val TOUCH_PHASES = setOf("began", "moved", "ended", "cancelled")
        val PENCIL_PHASES = setOf("down", "move", "up", "hover")
        val BUTTONS = setOf("left", "right")
        val APP_GESTURE_KINDS = setOf("magnify", "rotate")
        val APP_GESTURE_PHASES = setOf("began", "changed", "ended", "cancelled")

        /** Synthetic modifiers, in the protocol's canonical order. */
        val SYNTHETIC_MODIFIERS = listOf("command", "option", "control", "shift")

        /** Named modifiers a key may carry (PROTOCOL.md 6.1). */
        val MODIFIER_NAMES = setOf("shift", "control", "option", "command", "capsLock")

        fun isValidUsage(usage: Int) = usage in 0..65535
    }
}
