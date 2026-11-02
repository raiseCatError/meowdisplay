package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/PadControlLayoutTests.swift.
//
// Left out (types outside this port):
//  - testMoveViewCanBeHiddenAndNeedsLocalNavigation: LocalViewNavigationPolicy (viewport port).
//  - testShowDesktopAndControlCenterAreSemanticFunctionActions: SystemGestureShortcutMapping (Mac target, Mac/InputRouting.swift).
//  - testSettingsCategoriesAreSharedByBothSizeClasses: MobileSettingsCategory (Shared/MobileSettingsCategory.swift, not ported).
//  - testIPadOnlyControlSettingsNeverShowOnIPhone: PadControlSettingsVisibility (same file).

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Receiver defaults (schema 16), iPad Strip/Overlay geometry, control scale,
 * Custom layouts, radial palettes and Two-Hand Assist: all pure policy.
 */
class PadControlLayoutTests {
    private val container = CGRect(0.0, 0.0, 1194.0, 834.0)
    private val metrics = PadControlMetrics()

    private class MapStore : PreferenceBlobStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    private fun makeRepository(): Pair<ReceiverControlPreferencesRepository, MapStore> {
        val store = MapStore()
        return ReceiverControlPreferencesRepository(store) to store
    }

    private fun MapStore.put(json: Map<String, JsonElement>) {
        values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] = JsonObject(json).toString()
    }

    // region Defaults and migration

    @Test
    fun testNewInstallDefaults() {
        val preferences = ReceiverControlPreferences()
        assertTrue(preferences.smartTouchEnabled)
        assertTrue(preferences.autoHideEnabled)
        assertEquals(ReceiverGestureTarget.Viewport, preferences.pinchTarget)
        assertEquals(ReceiverGestureTarget.Disabled, preferences.rotateTarget)
        assertTrue(preferences.preferMeowDisplayGestures)
        assertEquals(PadControlLayoutMode.Strip, preferences.padControlLayout)
        assertFalse("hints default off (schema 17)", preferences.padShowControlHints)
        assertTrue(preferences.allowLocalViewNavigation)
        assertEquals(PadStandardControlVisibility(), preferences.padStandardControls)
        assertTrue(PadStandardControl.entries.all(preferences.padStandardControls::isVisible))
        assertEquals(1.0, preferences.padControlScale, 0.0)
        assertTrue("no empty Custom layouts are pre-created", preferences.customLayouts.isEmpty())
        assertFalse("audio stays opt-in", preferences.audioPreferred)
        assertTrue(preferences.allowInput)
    }

    @Test
    fun testSchema15InstallMigratesOnceToTheNewDefaults() {
        val (repository, store) = makeRepository()
        val old = ReceiverControlPreferences()
        old.version = 15
        old.smartTouchEnabled = false
        old.autoHideEnabled = false
        old.pinchTarget = ReceiverGestureTarget.App
        old.rotateTarget = ReceiverGestureTarget.Viewport
        old.inputMode = PointerInputMode.Trackpad
        old.hapticsEnabled = false
        val json = old.toJson().toMutableMap()
        for (key in listOf("preferMeowDisplayGestures", "padControlLayout", "padMainEdge", "padFunctionEdge", "padShowControlHints", "padControlScale", "customLayouts")) {
            json.remove(key)
        }
        store.put(json)

        val loaded = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
        assertTrue(loaded.smartTouchEnabled)
        assertTrue(loaded.autoHideEnabled)
        assertEquals(ReceiverGestureTarget.Viewport, loaded.pinchTarget)
        assertEquals(ReceiverGestureTarget.Disabled, loaded.rotateTarget)
        assertTrue(loaded.preferMeowDisplayGestures)
        assertEquals(PadControlLayoutMode.Strip, loaded.padControlLayout)
        assertEquals("unrelated choices survive", PointerInputMode.Trackpad, loaded.inputMode)
        assertFalse("unrelated choices survive", loaded.hapticsEnabled)
    }

    @Test
    fun testChoicesSavedUnderSchema16AreNeverRemigrated() {
        val (repository, _) = makeRepository()
        val chosen = repository.load()
        chosen.smartTouchEnabled = false
        chosen.autoHideEnabled = false
        chosen.pinchTarget = ReceiverGestureTarget.App
        chosen.rotateTarget = ReceiverGestureTarget.Viewport
        chosen.preferMeowDisplayGestures = false
        chosen.padControlLayout = PadControlLayoutMode.Overlay
        repository.save(chosen)
        val reloaded = repository.load()
        assertFalse(reloaded.smartTouchEnabled)
        assertFalse(reloaded.autoHideEnabled)
        assertEquals(ReceiverGestureTarget.App, reloaded.pinchTarget)
        assertEquals(ReceiverGestureTarget.Viewport, reloaded.rotateTarget)
        assertFalse(reloaded.preferMeowDisplayGestures)
        assertEquals(PadControlLayoutMode.Overlay, reloaded.padControlLayout)
    }

    @Test
    fun testSchema16InstallMigratesOnceToSchema17() {
        val (repository, store) = makeRepository()
        val old = ReceiverControlPreferences()
        old.version = 16
        old.padShowControlHints = true
        old.inputMode = PointerInputMode.Trackpad
        val json = old.toJson().toMutableMap()
        json.remove("padStandardControls")
        json.remove("allowLocalViewNavigation")
        json["padShowMoveViewControl"] = JsonPrimitive(false) // schema 16's own Move View switch
        store.put(json)

        val loaded = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
        assertFalse("pre-release installs take the new default once", loaded.padShowControlHints)
        assertTrue(loaded.allowLocalViewNavigation)
        assertFalse("a hidden Move View stays hidden", loaded.padStandardControls.isVisible(PadStandardControl.MoveView))
        assertTrue(loaded.padStandardControls.isVisible(PadStandardControl.ShowDesktop))
        assertEquals(PointerInputMode.Trackpad, loaded.inputMode)
    }

    @Test
    fun testChoicesSavedUnderSchema17AreNeverRemigrated() {
        val (repository, _) = makeRepository()
        val chosen = repository.load()
        chosen.padShowControlHints = true
        chosen.allowLocalViewNavigation = false
        chosen.padStandardControls.setVisible(false, PadStandardControl.ControlCenter)
        repository.save(chosen)
        repeat(2) {
            val reloaded = repository.load()
            assertTrue(reloaded.padShowControlHints)
            assertFalse(reloaded.allowLocalViewNavigation)
            assertFalse(reloaded.padStandardControls.isVisible(PadStandardControl.ControlCenter))
            repository.save(reloaded)
        }
    }

    @Test
    fun testPersistedControlScaleIsClampedOnLoad() {
        val (repository, store) = makeRepository()
        val json = ReceiverControlPreferences().toJson().toMutableMap()
        json["padControlScale"] = JsonPrimitive(9.0)
        store.put(json)
        assertEquals(PadControlScale.range.endInclusive, repository.load().padControlScale, 0.0)
    }

    @Test
    fun testAnUnreadableCustomLayoutIsDroppedWithoutResettingPreferences() {
        val (repository, store) = makeRepository()
        val preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = false
        preferences.createCustomLayout(id = "keep")
        preferences.createCustomLayout(id = "future")
        val json = preferences.toJson().toMutableMap()
        val layouts = (json["customLayouts"] as JsonArray).toMutableList()
        layouts[1] = JsonObject((layouts[1] as JsonObject).toMutableMap().also { it["landscape"] = JsonPrimitive("not an arrangement") })
        json["customLayouts"] = JsonArray(layouts)
        store.put(json)
        val loaded = repository.load()
        assertEquals(listOf("keep"), loaded.customLayouts.map { it.id })
        assertFalse(loaded.hapticsEnabled)
    }

    @Test
    fun testAnUnknownControlKindDropsOnlyThatPlacement() {
        val json = """
        {"corner":"bottomLeading","placements":[
          {"id":"a","kind":{"kind":"tray","value":"command"},"x":0.1,"y":0.9,"size":1},
          {"id":"b","kind":{"kind":"hologram"},"x":0.2,"y":0.9,"size":1}
        ]}
        """
        val arrangement = CustomControlArrangement.fromJson(parseJson(json))!!
        assertEquals(ControlCorner.BottomLeading, arrangement.corner)
        assertEquals(listOf("a"), arrangement.placements.map { it.id })
    }

    // endregion

    // region Control scale

    @Test
    fun testControlScaleIsBoundedWithAClearDefault() {
        assertEquals(1.0, PadControlScale.defaultValue, 0.0)
        assertTrue(1.0 in PadControlScale.range)
        assertEquals(PadControlScale.range.start, PadControlScale.clamped(0.1), 0.0)
        assertEquals(PadControlScale.range.endInclusive, PadControlScale.clamped(5.0), 0.0)
        assertEquals(1.0, PadControlScale.clamped(Double.NaN), 0.0)
        assertEquals(1.2, PadControlScale.clamped(1.2), 0.0)
        // Never an impractically small hit target.
        assertTrue(PadControlMetrics(scale = 0.0).item >= 37)
        assertTrue(PadControlMetrics(scale = 99.0).item <= 62)
    }

    // endregion

    // region Strip / Overlay geometry

    private val railGroups = listOf(3, 7, 2) // system, keys, view
    private val padSafe = ControlSafeInsets(top = 24.0, leading = 0.0, bottom = 20.0, trailing = 0.0)

    private fun layout(
        container: CGRect? = null, strip: Boolean = true, main: ControlEdge = ControlEdge.Trailing,
        function: ControlEdge = ControlEdge.Trailing, mainGroups: List<Int>? = null, functionGroups: List<Int> = listOf(2, 2),
        metrics: PadControlMetrics? = null, safe: ControlSafeInsets = ControlSafeInsets.zero, keyboardTop: Double? = null,
    ): PadEdgeLayout = PadEdgeGeometry.layout(
        container = container ?: this.container, safeInsets = safe, reservesStrips = strip,
        mainEdge = main, functionEdge = function, mainGroupCounts = mainGroups ?: railGroups,
        functionGroupCounts = functionGroups, metrics = metrics ?: this.metrics, keyboardTop = keyboardTop,
    )

    private fun assertNoOverlap(frames: List<CGRect>, gap: Double, message: String) {
        for (i in frames.indices) {
            for (j in frames.indices) {
                if (j <= i) continue
                val a = frames[i].insetBy(-gap / 2 + 0.01, -gap / 2 + 0.01)
                val b = frames[j].insetBy(-gap / 2 + 0.01, -gap / 2 + 0.01)
                assertFalse("$message: ${frames[i]} vs ${frames[j]}", a.intersects(b))
            }
        }
    }

    @Test
    fun testStripReservesARailAndCentersTheMainControls() {
        val result = layout(function = ControlEdge.Leading)
        val strip = result.strips.first { it.edge == ControlEdge.Trailing }.frame
        assertEquals(CGRect(1130.0, 0.0, 64.0, 834.0), strip)
        assertEquals(CGRect(64.0, 0.0, 1066.0, 834.0), result.canvas)
        val main = result.mainFrame!!
        assertEquals(container.midY, main.midY, 0.5)
        assertEquals(strip.midX, main.midX, 0.5)
        assertTrue(strip.contains(main))
        assertEquals(12, result.mainCells.size)
    }

    @Test
    fun testMainGroupsKeepAVisibleGap() {
        val result = layout(function = ControlEdge.Leading)
        assertEquals(railGroups, result.mainSegments.map { it.cells.size })
        for ((a, b) in result.mainSegments.zip(result.mainSegments.drop(1))) {
            assertEquals(metrics.groupGap, b.frame.minY - a.frame.maxY, 0.01)
        }
    }

    @Test
    fun testStripOnEachEdgeKeepsTheCanvasBesideIt() {
        for (edge in ControlEdge.entries) {
            val result = layout(main = edge, function = edge, functionGroups = emptyList())
            assertEquals("$edge", 1, result.strips.size)
            val strip = result.strips[0].frame
            assertFalse("$edge", strip.intersects(result.canvas))
            assertEquals("$edge", container, strip.union(result.canvas))
            val main = result.mainFrame ?: return fail("missing main frame on $edge")
            assertTrue("$edge", strip.contains(main))
            if (edge.stacksVertically) {
                assertEquals(container.midY, main.midY, 0.5)
            } else {
                assertEquals(container.midX, main.midX, 0.5)
            }
        }
    }

    @Test
    fun testStripIncludesTheSafeInsetButKeepsControlsClearOfIt() {
        val result = layout(
            main = ControlEdge.Bottom, function = ControlEdge.Bottom, functionGroups = emptyList(),
            safe = ControlSafeInsets(top = 0.0, leading = 0.0, bottom = 20.0, trailing = 0.0),
        )
        val strip = result.strips.first().frame
        assertEquals(container.maxY, strip.maxY, 0.0)
        assertEquals(metrics.stripThickness(ControlEdge.Bottom) + 20, strip.height, 0.0)
        assertTrue(result.mainFrame!!.maxY <= container.maxY - 20)
    }

    @Test
    fun testOverlayUsesTheWholeCanvas() {
        val result = layout(strip = false, main = ControlEdge.Leading, function = ControlEdge.Trailing)
        assertTrue(result.strips.isEmpty())
        assertEquals(container, result.canvas)
    }

    @Test
    fun testFunctionGroupsTakeTheEndsOfASharedVerticalEdge() {
        val result = layout(strip = false, mainGroups = listOf(3, 4, 1), safe = padSafe)
        val main = result.mainFrame!!
        assertEquals(2, result.functionSegments.size)
        assertEquals(1, result.laneCounts[ControlEdge.Trailing])
        assertEquals(24 + PadControlMetrics.edgeMargin, result.functionSegments[0].frame.minY, 0.01)
        assertEquals(834 - 20 - PadControlMetrics.edgeMargin, result.functionSegments[1].frame.maxY, 0.01)
        assertTrue(result.functionSegments[0].frame.maxY < main.minY)
        assertTrue(result.functionSegments[1].frame.minY > main.maxY)
    }

    @Test
    fun testFunctionGroupsTakeTheEndsOfASharedHorizontalEdge() {
        val result = layout(main = ControlEdge.Bottom, function = ControlEdge.Bottom, functionGroups = listOf(2, 2, 2))
        val main = result.mainFrame!!
        assertEquals(3, result.functionSegments.size)
        assertTrue(result.functionSegments[0].frame.maxX < result.functionSegments[1].frame.minX)
        assertTrue(result.functionSegments[1].frame.maxX < main.minX)
        assertTrue(result.functionSegments[2].frame.minX > main.maxX)
    }

    @Test
    fun testMainShiftsOffCenterRatherThanOverlapping() {
        // 766 pt of rail: Function (96) + gap + Main (640) fits only if Main
        // leaves the exact center.
        val result = layout(strip = false, main = ControlEdge.Leading, function = ControlEdge.Leading, functionGroups = listOf(2), safe = padSafe)
        val main = result.mainFrame!!
        val function = result.functionSegments.first().frame
        assertEquals(1, result.laneCounts[ControlEdge.Leading])
        assertEquals(function.maxY + metrics.groupGap, main.minY, 0.01)
        assertTrue(main.midY > container.midY)
        assertEquals(main.midX, function.midX, 0.01)
    }

    @Test
    fun testOverflowMovesToAnotherLaneAndWidensTheStrip() {
        val result = layout(main = ControlEdge.Leading, function = ControlEdge.Leading, functionGroups = listOf(2, 2, 2), safe = padSafe)
        assertEquals(2, result.laneCounts[ControlEdge.Leading])
        val strip = result.strips.first().frame
        assertEquals(
            metrics.clusterThickness(ControlEdge.Leading) * 2 + metrics.gap + PadControlMetrics.stripPadding * 2,
            strip.width, 0.01,
        )
        val main = result.mainFrame!!
        for (segment in result.functionSegments) {
            assertTrue("Function moved to the inner lane", segment.frame.minX > main.maxX)
            assertTrue(strip.contains(segment.frame))
        }
        assertNoOverlap(result.mainCells + result.functionCells, metrics.gap, "overflow")
    }

    @Test
    fun testAGroupLongerThanTheEdgeWrapsDeterministically() {
        val portrait = CGRect(0.0, 0.0, 834.0, 1194.0)
        val large = PadControlMetrics(scale = 1.4)
        val first = layout(portrait, main = ControlEdge.Top, function = ControlEdge.Top, mainGroups = listOf(20), functionGroups = emptyList(), metrics = large)
        val second = layout(portrait, main = ControlEdge.Top, function = ControlEdge.Top, mainGroups = listOf(20), functionGroups = emptyList(), metrics = large)
        assertEquals(first, second)
        assertEquals(20, first.mainCells.size)
        assertTrue((first.laneCounts[ControlEdge.Top] ?: 0) > 1)
        assertNoOverlap(first.mainCells, large.gap, "wrapped group")
    }

    @Test
    fun testNothingOverlapsOnAnyEdgeScaleOrientationOrMode() {
        val landscape = container
        val portrait = CGRect(0.0, 0.0, 834.0, 1194.0)
        for (size in listOf(landscape, portrait)) {
            for (strip in listOf(true, false)) {
                for (scale in listOf(0.85, 1.0, 1.4)) {
                    for (hints in listOf(false, true)) {
                        if (!(strip || !hints)) continue
                        val metrics = PadControlMetrics(scale = scale, showsHints = hints)
                        for (main in ControlEdge.entries) {
                            for (function in ControlEdge.entries) {
                                val result = layout(
                                    size, strip = strip, main = main, function = function,
                                    functionGroups = listOf(2, 2, 2), metrics = metrics, safe = padSafe,
                                )
                                val label = "${size.size} strip=$strip scale=$scale hints=$hints $main/$function"
                                val cells = result.mainCells + result.functionCells
                                assertEquals(label, 12, result.mainCells.size)
                                assertEquals(label, 6, result.functionCells.size)
                                assertNoOverlap(cells, metrics.gap, label)
                                val safeArea = CGRect(0.0, 24.0, size.width, size.height - 44)
                                for (cell in cells) {
                                    assertTrue("$label outside safe area: $cell", safeArea.contains(cell))
                                    if (strip) {
                                        assertFalse("$label control over the canvas", cell.intersects(result.canvas.insetBy(0.5, 0.5)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    fun testBottomControlsRiseAboveTheKeyboard() {
        val result = layout(strip = false, main = ControlEdge.Bottom, function = ControlEdge.Trailing, keyboardTop = 500.0)
        assertTrue(result.mainFrame!!.maxY <= 500)
        for (frame in result.functionSegments.map { it.frame }) assertTrue(frame.maxY <= 500)
    }

    @Test
    fun testHiddenControlsReserveNoStrip() {
        val result = layout(main = ControlEdge.Trailing, function = ControlEdge.Leading, mainGroups = emptyList(), functionGroups = emptyList())
        assertTrue(result.strips.isEmpty())
        assertEquals(container, result.canvas)
        assertNull(result.mainFrame)
    }

    @Test
    fun testPaletteAnchorCoversEveryLaneOnTheMainEdge() {
        val result = layout(main = ControlEdge.Leading, function = ControlEdge.Leading, functionGroups = listOf(2, 2, 2), safe = padSafe)
        val anchor = PadEdgeGeometry.paletteAnchor(result, mainEdge = ControlEdge.Leading, functionEdge = ControlEdge.Leading)!!
        for (segment in result.functionSegments) assertTrue(anchor.contains(segment.frame))
    }

    // endregion

    // region Standard rail

    private val everything = PadRailComposition.Availability(
        modifiers = ControlModifier.entries, keyboardAvailable = true, moveViewAvailable = true,
    )

    private fun tray(item: ControlTrayItem) = CustomControlKind.Tray(item)

    @Test
    fun testRailGroupsSystemThenKeysThenView() {
        val groups = PadRailComposition.mainGroups(PadStandardControlVisibility(), everything)
        assertEquals(
            listOf(
                listOf(CustomControlKind.Function("menu-bar"), tray(ControlTrayItem.Dock), CustomControlKind.Function("show-desktop"), CustomControlKind.Function("control-center")),
                listOf(
                    tray(ControlTrayItem.Command), tray(ControlTrayItem.Option), tray(ControlTrayItem.Control), tray(ControlTrayItem.Shift),
                    tray(ControlTrayItem.Escape), tray(ControlTrayItem.Tab), tray(ControlTrayItem.Keyboard),
                ),
                listOf(CustomControlKind.MoveView, tray(ControlTrayItem.Settings)),
            ),
            groups,
        )
    }

    @Test
    fun testEveryStandardControlCanBeHiddenButSettingsStays() {
        val visibility = PadStandardControlVisibility()
        for (control in PadStandardControl.entries) visibility.setVisible(false, control)
        val groups = PadRailComposition.mainGroups(visibility, everything)
        assertEquals(
            listOf(ControlModifier.entries.map { tray(ControlTrayItem.item(it)) }, listOf(tray(ControlTrayItem.Settings))),
            groups,
        )
        val bare = PadRailComposition.mainGroups(
            visibility,
            PadRailComposition.Availability(modifiers = emptyList(), keyboardAvailable = false, moveViewAvailable = false),
        )
        assertEquals(listOf(listOf(tray(ControlTrayItem.Settings))), bare)
    }

    @Test
    fun testStandardControlVisibilityDecodesLossily() {
        val decoded = PadStandardControlVisibility.fromJson(parseJson("""["moveView","hologram","dock"]"""))!!
        assertFalse(decoded.isVisible(PadStandardControl.MoveView))
        assertFalse(decoded.isVisible(PadStandardControl.Dock))
        assertTrue(decoded.isVisible(PadStandardControl.ControlCenter))
    }

    @Test
    fun testHintsWidenTheStrip() {
        val hinted = PadControlMetrics(showsHints = true)
        assertTrue(hinted.stripThickness(ControlEdge.Trailing) > metrics.stripThickness(ControlEdge.Trailing))
        assertTrue(hinted.stripThickness(ControlEdge.Bottom) > metrics.stripThickness(ControlEdge.Bottom))
    }

    @Test
    fun testPaletteOpensTowardTheCanvasAndStaysInside() {
        val anchor = CGRect(1140.0, 187.0, 44.0, 460.0)
        val bounds = CGRect(12.0, 12.0, 1130.0, 810.0)
        val frame = PadEdgeGeometry.paletteFrame(CGSize(44.0, 300.0), anchor, ControlEdge.Trailing, bounds, gap = 8.0)
        assertEquals(1132.0, frame.maxX, 0.0)
        assertEquals(anchor.midY, frame.midY, 0.5)
        assertTrue(bounds.contains(frame))
    }

    @Test
    fun testPaletteGridWrapsIntoMoreColumnsWhenAColumnWouldOverflow() {
        val grid = PadEdgeGeometry.paletteGrid(
            count = 12, key = CGSize(40.0, 40.0), gap = 5.0, edge = ControlEdge.Trailing, available = CGSize(900.0, 300.0),
        )
        assertEquals(6, grid.rows)
        assertEquals(2, grid.columns)
        assertTrue(grid.size.height <= 300)
    }

    @Test
    fun testAutoHideNeverAppliesToTheIPadStrip() {
        assertFalse(ControlAutoHidePolicy.applies(isPad = true, layout = PadControlLayoutMode.Strip))
        assertTrue(ControlAutoHidePolicy.applies(isPad = true, layout = PadControlLayoutMode.Overlay))
        assertTrue(ControlAutoHidePolicy.applies(isPad = true, layout = PadControlLayoutMode.Custom))
        assertTrue(ControlAutoHidePolicy.applies(isPad = false, layout = PadControlLayoutMode.Strip))
    }

    // endregion

    // region Custom layouts

    @Test
    fun testAtMostFiveCustomLayouts() {
        val preferences = ReceiverControlPreferences()
        for (index in 0 until 5) {
            assertTrue(preferences.canCreateCustomLayout)
            assertNotNull(preferences.createCustomLayout(id = "layout-$index"))
        }
        assertFalse(preferences.canCreateCustomLayout)
        assertNull(preferences.createCustomLayout())
        assertEquals(5, preferences.customLayouts.size)
        assertEquals("names are unique", 5, preferences.customLayouts.map { it.name }.toSet().size)
    }

    @Test
    fun testCreateRenameAndDeleteCustomLayouts() {
        val preferences = ReceiverControlPreferences()
        preferences.padControlLayout = PadControlLayoutMode.Custom
        val first = preferences.createCustomLayout(id = "a")!!
        val second = preferences.createCustomLayout(id = "b")!!
        assertEquals("a new layout becomes active", second, preferences.activeCustomLayout?.id)
        preferences.renameCustomLayout(first, "  Drawing  ")
        assertEquals("Drawing", preferences.customLayouts.first().name)
        preferences.renameCustomLayout(first, "   ")
        assertEquals("blank names are ignored", "Drawing", preferences.customLayouts.first().name)
        preferences.deleteCustomLayout(second)
        assertEquals(first, preferences.activeCustomLayout?.id)
        assertEquals(PadControlLayoutMode.Custom, preferences.padControlLayout)
        preferences.deleteCustomLayout(first)
        assertNull(preferences.activeCustomLayout)
        assertEquals("Custom with nothing to show falls back", PadControlLayoutMode.Overlay, preferences.padControlLayout)
    }

    @Test
    fun testPortraitAndLandscapeLayoutsAreIndependent() {
        var layout = CustomControlLayout.radialTemplate(name = "Test")
        var portrait = layout.arrangement(portrait = true)
        portrait = portrait.copy(
            placements = portrait.placements.toMutableList().also {
                it[0] = it[0].copy(x = 0.5)
                it.removeAt(it.lastIndex)
            },
        )
        val landscapeBefore = layout.arrangement(portrait = false)
        layout = layout.setArrangement(portrait, portrait = true)
        assertEquals(landscapeBefore, layout.arrangement(portrait = false))
        assertEquals(portrait, layout.arrangement(portrait = true))
        assertEquals(layout, CustomControlLayout.fromJson(parseJson(layout.toJson().toString())))
    }

    @Test
    fun testPlacementsStayNormalizedAndBounded() {
        val placement = CustomControlPlacement(kind = tray(ControlTrayItem.Escape), x = 1.7, y = -3.0, size = 9.0)
        assertEquals(1.0, placement.x, 0.0)
        assertEquals(0.0, placement.y, 0.0)
        assertEquals(CustomControlPlacement.sizeRange.endInclusive, placement.size, 0.0)
        val area = CustomLayoutGeometry.layoutArea(
            container, ControlSafeInsets(top = 24.0, leading = 0.0, bottom = 20.0, trailing = 0.0),
        )
        val frame = CustomLayoutGeometry.frame(placement, area, baseDiameter = 44.0)
        assertTrue("clamped clear of the Home indicator and edges", area.contains(frame))
        assertTrue(frame.maxY <= container.maxY - 20)
        val normalized = CustomLayoutGeometry.normalizedPoint(CGPoint(-50.0, area.midY), area)
        assertEquals(0.0, normalized.x, 0.0)
        assertEquals(0.5, normalized.y, 0.001)
    }

    @Test
    fun testAlignmentSnapOnlyNearAGridLine() {
        assertEquals(0.5, CustomLayoutGeometry.snapped(0.505), 0.0)
        assertEquals(0.52, CustomLayoutGeometry.snapped(0.52), 0.0)
    }

    @Test
    fun testRadialTemplateClustersAroundEachCornerWithoutOverlap() {
        for (corner in ControlCorner.entries) {
            for (portrait in listOf(false, true)) {
                val arrangement = CustomControlArrangement.radialTemplate(corner, portrait)
                val reference = if (portrait) CustomControlArrangement.referencePortrait else CustomControlArrangement.referenceLandscape
                assertEquals(corner, arrangement.corner)
                val points = arrangement.placements.map {
                    Pair(CGPoint(it.x * reference.width, it.y * reference.height), 44 * it.size)
                }
                for (i in points.indices) {
                    for (j in points.indices) {
                        if (j <= i) continue
                        val d = hypot(points[i].first.x - points[j].first.x, points[i].first.y - points[j].first.y)
                        assertTrue("$corner portrait=$portrait $i/$j", d >= (points[i].second + points[j].second) / 2)
                    }
                }
                // Settings sits closest to the corner.
                val cornerPoint = CGPoint(corner.unitPoint.x * reference.width, corner.unitPoint.y * reference.height)
                val nearest = arrangement.placements.minByOrNull {
                    hypot(it.x * reference.width - cornerPoint.x, it.y * reference.height - cornerPoint.y)
                }
                assertEquals(tray(ControlTrayItem.Settings), nearest?.kind)
                assertEquals(ControlModifier.entries.toSet(), arrangement.placements.mapNotNull { it.kind.modifier }.toSet())
                // The constellation stays in the corner's quadrant (the
                // system group sits on the opposite side on purpose).
                for (placement in arrangement.placements) {
                    if (placement.kind in CustomControlArrangement.templateSystem) continue
                    assertEquals(corner.isLeading, placement.x < 0.5)
                    assertEquals(corner.isTop, placement.y < 0.5)
                }
            }
        }
    }

    // endregion

    // region Radial palettes

    @Test
    fun testArcKeysAreEvenlySpacedAndFanTowardTheDirection() {
        val center = CGPoint(1000.0, 700.0)
        val direction = RadialPaletteLayout.direction(center, CGPoint(597.0, 417.0))
        val points = RadialPaletteLayout.points(
            count = 5, center = center, shape = PaletteShape.Arc, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 110.0, direction = direction, bounds = container,
        )
        assertEquals(5, points.size)
        for ((a, b) in points.zip(points.drop(1))) {
            assertTrue(hypot(a.x - b.x, a.y - b.y) >= 50 - 0.01)
        }
        for (point in points) {
            assertEquals(110.0, hypot(point.x - center.x, point.y - center.y), 0.01)
            assertTrue("fans toward the screen, away from the corner", point.x < center.x + 1)
        }
        val middle = points[2]
        assertEquals(direction, atan2(middle.y - center.y, middle.x - center.x), 0.001)
    }

    @Test
    fun testLongArcsContinueOnALargerArc() {
        val points = RadialPaletteLayout.points(
            count = 12, center = CGPoint(600.0, 400.0), shape = PaletteShape.Arc, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 80.0, direction = -PI / 2, bounds = container,
        )
        val radii = points.map { Math.round(hypot(it.x - 600, it.y - 400)).toInt() }.toSet()
        assertTrue(radii.size > 1)
        for (i in points.indices) {
            for (j in points.indices) {
                if (j <= i) continue
                assertTrue(hypot(points[i].x - points[j].x, points[i].y - points[j].y) >= 44)
            }
        }
    }

    @Test
    fun testRingRowAndColumnShapes() {
        val center = CGPoint(600.0, 400.0)
        val ring = RadialPaletteLayout.points(
            count = 8, center = center, shape = PaletteShape.Ring, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 44.0, direction = 0.0, bounds = container,
        )
        for ((a, b) in ring.zip(ring.drop(1) + listOf(ring[0]))) {
            assertTrue(hypot(a.x - b.x, a.y - b.y) >= 50 - 0.01)
        }
        val row = RadialPaletteLayout.points(
            count = 3, center = center, shape = PaletteShape.Row, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 60.0, direction = -PI / 2, bounds = container,
        )
        assertEquals(setOf(340.0), row.map { it.y }.toSet())
        assertEquals(listOf(550.0, 600.0, 650.0), row.map { it.x })
        val column = RadialPaletteLayout.points(
            count = 3, center = center, shape = PaletteShape.Column, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 60.0, direction = PI, bounds = container,
        )
        assertEquals(setOf(540.0), column.map { it.x }.toSet())
    }

    @Test
    fun testPaletteGrowsOutwardPastOtherControls() {
        val center = CGPoint(600.0, 400.0)
        val blocker = CGRect(578.0, 278.0, 44.0, 44.0) // straight up at radius 100
        val points = RadialPaletteLayout.points(
            count = 3, center = center, shape = PaletteShape.Arc, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 100.0, direction = -PI / 2, bounds = container, obstacles = listOf(blocker),
        )
        for (point in points) {
            assertFalse(blocker.insetBy(-22.0, -22.0).contains(point))
        }
    }

    @Test
    fun testPaletteKeysStayOnScreen() {
        val points = RadialPaletteLayout.points(
            count = 6, center = CGPoint(20.0, 20.0), shape = PaletteShape.Ring, itemDiameter = 44.0, spacing = 6.0,
            minimumRadius = 60.0, direction = 0.0, bounds = container,
        )
        for (point in points) {
            assertTrue(container.insetBy(21.9, 21.9).contains(point))
        }
    }

    // endregion

    // region Two-Hand Assist

    @Test
    fun testAssistProjectsTheSharedChordState() {
        val interaction = ControlInteractionState()
        assertEquals(TwoHandAssistState.Idle, TwoHandAssist.state(enabled = true, interaction = interaction))
        assertEquals(TwoHandAssistState.Hidden, TwoHandAssist.state(enabled = false, interaction = interaction))
        interaction.press(ControlModifier.Command)
        assertEquals(TwoHandAssistState.Helper(setOf(ControlModifier.Command)), TwoHandAssist.state(enabled = true, interaction = interaction))
    }

    @Test
    fun testHelperModifierJoinsTheHeldChord() {
        val interaction = ControlInteractionState()
        interaction.press(ControlModifier.Command)
        val effects = interaction.toggleAssistModifier(ControlModifier.Option)
        assertTrue(effects.contains(ControlInteractionEffect.ModifierDown(ControlModifier.Command)))
        assertTrue(effects.contains(ControlInteractionEffect.ModifierDown(ControlModifier.Option)))
        assertEquals(ModifierChord(setOf(ControlModifier.Command, ControlModifier.Option)), interaction.activeChord)
        assertEquals(
            "the primary palette updates to the combined chord",
            ModifierChord(setOf(ControlModifier.Command, ControlModifier.Option)), interaction.paletteChord,
        )
        assertEquals(
            TwoHandAssistState.Helper(setOf(ControlModifier.Command, ControlModifier.Option)),
            TwoHandAssist.state(enabled = true, interaction = interaction),
        )
        // Tapping it again on the helper removes it again.
        interaction.toggleAssistModifier(ControlModifier.Option)
        assertEquals(ModifierChord(setOf(ControlModifier.Command)), interaction.activeChord)
        interaction.toggleAssistModifier(ControlModifier.Shift)
        // Releasing the hold (executing a shortcut) releases everything, and
        // the idle Function actions come back.
        val action = ShortcutItem(
            title = "Redo", displayKey = "Z", usage = 29,
            modifiers = ModifierChord(setOf(ControlModifier.Command, ControlModifier.Shift)),
        )
        val release = interaction.finish(action)
        assertTrue(release.contains(ControlInteractionEffect.Execute(action)))
        assertTrue(release.contains(ControlInteractionEffect.ModifierUp(ControlModifier.Command)))
        assertTrue(release.contains(ControlInteractionEffect.ModifierUp(ControlModifier.Shift)))
        assertEquals(TwoHandAssistState.Idle, TwoHandAssist.state(enabled = true, interaction = interaction))
    }

    @Test
    fun testHelperModifierLatchesAlongsideALatchedChord() {
        val interaction = ControlInteractionState()
        interaction.tap(ControlModifier.Command)
        interaction.toggleAssistModifier(ControlModifier.Option)
        assertEquals(setOf(ControlModifier.Command, ControlModifier.Option), interaction.latchedModifiers)
        assertEquals(
            TwoHandAssistState.Helper(setOf(ControlModifier.Command, ControlModifier.Option)),
            TwoHandAssist.state(enabled = true, interaction = interaction),
        )
        interaction.resetAll()
        assertEquals(TwoHandAssistState.Idle, TwoHandAssist.state(enabled = true, interaction = interaction))
    }

    @Test
    fun testHelperAppearsOnTheOppositeSide() {
        assertEquals(CGPoint(0.125, 0.75), TwoHandAssist.helperAnchor(CGPoint(0.875, 0.75)))
        assertEquals(CGPoint(0.9, 0.2), TwoHandAssist.helperAnchor(CGPoint(0.1, 0.2)))
        assertEquals("a bottom-centered cluster mirrors to the top", CGPoint(0.5, 0.125), TwoHandAssist.helperAnchor(CGPoint(0.5, 0.875)))
        val area = CGRect(12.0, 12.0, 1170.0, 810.0)
        val points = TwoHandAssist.helperPoints(count = 4, clusterCentroid = CGPoint(0.9, 0.9), area = area, itemDiameter = 44.0, spacing = 6.0)
        assertEquals(4, points.size)
        for (point in points) {
            assertTrue(point.x < area.midX)
            assertTrue(point.y > area.midY)
            assertTrue(area.contains(point))
        }
    }

    @Test
    fun testTemplateEnablesTwoHandAssistWithIdleFunctionActions() {
        val layout = CustomControlLayout.radialTemplate(name = "Test", corner = ControlCorner.BottomLeading)
        assertTrue(layout.twoHandAssist)
        assertEquals(listOf("undo", "redo", "zoom-in", "zoom-out", "return"), layout.assistActionIDs)
        val canonicalIDs = FunctionTrayProfile.canonical().items.map { it.id }.toSet()
        assertTrue("idle actions reuse existing Function Tray items", canonicalIDs.containsAll(layout.assistActionIDs))
        assertTrue(layout.landscape.clusterCentroid.x < 0.5)
    }

    // endregion

    // region Gesture preference

    @Test
    fun testPreferMeowDisplayGesturesControlsEdgeDeferral() {
        assertTrue(ReceiverScreenEdgePolicy.defersScreenEdges(surfaceShown = true, inputAllowed = true, preferMeowDisplayGestures = true))
        assertFalse(ReceiverScreenEdgePolicy.defersScreenEdges(surfaceShown = true, inputAllowed = true, preferMeowDisplayGestures = false))
        assertTrue(ReceiverEditingInteractionPolicy.suppressesEditingInteractions(preferMeowDisplayGestures = true))
        assertFalse(ReceiverEditingInteractionPolicy.suppressesEditingInteractions(preferMeowDisplayGestures = false))
    }

    @Test
    fun testVoiceOverAlwaysWins() {
        assertFalse(
            ReceiverScreenEdgePolicy.defersScreenEdges(
                surfaceShown = true, inputAllowed = true, preferMeowDisplayGestures = true, voiceOverRunning = true,
            ),
        )
        val gate = ReceiverMultiFingerGestureGate(voiceOverRunning = true)
        assertFalse(gate.recognizersEnabled)
        gate.updateViewportNavigationActive(false)
        assertFalse("no preference or mode re-enables them under VoiceOver", gate.recognizersEnabled)
    }

    @Test
    fun testMoveViewParksTheMultiFingerRecognizers() {
        val gate = ReceiverMultiFingerGestureGate(voiceOverRunning = false)
        assertTrue(gate.updateViewportNavigationActive(true))
        for (kind in ReceiverMultiFingerRecognizer.entries) assertFalse(gate.isEnabled(kind))
        assertFalse(gate.updateViewportNavigationActive(true))
        assertTrue(gate.updateViewportNavigationActive(false))
        assertTrue(gate.recognizersEnabled)
    }

    // endregion
}

/**
 * A fresh iPad starts on the radial Custom layout around a bottom-right
 * Settings anchor; Strip and Overlay stay one setting away. Nothing a user
 * already saved changes, and the iPhone is unaffected.
 */
class PadDefaultLayoutTests {
    private class MapStore : PreferenceBlobStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    @Test
    fun testFreshPadStartsOnTheRadialCustomLayout() {
        val preferences = ReceiverControlPreferences.initial(isPad = true)
        assertEquals(PadControlLayoutMode.Custom, preferences.padControlLayout)
        val layout = preferences.activeCustomLayout!!
        assertEquals(CustomControlArrangement.radialTemplate(ControlCorner.BottomTrailing, portrait = false), layout.landscape)
        assertEquals(CustomControlArrangement.radialTemplate(ControlCorner.BottomTrailing, portrait = true), layout.portrait)
        assertEquals(1, preferences.customLayouts.size)
    }

    @Test
    fun testFreshPhoneKeepsTheStandardDefaults() {
        // Standard defaults, except that phones start in Trackpad (schema 21).
        assertEquals(ReceiverControlPreferences().also { it.inputMode = PointerInputMode.Trackpad }, ReceiverControlPreferences.initial(isPad = false))
    }

    @Test
    fun testRepositoryUsesTheInitialPreferencesOnlyWhenNothingIsSaved() {
        val repository = ReceiverControlPreferencesRepository(MapStore())
        assertEquals(PadControlLayoutMode.Custom, repository.load(ReceiverControlPreferences.initial(isPad = true)).padControlLayout)

        val saved = ReceiverControlPreferences()
        saved.padControlLayout = PadControlLayoutMode.Strip
        repository.save(saved)
        assertEquals(PadControlLayoutMode.Strip, repository.load(ReceiverControlPreferences.initial(isPad = true)).padControlLayout)
        assertTrue(repository.load(ReceiverControlPreferences.initial(isPad = true)).customLayouts.isEmpty())
    }
}

/**
 * The radial layout's idle Two-Hand Assist arc offers Return beside Undo,
 * Redo and Zoom, without crowding the arc.
 */
class RadialReturnTests {
    @Test
    fun testRadialTemplateOffersReturnInTwoHandAssist() {
        assertEquals(listOf("undo", "redo", "zoom-in", "zoom-out", "return"), CustomControlLayout.defaultAssistActionIDs)
        val layout = CustomControlLayout.radialTemplate(name = "Test")
        assertTrue(layout.assistActionIDs.contains("return"))
    }

    @Test
    fun testFiveAssistActionsDoNotOverlap() {
        val area = CGRect(0.0, 0.0, 1180.0, 820.0)
        val diameter = 52.0
        val points = TwoHandAssist.helperPoints(count = 5, clusterCentroid = CGPoint(0.9, 0.9), area = area, itemDiameter = diameter, spacing = 8.0)
        assertEquals(5, points.size)
        for ((i, a) in points.withIndex()) {
            assertTrue(area.insetBy(diameter / 2 - 0.5, diameter / 2 - 0.5).contains(a))
            for (b in points.drop(i + 1)) {
                assertTrue(hypot(a.x - b.x, a.y - b.y) >= diameter - 0.5)
            }
        }
    }
}
