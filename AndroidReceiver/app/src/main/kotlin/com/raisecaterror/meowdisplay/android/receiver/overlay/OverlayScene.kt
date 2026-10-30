package com.raisecaterror.meowdisplay.android.receiver.overlay

import com.raisecaterror.meowdisplay.android.receiver.OverlayEnvironment
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionState
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlProfile
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.CustomControlArrangement
import com.raisecaterror.meowdisplay.core.controls.CustomControlKind
import com.raisecaterror.meowdisplay.core.controls.CustomControlLayout
import com.raisecaterror.meowdisplay.core.controls.CustomControlPlacement
import com.raisecaterror.meowdisplay.core.controls.CustomLayoutGeometry
import com.raisecaterror.meowdisplay.core.controls.FunctionTrayProfile
import com.raisecaterror.meowdisplay.core.controls.LocalViewNavigationPolicy
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.PadControlLayoutMode
import com.raisecaterror.meowdisplay.core.controls.PadControlMetrics
import com.raisecaterror.meowdisplay.core.controls.PadControlScale
import com.raisecaterror.meowdisplay.core.controls.PadEdgeGeometry
import com.raisecaterror.meowdisplay.core.controls.PadEdgeLayout
import com.raisecaterror.meowdisplay.core.controls.PadGroupAlignment
import com.raisecaterror.meowdisplay.core.controls.PadPaletteStyle
import com.raisecaterror.meowdisplay.core.controls.PadRailComposition
import com.raisecaterror.meowdisplay.core.controls.PadStrip
import com.raisecaterror.meowdisplay.core.controls.PaletteShape
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferences
import com.raisecaterror.meowdisplay.core.controls.ShortcutButtonFace
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.TwoHandAssist
import com.raisecaterror.meowdisplay.core.controls.TwoHandAssistState
import com.raisecaterror.meowdisplay.core.controls.WheelPaletteGeometry
import com.raisecaterror.meowdisplay.core.controls.WheelPaletteLayout
import com.raisecaterror.meowdisplay.core.controls.ControlTrayAxis
import com.raisecaterror.meowdisplay.core.controls.ControlTrayGeometry
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.KeyboardBarItem
import com.raisecaterror.meowdisplay.core.controls.activeCustomLayout
import com.raisecaterror.meowdisplay.core.controls.item
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// The pure half of the overlay: for one set of inputs, every frame, chip, key and region
// of one presentation (spec section 2). The composables only draw a Scene and forward touches,
// so everything that decides where a control is, and which part of the screen it owns, is
// JVM-testable. Coordinates are dp (= iOS points) in the overlay's own space.

/** iPhone `Metrics` (RC 350-359) plus the iPad tray padding. */
internal object OverlayMetrics {
    const val TRAY_ITEM = 40.0
    const val TRAY_GAP = 4.0
    const val COLLAPSED = 46.0
    const val PALETTE_KEY = 38.0
    const val PALETTE_GAP = 5.0
    const val TOUCH_SLACK = 4.0
    const val TRAY_PADDING = 6.0

    /** Minimum Mac protocol version that understands synthetic modifiers (`WireProtocol.receiverControlsWireVersion`). */
    const val MODIFIER_PROTOCOL_VERSION = 6
}

/** Which visual primitive a chip uses (RC `chip`, `PadChip(onRail:)`). */
internal enum class ChipStyle { Phone, Rail, Floating }

/** How auto-hide treats a chip: the phone retreat (fade + scale + nudge), a plain fade, or never. */
internal enum class HideKind { None, Retreat, Fade }

internal sealed interface ChipFace {
    /** [size] is the font size in dp. */
    data class Label(val text: String, val size: Double, val rounded: Boolean = false, val shrinks: Boolean = false) : ChipFace

    /** [size] is the glyph box in dp. */
    data class Glyph(val glyph: OverlayGlyph, val size: Double) : ChipFace
}

/** What a chip does when TalkBack activates it, or (for own-tap chips) when tapped. */
internal sealed interface Activation {
    data class Tray(val item: ControlTrayItem) : Activation
    data object DismissKeyboard : Activation
    data object ReturnKey : Activation
    data object MoveView : Activation
    data class Function(val item: ShortcutItem) : Activation
    data class AssistModifier(val modifier: ControlModifier) : Activation
}

internal data class ChipSpec(
    val key: String,
    /** The circle. */
    val frame: CGRect,
    val face: ChipFace,
    val style: ChipStyle,
    val selected: Boolean,
    val label: String,
    val stateText: String? = null,
    /** Strip hint caption under the chip. */
    val hint: String? = null,
    val hide: HideKind = HideKind.None,
    val activation: Activation,
    /** Function and Two-Hand Assist chips own their taps (RC `onTapGesture`); the rest are driven by the chord gesture. */
    val ownTap: Boolean = false,
)

internal data class TraySpec(val rect: CGRect, val hideable: Boolean = false)

internal data class PaletteKeySpec(val action: ShortcutItem, val frame: CGRect, val style: ChipStyle, val selected: Boolean, val pill: Boolean = false)

internal data class WheelSpec(val layout: WheelPaletteLayout, val actions: List<ShortcutItem>, val selectedID: String?, val centerLabel: String)

internal data class HudSpec(val text: String, val cx: Double, val cy: Double)

/** The "No shortcuts for ..." caption; [onMaterial] is the phone look, otherwise the black pill. */
internal data class EmptyLabelSpec(val text: String, val cx: Double, val cy: Double, val onMaterial: Boolean)

internal data class RegionRect(val key: String, val rect: CGRect)

internal enum class Presentation { Phone, KeyboardBar, Strip, Overlay, Custom }

internal data class Scene(
    val presentation: Presentation,
    val chips: List<ChipSpec> = emptyList(),
    val strips: List<PadStrip> = emptyList(),
    val trays: List<TraySpec> = emptyList(),
    val paletteTray: TraySpec? = null,
    val keys: List<PaletteKeySpec> = emptyList(),
    val wheel: WheelSpec? = null,
    val emptyLabel: EmptyLabelSpec? = null,
    val hud: HudSpec? = null,
    /** Entry scale of the palette container (phone .75, pad keys .8, wheel .85, custom keys .6). */
    val paletteEnterScale: Float = 0.75f,
    /** Frame ids -> frames for the gesture's hit-testing (spec 1: modifier:, tray:, action:, control:). */
    val frames: Map<String, CGRect> = emptyMap(),
    /** The union of rects that own touches; everything else falls through to the video. */
    val region: List<RegionRect> = emptyList(),
    val occupied: List<CGRect> = emptyList(),
    /** Strip only: where the Mac picture goes beside the rails. */
    val canvas: CGRect? = null,
    val interactiveItems: List<ControlTrayItem> = emptyList(),
    /** Where the phone tray retreats to while auto-hidden (zero under Reduce Motion). */
    val retreat: CGPoint = CGPoint.zero,
    val showsMoveBanner: Boolean = false,
    val keyboardBar: Boolean = false,
    val bannerCenterY: Double = 0.0,
    val wheelHit: WheelHit? = null,
)

/** Every input a presentation depends on, for one composition pass. */
internal class SceneInput(
    val env: OverlayEnvironment,
    val prefs: ReceiverControlPreferences,
    val profile: ControlProfile,
    val functionProfile: FunctionTrayProfile,
    val layoutMode: PadControlLayoutMode,
    /** Already folded with `screenReaderRunning` (a screen reader never auto-hides). */
    val autoHiding: Boolean,
    val moveViewActive: Boolean,
    val chord: ChordSnapshot,
    val interaction: ControlInteractionState,
) {
    val container = CGRect(0.0, 0.0, env.containerSize.width, env.containerSize.height)
    val portrait: Boolean get() = env.containerSize.height > env.containerSize.width
    val collapsed: Boolean get() = prefs.trayCollapsed || !prefs.trayCanBeShown
    val safe: ControlSafeInsets get() = env.safeInsets

    /** RC `capabilityAllows`: modifiers need a Mac that speaks receiver controls, Keyboard needs the keyboard wire and its switch. */
    fun allows(item: ControlTrayItem): Boolean =
        if (item.modifier != null) env.senderPV >= OverlayMetrics.MODIFIER_PROTOCOL_VERSION
        else item != ControlTrayItem.Keyboard || (prefs.keyboardButtonEnabled && env.keyboardAvailable)

    /** RC `controls`: the iPhone tray's items. The gear is permanent chrome. */
    val phoneControls: List<ControlTrayItem>
        get() = when {
            !prefs.trayCanBeShown -> listOf(ControlTrayItem.Settings)
            prefs.trayCollapsed -> listOf(ControlTrayItem.Settings)
            else -> profile.visibleTrayItems.filter(::allows)
        }

    /**
     * Strip / Overlay / Custom: any chip the rail or layout actually draws can be started on.
     * (The Swift only accepts profile-visible items on rails, leaving a drawn Escape or Dock
     * dead when the Control Profile hides it; this is the consciously fixed behavior.)
     */
    val padInteractiveItems: List<ControlTrayItem>
        get() = if (!prefs.trayCanBeShown || prefs.trayCollapsed) listOf(ControlTrayItem.Settings)
        else ControlTrayItem.entries.filter(::allows)

    val functionGroups: List<List<ShortcutItem>>
        get() = if (prefs.functionTrayCanBeShown) functionProfile.visibleGroups else emptyList()

    val padShowsMoveView: Boolean
        get() = !collapsed && LocalViewNavigationPolicy.showsMoveView(true, prefs.allowLocalViewNavigation, env.videoEnabled)

    fun actions(chord: ModifierChord?): List<ShortcutItem> = chord?.let(profile::actions) ?: emptyList()
}

internal object OverlayScenes {
    fun build(input: SceneInput): Scene = when {
        input.env.keyboardVisibleRect != null -> keyboardBar(input)
        !input.env.expanded -> phone(input)
        input.layoutMode == PadControlLayoutMode.Custom && input.prefs.activeCustomLayout != null ->
            custom(input, input.prefs.activeCustomLayout!!)
        else -> edge(input, input.layoutMode)
    }

    // region shared

    private fun round(v: Double) = floor(v + 0.5)

    fun faceFor(face: ShortcutButtonFace, diameter: Double): ChipFace = when (face) {
        is ShortcutButtonFace.Symbol -> ChipFace.Glyph(OverlayGlyphs.forSymbol(face.name), diameter * 0.4)
        is ShortcutButtonFace.Text -> ChipFace.Label(
            face.text, diameter * (if (face.text.codePointCount(0, face.text.length) > 2) 0.28 else 0.36),
            rounded = true, shrinks = true,
        )
    }

    private fun rectAt(cx: Double, cy: Double, w: Double, h: Double = w) = CGRect(cx - w / 2, cy - h / 2, w, h)

    private fun hud(chord: ChordSnapshot, actions: List<ShortcutItem>, cx: Double, cy: Double): HudSpec? {
        val selected = actions.firstOrNull { it.id == chord.selectedActionID } ?: return null
        return HudSpec(chord.activeChord.hudText(selected.displayKey), cx, cy)
    }

    private fun emptyText(chord: ModifierChord) = "No shortcuts for ${chord.displayName}"

    /** The usual a11y wording of a tray chip's on/off state (literal English, like the iOS strings). */
    private fun onOff(on: Boolean) = if (on) "On" else "Off"

    private fun inset(r: CGRect, d: Double) = r.insetBy(-d, -d)

    // endregion

    // region iPhone compact tray (RC phoneBody)

    private fun phone(input: SceneInput): Scene {
        val env = input.env
        val prefs = input.prefs
        val w = env.containerSize.width
        val h = env.containerSize.height
        val portrait = input.portrait
        val collapsed = input.collapsed
        val controls = input.phoneControls
        val count = max(controls.size, 1)
        val d = ControlTrayGeometry.fittedChipDiameter(
            count, if (portrait) w else h, OverlayMetrics.TRAY_ITEM, OverlayMetrics.TRAY_GAP, OverlayMetrics.TOUCH_SLACK,
        )
        val traySize = trayContentSize(collapsed, portrait, count, d)
        val chord = input.chord
        val paletteChord = chord.paletteChord
        val actions = input.actions(paletteChord)
        val paletteSize = phonePaletteSize(actions.size, portrait)
        val layout = ControlTrayGeometry.layout(
            container = input.container, safeInsets = input.safe, keyboardVisibleRect = env.keyboardVisibleRect,
            portrait = portrait, side = prefs.preferredLandscapeSide, traySize = traySize, paletteSize = paletteSize,
            avoidNotch = prefs.avoidNotch, notchSide = env.notchSide, reservedRegions = env.reservedRegions,
        )
        val retreatDistance = if (env.reduceMotion) 0.0 else 3.0
        val retreat = if (portrait) CGPoint(0.0, retreatDistance)
        else CGPoint(if (layout.side == com.raisecaterror.meowdisplay.core.controls.LandscapeTraySide.Leading) -retreatDistance else retreatDistance, 0.0)
        val renderedMain = rectAt(layout.trayFrame.midX, layout.trayFrame.midY, traySize.width, traySize.height)
        val renderedPalette = paletteChord?.let { rectAt(layout.paletteFrame.midX, layout.paletteFrame.midY, paletteSize.width, paletteSize.height) }
        val groups = input.functionGroups
        val groupSizes = groups.map { functionGroupSize(it.size, portrait) }
        val functionFrames = ControlTrayGeometry.functionTrayLayout(
            container = input.container, safeInsets = input.safe, keyboardVisibleRect = env.keyboardVisibleRect,
            portrait = portrait, mainSide = layout.side, position = prefs.functionTrayPosition,
            mainTrayFrame = renderedMain, groupSizes = groupSizes, avoiding = renderedPalette,
            avoidNotch = prefs.avoidNotch, notchSide = env.notchSide, reservedRegions = env.reservedRegions,
        )
        val horizontal = layout.axis == ControlTrayAxis.Horizontal
        val frames = LinkedHashMap<String, CGRect>()
        val chips = mutableListOf<ChipSpec>()

        if (collapsed) {
            val gear = rectAt(layout.trayFrame.midX, layout.trayFrame.midY, OverlayMetrics.COLLAPSED)
            frames["tray:${ControlTrayItem.Settings.raw}"] = gear
            chips += ChipSpec(
                "tray:more", gear, ChipFace.Glyph(OverlayGlyph.Gear, 18.0), ChipStyle.Phone, false,
                ControlTrayItem.Settings.title, activation = Activation.Tray(ControlTrayItem.Settings),
            )
        } else {
            val cells = rowCells(layout.trayFrame.midX, layout.trayFrame.midY, controls.size, d, horizontal)
            controls.forEachIndexed { i, item ->
                val frame = cells[i]
                val modifier = item.modifier
                val selected = modifier != null && chord.isHeld(modifier)
                val face: ChipFace = when {
                    modifier != null -> ChipFace.Label(modifier.symbol, round(21 * d / OverlayMetrics.TRAY_ITEM))
                    item == ControlTrayItem.Escape || item == ControlTrayItem.Tab ->
                        ChipFace.Label(item.displayLabel, round(13 * d / OverlayMetrics.TRAY_ITEM))
                    else -> ChipFace.Glyph(OverlayGlyphs.forSymbol(item.displayLabel), round(18 * d / OverlayMetrics.TRAY_ITEM))
                }
                val id = modifier?.let { "modifier:${it.raw}" } ?: "tray:${item.raw}"
                frames[id] = frame
                chips += ChipSpec(
                    id, frame, face, ChipStyle.Phone, selected, item.title,
                    stateText = modifier?.let { onOff(selected) }, hide = HideKind.Retreat, activation = Activation.Tray(item),
                )
            }
        }

        groups.forEachIndexed { index, group ->
            val frame = functionFrames.getOrNull(index) ?: return@forEachIndexed
            val cells = rowCells(frame.midX, frame.midY, group.size, OverlayMetrics.TRAY_ITEM, horizontal)
            group.forEachIndexed { i, item ->
                chips += ChipSpec(
                    "function:${item.id}", cells[i], faceFor(item.face, OverlayMetrics.TRAY_ITEM), ChipStyle.Phone, false,
                    item.title, hide = HideKind.Retreat, activation = Activation.Function(item), ownTap = true,
                )
            }
        }

        var keys = emptyList<PaletteKeySpec>()
        var empty: EmptyLabelSpec? = null
        if (paletteChord != null) {
            if (actions.isEmpty()) {
                empty = EmptyLabelSpec(emptyText(paletteChord), layout.paletteFrame.midX, layout.paletteFrame.midY, onMaterial = true)
            } else {
                val rows = if (portrait) (if (actions.size > 8) 2 else 1) else actions.size
                val cols = max(1, ceil(actions.size.toDouble() / rows).toInt())
                val gridW = cols * OverlayMetrics.PALETTE_KEY + (cols - 1) * OverlayMetrics.PALETTE_GAP
                val gridH = rows * OverlayMetrics.PALETTE_KEY + (rows - 1) * OverlayMetrics.PALETTE_GAP
                val x0 = layout.paletteFrame.midX - gridW / 2
                val y0 = layout.paletteFrame.midY - gridH / 2
                val pitch = OverlayMetrics.PALETTE_KEY + OverlayMetrics.PALETTE_GAP
                keys = actions.mapIndexed { i, action ->
                    val frame = CGRect(x0 + (i / rows) * pitch, y0 + (i % rows) * pitch, OverlayMetrics.PALETTE_KEY, OverlayMetrics.PALETTE_KEY)
                    frames["action:${action.id}"] = frame
                    PaletteKeySpec(action, frame, ChipStyle.Phone, action.id == chord.selectedActionID)
                }
            }
        }

        val region = buildList {
            if (!input.autoHiding) add(RegionRect("tray", layout.trayFrame))
            if (paletteChord != null) add(RegionRect("palette", layout.paletteFrame))
        }
        return Scene(
            presentation = Presentation.Phone, chips = chips, keys = keys, emptyLabel = empty,
            hud = hud(chord, actions, w / 2, max(input.safe.top + 48, layout.paletteFrame.minY - 34)),
            paletteEnterScale = 0.75f, frames = frames, region = region,
            occupied = listOf(renderedMain) + functionFrames + listOfNotNull(renderedPalette),
            interactiveItems = controls, retreat = retreat,
        )
    }

    private fun trayContentSize(collapsed: Boolean, portrait: Boolean, count: Int, item: Double): CGSize {
        val thickness = item + OverlayMetrics.TOUCH_SLACK
        if (collapsed) return CGSize(OverlayMetrics.COLLAPSED + OverlayMetrics.TOUCH_SLACK, OverlayMetrics.COLLAPSED + OverlayMetrics.TOUCH_SLACK)
        val length = count * item + max(0, count - 1) * OverlayMetrics.TRAY_GAP + OverlayMetrics.TOUCH_SLACK
        return if (portrait) CGSize(length, thickness) else CGSize(thickness, length)
    }

    private fun functionGroupSize(count: Int, portrait: Boolean): CGSize {
        val thickness = OverlayMetrics.TRAY_ITEM + OverlayMetrics.TOUCH_SLACK
        val length = count * OverlayMetrics.TRAY_ITEM + max(0, count - 1) * OverlayMetrics.TRAY_GAP + OverlayMetrics.TOUCH_SLACK
        return if (portrait) CGSize(length, thickness) else CGSize(thickness, length)
    }

    fun phonePaletteSize(actionCount: Int, portrait: Boolean): CGSize {
        val count = max(actionCount, 1)
        fun span(n: Int) = n * OverlayMetrics.PALETTE_KEY + max(0, n - 1) * OverlayMetrics.PALETTE_GAP + OverlayMetrics.TOUCH_SLACK
        if (!portrait) return CGSize(span(1), span(count))
        val rows = if (actionCount > 8) 2 else 1
        val columns = max(1, ceil(count.toDouble() / rows).toInt())
        return CGSize(span(columns), span(rows))
    }

    /** [count] circles of [d] with the phone's 4 dp gap, centered on (cx, cy), along the tray axis. */
    private fun rowCells(cx: Double, cy: Double, count: Int, d: Double, horizontal: Boolean): List<CGRect> {
        val length = count * d + max(0, count - 1) * OverlayMetrics.TRAY_GAP
        return (0 until count).map { i ->
            val along = i * (d + OverlayMetrics.TRAY_GAP)
            if (horizontal) CGRect(cx - length / 2 + along, cy - d / 2, d, d) else CGRect(cx - d / 2, cy - length / 2 + along, d, d)
        }
    }

    // endregion

    // region Keyboard accessory bar (RC keyboardBarBody)

    fun keyboardBarItems(input: SceneInput): List<KeyboardBarItem> = KeyboardBarItem.defaultItems.filter { item ->
        if (item is KeyboardBarItem.Modifier) input.allows(ControlTrayItem.Command) else true
    }

    private fun keyboardBar(input: SceneInput): Scene {
        val env = input.env
        val w = env.containerSize.width
        val items = keyboardBarItems(input)
        val keyboardTop = env.keyboardVisibleRect?.maxY ?: env.containerSize.height
        val gap = 8.0
        val padding = 6.0
        val preferred = if (env.expanded) round(PadControlMetrics.baseItem * PadControlScale.clamped(input.prefs.padControlScale)) else 38.0
        val item = ControlTrayGeometry.fittedChipDiameter(items.size, w, preferred, gap, padding * 2)
        val barWidth = items.size * item + (items.size - 1) * gap + padding * 2
        val bar = CGRect(w / 2 - barWidth / 2, keyboardTop - 8 - item - padding * 2, barWidth, item + padding * 2)
        val chord = input.chord
        val paletteChord = chord.paletteChord
        val actions = input.actions(paletteChord)
        val key = item * 0.92
        val perRow = max(1, ((w - 32 + gap) / (key + gap)).toInt())
        val rows = ceil(max(actions.size, 1).toDouble() / perRow).toInt()
        val columns = min(max(actions.size, 1), perRow)
        val paletteSize = CGSize(columns * key + (columns - 1) * gap + padding * 2, rows * key + (rows - 1) * gap + padding * 2)
        val paletteFrame = CGRect(w / 2 - paletteSize.width / 2, bar.minY - 10 - paletteSize.height, paletteSize.width, paletteSize.height)

        val frames = LinkedHashMap<String, CGRect>()
        val chips = items.mapIndexed { index, entry ->
            val frame = CGRect(bar.minX + padding + index * (item + gap), bar.minY + padding, item, item)
            when (entry) {
                is KeyboardBarItem.Modifier -> {
                    val m = entry.modifier
                    val selected = chord.isHeldOrPressed(m)
                    frames["modifier:${m.raw}"] = frame
                    ChipSpec(
                        "modifier:${m.raw}", frame, ChipFace.Label(m.symbol, frame.width * 0.46), ChipStyle.Rail, selected,
                        m.title, onOff(selected), activation = Activation.Tray(ControlTrayItem.item(m)),
                    )
                }
                KeyboardBarItem.Escape, KeyboardBarItem.Tab -> {
                    val tray = if (entry == KeyboardBarItem.Escape) ControlTrayItem.Escape else ControlTrayItem.Tab
                    frames["tray:${tray.raw}"] = frame
                    ChipSpec(
                        "tray:${tray.raw}", frame, ChipFace.Label(tray.displayLabel, frame.width * 0.3), ChipStyle.Rail, false,
                        tray.title, activation = Activation.Tray(tray),
                    )
                }
                KeyboardBarItem.DismissKeyboard -> {
                    frames["tray:${ControlTrayItem.Keyboard.raw}"] = frame
                    ChipSpec(
                        "tray:keyboard", frame, ChipFace.Glyph(OverlayGlyph.KeyboardDown, frame.width * 0.38), ChipStyle.Rail, false,
                        "Hide Keyboard", activation = Activation.DismissKeyboard,
                    )
                }
                KeyboardBarItem.ReturnKey -> {
                    frames["control:return"] = frame
                    ChipSpec(
                        "control:return", frame, ChipFace.Glyph(OverlayGlyph.Return, frame.width * 0.38), ChipStyle.Rail, false,
                        "Return", activation = Activation.ReturnKey,
                    )
                }
            }
        }
        val trayItems = items.mapNotNull { entry ->
            when (entry) {
                is KeyboardBarItem.Modifier -> ControlTrayItem.item(entry.modifier)
                KeyboardBarItem.Escape -> ControlTrayItem.Escape
                KeyboardBarItem.Tab -> ControlTrayItem.Tab
                KeyboardBarItem.DismissKeyboard -> ControlTrayItem.Keyboard
                KeyboardBarItem.ReturnKey -> null
            }
        }
        val keyStyle = if (env.expanded) ChipStyle.Floating else ChipStyle.Phone
        var keys = emptyList<PaletteKeySpec>()
        var empty: EmptyLabelSpec? = null
        var paletteTray: TraySpec? = null
        if (paletteChord != null) {
            if (actions.isEmpty()) {
                empty = EmptyLabelSpec(emptyText(paletteChord), paletteFrame.midX, paletteFrame.maxY - 18, onMaterial = false)
            } else {
                paletteTray = TraySpec(paletteFrame)
                keys = actions.mapIndexed { index, action ->
                    val frame = CGRect(
                        paletteFrame.minX + padding + (index % perRow) * (key + gap),
                        paletteFrame.minY + padding + (index / perRow) * (key + gap), key, key,
                    )
                    frames["action:${action.id}"] = frame
                    PaletteKeySpec(action, frame, keyStyle, action.id == chord.selectedActionID)
                }
            }
        }
        return Scene(
            presentation = Presentation.KeyboardBar, chips = chips, trays = listOf(TraySpec(bar)), paletteTray = paletteTray,
            keys = keys, emptyLabel = empty, hud = hud(chord, actions, w / 2, max(input.safe.top + 30, paletteFrame.minY - 26)),
            frames = frames, interactiveItems = trayItems, keyboardBar = true,
            region = buildList {
                add(RegionRect("bar", bar))
                if (paletteChord != null) add(RegionRect("palette", paletteFrame))
            },
            occupied = listOf(bar),
        )
    }

    // endregion

    // region iPad Strip / Overlay (RC edgeLayoutContent)

    private class PlacedControl(val id: String, val kind: CustomControlKind, val frame: CGRect, val cell: CGRect)

    private fun frameId(kind: CustomControlKind): String = when (kind) {
        is CustomControlKind.Tray -> kind.item.modifier?.let { "modifier:${it.raw}" } ?: "tray:${kind.item.raw}"
        CustomControlKind.MoveView -> "control:moveView"
        is CustomControlKind.Function -> "function:${kind.id}"
        is CustomControlKind.Shortcut -> "shortcut:${kind.item.id}"
    }

    private fun padHint(kind: CustomControlKind, functionItem: (String) -> ShortcutItem?): String = when (kind) {
        is CustomControlKind.Tray -> when (kind.item) {
            ControlTrayItem.Settings -> "settings"
            else -> kind.item.title.lowercase().let { if (kind.item == ControlTrayItem.Dock) "dock" else it }
        }
        is CustomControlKind.Function -> functionItem(kind.id)?.title?.lowercase() ?: kind.id
        is CustomControlKind.Shortcut -> kind.item.title.lowercase()
        CustomControlKind.MoveView -> "move view"
    }

    private fun padControlChip(
        kind: CustomControlKind, frame: CGRect, style: ChipStyle, hint: String?, hide: HideKind, input: SceneInput, ownLabel: String? = null,
    ): ChipSpec {
        val chord = input.chord
        val d = frame.width
        val selected = when (kind) {
            is CustomControlKind.Tray -> kind.item.modifier?.let(chord::isHeldOrPressed) ?: false
            CustomControlKind.MoveView -> input.moveViewActive
            else -> false
        }
        val face: ChipFace = when (kind) {
            is CustomControlKind.Tray -> {
                val item = kind.item
                when {
                    item.modifier != null -> ChipFace.Label(item.modifier!!.symbol, d * 0.46)
                    item == ControlTrayItem.Escape || item == ControlTrayItem.Tab -> ChipFace.Label(item.displayLabel, d * 0.3)
                    else -> ChipFace.Glyph(OverlayGlyphs.forSymbol(item.displayLabel), d * 0.4)
                }
            }
            CustomControlKind.MoveView -> ChipFace.Glyph(OverlayGlyph.Move, d * 0.38)
            else -> ChipFace.Label("", d)
        }
        val label = when (kind) {
            is CustomControlKind.Tray -> kind.item.title
            CustomControlKind.MoveView -> "Move View"
            else -> ownLabel ?: ""
        }
        val stateful = (kind as? CustomControlKind.Tray)?.item?.modifier != null || kind == CustomControlKind.MoveView
        val activation = when (kind) {
            is CustomControlKind.Tray -> Activation.Tray(kind.item)
            else -> Activation.MoveView
        }
        return ChipSpec(
            frameId(kind), frame, face, style, selected, label, if (stateful) onOff(selected) else null, hint, hide, activation,
        )
    }

    private fun functionChip(item: ShortcutItem, frame: CGRect, style: ChipStyle, hint: String?, hide: HideKind) = ChipSpec(
        "function:${item.id}", frame, faceFor(item.face, frame.width), style, false, item.title, null, hint, hide,
        Activation.Function(item), ownTap = true,
    )

    private fun edge(input: SceneInput, mode: PadControlLayoutMode): Scene {
        val env = input.env
        val prefs = input.prefs
        val container = input.container
        val strip = mode == PadControlLayoutMode.Strip
        val hints = strip && prefs.padShowControlHints
        val metrics = PadControlMetrics(prefs.padControlScale, showsHints = hints)
        val collapsed = input.collapsed
        val modifiers = input.profile.visibleTrayItems.mapNotNull { it.modifier }.filter { input.allows(ControlTrayItem.Command) }
        val mainGroups = if (collapsed) emptyList() else PadRailComposition.mainGroups(
            prefs.padStandardControls,
            PadRailComposition.Availability(modifiers, input.allows(ControlTrayItem.Keyboard), input.padShowsMoveView),
        )
        val mainKinds = mainGroups.flatten()
        val groups = input.functionGroups
        val mainEdge = prefs.padMainEdge
        val functionEdge = prefs.padFunctionEdge
        val layout: PadEdgeLayout = PadEdgeGeometry.layout(
            container = container, safeInsets = input.safe, reservesStrips = strip, mainEdge = mainEdge, functionEdge = functionEdge,
            mainGroupCounts = mainGroups.map { it.size }, mainGroupAlignments = PadRailComposition.alignments(mainGroups),
            functionGroupCounts = groups.map { it.size }, metrics = metrics, keyboardTop = null,
        )
        val gearFrame: CGRect? = if (collapsed) PadEdgeGeometry.layout(
            container = container, safeInsets = input.safe, reservesStrips = false, mainEdge = mainEdge, functionEdge = functionEdge,
            mainGroupCounts = listOf(1), mainGroupAlignments = listOf(PadGroupAlignment.End), functionGroupCounts = emptyList(),
            metrics = PadControlMetrics(prefs.padControlScale),
        ).mainFrame else null
        val functionItems = input.functionProfile.allItems
        val functionItem: (String) -> ShortcutItem? = { id -> functionItems.firstOrNull { it.id == id } }
        val mainControls = mainKinds.zip(layout.mainCells).map { (kind, cell) ->
            PlacedControl(frameId(kind), kind, PadEdgeGeometry.circleFrame(cell, metrics), cell)
        }
        val functionControls = groups.flatten().zip(layout.functionCells).map { (item, cell) -> item to PadEdgeGeometry.circleFrame(cell, metrics) }
        val autoHiding = input.autoHiding
        val hide = if (strip) HideKind.None else HideKind.Fade
        val chord = input.chord
        val paletteChord = chord.paletteChord
        val actions = input.actions(paletteChord)
        val s = metrics.scale
        val keySize = if (hints) CGSize(132 * s, 36 * s) else CGSize(metrics.item * 0.92, metrics.item * 0.92)
        val paletteBounds = layout.canvas.insetBy(PadControlMetrics.edgeMargin, PadControlMetrics.edgeMargin)
        val wheelStyle = prefs.padOverlayPaletteStyle == PadPaletteStyle.Wheel && actions.isNotEmpty()
        val wheel: WheelPaletteLayout? = if (wheelStyle) {
            val modifier = chord.paletteAnchor?.takeIf { chord.activeChord.contains(it) }
                ?: ControlModifier.entries.firstOrNull { chord.activeChord.contains(it) }
            val anchor = mainControls.firstOrNull { modifier != null && it.kind.modifier == modifier }?.frame
                ?: mainControls.firstOrNull { it.kind.modifier != null }?.frame ?: gearFrame
            anchor?.let { WheelPaletteGeometry.layout(actions.size, it, metrics.item * 0.92, metrics.gap, paletteBounds) }
        } else null
        val grid = PadEdgeGeometry.paletteGrid(actions.size, keySize, metrics.gap, mainEdge, paletteBounds.size)
        val paletteAnchor = PadEdgeGeometry.paletteAnchor(layout, mainEdge, functionEdge)
        val paletteFrame: CGRect? = if (paletteChord == null) null else (paletteAnchor ?: gearFrame)?.let {
            PadEdgeGeometry.paletteFrame(
                if (actions.isEmpty()) CGSize(220.0, 36.0) else grid.size, it, mainEdge, paletteBounds, metrics.gap * 2,
            )
        }
        val frames = LinkedHashMap<String, CGRect>()
        val keys = if (wheel != null || paletteFrame == null) emptyList() else actions.mapIndexed { index, action ->
            // Column-major along a vertical edge, row-major along a horizontal one, so keys read outward from the rail.
            val row = if (mainEdge.stacksVertically) index % grid.rows else index / grid.columns
            val column = if (mainEdge.stacksVertically) index / grid.rows else index % grid.columns
            val frame = CGRect(paletteFrame.minX + column * (keySize.width + metrics.gap), paletteFrame.minY + row * (keySize.height + metrics.gap), keySize.width, keySize.height)
            frames["action:${action.id}"] = frame
            PaletteKeySpec(action, frame, ChipStyle.Floating, action.id == chord.selectedActionID, pill = hints)
        }
        val trays = if (strip) emptyList() else (layout.mainSegments + layout.functionSegments).map {
            TraySpec(PadEdgeGeometry.circleRun(it, metrics).insetBy(-OverlayMetrics.TRAY_PADDING, -OverlayMetrics.TRAY_PADDING), hideable = true)
        }
        val chips = mutableListOf<ChipSpec>()
        if (gearFrame != null) {
            frames["tray:more"] = gearFrame
            chips += padControlChip(CustomControlKind.Tray(ControlTrayItem.Settings), gearFrame, ChipStyle.Floating, null, HideKind.None, input)
        }
        for (control in mainControls) {
            frames[control.id] = control.frame
            val hint = if (hints) padHint(control.kind, functionItem) else null
            val kind = control.kind
            if (kind is CustomControlKind.Function) {
                val item = functionItem(kind.id) ?: continue
                chips += functionChip(item, control.frame, ChipStyle.Rail, hint, hide)
            } else {
                chips += padControlChip(kind, control.frame, ChipStyle.Rail, hint, hide, input)
            }
        }
        for ((item, frame) in functionControls) {
            chips += functionChip(item, frame, ChipStyle.Rail, if (hints) item.title.lowercase() else null, hide)
        }
        val occupied = layout.mainSegments.map { it.frame } + layout.functionSegments.map { it.frame } + listOfNotNull(gearFrame, paletteFrame)
        val region = buildList {
            if (!autoHiding) mainControls.filter { !it.kind.isOneTapAction }.forEach { add(RegionRect("chip:${it.id}", inset(it.frame, 4.0))) }
            gearFrame?.let { add(RegionRect("gear", inset(it, 4.0))) }
            if (wheel != null) add(RegionRect("wheel", inset(wheel.frame, 8.0)))
            else if (paletteFrame != null) add(RegionRect("palette", paletteFrame))
        }
        val wheelSpec = wheel?.let { WheelSpec(it, actions, chord.selectedActionID, chord.paletteChord?.symbols ?: "") }
        val hudAnchor = wheel?.frame ?: paletteFrame
        return Scene(
            presentation = if (strip) Presentation.Strip else Presentation.Overlay,
            chips = chips, strips = layout.strips, trays = trays,
            paletteTray = if (paletteFrame != null && wheel == null && actions.isNotEmpty()) {
                TraySpec(paletteFrame.insetBy(-OverlayMetrics.TRAY_PADDING, -OverlayMetrics.TRAY_PADDING))
            } else null,
            keys = keys, wheel = wheelSpec,
            emptyLabel = if (paletteChord != null && wheel == null && actions.isEmpty() && paletteFrame != null) {
                EmptyLabelSpec(emptyText(paletteChord), paletteFrame.midX, paletteFrame.midY, onMaterial = false)
            } else null,
            hud = hudAnchor?.let { hud(chord, actions, it.midX, max(input.safe.top + 30, it.minY - 28)) },
            paletteEnterScale = if (wheel != null) 0.85f else 0.8f,
            frames = frames, region = region, occupied = occupied, canvas = if (strip) layout.canvas else null,
            interactiveItems = input.padInteractiveItems, showsMoveBanner = input.moveViewActive,
            bannerCenterY = input.safe.top + 34,
            wheelHit = wheelSpec?.let { WheelHit(it.layout, it.actions.map { a -> a.id }) },
        )
    }

    // endregion

    // region iPad Custom (RC customLayoutContent)

    /** Settings is permanent chrome, so a layout without it still gets one in its corner. */
    fun arrangementWithSettings(arrangement: CustomControlArrangement): CustomControlArrangement {
        if (arrangement.placements.any { it.kind == CustomControlKind.Tray(ControlTrayItem.Settings) }) return arrangement
        val corner = arrangement.corner.unitPoint
        return arrangement.copy(
            placements = arrangement.placements + CustomControlPlacement(
                id = "settings", kind = CustomControlKind.Tray(ControlTrayItem.Settings), x = corner.x, y = corner.y, size = 0.9,
            ),
        )
    }

    private fun custom(input: SceneInput, layout: CustomControlLayout): Scene {
        val env = input.env
        val prefs = input.prefs
        val portrait = input.portrait
        val arrangement = arrangementWithSettings(layout.arrangement(portrait))
        val metrics = PadControlMetrics(prefs.padControlScale)
        val area = CustomLayoutGeometry.layoutArea(input.container, input.safe)
        val allFrames = CustomLayoutGeometry.frames(arrangement, area, metrics.item)
        val functionItems = prefs.functionTrayProfile(layout.functionProfile ?: prefs.activeFunctionTrayProfile).allItems
        val itemById: (String) -> ShortcutItem? = { id -> functionItems.firstOrNull { it.id == id } }
        val allowed = input.padInteractiveItems.toSet()
        val collapsed = input.collapsed
        val placed = arrangement.placements.filter { p ->
            when (val kind = p.kind) {
                is CustomControlKind.Tray -> kind.item in allowed
                is CustomControlKind.Function -> prefs.functionTrayCanBeShown && !collapsed
                is CustomControlKind.Shortcut -> prefs.trayCanBeShown && !collapsed
                CustomControlKind.MoveView -> input.padShowsMoveView
            }
        }.mapNotNull { p -> allFrames[p.id]?.let { PlacedControl(p.id, p.kind, it, it) } }
        val autoHiding = input.autoHiding
        val chord = input.chord
        val paletteChord = chord.paletteChord
        val actions = input.actions(paletteChord)
        val keyDiameter = CustomLayoutGeometry.paletteKeyDiameter(metrics.item)
        val anchorModifier = chord.paletteAnchor?.takeIf { arrangement.placement(it) != null }
            ?: ControlModifier.entries.firstOrNull { chord.activeChord.contains(it) && arrangement.placement(it) != null }
        val anchorControl = anchorModifier?.let { m -> placed.firstOrNull { it.kind.modifier == m } }
        val anchorStyle = anchorControl?.let { c -> arrangement.placements.firstOrNull { it.id == c.id }?.palette }
        val wheel: WheelPaletteLayout? =
            if (anchorStyle?.shape == PaletteShape.Wheel && paletteChord != null && actions.isNotEmpty()) {
                anchorControl?.let { WheelPaletteGeometry.layout(actions.size, it.frame, keyDiameter, metrics.gap, area) }
            } else null
        val frames = LinkedHashMap<String, CGRect>()
        val keys: List<PaletteKeySpec> = if (paletteChord == null || wheel != null || anchorControl == null) emptyList() else {
            val points = CustomLayoutGeometry.palettePoints(actions.size, anchorControl.id, arrangement, allFrames, area, metrics.item, metrics.gap)
            actions.zip(points).map { (action, point) ->
                val frame = CGRect(point.x - keyDiameter / 2, point.y - keyDiameter / 2, keyDiameter, keyDiameter)
                frames["action:${action.id}"] = frame
                PaletteKeySpec(action, frame, ChipStyle.Floating, action.id == chord.selectedActionID)
            }
        }
        val assistState = TwoHandAssist.state(layout.twoHandAssist && !collapsed && prefs.allowInput, input.interaction)
        val assistIdle = layout.assistActionIDs.mapNotNull(itemById)
        val assistCount = when (assistState) {
            TwoHandAssistState.Hidden -> 0
            TwoHandAssistState.Idle -> if (prefs.functionTrayCanBeShown) assistIdle.size else 0
            is TwoHandAssistState.Helper -> TwoHandAssist.helperModifiers.size
        }
        val assistFrames = TwoHandAssist.helperPoints(assistCount, arrangement, allFrames, area, metrics.item, metrics.gap).map {
            CGRect(it.x - metrics.item / 2, it.y - metrics.item / 2, metrics.item, metrics.item)
        }
        val settingsKind = CustomControlKind.Tray(ControlTrayItem.Settings)
        val chips = mutableListOf<ChipSpec>()
        for (control in placed) {
            val hide = if (control.kind == settingsKind) HideKind.None else HideKind.Fade
            when (val kind = control.kind) {
                is CustomControlKind.Function -> itemById(kind.id)?.let { chips += functionChip(it, control.frame, ChipStyle.Floating, null, hide) }
                is CustomControlKind.Shortcut -> chips += functionChip(kind.item, control.frame, ChipStyle.Floating, null, hide)
                is CustomControlKind.Tray, CustomControlKind.MoveView -> {
                    frames[frameId(kind)] = control.frame
                    chips += padControlChip(kind, control.frame, ChipStyle.Floating, null, hide, input)
                }
            }
        }
        when (assistState) {
            TwoHandAssistState.Hidden -> Unit
            TwoHandAssistState.Idle -> assistIdle.zip(assistFrames).forEach { (item, frame) ->
                chips += functionChip(item, frame, ChipStyle.Floating, null, HideKind.Fade).copy(key = "assist:${item.id}")
            }
            is TwoHandAssistState.Helper -> TwoHandAssist.helperModifiers.zip(assistFrames).forEach { (m, frame) ->
                val selected = m in assistState.active
                chips += ChipSpec(
                    "assist:${m.raw}", frame, ChipFace.Label(m.symbol, frame.width * 0.46), ChipStyle.Floating, selected, m.title,
                    onOff(selected), hide = HideKind.Fade, activation = Activation.AssistModifier(m), ownTap = true,
                )
            }
        }
        val region = buildList {
            placed.filter { !it.kind.isOneTapAction && (!autoHiding || it.kind == settingsKind) }
                .forEach { add(RegionRect("chip:${it.id}", inset(it.frame, 4.0))) }
            keys.forEach { add(RegionRect("key:${it.action.id}", inset(it.frame, 3.0))) }
            wheel?.let { add(RegionRect("wheel", inset(it.frame, 8.0))) }
        }
        val wheelSpec = wheel?.let { WheelSpec(it, actions, chord.selectedActionID, paletteChord?.symbols ?: "") }
        return Scene(
            presentation = Presentation.Custom, chips = chips, keys = keys, wheel = wheelSpec,
            emptyLabel = if (paletteChord != null && wheel == null && keys.isEmpty() && anchorControl != null) {
                EmptyLabelSpec(emptyText(paletteChord), anchorControl.frame.midX, anchorControl.frame.minY - metrics.item * 0.9, onMaterial = false)
            } else null,
            hud = hud(chord, actions, env.containerSize.width / 2, input.safe.top + 44),
            paletteEnterScale = if (wheel != null) 0.85f else 0.6f,
            frames = frames, region = region,
            occupied = placed.map { it.frame } + keys.map { it.frame } + assistFrames + listOfNotNull(wheel?.frame),
            interactiveItems = input.padInteractiveItems, showsMoveBanner = input.moveViewActive,
            bannerCenterY = input.safe.top + 34,
            wheelHit = wheelSpec?.let { WheelHit(it.layout, it.actions.map { a -> a.id }) },
        )
    }

    // endregion
}
