package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ControlProfile.swift.

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

enum class ControlModifier(val raw: String, val symbol: String, val title: String) {
    Command("command", "⌘", "Command"),
    Option("option", "⌥", "Option"),
    Control("control", "⌃", "Control"),
    Shift("shift", "⇧", "Shift");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): ControlModifier? = entries.firstOrNull { it.raw == raw }

        /** `allCases.filter(set.contains)`: the canonical order. */
        fun ordered(modifiers: Set<ControlModifier>): List<ControlModifier> = entries.filter { it in modifiers }
    }
}

/** A stable, order-independent key for a modifier combination. */
data class ModifierChord(val modifiers: Set<ControlModifier> = emptySet()) {
    constructor(vararg modifiers: ControlModifier) : this(modifiers.toSet())

    val id: String get() = ControlModifier.ordered(modifiers).joinToString("+") { it.raw }

    val displayName: String
        get() = ControlModifier.ordered(modifiers).let { ordered ->
            if (ordered.isEmpty()) "No Modifiers" else ordered.joinToString(" + ") { it.title }
        }

    val symbols: String get() = ControlModifier.ordered(modifiers).joinToString("") { it.symbol }

    /** Compact keycap form for the heads-up display: `⌘C`, `⌘⌥V`, `⌘⇧4`. */
    fun hudText(key: String): String = symbols + key

    fun contains(modifier: ControlModifier) = modifier in modifiers

    fun toJson(): JsonElement = buildJsonObject {
        put("modifiers", jsonArrayOf(ControlModifier.ordered(modifiers).map { jsonOf(it.raw) }))
    }

    companion object {
        fun fromJson(e: JsonElement?): ModifierChord? {
            val list = e.obj()?.get("modifiers").listOf { ControlModifier.of(it.str()) } ?: return null
            return ModifierChord(list.toSet())
        }
    }
}

enum class ControlTrayItem(val raw: String, val title: String, val displayLabel: String) {
    Command("command", "Command", "⌘"),
    Option("option", "Option", "⌥"),
    Control("control", "Control", "⌃"),
    Shift("shift", "Shift", "⇧"),
    Escape("escape", "Escape", "esc"),
    Tab("tab", "Tab", "tab"),
    Dock("dock", "Toggle Dock", "dock.rectangle"),
    Keyboard("keyboard", "Keyboard", "keyboard"),

    /** Opens receiver Settings. The raw value stays `"more"` so profiles persisted before it became a gear still decode. */
    Settings("more", "Settings", "gearshape.fill");

    val id: String get() = raw

    val modifier: ControlModifier?
        get() = when (this) {
            Command -> ControlModifier.Command
            Option -> ControlModifier.Option
            Control -> ControlModifier.Control
            Shift -> ControlModifier.Shift
            else -> null
        }

    companion object {
        fun of(raw: String?): ControlTrayItem? = entries.firstOrNull { it.raw == raw }
    }
}

data class TrayItemConfiguration(val item: ControlTrayItem, val isVisible: Boolean) {
    val id: ControlTrayItem get() = item

    fun toJson(): JsonElement = buildJsonObject {
        put("item", jsonOf(item.raw))
        put("isVisible", jsonOf(isVisible))
    }

    companion object {
        fun fromJson(e: JsonElement?): TrayItemConfiguration? {
            val o = e.obj() ?: return null
            return TrayItemConfiguration(ControlTrayItem.of(o["item"].str()) ?: return null, o["isVisible"].bool() ?: return null)
        }
    }
}

data class KeyboardShortcut(
    val usage: Int,
    val modifiers: ModifierChord,
    /**
     * Further ordinary keys held together with `usage` (e.g. K + 3). Empty for
     * every ordinary shortcut, and then never encoded, so the wire and stored
     * form of existing shortcuts is unchanged.
     */
    val additionalUsages: List<Int> = emptyList(),
) {
    /** Every ordinary key in the chord, in press order. */
    val usages: List<Int> get() = listOf(usage) + additionalUsages

    val isValid: Boolean
        get() = usages.size <= MAXIMUM_KEYS && usages.all { it in VALID_USAGES } && usages.toSet().size == usages.size

    fun toJson(): JsonElement = buildJsonObject {
        put("usage", jsonOf(usage))
        put("modifiers", modifiers.toJson())
        if (additionalUsages.isNotEmpty()) put("additionalUsages", jsonArrayOf(additionalUsages.map(::jsonOf)))
    }

    companion object {
        /** USB HID keyboard-page usages a chord may use (modifier keys excluded: those travel as `modifiers`). */
        val VALID_USAGES = 4..221
        const val MAXIMUM_KEYS = 4

        fun fromJson(e: JsonElement?): KeyboardShortcut? {
            val o = e.obj() ?: return null
            val additional = if (o.containsKey("additionalUsages")) (o["additionalUsages"].listOf { it.int() } ?: return null) else emptyList()
            return KeyboardShortcut(o["usage"].int() ?: return null, ModifierChord.fromJson(o["modifiers"]) ?: return null, additional)
        }
    }
}

/** One key transition of a one-tap chord. */
data class KeyboardChordEvent(val phase: Phase, val usage: Int, val modifiers: List<String>) {
    enum class Phase { Down, Up }
}

/**
 * How a one-tap shortcut reaches the Mac over the existing `keyboard`
 * messages: a single key uses the atomic `press`; a multi-key chord presses
 * every key down in order, then releases them in reverse, so nothing is
 * ever left held.
 */
object KeyboardChordPlan {
    fun events(shortcut: KeyboardShortcut): List<KeyboardChordEvent> {
        val modifiers = ControlModifier.ordered(shortcut.modifiers.modifiers).map { it.raw }
        val keys = shortcut.usages
        return keys.map { KeyboardChordEvent(KeyboardChordEvent.Phase.Down, it, modifiers) } +
            keys.reversed().map { KeyboardChordEvent(KeyboardChordEvent.Phase.Up, it, modifiers) }
    }
}

sealed interface ControlAction {
    data class KeyboardShortcutAction(val shortcut: KeyboardShortcut) : ControlAction

    /**
     * A semantic `ReceiverGesture` (its raw value) sent as the existing
     * `gesture` message — for Mac actions with no reliable keyboard shortcut
     * (Launchpad, Show Desktop).
     */
    data class ReceiverGestureAction(val name: String) : ControlAction

    /** A bounded macro: existing keyboard/semantic actions run in order — never scripts, never nested sequences. */
    data class Sequence(val steps: List<ControlActionStep>) : ControlAction

    /** Sequences are 1…[MAXIMUM_SEQUENCE_STEPS] flat steps; shortcuts must be valid chords; gestures must be known. */
    val isValid: Boolean
        get() = when (this) {
            is KeyboardShortcutAction -> shortcut.isValid
            is ReceiverGestureAction -> ReceiverGesture.of(name) != null
            is Sequence -> steps.size in 1..MAXIMUM_SEQUENCE_STEPS && steps.all { step ->
                step.action !is Sequence && step.action.isValid && step.delayMs in 0..MAXIMUM_STEP_DELAY_MS
            }
        }

    fun toJson(): JsonElement = when (this) {
        is KeyboardShortcutAction -> swiftCase("keyboardShortcut", shortcut.toJson())
        is ReceiverGestureAction -> swiftCase("receiverGesture", jsonOf(name))
        is Sequence -> swiftCase("sequence", jsonArrayOf(steps.map { it.toJson() }))
    }

    companion object {
        const val MAXIMUM_SEQUENCE_STEPS = 8
        const val MAXIMUM_STEP_DELAY_MS = 2000

        fun fromJson(e: JsonElement?): ControlAction? {
            val (case, payload) = e.swiftCaseOf() ?: return null
            val value = payload["_0"]
            return when (case) {
                "keyboardShortcut" -> KeyboardShortcutAction(KeyboardShortcut.fromJson(value) ?: return null)
                "receiverGesture" -> ReceiverGestureAction(value.str() ?: return null)
                "sequence" -> Sequence(value.listOf(ControlActionStep::fromJson) ?: return null)
                else -> null
            }
        }
    }
}

/** One step of a [ControlAction.Sequence], and the pause after it. */
data class ControlActionStep(val action: ControlAction, val delayMs: Int = DEFAULT_DELAY_MS) {
    fun toJson(): JsonElement = buildJsonObject {
        put("action", action.toJson())
        put("delayMs", jsonOf(delayMs))
    }

    companion object {
        const val DEFAULT_DELAY_MS = 150

        fun fromJson(e: JsonElement?): ControlActionStep? {
            val o = e.obj() ?: return null
            return ControlActionStep(ControlAction.fromJson(o["action"]) ?: return null, o["delayMs"].int() ?: return null)
        }
    }
}

/** One thing a one-tap control does on the existing wire. */
sealed interface ControlActionOperation {
    /** The atomic `keyboard` press (a single key with its modifiers). */
    data class Press(val usage: Int, val modifiers: List<String>) : ControlActionOperation

    /** One half of a multi-key chord. */
    data class Key(val event: KeyboardChordEvent) : ControlActionOperation

    /** The semantic `gesture` message. */
    data class Gesture(val name: String) : ControlActionOperation

    /** A pause between sequence steps. */
    data class Pause(val milliseconds: Int) : ControlActionOperation
}

/**
 * The ordered wire operations for a one-tap action. Deterministic; every key
 * that goes down comes back up within its own step, so a sequence can never
 * leave a key held between steps.
 */
object ControlActionPlan {
    fun operations(action: ControlAction): List<ControlActionOperation> {
        if (!action.isValid) return emptyList()
        return when (action) {
            is ControlAction.KeyboardShortcutAction -> {
                val shortcut = action.shortcut
                val modifiers = ControlModifier.ordered(shortcut.modifiers.modifiers).map { it.raw }
                if (shortcut.additionalUsages.isEmpty()) {
                    listOf(ControlActionOperation.Press(shortcut.usage, modifiers))
                } else {
                    KeyboardChordPlan.events(shortcut).map(ControlActionOperation::Key)
                }
            }
            is ControlAction.ReceiverGestureAction -> listOf(ControlActionOperation.Gesture(action.name))
            is ControlAction.Sequence -> action.steps.flatMapIndexed { index, step ->
                operations(step.action) +
                    if (index < action.steps.size - 1 && step.delayMs > 0) listOf(ControlActionOperation.Pause(step.delayMs)) else emptyList()
            }
        }
    }
}

/** How a one-tap button looks — separate from what it does. */
sealed interface ShortcutButtonDisplay {
    data class Symbol(val name: String) : ShortcutButtonDisplay
    data class Text(val text: String) : ShortcutButtonDisplay
    data class Emoji(val emoji: String) : ShortcutButtonDisplay

    /** The keys it sends, e.g. `⌃U`. */
    data object Keys : ShortcutButtonDisplay

    fun toJson(): JsonElement = when (this) {
        is Symbol -> swiftCase("symbol", jsonOf(name))
        is Text -> swiftCase("text", jsonOf(text))
        is Emoji -> swiftCase("emoji", jsonOf(emoji))
        Keys -> swiftCase("keys")
    }

    companion object {
        const val MAXIMUM_TEXT_LENGTH = 4

        fun fromJson(e: JsonElement?): ShortcutButtonDisplay? {
            val (case, payload) = e.swiftCaseOf() ?: return null
            return when (case) {
                "symbol" -> Symbol(payload["_0"].str() ?: return null)
                "text" -> Text(payload["_0"].str() ?: return null)
                "emoji" -> Emoji(payload["_0"].str() ?: return null)
                "keys" -> Keys
                else -> null
            }
        }
    }
}

/** What a button face actually draws. */
sealed interface ShortcutButtonFace {
    data class Symbol(val name: String) : ShortcutButtonFace
    data class Text(val text: String) : ShortcutButtonFace
}

/** Swift `String.prefix(n)` counts Characters (grapheme clusters), not UTF-16 units. */
internal fun String.prefixCharacters(count: Int): String {
    if (count <= 0) return ""
    val iterator = java.text.BreakIterator.getCharacterInstance()
    iterator.setText(this)
    var end = 0
    repeat(count) {
        val next = iterator.next()
        if (next == java.text.BreakIterator.DONE) return this
        end = next
    }
    return substring(0, end)
}

data class ShortcutItem(
    val id: String,
    val title: String,
    val displayKey: String,
    val action: ControlAction,
    /**
     * Optional SF Symbol name for a native icon (Function Tray buttons) —
     * null for the Main Tray's palette shortcuts, which show `displayKey`.
     * Android maps the name to its own icon (see the app's icon table).
     */
    val systemImage: String? = null,
    /** The user's chosen face; null keeps the default of `systemImage`, else `displayKey`. */
    val display: ShortcutButtonDisplay? = null,
) {
    constructor(
        id: String = newUUIDString(),
        title: String,
        displayKey: String,
        usage: Int,
        modifiers: ModifierChord,
        systemImage: String? = null,
    ) : this(id, title, displayKey, ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage, modifiers)), systemImage, null)

    constructor(id: String, title: String, gesture: ReceiverGesture, systemImage: String) :
        this(id, title, title, ControlAction.ReceiverGestureAction(gesture.raw), systemImage, null)

    /** What to draw on this button. */
    val face: ShortcutButtonFace
        get() = when (val d = display) {
            is ShortcutButtonDisplay.Symbol if d.name.isNotEmpty() -> ShortcutButtonFace.Symbol(d.name)
            is ShortcutButtonDisplay.Text if d.text.isNotEmpty() ->
                ShortcutButtonFace.Text(d.text.prefixCharacters(ShortcutButtonDisplay.MAXIMUM_TEXT_LENGTH))
            is ShortcutButtonDisplay.Emoji if d.emoji.isNotEmpty() -> ShortcutButtonFace.Text(d.emoji.prefixCharacters(2))
            ShortcutButtonDisplay.Keys -> ShortcutButtonFace.Text(keysDescription)
            else -> systemImage?.let(ShortcutButtonFace::Symbol) ?: ShortcutButtonFace.Text(displayKey)
        }

    /** The keys this sends, e.g. `⌘⇧P` or `K+3`; a sequence shows its steps. */
    val keysDescription: String
        get() {
            fun describe(action: ControlAction): String = when (action) {
                is ControlAction.KeyboardShortcutAction ->
                    action.shortcut.modifiers.symbols + action.shortcut.usages.joinToString("+", transform = ::appGestureCommandKeyLabel)
                is ControlAction.ReceiverGestureAction -> title
                is ControlAction.Sequence -> action.steps.joinToString(" → ") { describe(it.action) }
            }
            return describe(action)
        }

    fun toJson(): JsonElement = buildJsonObject {
        put("id", jsonOf(id))
        put("title", jsonOf(title))
        put("displayKey", jsonOf(displayKey))
        put("action", action.toJson())
        putIfNotNull("systemImage", systemImage?.let(::jsonOf))
        putIfNotNull("display", display?.toJson())
    }

    companion object {
        fun fromJson(e: JsonElement?): ShortcutItem? {
            val o = e.obj() ?: return null
            val display = if (o["display"] == null || o["display"] is kotlinx.serialization.json.JsonNull) {
                null
            } else {
                ShortcutButtonDisplay.fromJson(o["display"]) ?: return null
            }
            return ShortcutItem(
                id = o["id"].str() ?: return null,
                title = o["title"].str() ?: return null,
                displayKey = o["displayKey"].str() ?: return null,
                action = ControlAction.fromJson(o["action"]) ?: return null,
                systemImage = o["systemImage"].str(),
                display = display,
            )
        }
    }
}

data class ChordPalette(val chord: ModifierChord, val actions: List<ShortcutItem>) {
    val id: String get() = chord.id

    fun toJson(): JsonElement = buildJsonObject {
        put("chord", chord.toJson())
        put("actions", jsonArrayOf(actions.map { it.toJson() }))
    }

    companion object {
        fun fromJson(e: JsonElement?): ChordPalette? {
            val o = e.obj() ?: return null
            return ChordPalette(ModifierChord.fromJson(o["chord"]) ?: return null, o["actions"].listOf(ShortcutItem::fromJson) ?: return null)
        }
    }
}

enum class ControlProfileSlot(val raw: String, val title: String) {
    Default("default", "Default"),
    Profile1("profile1", "Profile 1"),
    Profile2("profile2", "Profile 2");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): ControlProfileSlot? = entries.firstOrNull { it.raw == raw }
    }
}

/** `Array.moveItems(from:to:)`: SwiftUI `onMove` semantics. */
internal fun <T> List<T>.movingItems(source: Set<Int>, destination: Int): List<T> {
    val sorted = source.sorted()
    val moving = sorted.map { this[it] }
    val result = toMutableList()
    for (index in sorted.reversed()) result.removeAt(index)
    val removedBeforeDestination = source.count { it < destination }
    result.addAll(maxOf(0, destination - removedBeforeDestination), moving)
    return result
}

data class ControlProfile(
    var slot: ControlProfileSlot,
    var trayItems: List<TrayItemConfiguration>,
    var palettes: List<ChordPalette>,
) {
    val id: String get() = slot.raw

    val visibleTrayItems: List<ControlTrayItem> get() = trayItems.filter { it.isVisible }.map { it.item }

    fun actions(chord: ModifierChord): List<ShortcutItem> = palettes.firstOrNull { it.chord == chord }?.actions ?: emptyList()

    fun setActions(actions: List<ShortcutItem>, chord: ModifierChord) {
        val index = palettes.indexOfFirst { it.chord == chord }
        palettes = if (index >= 0) {
            palettes.toMutableList().also { it[index] = it[index].copy(actions = actions) }
        } else {
            palettes + ChordPalette(chord, actions)
        }
    }

    fun moveTrayItems(source: Set<Int>, destination: Int) {
        trayItems = trayItems.movingItems(source, destination)
    }

    fun moveActions(chord: ModifierChord, source: Set<Int>, destination: Int) {
        setActions(actions(chord).movingItems(source, destination), chord)
    }

    fun toJson(): JsonElement = buildJsonObject {
        put("slot", jsonOf(slot.raw))
        put("trayItems", jsonArrayOf(trayItems.map { it.toJson() }))
        put("palettes", jsonArrayOf(palettes.map { it.toJson() }))
    }

    companion object {
        fun fromJson(e: JsonElement?): ControlProfile? {
            val o = e.obj() ?: return null
            return ControlProfile(
                ControlProfileSlot.of(o["slot"].str()) ?: return null,
                o["trayItems"].listOf(TrayItemConfiguration::fromJson) ?: return null,
                o["palettes"].listOf(ChordPalette::fromJson) ?: return null,
            )
        }

        fun canonical(slot: ControlProfileSlot = ControlProfileSlot.Default): ControlProfile {
            val tray = ControlTrayItem.entries.map { TrayItemConfiguration(it, true) }
            val command = ModifierChord(ControlModifier.Command)
            val commandOption = ModifierChord(ControlModifier.Command, ControlModifier.Option)
            val commandShift = ModifierChord(ControlModifier.Command, ControlModifier.Shift)
            return ControlProfile(
                slot, tray,
                listOf(
                    ChordPalette(
                        command,
                        listOf(
                            shortcut("copy", "Copy", "C", 6, command),
                            shortcut("paste", "Paste", "V", 25, command),
                            shortcut("cut", "Cut", "X", 27, command),
                            shortcut("undo", "Undo", "Z", 29, command),
                            shortcut("select-all", "Select All", "A", 4, command),
                            shortcut("close", "Close", "W", 26, command),
                            shortcut("spotlight", "Spotlight", "Space", 44, command),
                        ),
                    ),
                    ChordPalette(
                        commandOption,
                        listOf(
                            shortcut("move-here", "Move Item Here", "V", 25, commandOption),
                            shortcut("force-quit", "Force Quit", "Esc", 41, commandOption),
                            shortcut("dock", "Toggle Dock", "D", 7, commandOption),
                            shortcut("hide-others", "Hide Others", "H", 11, commandOption),
                            shortcut("close-all", "Close All Windows", "W", 26, commandOption),
                        ),
                    ),
                    ChordPalette(
                        commandShift,
                        listOf(
                            shortcut("redo", "Redo", "Z", 29, commandShift),
                            shortcut("new-folder", "New Folder", "N", 17, commandShift),
                            shortcut("reopen-tab", "Reopen Closed Tab", "T", 23, commandShift),
                            shortcut("screenshot", "Screenshot", "3", 32, commandShift),
                            shortcut("screenshot-selection", "Screenshot Selection", "4", 33, commandShift),
                            shortcut("screenshot-controls", "Screenshot Controls", "5", 34, commandShift),
                        ),
                    ),
                ),
            )
        }

        private fun shortcut(id: String, title: String, key: String, usage: Int, chord: ModifierChord) =
            ShortcutItem(id = id, title = title, displayKey = key, usage = usage, modifiers = chord)
    }
}

/** Which side of the screen the tray hugs in landscape. Portrait is always bottom-centered. */
enum class LandscapeTraySide(val raw: String, val title: String) {
    Leading("leading", "Left"),
    Trailing("trailing", "Right");

    val id: String get() = raw
    val opposite: LandscapeTraySide get() = if (this == Leading) Trailing else Leading

    companion object {
        fun of(raw: String?): LandscapeTraySide? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Receiver-local destination for a two-finger pinch or rotation gesture. The
 * stored choice is preserved while video is off; the receiver applies the
 * temporary App override at routing time instead of rewriting it.
 * `Disabled` never zooms/rotates the viewport and never fires an App Gesture
 * Command (VideoInteractionPolicy must never promote it to App).
 */
enum class ReceiverGestureTarget(val raw: String, val title: String) {
    Viewport("viewport", "Viewport"),
    App("app", "App"),
    Disabled("disabled", "Disabled");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): ReceiverGestureTarget? = entries.firstOrNull { it.raw == raw }
    }
}

/** One configurable App-mode gesture command. */
enum class AppGestureCommandKind(val raw: String, val title: String) {
    ZoomIn("zoomIn", "Zoom In"),
    ZoomOut("zoomOut", "Zoom Out"),
    RotateLeft("rotateLeft", "Rotate Left"),
    RotateRight("rotateRight", "Rotate Right");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): AppGestureCommandKind? = entries.firstOrNull { it.raw == raw }
    }
}

/** Persisted defaults: Cmd+= / Cmd+- / Cmd+[ / Cmd+]. HID keyboard-page usages. */
data class AppGestureCommands(
    var zoomIn: KeyboardShortcut = KeyboardShortcut(46, ModifierChord(ControlModifier.Command)),
    var zoomOut: KeyboardShortcut = KeyboardShortcut(45, ModifierChord(ControlModifier.Command)),
    var rotateLeft: KeyboardShortcut = KeyboardShortcut(47, ModifierChord(ControlModifier.Command)),
    var rotateRight: KeyboardShortcut = KeyboardShortcut(48, ModifierChord(ControlModifier.Command)),
) {
    fun shortcut(kind: AppGestureCommandKind): KeyboardShortcut = when (kind) {
        AppGestureCommandKind.ZoomIn -> zoomIn
        AppGestureCommandKind.ZoomOut -> zoomOut
        AppGestureCommandKind.RotateLeft -> rotateLeft
        AppGestureCommandKind.RotateRight -> rotateRight
    }

    fun setShortcut(shortcut: KeyboardShortcut, kind: AppGestureCommandKind) {
        when (kind) {
            AppGestureCommandKind.ZoomIn -> zoomIn = shortcut
            AppGestureCommandKind.ZoomOut -> zoomOut = shortcut
            AppGestureCommandKind.RotateLeft -> rotateLeft = shortcut
            AppGestureCommandKind.RotateRight -> rotateRight = shortcut
        }
    }

    fun toJson(): JsonElement = buildJsonObject {
        put("zoomIn", zoomIn.toJson())
        put("zoomOut", zoomOut.toJson())
        put("rotateLeft", rotateLeft.toJson())
        put("rotateRight", rotateRight.toJson())
    }

    companion object {
        val defaults: AppGestureCommands get() = AppGestureCommands()

        fun fromJson(e: JsonElement?): AppGestureCommands? {
            val o = e.obj() ?: return null
            return AppGestureCommands(
                KeyboardShortcut.fromJson(o["zoomIn"]) ?: return null,
                KeyboardShortcut.fromJson(o["zoomOut"]) ?: return null,
                KeyboardShortcut.fromJson(o["rotateLeft"]) ?: return null,
                KeyboardShortcut.fromJson(o["rotateRight"]) ?: return null,
            )
        }
    }
}

/**
 * Full key list for App Gesture Commands editing — letters, 0-9, the listed
 * symbol keys and special keys. "+" is Shift with "=", so not listed.
 */
val appGestureCommandEditableKeys: List<Pair<String, Int>> = run {
    val letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".mapIndexed { i, c -> c.toString() to (4 + i) }
    val digits = listOf("1" to 30, "2" to 31, "3" to 32, "4" to 33, "5" to 34, "6" to 35, "7" to 36, "8" to 37, "9" to 38, "0" to 39)
    val symbols = listOf("=" to 46, "-" to 45, "[" to 47, "]" to 48, "/" to 56, "\\" to 49, "," to 54, "." to 55, ";" to 51, "'" to 52)
    val special = listOf(
        "Space" to 44, "Return" to 40, "Tab" to 43, "Escape" to 41, "Delete" to 42,
        "↑" to 82, "↓" to 81, "←" to 80, "→" to 79,
    )
    letters + digits + symbols + special
}

fun appGestureCommandKeyLabel(usage: Int): String = appGestureCommandEditableKeys.firstOrNull { it.second == usage }?.first ?: "?"

fun appGestureCommandDisplayText(shortcut: KeyboardShortcut): String = shortcut.modifiers.symbols + appGestureCommandKeyLabel(shortcut.usage)

// MARK: - Function Tray

/**
 * One Function Tray button. Reuses [ShortcutItem]/[ControlAction] exactly as
 * the Main Tray's chord palettes do but fires immediately on tap. `group`
 * is a generic visual-clustering key: consecutive items sharing it render as
 * one bubble cluster.
 */
data class FunctionTrayItemConfiguration(
    var item: ShortcutItem,
    var isVisible: Boolean,
    var group: Int,
    /** The user's name for a built-in action (custom items rename `item` itself). */
    var customTitle: String? = null,
    /** The user's face for a built-in action. */
    var customDisplay: ShortcutButtonDisplay? = null,
) {
    val id: String get() = item.id

    /** `item` with the user's name and face applied. */
    val resolvedItem: ShortcutItem
        get() {
            var resolved = item
            val title = customTitle
            if (!title.isNullOrEmpty()) resolved = resolved.copy(title = title)
            customDisplay?.let { resolved = resolved.copy(display = it) }
            return resolved
        }

    fun toJson(): JsonElement = buildJsonObject {
        put("item", item.toJson())
        put("isVisible", jsonOf(isVisible))
        put("group", jsonOf(group))
        putIfNotNull("customTitle", customTitle?.let(::jsonOf))
        putIfNotNull("customDisplay", customDisplay?.toJson())
    }

    companion object {
        fun fromJson(e: JsonElement?): FunctionTrayItemConfiguration? {
            val o = e.obj() ?: return null
            val customDisplay = o["customDisplay"]?.takeIf { it !is kotlinx.serialization.json.JsonNull }
                ?.let { ShortcutButtonDisplay.fromJson(it) ?: return null }
            return FunctionTrayItemConfiguration(
                ShortcutItem.fromJson(o["item"]) ?: return null,
                o["isVisible"].bool() ?: return null,
                o["group"].int() ?: return null,
                o["customTitle"].str(),
                customDisplay,
            )
        }
    }
}

/**
 * The Function Tray's profile: independent of [ControlProfile] even though it
 * reuses the Default/Profile 1/Profile 2 slots — Main Tray and Function Tray
 * profiles are selected, stored and switched separately.
 */
data class FunctionTrayProfile(var slot: ControlProfileSlot, var items: List<FunctionTrayItemConfiguration>) {
    val id: String get() = slot.raw

    val visibleItems: List<ShortcutItem> get() = items.filter { it.isVisible }.map { it.resolvedItem }

    /** Every action, visible or not, as it should appear. */
    val allItems: List<ShortcutItem> get() = items.map { it.resolvedItem }

    /** [visibleItems] clustered into consecutive runs of the same `group`, in tray order. */
    val visibleGroups: List<List<ShortcutItem>>
        get() {
            val groups = mutableListOf<MutableList<ShortcutItem>>()
            var currentGroup: Int? = null
            for (configuration in items) {
                if (!configuration.isVisible) continue
                if (currentGroup != configuration.group) {
                    groups += mutableListOf<ShortcutItem>()
                    currentGroup = configuration.group
                }
                groups.last() += configuration.resolvedItem
            }
            return groups
        }

    fun moveItems(source: Set<Int>, destination: Int) {
        items = items.movingItems(source, destination)
    }

    /**
     * Refreshes presentation and shortcut metadata by stable action ID.
     * Visibility, ordering and grouping remain user-owned. A canonical item a
     * saved profile predates is appended HIDDEN. A tray still exactly as an
     * earlier release started it was never customized, so it takes today's
     * default instead, new visible actions included.
     */
    fun resolvingCanonicalMetadata(): FunctionTrayProfile {
        if (isEarlierReleaseDefault) return canonical(slot)
        val canonical = canonical(slot).items
        val canonicalByID = canonical.associate { it.id to it.item }
        val savedIDs = items.map { it.id }.toSet()
        val resolved = items.map { configuration ->
            val item = canonicalByID[configuration.id] ?: return@map configuration
            FunctionTrayItemConfiguration(item, configuration.isVisible, configuration.group, configuration.customTitle, configuration.customDisplay)
        }
        val added = canonical.filter { it.id !in savedIDs }.map { FunctionTrayItemConfiguration(it.item, false, it.group) }
        return FunctionTrayProfile(slot, resolved + added)
    }

    /** Unchanged since an earlier release created it, and no built-in renamed or restyled. */
    private val isEarlierReleaseDefault: Boolean
        get() {
            val entries = items.map { EarlierDefaultEntry(it.id, it.isVisible, it.group) }
            return entries in EARLIER_RELEASE_DEFAULTS && items.all { it.customTitle == null && it.customDisplay == null }
        }

    /** Built-in actions can't be deleted (they come back hidden), so removing one hides it; custom actions are deleted. */
    fun removeItem(id: String) {
        items = if (isBuiltIn(id)) {
            items.map { if (it.id == id) it.copy(isVisible = false) else it }
        } else {
            items.filter { it.id != id }
        }
    }

    /** Adds a user-made action, visible, in its own group at the end. False when invalid or the tray is full. */
    fun addCustomItem(item: ShortcutItem): Boolean {
        if (!item.action.isValid || items.any { it.id == item.id } || items.count { !isBuiltIn(it.id) } >= MAXIMUM_CUSTOM_ITEMS) return false
        val group = (items.maxOfOrNull { it.group } ?: 0) + 1
        items = items + FunctionTrayItemConfiguration(item, true, group)
        return true
    }

    /** Replaces a custom action's definition (its name, keys, face). */
    fun updateCustomItem(item: ShortcutItem) {
        if (!item.action.isValid || isBuiltIn(item.id)) return
        val index = items.indexOfFirst { it.id == item.id }
        if (index < 0) return
        items = items.toMutableList().also { it[index] = it[index].copy(item = item) }
    }

    fun rename(id: String, title: String) {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return
        val trimmed = title.trim().prefixCharacters(40)
        items = items.toMutableList().also {
            if (isBuiltIn(id)) {
                it[index] = it[index].copy(customTitle = trimmed.ifEmpty { null })
            } else if (trimmed.isNotEmpty()) {
                it[index] = it[index].copy(item = it[index].item.copy(title = trimmed))
            }
        }
    }

    fun setDisplay(id: String, display: ShortcutButtonDisplay?) {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return
        items = items.toMutableList().also {
            it[index] = if (isBuiltIn(id)) it[index].copy(customDisplay = display) else it[index].copy(item = it[index].item.copy(display = display))
        }
    }

    fun toJson(): JsonElement = buildJsonObject {
        put("slot", jsonOf(slot.raw))
        put("items", jsonArrayOf(items.map { it.toJson() }))
    }

    private data class EarlierDefaultEntry(val id: String, val isVisible: Boolean, val group: Int)

    companion object {
        /** Every slot's starting tray in an earlier release, by user-owned fields only: v1.20.0, before Return. */
        private val EARLIER_RELEASE_DEFAULTS: List<List<EarlierDefaultEntry>> = listOf(
            listOf(
                EarlierDefaultEntry("zoom-in", true, 0), EarlierDefaultEntry("zoom-out", true, 0),
                EarlierDefaultEntry("undo", true, 1), EarlierDefaultEntry("redo", true, 1),
                EarlierDefaultEntry("menu-bar", false, 2), EarlierDefaultEntry("launchpad", false, 2),
                EarlierDefaultEntry("show-desktop", false, 2), EarlierDefaultEntry("control-center", false, 2),
            ),
        )

        const val MAXIMUM_CUSTOM_ITEMS = 24

        val canonicalIDs: Set<String> by lazy { canonical().items.map { it.id }.toSet() }

        fun isBuiltIn(id: String): Boolean = id in canonicalIDs

        fun fromJson(e: JsonElement?): FunctionTrayProfile? {
            val o = e.obj() ?: return null
            return FunctionTrayProfile(
                ControlProfileSlot.of(o["slot"].str()) ?: return null,
                o["items"].listOf(FunctionTrayItemConfiguration::fromJson) ?: return null,
            )
        }

        fun canonical(slot: ControlProfileSlot = ControlProfileSlot.Default): FunctionTrayProfile {
            val command = ModifierChord(ControlModifier.Command)
            val commandShift = ModifierChord(ControlModifier.Command, ControlModifier.Shift)
            // Two default clusters: app-level zoom (the Mac app's own ⌘+/⌘−,
            // separate from MeowDisplay's local viewport zoom) and edit.
            val zoomGroup = 0
            val editGroup = 1
            val systemGroup = 2
            // Return in its own cluster after editing, so a reach for Redo can't submit.
            val returnGroup = 3
            val items = listOf(
                ShortcutItem(id = "zoom-in", title = "Zoom In", displayKey = "+", usage = 46, modifiers = command, systemImage = "plus.magnifyingglass") to zoomGroup,
                ShortcutItem(id = "zoom-out", title = "Zoom Out", displayKey = "−", usage = 45, modifiers = command, systemImage = "minus.magnifyingglass") to zoomGroup,
                ShortcutItem(id = "undo", title = "Undo", displayKey = "Z", usage = 29, modifiers = command, systemImage = "arrow.uturn.backward") to editGroup,
                ShortcutItem(id = "redo", title = "Redo", displayKey = "Z", usage = 29, modifiers = commandShift, systemImage = "arrow.uturn.forward") to editGroup,
                // HID Return (40) with no modifiers of its own: a latched ⌘ or ⇧ still applies (⌘↵, ⇧↵).
                ShortcutItem(id = "return", title = "Return", displayKey = "↵", usage = 40, modifiers = ModifierChord(), systemImage = "return") to returnGroup,
            )
            // Opt-in (hidden by default): the only routes to Launchpad and Show Desktop besides the 4/5-finger pinch/spread.
            val systemItems = listOf(
                ShortcutItem("menu-bar", "Menu Bar", ReceiverGesture.MenuBar, "menubar.rectangle") to systemGroup,
                ShortcutItem("launchpad", "Launchpad", ReceiverGesture.Launchpad, "square.grid.3x3") to systemGroup,
                ShortcutItem("show-desktop", "Show Desktop", ReceiverGesture.ShowDesktop, "rectangle.dashed") to systemGroup,
                ShortcutItem("control-center", "Control Center", ReceiverGesture.ControlCenter, "switch.2") to systemGroup,
            )
            return FunctionTrayProfile(
                slot,
                items.map { FunctionTrayItemConfiguration(it.first, true, it.second) } +
                    systemItems.map { FunctionTrayItemConfiguration(it.first, false, it.second) },
            )
        }
    }
}

/** Global placement of the Function Tray relative to the Main Tray in landscape. */
enum class FunctionTrayPosition(val raw: String, val title: String) {
    SameSide("sameSide", "Same Side"),
    OppositeSide("oppositeSide", "Opposite Side");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): FunctionTrayPosition? = entries.firstOrNull { it.raw == raw }
    }
}

/** Superseded by [LandscapeTraySide]. Decoded only to migrate schema-2 preferences; never written. */
enum class LandscapeTrayCorner(val raw: String) {
    TopLeading("topLeading"), TopTrailing("topTrailing"), BottomLeading("bottomLeading"), BottomTrailing("bottomTrailing");

    val side: LandscapeTraySide get() = if (this == TopLeading || this == BottomLeading) LandscapeTraySide.Leading else LandscapeTraySide.Trailing

    companion object {
        fun of(raw: String?): LandscapeTrayCorner? = entries.firstOrNull { it.raw == raw }
    }
}

/** Strip/Overlay chord palette presentation. */
enum class PadPaletteStyle(val raw: String, val title: String) {
    /** Separate keys in a row or column beside the rail. */
    Keys("keys", "Keys"),

    /** A segmented wheel — see `WheelPaletteGeometry`. */
    Wheel("wheel", "Wheel");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): PadPaletteStyle? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Per-axis remote scroll direction. The gesture pipeline delivers natural
 * deltas (content follows the fingers); turning an axis's inversion off flips
 * that axis alone.
 */
object ScrollDirectionPolicy {
    fun apply(dx: Double, dy: Double, invertVertical: Boolean, invertHorizontal: Boolean): Pair<Double, Double> =
        (if (invertHorizontal) dx else -dx) to (if (invertVertical) dy else -dy)
}

/**
 * Software-keyboard typing while a MeowDisplay modifier chord is active: the
 * typed key is sent as that chord (⌘ latched, then C → ⌘C) instead of text.
 */
object SoftwareKeyboardChordPolicy {
    /** The key press for one typed character under [modifiers], or null when no chord is active or the character has no key. */
    fun press(text: String, modifiers: Set<ControlModifier>): Pair<Int, List<String>>? {
        if (modifiers.isEmpty()) return null
        // One Swift Character.
        if (text.isEmpty() || text.prefixCharacters(1) != text) return null
        val chord = modifiers.toMutableSet()
        val usage: Int? = when {
            text == " " -> 44
            text == "\n" -> 40
            text.length == 1 && text[0].isLetter() && text[0].code < 128 -> {
                if (text[0].isUpperCase()) chord += ControlModifier.Shift
                text[0].lowercaseChar().code - 97 + 4
            }
            else -> appGestureCommandEditableKeys.firstOrNull { it.first == text }?.second
        }
        return (usage ?: return null) to ControlModifier.ordered(chord).map { it.raw }
    }

    /** Modifier names for a special or hardware key: its own plus the chord. */
    fun modifiers(own: List<String>, chord: Set<ControlModifier>): List<String> {
        val combined = own.toSet() + chord.map { it.raw }
        return ControlModifier.entries.map { it.raw }.filter { it in combined }
    }
}

/**
 * Mac -> receiver control/UI preference push, carried on `receiverUI`. Every
 * field is optional and additive; the receiver applies only the keys a Mac
 * actually sent.
 */
data class ReceiverUIPreferenceUpdate(
    val trayEnabled: Boolean? = null,
    val keyboardButtonEnabled: Boolean? = null,
    val functionTrayEnabled: Boolean? = null,
    val inputMode: PointerInputMode? = null,
    val trackpadSensitivity: Double? = null,
    val hapticsEnabled: Boolean? = null,
    val avoidNotch: Boolean? = null,
    val pinchTarget: ReceiverGestureTarget? = null,
    val rotateTarget: ReceiverGestureTarget? = null,
    val snapRotation: Boolean? = null,
    val appGestureCommands: AppGestureCommands? = null,
) {
    fun apply(preferences: ReceiverControlPreferences) {
        trayEnabled?.let { preferences.trayEnabled = it }
        keyboardButtonEnabled?.let { preferences.keyboardButtonEnabled = it }
        functionTrayEnabled?.let { preferences.functionTrayEnabled = it }
        inputMode?.let { preferences.inputMode = it }
        trackpadSensitivity?.let {
            val range = PointerGestureConfig.trackpadSensitivityRange
            preferences.trackpadSensitivity = minOf(maxOf(it, range.start), range.endInclusive)
        }
        hapticsEnabled?.let { preferences.hapticsEnabled = it }
        avoidNotch?.let { preferences.avoidNotch = it }
        pinchTarget?.let { preferences.pinchTarget = it }
        rotateTarget?.let { preferences.rotateTarget = it }
        snapRotation?.let { preferences.snapRotation = it }
        appGestureCommands?.let { preferences.appGestureCommands = it.copy() }
    }

    companion object {
        /** Null unless [message] is a `receiverUI` carrying at least one known field. */
        fun parse(message: JsonObject): ReceiverUIPreferenceUpdate? {
            if (message["type"].str() != "receiverUI") return null
            val update = ReceiverUIPreferenceUpdate(
                trayEnabled = message["trayEnabled"].bool(),
                keyboardButtonEnabled = message["keyboardButtonEnabled"].bool(),
                functionTrayEnabled = message["functionTrayEnabled"].bool(),
                inputMode = PointerInputMode.of(message["inputMode"].str()),
                trackpadSensitivity = message["trackpadSensitivity"].dbl()?.takeIf { it.isFinite() },
                hapticsEnabled = message["hapticsEnabled"].bool(),
                avoidNotch = message["avoidNotch"].bool(),
                pinchTarget = ReceiverGestureTarget.of(message["pinchTarget"].str()),
                rotateTarget = ReceiverGestureTarget.of(message["rotateTarget"].str()),
                snapRotation = message["snapRotation"].bool(),
                appGestureCommands = message["appGestureCommands"]?.let(AppGestureCommands::fromJson),
            )
            return update.takeIf { it != ReceiverUIPreferenceUpdate() }
        }
    }
}
