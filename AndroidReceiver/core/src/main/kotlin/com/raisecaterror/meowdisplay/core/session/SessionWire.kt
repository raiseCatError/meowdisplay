package com.raisecaterror.meowdisplay.core.session

import com.raisecaterror.meowdisplay.core.wire.ControlChunkWire
import com.raisecaterror.meowdisplay.core.crypto.utf8
import com.raisecaterror.meowdisplay.core.pairing.PairingProtocol
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** The media protocol's version gates (Shared/Protocol.swift `WireProtocol`). */
object WireProtocol {
    const val VERSION = 22
    const val MIN_SUPPORTED_PEER = 1
    const val ASSUMED_WHEN_ABSENT = 1
    const val PENCIL = 3
    const val KEYBOARD = 4
    const val POINTER = 5
    const val RECEIVER_CONTROLS = 6
    const val DISPLAY_MODE = 7
    const val ALLOW_INPUT = 8
    const val VIDEO_CONTROL = 9
    const val NATIVE_APP_GESTURE = 10
    const val AUDIO = 12
    const val MIRROR_DISPLAY = 13
    const val EXTEND_SHAPE = 14
    const val MAX_FPS = 15
    const val STREAMING_PRIORITY = 16
    const val MIRROR_UNAVAILABLE = 17
    const val SMART_TOUCH = 20
    const val SESSION_INVITATION = 21
    /** The oldest receiver pv whose `streamingProfileRequest` the Mac honors (pinned at 21). */
    const val STREAMING_PROFILE_REQUEST = 21
    const val MEDIA_PORT = 9001
    const val DEVICE_KIND = "Android"
}

enum class DisplayMode(val wire: String) {
    Mirror("mirror"), Extend("extend"),
    /** Selected Mac windows (PROTOCOL.md 6.10); only with a Mac that offers it. */
    Window("window");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

enum class StreamCodec(val wire: String) {
    H264("h264"), Hevc("hevc");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** `allowInputState.state` (pv 18); `allowed` stays the effective on/off for every peer. */
enum class InputWireState(val wire: String) {
    Off("off"), Requesting("requesting"), Allowed("allowed"), NotAllowed("notAllowed"), RequestsDisabled("requestsDisabled");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** What this receiver announces in `hello` (PROTOCOL.md 6.1). Never addresses: phones don't offer cable upgrade. */
data class HelloFields(
    val pixelsWide: Int,
    val pixelsHigh: Int,
    val scale: Double,
    val installID: String,
    val requestedMode: DisplayMode? = null,
    /** Window workspaces version this receiver speaks (hello `ws`); null = none. */
    val windowWorkspace: Int? = null,
    val trayEnabled: Boolean = true,
    val keyboardButtonEnabled: Boolean = true,
    val maxEncodeWide: Int? = null,
    val maxEncodeHigh: Int? = null,
    val maxFPS: Int? = null,
    val codecs: List<StreamCodec> = listOf(StreamCodec.H264),
)

/** Receiver-to-sender control messages, each one JSON object in one frame. */
object ReceiverMessages {
    fun hello(fields: HelloFields) = buildJsonObject {
        put("type", "hello")
        put("pixelsWide", fields.pixelsWide)
        put("pixelsHigh", fields.pixelsHigh)
        put("scale", fields.scale)
        put("device", WireProtocol.DEVICE_KIND)
        put("id", fields.installID)
        put("pv", WireProtocol.VERSION)
        // Unauthenticated pairing-version hint, early UX only.
        put("pp", PairingProtocol.VERSION)
        // Older Macs read only mirror/extend here; Window is asked for with displayModeRequest instead.
        fields.requestedMode?.takeIf { it != DisplayMode.Window }?.let { put("requestedMode", it.wire) }
        fields.windowWorkspace?.let { put("ws", it) }
        // This receiver reassembles control messages sent in parts (PROTOCOL.md 6.14).
        put(ControlChunkWire.HELLO_FIELD, ControlChunkWire.VERSION)
        put("trayEnabled", fields.trayEnabled)
        put("keyboardButtonEnabled", fields.keyboardButtonEnabled)
        if (fields.maxEncodeWide != null && fields.maxEncodeHigh != null) {
            put("maxEncodeWide", fields.maxEncodeWide)
            put("maxEncodeHigh", fields.maxEncodeHigh)
        }
        fields.maxFPS?.let { put("maxFPS", it) }
        put("codecs", buildJsonArray { (listOf(StreamCodec.H264) + fields.codecs).distinct().forEach { add(JsonPrimitive(it.wire)) } })
        // No QUIC listener: TCP only, and never `qv` (PROTOCOL.md 2.2a).
        put("transports", buildJsonArray { add(JsonPrimitive("tcp")) })
    }

    fun ping(nowMs: Long) = buildJsonObject { put("type", "ping"); put("t", nowMs) }
    fun keyframeRequest() = typeOnly("kf")
    fun closing() = typeOnly("closing")
    fun sleeping() = typeOnly("sleeping")
    fun allowInputRequest(allowed: Boolean) = buildJsonObject { put("type", "allowInputRequest"); put("allowed", allowed) }
    fun audioRequest(enabled: Boolean) = buildJsonObject { put("type", "audioRequest"); put("enabled", enabled) }
    fun videoRequest(enabled: Boolean) = buildJsonObject { put("type", "videoRequest"); put("enabled", enabled) }
    fun invitationResponse(id: String, result: InvitationResult) =
        buildJsonObject { put("type", "sessionInviteResponse"); put("id", id); put("result", result.wire) }

    fun encode(message: JsonObject): ByteArray = message.toString().utf8

    fun displayModeRequest(mode: DisplayMode) = buildJsonObject { put("type", "displayModeRequest"); put("mode", mode.wire) }

    private fun typeOnly(type: String) = buildJsonObject { put("type", type) }
}

/** Sender-to-receiver control messages this core acts on (PROTOCOL.md 6.2). */
/** The paired Mac's user name as shown: printable, one line, at most [MAX] characters. */
object PairedMacUser {
    const val MAX = 64
    /** Invisible or layout-changing characters (controls, bidi overrides, separators) are dropped,
     *  so a name can't disguise itself as another Mac's ID; same rule as the Mac and iOS. */
    private val dropped = setOf(
        Character.CONTROL, Character.FORMAT, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
        Character.SURROGATE, Character.UNASSIGNED, Character.PRIVATE_USE,
    ).map { it.toInt() }.toSet()

    fun clean(raw: String?): String? {
        val text = raw?.filter { Character.getType(it) !in dropped }?.trim() ?: return null
        return text.take(MAX).ifEmpty { null }
    }
}

sealed interface SenderMessage {
    /** [privacyShield]: the Mac covers its own screens while this device is connected (null: an older Mac). */
    /** [user]: the full name of who uses the Mac (paired sessions only; null: hidden or an older Mac). */
    data class Welcome(val pv: Int, val min: Int, val features: Set<String> = emptySet(), val privacyShield: Boolean? = null,
                       val user: String? = null) : SenderMessage
    data class UpdateRequired(val message: String?, val store: String?) : SenderMessage
    data class Pong(val t: Double, val mt: Double) : SenderMessage
    data object Ping : SenderMessage
    data class Invite(val invitation: SessionInvitation) : SenderMessage
    data class InviteCancel(val id: String) : SenderMessage
    data class AllowInputState(val allowed: Boolean, val state: InputWireState) : SenderMessage
    data class VideoState(val enabled: Boolean, val width: Int?, val height: Int?) : SenderMessage
    data class AudioState(val enabled: Boolean) : SenderMessage
    data class CodecState(val codec: StreamCodec) : SenderMessage
    data class DisplayPaused(val paused: Boolean) : SenderMessage
    data class DisplayModeState(val mode: DisplayMode) : SenderMessage
    /** [pane]: Window mode's scale and rotation of the pane under the cursor (PROTOCOL.md 6.10); null otherwise. */
    data class Cursor(val x: Double, val y: Double, val visible: Boolean, val sequence: Long?, val pane: CursorPane? = null) : SenderMessage

    /**
     * The Mac's focused text caret as a rectangle normalized to the streamed display, top-left
     * origin (`visible` false: none known). Optional and additive (PROTOCOL.md 6.11): only ever a
     * rectangle, never text.
     */
    data class TextCaret(
        val x: Double,
        val y: Double,
        val width: Double,
        val height: Double,
        val visible: Boolean,
        val sequence: Long?,
    ) : SenderMessage

    data object InputReset : SenderMessage
    data object Closing : SenderMessage

    /** One part of a message too long for one control frame (PROTOCOL.md 6.14). */
    class Chunk(val body: JsonObject) : SenderMessage

    /** A type this core leaves to the app (cursor sprite, UI preferences, ...). */
    data class Other(val type: String, val body: JsonObject) : SenderMessage

    companion object {
        private val json = Json { isLenient = false }

        /**
         * Null for anything to ignore: not JSON, no `type`, or a known type with
         * a missing or mistyped required field. Never throws (PROTOCOL.md 6).
         */
        fun parse(text: String): SenderMessage? {
            val obj = try {
                json.parseToJsonElement(text) as? JsonObject
            } catch (_: Exception) {
                null
            } catch (_: StackOverflowError) {
                null
            } ?: return null
            val type = obj.string("type") ?: return null
            return when (type) {
                "welcome" -> Welcome(
                    pv = obj.int("pv") ?: WireProtocol.ASSUMED_WHEN_ABSENT,
                    min = obj.int("min") ?: WireProtocol.ASSUMED_WHEN_ABSENT,
                    features = (obj["features"] as? kotlinx.serialization.json.JsonArray)?.take(16)
                        ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.take(32) }?.toSet() ?: emptySet(),
                    privacyShield = (obj["privacyShield"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull(),
                    user = PairedMacUser.clean((obj["user"] as? JsonPrimitive)?.takeIf { it.isString }?.content),
                )
                "updateRequired" -> UpdateRequired(obj.string("message"), obj.string("store"))
                "pong" -> {
                    val t = obj.number("t") ?: return null
                    val mt = obj.number("mt") ?: return null
                    Pong(t, mt)
                }
                "ping" -> Ping
                "sessionInvite" -> SessionInvitation.parse(obj)?.let(::Invite)
                "sessionInviteCancel" -> obj.string("id")?.let(::InviteCancel)
                "allowInputState" -> {
                    val allowed = obj.bool("allowed") ?: return null
                    AllowInputState(allowed, InputWireState.of(obj.string("state")) ?: if (allowed) InputWireState.Allowed else InputWireState.Off)
                }
                "videoState" -> VideoState(obj.bool("enabled") ?: return null, obj.int("width"), obj.int("height"))
                "audioState" -> AudioState(obj.bool("enabled") ?: return null)
                "streamCodecState" -> StreamCodec.of(obj.string("codec"))?.let(::CodecState)
                "displayState" -> when (obj.string("state")) {
                    "paused" -> DisplayPaused(true)
                    "running" -> DisplayPaused(false)
                    else -> null
                }
                "displayModeState" -> DisplayMode.of(obj.string("mode"))?.let(::DisplayModeState)
                "cursor" -> Cursor(
                    x = obj.number("x") ?: 0.0,
                    y = obj.number("y") ?: 0.0,
                    visible = obj.int("v") == 1,
                    sequence = obj.long("s")?.takeIf { it >= 0 },
                    pane = CursorPane.parse(obj.number("kx"), obj.number("ky"), obj.int("r")),
                )
                "textCaret" -> {
                    val sequence = obj.long("s")?.takeIf { it >= 0 }
                    if (obj.int("v") != 1) {
                        TextCaret(0.0, 0.0, 0.0, 0.0, visible = false, sequence = sequence)
                    } else {
                        // A visible caret needs a finite x and y; the size defaults to zero.
                        val x = obj.number("x") ?: return null
                        val y = obj.number("y") ?: return null
                        TextCaret(
                            x, y,
                            (obj.number("w") ?: 0.0).coerceIn(0.0, 1.0),
                            (obj.number("h") ?: 0.0).coerceIn(0.0, 1.0),
                            visible = true, sequence = sequence,
                        )
                    }
                }
                "inputReset" -> InputReset
                "closing" -> Closing
                ControlChunkWire.TYPE -> Chunk(obj)
                else -> Other(type, obj)
            }
        }
    }
}

internal fun JsonObject.primitive(key: String): JsonPrimitive? = get(key) as? JsonPrimitive

internal fun JsonObject.string(key: String): String? = primitive(key)?.takeIf { it.isString }?.content

internal fun JsonObject.bool(key: String): Boolean? = primitive(key)?.takeIf { !it.isString }?.booleanOrNull

internal fun JsonObject.number(key: String): Double? =
    primitive(key)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }

/** Integral JSON numbers only (`22` or `22.0`), within Int range. */
internal fun JsonObject.int(key: String): Int? =
    long(key)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

internal fun JsonObject.long(key: String): Long? {
    val p = primitive(key)?.takeIf { !it.isString } ?: return null
    p.longOrNull?.let { return it }
    val d = p.doubleOrNull ?: return null
    return if (d.isFinite() && d == Math.rint(d) && d >= Long.MIN_VALUE && d <= Long.MAX_VALUE) d.toLong() else null
}

internal fun JsonObject.array(key: String): JsonArray? = get(key) as? JsonArray

/**
 * Window mode: how big one Mac point is where the cursor is ([kx]/[ky], normalized to the canvas
 * width and height: the pane's Fit/Fill and zoom) and the pane's rotation in degrees. The cursor
 * sprite is sized from its size in Mac points times these, so it keeps its shape.
 */
data class CursorPane(val kx: Double, val ky: Double, val rotation: Int) {
    companion object {
        fun parse(kx: Double?, ky: Double?, r: Int?): CursorPane? {
            if (kx == null || ky == null || !(kx > 0 && kx < 1) || !(ky > 0 && ky < 1)) return null
            return CursorPane(kx, ky, (((r ?: 0) % 360) + 360) % 360)
        }
    }
}
