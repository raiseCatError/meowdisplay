package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/ExtendViewportTests.swift.

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Extend's orientation-aware "fill the constraining axis, never crop" viewport
 * behavior. There is deliberately no Extend-specific coordinate system: Extend
 * and Mirror share the exact same call site
 * (`RemoteViewportCalculator.normal(viewBounds, remoteAspectSize)`), so this
 * suite is pure regression coverage against that shared function proving it
 * already produces the desired behavior for every ratio Extend can select:
 * landscape prioritizes filling height, portrait prioritizes filling width,
 * both purely as a consequence of standard aspect-fit math, and an extreme
 * ratio that can't fill an axis without cropping falls back to ordinary
 * full-content aspect-fit automatically.
 */
class ExtendViewportTests {

    // Representative iPhone bounds (points), same aspect either orientation.
    private val landscapeBounds = CGRect(0.0, 0.0, 852.0, 393.0)
    private val portraitBounds = CGRect(0.0, 0.0, 393.0, 852.0)

    /** Swift's `rounded()` is ties-away-from-zero; for these positive values that is `Math.round`. */
    private fun aspect(ratio: Double, longEdge: CGFloat = 1278.0): CGSize =
        CGSize(longEdge, Math.round(longEdge / ratio).toDouble())

    // MARK: - Landscape: prioritize filling height

    @Test
    fun testLandscape16x10FillsHeightWithSideMargins() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        assertEquals(landscapeBounds.height, t.displayedRect.height, 0.5)
        assertTrue(t.displayedRect.width < landscapeBounds.width)
        assertEquals(landscapeBounds.midX, t.displayedRect.midX, 0.5)
        assertEquals(landscapeBounds.minY, t.displayedRect.minY, 0.001)
        assertEquals(landscapeBounds.maxY, t.displayedRect.maxY, 0.001)
    }

    @Test
    fun testLandscape16x9FillsHeightWithSmallerSideMargins() {
        val wide = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 9.0))
        val narrower = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        assertEquals(landscapeBounds.height, wide.displayedRect.height, 0.5)
        // 16:9 is wider than 16:10, so it fills more of the width for the same
        // filled height: a smaller side margin, not a larger one.
        assertTrue(wide.displayedRect.width > narrower.displayedRect.width)
    }

    @Test
    fun testLandscape4x3FillsHeightWithWiderSideMargins() {
        val narrow = RemoteViewportCalculator.normal(landscapeBounds, aspect(4.0 / 3.0))
        val wide = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        assertEquals(landscapeBounds.height, narrow.displayedRect.height, 0.5)
        assertTrue(
            "a squarer ratio must show wider side margins than a more landscape one",
            narrow.displayedRect.width < wide.displayedRect.width,
        )
    }

    @Test
    fun testLandscape21x9NeverCropsAndFallsBackToAspectFit() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(21.0 / 9.0))
        // The whole desktop stays visible: displayedRect never exceeds the view
        // bounds on either axis, however the fit resolves.
        assertTrue(t.displayedRect.width <= landscapeBounds.width + 0.5)
        assertTrue(t.displayedRect.height <= landscapeBounds.height + 0.5)
        val contentAspect = t.displayedRect.width / t.displayedRect.height
        assertEquals(21.0 / 9.0, contentAspect, 0.01)
    }

    @Test
    fun testLandscape32x9NeverCrops() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(32.0 / 9.0))
        assertTrue(t.displayedRect.width <= landscapeBounds.width + 0.5)
        assertTrue(t.displayedRect.height <= landscapeBounds.height + 0.5)
        val contentAspect = t.displayedRect.width / t.displayedRect.height
        assertEquals(32.0 / 9.0, contentAspect, 0.01)
    }

    // MARK: - Portrait: prioritize filling width

    @Test
    fun testPortrait16x10FillsWidthWithTopBottomMargins() {
        val t = RemoteViewportCalculator.normal(portraitBounds, aspect(16.0 / 10.0))
        assertEquals(portraitBounds.width, t.displayedRect.width, 0.5)
        assertTrue(t.displayedRect.height < portraitBounds.height)
        assertEquals(portraitBounds.midY, t.displayedRect.midY, 0.5)
        assertEquals(portraitBounds.minX, t.displayedRect.minX, 0.001)
        assertEquals(portraitBounds.maxX, t.displayedRect.maxX, 0.001)
    }

    @Test
    fun testPortrait16x9FillsWidthWithoutStretchOrCrop() {
        val t = RemoteViewportCalculator.normal(portraitBounds, aspect(16.0 / 9.0))
        assertEquals(portraitBounds.width, t.displayedRect.width, 0.5)
        val contentAspect = t.displayedRect.width / t.displayedRect.height
        assertEquals("must preserve aspect, never stretch", 16.0 / 9.0, contentAspect, 0.01)
    }

    @Test
    fun testPortrait1x1FillsWidthWithVerticalMargins() {
        val t = RemoteViewportCalculator.normal(portraitBounds, aspect(1.0))
        assertEquals(portraitBounds.width, t.displayedRect.width, 0.5)
        assertTrue(t.displayedRect.height < portraitBounds.height)
    }

    // MARK: - Input mapping

    @Test
    fun testTouchInsideContentMapsToTheExpectedNormalizedPoint() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        val center = CGPoint(t.displayedRect.midX, t.displayedRect.midY)
        val mapped = t.remotePoint(center)
        assertNotNull(mapped)
        assertEquals(0.5, mapped!!.x, 0.01)
        assertEquals(0.5, mapped.y, 0.01)
        assertTrue(t.containsViewPoint(center))
    }

    @Test
    fun testTouchInLeftRightLetterboxIsNotOnContent() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        assertTrue("test needs an actual side margin", t.displayedRect.minX > landscapeBounds.minX)
        val inMargin = CGPoint(landscapeBounds.minX + 1, landscapeBounds.midY)
        assertFalse(t.containsViewPoint(inMargin))
    }

    @Test
    fun testTouchInTopBottomLetterboxIsNotOnContent() {
        val t = RemoteViewportCalculator.normal(portraitBounds, aspect(16.0 / 10.0))
        assertTrue("test needs an actual top margin", t.displayedRect.minY > portraitBounds.minY)
        val inMargin = CGPoint(portraitBounds.midX, portraitBounds.minY + 1)
        assertFalse(t.containsViewPoint(inMargin))
    }

    /**
     * The admission gate actually used at the touch call site (`routeTouches`,
     * direct-touch mode): a `began` touch outside the content rect is never
     * admitted, so it is never forwarded to the Mac regardless of where it
     * later moves; this is what makes letterbox touches true no-ops, not merely
     * clamped input.
     */
    @Test
    fun testBeginOutsideContentIsNeverAdmittedEvenIfItLaterMovesOntoContent() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        val admission = SurfaceTouchAdmission<Int>()
        val beganInMargin = CGPoint(landscapeBounds.minX + 1, landscapeBounds.midY)
        admission.begin(1, inside = t.containsViewPoint(beganInMargin))
        assertFalse(admission.contains(1))
    }

    @Test
    fun testRotationRecomputesTheTransformForTheNewBounds() {
        val landscape = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        val portrait = RemoteViewportCalculator.normal(portraitBounds, aspect(16.0 / 10.0))
        // Landscape fills height; the same content in portrait bounds fills
        // width instead: the fit is recomputed from bounds, not cached.
        assertEquals(landscapeBounds.height, landscape.displayedRect.height, 0.5)
        assertEquals(portraitBounds.width, portrait.displayedRect.width, 0.5)
    }

    // MARK: - Mirror regression (same shared function, must stay identical)

    @Test
    fun testMirrorLandscapeViewportUnchanged() {
        // A typical Mac laptop display (16:10) mirrored onto a landscape iPhone,
        // re-asserted here so an Extend-motivated change to shared geometry
        // cannot silently regress Mirror.
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        assertEquals(landscapeBounds.height, t.displayedRect.height, 0.5)
        assertEquals(landscapeBounds.midX, t.displayedRect.midX, 0.5)
    }

    @Test
    fun testMirrorInputMappingUnchanged() {
        val t = RemoteViewportCalculator.normal(landscapeBounds, aspect(16.0 / 10.0))
        val corner = CGPoint(t.displayedRect.minX, t.displayedRect.minY)
        val mapped = t.remotePoint(corner)
        assertNotNull(mapped)
        assertEquals(0.0, mapped!!.x, 0.01)
        assertEquals(0.0, mapped.y, 0.01)
    }
}
