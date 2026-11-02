package com.raisecaterror.meowdisplay.core.wire

import com.raisecaterror.meowdisplay.core.crypto.base64
import com.raisecaterror.meowdisplay.core.crypto.base64Bytes
import com.raisecaterror.meowdisplay.core.crypto.sha256
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream

/**
 * Large control messages (PROTOCOL.md 6.14). A control frame must stay under 32768 bytes
 * (PROTOCOL.md 4), so the Mac sends a longer one (a Remote Finder preview, a window still, a
 * pane's whole-source still) as ordered `chunk` messages to a receiver that said in its hello
 * that it reassembles them. Mirrors Shared/ControlChunks.swift.
 */
object ControlChunkWire {
    const val TYPE = "chunk"
    const val HELLO_FIELD = "chunks"
    const val VERSION = 1
    const val THRESHOLD = 32_000
    const val PART_BYTES = 22_000
    const val MAX_TOTAL_BYTES = 4 shl 20
    const val MAX_IN_FLIGHT = 4
    const val TIMEOUT_MS = 15_000L

    /** First 16 hex digits of the SHA-256 of the whole message. */
    fun digest(bytes: ByteArray): String = sha256(bytes).take(8).joinToString("") { "%02x".format(it) }

    /** The chunk messages for one message, in order (the Mac's side; used by tests and the demo). */
    fun split(message: ByteArray, id: Int, partBytes: Int = PART_BYTES): List<JsonObject> {
        require(message.isNotEmpty() && message.size <= MAX_TOTAL_BYTES && partBytes > 0)
        val n = (message.size + partBytes - 1) / partBytes
        return (0 until n).map { i ->
            val part = message.copyOfRange(i * partBytes, minOf(message.size, (i + 1) * partBytes))
            buildJsonObject {
                put("type", TYPE); put("id", id); put("i", i); put("n", n); put("d", part.base64())
                if (i == 0) { put("len", message.size); put("sha", digest(message)) }
            }
        }
    }
}

/** Reassembles `chunk` messages: in order, bounded in size, count and time, digest-checked. One per connection. */
class ControlChunkAssembler {
    sealed interface Outcome {
        data object Pending : Outcome
        class Complete(val bytes: ByteArray) : Outcome { val text: String get() = String(bytes, Charsets.UTF_8) }
        /** Abandoned (gap, oversize, bad digest, …); the reason is for logs. */
        data class Dropped(val reason: String) : Outcome
    }

    private class Partial(val n: Int, val length: Int, val digest: String, var next: Int, var touched: Long) {
        val data = ByteArrayOutputStream(length)
    }

    private val partials = LinkedHashMap<Int, Partial>()

    val inFlight: Int get() = partials.size

    fun reset() = partials.clear()

    fun add(obj: JsonObject, nowMs: Long): Outcome {
        partials.entries.removeAll { nowMs - it.value.touched > ControlChunkWire.TIMEOUT_MS }
        val id = obj.intField("id"); val i = obj.intField("i"); val n = obj.intField("n")
        val d = (obj["d"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (id == null || i == null || n == null || d == null || d.length > 4 * ControlChunkWire.PART_BYTES / 3 + 8) {
            return Outcome.Dropped("malformed")
        }
        val part = d.base64Bytes() ?: run { partials.remove(id); return Outcome.Dropped("bad base64") }
        if (i == 0) {
            val length = obj.intField("len")
            val digest = (obj["sha"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            if (length == null || length <= 0 || length > ControlChunkWire.MAX_TOTAL_BYTES || digest?.length != 16 || n < 1 || n > length) {
                partials.remove(id)
                return Outcome.Dropped("bad header")
            }
            if (!partials.containsKey(id) && partials.size >= ControlChunkWire.MAX_IN_FLIGHT) {
                partials.minByOrNull { it.value.touched }?.key?.let { partials.remove(it) }
            }
            partials[id] = Partial(n, length, digest, 0, nowMs)
        }
        val p = partials[id] ?: return Outcome.Dropped("no start")
        if (i != p.next || n != p.n) { partials.remove(id); return Outcome.Dropped("out of order") }
        if (p.data.size() + part.size > p.length) { partials.remove(id); return Outcome.Dropped("too long") }
        p.data.write(part)
        p.next += 1
        p.touched = nowMs
        if (p.next < p.n) return Outcome.Pending
        partials.remove(id)
        val bytes = p.data.toByteArray()
        if (bytes.size != p.length) return Outcome.Dropped("short")
        if (ControlChunkWire.digest(bytes) != p.digest) return Outcome.Dropped("digest")
        return Outcome.Complete(bytes)
    }

    private fun JsonObject.intField(k: String): Int? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
}
