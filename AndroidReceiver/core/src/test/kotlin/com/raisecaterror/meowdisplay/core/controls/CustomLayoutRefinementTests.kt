package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/CustomLayoutRefinementTests.swift.
//
// Left out (types outside this port):
//  - testSearchFindsRealSettingsOnTheirPages, testSearchRespectsDeviceAndBuild: MobileSettingsSearchIndex / MobileSettingsCategory (not ported).
//  - testLocalNavigationWorksWithInputOff, testLocalNavigationNeverRoutesAnythingToTheMac,
//    testDisabledLocalNavigationLeavesRemoteRoutesIntact: LocalViewNavigationPolicy / TwoFingerRoutingPolicy (viewport port).
// `ManualViewportState.normalizedAngle` (viewport port) is the package-internal `normalizedAngle` from CustomControlLayout.kt here.

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
import kotlin.math.hypot

/**
 * Concentric radial layouts, mirrored Two-Hand Assist, one-tap keyboard
 * chords, share codes, the editor Preview, Settings search, and the Local
 * View Navigation / Allow Input split.
 */
class CustomLayoutRefinementTests {
    private val base = 44.0

    private fun referenceArea(portrait: Boolean): CGRect =
        CGRect(CGPoint.zero, if (portrait) CustomControlArrangement.referencePortrait else CustomControlArrangement.referenceLandscape)

    private fun center(rect: CGRect) = CGPoint(rect.midX, rect.midY)

    private fun distance(a: CGPoint, b: CGPoint) = hypot(a.x - b.x, a.y - b.y)

    /** Unwrapped angles of [points] around [origin], relative to the corner's horizontal edge, in sweep order (0...pi/2). */
    private fun sweepOffsets(points: List<CGPoint>, origin: CGPoint, corner: ControlCorner): List<Double> {
        val start = CornerArcGeometry.horizontalEdgeAngle(corner)
        val sign = if (CornerArcGeometry.sweep(corner) > 0) 1.0 else -1.0
        return points.map { point -> normalizedAngle((atan2(point.y - origin.y, point.x - origin.x) - start) * sign) }
    }

    private fun steps(offsets: List<Double>) = offsets.zip(offsets.drop(1)).map { (a, b) -> b - a }

    // region Concentric radial template

    @Test
    fun testTemplateIsSettingsThenUtilitiesThenModifiersOnConcentricArcs() {
        for (corner in ControlCorner.entries) {
            for (portrait in listOf(false, true)) {
                val label = "$corner portrait=$portrait"
                val arrangement = CustomControlArrangement.radialTemplate(corner, portrait)
                val area = referenceArea(portrait)
                val frames = CustomLayoutGeometry.frames(arrangement, area, base)
                val origin = center(frames["settings"]!!)
                val utilities = CustomControlArrangement.templateUtilities.map { center(frames[it.stableID]!!) }
                val modifiers = CustomControlArrangement.templateModifiers.map { center(frames[it.raw]!!) }
                val utilityRadii = utilities.map { distance(it, origin) }
                val modifierRadii = modifiers.map { distance(it, origin) }
                // Every layer is one true arc: a single radius.
                for (radius in utilityRadii) assertEquals(label, utilityRadii[0], radius, 0.5)
                for (radius in modifierRadii) assertEquals(label, modifierRadii[0], radius, 0.5)
                // Settings -> utilities -> modifiers, each layer clear of the last.
                assertTrue(label, utilityRadii[0] >= base * 0.9 + 8 - 0.5)
                assertTrue(label, modifierRadii[0] - utilityRadii[0] >= base * 0.45 + base / 2 + 8 - 0.5)
                // Even angular distribution, in order along the sweep.
                for (points in listOf(utilities, modifiers)) {
                    val offsets = sweepOffsets(points, origin, corner)
                    val steps = steps(offsets)
                    for (step in steps) {
                        assertTrue("$label ordered", step > 0)
                        assertEquals("$label evenly spaced", steps[0], step, 0.01)
                    }
                    for (offset in offsets) {
                        assertTrue(label, offset >= -0.001)
                        assertTrue(label, offset <= PI / 2 + 0.001)
                    }
                }
            }
        }
    }

    @Test
    fun testArcAnglesSweepFromEachCornersHorizontalEdgeTowardItsVerticalEdge() {
        val expected = mapOf(
            ControlCorner.TopLeading to (0.0 to PI / 2), ControlCorner.TopTrailing to (PI to PI / 2),
            ControlCorner.BottomLeading to (0.0 to -PI / 2), ControlCorner.BottomTrailing to (PI to 1.5 * PI),
        )
        for (corner in ControlCorner.entries) {
            val angles = CornerArcGeometry.angles(
                count = 3, radius = 200.0, corner = corner, diameter = 10.0, edgeDistances = CGSize(100.0, 100.0),
            )
            val (start, end) = expected[corner]!!
            assertEquals("$corner", start, angles[0], 0.001)
            assertEquals("$corner", (start + end) / 2, angles[1], 0.001)
            assertEquals("$corner", end, angles[2], 0.001)
        }
    }

    @Test
    fun testArcsStayClearOfTheCornerEdges() {
        val edges = CGSize(20.0, 30.0)
        for (corner in ControlCorner.entries) {
            val origin = CGPoint(500.0, 500.0)
            val points = CornerArcGeometry.points(
                count = 5, radius = 120.0, origin = origin, corner = corner, diameter = 44.0, edgeDistances = edges,
            )
            for (point in points) {
                // Distance to the vertical and horizontal edge lines.
                assertTrue("$corner", kotlin.math.abs(point.x - origin.x) + edges.width >= 22 - 0.01)
                assertTrue("$corner", kotlin.math.abs(point.y - origin.y) + edges.height >= 22 - 0.01)
            }
        }
    }

    // endregion

    // region Palette on the next arc

    @Test
    fun testPaletteBloomsOnTheArcDirectlyOutsideTheModifiers() {
        for (corner in ControlCorner.entries) {
            val arrangement = CustomControlArrangement.radialTemplate(corner, portrait = false)
            val area = referenceArea(portrait = false)
            val frames = CustomLayoutGeometry.frames(arrangement, area, base)
            val origin = center(frames["settings"]!!)
            val modifierRadius = distance(center(frames["command"]!!), origin)
            val keyDiameter = CustomLayoutGeometry.paletteKeyDiameter(base)
            val points = CustomLayoutGeometry.palettePoints(
                count = 5, anchorID = "command", arrangement = arrangement, frames = frames, area = area,
                baseDiameter = base, spacing = 8.0,
            )
            assertEquals(5, points.size)
            val expected = modifierRadius + base / 2 + keyDiameter / 2 + 8
            for (point in points) {
                assertEquals("$corner: attached to the modifiers", expected, distance(point, origin), 0.5)
            }
            val offsets = sweepOffsets(points, origin, corner)
            val steps = steps(offsets)
            for (step in steps) assertEquals("$corner evenly spaced", steps[0], step, 0.01)
            for (point in points) {
                for (frame in frames.values) {
                    assertTrue(distance(point, center(frame)) >= frame.width / 2 + keyDiameter / 2 - 0.5)
                }
            }
        }
    }

    @Test
    fun testLargePalettesContinueOnTheNextArcOut() {
        val arrangement = CustomControlArrangement.radialTemplate(ControlCorner.BottomTrailing, portrait = false)
        val area = referenceArea(portrait = false)
        val frames = CustomLayoutGeometry.frames(arrangement, area, base)
        val origin = center(frames["settings"]!!)
        val points = CustomLayoutGeometry.palettePoints(
            count = 14, anchorID = "option", arrangement = arrangement, frames = frames, area = area,
            baseDiameter = base, spacing = 8.0,
        )
        val radii = points.map { Math.round(distance(it, origin)).toInt() }.toSet()
        assertTrue(radii.size > 1)
        for (i in points.indices) {
            for (j in points.indices) {
                if (j <= i) continue
                assertTrue(distance(points[i], points[j]) >= CustomLayoutGeometry.paletteKeyDiameter(base) - 0.5)
            }
        }
    }

    @Test
    fun testAModifierMovedAwayFromTheCornerBloomsAroundItself() {
        var arrangement = CustomControlArrangement.radialTemplate(ControlCorner.BottomTrailing, portrait = false)
        val index = arrangement.placements.indexOfFirst { it.id == "command" }
        assertTrue(index >= 0)
        arrangement = arrangement.copy(
            placements = arrangement.placements.toMutableList().also { it[index] = it[index].copy(x = 0.4, y = 0.4) },
        )
        val area = referenceArea(portrait = false)
        val frames = CustomLayoutGeometry.frames(arrangement, area, base)
        assertNull(CornerCluster.resolve(arrangement, frames, area))
        val anchor = center(frames["command"]!!)
        val points = CustomLayoutGeometry.palettePoints(
            count = 4, anchorID = "command", arrangement = arrangement, frames = frames, area = area,
            baseDiameter = base, spacing = 8.0,
        )
        for (point in points) assertTrue(distance(point, anchor) < 200)
    }

    // endregion

    // region Two-Hand Assist

    @Test
    fun testHelperModifiersAreTheModifierArcMirrored() {
        for (corner in ControlCorner.entries) {
            for (portrait in listOf(false, true)) {
                val arrangement = CustomControlArrangement.radialTemplate(corner, portrait)
                val area = referenceArea(portrait)
                val frames = CustomLayoutGeometry.frames(arrangement, area, base)
                val helpers = TwoHandAssist.helperPoints(
                    count = 4, arrangement = arrangement, frames = frames, area = area, itemDiameter = base, spacing = 8.0,
                )
                val mirroredModifiers = CustomControlArrangement.templateModifiers.map { item ->
                    val point = center(frames[item.raw]!!)
                    CGPoint(area.minX + area.maxX - point.x, point.y)
                }
                assertEquals(4, helpers.size)
                for ((helper, expected) in helpers.zip(mirroredModifiers)) {
                    assertEquals("$corner portrait=$portrait", expected.x, helper.x, 0.5)
                    assertEquals("$corner portrait=$portrait", expected.y, helper.y, 0.5)
                }
                // A real arc around the mirrored anchor.
                val settings = center(frames["settings"]!!)
                val mirroredOrigin = CGPoint(area.minX + area.maxX - settings.x, settings.y)
                val radii = helpers.map { distance(it, mirroredOrigin) }
                for (radius in radii) assertEquals(radii[0], radius, 0.5)
                val offsets = sweepOffsets(helpers, mirroredOrigin, CornerArcGeometry.mirroredHorizontally(corner))
                val steps = steps(offsets)
                for (step in steps) assertEquals(steps[0], step, 0.01)
            }
        }
    }

    @Test
    fun testMoreIdleActionsWidenTheMirroredArcInsteadOfCrowdingIt() {
        val arrangement = CustomControlArrangement.radialTemplate(ControlCorner.BottomTrailing, portrait = true)
        val area = referenceArea(portrait = true)
        val frames = CustomLayoutGeometry.frames(arrangement, area, base)
        val points = TwoHandAssist.helperPoints(
            count = 7, arrangement = arrangement, frames = frames, area = area, itemDiameter = base, spacing = 8.0,
        )
        for ((a, b) in points.zip(points.drop(1))) {
            assertTrue(distance(a, b) >= base + 8 - 0.5)
        }
        for (point in points) assertTrue(point.x < area.midX)
    }

    // endregion

    // region One-tap keyboard shortcuts

    @Test
    fun testChordPlanPressesThenReleasesEveryKeyInReverse() {
        val shortcut = KeyboardShortcut(usage = 14, modifiers = ModifierChord(setOf(ControlModifier.Shift, ControlModifier.Command)), additionalUsages = listOf(32))
        val events = KeyboardChordPlan.events(shortcut)
        assertEquals(
            listOf(KeyboardChordEvent.Phase.Down, KeyboardChordEvent.Phase.Down, KeyboardChordEvent.Phase.Up, KeyboardChordEvent.Phase.Up),
            events.map { it.phase },
        )
        assertEquals(listOf(14, 32, 32, 14), events.map { it.usage })
        assertTrue(events.all { it.modifiers == listOf("command", "shift") })
        val held = mutableSetOf<Int>()
        for (event in events) {
            if (event.phase == KeyboardChordEvent.Phase.Down) {
                assertTrue(held.add(event.usage))
            } else {
                assertTrue(held.remove(event.usage))
            }
        }
        assertTrue("no key is left held", held.isEmpty())
    }

    @Test
    fun testKeyboardShortcutCodableStaysBackwardCompatible() {
        val plain = KeyboardShortcut(usage = 24, modifiers = ModifierChord(setOf(ControlModifier.Control)))
        val json = plain.toJson().toString()
        assertFalse("ordinary shortcuts encode exactly as before", json.contains("additionalUsages"))
        val legacy = KeyboardShortcut.fromJson(parseJson("""{"usage":24,"modifiers":{"modifiers":["control"]}}"""))
        assertEquals(plain, legacy)
        val chord = KeyboardShortcut(usage = 14, modifiers = ModifierChord(), additionalUsages = listOf(32))
        assertEquals(chord, KeyboardShortcut.fromJson(parseJson(chord.toJson().toString())))
        assertTrue(chord.isValid)
        assertFalse(KeyboardShortcut(usage = 14, modifiers = ModifierChord(), additionalUsages = listOf(14)).isValid)
        assertFalse(KeyboardShortcut(usage = 999, modifiers = ModifierChord()).isValid)
    }

    @Test
    fun testShortcutPlacementsRoundTrip() {
        val item = ShortcutItem(
            id = "u", title = "Underline", displayKey = "U", usage = 24,
            modifiers = ModifierChord(setOf(ControlModifier.Control)), systemImage = "underline",
        )
        val placement = CustomControlPlacement(kind = CustomControlKind.Shortcut(item), x = 0.3, y = 0.7)
        val decoded = CustomControlPlacement.fromJson(parseJson(placement.toJson().toString()))!!
        assertEquals(placement, decoded)
        assertNull(decoded.palette)
    }

    // endregion

    // region Share codes

    private fun sampleLayout(): CustomControlLayout {
        var layout = CustomControlLayout.radialTemplate(id = "local-id", name = "Drawing", corner = ControlCorner.BottomLeading)
        val shortcut = ShortcutItem(
            id = "k3", title = "K then 3", displayKey = "K3", usage = 14, modifiers = ModifierChord(), systemImage = null,
        )
        val item = shortcut.copy(
            action = ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage = 14, modifiers = ModifierChord(), additionalUsages = listOf(32))),
        )
        layout = layout.copy(
            portrait = layout.portrait.copy(
                placements = layout.portrait.placements + CustomControlPlacement(id = "k3", kind = CustomControlKind.Shortcut(item), x = 0.5, y = 0.2, size = 1.2),
            ),
        )
        layout = layout.copy(landscape = layout.landscape.copy(placements = layout.landscape.placements.dropLast(1)))
        return layout.copy(twoHandAssist = false)
    }

    @Test
    fun testShareCodeRoundTripsTheLayout() {
        val layout = sampleLayout()
        val code = CustomLayoutShareCode.encode(layout)
        assertTrue(code.startsWith("MDL1-"))
        val summary = CustomLayoutShareCode.decode(code).getOrThrow()
        assertNotEquals("an import is a new layout", layout.id, summary.layout.id)
        assertEquals("Drawing", summary.layout.name)
        assertEquals(layout.landscape, summary.layout.landscape)
        assertEquals("portrait survives independently", layout.portrait, summary.layout.portrait)
        assertEquals(false, summary.layout.twoHandAssist)
        assertEquals(1, summary.shortcutCount)
        assertEquals(layout.landscape.placements.size, summary.landscapeControls)
        assertEquals(layout.portrait.placements.size, summary.portraitControls)
        assertEquals(emptyList<CustomLayoutShareCode.ImportSummary.Warning>(), summary.warnings)
        // Whitespace from chat apps doesn't matter.
        CustomLayoutShareCode.decode(" \n" + code.take(20) + "\n" + code.drop(20)).getOrThrow()
    }

    @Test
    fun testCorruptedAndForeignCodesAreRejected() {
        val code = CustomLayoutShareCode.encode(sampleLayout())
        val chars = code.toCharArray()
        val index = chars.size / 2
        chars[index] = if (chars[index] == 'A') 'B' else 'A'
        assertEquals(ShareCodeError.Corrupted, CustomLayoutShareCode.decode(String(chars)).failure)
        assertEquals(ShareCodeError.Corrupted, CustomLayoutShareCode.decode(code.dropLast(3)).failure)
        assertEquals(ShareCodeError.NotAShareCode, CustomLayoutShareCode.decode("hello").failure)
        assertEquals(ShareCodeError.UnsupportedVersion(2), CustomLayoutShareCode.decode("MDL2-" + code.drop(5)).failure)
        assertEquals(ShareCodeError.TooLarge, CustomLayoutShareCode.decode("MDL1-" + "A".repeat(70_000)).failure)
    }

    /** What Swift's test does by hand: base64url body -> raw-DEFLATE decompress -> JSON text. */
    private fun payloadJson(code: String): String {
        val body = code.drop(5).split('.')[0]
        val base64 = body.replace('-', '+').replace('_', '/') + "=".repeat((4 - body.length % 4) % 4)
        val compressed = java.util.Base64.getDecoder().decode(base64)
        val inflater = Inflater(true)
        inflater.setInput(compressed)
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (!inflater.finished()) out.write(buffer, 0, inflater.inflate(buffer))
        inflater.end()
        return out.toString(Charsets.UTF_8)
    }

    @Test
    fun testShareCodesCarryOnlyLayoutData() {
        val code = CustomLayoutShareCode.encode(sampleLayout())
        val json = payloadJson(code)
        val obj = parseJson(json) as kotlinx.serialization.json.JsonObject
        assertEquals(setOf("name", "landscape", "portrait", "twoHandAssist", "assistActionIDs"), obj.keys)
        val text = json.lowercase()
        for (secret in listOf("local-id", "peer", "trust", "certificate", "token", "tailscale", "allowinput")) {
            assertFalse(secret, text.contains(secret))
        }
    }

    @Test
    fun testImportsAddANewLayoutWithinTheLimit() {
        val preferences = ReceiverControlPreferences()
        preferences.createCustomLayout(id = "a")
        val existing = preferences.customLayouts[0]
        val summary = CustomLayoutShareCode.decode(CustomLayoutShareCode.encode(existing)).getOrThrow()
        val result = preferences.importCustomLayout(summary.layout)
        val id = (result as? CustomLayoutImportResult.Imported)?.id ?: return fail("import refused")
        assertEquals(2, preferences.customLayouts.size)
        assertEquals("never overwrites", existing, preferences.customLayouts[0])
        assertEquals(existing.name + " 2", preferences.customLayouts.first { it.id == id }.name)
        while (preferences.canCreateCustomLayout) preferences.createCustomLayout()
        assertEquals(CustomLayoutImportResult.LimitReached, preferences.importCustomLayout(summary.layout))
        assertEquals(CustomControlLayout.maximumCount, preferences.customLayouts.size)
    }

    @Test
    fun testImportSanitizesAndWarnsAboutUnknownContent() {
        var layout = sampleLayout()
        layout = layout.copy(name = "x".repeat(200))
        layout = layout.copy(
            portrait = layout.portrait.copy(
                placements = layout.portrait.placements + CustomControlPlacement(id = "f", kind = CustomControlKind.Function("teleport"), x = 0.5, y = 0.5),
            ),
        )
        val summary = CustomLayoutShareCode.decode(CustomLayoutShareCode.encode(layout)).getOrThrow()
        assertEquals(CustomLayoutShareCode.maximumNameLength, summary.layout.name.characterCount())
        assertEquals(listOf<CustomLayoutShareCode.ImportSummary.Warning>(CustomLayoutShareCode.ImportSummary.Warning.UnknownActions(1)), summary.warnings)
    }

    // endregion

    // region Editor and Preview

    @Test
    fun testPreviewNeverSendsAndShowsWhatWouldBeSent() {
        val session = CustomLayoutPreviewSession()
        session.tapModifier(ControlModifier.Command)
        session.tapAssistModifier(ControlModifier.Shift)
        assertEquals(ModifierChord(setOf(ControlModifier.Command, ControlModifier.Shift)), session.interaction.activeChord)
        val redo = ShortcutItem(
            title = "Redo", displayKey = "Z", usage = 29,
            modifiers = ModifierChord(setOf(ControlModifier.Command, ControlModifier.Shift)),
        )
        session.tapPaletteAction(redo)
        assertEquals(CustomLayoutPreviewSession.Feedback.WouldSend("⌘⇧Z"), session.feedback)
        val showDesktop = FunctionTrayProfile.canonical().items.first { it.id == "show-desktop" }.item
        session.tapAction(showDesktop)
        assertEquals(CustomLayoutPreviewSession.Feedback.WouldPerform("Show Desktop"), session.feedback)
        session.reset()
        assertEquals(ControlInteractionState(), session.interaction)
    }

    @Test
    fun testEditorAndRuntimeShareOneGeometryAndSnapOnlyChangesStoredPositions() {
        val area = CGRect(12.0, 36.0, 1170.0, 766.0)
        val point = CGPoint(area.minX + area.width * 0.503, area.minY + area.height * 0.25)
        val free = CustomLayoutGeometry.droppedPosition(point, area, diameter = 44.0, snapToEdges = false, snapToGuides = false)
        assertEquals(0.503, free.x, 0.0001)
        val snapped = CustomLayoutGeometry.droppedPosition(point, area, diameter = 44.0, snapToEdges = false, snapToGuides = true)
        assertEquals(0.5, snapped.x, 0.0)
        assertEquals(0.25, snapped.y, 0.0001)
        val arrangement = CustomControlArrangement.radialTemplate(ControlCorner.TopLeading, portrait = false)
        assertEquals(
            CustomLayoutGeometry.frames(arrangement, area, base),
            CustomLayoutGeometry.frames(arrangement, area, base),
        )
    }

    // endregion

    // region Local View Navigation

    @Test
    fun testVoiceOverStillOverridesEverything() {
        val gate = ReceiverMultiFingerGestureGate(voiceOverRunning = true)
        gate.update(remoteInputAllowed = true, localNavigationAllowed = true)
        for (kind in ReceiverMultiFingerRecognizer.entries) assertFalse(gate.isEnabled(kind))
    }

    // endregion
}
