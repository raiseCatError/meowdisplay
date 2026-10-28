package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/SecondQARefinementTests.swift.
//
// Left out (types outside this port):
//  - testSystemActionsMapToDocumentedMacShortcuts: SystemGestureShortcutMapping (Mac target, Mac/InputRouting.swift).
// `ManualViewportState.normalizedAngle` (viewport port) is the package-internal `normalizedAngle` from CustomControlLayout.kt here.

import com.raisecaterror.meowdisplay.core.session.InputWireState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.zip.Inflater
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Second physical-QA pass: system actions, rail anchoring, software-keyboard
 * chords, the editable Function Tray and its sequences, scroll direction, Wheel
 * and fan geometry, editor/import flows, and Request Input.
 */
class SecondQARefinementTests {
    private val container = CGRect(0.0, 0.0, 1194.0, 834.0)
    private val safe = ControlSafeInsets(top = 24.0, leading = 0.0, bottom = 20.0, trailing = 0.0)
    private val metrics = PadControlMetrics()

    private class MapStore : PreferenceBlobStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    // region System actions

    @Test
    fun testStandardSystemGroupIsMenuBarDockDesktopControlCenter() {
        val items = FunctionTrayProfile.canonical().items
        val menuBar = items.first { it.id == "menu-bar" }
        assertEquals(ControlAction.ReceiverGestureAction(ReceiverGesture.MenuBar.raw), menuBar.item.action)
        assertFalse("opt-in in the Function Tray itself", menuBar.isVisible)
        val groups = PadRailComposition.mainGroups(
            PadStandardControlVisibility(),
            PadRailComposition.Availability(modifiers = ControlModifier.entries, keyboardAvailable = true, moveViewAvailable = true),
        )
        assertEquals(
            listOf(
                CustomControlKind.Function("menu-bar"), CustomControlKind.Tray(ControlTrayItem.Dock),
                CustomControlKind.Function("show-desktop"), CustomControlKind.Function("control-center"),
            ),
            groups.first(),
        )
        assertEquals(listOf(PadGroupAlignment.Start, PadGroupAlignment.Center, PadGroupAlignment.End), PadRailComposition.alignments(groups))
        // Dock stays the existing ⌥⌘D tray action.
        assertEquals(CustomControlKind.Tray(ControlTrayItem.Dock), PadStandardControl.Dock.kind)
    }

    // endregion

    // region Rail anchoring

    private fun railLayout(
        main: ControlEdge = ControlEdge.Trailing, function: ControlEdge = ControlEdge.Trailing,
        functionGroups: List<Int> = listOf(2, 2), strip: Boolean = false,
        metrics: PadControlMetrics? = null, keyboardTop: Double? = null, size: CGRect? = null,
    ): PadEdgeLayout = PadEdgeGeometry.layout(
        container = size ?: container, safeInsets = safe, reservesStrips = strip,
        mainEdge = main, functionEdge = function, mainGroupCounts = listOf(4, 7, 2),
        mainGroupAlignments = listOf(PadGroupAlignment.Start, PadGroupAlignment.Center, PadGroupAlignment.End),
        functionGroupCounts = functionGroups, metrics = metrics ?: this.metrics, keyboardTop = keyboardTop,
    )

    @Test
    fun testSystemGroupStartsAtTheTopAndSettingsSitsAtTheBottom() {
        val layout = railLayout(functionGroups = emptyList())
        val railTop = 24 + PadControlMetrics.edgeMargin
        val railBottom = 834 - 20 - PadControlMetrics.edgeMargin
        assertEquals(railTop, layout.mainSegments.first().frame.minY, 0.01)
        assertEquals(railBottom, layout.mainSegments.last().frame.maxY, 0.01)
        assertTrue("top-right", layout.mainSegments.first().frame.midX > container.midX)
    }

    @Test
    fun testSharedEdgeFunctionGroupsSitBetweenTheAnchoredGroups() {
        val layout = railLayout(size = CGRect(0.0, 0.0, 834.0, 1194.0))
        assertEquals(1, layout.laneCounts[ControlEdge.Trailing])
        val system = layout.mainSegments[0].frame
        val settings = layout.mainSegments[2].frame
        for (segment in layout.functionSegments) {
            assertTrue(segment.frame.minY > system.maxY)
            assertTrue(segment.frame.maxY < settings.minY)
        }
    }

    @Test
    fun testAnchoredRailsNeverOverlapAnywhere() {
        for (size in listOf(container, CGRect(0.0, 0.0, 834.0, 1194.0))) {
            for (strip in listOf(true, false)) {
                for (scale in listOf(0.85, 1.4)) {
                    for (main in ControlEdge.entries) {
                        for (function in ControlEdge.entries) {
                            val metrics = PadControlMetrics(scale = scale)
                            val layout = railLayout(main, function, functionGroups = listOf(2, 2, 3), strip = strip, metrics = metrics, size = size)
                            val cells = layout.mainCells + layout.functionCells
                            assertEquals(20, cells.size)
                            for (i in cells.indices) {
                                for (j in cells.indices) {
                                    if (j <= i) continue
                                    assertFalse(
                                        "${size.size} strip=$strip $scale $main/$function",
                                        cells[i].insetBy(-metrics.gap / 2 + 0.01, -metrics.gap / 2 + 0.01)
                                            .intersects(cells[j].insetBy(-metrics.gap / 2 + 0.01, -metrics.gap / 2 + 0.01)),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    fun testSettingsStaysReachableAboveTheKeyboard() {
        val layout = railLayout(functionGroups = emptyList(), keyboardTop = 480.0)
        val settings = layout.mainSegments.last().frame
        val system = layout.mainSegments.first().frame
        assertEquals(480 - PadControlMetrics.edgeMargin, settings.maxY, 0.01)
        assertEquals(24 + PadControlMetrics.edgeMargin, system.minY, 0.01)
        assertEquals("both stay on the outer lane", system.midX, settings.midX, 0.01)
        val cells = layout.mainCells
        for (i in cells.indices) {
            for (j in cells.indices) {
                if (j <= i) continue
                assertFalse(cells[i].intersects(cells[j]))
            }
            assertTrue(cells[i].maxY <= 480)
        }
    }

    // endregion

    // region Modifier buttons + software keyboard

    @Test
    fun testTypedKeysCombineWithTheActiveChord() {
        val command = setOf(ControlModifier.Command)
        val copy = SoftwareKeyboardChordPolicy.press("c", command)!!
        assertEquals(6, copy.first)
        assertEquals(listOf("command"), copy.second)
        val selectAll = SoftwareKeyboardChordPolicy.press("a", command)!!
        assertEquals(4, selectAll.first)
        val palette = SoftwareKeyboardChordPolicy.press("P", command)!!
        assertEquals(19, palette.first)
        assertEquals("an uppercase letter adds Shift", listOf("command", "shift"), palette.second)
        assertEquals(32, SoftwareKeyboardChordPolicy.press("3", setOf(ControlModifier.Command, ControlModifier.Shift))?.first)
        assertNull("no chord: ordinary text", SoftwareKeyboardChordPolicy.press("c", emptySet()))
        assertNull(SoftwareKeyboardChordPolicy.press("cc", command))
        assertEquals(listOf("command", "shift"), SoftwareKeyboardChordPolicy.modifiers(listOf("shift"), command))
    }

    // endregion

    // region Function Tray editing

    private fun customItem(id: String = "u") =
        ShortcutItem(id = id, title = "Underline", displayKey = "U", usage = 24, modifiers = ModifierChord(setOf(ControlModifier.Control)))

    @Test
    fun testFunctionTrayAddRemoveReorder() {
        val profile = FunctionTrayProfile.canonical()
        val count = profile.items.size
        assertTrue(profile.addCustomItem(customItem()))
        assertEquals(count + 1, profile.items.size)
        assertTrue(profile.visibleItems.any { it.id == "u" })
        assertFalse("ids stay unique", profile.addCustomItem(customItem()))
        profile.moveItems(setOf(profile.items.size - 1), 0)
        assertEquals("u", profile.items.firstOrNull()?.id)
        profile.removeItem("u")
        assertFalse("custom actions are deleted", profile.items.any { it.id == "u" })
        profile.removeItem("undo")
        assertEquals("built-ins are hidden", false, profile.items.firstOrNull { it.id == "undo" }?.isVisible)
        assertEquals(false, profile.resolvingCanonicalMetadata().items.firstOrNull { it.id == "undo" }?.isVisible)
        val invalid = customItem("bad").copy(action = ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage = 999, modifiers = ModifierChord())))
        assertFalse(profile.addCustomItem(invalid))
    }

    @Test
    fun testRenamesAndFacesPersistAndSurviveCanonicalRefresh() {
        val profile = FunctionTrayProfile.canonical()
        profile.rename("undo", "Back")
        profile.setDisplay("undo", ShortcutButtonDisplay.Emoji("⏪"))
        profile.addCustomItem(customItem())
        profile.setDisplay("u", ShortcutButtonDisplay.Text("U̲"))
        profile.rename("u", "Underline It")
        val decoded = FunctionTrayProfile.fromJson(parseJson(profile.toJson().toString()))!!.resolvingCanonicalMetadata()
        val undo = decoded.allItems.first { it.id == "undo" }
        assertEquals("Back", undo.title)
        assertEquals(ShortcutButtonFace.Text("⏪"), undo.face)
        assertEquals(
            "the action is untouched by its label",
            FunctionTrayProfile.canonical().items.firstOrNull { it.id == "undo" }?.item?.action, undo.action,
        )
        val custom = decoded.allItems.first { it.id == "u" }
        assertEquals("Underline It", custom.title)
        assertEquals(ShortcutButtonFace.Text("U̲"), custom.face)
        val keys = customItem().copy(display = ShortcutButtonDisplay.Keys)
        assertEquals(ShortcutButtonFace.Text("⌃U"), keys.face)
        val symbol = customItem().copy(display = ShortcutButtonDisplay.Symbol("underline"))
        assertEquals(ShortcutButtonFace.Symbol("underline"), symbol.face)
        assertEquals("default: the key cap", ShortcutButtonFace.Text("U"), customItem().face)
    }

    // endregion

    // region Sequences

    private fun sequenceAction(): ControlAction = ControlAction.Sequence(
        listOf(
            ControlActionStep(ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage = 14, modifiers = ModifierChord(setOf(ControlModifier.Command)))), delayMs = 200),
            ControlActionStep(
                ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage = 14, modifiers = ModifierChord(), additionalUsages = listOf(32))),
                delayMs = 100,
            ),
            ControlActionStep(ControlAction.ReceiverGestureAction(ReceiverGesture.ShowDesktop.raw)),
        ),
    )

    @Test
    fun testSequencesRunInOrderWithBalancedKeys() {
        val operations = ControlActionPlan.operations(sequenceAction())
        assertEquals(
            listOf(
                ControlActionOperation.Press(usage = 14, modifiers = listOf("command")),
                ControlActionOperation.Pause(milliseconds = 200),
                ControlActionOperation.Key(KeyboardChordEvent(KeyboardChordEvent.Phase.Down, usage = 14, modifiers = emptyList())),
                ControlActionOperation.Key(KeyboardChordEvent(KeyboardChordEvent.Phase.Down, usage = 32, modifiers = emptyList())),
                ControlActionOperation.Key(KeyboardChordEvent(KeyboardChordEvent.Phase.Up, usage = 32, modifiers = emptyList())),
                ControlActionOperation.Key(KeyboardChordEvent(KeyboardChordEvent.Phase.Up, usage = 14, modifiers = emptyList())),
                ControlActionOperation.Pause(milliseconds = 100),
                ControlActionOperation.Gesture("showDesktop"),
            ),
            operations,
        )
        val held = mutableSetOf<Int>()
        for (operation in operations) {
            if (operation !is ControlActionOperation.Key) continue
            val event = operation.event
            if (event.phase == KeyboardChordEvent.Phase.Down) held.add(event.usage) else held.remove(event.usage)
        }
        assertTrue(held.isEmpty())
    }

    @Test
    fun testSequencesAreBounded() {
        val step = ControlActionStep(ControlAction.ReceiverGestureAction("spotlight"))
        assertTrue(ControlAction.Sequence(listOf(step)).isValid)
        assertFalse(ControlAction.Sequence(emptyList()).isValid)
        assertFalse(ControlAction.Sequence(List(9) { step }).isValid)
        assertFalse("no nesting", ControlAction.Sequence(listOf(ControlActionStep(ControlAction.Sequence(listOf(step))))).isValid)
        assertFalse(ControlAction.Sequence(listOf(ControlActionStep(ControlAction.ReceiverGestureAction("rm -rf")))).isValid)
        assertFalse(ControlAction.Sequence(listOf(ControlActionStep(ControlAction.ReceiverGestureAction("spotlight"), delayMs = 9_000))).isValid)
        assertEquals("invalid actions do nothing", emptyList<ControlActionOperation>(), ControlActionPlan.operations(ControlAction.Sequence(emptyList())))
    }

    @Test
    fun testSequenceItemsRoundTrip() {
        val item = customItem("macro").copy(action = sequenceAction(), display = ShortcutButtonDisplay.Emoji("🚀"))
        assertEquals(item, ShortcutItem.fromJson(parseJson(item.toJson().toString())))
        assertEquals("⌘K → K+3 → Underline", item.keysDescription)
    }

    // endregion

    // region Scroll direction

    @Test
    fun testScrollInversionIsPerAxis() {
        val natural = ScrollDirectionPolicy.apply(dx = 3.0, dy = -5.0, invertVertical = true, invertHorizontal = true)
        assertEquals(3.0, natural.first, 0.0)
        assertEquals(-5.0, natural.second, 0.0)
        val vertical = ScrollDirectionPolicy.apply(dx = 0.0, dy = -5.0, invertVertical = false, invertHorizontal = true)
        assertEquals(5.0, vertical.second, 0.0)
        val horizontal = ScrollDirectionPolicy.apply(dx = 3.0, dy = 0.0, invertVertical = true, invertHorizontal = false)
        assertEquals(-3.0, horizontal.first, 0.0)
        val diagonal = ScrollDirectionPolicy.apply(dx = 3.0, dy = -5.0, invertVertical = false, invertHorizontal = true)
        assertEquals("each axis follows only its own setting", 3.0, diagonal.first, 0.0)
        assertEquals(5.0, diagonal.second, 0.0)
        val both = ScrollDirectionPolicy.apply(dx = 3.0, dy = -5.0, invertVertical = false, invertHorizontal = false)
        assertEquals(-3.0, both.first, 0.0)
        assertEquals(5.0, both.second, 0.0)
    }

    @Test
    fun testSchema18DefaultsAndMigration() {
        val preferences = ReceiverControlPreferences()
        assertTrue(preferences.invertVerticalScroll)
        assertTrue(preferences.invertHorizontalScroll)
        assertEquals(PadPaletteStyle.Keys, preferences.padOverlayPaletteStyle)
        val store = MapStore()
        val old = ReceiverControlPreferences()
        old.version = 17
        old.padShowControlHints = true
        val json = old.toJson().toMutableMap()
        for (key in listOf("invertVerticalScroll", "invertHorizontalScroll", "padOverlayPaletteStyle")) json.remove(key)
        store.values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] = kotlinx.serialization.json.JsonObject(json).toString()
        val repository = ReceiverControlPreferencesRepository(store)
        val loaded = repository.load()
        assertEquals(18, loaded.version)
        assertTrue("a schema-17 choice survives", loaded.padShowControlHints)
        assertTrue(loaded.invertVerticalScroll)
        loaded.invertHorizontalScroll = false
        repository.save(loaded)
        assertFalse(repository.load().invertHorizontalScroll)
    }

    // endregion

    // region Custom system controls and editor

    @Test
    fun testTemplatePlacesTheSystemGroupOnTheOppositeSide() {
        for (corner in ControlCorner.entries) {
            val arrangement = CustomControlArrangement.radialTemplate(corner, portrait = false)
            val system = arrangement.placements.filter { it.kind in CustomControlArrangement.templateSystem }
            assertEquals(CustomControlArrangement.templateSystem, system.map { it.kind })
            for (placement in system) {
                assertEquals("$corner: opposite side", !corner.isLeading, placement.x < 0.5)
                assertEquals(corner.isTop, placement.y < 0.5)
            }
        }
    }

    @Test
    fun testTwoHandAssistStaysDormantWhileEditing() {
        val interaction = ControlInteractionState()
        interaction.press(ControlModifier.Command)
        interaction.toggleAssistModifier(ControlModifier.Option)
        assertEquals(
            TwoHandAssistState.Hidden,
            EditorTwoHandPresentation.state(previewing = false, showingAssistPreview = false, enabled = true, interaction = interaction),
        )
        assertEquals(
            TwoHandAssistState.Helper(setOf(ControlModifier.Command)),
            EditorTwoHandPresentation.state(previewing = false, showingAssistPreview = true, enabled = true, interaction = ControlInteractionState()),
        )
        assertEquals(
            TwoHandAssistState.Helper(setOf(ControlModifier.Command, ControlModifier.Option)),
            EditorTwoHandPresentation.state(previewing = true, showingAssistPreview = false, enabled = true, interaction = interaction),
        )
        assertEquals(
            TwoHandAssistState.Hidden,
            EditorTwoHandPresentation.state(previewing = true, showingAssistPreview = true, enabled = false, interaction = interaction),
        )
    }

    @Test
    fun testSnapToEdgesAndSnapToGuidesAreSeparate() {
        val area = CGRect(12.0, 36.0, 1170.0, 766.0)
        val nearLeft = CGPoint(area.minX + 22 + 8, area.minY + 300)
        val edge = CustomLayoutGeometry.droppedPosition(nearLeft, area, diameter = 44.0, snapToEdges = true, snapToGuides = false)
        assertEquals("flush against the edge", 22 / area.width, edge.x, 0.0001)
        val free = CustomLayoutGeometry.droppedPosition(nearLeft, area, diameter = 44.0, snapToEdges = false, snapToGuides = false)
        assertEquals(30 / area.width, free.x, 0.0001)
        val nearCenter = CGPoint(area.midX + 7, area.minY + area.height * 0.2503)
        val centered = CustomLayoutGeometry.droppedPosition(nearCenter, area, diameter = 44.0, snapToEdges = true, snapToGuides = true)
        assertEquals("center line", 0.5, centered.x, 0.0001)
        assertEquals("guide line", 0.25, centered.y, 0.0001)
    }

    // endregion

    // region Wheel

    @Test
    fun testWheelDividesARingIntoEqualWedgesAroundTheModifier() {
        val anchor = CGRect(580.0, 380.0, 44.0, 44.0)
        val wheel = WheelPaletteGeometry.layout(count = 6, anchor = anchor, keyDiameter = 40.0, spacing = 8.0, bounds = container)!!
        assertEquals(CGPoint(anchor.midX, anchor.midY), wheel.center)
        assertTrue(wheel.innerRadius >= 22 + 8)
        assertEquals(6, wheel.segments.size)
        val total = wheel.segments.map { it.endAngle - it.startAngle }.fold(0.0) { a, b -> a + b }
        assertEquals(2 * PI, total, 0.0001)
        for ((index, segment) in wheel.segments.withIndex()) {
            assertEquals(PI / 3, segment.endAngle - segment.startAngle, 0.0001)
            assertEquals(
                (wheel.innerRadius + wheel.outerRadius) / 2,
                hypot(segment.labelPoint.x - wheel.center.x, segment.labelPoint.y - wheel.center.y), 0.001,
            )
            assertEquals(index, wheel.segmentIndex(segment.labelPoint))
        }
        assertEquals("first segment on top", wheel.center.x, wheel.segments[0].labelPoint.x, 0.001)
        assertNull("the center is the anchor, not an action", wheel.segmentIndex(wheel.center))
    }

    @Test
    fun testWheelMovesInwardToStayOnScreenAndWidensForManyActions() {
        val corner = CGRect(1150.0, 790.0, 44.0, 44.0)
        val wheel = WheelPaletteGeometry.layout(count = 8, anchor = corner, keyDiameter = 40.0, spacing = 8.0, bounds = container)!!
        assertTrue(container.contains(wheel.frame))
        val crowded = WheelPaletteGeometry.layout(
            count = 16, anchor = CGRect(580.0, 380.0, 44.0, 44.0), keyDiameter = 40.0, spacing = 8.0, bounds = container,
        )!!
        val middle = (crowded.innerRadius + crowded.outerRadius) / 2
        assertTrue("more than a key's width per wedge", 2 * PI * middle / 16 >= 40 * 1.15 - 0.01)
        assertTrue("deep enough to hit", crowded.outerRadius - crowded.innerRadius >= 40 * 1.5 - 0.01)
    }

    // endregion

    // region Arc fan in every corner

    @Test
    fun testArcFansIntoFreeSpaceFromEveryCornerAndMovedAnchor() {
        val bounds = CGRect(12.0, 36.0, 1170.0, 766.0)
        val anchors = listOf(
            CGPoint(60.0, 80.0), CGPoint(1140.0, 80.0), CGPoint(60.0, 760.0),
            CGPoint(1140.0, 760.0), CGPoint(597.0, 760.0), CGPoint(60.0, 420.0),
            CGPoint(597.0, 419.0),
        )
        for (anchor in anchors) {
            val toward = RadialPaletteLayout.direction(anchor, CGPoint(bounds.midX, bounds.midY))
            val points = RadialPaletteLayout.points(
                count = 6, center = anchor, shape = PaletteShape.Arc, itemDiameter = 40.0, spacing = 8.0,
                minimumRadius = 110.0, direction = toward, bounds = bounds,
            )
            assertEquals("$anchor", 6, points.size)
            val radii = points.map { hypot(it.x - anchor.x, it.y - anchor.y) }
            for (radius in radii) assertEquals("$anchor: one arc", radii[0], radius, 0.01)
            val angles = points.map { atan2(it.y - anchor.y, it.x - anchor.x) }
            val steps = angles.zip(angles.drop(1)).map { (a, b) -> normalizedAngle(b - a) }
            for (step in steps) assertEquals("$anchor: even spacing", steps[0], step, 0.001)
            val inner = bounds.insetBy(20.0, 20.0)
            for (point in points) assertTrue("$anchor: on screen $point", inner.contains(point))
            // It opens toward the room available, not into a corner.
            val mean = CGPoint(points.map { it.x }.fold(0.0) { a, b -> a + b } / 6 - anchor.x, points.map { it.y }.fold(0.0) { a, b -> a + b } / 6 - anchor.y)
            assertTrue("$anchor", mean.x * cos(toward) + mean.y * sin(toward) > 0)
        }
    }

    @Test
    fun testCornerClusterFollowsWhereTheAnchorActuallyIs() {
        // Stored as bottom-right, but arranged top-left.
        val arrangement = CustomControlArrangement.radialTemplate(ControlCorner.TopLeading, portrait = false).copy(corner = ControlCorner.BottomTrailing)
        val area = CGRect(CGPoint.zero, CustomControlArrangement.referenceLandscape)
        val frames = CustomLayoutGeometry.frames(arrangement, area, baseDiameter = 44.0)
        assertEquals(ControlCorner.TopLeading, CornerCluster.resolve(arrangement, frames, area)?.corner)
    }

    // endregion

    // region Import

    @Test
    fun testImportFlowOnlyFinishesAfterASuccessfulImport() {
        val preferences = ReceiverControlPreferences()
        preferences.createCustomLayout(id = "a")
        val code = CustomLayoutShareCode.encode(preferences.customLayouts[0])
        val flow = CustomLayoutImportFlow()
        flow.validate()
        assertEquals(CustomLayoutImportFlow.Stage.Entering, flow.stage)
        flow.paste("garbage")
        assertEquals(CustomLayoutImportFlow.Stage.Failed(ShareCodeError.NotAShareCode), flow.stage)
        assertFalse(flow.isFinished)
        flow.paste(code)
        if (flow.stage !is CustomLayoutImportFlow.Stage.Reviewing) return fail("expected a summary")
        assertFalse("reviewing never closes the screen", flow.isFinished)
        flow.importLayout(preferences)
        assertTrue(flow.isFinished)
        assertEquals(2, preferences.customLayouts.size)
        val full = preferences.deepCopy()
        while (full.canCreateCustomLayout) full.createCustomLayout()
        val second = CustomLayoutImportFlow()
        second.paste(code)
        second.importLayout(full)
        if (second.stage !is CustomLayoutImportFlow.Stage.LimitReached) return fail("expected the limit")
        assertFalse(second.isFinished)
        second.edit("")
        assertEquals(CustomLayoutImportFlow.Stage.Entering, second.stage)
    }

    @Test
    fun testSharedLayoutsCarryTheirCustomActions() {
        var layout = CustomControlLayout.radialTemplate(name = "Macro", corner = ControlCorner.BottomTrailing)
        layout = layout.copy(
            landscape = layout.landscape.copy(
                placements = layout.landscape.placements +
                    CustomControlPlacement(id = "m", kind = CustomControlKind.Function("my-macro"), x = 0.5, y = 0.5) +
                    CustomControlPlacement(id = "z", kind = CustomControlKind.Function("zoom-in"), x = 0.4, y = 0.5),
            ),
            assistActionIDs = listOf("undo", "my-macro"),
        )
        val macro = customItem("my-macro").copy(action = sequenceAction(), display = ShortcutButtonDisplay.Emoji("🚀"))
        val unrelated = customItem("unused")
        val code = CustomLayoutShareCode.encode(layout, functionItems = listOf(macro, unrelated))
        val summary = CustomLayoutShareCode.decode(code).getOrThrow()
        val placements = summary.layout.landscape.placements
        val adopted = placements.first { it.id == "m" }
        val kind = adopted.kind as? CustomControlKind.Shortcut ?: return fail("the macro travels as a one-tap button")
        val item = kind.item
        assertEquals(macro.action, item.action)
        assertEquals(ShortcutButtonDisplay.Emoji("🚀"), item.display)
        assertNotEquals("a new local definition", "my-macro", item.id)
        assertEquals("built-ins travel by id", CustomControlKind.Function("zoom-in"), placements.firstOrNull { it.id == "z" }?.kind)
        assertEquals(listOf("undo"), summary.layout.assistActionIDs)
        assertFalse(code.isEmpty())
        // Only what the layout uses.
        val body = code.drop(5).split('.')[0]
        val base64 = body.replace('-', '+').replace('_', '/') + "=".repeat((4 - body.length % 4) % 4)
        val inflater = Inflater(true)
        inflater.setInput(java.util.Base64.getDecoder().decode(base64))
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (!inflater.finished()) out.write(buffer, 0, inflater.inflate(buffer))
        inflater.end()
        assertFalse(out.toString(Charsets.UTF_8).contains("unused"))
    }

    // endregion

    // region Request Input

    @Test
    fun testBlockedTouchOffersRequestInputThenFades() {
        val prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        assertEquals(emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 0.0, userTurnedOff = false, autoRequest = false))
        assertEquals(ReceiverInputPrompt.Kind.RequestInput, prompt.kind)
        assertTrue(prompt.isVisible(1.0))
        prompt.blockedAttempt(now = 3.0, userTurnedOff = false, autoRequest = false)
        assertTrue("another attempt refreshes the timer", prompt.isVisible(6.0))
        prompt.tick(now = 7.0)
        assertNull("it fades once attempts stop", prompt.kind)
        prompt.blockedAttempt(now = 10.0, userTurnedOff = true, autoRequest = false)
        assertEquals(ReceiverInputPrompt.Kind.EnableInput, prompt.kind)
    }

    @Test
    fun testRequestIsSentOnceAndTheGrantShowsBriefly() {
        val prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        prompt.blockedAttempt(now = 0.0, userTurnedOff = false, autoRequest = false)
        assertEquals(listOf(ReceiverInputPrompt.Effect.SendRequest), prompt.requestTapped(now = 0.5))
        assertEquals(ReceiverInputPrompt.Kind.Requesting, prompt.kind)
        assertEquals("no duplicate requests", emptyList<ReceiverInputPrompt.Effect>(), prompt.requestTapped(now = 0.7))
        prompt.inputStateChanged(InputWireState.Requesting, now = 0.8)
        assertEquals("already pending", emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 1.0, userTurnedOff = false, autoRequest = true))
        assertEquals(ReceiverInputPrompt.Kind.Requesting, prompt.kind)
        prompt.inputStateChanged(InputWireState.Allowed, now = 2.0)
        assertEquals(ReceiverInputPrompt.Kind.Enabled, prompt.kind)
        prompt.tick(now = 2 + ReceiverInputPrompt.ENABLED_DURATION + 0.01)
        assertNull(prompt.kind)
        assertEquals("input works now", emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 5.0, userTurnedOff = false, autoRequest = true))
    }

    @Test
    fun testAlwaysAllowPeersRequestAutomaticallyButRateLimited() {
        val prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        assertEquals(listOf(ReceiverInputPrompt.Effect.SendRequest), prompt.blockedAttempt(now = 0.0, userTurnedOff = false, autoRequest = true))
        prompt.inputStateChanged(InputWireState.Off, now = 0.2)
        assertEquals("rate-limited", emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 1.0, userTurnedOff = false, autoRequest = true))
        assertEquals(listOf(ReceiverInputPrompt.Effect.SendRequest), prompt.blockedAttempt(now = 10.0, userTurnedOff = false, autoRequest = true))
        prompt.inputStateChanged(InputWireState.NotAllowed, now = 11.0)
        assertEquals(
            "a declined request is never re-sent automatically",
            emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 30.0, userTurnedOff = false, autoRequest = true),
        )
        assertEquals(
            "input the user turned off stays off until they ask",
            emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 40.0, userTurnedOff = true, autoRequest = true),
        )
    }

    @Test
    fun testNoPromptWithoutALiveSessionOrWhenTheMacDisablesRequests() {
        val prompt = ReceiverInputPrompt()
        assertEquals(emptyList<ReceiverInputPrompt.Effect>(), prompt.blockedAttempt(now = 0.0, userTurnedOff = false, autoRequest = true))
        assertNull(prompt.kind)
        prompt.setSessionLive(true)
        prompt.inputStateChanged(InputWireState.RequestsDisabled, now = 0.0)
        prompt.blockedAttempt(now = 1.0, userTurnedOff = false, autoRequest = true)
        assertEquals(ReceiverInputPrompt.Kind.Unavailable, prompt.kind)
        assertEquals(emptyList<ReceiverInputPrompt.Effect>(), prompt.requestTapped(now = 2.0))
    }

    @Test
    fun testLocalViewGesturesNeverAskForInput() {
        assertFalse("two fingers are local pan/zoom/rotate", BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount = 2, moveViewActive = false))
        assertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount = 1, moveViewActive = true))
        assertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount = 1, moveViewActive = false))
        assertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount = 3, moveViewActive = false))
        assertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount = 0, moveViewActive = false))
    }

    // endregion
}
