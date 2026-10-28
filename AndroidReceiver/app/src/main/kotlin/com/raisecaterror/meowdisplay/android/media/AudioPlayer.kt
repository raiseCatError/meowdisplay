package com.raisecaterror.meowdisplay.android.media

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.raisecaterror.meowdisplay.core.wire.AudioMediaFrame
import com.raisecaterror.meowdisplay.core.wire.AudioPlaybackPlanner
import java.nio.ByteBuffer

/**
 * The Mac's system audio (PROTOCOL.md 5A): AAC-LC built from the config
 * frame's AudioSpecificConfig, or raw 16-bit PCM. Timing follows the iOS
 * receiver's continuous scheduling ([AudioPlaybackPlanner]): the first
 * buffer waits a preroll plus the A/V offset, the rest chain in the
 * streaming AudioTrack, a real discontinuity re-anchors, and a backlog
 * drops the newest packet. Malformed or out-of-order input is dropped,
 * never fatal.
 */
class AudioPlayer(avSyncOffsetMs: () -> Int = { 0 }) {
    private val thread = HandlerThread("meow-audio").apply { start() }
    private val handler = Handler(thread.looper)
    private val info = MediaCodec.BufferInfo()

    // Confined to [thread].
    private var decoder: MediaCodec? = null
    private var track: AudioTrack? = null
    private var pcm = false
    private val planner = AudioPlaybackPlanner(avSyncOffsetMs)
    private var sampleRate = 48_000
    private var channels = 2
    private var framesWritten = 0L
    private var headBaseline = 0L

    fun submit(frame: AudioMediaFrame) = handler.post {
        try {
            when (frame) {
                is AudioMediaFrame.Config -> configureAac(frame)
                is AudioMediaFrame.PcmConfig -> configurePcm(frame)
                is AudioMediaFrame.Packet -> if (!pcm && admit(frame.sequence, frame.capturedAtMs, AAC_FRAMES_PER_PACKET)) decodeAac(frame.payload.value)
                is AudioMediaFrame.PcmPacket -> if (pcm && admit(frame.sequence, frame.capturedAtMs, frame.frameCount.toInt())) {
                    writePcm(frame.payload.value, 0, frame.payload.value.size)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio reset: $e")
            release()
        }
    }

    /** Audio off, paused or a new session: stop and forget the format. */
    fun stop() = handler.post { release() }

    fun shutdown() {
        handler.post { release() }
        thread.quitSafely()
    }

    private fun configureAac(config: AudioMediaFrame.Config) {
        release()
        val rate = config.sampleRate.toInt().takeIf { it in 8_000..96_000 } ?: return
        val channels = config.channelCount.takeIf { it in 1..2 } ?: return
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(config.cookie.value))
        }
        decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(format, null, null, 0)
            start()
        }
        track = newTrack(rate, channels)
        pcm = false
        startGeneration(rate, channels)
    }

    private fun configurePcm(config: AudioMediaFrame.PcmConfig) {
        release()
        val rate = config.sampleRate.toInt().takeIf { it in 8_000..96_000 } ?: return
        val channels = config.channelCount.takeIf { it in 1..2 } ?: return
        track = newTrack(rate, channels)
        pcm = true
        startGeneration(rate, channels)
    }

    private fun startGeneration(rate: Int, channelCount: Int) {
        sampleRate = rate
        channels = channelCount
        framesWritten = 0
        headBaseline = 0
        planner.reset()
    }

    /** The planner's verdict for one packet; writes the anchor's silence (after a flush) when it asks. */
    private fun admit(sequence: Long, capturedAtMs: Long, packetFrames: Int): Boolean {
        val active = track ?: return false
        val frames = packetFrames.coerceAtLeast(1)
        val played = (active.playbackHeadPosition.toLong() and 0xFFFF_FFFFL) - headBaseline
        val pending = ((framesWritten - played).coerceAtLeast(0) / frames).toInt()
        return when (val decision = planner.packet(sequence, capturedAtMs, frames * 1000.0 / sampleRate, sampleRate, pending)) {
            is AudioPlaybackPlanner.Decision.Drop -> false
            is AudioPlaybackPlanner.Decision.Play -> {
                if (decision.flush) {
                    active.pause()
                    active.flush()
                    active.play()
                    framesWritten = 0
                    headBaseline = active.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
                }
                if (decision.leadingSilenceFrames > 0) {
                    val silence = ByteArray(decision.leadingSilenceFrames * channels * BYTES_PER_SAMPLE)
                    writePcm(silence, 0, silence.size)
                }
                true
            }
        }
    }

    private fun writePcm(bytes: ByteArray, offset: Int, size: Int) {
        val written = track?.write(bytes, offset, size, AudioTrack.WRITE_NON_BLOCKING) ?: return
        if (written > 0) framesWritten += written / (channels * BYTES_PER_SAMPLE)
    }

    private fun decodeAac(payload: ByteArray) {
        val active = decoder ?: return
        val index = active.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index >= 0) {
            val input = active.getInputBuffer(index) ?: return
            input.clear()
            if (payload.size > input.capacity()) {
                active.queueInputBuffer(index, 0, 0, 0, 0)
                return
            }
            input.put(payload)
            active.queueInputBuffer(index, 0, payload.size, System.nanoTime() / 1000, 0)
        }
        while (true) {
            val out = active.dequeueOutputBuffer(info, 0)
            if (out < 0) return
            val buffer = active.getOutputBuffer(out)
            if (buffer != null && info.size > 0) {
                buffer.position(info.offset)
                buffer.limit(info.offset + info.size)
                val written = track?.write(buffer, info.size, AudioTrack.WRITE_NON_BLOCKING) ?: 0
                if (written > 0) framesWritten += written / (channels * BYTES_PER_SAMPLE)
            }
            active.releaseOutputBuffer(out, false)
        }
    }

    private fun newTrack(rate: Int, channels: Int): AudioTrack {
        val mask = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_UNKNOWN).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(mask).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(minimum * 2)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .apply { play() }
    }

    private fun release() {
        decoder?.let { runCatching { it.stop() }; runCatching { it.release() } }
        decoder = null
        track?.let { runCatching { it.stop() }; runCatching { it.release() } }
        track = null
        pcm = false
    }

    private companion object {
        const val TAG = "MeowAudio"
        const val INPUT_TIMEOUT_US = 10_000L
        const val AAC_FRAMES_PER_PACKET = 1024
        const val BYTES_PER_SAMPLE = 2
    }
}
