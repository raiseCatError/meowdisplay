package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Lock This Mac (PROTOCOL.md 6.16), in any display mode: the Mac shows macOS's own lock screen,
 * so its login password is needed to go on. Needs control; the Mac answers with what happened.
 */
object LockMacWire {
    const val FEATURE = "lockMac"
    const val REQUEST = "lockMac"
    const val RESULT = "lockMacResult"

    fun request(req: Int) = buildJsonObject { put("type", REQUEST); put("req", req) }
}

/** What the Mac reports after [LockMacWire.REQUEST]. */
enum class LockMacResult(val wire: String) {
    Locked("locked"), Control("control"), Accessibility("accessibility"), Failed("failed");

    val message: String get() = when (this) {
        Locked -> "The Mac is locked."
        Control -> "Locking needs control of the Mac. Request Control first."
        Accessibility -> "The Mac can't lock: turn on MeowDisplay in System Settings ▸ Privacy & Security ▸ Accessibility on the Mac."
        Failed -> "The Mac didn't lock. Its Lock Screen shortcut (Control-Command-Q) may be changed or off."
    }

    companion object {
        fun parse(obj: JsonObject): LockMacResult? {
            val raw = (obj["result"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.take(32) ?: return null
            return entries.firstOrNull { it.wire == raw }
        }
    }
}
