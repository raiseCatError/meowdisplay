package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/RemoteViewportTests.swift.

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Pure-logic coverage for the M4 keyboard-presentation viewport transform.
 *
 * Product rule under test: whenever the keyboard is open, the likely typing
 * anchor stays visible via vertical-only movement. Zoom While Typing OFF never
 * shrinks below normal scale and never pans horizontally; ON is an additional
 * magnification on top of that same normal scale, so it can never be smaller
 * than OFF, and is likewise vertical-only.
 */
class RemoteViewportTests {

    // A 1:1 aspect remote matching the view bounds exactly keeps the arithmetic
    // in most tests exact and easy to reason about.
    private val squareBounds = CGRect(0.0, 0.0, 400.0, 800.0)
    private val squareAspect = CGSize(400.0, 800.0)

    // MARK: - Keyboard hidden

    @Test
    fun testKeyboardHiddenIsFullAspectFitWithNoCrop() {
        val t = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        assertEquals(CGRect(0.0, 0.0, 1.0, 1.0), t.remoteCrop)
        assertEquals(squareBounds, t.displayedRect)
    }

    @Test
    fun testKeyboardHiddenLetterboxesAMismatchedAspectRatio() {
        // Landscape 16:9 remote into a portrait phone view -> letterboxed
        // top/bottom, full width, centered.
        val bounds = CGRect(0.0, 0.0, 390.0, 844.0)
        val t = RemoteViewportCalculator.normal(bounds, CGSize(1920.0, 1080.0))
        assertEquals(390.0, t.displayedRect.width, 0.001)
        assertTrue(t.displayedRect.height < bounds.height)
        assertEquals(bounds.midX, t.displayedRect.midX, 0.001)
        assertEquals(bounds.midY, t.displayedRect.midY, 0.001)
    }

    // MARK: - Zoom While Typing OFF: never shrinks, vertical-only

    @Test
    fun testZoomOffMatchesNormalScaleExactly() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0) // keyboard ate the bottom 300
        // y=0.85, not 1.0: there's enough slack for pure translation to reach
        // the comfort margin here (verified separately below for the
        // genuinely-insufficient case).
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.85), zoomEnabled = false,
        )
        assertEquals("must start from the exact normal scale", normal.displayedRect.size, t.displayedRect.size)
    }

    @Test
    fun testZoomOffNeverHorizontallyTranslates() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        for (anchor in listOf(CGPoint(0.02, 0.9), CGPoint(0.98, 0.9), CGPoint(0.5, 0.1))) {
            val t = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = anchor, zoomEnabled = false,
            )
            assertEquals(
                "anchor.x (${anchor.x}) must never move the horizontal position",
                normal.displayedRect.minX, t.displayedRect.minX, 0.001,
            )
        }
    }

    @Test
    fun testZoomOffMovesTheAnchorIntoTheFreeViewport() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0) // keyboard covers y >= 500
        val anchor = CGPoint(0.5, 0.98) // near the bottom of the remote display
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = anchor, zoomEnabled = false,
        )
        val anchorView = t.viewPoint(anchor)
        assertTrue("anchor must land above the keyboard", anchorView.y <= visible.maxY)
        assertTrue(anchorView.y >= visible.minY)
    }

    @Test
    fun testZoomOffDoesNothingWhenTheAnchorIsAlreadyComfortablyVisible() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val anchor = CGPoint(0.5, 0.3) // well within the free viewport already
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = anchor, zoomEnabled = false,
        )
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        assertEquals("no unnecessary panning", normal.displayedRect, t.displayedRect)
    }

    @Test
    fun testZoomOffPanClampingNeverExposesBlankSpaceBeyondContentEdges() {
        val visible = CGRect(0.0, 0.0, 400.0, 780.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.999), zoomEnabled = false,
        )
        assertTrue(t.displayedRect.maxY <= visible.maxY + 0.001)
        assertTrue(t.displayedRect.minY <= 0.001)
    }

    // MARK: - Zoom While Typing ON: never smaller than OFF, vertical-only

    @Test
    fun testZoomOnScaleIsNeverSmallerThanZoomOff() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        for (anchorY in listOf(0.05, 0.5, 0.95)) {
            val off = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = CGPoint(0.5, anchorY), zoomEnabled = false,
            )
            val on = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = CGPoint(0.5, anchorY), zoomEnabled = true,
            )
            assertTrue("anchorY $anchorY", on.displayedRect.width >= off.displayedRect.width)
            assertTrue("anchorY $anchorY", on.displayedRect.height >= off.displayedRect.height)
        }
    }

    @Test
    fun testZoomOnNeverShrinksBelowNormalScale() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        // Even a barely-covering keyboard must not make Zoom ON smaller than
        // normal; this is the exact real-device regression.
        val visible = CGRect(0.0, 0.0, 400.0, 790.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        assertTrue(t.displayedRect.width >= normal.displayedRect.width - 0.001)
        assertTrue(t.displayedRect.height >= normal.displayedRect.height - 0.001)
    }

    @Test
    fun testZoomOnMagnifiesAboveNormalWhenKeyboardCoversMeaningfulArea() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0) // keyboard covers a large fraction
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        assertTrue("should actually magnify, not merely match", t.displayedRect.width > normal.displayedRect.width)
    }

    @Test
    fun testZoomOnIsCappedAtTheConfiguredMaximum() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 61.0) // just above the minimum-usable floor
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true, maxZoom = 1.5,
        )
        assertEquals(normal.displayedRect.width * 1.5, t.displayedRect.width, 0.01)
    }

    @Test
    fun testZoomOnNeverHorizontallyTranslatesOrChasesTheAnchor() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        for (anchorX in listOf(0.02, 0.5, 0.98)) {
            val t = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = CGPoint(anchorX, 0.5), zoomEnabled = true,
            )
            assertEquals(
                "anchor.x ($anchorX) must never move the horizontal center",
                normal.displayedRect.midX, t.displayedRect.midX, 0.001,
            )
        }
    }

    @Test
    fun testZoomOnRemainsStableAcrossKeyboardHeightChangesLikeSwitchingToEmoji() {
        // A meaningfully taller keyboard (e.g. the emoji keyboard, or one with a
        // predictive bar) must not suddenly shrink the display; the magnified
        // scale may adjust, but never below normal.
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val normalKeyboardVisible = CGRect(0.0, 0.0, 400.0, 550.0)
        val emojiKeyboardVisible = CGRect(0.0, 0.0, 400.0, 480.0) // taller keyboard
        val beforeSwitch = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = normalKeyboardVisible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        val afterSwitch = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = emojiKeyboardVisible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        assertTrue(beforeSwitch.displayedRect.width >= normal.displayedRect.width - 0.001)
        assertTrue(afterSwitch.displayedRect.width >= normal.displayedRect.width - 0.001)
    }

    // MARK: - Anchor position (top / center / bottom)

    @Test
    fun testAnchorNearTopIsBroughtIntoView() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        for (zoomEnabled in listOf(false, true)) {
            val t = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = CGPoint(0.5, 0.02), zoomEnabled = zoomEnabled,
            )
            val anchorView = t.viewPoint(CGPoint(0.5, 0.02))
            assertTrue("zoomEnabled $zoomEnabled", anchorView.y >= visible.minY - 0.5)
            assertTrue("zoomEnabled $zoomEnabled", anchorView.y <= visible.maxY + 0.5)
        }
    }

    @Test
    fun testAnchorNearCenterNeedsNoAdjustment() {
        val visible = CGRect(0.0, 0.0, 400.0, 700.0) // generous free viewport
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.5), zoomEnabled = false,
        )
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        assertEquals(normal.displayedRect, t.displayedRect)
    }

    @Test
    fun testAnchorNearBottomIsBroughtIntoView() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        for (zoomEnabled in listOf(false, true)) {
            val t = RemoteViewportCalculator.keyboardOpen(
                viewBounds = squareBounds, remoteAspectSize = squareAspect,
                visibleRect = visible, anchor = CGPoint(0.5, 0.98), zoomEnabled = zoomEnabled,
            )
            val anchorView = t.viewPoint(CGPoint(0.5, 0.98))
            assertTrue("zoomEnabled $zoomEnabled", anchorView.y <= visible.maxY + 0.5)
        }
    }

    // MARK: - No-anchor default (vertical center, not a shrink fallback)

    @Test
    fun testNoAnchorDefaultsToVerticalCenterWithoutShrinking() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = null, zoomEnabled = false,
        )
        assertEquals("no anchor is ordinary behavior, not a fallback", normal.displayedRect.size, t.displayedRect.size)
    }

    @Test
    fun testOutOfRangeAnchorFallsBackToVerticalCenterWithoutShrinking() {
        val normal = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 42.0), zoomEnabled = false,
        )
        assertEquals(normal.displayedRect.size, t.displayedRect.size)
    }

    // MARK: - Preference toggle while keyboard is already open

    @Test
    fun testTogglingZoomWhileTypingChangesOnlyScaleNotVerticalIntent() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val anchor = CGPoint(0.5, 0.9)
        val off = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = anchor, zoomEnabled = false,
        )
        val on = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = anchor, zoomEnabled = true,
        )
        // Both keep the same anchor visible above the keyboard regardless of the toggle.
        for (t in listOf(off, on)) {
            val anchorView = t.viewPoint(anchor)
            assertTrue(anchorView.y <= visible.maxY + 0.5)
        }
        assertTrue(on.displayedRect.width >= off.displayedRect.width)
    }

    // MARK: - Too-small viewport falls back safely (genuinely invalid geometry only)

    @Test
    fun testViewportBelowMinimumUsableHeightFallsBackToFitEverything() {
        val visible = CGRect(0.0, 0.0, 400.0, 10.0) // well under the floor
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        assertEquals(CGRect(0.0, 0.0, 1.0, 1.0), t.remoteCrop)
        assertTrue(t.displayedRect.height <= visible.height + 0.001)
    }

    // MARK: - Invalid geometry safety

    @Test
    fun testZeroSizedViewBoundsProducesNoNaN() {
        val t = RemoteViewportCalculator.normal(CGRect.zero, squareAspect)
        assertFalse(t.isValid)
        assertFalse(t.displayedRect.origin.x.isNaN())
        assertFalse(t.displayedRect.width.isNaN())
    }

    @Test
    fun testZeroRemoteAspectSizeProducesNoNaN() {
        val t = RemoteViewportCalculator.normal(squareBounds, CGSize.zero)
        assertFalse(t.isValid)
        assertFalse(t.displayedRect.width.isNaN())
    }

    @Test
    fun testInvalidTransformMapsSafelyWithoutNaN() {
        val t = RemoteViewportTransform.invalid
        assertNull(t.remotePoint(CGPoint(10.0, 10.0)))
        assertEquals(CGPoint.zero, t.viewPoint(CGPoint(0.5, 0.5)))
        assertFalse(t.containsViewPoint(CGPoint(0.0, 0.0)))
    }

    @Test
    fun testKeyboardOpenWithZeroVisibleRectFallsBackToNormal() {
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = CGRect.zero, anchor = CGPoint(0.5, 0.5), zoomEnabled = true,
        )
        assertEquals(RemoteViewportCalculator.normal(squareBounds, squareAspect), t)
    }

    // MARK: - Forward (remote -> view) and inverse (view -> remote) mapping

    @Test
    fun testForwardAndInverseMappingRoundTripUnderZoom() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.3, 0.4), zoomEnabled = true,
        )
        val remotePoint = CGPoint(0.32, 0.42)
        val viewPoint = t.viewPoint(remotePoint)
        val back = t.remotePoint(viewPoint) ?: return fail("expected a valid inverse mapping")
        assertEquals(remotePoint.x, back.x, 0.0005)
        assertEquals(remotePoint.y, back.y, 0.0005)
    }

    @Test
    fun testForwardAndInverseMappingRoundTripUnderPan() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.95), zoomEnabled = false,
        )
        val remotePoint = CGPoint(0.5, 0.9)
        val viewPoint = t.viewPoint(remotePoint)
        val back = t.remotePoint(viewPoint) ?: return fail("expected a valid inverse mapping")
        assertEquals(remotePoint.x, back.x, 0.0005)
        assertEquals(remotePoint.y, back.y, 0.0005)
    }

    @Test
    fun testATappedRemoteLocationMapsToTheExactSameViewPointItWasDrawnAt() {
        // A visible Mac control tapped while zoomed/panned must still receive
        // input at that exact Mac location: the cursor-sprite path (viewPoint)
        // and the touch-input path (remotePoint) must agree.
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.6, 0.7), zoomEnabled = true,
        )
        val controlLocation = CGPoint(0.62, 0.71)
        val drawnAt = t.viewPoint(controlLocation)
        assertTrue(t.containsViewPoint(drawnAt))
        val tappedBack = t.remotePoint(drawnAt) ?: return fail("expected a valid inverse mapping")
        assertEquals(controlLocation.x, tappedBack.x, 0.0005)
        assertEquals(controlLocation.y, tappedBack.y, 0.0005)
    }

    // MARK: - Portrait / landscape

    @Test
    fun testPortraitAndLandscapeBothProduceValidGeometry() {
        val portrait = CGRect(0.0, 0.0, 390.0, 844.0)
        val landscape = CGRect(0.0, 0.0, 844.0, 390.0)
        val aspect = CGSize(1920.0, 1080.0)
        for (bounds in listOf(portrait, landscape)) {
            val visible = CGRect(0.0, 0.0, bounds.width, bounds.height * 0.6)
            val t = RemoteViewportCalculator.keyboardOpen(
                viewBounds = bounds, remoteAspectSize = aspect,
                visibleRect = visible, anchor = CGPoint(0.5, 0.9), zoomEnabled = true,
            )
            assertTrue("bounds $bounds", t.isValid)
            assertFalse(t.displayedRect.origin.x.isNaN())
        }
    }

    // MARK: - Minimal-necessary-scale fallback (the portrait regression)

    // A realistic portrait phone: tall/narrow viewport, a widescreen remote
    // display (letterboxed to a modest horizontal band well inside a typical
    // keyboard-free area), keyboard consuming roughly half the height, anchor
    // near the bottom of the Mac display. Translation alone is expected to
    // suffice here; this is the exact shape of geometry the original portrait
    // bug was reported against.
    private val portraitBounds = CGRect(0.0, 0.0, 390.0, 844.0)
    private val widescreenAspect = CGSize(1920.0, 1080.0)
    // A less letterboxed aspect ratio, so a genuinely-too-small visible
    // viewport can be constructed to exercise the scale-reduction path.
    private val standardAspect = CGSize(1024.0, 768.0)

    @Test
    fun testPortraitBottomAnchorNormalScaleSufficient() {
        val visible = CGRect(0.0, 0.0, 390.0, 422.0) // keyboard ~ half the height
        val normal = RemoteViewportCalculator.normal(portraitBounds, widescreenAspect)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = widescreenAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.95), zoomEnabled = false,
        )
        assertEquals("translation alone should suffice here", normal.displayedRect.size, t.displayedRect.size)
        val anchorView = t.viewPoint(CGPoint(0.5, 0.95))
        assertTrue(anchorView.y <= visible.maxY + 0.5)
        assertTrue(anchorView.y >= visible.minY - 0.5)
    }

    @Test
    fun testPortraitBottomAnchorNormalScaleInsufficientTriggersMinimalShrink() {
        // A shorter, less-letterboxed (4:3) remote and a short keyboard-free
        // viewport with the anchor at the very bottom edge: translation alone
        // provably cannot reach the comfort margin, so this must shrink, but
        // only as much as necessary.
        val visible = CGRect(0.0, 0.0, 390.0, 250.0)
        val normal = RemoteViewportCalculator.normal(portraitBounds, standardAspect)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 1.0), zoomEnabled = false,
        )
        assertTrue("must actually shrink here", t.displayedRect.height < normal.displayedRect.height)
        val anchorView = t.viewPoint(CGPoint(0.5, 1.0))
        assertTrue("the anchor must end up visible after shrinking", anchorView.y <= visible.maxY + 0.5)
        assertTrue(anchorView.y >= visible.minY - 0.5)
    }

    @Test
    fun testMinimalShrinkStaysWellAboveTheFloorWhenOnlyAModestReductionIsNeeded() {
        // A geometry that does need some shrink (translation alone isn't enough
        // at normal scale) but only a modest one: the search for the minimal
        // necessary scale must land close to 1, not jump to the aggressive
        // `minimumScaleFactor` floor.
        val visible = CGRect(0.0, 0.0, 390.0, 250.0)
        val normal = RemoteViewportCalculator.normal(portraitBounds, standardAspect)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.9), zoomEnabled = false,
        )
        assertTrue("this geometry must still require some shrink", t.displayedRect.height < normal.displayedRect.height)
        assertTrue(
            "a minimal shrink must stay well clear of the aggressive floor",
            t.displayedRect.height > normal.displayedRect.height * 0.7,
        )
    }

    @Test
    fun testLandscapeCaseRemainsAtNormalScale() {
        val landscapeBounds = CGRect(0.0, 0.0, 844.0, 390.0)
        val normal = RemoteViewportCalculator.normal(landscapeBounds, widescreenAspect)
        val visible = CGRect(0.0, 0.0, 844.0, 220.0) // keyboard covers a modest landscape band
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = landscapeBounds, remoteAspectSize = widescreenAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.9), zoomEnabled = false,
        )
        assertEquals("landscape must not regress into shrinking", normal.displayedRect.size, t.displayedRect.size)
    }

    @Test
    fun testTallerEmojiKeyboardCausesOnlyTheAdditionallyRequiredShrink() {
        val normalKeyboard = CGRect(0.0, 0.0, 390.0, 260.0)
        val emojiKeyboard = CGRect(0.0, 0.0, 390.0, 210.0) // taller keyboard, shorter visible area
        val anchor = CGPoint(0.5, 1.0)
        val withNormalKeyboard = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = normalKeyboard, anchor = anchor, zoomEnabled = false,
        )
        val withEmojiKeyboard = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = emojiKeyboard, anchor = anchor, zoomEnabled = false,
        )
        assertTrue(
            "a taller keyboard must never grow the display",
            withEmojiKeyboard.displayedRect.height <= withNormalKeyboard.displayedRect.height + 0.01,
        )
        // Still visible under the taller keyboard, not just smaller.
        val anchorView = withEmojiKeyboard.viewPoint(anchor)
        assertTrue(anchorView.y <= emojiKeyboard.maxY + 0.5)
    }

    @Test
    fun testShorterKeyboardRestoresScaleTowardNormal() {
        val normal = RemoteViewportCalculator.normal(portraitBounds, standardAspect)
        val shortVisible = CGRect(0.0, 0.0, 390.0, 250.0) // forces a shrink
        val tallVisible = CGRect(0.0, 0.0, 390.0, 600.0) // keyboard dismissed most of the way
        val anchor = CGPoint(0.5, 1.0)
        val shrunk = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = shortVisible, anchor = anchor, zoomEnabled = false,
        )
        val restored = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = tallVisible, anchor = anchor, zoomEnabled = false,
        )
        assertTrue(shrunk.displayedRect.height < normal.displayedRect.height)
        assertTrue(
            "a taller keyboard-free area must restore scale back toward normal",
            restored.displayedRect.height > shrunk.displayedRect.height,
        )
    }

    @Test
    fun testForwardAndInverseMappingRemainCorrectUnderTheMinimalShrinkFallback() {
        val visible = CGRect(0.0, 0.0, 390.0, 250.0)
        val t = RemoteViewportCalculator.keyboardOpen(
            viewBounds = portraitBounds, remoteAspectSize = standardAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 1.0), zoomEnabled = false,
        )
        val remotePoint = CGPoint(0.4, 0.9)
        val viewPoint = t.viewPoint(remotePoint)
        val back = t.remotePoint(viewPoint) ?: return fail("expected a valid inverse mapping under the shrink fallback")
        assertEquals(remotePoint.x, back.x, 0.0005)
        assertEquals(remotePoint.y, back.y, 0.0005)
    }

    // MARK: - Manual viewport zoom/pan

    @Test
    fun testIdentityManualStateReturnsBaseTransformUnchanged() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val result = RemoteViewportCalculator.applyManualZoom(base, ManualViewportState.identity)
        assertEquals("identity manual state must be an exact pass-through, not merely numerically equal", base, result)
    }

    @Test
    fun testManualZoomAboveOneMagnifiesTheDisplayedRect() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val state = ManualViewportState(scale = 2.0, panX = 0.0, panY = 0.0)
        val result = RemoteViewportCalculator.applyManualZoom(base, state)
        assertEquals(base.displayedRect.width * 2, result.displayedRect.width, 0.001)
        assertEquals(base.displayedRect.height * 2, result.displayedRect.height, 0.001)
    }

    @Test
    fun testManualScaleClampsBelowOneUpToOne() {
        val clamped = ManualViewportState(scale = 0.3, panX = 0.0, panY = 0.0).clamped(squareBounds)
        assertEquals(1.0, clamped.scale, 0.0)
    }

    @Test
    fun testManualScaleClampsAtMaximum() {
        val clamped = ManualViewportState(scale = 10.0, panX = 0.0, panY = 0.0).clamped(squareBounds)
        assertEquals(ManualViewportState.maxScale, clamped.scale, 0.0)
    }

    @Test
    fun testMinimumScaleKeepsPanWithinHalfTheContent() {
        // 100% no longer forces the view back to center; an edge may reach the
        // viewport's center and no further.
        val clamped = ManualViewportState(scale = 1.0, panX = 999.0, panY = -999.0).clamped(squareBounds)
        assertEquals(squareBounds.width / 2, clamped.panX, 0.0)
        assertEquals(-squareBounds.height / 2, clamped.panY, 0.0)
    }

    @Test
    fun testZoomedPanStopsWhenAnEdgeReachesTheViewportCenter() {
        val state = ManualViewportState(scale = 2.0, panX = 10_000.0, panY = -10_000.0)
        val clamped = state.clamped(squareBounds)
        val width = squareBounds.width * clamped.scale
        val height = squareBounds.height * clamped.scale
        assertEquals(width / 2, clamped.panX, 0.001)
        assertEquals(-height / 2, clamped.panY, 0.001)
    }

    @Test
    fun testPinchZoomsAroundTheGestureMidpoint() {
        val base = squareBounds // 400x800
        val midpoint = CGPoint(base.midX, base.midY)
        val result = ManualViewportState.pinching(
            from = ManualViewportState.identity, initialBase = base,
            initialMidpoint = midpoint, currentMidpoint = midpoint, scaleRatio = 2.0,
        )
        assertEquals(2.0, result.scale, 0.001)
        // Pinching around dead-center keeps the content centered, i.e. no pan.
        assertEquals(0.0, result.panX, 0.5)
        assertEquals(0.0, result.panY, 0.5)
    }

    @Test
    fun testPinchKeepsContentUnderAnOffCenterMidpointApproximatelyFixed() {
        val base = squareBounds
        val anchor = CGPoint(base.minX + 100, base.minY + 200) // off-center
        val start = ManualViewportState.pinching(
            from = ManualViewportState.identity, initialBase = base,
            initialMidpoint = anchor, currentMidpoint = anchor, scaleRatio = 1.8,
        )
        val baseTransform = RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), base)
        val zoomed = RemoteViewportCalculator.applyManualZoom(baseTransform, start)
        // The content that sat under `anchor` before zooming should still be
        // very close to `anchor` after, up to whatever clamping required.
        val remoteUnderAnchorBefore = baseTransform.remotePoint(anchor) ?: return fail("expected a valid pre-zoom mapping")
        val viewPointAfter = zoomed.viewPoint(remoteUnderAnchorBefore)
        assertEquals(anchor.x, viewPointAfter.x, 1.0)
        assertEquals(anchor.y, viewPointAfter.y, 1.0)
    }

    @Test
    fun testPanWhileZoomedTranslatesTheDisplayedRect() {
        val base = squareBounds
        val zoomedIn = ManualViewportState(scale = 2.0, panX = 0.0, panY = 0.0)
        val start = CGPoint(base.midX, base.midY)
        val dragged = CGPoint(base.midX + 20, base.midY - 15)
        val panned = ManualViewportState.pinching(
            from = zoomedIn, initialBase = base,
            initialMidpoint = start, currentMidpoint = dragged, scaleRatio = 1.0,
        )
        assertEquals("a pure drag must not also change scale", zoomedIn.scale, panned.scale, 0.001)
        assertEquals(20.0, panned.panX, 0.5)
        assertEquals(-15.0, panned.panY, 0.5)
    }

    @Test
    fun testResetToIdentityReturnsExactlyToTheBaseTransform() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        var state = ManualViewportState(scale = 2.4, panX = 30.0, panY = -12.0)
        assertNotEquals(base, RemoteViewportCalculator.applyManualZoom(base, state))
        state = ManualViewportState.identity
        assertEquals(base, RemoteViewportCalculator.applyManualZoom(base, state))
    }

    @Test
    fun testManualZoomRecomputesValidlyAfterAnOrientationChange() {
        // A state clamped/valid in portrait must still clamp to something finite
        // and valid once the base rect changes shape (rotation).
        val portrait = CGRect(0.0, 0.0, 390.0, 844.0)
        val landscape = CGRect(0.0, 0.0, 844.0, 390.0)
        val state = ManualViewportState(scale = 2.5, panX = 150.0, panY = 300.0).clamped(portrait)
        val recomputed = state.clamped(landscape)
        assertTrue(recomputed.scale.isFinite() && recomputed.panX.isFinite() && recomputed.panY.isFinite())
        assertTrue(recomputed.scale >= ManualViewportState.minScale)
        assertTrue(recomputed.scale <= ManualViewportState.maxScale)
    }

    @Test
    fun testManualZoomComposesOnTopOfTheKeyboardOpenPresentation() {
        val visible = CGRect(0.0, 0.0, 400.0, 500.0)
        val base = RemoteViewportCalculator.keyboardOpen(
            viewBounds = squareBounds, remoteAspectSize = squareAspect,
            visibleRect = visible, anchor = CGPoint(0.5, 0.9), zoomEnabled = false,
        )
        val manual = ManualViewportState(scale = 1.5, panX = 0.0, panY = 0.0)
        val result = RemoteViewportCalculator.applyManualZoom(base, manual)
        assertTrue(result.isValid)
        assertEquals(
            "manual zoom must magnify the keyboard-adjusted rect, not replace it",
            base.displayedRect.width * 1.5, result.displayedRect.width, 0.001,
        )
    }

    @Test
    fun testManualZoomNeverProducesNaNOrInvalidGeometry() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        for (scale in listOf(-5.0, 0.0, 0.001, 1.0, 1.5, 3.0, 999.0)) {
            for (pan in listOf(-1e6, 0.0, 1e6)) {
                val state = ManualViewportState(scale = scale, panX = pan, panY = pan)
                val result = RemoteViewportCalculator.applyManualZoom(base, state)
                assertFalse(result.displayedRect.origin.x.isNaN())
                assertFalse(result.displayedRect.origin.y.isNaN())
                assertFalse(result.displayedRect.width.isNaN())
                assertFalse(result.displayedRect.height.isNaN())
            }
        }
    }

    @Test
    fun testForwardAndInverseMappingRemainCorrectUnderManualZoomAndPan() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val state = ManualViewportState(scale = 2.0, panX = 30.0, panY = -20.0).clamped(base.displayedRect)
        val t = RemoteViewportCalculator.applyManualZoom(base, state)
        for (remotePoint in listOf(CGPoint(0.1, 0.2), CGPoint(0.5, 0.5), CGPoint(0.9, 0.8))) {
            val viewPoint = t.viewPoint(remotePoint)
            val back = t.remotePoint(viewPoint) ?: return fail("expected a valid inverse mapping under manual zoom/pan")
            assertEquals(remotePoint.x, back.x, 0.0005)
            assertEquals(remotePoint.y, back.y, 0.0005)
        }
    }

    @Test
    fun testForwardAndInverseMappingRemainCorrectUnderCombinedTransform() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val state = ManualViewportState(scale = 2.0, panX = 30.0, panY = -20.0, rotationRadians = PI / 3)
        val transform = RemoteViewportCalculator.applyManualZoom(base, state)
        for (remote in listOf(CGPoint(0.1, 0.2), CGPoint(0.5, 0.5), CGPoint(0.9, 0.8))) {
            val view = transform.viewPoint(remote)
            val mapped = transform.remotePoint(view)
            assertNotNull(mapped)
            assertEquals(remote.x, mapped?.x ?: Double.NEGATIVE_INFINITY, 0.0005)
            assertEquals(remote.y, mapped?.y ?: Double.NEGATIVE_INFINITY, 0.0005)
        }
    }

    @Test
    fun testPinchPanAndRotationPreserveGestureAnchor() {
        val initial = ManualViewportState(scale = 1.4, panX = 15.0, panY = -10.0, rotationRadians = PI / 8)
        val start = CGPoint(420.0, 470.0)
        val current = CGPoint(445.0, 450.0)
        val result = ManualViewportState.pinching(
            from = initial, initialBase = squareBounds,
            initialMidpoint = start, currentMidpoint = current,
            scaleRatio = 1.25, rotationDelta = PI / 6,
        )
        val before = RemoteViewportCalculator.applyManualZoom(
            RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), squareBounds), initial,
        )
        val after = RemoteViewportCalculator.applyManualZoom(
            RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), squareBounds), result,
        )
        val remote = before.remotePoint(start)!!
        val anchored = after.viewPoint(remote)
        assertEquals(current.x, anchored.x, 1.0)
        assertEquals(current.y, anchored.y, 1.0)
    }

    @Test
    fun testRotationSnapEngagesOnceInsideSevenDegreeZone() {
        val nearQuarter = ViewportRotationSnap.snappedAngle(84 * PI / 180, enabled = true)
        assertEquals(PI / 2, nearQuarter.angle, 0.0001)
        assertEquals(1, nearQuarter.targetQuarter)
        assertNull(ViewportRotationSnap.snappedAngle(80 * PI / 180, enabled = true).targetQuarter)
        assertNull(ViewportRotationSnap.snappedAngle(89 * PI / 180, enabled = false).targetQuarter)
    }

    @Test
    fun testVideoOffIgnoresButPreservesManualViewportState() {
        val base = RemoteViewportCalculator.normal(squareBounds, squareAspect)
        val stored = ManualViewportState(scale = 2.0, panX = 40.0, panY = -25.0, rotationRadians = PI / 2)
        assertEquals(base, VideoInteractionPolicy.viewportTransform(base, stored, videoEnabled = false))
        assertEquals(
            RemoteViewportCalculator.applyManualZoom(base, stored),
            VideoInteractionPolicy.viewportTransform(base, stored, videoEnabled = true),
        )
        assertEquals(PI / 2, stored.rotationRadians, 0.0)
    }

    @Test
    fun testVideoOffForcesEffectiveAppTargetsWithoutChangingStoredValue() {
        val stored = ReceiverGestureTarget.Viewport
        assertEquals(ReceiverGestureTarget.App, VideoInteractionPolicy.effectiveTarget(stored, videoEnabled = false))
        assertEquals(ReceiverGestureTarget.Viewport, VideoInteractionPolicy.effectiveTarget(stored, videoEnabled = true))
        assertEquals(ReceiverGestureTarget.Viewport, stored)
    }

    /**
     * Disabled must be a true no-op: unlike `.viewport`, turning video off must
     * never promote it into `.app` (that would fire a keyboard command the user
     * explicitly asked to disable).
     */
    @Test
    fun testDisabledGestureTargetNeverPromotesToApp() {
        assertEquals(
            ReceiverGestureTarget.Disabled,
            VideoInteractionPolicy.effectiveTarget(ReceiverGestureTarget.Disabled, videoEnabled = false),
        )
        assertEquals(
            ReceiverGestureTarget.Disabled,
            VideoInteractionPolicy.effectiveTarget(ReceiverGestureTarget.Disabled, videoEnabled = true),
        )
    }

    /**
     * Backward compatibility: `ReceiverGestureTarget` gained `.disabled` after
     * `.viewport`/`.app` shipped and persisted. Previously-stored raw values
     * must keep decoding to the same cases.
     */
    @Test
    fun testReceiverGestureTargetDecodesPreviouslyPersistedRawValues() {
        assertEquals(ReceiverGestureTarget.Viewport, ReceiverGestureTarget.of("viewport"))
        assertEquals(ReceiverGestureTarget.App, ReceiverGestureTarget.of("app"))
        assertEquals(ReceiverGestureTarget.Disabled, ReceiverGestureTarget.of("disabled"))
    }

    @Test
    fun testSurfaceAdmissionRejectsOutsideBeginAndKeepsInsideSequenceOutside() {
        val admission = SurfaceTouchAdmission<Int>()
        admission.begin(1, inside = false)
        assertFalse(admission.contains(1))
        admission.begin(2, inside = true)
        assertTrue("movement outside must not cancel a sequence admitted at begin", admission.contains(2))
        admission.end(2)
        assertFalse(admission.contains(2))
    }

    @Test
    fun testDoubleTapResetRestoreIncludesRotation() {
        val transformed = ManualViewportState(scale = 1.8, panX = 20.0, panY = -15.0, rotationRadians = PI / 2)
        val reset = ViewportResetRestorePolicy.toggled(transformed, null, squareBounds)!!
        assertEquals(ManualViewportState.identity, reset.current)
        val restored = ViewportResetRestorePolicy.toggled(reset.current, reset.memory, squareBounds)!!
        assertEquals(PI / 2, restored.current.rotationRadians, 0.0001)
        assertEquals(transformed.scale, restored.current.scale, 0.0001)
    }
}

/**
 * Local pinch-to-zoom up to 8x: geometry stays finite, the content under the
 * fingers stays put, touches still land on the right Mac point, and pan,
 * rotation and reset keep working at every magnification.
 */
class HighMagnificationViewportTests {
    /** The un-zoomed presentation of a 16:10 Mac on a portrait iPhone. */
    private val portraitBase = RemoteViewportCalculator.normal(
        CGRect(0.0, 0.0, 402.0, 874.0), CGSize(1728.0, 1080.0),
    )
    private val scales = listOf(1.0, 3.0, 4.0, 6.0, 8.0)

    private fun zoomed(state: ManualViewportState, base: RemoteViewportTransform? = null): RemoteViewportTransform =
        RemoteViewportCalculator.applyManualZoom(base ?: portraitBase, state)

    private fun assertFinite(rect: CGRect) {
        assertTrue(listOf(rect.minX, rect.minY, rect.width, rect.height).all { it.isFinite() })
        assertTrue(rect.width > 0)
        assertTrue(rect.height > 0)
    }

    /**
     * Whether `point` lies on the displayed (rotated) picture, edges included:
     * the clamp lets an edge travel exactly to the center, which `CGRect.contains`
     * (open at the max edges) would count as off.
     */
    private fun isOnPicture(point: CGPoint, transform: RemoteViewportTransform): Boolean {
        val rect = transform.displayedRect
        val dx = point.x - rect.midX
        val dy = point.y - rect.midY
        val c = cos(-transform.rotationRadians)
        val s = sin(-transform.rotationRadians)
        val tolerance = 1e-6
        return abs(dx * c - dy * s) <= rect.width / 2 + tolerance &&
            abs(dx * s + dy * c) <= rect.height / 2 + tolerance
    }

    /**
     * How far inside the picture's nearest edge the view's center sits for
     * `state` as given, without clamping it: negative means off the picture.
     */
    private fun edgeGap(state: ManualViewportState, rotation: Double, base: CGRect): Double {
        val c = cos(-rotation)
        val s = sin(-rotation)
        val localX = -state.panX * c + state.panY * s
        val localY = -state.panX * s - state.panY * c
        return min(base.width * state.scale / 2 - abs(localX), base.height * state.scale / 2 - abs(localY))
    }

    /**
     * The clamp at any angle, not only quarter turns: the view's center always
     * ends up on the picture, a pan already on it is kept exactly, a pan that
     * was off it lands on the picture's edge (give or take the 0.01pt rest
     * snap), and clamping twice changes nothing. The grid includes near-zero
     * components, where the rest snap meets the edge.
     */
    @Test
    fun testClampKeepsTheCenterOnThePictureAtArbitraryAngles() {
        val base = portraitBase.displayedRect
        val center = CGPoint(base.midX, base.midY)
        val fractions = listOf(-1.5, -1.05, -0.7, -0.45, -0.2, 0.0, 0.2, 0.45, 0.7, 1.05, 1.5)
        val degreesList = (0..48).map { -180.0 + it * 7.5 } + listOf(0.1, -1.0, 44.9, 89.9)
        for (degrees in degreesList) {
            val rotation = degrees * PI / 180
            for (scale in scales) {
                val reach = base.width * scale
                val offsets = fractions.map { it * reach } + listOf(-0.004, 0.004)
                for (panX in offsets) {
                    for (panY in offsets) {
                        val state = ManualViewportState(scale = scale, panX = panX, panY = panY, rotationRadians = rotation)
                        val clamped = state.clamped(base)
                        val transform = zoomed(clamped)
                        assertTrue("$degrees° $scale× $state", isOnPicture(center, transform))
                        assertEquals("$degrees° $scale×", clamped, clamped.clamped(base))
                        val before = edgeGap(state, clamped.rotationRadians, base)
                        if (before >= 0 && abs(state.panX) >= 0.01 && abs(state.panY) >= 0.01) {
                            assertEquals("$degrees° $scale×", state.panX, clamped.panX, 0.0)
                            assertEquals("$degrees° $scale×", state.panY, clamped.panY, 0.0)
                        } else if (before < 0) {
                            // Clamped onto the edge, not pulled further in.
                            val after = edgeGap(clamped, clamped.rotationRadians, base)
                            assertTrue("$degrees° $scale× $state", after >= -1e-6)
                            assertTrue("$degrees° $scale× $state", after <= 0.01)
                        }
                    }
                }
            }
        }
    }

    /**
     * The pre-existing failure the rotated-frame clamp fixes: tilted 30 degrees,
     * zoomed and dragged far along a diagonal, the bounding-box limits let the
     * whole picture leave the screen.
     */
    @Test
    fun testTiltedDiagonalExtremePanNoLongerLosesThePicture() {
        val base = portraitBase.displayedRect
        val center = CGPoint(base.midX, base.midY)
        for (scale in scales) {
            val state = ManualViewportState(scale = scale, panX = 1e6, panY = 1e6, rotationRadians = PI / 6)
                .clamped(base)
            assertTrue("$scale×", isOnPicture(center, zoomed(state)))
        }
    }

    @Test
    fun testMaximumManualZoomIsEightTimesAndClampsAbove() {
        assertEquals(8.0, ManualViewportState.maxScale, 0.0)
        val over = ManualViewportState(scale = 50.0).clamped(portraitBase.displayedRect)
        assertEquals(8.0, over.scale, 0.0)
        assertEquals(1.0, ManualViewportState(scale = 0.2).clamped(portraitBase.displayedRect).scale, 0.0)
        assertEquals(1.0, ManualViewportState(scale = Double.NaN).clamped(portraitBase.displayedRect).scale, 0.0)
        assertEquals(1.0, ManualViewportState(scale = Double.POSITIVE_INFINITY).clamped(portraitBase.displayedRect).scale, 0.0)
    }

    /** The separate Zoom While Typing cap is untouched. */
    @Test
    fun testZoomWhileTypingKeepsItsOwnLimit() {
        assertEquals(1.5, RemoteViewportCalculator.defaultMaxZoom, 0.0)
    }

    @Test
    fun testPinchKeepsTheContentUnderTheMidpointAtEveryScale() {
        val base = portraitBase.displayedRect
        val midpoint = CGPoint(base.minX + base.width * 0.73, base.minY + base.height * 0.31)
        val before = portraitBase.remotePoint(midpoint)!!
        for (scale in scales) {
            val state = ManualViewportState.pinching(
                from = ManualViewportState.identity, initialBase = base, initialMidpoint = midpoint,
                currentMidpoint = midpoint, scaleRatio = scale,
            )
            assertEquals(scale, state.scale, 1e-9)
            val transform = zoomed(state)
            assertFinite(transform.displayedRect)
            assertEquals(base.width * scale, transform.displayedRect.width, 1e-6)
            val after = transform.remotePoint(midpoint)!!
            assertEquals("$scale×", before.x, after.x, 1e-9)
            assertEquals("$scale×", before.y, after.y, 1e-9)
        }
    }

    /**
     * A slow two-finger spread from 1x to 8x and back moves smoothly: no jumps,
     * no NaN, and the anchored content never drifts.
     */
    @Test
    fun testContinuousPinchToEightAndBackIsSmoothAndAnchored() {
        val base = portraitBase.displayedRect
        val midpoint = CGPoint(base.midX + 40, base.midY - 25)
        val anchor = portraitBase.remotePoint(midpoint)!!
        var previous = 1.0
        val ratios = (0..200).map { step ->
            val t = step.toDouble() / 100
            if (t <= 1) Math.pow(8.0, t) else Math.pow(8.0, 2 - t)
        }
        for (ratio in ratios) {
            val state = ManualViewportState.pinching(
                from = ManualViewportState.identity, initialBase = base, initialMidpoint = midpoint,
                currentMidpoint = midpoint, scaleRatio = ratio,
            )
            assertTrue("jump at ratio $ratio", abs(state.scale - previous) < 0.17)
            previous = state.scale
            val mapped = zoomed(state).remotePoint(midpoint)!!
            assertEquals(anchor.x, mapped.x, 1e-9)
            assertEquals(anchor.y, mapped.y, 1e-9)
        }
        assertEquals(1.0, previous, 1e-9)
    }

    /**
     * Zoomed further than 8x in one gesture, the pinch stops at 8x without
     * throwing the content away from the fingers.
     */
    @Test
    fun testPinchingPastTheCapStaysAtEightAndOnScreen() {
        val base = portraitBase.displayedRect
        val midpoint = CGPoint(base.midX, base.midY)
        val state = ManualViewportState.pinching(
            from = ManualViewportState(scale = 6.0), initialBase = base,
            initialMidpoint = midpoint, currentMidpoint = midpoint, scaleRatio = 40.0,
        )
        assertEquals(8.0, state.scale, 0.0)
        assertTrue(zoomed(state).containsViewPoint(midpoint))
    }

    /**
     * However far the user drags, an edge of the Mac can only reach the middle
     * of the view: the content can't be lost off screen.
     */
    @Test
    fun testExtremePanIsClampedSoTheMacStaysReachable() {
        val base = portraitBase.displayedRect
        val center = CGPoint(base.midX, base.midY)
        val pans = listOf(
            1e9 to 1e9, -1e9 to 1e9, 1e9 to -1e9, -1e9 to -1e9, Double.POSITIVE_INFINITY to Double.NaN,
        )
        for (scale in scales) {
            for ((dx, dy) in pans) {
                val state = ManualViewportState(scale = scale, panX = dx, panY = dy).clamped(base)
                assertTrue(state.panX.isFinite() && state.panY.isFinite())
                val transform = zoomed(state)
                assertFinite(transform.displayedRect)
                assertTrue("$scale× pan ($dx, $dy)", isOnPicture(center, transform))
                assertNotNull(transform.remotePoint(center))
            }
        }
    }

    /** A pan that arrives through the gesture is bounded the same way. */
    @Test
    fun testExtremeDragAtEightTimesIsBounded() {
        val base = portraitBase.displayedRect
        val start = CGPoint(base.midX, base.midY)
        val state = ManualViewportState.pinching(
            from = ManualViewportState(scale = 8.0), initialBase = base,
            initialMidpoint = start,
            currentMidpoint = CGPoint(start.x + 50_000, start.y - 50_000),
            scaleRatio = 1.0,
        )
        val limits = state.panLimits(base)
        assertNotNull(limits)
        assertEquals(limits?.x ?: -1.0, abs(state.panX), 1e-6)
        assertEquals(limits?.y ?: -1.0, abs(state.panY), 1e-6)
        assertTrue(isOnPicture(start, zoomed(state)))
    }

    /**
     * Reset returns to exactly the normal presentation from any zoom, and the
     * restore toggle brings the same 8x view back.
     */
    @Test
    fun testResetAndRestoreAtEveryScale() {
        val base = portraitBase.displayedRect
        for (scale in scales.drop(1)) {
            val zoomedState = ManualViewportState(scale = scale, panX = 30.0, panY = -12.0, rotationRadians = PI / 7)
                .clamped(base)
            val reset = ViewportResetRestorePolicy.toggled(zoomedState, null, base)
            assertEquals(ManualViewportState.identity, reset?.current)
            assertEquals(portraitBase, zoomed(reset?.current ?: zoomedState))
            val restored = ViewportResetRestorePolicy.toggled(ManualViewportState.identity, reset?.memory, base)
            assertEquals(zoomedState, restored?.current)
        }
    }

    /**
     * Touch -> Mac -> view round trip at high zoom, with and without rotation:
     * a visible Mac control tapped at 8x receives the tap at that exact point.
     */
    @Test
    fun testPointerMappingIsExactAtHighMagnificationAndRotation() {
        val base = portraitBase.displayedRect
        val view = CGRect(0.0, 0.0, 402.0, 874.0)
        for (scale in scales) {
            for (rotation in listOf(0.0, PI / 2, -PI / 3, PI)) {
                val state = ManualViewportState(
                    scale = scale, panX = -base.width * 0.9, panY = base.height * 0.4, rotationRadians = rotation,
                ).clamped(base)
                val transform = zoomed(state)
                // stride(from: 0.05, through: 0.95, by: 0.15)
                val fractions = generateSequence(0.05) { it + 0.15 }.takeWhile { it <= 0.95 + 1e-9 }.toList()
                for (fx in fractions) {
                    for (fy in fractions) {
                        val touch = CGPoint(view.width * fx, view.height * fy)
                        if (!transform.containsViewPoint(touch)) continue
                        val mac = transform.remotePoint(touch)!!
                        val back = transform.viewPoint(mac)
                        assertEquals("$scale× $rotation", touch.x, back.x, 1e-6)
                        assertEquals("$scale× $rotation", touch.y, back.y, 1e-6)
                    }
                }
            }
        }
    }

    /**
     * At 8x one point of finger travel moves 1/8 as far across the Mac as at
     * 1x: magnification makes pointing finer, never coarser.
     */
    @Test
    fun testOnePointOfTravelIsFinerAtEightTimes() {
        val base = portraitBase.displayedRect
        val center = CGPoint(base.midX, base.midY)
        fun step(scale: Double): Double {
            val transform = zoomed(ManualViewportState(scale = scale))
            val a = transform.remotePoint(center)!!
            val b = transform.remotePoint(CGPoint(center.x + 1, center.y))!!
            return b.x - a.x
        }
        assertEquals(step(1.0) / 8, step(8.0), 1e-12)
    }

    /** Rotation stays available at 8x and snaps exactly like at 1x. */
    @Test
    fun testRotationAtEightTimesKeepsScaleAndAnchor() {
        val base = portraitBase.displayedRect
        val midpoint = CGPoint(base.midX - 30, base.midY + 10)
        val start = ManualViewportState.pinching(
            from = ManualViewportState.identity, initialBase = base, initialMidpoint = midpoint,
            currentMidpoint = midpoint, scaleRatio = 8.0,
        )
        val anchor = zoomed(start).remotePoint(midpoint)!!
        val rotated = ManualViewportState.pinching(
            from = start, initialBase = base, initialMidpoint = midpoint,
            currentMidpoint = midpoint, scaleRatio = 1.0,
            rotationDelta = PI / 2,
        )
        assertEquals(8.0, rotated.scale, 1e-9)
        assertEquals(PI / 2, rotated.rotationRadians, 1e-9)
        val mapped = zoomed(rotated).remotePoint(midpoint)!!
        assertEquals(anchor.x, mapped.x, 1e-9)
        assertEquals(anchor.y, mapped.y, 1e-9)
    }

    /**
     * Rotating the device, resizing an iPad window or opening the keyboard
     * changes the base. An 8x state re-clamps against the new base into valid,
     * finite geometry that still covers the view's center.
     */
    @Test
    fun testEightTimesSurvivesOrientationWindowAndKeyboardChanges() {
        val mac = CGSize(1728.0, 1080.0)
        val views = listOf(
            CGRect(0.0, 0.0, 402.0, 874.0), CGRect(0.0, 0.0, 874.0, 402.0),
            CGRect(0.0, 0.0, 1032.0, 1376.0), CGRect(0.0, 0.0, 507.0, 688.0),
            CGRect(0.0, 0.0, 320.0, 240.0),
        )
        val state = ManualViewportState(scale = 8.0, panX = 5_000.0, panY = -5_000.0, rotationRadians = PI / 4)
        for (view in views) {
            val normal = RemoteViewportCalculator.normal(view, mac)
            val typing = RemoteViewportCalculator.keyboardOpen(
                viewBounds = view, remoteAspectSize = mac,
                visibleRect = CGRect(0.0, 0.0, view.width, view.height * 0.55),
                anchor = CGPoint(0.5, 0.8), zoomEnabled = true,
            )
            for (base in listOf(normal, typing).filter { it.isValid }) {
                val clamped = state.clamped(base.displayedRect)
                assertEquals(8.0, clamped.scale, 0.0)
                val transform = RemoteViewportCalculator.applyManualZoom(base, clamped)
                assertFinite(transform.displayedRect)
                val center = CGPoint(base.displayedRect.midX, base.displayedRect.midY)
                assertTrue("${view.size}", isOnPicture(center, transform))
            }
        }
    }

    /** Unusable geometry never yields NaN at any scale. */
    @Test
    fun testDegenerateGeometryNeverProducesNaN() {
        val degenerate = RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), CGRect.zero)
        for (scale in scales) {
            val transform = RemoteViewportCalculator.applyManualZoom(degenerate, ManualViewportState(scale = scale))
            assertNull(transform.remotePoint(CGPoint.zero))
            val state = ManualViewportState.pinching(
                from = ManualViewportState(scale = scale), initialBase = CGRect.zero,
                initialMidpoint = CGPoint.zero, currentMidpoint = CGPoint(10.0, 10.0),
                scaleRatio = Double.NaN,
            )
            assertEquals(scale, state.scale, 0.0)
        }
    }
}
