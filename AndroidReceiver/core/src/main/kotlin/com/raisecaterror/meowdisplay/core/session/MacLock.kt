package com.raisecaterror.meowdisplay.core.session

import kotlinx.serialization.json.JsonObject

/**
 * The Mac's lock screen as the receiver is told it (PROTOCOL.md 6.18, Shared/MacLockWire.swift).
 * Only [Unlocked] lets content through; everything else, including a state this build doesn't
 * know, counts as locked.
 */
enum class MacScreenPrivacy(val wire: String) {
    Unlocked("unlocked"),
    Locked("locked"),
    SwitchedOut("switchedOut"),
    Unknown("unknown");

    val allowsContent: Boolean get() = this == Unlocked

    companion object {
        /** An unrecognised value is [Unknown]: locked, never unlocked. */
        fun of(raw: String): MacScreenPrivacy = entries.firstOrNull { it.wire == raw } ?: Unknown
    }
}

/** The receiver's copy of `macLockState`. [remoteUnlock] is informational: this receiver never unlocks a Mac. */
data class MacLockNotice(val state: MacScreenPrivacy, val remoteUnlock: Boolean = false) {
    val isLocked: Boolean get() = !state.allowsContent

    companion object {
        /** Null for anything malformed (no usable `state`), as on iOS. */
        fun parse(obj: JsonObject): MacLockNotice? {
            val raw = obj.string(MacLockWire.TYPE_STATE_KEY)?.takeIf { it.isNotEmpty() } ?: return null
            return MacLockNotice(MacScreenPrivacy.of(raw.take(32)), obj.bool("remoteUnlock") ?: false)
        }
    }
}

object MacLockWire {
    const val TYPE = "macLockState"
    const val FEATURE = "macLockState"
    internal const val TYPE_STATE_KEY = "state"

    /**
     * Control messages that may still be used while the Mac is locked. Everything else (window
     * lists, titles, stills, backdrops, app lists, Files, menus, clipboard, cursor images, ...) is
     * dropped: the Mac sends none of it then, and a late or forged one must not draw anything.
     */
    private val allowedWhileLocked = setOf("receiverUI", "lockMacResult")

    fun passesWhileLocked(type: String): Boolean = type in allowedWhileLocked
}

/**
 * The session's view of the Mac's lock state. Starts unlocked on every connection (a Mac that
 * never sends `macLockState` is never shown as locked) and is locked by anything but a clear
 * `unlocked`. Nothing is remembered across a lock: content comes back only from fresh Mac messages.
 */
class MacLockGate {
    var state: MacScreenPrivacy = MacScreenPrivacy.Unlocked
        private set

    val locked: Boolean get() = !state.allowsContent

    /** True when the locked/unlocked answer changed. */
    fun apply(notice: MacLockNotice): Boolean {
        val wasLocked = locked
        state = notice.state
        return wasLocked != locked
    }

    fun reset() { state = MacScreenPrivacy.Unlocked }
}
