package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** What a knock means (Shared/SessionInvitation.swift `SessionInvitationIntent`). It only ever narrows what the Mac does. */
enum class KnockIntent(val wire: String) {
    /** This device's user explicitly asked to connect to that Mac. */
    Manual("manual"),

    /** Background recovery: the Mac judges it as a background attempt and never prompts for it. */
    Automatic("automatic"),
}

/**
 * The one frame a knock carries on the pinned connection (Shared/RemoteConnectRequestPolicy.swift
 * `RemoteConnectRequestIntent`): a 4-byte big-endian length, then the JSON body, byte for byte what
 * the Swift receivers send (fixtures/remote/knock-frame-vectors.json).
 */
object KnockFrame {
    const val MESSAGE_TYPE = "remoteConnectRequest"

    /** The most the Mac reads from a knock. */
    const val MAX_FRAME_BYTES = 256

    fun encode(intent: KnockIntent): ByteArray {
        val body = "{\"type\":\"$MESSAGE_TYPE\",\"intent\":\"${intent.wire}\"}".toByteArray(Charsets.UTF_8)
        val length = body.size
        return byteArrayOf((length ushr 24).toByte(), (length ushr 16).toByte(), (length ushr 8).toByte(), length.toByte()) + body
    }

    /**
     * What the Mac makes of the bytes it read: anything that is not exactly one well-formed frame
     * with a known intent is [KnockIntent.Automatic].
     */
    fun intent(frame: ByteArray?): KnockIntent {
        if (frame == null || frame.size <= 4 || frame.size > MAX_FRAME_BYTES) return KnockIntent.Automatic
        val length = frame.take(4).fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }
        if (length <= 0 || length != frame.size - 4) return KnockIntent.Automatic
        val body = runCatching { Json.parseToJsonElement(String(frame, 4, length, Charsets.UTF_8)).jsonObject }.getOrNull()
            ?: return KnockIntent.Automatic
        if (body.text("type") != MESSAGE_TYPE) return KnockIntent.Automatic
        return KnockIntent.entries.firstOrNull { it.wire == body.text("intent") } ?: KnockIntent.Automatic
    }

    private fun JsonObject.text(key: String): String? = runCatching { getValue(key).jsonPrimitive.takeIf { it.isString }?.content }.getOrNull()
}
