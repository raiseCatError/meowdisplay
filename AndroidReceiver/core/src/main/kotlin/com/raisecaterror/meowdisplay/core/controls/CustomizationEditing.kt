package com.raisecaterror.meowdisplay.core.controls

/**
 * Pure editing rules shared by the Android customization editors (Custom
 * Layout, Function Tray, chord palettes): the same rules as iOS
 * `CustomLayoutEditor` / `ShortcutButtonEditor`, kept here so they are tested
 * once and the Compose screens only draw them.
 */

/** iOS `ReceiverGesture.title`. */
val ReceiverGesture.title: String
    get() = when (this) {
        ReceiverGesture.MissionControl -> "Mission Control"
        ReceiverGesture.AppExpose -> "App Exposé"
        ReceiverGesture.NextSpace -> "Next Space"
        ReceiverGesture.PreviousSpace -> "Previous Space"
        ReceiverGesture.ShowDesktop -> "Show Desktop"
        ReceiverGesture.Launchpad -> "Launchpad"
        ReceiverGesture.Spotlight -> "Spotlight"
        ReceiverGesture.ControlCenter -> "Control Center"
        ReceiverGesture.MenuBar -> "Menu Bar"
    }

object ReceiverGestureActions {
    /** iOS `ReceiverGesture.oneTapActions`: the semantic actions a button may send. */
    val oneTap: List<ReceiverGesture> = listOf(
        ReceiverGesture.MenuBar, ReceiverGesture.ShowDesktop, ReceiverGesture.ControlCenter, ReceiverGesture.MissionControl,
        ReceiverGesture.AppExpose, ReceiverGesture.Launchpad, ReceiverGesture.Spotlight, ReceiverGesture.NextSpace, ReceiverGesture.PreviousSpace,
    )
}

/** What the shortcut editor builds: iOS `ShortcutButtonEditor.item`. */
object ShortcutDraft {
    /** A one-tap chord: the name defaults to the keys it sends, and the face shows them. */
    fun keyboard(id: String, title: String, modifiers: Set<ControlModifier>, keys: List<Int>, display: ShortcutButtonDisplay?): ShortcutItem {
        val usages = keys.ifEmpty { listOf(DEFAULT_KEY) }
        val shortcut = KeyboardShortcut(usages.first(), ModifierChord(modifiers), usages.drop(1))
        val base = ShortcutItem(id, "", "", ControlAction.KeyboardShortcutAction(shortcut), null, display)
        val described = base.keysDescription
        return base.copy(title = title.trim().ifEmpty { described }, displayKey = described)
    }

    /** A semantic Mac action (Mission Control, Menu Bar…) sent as the existing `gesture` message. */
    fun gesture(id: String, title: String, gesture: ReceiverGesture, display: ShortcutButtonDisplay?): ShortcutItem =
        ShortcutItem(id, title.trim().ifEmpty { gesture.title }, gesture, "sparkles").copy(display = display)

    /** The editor's starting keys for [item]: its chord, or C with the palette's own modifiers for a new one. */
    fun initialChord(item: ShortcutItem?, defaultModifiers: Set<ControlModifier>): Pair<Set<ControlModifier>, List<Int>> {
        val shortcut = (item?.action as? ControlAction.KeyboardShortcutAction)?.shortcut
            ?: return defaultModifiers to listOf(if (defaultModifiers.isEmpty()) DEFAULT_KEY else 6)
        return shortcut.modifiers.modifiers to shortcut.usages
    }

    /** U, as iOS starts an empty chord. */
    const val DEFAULT_KEY = 24
}

/** The Custom Layout editor's operations on one orientation's arrangement. */
object CustomLayoutEditing {
    /** Settings is permanent chrome: always reachable, never removed. */
    fun isRemovable(kind: CustomControlKind): Boolean = kind != CustomControlKind.Tray(ControlTrayItem.Settings)

    /** Every kind but a user shortcut appears at most once per orientation. */
    fun canAdd(arrangement: CustomControlArrangement, kind: CustomControlKind): Boolean =
        kind is CustomControlKind.Shortcut || arrangement.placements.none { it.kind == kind }

    /** Adds [kind] at the center (iOS `add`), returning the arrangement and the new placement's id. */
    fun add(arrangement: CustomControlArrangement, kind: CustomControlKind, id: String = newUUIDString()): Pair<CustomControlArrangement, String>? {
        if (!canAdd(arrangement, kind)) return null
        val placement = CustomControlPlacement(id = id, kind = kind, x = 0.5, y = 0.5)
        return arrangement.copy(placements = arrangement.placements + placement) to placement.id
    }

    fun remove(arrangement: CustomControlArrangement, id: String): CustomControlArrangement =
        arrangement.copy(placements = arrangement.placements.filterNot { it.id == id && isRemovable(it.kind) })

    fun move(arrangement: CustomControlArrangement, id: String, position: NormalizedPosition): CustomControlArrangement =
        update(arrangement, id) { it.copy(x = position.x, y = position.y) }

    fun resize(arrangement: CustomControlArrangement, id: String, size: Double): CustomControlArrangement =
        update(arrangement, id) { it.copy(size = size) }

    /** Palette style for a modifier placement; spacing is clamped, a null direction means Toward Screen Center. */
    fun restyle(arrangement: CustomControlArrangement, id: String, change: (PalettePresentation) -> PalettePresentation): CustomControlArrangement =
        update(arrangement, id) { placement ->
            if (placement.kind.modifier == null) return@update placement
            val style = change(placement.palette ?: PalettePresentation())
            val spacing = style.spacing.coerceIn(PalettePresentation.spacingRange)
            val direction = style.directionDegrees?.let { if (it.isFinite()) it.coerceIn(-180.0, 180.0) else null }
            placement.copy(palette = style.copy(spacing = spacing, directionDegrees = direction))
        }

    /** A user shortcut placement: replaces the one with [id], or adds it at the center when [id] is null. */
    fun setShortcut(arrangement: CustomControlArrangement, id: String?, item: ShortcutItem): Pair<CustomControlArrangement, String>? {
        if (!item.action.isValid || item.action !is ControlAction.KeyboardShortcutAction) return null
        if (id == null) return add(arrangement, CustomControlKind.Shortcut(item))
        if (arrangement.placements.none { it.id == id && it.kind is CustomControlKind.Shortcut }) return null
        return update(arrangement, id) { it.copy(kind = CustomControlKind.Shortcut(item)) } to id
    }

    /** Use Template: this orientation only goes back to the radial starter around its corner. */
    fun useTemplate(layout: CustomControlLayout, portrait: Boolean): CustomControlLayout =
        layout.setArrangement(CustomControlArrangement.radialTemplate(layout.arrangement(portrait).corner, portrait), portrait)

    /** Function controls come from the layout's chosen profile, or the active one. */
    fun functionItems(preferences: ReceiverControlPreferences, layout: CustomControlLayout?): List<ShortcutItem> =
        preferences.functionTrayProfile(layout?.functionProfile ?: preferences.activeFunctionTrayProfile).allItems

    /** Re-normalizes through the public constructor's clamps, as iOS `updatePlacement` does. */
    private fun update(arrangement: CustomControlArrangement, id: String, change: (CustomControlPlacement) -> CustomControlPlacement): CustomControlArrangement =
        arrangement.copy(placements = arrangement.placements.map { placement ->
            if (placement.id != id) return@map placement
            val p = change(placement)
            CustomControlPlacement(id = p.id, kind = p.kind, x = p.x, y = p.y, size = p.size, palette = p.palette)
        })
}
