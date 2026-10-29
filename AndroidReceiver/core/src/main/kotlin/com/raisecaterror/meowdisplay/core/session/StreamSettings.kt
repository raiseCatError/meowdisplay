package com.raisecaterror.meowdisplay.core.session

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/*
 * The Mac-authoritative stream and display settings a receiver can ask for (PROTOCOL.md 6.6–6.8,
 * Shared/StreamingProfile.swift, StreamingPriority.swift, ExtendDisplayShape.swift,
 * ReceiverMaxFPS.swift, MacSender `sendMirrorDisplayState`). The receiver only requests; what it
 * shows is what the Mac confirmed, with this device's own request in flight shown until the Mac
 * answers or [StreamSettingsModel.PENDING_TIMEOUT_MS] passes (iOS uses the same 15 s).
 */

/** How the Mac trades refresh rate against power and bandwidth (Mac-wide on the Mac). */
enum class StreamingProfile(val wire: String, val title: String, val explanation: String) {
    Efficiency("efficiency", "Efficiency", "Lower power/bandwidth, up to 60 FPS."),
    Performance("performance", "Performance", "Prioritize responsiveness, up to the receiver's supported refresh rate, capped at 120 FPS."),
    Custom("custom", "Custom", "Manual streaming controls.");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** Custom profile's frame rate. Auto asks for the same ceiling as Performance. */
enum class CustomFrameRate(val wire: String, val title: String) {
    Auto("auto", "Auto"), Fps30("fps30", "30"), Fps60("fps60", "60"), Fps90("fps90", "90"), Fps120("fps120", "120");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** How the Mac's encoder trades sustained frame rate against latency. */
enum class StreamingPriority(val wire: String, val title: String, val explanation: String) {
    Auto("auto", "Auto", "Balanced default."),
    PreferFps("preferFPS", "Prefer FPS", "Favors smooth, sustained frame rate, allowing a small amount of extra work in flight at a small cost to latency."),
    PreferLatency("preferLatency", "Prefer Latency", "Favors the newest frame and bounded latency, accepting lower frame rate under pressure.");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** The Extend virtual display's aspect ratio. */
enum class ExtendShape(val wire: String) {
    Automatic("automatic"), R16x10("16:10"), R16x9("16:9"), R3x2("3:2"), R4x3("4:3"),
    R5x4("5:4"), R21x9("21:9"), R32x9("32:9"), R1x1("1:1");

    val title: String get() = if (this == Automatic) "Automatic" else wire

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** `useFullDisplay` applies to Automatic only: it matches this device's own screen shape. */
data class ExtendShapePreference(val shape: ExtendShape = ExtendShape.Automatic, val useFullDisplay: Boolean = false)

/** This receiver's own enforced frame-rate ceiling, kept per receiver on the Mac. */
data class MaxFPSPreference(val enabled: Boolean = false, val maxFPS: Int = 60)

/** `maxFPSState`: the confirmed preference plus the Mac's ceilings for the current encode size. */
data class MaxFPSState(
    val preference: MaxFPSPreference,
    /** Tiers this device may choose now (the Mac filtered out unreachable ones). */
    val availableTiers: List<Int>,
    val encoderSafeFPS: Int?,
    val requestedFPS: Int?,
    val effectiveFPS: Int?,
    val reason: String?,
)

/** One Mac display Mirror can show. */
data class MirrorDisplay(
    val uuid: String,
    val name: String,
    val isMain: Boolean,
    val pixelWidth: Int?,
    val pixelHeight: Int?,
    val likelyVirtual: Boolean,
)

/** `mirrorDisplayState`: null [selectedUUID] is Auto. */
data class MirrorDisplayState(val selectedUUID: String?, val displays: List<MirrorDisplay>) {
    val selectionUnavailable: Boolean get() = selectedUUID != null && displays.none { it.uuid == selectedUUID }
}

/** Everything the settings screen shows. Null confirmed values: the Mac hasn't said (yet, or at all). */
data class StreamSettings(
    /** The Mac's protocol version on this connection (0 before its welcome). */
    val macProtocolVersion: Int = 0,
    val profile: StreamingProfile? = null,
    /** The Custom frame rate this device last asked for (the Mac's state carries only the profile). */
    val customFrameRate: CustomFrameRate = CustomFrameRate.Auto,
    val priority: StreamingPriority? = null,
    val extendShape: ExtendShapePreference? = null,
    val pendingExtendShape: ExtendShapePreference? = null,
    val maxFPS: MaxFPSPreference? = null,
    val pendingMaxFPS: MaxFPSPreference? = null,
    val maxFPSState: MaxFPSState? = null,
    val mirrorDisplays: MirrorDisplayState? = null,
    /** The Mac has no usable physical display to mirror (a headless Mac): offer Extend. */
    val mirrorUnavailable: Boolean = false,
    /** Video on/off as the Mac confirmed it (`videoState`); null until it says. */
    val videoEnabled: Boolean? = null,
) {
    val supportsVideoControl get() = macProtocolVersion >= WireProtocol.VIDEO_CONTROL
    val supportsMirrorDisplay get() = macProtocolVersion >= WireProtocol.MIRROR_DISPLAY
    val supportsExtendShape get() = macProtocolVersion >= WireProtocol.EXTEND_SHAPE
    val supportsMaxFPS get() = macProtocolVersion >= WireProtocol.MAX_FPS
    val supportsPriority get() = macProtocolVersion >= WireProtocol.STREAMING_PRIORITY
    val supportsProfileRequest get() = macProtocolVersion >= WireProtocol.STREAMING_PROFILE_REQUEST
    val shownExtendShape get() = pendingExtendShape ?: extendShape
    val shownMaxFPS get() = pendingMaxFPS ?: maxFPS

    /** Tiers for the Maximum FPS picker: what the Mac offered, else the Mac's standard list. */
    val maxFPSTiers: List<Int> get() = maxFPSState?.availableTiers?.takeIf { it.isNotEmpty() } ?: STANDARD_FPS_TIERS

    /**
     * "Performance requests 120 FPS. Limited to 60 FPS at this display size." when the encoder,
     * not this device, is what holds the rate down; null otherwise (iOS `fpsLimitationText`).
     */
    val fpsLimitationText: String?
        get() {
            val state = maxFPSState ?: return null
            val safe = state.encoderSafeFPS ?: return null
            val requested = state.requestedFPS ?: return null
            if (safe >= requested) return null
            val name = (profile ?: StreamingProfile.Performance).title
            return "$name requests $requested FPS. Limited to $safe FPS at this display size."
        }

    companion object {
        /** EncoderCapability.supportedFPSTiers on the Mac. */
        val STANDARD_FPS_TIERS = listOf(1, 5, 10, 24, 30, 60, 120)

        /** The tier a stored ceiling shows as: the highest tier at or below it, else the lowest (PickerSelection.ceiling). */
        fun tierFor(maxFPS: Int, tiers: List<Int>): Int = tiers.filter { it <= maxFPS }.maxOrNull() ?: tiers.minOrNull() ?: maxFPS
    }
}

/** Parsed Mac → receiver setting states. */
sealed interface StreamSettingsUpdate {
    data class Profile(val profile: StreamingProfile) : StreamSettingsUpdate
    data class Priority(val priority: StreamingPriority) : StreamSettingsUpdate
    data class ExtendShapeConfirmed(val preference: ExtendShapePreference) : StreamSettingsUpdate
    data class MaxFPS(val state: MaxFPSState) : StreamSettingsUpdate
    data class MirrorDisplays(val state: MirrorDisplayState) : StreamSettingsUpdate
    data object MirrorUnavailable : StreamSettingsUpdate
}

object StreamSettingsWire {
    /** Bounds on what a Mac can make this device hold or draw. */
    const val MAX_DISPLAYS = 16
    const val MAX_TIERS = 16
    const val MAX_NAME_LENGTH = 64

    /** Null for any other type, or a known one with a missing/mistyped required field. */
    fun parse(type: String, body: JsonObject): StreamSettingsUpdate? = when (type) {
        "streamingProfileState" -> StreamingProfile.of(body.string("profile"))?.let(StreamSettingsUpdate::Profile)
        "streamingPriorityState" -> StreamingPriority.of(body.string("priority"))?.let(StreamSettingsUpdate::Priority)
        "extendShapeState" -> ExtendShape.of(body.string("shape"))?.let {
            StreamSettingsUpdate.ExtendShapeConfirmed(ExtendShapePreference(it, body.bool("useFullDisplay") ?: false))
        }
        "maxFPSState" -> parseMaxFPS(body)?.let(StreamSettingsUpdate::MaxFPS)
        "mirrorDisplayState" -> parseMirrorDisplays(body)?.let(StreamSettingsUpdate::MirrorDisplays)
        "mirrorUnavailable" -> StreamSettingsUpdate.MirrorUnavailable
        else -> null
    }

    private fun parseMaxFPS(body: JsonObject): MaxFPSState? {
        val enabled = body.bool("enabled") ?: return null
        val maxFPS = body.int("maxFPS")?.takeIf { it > 0 } ?: return null
        val tiers = body.array("availableTiers")?.take(MAX_TIERS)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.content?.toIntOrNull()?.takeIf { fps -> fps in 1..1000 } }
            ?.distinct()?.sorted().orEmpty()
        return MaxFPSState(
            MaxFPSPreference(enabled, maxFPS), tiers,
            encoderSafeFPS = body.int("encoderSafeFPS")?.takeIf { it > 0 },
            requestedFPS = body.int("requestedFPS")?.takeIf { it > 0 },
            effectiveFPS = body.int("effectiveFPS")?.takeIf { it > 0 },
            reason = body.string("reason")?.take(32),
        )
    }

    private fun parseMirrorDisplays(body: JsonObject): MirrorDisplayState? {
        val list = body.array("displays") ?: return null
        val displays = list.take(MAX_DISPLAYS).mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val uuid = obj.string("uuid")?.takeIf { it.isNotBlank() && it.length <= 64 } ?: return@mapNotNull null
            MirrorDisplay(
                uuid = uuid,
                name = obj.string("name")?.trim()?.take(MAX_NAME_LENGTH)?.ifEmpty { null } ?: "Display",
                isMain = obj.bool("isMain") ?: false,
                pixelWidth = obj.int("pixelWidth")?.takeIf { it in 1..16_384 },
                pixelHeight = obj.int("pixelHeight")?.takeIf { it in 1..16_384 },
                likelyVirtual = obj.bool("likelyVirtual") ?: false,
            )
        }.distinctBy { it.uuid }
        return MirrorDisplayState(body.string("selectedUUID")?.takeIf { it.isNotBlank() }, displays)
    }

    fun streamingProfileRequest(profile: StreamingProfile, customFrameRate: CustomFrameRate) = buildJsonObject {
        put("type", "streamingProfileRequest"); put("profile", profile.wire); put("customFrameRate", customFrameRate.wire)
    }

    fun streamingPriorityRequest(priority: StreamingPriority) = buildJsonObject {
        put("type", "streamingPriorityRequest"); put("priority", priority.wire)
    }

    /** Null [uuid]: Auto. */
    fun mirrorDisplayRequest(uuid: String?) = buildJsonObject {
        put("type", "mirrorDisplayRequest"); uuid?.let { put("selectedUUID", it) }
    }

    fun extendShapeRequest(preference: ExtendShapePreference) = buildJsonObject {
        put("type", "extendShapeRequest"); put("shape", preference.shape.wire); put("useFullDisplay", preference.useFullDisplay)
    }

    fun maxFPSRequest(preference: MaxFPSPreference) = buildJsonObject {
        put("type", "maxFPSRequest"); put("enabled", preference.enabled); put("maxFPS", preference.maxFPS)
    }
}

/**
 * The settings state for one connection. Not thread-safe: [ReceiverSession] owns it under its lock.
 * `request*` return the message to send, or null when the Mac can't take it (too old, nothing to
 * change, or a request of the same kind is still unanswered).
 */
class StreamSettingsModel {
    var state = StreamSettings()
        private set
    private var extendShapeSentAt = 0L
    private var maxFPSSentAt = 0L

    /** A new connection: nothing is known about the new Mac. The Custom frame rate choice stays. */
    fun reset() {
        state = StreamSettings(customFrameRate = state.customFrameRate)
    }

    fun peerVersion(pv: Int) {
        state = state.copy(macProtocolVersion = pv)
    }

    fun videoState(enabled: Boolean) {
        state = state.copy(videoEnabled = enabled)
    }

    fun displayModeConfirmed(mode: DisplayMode) {
        // A confirmed mode answers a "no physical display" offer either way.
        if (state.mirrorUnavailable && mode != DisplayMode.Mirror) state = state.copy(mirrorUnavailable = false)
    }

    fun apply(update: StreamSettingsUpdate) {
        state = when (update) {
            is StreamSettingsUpdate.Profile -> state.copy(profile = update.profile)
            is StreamSettingsUpdate.Priority -> state.copy(priority = update.priority)
            is StreamSettingsUpdate.ExtendShapeConfirmed -> state.copy(extendShape = update.preference, pendingExtendShape = null)
            is StreamSettingsUpdate.MaxFPS -> state.copy(maxFPS = update.state.preference, pendingMaxFPS = null, maxFPSState = update.state)
            is StreamSettingsUpdate.MirrorDisplays -> state.copy(mirrorDisplays = update.state, mirrorUnavailable = false)
            StreamSettingsUpdate.MirrorUnavailable -> state.copy(mirrorUnavailable = true)
        }
    }

    fun requestProfile(profile: StreamingProfile, customFrameRate: CustomFrameRate): JsonObject? {
        if (!state.supportsProfileRequest) return null
        state = state.copy(customFrameRate = customFrameRate)
        return StreamSettingsWire.streamingProfileRequest(profile, customFrameRate)
    }

    fun requestPriority(priority: StreamingPriority): JsonObject? =
        if (state.supportsPriority) StreamSettingsWire.streamingPriorityRequest(priority) else null

    /** Only a display the Mac listed (or Auto) can be asked for. */
    fun requestMirrorDisplay(uuid: String?): JsonObject? {
        if (!state.supportsMirrorDisplay) return null
        if (uuid != null && state.mirrorDisplays?.displays?.none { it.uuid == uuid } != false) return null
        return StreamSettingsWire.mirrorDisplayRequest(uuid)
    }

    fun requestExtendShape(preference: ExtendShapePreference, nowMs: Long): JsonObject? {
        if (!state.supportsExtendShape || state.pendingExtendShape != null || preference == state.extendShape) return null
        state = state.copy(pendingExtendShape = preference)
        extendShapeSentAt = nowMs
        return StreamSettingsWire.extendShapeRequest(preference)
    }

    fun requestMaxFPS(preference: MaxFPSPreference, nowMs: Long): JsonObject? {
        if (!state.supportsMaxFPS || state.pendingMaxFPS != null || preference == state.maxFPS || preference.maxFPS <= 0) return null
        state = state.copy(pendingMaxFPS = preference)
        maxFPSSentAt = nowMs
        return StreamSettingsWire.maxFPSRequest(preference)
    }

    /** Drops requests the Mac never answered; true when anything changed. */
    fun expire(nowMs: Long): Boolean {
        var next = state
        if (next.pendingExtendShape != null && nowMs - extendShapeSentAt >= PENDING_TIMEOUT_MS) next = next.copy(pendingExtendShape = null)
        if (next.pendingMaxFPS != null && nowMs - maxFPSSentAt >= PENDING_TIMEOUT_MS) next = next.copy(pendingMaxFPS = null)
        if (next == state) return false
        state = next
        return true
    }

    companion object {
        const val PENDING_TIMEOUT_MS = 15_000L
    }
}
