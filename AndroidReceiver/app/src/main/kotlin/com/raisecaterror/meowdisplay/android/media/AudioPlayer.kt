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
import java.nio.ByteBuffer

/**
 * The Mac's system audio (PROTOCOL.md 5A): AAC-LC built from the config
 * frame's AudioSpecificConfig, or raw 16-bit PCM, played as it arrives.
 * Malformed or out-of-order input is dropped, never fatal.
 */
class AudioPlayer {
    private val thread = HandlerThread("meow-audio").apply { start() }
    private val handler = Handler(thread.looper)
    private val info = MediaCodec.BufferInfo()

    // Confined to [thread].
    private var decoder: MediaCodec? = null
    private var track: AudioTrack? = null
    private var pcm = false

    fun submit(frame: AudioMediaFrame) = handler.post {
        try {
            when (frame) {
                is AudioMediaFrame.Config -> configureAac(frame)
                is AudioMediaFrame.PcmConfig -> configurePcm(frame)
                is AudioMediaFrame.Packet -> decodeAac(frame.payload.value)
                is AudioMediaFrame.PcmPacket -> if (pcm) track?.write(frame.payload.value, 0, frame.payload.value.size, AudioTrack.WRITE_NON_BLOCKING)
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
    }

    private fun configurePcm(config: AudioMediaFrame.PcmConfig) {
        release()
        val rate = config.sampleRate.toInt().takeIf { it in 8_000..96_000 } ?: return
        val channels = config.channelCount.takeIf { it in 1..2 } ?: return
        track = newTrack(rate, channels)
        pcm = true
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
                track?.write(buffer, info.size, AudioTrack.WRITE_NON_BLOCKING)
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
    }
}
