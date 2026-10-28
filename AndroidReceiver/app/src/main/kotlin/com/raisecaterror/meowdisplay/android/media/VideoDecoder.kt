package com.raisecaterror.meowdisplay.android.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.raisecaterror.meowdisplay.core.session.StreamCodec
import com.raisecaterror.meowdisplay.core.video.DecodableSample
import com.raisecaterror.meowdisplay.core.video.DecodeQueue
import com.raisecaterror.meowdisplay.core.video.StreamStats
import java.nio.ByteBuffer

/**
 * Hardware decode straight to a Surface (PROTOCOL.md 5): one access unit per
 * input buffer, each picture rendered as soon as it decodes, no presentation
 * clock. MediaCodec runs in asynchronous mode, so output is rendered whenever
 * it is ready, independent of input; access units wait in a bounded
 * [DecodeQueue] until the codec offers an input buffer. Decoders recycle
 * input buffers only as they produce output, so a synchronous feed loop that
 * dropped a unit after a short wait lost the rest of its GOP.
 */
class VideoDecoder(
    private val requestKeyframe: () -> Unit,
    private val onVideoSize: (width: Int, height: Int) -> Unit,
    /** For the performance overlay. */
    private val stats: StreamStats? = null,
    /** A Mac capture time on this device's wall clock; null until the clocks are synced. */
    private val captureToLocalMs: (Double) -> Double? = { null },
) {
    private val thread = HandlerThread("meow-video").apply { start() }
    private val handler = Handler(thread.looper)

    // Everything below is confined to [thread]; codec callbacks run there too.
    private val queue = DecodeQueue()
    private val freeInputs = ArrayDeque<Int>()
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var inputCapacity = 0
    private var decodedFrames = 0L
    /** Queue time (µs, the codec's presentation time) -> Mac capture time, for latency. Bounded. */
    private val captureTimes = object : LinkedHashMap<Long, Double>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Double>?) = size > 64
    }

    // Diagnostics: a bounded trace after each (re)configuration.
    private var traced = 0
    private fun now() = SystemClock.elapsedRealtime()
    private fun trace(message: String) {
        if (traced++ < TRACE_LIMIT) Log.i(TRACE, "t=${now()} $message")
    }

    fun setSurface(target: Surface?) = handler.post {
        Log.i(TRACE, "t=${now()} surface ${if (target == null) "cleared" else "set"} (codec=${codec != null}, held=${queue.size})")
        if (target === surface) return@post
        val hadCodec = codec != null
        release()
        surface = target
        // The pictures the old codec consumed are gone with it.
        if (hadCodec && queue.decoderLost()) requestKeyframe()
        if (target == null) return@post
        if (queue.awaitingKeyframe) requestKeyframe() else startIfReady()
    }

    fun submit(sample: DecodableSample) = handler.post {
        stats?.frameArrived(sample.data.size, System.currentTimeMillis().toDouble())
        when (queue.offer(sample)) {
            DecodeQueue.Offer.HeldNeedsDecoder -> {
                trace("format ${sample.codec.wire} sets=" + sample.newFormat!!.joinToString { "${it.size}B" })
                release()
                startIfReady()
            }
            DecodeQueue.Offer.Held -> if (codec == null) startIfReady() else feed()
            DecodeQueue.Offer.NeedsKeyframe -> {
                trace("refused unit: no keyframe yet")
                requestKeyframe()
            }
            DecodeQueue.Offer.Overflowed -> {
                stats?.frameDropped(System.currentTimeMillis().toDouble())
                Log.w(TAG, "decoder fell behind: dropped its queue, waiting for a keyframe")
                requestKeyframe()
            }
        }
    }

    /** The stream stopped, changed codec or the session changed: nothing carries over. */
    fun reset() = handler.post {
        Log.i(TRACE, "t=${now()} reset (codec=${codec != null})")
        release()
        queue.reset()
    }

    fun shutdown() {
        handler.post { release() }
        thread.quitSafely()
    }

    /** Builds the decoder once there is a surface, a format and a keyframe waiting. */
    private fun startIfReady() {
        if (codec != null || surface == null || queue.format == null || queue.isEmpty) return
        configure()
    }

    private fun feed() {
        val active = codec ?: return
        while (freeInputs.isNotEmpty()) {
            val sample = queue.next() ?: return
            val index = freeInputs.removeFirst()
            try {
                val input = active.getInputBuffer(index)
                if (input == null) {
                    queue.putBack(sample)
                    return
                }
                if (sample.data.size > input.capacity()) {
                    // Never truncate: rebuild with room for it and replay from a keyframe.
                    inputCapacity = input.capacity()
                    queue.putBack(sample)
                    Log.w(TAG, "access unit of ${sample.data.size} bytes exceeds input capacity ${input.capacity()}: rebuilding")
                    release()
                    if (queue.decoderLost()) requestKeyframe() else startIfReady()
                    return
                }
                input.clear()
                input.put(sample.data)
                val queuedUs = System.nanoTime() / 1000
                sample.captureMs?.let { captureTimes[queuedUs] = it }
                active.queueInputBuffer(index, 0, sample.data.size, queuedUs, if (sample.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                trace("queued #$index key=${sample.isKeyframe} bytes=${sample.data.size} held=${queue.size}")
            } catch (e: IllegalStateException) {
                failed(active, e)
                return
            }
        }
    }

    private fun configure() {
        val sets = queue.format ?: return
        val target = surface ?: return
        val mime = if (queue.codec == StreamCodec.Hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        traced = 0
        try {
            // The picture size comes from the SPS; these only size the buffers.
            val format = MediaFormat.createVideoFormat(mime, NOMINAL_WIDTH, NOMINAL_HEIGHT).apply {
                if (queue.codec == StreamCodec.Hevc) {
                    setByteBuffer("csd-0", ByteBuffer.wrap(sets.reduce(ByteArray::plus)))
                } else {
                    setByteBuffer("csd-0", ByteBuffer.wrap(sets[0]))
                    setByteBuffer("csd-1", ByteBuffer.wrap(sets[1]))
                }
                // The codec sizes its own buffers; only a unit that outgrew them asks for more:
                // twice the largest seen, capped at the receiver's frame cap.
                if (inputCapacity > 0 && queue.largestUnit > inputCapacity) {
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minOf(queue.largestUnit.toLong() * 2, MAX_UNIT_BYTES.toLong()).toInt())
                }
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            }
            val created = MediaCodec.createDecoderByType(mime)
            // Low-latency mode only where the decoder offers it: some hardware decoders (the Moto
            // G5S Plus's OMX.qcom AVC) refuse to configure at all when asked, which used to drop
            // every session to the much slower software decoder. Qualcomm decoders also hold a
            // frame for reordering unless told to output in decode order (the stream has none).
            val optional = buildList {
                val claimsLowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && runCatching {
                    created.codecInfo.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                }.getOrDefault(false)
                if (claimsLowLatency) add(MediaFormat.KEY_LOW_LATENCY)
                if (created.name.startsWith("OMX.qcom.") || created.name.startsWith("c2.qti.")) {
                    add(QCOM_PICTURE_ORDER); add(QCOM_LOW_LATENCY)
                }
            }
            optional.forEach { format.setInteger(it, 1) }
            trace("codec ${created.name} hw=${created.codecInfo.isHardwareAccelerated} configure $format")
            created.setCallback(Callbacks(created), handler)
            try {
                created.configure(format, target, null, 0)
            } catch (e: MediaCodec.CodecException) {
                if (optional.isEmpty()) throw e
                // Refused: the same decoder, without the optional keys.
                Log.w(TAG, "${created.name} refused $optional; configuring without them")
                created.reset()
                optional.forEach { format.removeKey(it) }
                created.setCallback(Callbacks(created), handler)
                created.configure(format, target, null, 0)
            }
            codec = created
            created.start()
            inputCapacity = created.inputFormat.takeIf { it.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE) }
                ?.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) ?: 0
            decodedFrames = 0
            trace("started; input capacity $inputCapacity, held ${queue.size}")
        } catch (e: Exception) {
            Log.w(TAG, "configure $mime failed: $e")
            release()
            if (queue.decoderLost()) requestKeyframe()
        }
    }

    private inner class Callbacks(private val owner: MediaCodec) : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            if (owner !== this@VideoDecoder.codec) return
            freeInputs.addLast(index)
            feed()
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (owner !== this@VideoDecoder.codec) return
            try {
                codec.releaseOutputBuffer(index, true)
            } catch (e: IllegalStateException) {
                failed(owner, e)
                return
            }
            stats?.let { st ->
                val nowMs = System.currentTimeMillis().toDouble()
                val latency = captureTimes.remove(info.presentationTimeUs)?.let(captureToLocalMs)?.let { nowMs - it }
                st.frameShown((System.nanoTime() / 1000 - info.presentationTimeUs) / 1000.0, latency, nowMs)
            }
            if (++decodedFrames % LOG_EVERY == 1L) Log.i(TAG, "decoded $decodedFrames frames (${queue.codec.wire})")
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            if (owner !== this@VideoDecoder.codec) return
            val width = format.cropWidth() ?: format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.cropHeight() ?: format.getInteger(MediaFormat.KEY_HEIGHT)
            Log.i(TAG, "output ${width}x$height (${queue.codec.wire})")
            onVideoSize(width, height)
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            if (owner !== this@VideoDecoder.codec) return
            trace("codec error transient=${e.isTransient} recoverable=${e.isRecoverable} ${e.diagnosticInfo}")
            failed(owner, e)
        }
    }

    private fun failed(owner: MediaCodec, e: Exception) {
        if (owner !== codec) return
        Log.w(TAG, "decoder reset: $e")
        release()
        if (queue.decoderLost()) requestKeyframe() else startIfReady()
    }

    private fun release() {
        codec?.let {
            trace("release ${it.name} after $decodedFrames frames")
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
        freeInputs.clear()
    }

    private fun MediaFormat.cropWidth(): Int? =
        if (containsKey("crop-right") && containsKey("crop-left")) getInteger("crop-right") - getInteger("crop-left") + 1 else null

    private fun MediaFormat.cropHeight(): Int? =
        if (containsKey("crop-bottom") && containsKey("crop-top")) getInteger("crop-bottom") - getInteger("crop-top") + 1 else null

    private companion object {
        /** Qualcomm vendor keys: output in decode order, and its own low-latency switch. */
        const val QCOM_PICTURE_ORDER = "vendor.qti-ext-dec-picture-order.enable"
        const val QCOM_LOW_LATENCY = "vendor.qti-ext-dec-low-latency.enable"
        const val TAG = "MeowDecoder"
        const val TRACE = "MeowDecoderTrace"
        const val TRACE_LIMIT = 40
        const val NOMINAL_WIDTH = 1920
        const val NOMINAL_HEIGHT = 1080
        // The receiver's cap on any sender frame (WireFraming.MAX_INCOMING_BYTES).
        const val MAX_UNIT_BYTES = 32 shl 20
        const val LOG_EVERY = 15L
    }
}
