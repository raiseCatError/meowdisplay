package com.raisecaterror.meowdisplay.core.video

import com.raisecaterror.meowdisplay.core.session.StreamCodec
import com.raisecaterror.meowdisplay.core.session.number
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * One wire video frame (PROTOCOL.md 5.1): an optional JSON telemetry prefix,
 * then NAL units each behind a 4-byte start code. The sender never emits
 * 3-byte start codes, so only the 4-byte pattern splits.
 */
class AccessUnit(val captureMs: Double?, val sendMs: Double?, val nalus: List<ByteArray>) {
    companion object {
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        fun parse(payload: ByteArray): AccessUnit {
            val nalus = mutableListOf<ByteArray>()
            var firstStart = -1
            var naluStart = -1
            var i = 0
            while (i + 4 <= payload.size) {
                if (payload[i] == 0.toByte() && payload[i + 1] == 0.toByte() && payload[i + 2] == 0.toByte() && payload[i + 3] == 1.toByte()) {
                    if (firstStart < 0) firstStart = i
                    if (naluStart in 0 until i) nalus += payload.copyOfRange(naluStart, i)
                    naluStart = i + 4
                    i += 4
                } else {
                    i++
                }
            }
            if (naluStart in 0 until payload.size) nalus += payload.copyOfRange(naluStart, payload.size)
            var cap: Double? = null
            var snd: Double? = null
            if (firstStart > 0) {
                val meta = runCatching { Json.parseToJsonElement(String(payload, 0, firstStart, Charsets.UTF_8)) as? JsonObject }.getOrNull()
                cap = meta?.number("cap")
                snd = meta?.number("snd")
            }
            return AccessUnit(cap, snd, nalus)
        }

        fun annexB(nalus: List<ByteArray>): ByteArray {
            val out = java.io.ByteArrayOutputStream(nalus.sumOf { it.size + 4 })
            nalus.forEach { out.write(START_CODE); out.write(it) }
            return out.toByteArray()
        }
    }
}

enum class NalKind { Vps, Sps, Pps, Sei, Keyframe, Slice, Other }

object NalUnits {
    fun kind(codec: StreamCodec, nalu: ByteArray): NalKind {
        val first = nalu.firstOrNull()?.toInt()?.and(0xFF) ?: return NalKind.Other
        return when (codec) {
            StreamCodec.H264 -> when (first and 0x1F) {
                7 -> NalKind.Sps
                8 -> NalKind.Pps
                6 -> NalKind.Sei
                5 -> NalKind.Keyframe
                1 -> NalKind.Slice
                else -> NalKind.Other
            }
            StreamCodec.Hevc -> when ((first shr 1) and 0x3F) {
                32 -> NalKind.Vps
                33 -> NalKind.Sps
                34 -> NalKind.Pps
                39, 40 -> NalKind.Sei
                in 16..21 -> NalKind.Keyframe
                in 0..9 -> NalKind.Slice
                else -> NalKind.Other
            }
        }
    }
}

/** What the decoder needs for one access unit. */
class DecodableSample(
    val codec: StreamCodec,
    /** Codec-specific data (start-code-prefixed parameter sets); non-null when the decoder must be (re)built. */
    val newFormat: List<ByteArray>?,
    val isKeyframe: Boolean,
    /** Slice NAL units only, start-code prefixed. */
    val data: ByteArray,
    val captureMs: Double?,
)

/**
 * Tracks the active parameter sets (5.1, 5.2, 5.4): a changed SPS/PPS/VPS
 * means a decoder rebuild, and nothing decodes until a keyframe arrives with
 * its parameter sets. A codec change drops everything.
 */
class ParameterSetTracker(codec: StreamCodec = StreamCodec.H264) {
    var codec: StreamCodec = codec
        private set
    private var vps: ByteArray? = null
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var formatPending = true
    private var awaitingKeyframe = true

    val needsKeyframe: Boolean get() = awaitingKeyframe

    fun reset(newCodec: StreamCodec = codec) {
        codec = newCodec
        vps = null; sps = null; pps = null
        formatPending = true
        awaitingKeyframe = true
    }

    /** Null when the unit cannot be decoded yet (no keyframe since the last reset or format change). */
    fun accept(unit: AccessUnit): DecodableSample? {
        val slices = mutableListOf<ByteArray>()
        var keyframe = false
        for (nalu in unit.nalus) {
            when (NalUnits.kind(codec, nalu)) {
                NalKind.Vps -> if (!nalu.contentEquals(vps)) { vps = nalu; formatPending = true }
                NalKind.Sps -> if (!nalu.contentEquals(sps)) { sps = nalu; formatPending = true }
                NalKind.Pps -> if (!nalu.contentEquals(pps)) { pps = nalu; formatPending = true }
                NalKind.Sei -> Unit
                NalKind.Keyframe -> { keyframe = true; slices += nalu }
                NalKind.Slice, NalKind.Other -> slices += nalu
            }
        }
        if (slices.isEmpty()) return null
        val sets = listOfNotNull(if (codec == StreamCodec.Hevc) vps ?: return null else null, sps ?: return null, pps ?: return null)
        if (formatPending && !keyframe) {
            awaitingKeyframe = true
            return null
        }
        if (awaitingKeyframe && !keyframe) return null
        awaitingKeyframe = false
        val newFormat = if (formatPending) sets.map { AccessUnit.annexB(listOf(it)) } else null
        formatPending = false
        return DecodableSample(codec, newFormat, keyframe, AccessUnit.annexB(slices), unit.captureMs)
    }
}
