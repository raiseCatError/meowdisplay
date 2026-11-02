package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/Protocol.swift (ReceiverDisplayMode, DisplayModeRequestState) and
// Mac/CaptureLifecycle.swift (CaptureMode). Only these pure types; the rest of Protocol.swift is
// the wire layer.

enum class ReceiverDisplayMode(val raw: String, val title: String) {
    /** Duplicate the Mac's screen onto the device. */
    Mirror("mirror", "Mirror"),

    /** Add the device as a second, separate screen (not the verb "to extend"). */
    Extend("extend", "Extend");

    companion object {
        fun of(raw: String?): ReceiverDisplayMode? = entries.firstOrNull { it.raw == raw }
    }
}

enum class CaptureMode(val raw: String) {
    Mirror("mirror"), Extend("extend");

    val receiverMode: ReceiverDisplayMode
        get() = if (this == Mirror) ReceiverDisplayMode.Mirror else ReceiverDisplayMode.Extend

    companion object {
        fun of(raw: String?): CaptureMode? = entries.firstOrNull { it.raw == raw }
        fun from(receiverMode: ReceiverDisplayMode): CaptureMode =
            if (receiverMode == ReceiverDisplayMode.Mirror) Mirror else Extend
    }
}

/**
 * Receiver-side request bookkeeping. The Mac's state message always wins; the boolean return from
 * [confirm] identifies the single successful reply that should produce user feedback.
 */
data class DisplayModeRequestState(
    var confirmedMode: ReceiverDisplayMode? = null,
    var pendingMode: ReceiverDisplayMode? = null,
    /** Bumped for every accepted request so a late expiry can only retire the request it was armed for. */
    var pendingGeneration: Int = 0,
) {
    fun request(mode: ReceiverDisplayMode): Boolean {
        if (pendingMode != null || mode == confirmedMode) return false
        pendingMode = mode
        pendingGeneration += 1
        return true
    }

    fun confirm(mode: ReceiverDisplayMode): Boolean {
        val confirmsReceiverRequest = pendingMode == mode
        confirmedMode = mode
        pendingMode = null
        return confirmsReceiverRequest
    }

    /** Retires a request the Mac never answered. The last confirmed mode (the real one) is kept. */
    fun expirePending(generation: Int): Boolean {
        if (pendingMode == null || pendingGeneration != generation) return false
        pendingMode = null
        return true
    }

    /** Session teardown: nothing about the Mac's mode is known across a deliberate reset. */
    fun reset() {
        confirmedMode = null
        pendingMode = null
    }
}
