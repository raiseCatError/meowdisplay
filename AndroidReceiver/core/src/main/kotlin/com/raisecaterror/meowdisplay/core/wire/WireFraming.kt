package com.raisecaterror.meowdisplay.core.wire

import com.raisecaterror.meowdisplay.core.crypto.uint32BE
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream

/**
 * Media-connection framing (PROTOCOL.md 3 and 4): `[u32 BE length][payload]`
 * in both directions over the pinned TLS stream.
 */
object WireFraming {
    /** Receiver to sender: 1 to 2^20 - 1 bytes (PROTOCOL.md 3). */
    const val MAX_OUTGOING_BYTES = (1 shl 20) - 1

    /**
     * Sender to receiver has no protocol maximum; a receiver still refuses
     * anything no keyframe of a supported panel could need.
     */
    const val MAX_INCOMING_BYTES = 32 shl 20

    fun frame(payload: ByteArray): ByteArray {
        require(payload.isNotEmpty() && payload.size <= MAX_OUTGOING_BYTES) { "frame size ${payload.size}" }
        return uint32BE(payload.size.toLong()) + payload
    }

    /** Blocks for one whole frame; null at a clean end of stream. */
    fun read(input: DataInputStream): ByteArray? {
        val length = try {
            input.readInt().toLong() and 0xFFFF_FFFFL
        } catch (_: EOFException) {
            return null
        }
        if (length == 0L || length > MAX_INCOMING_BYTES) throw IOException("bad frame length $length")
        return ByteArray(length.toInt()).also { input.readFully(it) }
    }

    fun reader(input: InputStream) = DataInputStream(input.buffered(64 * 1024))
}

/** What one sender-to-receiver payload is. */
sealed interface IncomingFrame {
    class Control(val json: String) : IncomingFrame
    class Video(val payload: ByteArray) : IncomingFrame
    class Audio(val frame: AudioMediaFrame) : IncomingFrame
    /** A malformed audio frame: ignored, never fatal (PROTOCOL.md 5A.1). */
    data object Ignored : IncomingFrame

    companion object {
        /**
         * The audio marker is checked first (5A.1); then the deprecated JSON
         * heuristic (4): under 32768 bytes, starts with `{`, no NUL byte.
         * Isolated here so a typed frame header can replace it cheaply.
         */
        fun classify(payload: ByteArray): IncomingFrame {
            if (AudioMediaFrame.isAudioFrame(payload)) {
                return AudioMediaFrame.decode(payload)?.let(::Audio) ?: Ignored
            }
            val isControl = payload.size < 32768 && payload.firstOrNull() == '{'.code.toByte() &&
                payload.none { it == 0.toByte() }
            return if (isControl) Control(String(payload, Charsets.UTF_8)) else Video(payload)
        }
    }
}
