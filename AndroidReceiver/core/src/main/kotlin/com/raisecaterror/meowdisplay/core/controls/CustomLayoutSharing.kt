package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/CustomLayoutSharing.swift.
//
// Portable share codes for Custom layouts, and the editor's display-only
// Preview session.
//
// Interchange with the iOS app: the code is `MDL1-<body>.<check>`; `body` is
// the payload JSON (sorted keys, compact, written the way Swift's JSONEncoder
// writes it) compressed with Apple's `.zlib` algorithm, which is RAW DEFLATE
// (RFC 1951, no zlib header: verified on macOS, the stream starts 0xCB, not
// 0x78), then standard base64 with `+` -> `-`, `/` -> `_` and the `=` padding
// removed. `check` is the first 4 bytes of the SHA-256 of the uncompressed
// JSON, lowercase hex. Compressed bytes differ between deflate encoders
// (Apple compresses at level 5), but any conforming inflater reads them.

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.DataFormatException
import java.util.zip.Deflater
import java.util.zip.Inflater
import kotlin.math.max
import kotlin.math.min

/** What can be wrong with a pasted code (Swift's `ShareCodeError`). */
sealed class ShareCodeError : Exception() {
    data object NotAShareCode : ShareCodeError()
    data class UnsupportedVersion(val version: Int) : ShareCodeError()
    data object Corrupted : ShareCodeError()
    data object TooLarge : ShareCodeError()
}

/** Swift's `Result<ImportSummary, ShareCodeError>`. */
sealed interface ShareCodeResult {
    data class Success(val summary: CustomLayoutShareCode.ImportSummary) : ShareCodeResult
    data class Failure(val error: ShareCodeError) : ShareCodeResult

    /** Swift's `.get()`. */
    fun getOrThrow(): CustomLayoutShareCode.ImportSummary = when (this) {
        is Success -> summary
        is Failure -> throw error
    }

    val failure: ShareCodeError? get() = (this as? Failure)?.error
}

/**
 * A Custom layout as text: `MDL<version>-<body>.<check>`. Generated and read
 * entirely on-device.
 *
 * The payload holds only what defines the layout (name, both arrangements:
 * positions, sizes, palette styles, one-tap shortcuts, and Two-Hand Assist),
 * never trust data, keys, device or peer IDs, Remote Access details,
 * permissions or history. Importing validates, sanitizes and summarizes; it
 * never executes anything.
 */
object CustomLayoutShareCode {
    const val currentVersion = 1
    const val maximumCodeLength = 60_000
    const val maximumPayloadBytes = 256 * 1024
    const val maximumPlacements = 64
    const val maximumNameLength = 40

    /**
     * Everything a share code carries: deliberately a separate type from
     * [CustomControlLayout] so its local `id` never leaves the device.
     */
    data class Payload(
        val name: String,
        val landscape: CustomControlArrangement,
        val portrait: CustomControlArrangement,
        val twoHandAssist: Boolean,
        val assistActionIDs: List<String>,
        /** Definitions of the user-made Function actions the layout places (built-in actions travel by id). Omitted when there are none. */
        val functionActions: List<ShortcutItem>?,
    ) {
        fun toJson(): JsonElement = buildJsonObject {
            put("name", jsonOf(name))
            put("landscape", landscape.toJson())
            put("portrait", portrait.toJson())
            put("twoHandAssist", jsonOf(twoHandAssist))
            put("assistActionIDs", jsonArrayOf(assistActionIDs.map(::jsonOf)))
            putIfNotNull("functionActions", functionActions?.let { items -> jsonArrayOf(items.map { it.toJson() }) })
        }

        companion object {
            fun fromJson(e: JsonElement?): Payload? {
                val o = e.obj() ?: return null
                val actions = o["functionActions"]
                return Payload(
                    name = o["name"].str() ?: return null,
                    landscape = CustomControlArrangement.fromJson(o["landscape"]) ?: return null,
                    portrait = CustomControlArrangement.fromJson(o["portrait"]) ?: return null,
                    twoHandAssist = o["twoHandAssist"].bool() ?: return null,
                    assistActionIDs = o["assistActionIDs"].listOf { it.str() } ?: return null,
                    functionActions = if (actions == null || actions is JsonNull) null else actions.listOf(ShortcutItem::fromJson) ?: return null,
                )
            }
        }
    }

    data class ImportSummary(
        /** Ready to add, with a fresh local id. */
        val layout: CustomControlLayout,
        val landscapeControls: Int,
        val portraitControls: Int,
        val shortcutCount: Int,
        val twoHandAssist: Boolean,
        val warnings: List<Warning>,
    ) {
        sealed interface Warning {
            /** Controls from a newer MeowDisplay this version doesn't know. */
            data class SkippedControls(val count: Int) : Warning

            /** Function Tray actions this version doesn't have. */
            data class UnknownActions(val count: Int) : Warning
        }
    }

    /**
     * @param functionItems the Function actions the layout's profile defines;
     * only user-made ones the layout places are carried.
     */
    fun encode(layout: CustomControlLayout, functionItems: List<ShortcutItem> = emptyList()): String {
        val placed = (layout.landscape.placements + layout.portrait.placements).mapNotNull { placement ->
            val kind = placement.kind
            if (kind is CustomControlKind.Function && !FunctionTrayProfile.isBuiltIn(kind.id)) kind.id else null
        }.toSet()
        val actions = functionItems.filter { it.id in placed }
        val payload = Payload(
            name = layout.name, landscape = layout.landscape, portrait = layout.portrait,
            twoHandAssist = layout.twoHandAssist, assistActionIDs = layout.assistActionIDs,
            functionActions = actions.ifEmpty { null },
        )
        val json = SwiftJsonWriter.write(payload.toJson()).toByteArray(Charsets.UTF_8)
        return "MDL$currentVersion-" + base64URL(deflateRaw(json)) + "." + checksum(json)
    }

    fun decode(text: String): ShareCodeResult {
        val code = text.filter { !it.isWhitespace() }
        if (code.length > maximumCodeLength && code.characterCount() > maximumCodeLength) return fail(ShareCodeError.TooLarge)
        val dash = code.indexOf('-')
        if (!code.startsWith("MDL") || dash < 0) return fail(ShareCodeError.NotAShareCode)
        val version = code.substring(3, dash).toIntOrNull() ?: return fail(ShareCodeError.NotAShareCode)
        if (version != currentVersion) return fail(ShareCodeError.UnsupportedVersion(version))
        val rest = code.substring(dash + 1)
        val dot = rest.lastIndexOf('.')
        if (dot < 0) return fail(ShareCodeError.Corrupted)
        val compressed = data(base64URL = rest.substring(0, dot)) ?: return fail(ShareCodeError.Corrupted)
        val json = when (val inflated = inflateRaw(compressed, maximumPayloadBytes)) {
            Inflated.Invalid -> return fail(ShareCodeError.Corrupted)
            Inflated.TooLarge -> return fail(ShareCodeError.TooLarge)
            is Inflated.Bytes -> inflated.bytes
        }
        if (checksum(json) != rest.substring(dot + 1)) return fail(ShareCodeError.Corrupted)
        val element = parseJson(String(json, Charsets.UTF_8)) ?: return fail(ShareCodeError.Corrupted)
        val payload = Payload.fromJson(element) ?: return fail(ShareCodeError.Corrupted)
        return ShareCodeResult.Success(summary(payload, rawPlacementCount(element)))
    }

    private fun fail(error: ShareCodeError) = ShareCodeResult.Failure(error)

    // region Sanitizing

    private fun summary(payload: Payload, rawPlacementCount: Int?): ImportSummary {
        // Carried custom actions become layout-owned one-tap buttons with
        // fresh ids: never merged into, or overwriting, local profiles.
        val definitions = mutableMapOf<String, ShortcutItem>()
        for (action in (payload.functionActions ?: emptyList()).take(maximumPlacements)) {
            if (!action.action.isValid) continue
            // Encode never carries built-ins: a "custom" action claiming a built-in id (Undo, Return, …)
            // could borrow its look while sending something else, so it is dropped (Android hardening).
            if (FunctionTrayProfile.isBuiltIn(action.id) || action.id.characterCount() > 64) continue
            definitions[action.id] = action.copy(id = newUUIDString())
        }
        fun adopt(arrangement: CustomControlArrangement): CustomControlArrangement =
            arrangement.copy(
                placements = arrangement.placements.map { placement ->
                    val kind = placement.kind
                    val item = if (kind is CustomControlKind.Function) definitions[kind.id] else null
                    if (item == null) placement else placement.copy(kind = CustomControlKind.Shortcut(item))
                },
            )
        val landscape = sanitized(adopt(payload.landscape))
        val portrait = sanitized(adopt(payload.portrait))
        val trimmedName = payload.name.trim { it.isWhitespace() }
        val layout = CustomControlLayout(
            id = newUUIDString(),
            name = if (trimmedName.isEmpty()) "Imported Layout" else trimmedName.prefixCharacters(maximumNameLength),
            landscape = landscape, portrait = portrait,
            twoHandAssist = payload.twoHandAssist,
            assistActionIDs = payload.assistActionIDs.filter(FunctionTrayProfile::isBuiltIn).take(8).map { it.prefixCharacters(40) },
        )
        val all = landscape.placements + portrait.placements
        val known = FunctionTrayProfile.canonical().items.map { it.id }.toSet()
        val unknown = all.filter { val k = it.kind; k is CustomControlKind.Function && k.id !in known }
        val warnings = mutableListOf<ImportSummary.Warning>()
        if (rawPlacementCount != null && rawPlacementCount > all.size) {
            warnings.add(ImportSummary.Warning.SkippedControls(rawPlacementCount - all.size))
        }
        if (unknown.isNotEmpty()) warnings.add(ImportSummary.Warning.UnknownActions(unknown.size))
        val shortcuts = all.count { it.kind is CustomControlKind.Shortcut }
        return ImportSummary(
            layout = layout, landscapeControls = landscape.placements.size, portraitControls = portrait.placements.size,
            shortcutCount = shortcuts, twoHandAssist = payload.twoHandAssist, warnings = warnings,
        )
    }

    private fun sanitized(arrangement: CustomControlArrangement): CustomControlArrangement {
        val seen = mutableSetOf<String>()
        val placements = arrangement.placements.take(maximumPlacements).mapNotNull { placement ->
            val unique = seen.add(placement.id)
            val id = if (unique && placement.id.isNotEmpty() && placement.id.characterCount() <= 64) placement.id else newUUIDString()
            var kind = placement.kind
            if (kind is CustomControlKind.Shortcut) {
                var item = kind.item
                if (!item.action.isValid) return@mapNotNull null
                item = item.copy(
                    title = item.title.prefixCharacters(maximumNameLength),
                    displayKey = item.displayKey.prefixCharacters(24),
                    systemImage = item.systemImage?.prefixCharacters(60),
                    // Android hardening: a face is stored no longer than it can ever be drawn.
                    display = when (val face = item.display) {
                        is ShortcutButtonDisplay.Symbol -> face.copy(name = face.name.prefixCharacters(60))
                        is ShortcutButtonDisplay.Text -> face.copy(text = face.text.prefixCharacters(ShortcutButtonDisplay.MAXIMUM_TEXT_LENGTH))
                        is ShortcutButtonDisplay.Emoji -> face.copy(emoji = face.emoji.prefixCharacters(2))
                        else -> face
                    },
                )
                kind = CustomControlKind.Shortcut(item)
            }
            var palette = placement.palette
            if (palette != null) {
                val spacing = if (palette.spacing.isFinite()) {
                    min(max(palette.spacing, PalettePresentation.spacingRange.start), PalettePresentation.spacingRange.endInclusive)
                } else {
                    1.0
                }
                val direction = palette.directionDegrees?.let { if (it.isFinite()) min(max(it, -180.0), 180.0) else null }
                palette = palette.copy(spacing = spacing, directionDegrees = direction)
            }
            // The initializer re-clamps position and size.
            CustomControlPlacement(id = id, kind = kind, x = placement.x, y = placement.y, size = placement.size, palette = palette)
        }
        return CustomControlArrangement(arrangement.corner, placements)
    }

    private fun rawPlacementCount(root: JsonElement): Int? {
        val obj = root as? JsonObject ?: return null
        fun count(key: String): Int = ((obj[key] as? JsonObject)?.get("placements") as? JsonArray)?.size ?: 0
        return min(count("landscape"), maximumPlacements) + min(count("portrait"), maximumPlacements)
    }

    // endregion

    // region Encoding helpers

    private fun checksum(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).take(4).joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun base64URL(data: ByteArray): String =
        Base64.getEncoder().encodeToString(data).replace('+', '-').replace('/', '_').replace("=", "")

    private fun data(base64URL: String): ByteArray? {
        if (!base64URL.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }) return null
        val padded = base64URL.replace('-', '+').replace('_', '/') + "=".repeat((4 - base64URL.length % 4) % 4)
        return try {
            Base64.getDecoder().decode(padded)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    /** Raw DEFLATE (no zlib header), level 5 like Apple's `.zlib`. */
    private fun deflateRaw(input: ByteArray): ByteArray {
        val deflater = Deflater(5, true)
        try {
            deflater.setInput(input)
            deflater.finish()
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
            return out.toByteArray()
        } finally {
            deflater.end()
        }
    }

    private sealed interface Inflated {
        class Bytes(val bytes: ByteArray) : Inflated
        data object Invalid : Inflated
        data object TooLarge : Inflated
    }

    /** Inflates raw DEFLATE, stopping once more than [limit] bytes come out (a decompression bomb). */
    private fun inflateRaw(input: ByteArray, limit: Int): Inflated {
        val inflater = Inflater(true)
        try {
            // The extra byte is the documented dummy for raw streams on older zlib builds.
            inflater.setInput(input + byteArrayOf(0))
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) return Inflated.Invalid
                out.write(buffer, 0, n)
                if (out.size() > limit) return Inflated.TooLarge
            }
            return Inflated.Bytes(out.toByteArray())
        } catch (_: DataFormatException) {
            return Inflated.Invalid
        } finally {
            inflater.end()
        }
    }

    // endregion
}

/**
 * JSON text the way Swift's `JSONEncoder` with `.sortedKeys` writes it: keys
 * sorted, no whitespace, `/` escaped as `\/`, integral doubles without a
 * fraction, other doubles as Swift's `description`.
 */
internal object SwiftJsonWriter {
    fun write(element: JsonElement): String = StringBuilder().also { append(it, element) }.toString()

    private fun append(sb: StringBuilder, element: JsonElement) {
        when (element) {
            is JsonObject -> {
                sb.append('{')
                element.entries.sortedBy { it.key }.forEachIndexed { index, (key, value) ->
                    if (index > 0) sb.append(',')
                    appendString(sb, key)
                    sb.append(':')
                    append(sb, value)
                }
                sb.append('}')
            }
            is JsonArray -> {
                sb.append('[')
                element.forEachIndexed { index, value ->
                    if (index > 0) sb.append(',')
                    append(sb, value)
                }
                sb.append(']')
            }
            is JsonNull -> sb.append("null")
            is JsonPrimitive -> if (element.isString) appendString(sb, element.content) else sb.append(number(element.content))
        }
    }

    private fun appendString(sb: StringBuilder, text: String) {
        sb.append('"')
        for (c in text) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '/' -> sb.append("\\/")
                c == '\b' -> sb.append("\\b")
                c == '\u000C' -> sb.append("\\f")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c < ' ' -> sb.append("\\u%04x".format(c.code))
                else -> sb.append(c)
            }
        }
        sb.append('"')
    }

    /** Booleans and integers pass through; a fractional or exponent form is rewritten as Swift prints that Double. */
    private fun number(content: String): String {
        if (content == "true" || content == "false" || content.none { it == '.' || it == 'e' || it == 'E' }) return content
        val value = content.toDouble()
        require(value.isFinite()) { "JSON cannot hold a non-finite number" }
        return swiftDescription(value)
    }

    /** Swift's `Double.description`: shortest round-trip digits; exponent form below 1e-4 or from 1e16. */
    fun swiftDescription(value: Double): String {
        if (value == 0.0) return if (1.0 / value < 0) "-0" else "0"
        val negative = value < 0
        val decimal = java.math.BigDecimal(java.lang.Double.toString(kotlin.math.abs(value))).stripTrailingZeros()
        val digits = decimal.unscaledValue().toString()
        val exponent = digits.length - 1 - decimal.scale()
        val body = if (exponent < -4 || exponent >= 16) {
            val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
            mantissa + "e" + (if (exponent < 0) "-" else "+") + kotlin.math.abs(exponent).toString().padStart(2, '0')
        } else if (decimal.scale() <= 0) {
            digits + "0".repeat(-decimal.scale())
        } else {
            decimal.toPlainString()
        }
        return if (negative) "-$body" else body
    }
}

/** Swift's `String.count`: grapheme clusters. */
internal fun String.characterCount(): Int {
    if (isEmpty()) return 0
    val iterator = java.text.BreakIterator.getCharacterInstance()
    iterator.setText(this)
    var count = 0
    while (iterator.next() != java.text.BreakIterator.DONE) count++
    return count
}

sealed interface CustomLayoutImportResult {
    data class Imported(val id: String) : CustomLayoutImportResult
    data object LimitReached : CustomLayoutImportResult
}

/**
 * Adds an imported layout as a new layout, never overwriting one, within
 * [CustomControlLayout.maximumCount]. A clashing name gets a number.
 */
fun ReceiverControlPreferences.importCustomLayout(layout: CustomControlLayout): CustomLayoutImportResult {
    if (!canCreateCustomLayout) return CustomLayoutImportResult.LimitReached
    var imported = layout.copy(id = newUUIDString())
    val names = customLayouts.map { it.name }.toSet()
    if (imported.name in names) {
        var number = 2
        while ("${imported.name} $number" in names) number += 1
        imported = imported.copy(name = "${imported.name} $number")
    }
    customLayouts = customLayouts + imported
    return CustomLayoutImportResult.Imported(imported.id)
}

// region Editor Preview

/**
 * The Custom editor's Preview: the real chord state machine driving the real
 * layout geometry, with every would-be Mac command turned into a display-only
 * note. It has no way to reach a receiver or the wire.
 */
class CustomLayoutPreviewSession {
    /** What Preview shows instead of sending. */
    sealed interface Feedback {
        /** The keys that a tap would send, e.g. `⌘C`. */
        data class WouldSend(val keys: String) : Feedback

        /** A non-keyboard action, e.g. Show Desktop. */
        data class WouldPerform(val title: String) : Feedback
    }

    var interaction = ControlInteractionState()
        private set
    var feedback: Feedback? = null
        private set

    /** Tap-to-latch, exactly like the live modifier buttons. */
    fun tapModifier(modifier: ControlModifier) {
        interaction.tap(modifier)
    }

    /** A helper modifier on the Two-Hand Assist side. */
    fun tapAssistModifier(modifier: ControlModifier) {
        interaction.toggleAssistModifier(modifier)
    }

    fun tapPaletteAction(action: ShortcutItem) {
        val chord = interaction.activeChord
        val effects = interaction.finish(action)
        if (ControlInteractionEffect.Execute(action) !in effects) return
        feedback = when (action.action) {
            is ControlAction.KeyboardShortcutAction -> Feedback.WouldSend(chord.hudText(action.displayKey))
            is ControlAction.ReceiverGestureAction -> Feedback.WouldPerform(action.title)
            is ControlAction.Sequence -> Feedback.WouldSend(action.keysDescription)
        }
    }

    /** A one-tap control (Function action or custom shortcut). */
    fun tapAction(item: ShortcutItem) {
        feedback = when (val a = item.action) {
            is ControlAction.KeyboardShortcutAction -> {
                val keys = a.shortcut.usages.joinToString("+", transform = ::appGestureCommandKeyLabel)
                Feedback.WouldSend(a.shortcut.modifiers.symbols + keys)
            }
            is ControlAction.ReceiverGestureAction -> Feedback.WouldPerform(item.title)
            is ControlAction.Sequence -> Feedback.WouldSend(item.keysDescription)
        }
    }

    fun reset() {
        interaction.resetAll()
        feedback = null
    }

    override fun equals(other: Any?): Boolean = other is CustomLayoutPreviewSession && interaction == other.interaction && feedback == other.feedback
    override fun hashCode(): Int = 31 * interaction.hashCode() + (feedback?.hashCode() ?: 0)
}

// endregion

// region Import flow

/**
 * Paste -> Validate -> review -> Import, as state. The flow only finishes (and
 * the screen only closes) after a successful import (or a cancel, which the
 * view handles); every other step keeps the code editable.
 */
class CustomLayoutImportFlow {
    sealed interface Stage {
        data object Entering : Stage
        data class Reviewing(val summary: CustomLayoutShareCode.ImportSummary) : Stage
        data class Failed(val error: ShareCodeError) : Stage
        data class LimitReached(val summary: CustomLayoutShareCode.ImportSummary) : Stage
        data class Imported(val id: String) : Stage
    }

    var code: String = ""
        private set
    var stage: Stage = Stage.Entering
        private set

    val isFinished: Boolean get() = stage is Stage.Imported

    val canValidate: Boolean get() = code.trim { it.isWhitespace() }.isNotEmpty()

    fun edit(text: String) {
        if (text == code) return
        code = text
        stage = Stage.Entering
    }

    /** Paste from Clipboard: take the pasted text and validate it at once. */
    fun paste(text: String?) {
        edit(text ?: "")
        if (canValidate) validate()
    }

    fun validate() {
        if (!canValidate) {
            stage = Stage.Entering
            return
        }
        stage = when (val result = CustomLayoutShareCode.decode(code)) {
            is ShareCodeResult.Success -> Stage.Reviewing(result.summary)
            is ShareCodeResult.Failure -> Stage.Failed(result.error)
        }
    }

    fun importLayout(preferences: ReceiverControlPreferences) {
        val summary = when (val s = stage) {
            is Stage.Reviewing -> s.summary
            is Stage.LimitReached -> s.summary
            else -> return
        }
        stage = when (val result = preferences.importCustomLayout(summary.layout)) {
            is CustomLayoutImportResult.Imported -> Stage.Imported(result.id)
            CustomLayoutImportResult.LimitReached -> Stage.LimitReached(summary)
        }
    }

    override fun equals(other: Any?): Boolean = other is CustomLayoutImportFlow && code == other.code && stage == other.stage
    override fun hashCode(): Int = 31 * code.hashCode() + stage.hashCode()
}

// endregion
