package com.raisecaterror.meowdisplay.core.wire

import java.nio.BufferUnderflowException
import java.nio.ByteBuffer

/**
 * Mac system-audio media frames (PROTOCOL.md 5A, Shared/AudioMediaFrame.swift):
 * `[0x01 marker][subtype][body]`, every integer big-endian.
 */
sealed interface AudioMediaFrame {
    /** AAC-LC AudioSpecificConfig, sent before any packet. */
    data class Config(val sampleRate: Long, val channelCount: Int, val cookie: Bytes) : AudioMediaFrame

    /** One raw AAC-LC access unit (no ADTS header). */
    data class Packet(val sequence: Long, val capturedAtMs: Long, val durationMs: Long, val payload: Bytes) : AudioMediaFrame

    /** Debug-only PCM bypass (Float32 interleaved); production senders never send it. */
    data class PcmConfig(val sampleRate: Long, val channelCount: Int) : AudioMediaFrame
    data class PcmPacket(val sequence: Long, val capturedAtMs: Long, val frameCount: Long, val payload: Bytes) : AudioMediaFrame

    /** Byte array with value equality, so frames compare by content. */
    class Bytes(val value: ByteArray) {
        override fun equals(other: Any?) = other is Bytes && value.contentEquals(other.value)
        override fun hashCode() = value.contentHashCode()
        override fun toString() = "Bytes(${value.size})"
    }

    fun encode(): ByteArray {
        val (subtype, body) = when (this) {
            is Config -> 0x01 to ByteBuffer.allocate(7 + cookie.value.size).apply {
                putInt(sampleRate.toInt()); put(channelCount.toByte()); putShort(cookie.value.size.toShort()); put(cookie.value)
            }
            is Packet -> 0x02 to ByteBuffer.allocate(20 + payload.value.size).apply {
                putInt(sequence.toInt()); putLong(capturedAtMs); putInt(durationMs.toInt()); putInt(payload.value.size); put(payload.value)
            }
            is PcmConfig -> 0x03 to ByteBuffer.allocate(5).apply {
                putInt(sampleRate.toInt()); put(channelCount.toByte())
            }
            is PcmPacket -> 0x04 to ByteBuffer.allocate(20 + payload.value.size).apply {
                putInt(sequence.toInt()); putLong(capturedAtMs); putInt(frameCount.toInt()); putInt(payload.value.size); put(payload.value)
            }
        }
        return byteArrayOf(MARKER, subtype.toByte()) + body.array()
    }

    companion object {
        const val MARKER: Byte = 0x01

        fun isAudioFrame(payload: ByteArray) = payload.firstOrNull() == MARKER

        /** Null for anything malformed or truncated: drop it, never fail. */
        fun decode(payload: ByteArray): AudioMediaFrame? {
            if (payload.size < 2 || payload[0] != MARKER) return null
            val body = ByteBuffer.wrap(payload, 2, payload.size - 2)
            return try {
                when (payload[1].toInt()) {
                    0x01 -> Config(body.u32(), body.get().toInt() and 0xFF, Bytes(body.bytes(body.short.toInt() and 0xFFFF)))
                    0x02 -> Packet(body.u32(), body.long, body.u32(), Bytes(body.bytes(body.u32())))
                    0x03 -> PcmConfig(body.u32(), body.get().toInt() and 0xFF)
                    0x04 -> PcmPacket(body.u32(), body.long, body.u32(), Bytes(body.bytes(body.u32())))
                    else -> null
                }
            } catch (_: BufferUnderflowException) {
                null
            }
        }

        private fun ByteBuffer.u32(): Long = int.toLong() and 0xFFFF_FFFFL

        private fun ByteBuffer.bytes(length: Number): ByteArray {
            val count = length.toLong()
            if (count < 0 || count > remaining()) throw BufferUnderflowException()
            return ByteArray(count.toInt()).also { get(it) }
        }
    }
}
