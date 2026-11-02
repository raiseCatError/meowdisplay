package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ControlProfile.swift (ReceiverControlPreferences and its
// repository) and Shared/AudioMediaFrame.swift (AVSyncOffset).

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

/**
 * Receiver-local A/V sync offset. Positive values delay audio; negative values
 * delay video (audio can't play before it arrives, so "earlier" audio means
 * holding the picture back).
 */
object AVSyncOffset {
    val range = -1_000..1_000
    const val STEP_MS = 25

    fun clamped(ms: Int): Int = ms.coerceIn(range.first, range.last)

    fun audioDelayMs(offsetMs: Int): Int = maxOf(0, clamped(offsetMs))

    fun videoDelayMs(offsetMs: Int): Int = maxOf(0, -clamped(offsetMs))
}

/**
 * Every receiver control preference, persisted as one JSON blob in the same
 * shape the iOS receiver writes. Values are plain `var`s like the Swift
 * struct; the app's store always mutates a [deepCopy], so a published value
 * never changes underneath its observers.
 */
data class ReceiverControlPreferences(
    var version: Int = SCHEMA_VERSION,
    var trayEnabled: Boolean = true,
    var keyboardButtonEnabled: Boolean = true,
    var hapticsEnabled: Boolean = true,
    var preferredLandscapeSide: LandscapeTraySide = LandscapeTraySide.Trailing,
    var activeControlProfile: ControlProfileSlot = ControlProfileSlot.Default,
    var trayCollapsed: Boolean = false,
    /**
     * Whether the trays retreat after inactivity. Only the behavior: whether a
     * tray is auto-hidden right now is transient and never persisted. Defaults
     * on (schema 16); the iPad Strip keeps its rail visible regardless.
     */
    var autoHideEnabled: Boolean = true,
    /**
     * Whether THIS session currently has effective input, mirrored from the
     * Mac's per-session decision. True only so a brand-new install shows no
     * manufactured "denied" state; the Mac's state always overwrites it before
     * input could be sent. Android never sends input on this flag alone: the
     * session's own grant gates every message.
     */
    var allowInput: Boolean = true,
    var inputMode: PointerInputMode = PointerInputMode.Direct,
    var trackpadSensitivity: Double = PointerGestureConfig.defaultTrackpadSensitivity,
    /** Smart Touch (Experimental). Defaults on (schema 16). No effect in Trackpad mode. */
    var smartTouchEnabled: Boolean = true,
    /** Smart Touch hold haptics; also silenced while [hapticsEnabled] is off. Original persisted name kept. */
    var smartTouchLongPressHapticEnabled: Boolean = true,
    /** Direct Touch style: Classic for everyone, new and upgraded (schema 21; 19 had made it Natural). Never affects Trackpad mode. */
    var touchStyle: DirectTouchStyle = DirectTouchStyle.Classic,
    /** Whether the one-time "Natural Touch is on" hint has been shown. */
    var naturalTouchHintShown: Boolean = false,
    /** Window mode's switcher (schema 20): Stage Peek unless one was chosen; Rail keeps its own settings. */
    var windowSwitcher: WindowSwitcherStyle = WindowSwitcherStyle.StagePeek,
    /** The edge Stage Peek opens from. */
    var stagePeekEdge: StagePeekEdge = StagePeekEdge.Left,
    /** Compact (a bounded, fading column between the controls) or Normal (the open column). */
    var stagePeekDock: StagePeekDockStyle = StagePeekDockStyle.Compact,
    /**
     * Hardware keyboards: Control sends ⌘. Android keeps Meta-key (⌘) combinations for its own
     * shortcuts and never passes them to apps, so this is the only way to type ⌘ shortcuts from a
     * physical keyboard. Off by default; the on-screen ^ key still sends Control.
     */
    var controlKeyAsCommand: Boolean = false,
    /** Reconnect by itself after a lost connection (iOS Settings → Connections → Auto-Reconnect). */
    var autoReconnectEnabled: Boolean = true,
    var profiles: List<ControlProfile> = ControlProfileSlot.entries.map { ControlProfile.canonical(it) },
    var functionTrayEnabled: Boolean = true,
    var activeFunctionTrayProfile: ControlProfileSlot = ControlProfileSlot.Default,
    /** New preferences start opposite the Main Tray; a saved blob without this key keeps `sameSide`. */
    var functionTrayPosition: FunctionTrayPosition = FunctionTrayPosition.OppositeSide,
    var functionTrayProfiles: List<FunctionTrayProfile> = ControlProfileSlot.entries.map { FunctionTrayProfile.canonical(it) },
    /** Shift controls inward to clear a cutout/hinge-adjacent unsafe strip only when they'd intersect it. */
    var avoidNotch: Boolean = true,
    /** Decoration for the mapped surface shown while video is off; never hit-tested. */
    var showSurfaceGrid: Boolean = true,
    var pinchTarget: ReceiverGestureTarget = ReceiverGestureTarget.Viewport,
    /** Defaults to Disabled (schema 16): an accidental twist while pinching never tilts the view. */
    var rotateTarget: ReceiverGestureTarget = ReceiverGestureTarget.Disabled,
    var snapRotation: Boolean = true,
    /** Remote scroll direction per axis; on = natural scrolling. Never affects local panning. */
    var invertVerticalScroll: Boolean = true,
    var invertHorizontalScroll: Boolean = true,
    /** Prefer MeowDisplay Gestures: claim screen-edge gestures while controlling the Mac (public API only). */
    var preferMeowDisplayGestures: Boolean = true,
    var appGestureCommands: AppGestureCommands = AppGestureCommands.defaults,
    /** This receiver's own system-audio wish, resent as `audioRequest` on every connection. Off by default. */
    var audioPreferred: Boolean = false,
    /** Receiver-local A/V sync offset (ms), clamped to [AVSyncOffset.range]. Never sent to the Mac. */
    var avSyncOffsetMs: Int = 0,
    var pictureInPictureEnabled: Boolean = true,
    // Expanded (iPad-style) presentation; the compact (iPhone-style) tray never reads these.
    var padControlLayout: PadControlLayoutMode = PadControlLayoutMode.Strip,
    var padMainEdge: ControlEdge = ControlEdge.Trailing,
    /** New preferences start opposite the Main controls; a saved blob without this key keeps `trailing`. */
    var padFunctionEdge: ControlEdge = ControlEdge.Leading,
    var padShowControlHints: Boolean = false,
    var padControlScale: Double = PadControlScale.defaultValue,
    var padStandardControls: PadStandardControlVisibility = PadStandardControlVisibility(),
    /** Local View Navigation: pan, zoom, rotate, Move View, reset — receiver-local, independent of Allow Input. */
    var allowLocalViewNavigation: Boolean = true,
    var padOverlayPaletteStyle: PadPaletteStyle = PadPaletteStyle.Keys,
    var customLayouts: List<CustomControlLayout> = emptyList(),
    var activeCustomLayoutID: String? = null,
) {
    /** The normal tray renders only while input is allowed: it only ever drives remote input. The stored choice is kept. */
    val trayCanBeShown: Boolean get() = allowInput && trayEnabled

    /** Same rule, independently, for the Function Tray. */
    val functionTrayCanBeShown: Boolean get() = allowInput && functionTrayEnabled

    /** An independent copy: nothing nested is shared with this value. */
    fun deepCopy(): ReceiverControlPreferences = decode(toJson()) ?: copy()

    /** Restores only the four App Gesture Commands — never targets, Snap Rotation, or anything else. */
    fun resetAppGestureCommands() {
        appGestureCommands = AppGestureCommands.defaults
    }

    fun profile(slot: ControlProfileSlot): ControlProfile = profiles.firstOrNull { it.slot == slot } ?: ControlProfile.canonical(slot)

    fun updateProfile(profile: ControlProfile) {
        val index = profiles.indexOfFirst { it.slot == profile.slot }
        profiles = if (index >= 0) profiles.toMutableList().also { it[index] = profile } else profiles + profile
    }

    fun resetProfile(slot: ControlProfileSlot) = updateProfile(ControlProfile.canonical(slot))

    fun functionTrayProfile(slot: ControlProfileSlot): FunctionTrayProfile =
        (functionTrayProfiles.firstOrNull { it.slot == slot } ?: FunctionTrayProfile.canonical(slot)).resolvingCanonicalMetadata()

    fun updateFunctionTrayProfile(profile: FunctionTrayProfile) {
        val index = functionTrayProfiles.indexOfFirst { it.slot == profile.slot }
        functionTrayProfiles = if (index >= 0) functionTrayProfiles.toMutableList().also { it[index] = profile } else functionTrayProfiles + profile
    }

    fun resetFunctionTrayProfile(slot: ControlProfileSlot) = updateFunctionTrayProfile(FunctionTrayProfile.canonical(slot))

    /** Swift's synthesized encoding: every stored property under its own name; nil optionals omitted. */
    fun toJson(): JsonObject = buildJsonObject {
        put("version", jsonOf(version))
        put("trayEnabled", jsonOf(trayEnabled))
        put("keyboardButtonEnabled", jsonOf(keyboardButtonEnabled))
        put("hapticsEnabled", jsonOf(hapticsEnabled))
        put("preferredLandscapeSide", jsonOf(preferredLandscapeSide.raw))
        put("activeControlProfile", jsonOf(activeControlProfile.raw))
        put("trayCollapsed", jsonOf(trayCollapsed))
        put("autoHideEnabled", jsonOf(autoHideEnabled))
        put("allowInput", jsonOf(allowInput))
        put("inputMode", jsonOf(inputMode.raw))
        put("trackpadSensitivity", jsonOf(trackpadSensitivity))
        put("smartTouchEnabled", jsonOf(smartTouchEnabled))
        put("smartTouchLongPressHapticEnabled", jsonOf(smartTouchLongPressHapticEnabled))
        put("touchStyle", jsonOf(touchStyle.raw))
        put("naturalTouchHintShown", jsonOf(naturalTouchHintShown))
        put("windowSwitcher", jsonOf(windowSwitcher.raw))
        put("stagePeekEdge", jsonOf(stagePeekEdge.raw))
        put("stagePeekDock", jsonOf(stagePeekDock.raw))
        put("controlKeyAsCommand", jsonOf(controlKeyAsCommand))
        put("autoReconnectEnabled", jsonOf(autoReconnectEnabled))
        put("profiles", jsonArrayOf(profiles.map { it.toJson() }))
        put("functionTrayEnabled", jsonOf(functionTrayEnabled))
        put("activeFunctionTrayProfile", jsonOf(activeFunctionTrayProfile.raw))
        put("functionTrayPosition", jsonOf(functionTrayPosition.raw))
        put("functionTrayProfiles", jsonArrayOf(functionTrayProfiles.map { it.toJson() }))
        put("avoidNotch", jsonOf(avoidNotch))
        put("showSurfaceGrid", jsonOf(showSurfaceGrid))
        put("pinchTarget", jsonOf(pinchTarget.raw))
        put("rotateTarget", jsonOf(rotateTarget.raw))
        put("snapRotation", jsonOf(snapRotation))
        put("invertVerticalScroll", jsonOf(invertVerticalScroll))
        put("invertHorizontalScroll", jsonOf(invertHorizontalScroll))
        put("preferMeowDisplayGestures", jsonOf(preferMeowDisplayGestures))
        put("appGestureCommands", appGestureCommands.toJson())
        put("audioPreferred", jsonOf(audioPreferred))
        put("avSyncOffsetMs", jsonOf(avSyncOffsetMs))
        put("pictureInPictureEnabled", jsonOf(pictureInPictureEnabled))
        put("padControlLayout", jsonOf(padControlLayout.raw))
        put("padMainEdge", jsonOf(padMainEdge.raw))
        put("padFunctionEdge", jsonOf(padFunctionEdge.raw))
        put("padShowControlHints", jsonOf(padShowControlHints))
        put("padControlScale", jsonOf(padControlScale))
        put("padStandardControls", padStandardControls.toJson())
        put("allowLocalViewNavigation", jsonOf(allowLocalViewNavigation))
        put("padOverlayPaletteStyle", jsonOf(padOverlayPaletteStyle.raw))
        put("customLayouts", jsonArrayOf(customLayouts.map { it.toJson() }))
        putIfNotNull("activeCustomLayoutID", activeCustomLayoutID?.let(::jsonOf))
    }

    companion object {
        const val SCHEMA_VERSION = 21

        /**
         * The hand-written Swift `init(from:)`: a key added by a later schema
         * never makes the blob undecodable. Absent keys take a fresh install's
         * value (with the few documented exceptions); a present key of the
         * wrong type fails the whole decode, as JSONDecoder would.
         */
        fun decode(e: JsonElement?): ReceiverControlPreferences? {
            val o = e.obj() ?: return null
            val fallback = ReceiverControlPreferences()
            val p = ReceiverControlPreferences()

            class Invalid : Exception()

            fun <T> value(key: String, default: T, decode: (JsonElement) -> T?): T {
                val raw = o[key] ?: return default
                if (raw is JsonNull) return default
                return decode(raw) ?: throw Invalid()
            }
            return try {
                // Absent means "written before versioning existed", i.e. schema 1.
                p.version = value("version", 1) { it.int() }
                p.trayEnabled = value("trayEnabled", fallback.trayEnabled) { it.bool() }
                p.keyboardButtonEnabled = value("keyboardButtonEnabled", fallback.keyboardButtonEnabled) { it.bool() }
                p.hapticsEnabled = value("hapticsEnabled", fallback.hapticsEnabled) { it.bool() }
                p.preferredLandscapeSide = value("preferredLandscapeSide", fallback.preferredLandscapeSide) { LandscapeTraySide.of(it.str()) }
                p.activeControlProfile = value("activeControlProfile", fallback.activeControlProfile) { ControlProfileSlot.of(it.str()) }
                p.trayCollapsed = value("trayCollapsed", fallback.trayCollapsed) { it.bool() }
                p.allowInput = value("allowInput", fallback.allowInput) { it.bool() }
                p.inputMode = value("inputMode", fallback.inputMode) { PointerInputMode.of(it.str()) }
                p.trackpadSensitivity = value("trackpadSensitivity", fallback.trackpadSensitivity) { it.dbl() }
                p.profiles = value("profiles", fallback.profiles) { it.listOf(ControlProfile::fromJson) }
                p.functionTrayEnabled = value("functionTrayEnabled", fallback.functionTrayEnabled) { it.bool() }
                p.activeFunctionTrayProfile = value("activeFunctionTrayProfile", fallback.activeFunctionTrayProfile) { ControlProfileSlot.of(it.str()) }
                // Older saves predate the opposite-side default: keep what they had.
                p.functionTrayPosition = value("functionTrayPosition", FunctionTrayPosition.SameSide) { FunctionTrayPosition.of(it.str()) }
                p.functionTrayProfiles = value("functionTrayProfiles", fallback.functionTrayProfiles) { it.listOf(FunctionTrayProfile::fromJson) }
                p.avoidNotch = value("avoidNotch", fallback.avoidNotch) { it.bool() }
                p.showSurfaceGrid = value("showSurfaceGrid", fallback.showSurfaceGrid) { it.bool() }
                p.pinchTarget = value("pinchTarget", fallback.pinchTarget) { ReceiverGestureTarget.of(it.str()) }
                p.rotateTarget = value("rotateTarget", fallback.rotateTarget) { ReceiverGestureTarget.of(it.str()) }
                p.snapRotation = value("snapRotation", fallback.snapRotation) { it.bool() }
                p.appGestureCommands = value("appGestureCommands", fallback.appGestureCommands) { AppGestureCommands.fromJson(it) }
                p.audioPreferred = value("audioPreferred", fallback.audioPreferred) { it.bool() }
                p.avSyncOffsetMs = AVSyncOffset.clamped(value("avSyncOffsetMs", fallback.avSyncOffsetMs) { it.int() })
                p.autoHideEnabled = value("autoHideEnabled", fallback.autoHideEnabled) { it.bool() }
                p.smartTouchEnabled = value("smartTouchEnabled", fallback.smartTouchEnabled) { it.bool() }
                p.smartTouchLongPressHapticEnabled =
                    value("smartTouchLongPressHapticEnabled", fallback.smartTouchLongPressHapticEnabled) { it.bool() }
                p.touchStyle = value("touchStyle", fallback.touchStyle) { DirectTouchStyle.of(it.str()) }
                p.naturalTouchHintShown = value("naturalTouchHintShown", fallback.naturalTouchHintShown) { it.bool() }
                // Absent (schema < 20): Stage Peek from the left edge.
                p.windowSwitcher = value("windowSwitcher", fallback.windowSwitcher) { WindowSwitcherStyle.of(it.str()) }
                p.stagePeekEdge = value("stagePeekEdge", fallback.stagePeekEdge) { StagePeekEdge.of(it.str()) }
                // Absent (added 2026-10-30): Compact.
                p.stagePeekDock = value("stagePeekDock", fallback.stagePeekDock) { StagePeekDockStyle.of(it.str()) }
                p.controlKeyAsCommand = value("controlKeyAsCommand", fallback.controlKeyAsCommand) { it.bool() }
                p.autoReconnectEnabled = value("autoReconnectEnabled", fallback.autoReconnectEnabled) { it.bool() }
                p.pictureInPictureEnabled = value("pictureInPictureEnabled", fallback.pictureInPictureEnabled) { it.bool() }
                p.preferMeowDisplayGestures = value("preferMeowDisplayGestures", fallback.preferMeowDisplayGestures) { it.bool() }
                p.padControlLayout = value("padControlLayout", fallback.padControlLayout) { PadControlLayoutMode.of(it.str()) }
                p.padMainEdge = value("padMainEdge", fallback.padMainEdge) { ControlEdge.of(it.str()) }
                p.padFunctionEdge = value("padFunctionEdge", ControlEdge.Trailing) { ControlEdge.of(it.str()) }
                p.padShowControlHints = value("padShowControlHints", fallback.padShowControlHints) { it.bool() }
                p.padControlScale = PadControlScale.clamped(value("padControlScale", fallback.padControlScale) { it.dbl() })
                p.padStandardControls = value("padStandardControls", fallback.padStandardControls) { PadStandardControlVisibility.fromJson(it) }
                // Schema 16 stored Move View's visibility on its own.
                if (o["padShowMoveViewControl"].bool() == false) p.padStandardControls.setVisible(false, PadStandardControl.MoveView)
                p.allowLocalViewNavigation = value("allowLocalViewNavigation", fallback.allowLocalViewNavigation) { it.bool() }
                p.invertVerticalScroll = value("invertVerticalScroll", fallback.invertVerticalScroll) { it.bool() }
                p.invertHorizontalScroll = value("invertHorizontalScroll", fallback.invertHorizontalScroll) { it.bool() }
                p.padOverlayPaletteStyle = value("padOverlayPaletteStyle", fallback.padOverlayPaletteStyle) { PadPaletteStyle.of(it.str()) }
                // Lossy: one layout written by a newer build is dropped on its own.
                p.customLayouts = value("customLayouts", emptyList()) { it.lossyListOf(CustomControlLayout::fromJson) }
                    .take(CustomControlLayout.maximumCount)
                p.activeCustomLayoutID = o["activeCustomLayoutID"]?.takeIf { it !is JsonNull }?.let { it.str() ?: throw Invalid() }
                p
            } catch (_: Invalid) {
                null
            }
        }
    }
}

/** Where the preference blob lives: SharedPreferences in the app, a map in tests. */
interface PreferenceBlobStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
}

class ReceiverControlPreferencesRepository(private val store: PreferenceBlobStore) {
    /** [initial] is what a device starts with while nothing usable is saved. */
    fun load(initial: ReceiverControlPreferences = ReceiverControlPreferences()): ReceiverControlPreferences {
        val text = store.read(DEFAULTS_KEY) ?: return initial
        val raw = parseJson(text).obj() ?: return initial
        // A newer build's settings (after a downgrade) are read for every field this build
        // knows instead of being reset: no migration below applies to a newer schema, and
        // [save] keeps the newer build's own fields (Swift: ReceiverControlPreferencesRepository).
        val value = ReceiverControlPreferences.decode(raw) ?: return initial
        if (value.version < 2) {
            value.profiles = value.profiles.map { profile ->
                if (profile.trayItems.any { it.item == ControlTrayItem.Tab }) return@map profile
                val keyboardIndex = profile.trayItems.indexOfFirst { it.item == ControlTrayItem.Keyboard }.takeIf { it >= 0 } ?: profile.trayItems.size
                profile.copy(trayItems = profile.trayItems.toMutableList().also { it.add(keyboardIndex, TrayItemConfiguration(ControlTrayItem.Tab, true)) })
            }
            value.version = 2
        }
        if (value.version < 3) {
            // Schema 2 stored a four-corner landscape anchor; keep its left/right half.
            LandscapeTrayCorner.of(raw["preferredLandscapeCorner"].str())?.let { value.preferredLandscapeSide = it.side }
            value.version = 3
        }
        // Schemas 3–7 only added keys the decoder already defaulted.
        if (value.version < 7) value.version = 7
        if (value.version < 8) {
            // Toggle Dock: inserted before Keyboard; visible only in the Default profile.
            value.profiles = value.profiles.map { profile ->
                if (profile.trayItems.any { it.item == ControlTrayItem.Dock }) return@map profile
                val keyboardIndex = profile.trayItems.indexOfFirst { it.item == ControlTrayItem.Keyboard }.takeIf { it >= 0 } ?: profile.trayItems.size
                profile.copy(
                    trayItems = profile.trayItems.toMutableList().also {
                        it.add(keyboardIndex, TrayItemConfiguration(ControlTrayItem.Dock, profile.slot == ControlProfileSlot.Default))
                    },
                )
            }
            value.version = 8
        }
        // Schemas 9–15 only added keys the decoder already defaulted.
        if (value.version < 15) value.version = 15
        if (value.version < 16) {
            // Four pre-release defaults changed once (Smart Touch on, Auto-hide on, Pinch → Viewport, Rotation → Disabled).
            val defaults = ReceiverControlPreferences()
            value.smartTouchEnabled = defaults.smartTouchEnabled
            value.autoHideEnabled = defaults.autoHideEnabled
            value.pinchTarget = defaults.pinchTarget
            value.rotateTarget = defaults.rotateTarget
            value.version = 16
        }
        if (value.version < 17) {
            value.padShowControlHints = ReceiverControlPreferences().padShowControlHints
            value.version = 17
        }
        if (value.version < 18) value.version = 18
        // Schema 18 predates Touch Style; the decoder already defaulted it to Natural.
        if (value.version < 19) value.version = 19
        // Schema 19 predates the window switcher choice; the decoder already defaulted it.
        if (value.version < 20) value.version = 20
        // Schema 21 (owner decision 2026-10-30): Classic Direct Touch for everyone; phones start in
        // Trackpad, tablets stay in Direct Touch. Applied once to upgraded installs too, like 19.
        if (value.version < 21) {
            value.touchStyle = DirectTouchStyle.Classic
            if (initial.inputMode == PointerInputMode.Trackpad) value.inputMode = PointerInputMode.Trackpad
            value.version = 21
        }
        // Resolve current canonical Function Tray metadata by ID without rewriting the user's choices.
        value.functionTrayProfiles = value.functionTrayProfiles.map { it.resolvingCanonicalMetadata() }
        return value
    }

    fun save(preferences: ReceiverControlPreferences) {
        store.write(DEFAULTS_KEY, keepingNewerFields(preferences.toJson(), store.read(DEFAULTS_KEY)).toString())
    }

    companion object {
        const val DEFAULTS_KEY = "receiverControlPreferences.v1"

        /**
         * When what's stored came from a newer schema, the fields this build doesn't know are
         * kept, and so is the newer version number; every field this build knows is written as
         * now. Otherwise [json] as it is.
         */
        fun keepingNewerFields(json: JsonObject, stored: String?): JsonObject {
            val old = stored?.let { runCatching { parseJson(it).obj() }.getOrNull() } ?: return json
            val storedVersion = old["version"].int() ?: return json
            if (storedVersion <= ReceiverControlPreferences.SCHEMA_VERSION) return json
            val known = ReceiverControlPreferences().toJson().keys + json.keys
            return JsonObject(json + old.filterKeys { it !in known } + ("version" to kotlinx.serialization.json.JsonPrimitive(storedVersion)))
        }
    }
}

/**
 * The preferences a new app process starts from. `allowInput` mirrors the
 * Mac's grant for the current session (iOS overwrites it from the Mac's
 * state on every session); a new process has no session, so it starts View
 * Only until the Mac says otherwise. Without this a grant stored by the last
 * process showed the full Control Tray in a View Only session (C4 F-05).
 */
fun ReceiverControlPreferences.atProcessStart(): ReceiverControlPreferences = copy(allowInput = false)

