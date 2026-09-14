import CoreGraphics
import XCTest

/// Pure-logic coverage for the M4 keyboard-presentation viewport transform.
/// No UIKit/keyboard-notification plumbing is exercised here (that lives in
/// `iOS/OpenSidecarPhoneApp.swift` and can't run outside a real app); this
/// covers the geometry math both rendering and touch-input mapping share.
///
/// Product rule under test: whenever the keyboard is open, the likely
/// typing anchor stays visible via *vertical-only* movement — Zoom While
/// Typing OFF never shrinks below normal scale and never pans
/// horizontally; ON is an additional magnification on top of that same
/// normal scale, so it can never be smaller than OFF, and is likewise
/// vertical-only.
final class RemoteViewportTests: XCTestCase {

    // A 1:1 aspect remote matching the view bounds exactly — no letterboxing
    // — keeps the arithmetic in most tests exact and easy to reason about.
    private let squareBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let squareAspect = CGSize(width: 400, height: 800)

    // MARK: - Keyboard hidden

    func testKeyboardHiddenIsFullAspectFitWithNoCrop() {
        let t = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        XCTAssertEqual(t.remoteCrop, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(t.displayedRect, squareBounds)
    }

    func testKeyboardHiddenLetterboxesAMismatchedAspectRatio() {
        // Landscape 16:9 remote into a portrait phone view -> letterboxed
        // top/bottom, full width, centered.
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let t = RemoteViewportCalculator.normal(viewBounds: bounds, remoteAspectSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(t.displayedRect.width, 390, accuracy: 0.001)
        XCTAssertLessThan(t.displayedRect.height, bounds.height)
        XCTAssertEqual(t.displayedRect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(t.displayedRect.midY, bounds.midY, accuracy: 0.001)
    }

    // MARK: - Zoom While Typing OFF: never shrinks, vertical-only

    func testZoomOffMatchesNormalScaleExactly() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)   // keyboard ate the bottom 300
        // y=0.85, not 1.0: there's enough slack for pure translation to
        // reach the comfort margin here (verified separately below for the
        // genuinely-insufficient case) — this test is about the ordinary,
        // sufficient-translation path.
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.85), zoomEnabled: false)
        XCTAssertEqual(t.displayedRect.size, normal.displayedRect.size, "must start from the exact normal scale")
    }

    func testZoomOffNeverHorizontallyTranslates() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        for anchor in [CGPoint(x: 0.02, y: 0.9), CGPoint(x: 0.98, y: 0.9), CGPoint(x: 0.5, y: 0.1)] {
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: anchor, zoomEnabled: false)
            XCTAssertEqual(t.displayedRect.minX, normal.displayedRect.minX, accuracy: 0.001,
                          "anchor.x (\(anchor.x)) must never move the horizontal position")
        }
    }

    func testZoomOffMovesTheAnchorIntoTheFreeViewport() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)   // keyboard covers y >= 500
        let anchor = CGPoint(x: 0.5, y: 0.98)   // near the bottom of the remote display
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: anchor, zoomEnabled: false)
        let anchorView = t.viewPoint(forRemote: anchor)
        XCTAssertLessThanOrEqual(anchorView.y, visible.maxY, "anchor must land above the keyboard")
        XCTAssertGreaterThanOrEqual(anchorView.y, visible.minY)
    }

    func testZoomOffDoesNothingWhenTheAnchorIsAlreadyComfortablyVisible() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let anchor = CGPoint(x: 0.5, y: 0.3)   // well within the free viewport already
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: anchor, zoomEnabled: false)
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        XCTAssertEqual(t.displayedRect, normal.displayedRect, "no unnecessary panning")
    }

    func testZoomOffPanClampingNeverExposesBlankSpaceBeyondContentEdges() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 780)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.999), zoomEnabled: false)
        XCTAssertLessThanOrEqual(t.displayedRect.maxY, visible.maxY + 0.001)
        XCTAssertLessThanOrEqual(t.displayedRect.minY, 0.001)
    }

    // MARK: - Zoom While Typing ON: never smaller than OFF, vertical-only

    func testZoomOnScaleIsNeverSmallerThanZoomOff() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        for anchorY: CGFloat in [0.05, 0.5, 0.95] {
            let off = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: CGPoint(x: 0.5, y: anchorY), zoomEnabled: false)
            let on = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: CGPoint(x: 0.5, y: anchorY), zoomEnabled: true)
            XCTAssertGreaterThanOrEqual(on.displayedRect.width, off.displayedRect.width, "anchorY \(anchorY)")
            XCTAssertGreaterThanOrEqual(on.displayedRect.height, off.displayedRect.height, "anchorY \(anchorY)")
        }
    }

    func testZoomOnNeverShrinksBelowNormalScale() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        // Even a barely-covering keyboard must not make Zoom ON smaller
        // than normal — this is the exact real-device regression.
        let visible = CGRect(x: 0, y: 0, width: 400, height: 790)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        XCTAssertGreaterThanOrEqual(t.displayedRect.width, normal.displayedRect.width - 0.001)
        XCTAssertGreaterThanOrEqual(t.displayedRect.height, normal.displayedRect.height - 0.001)
    }

    func testZoomOnMagnifiesAboveNormalWhenKeyboardCoversMeaningfulArea() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)   // keyboard covers a large fraction
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        XCTAssertGreaterThan(t.displayedRect.width, normal.displayedRect.width, "should actually magnify, not merely match")
    }

    func testZoomOnIsCappedAtTheConfiguredMaximum() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 61)   // just above the minimum-usable floor
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true, maxZoom: 1.5)
        XCTAssertEqual(t.displayedRect.width, normal.displayedRect.width * 1.5, accuracy: 0.01)
    }

    func testZoomOnNeverHorizontallyTranslatesOrChasesTheAnchor() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        for anchorX: CGFloat in [0.02, 0.5, 0.98] {
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: CGPoint(x: anchorX, y: 0.5), zoomEnabled: true)
            XCTAssertEqual(t.displayedRect.midX, normal.displayedRect.midX, accuracy: 0.001,
                          "anchor.x (\(anchorX)) must never move the horizontal center")
        }
    }

    func testZoomOnRemainsStableAcrossKeyboardHeightChangesLikeSwitchingToEmoji() {
        // A meaningfully taller keyboard (e.g. the emoji keyboard, or one
        // with a predictive bar) must not suddenly shrink the display —
        // the magnified scale may adjust, but never below normal.
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let normalKeyboardVisible = CGRect(x: 0, y: 0, width: 400, height: 550)
        let emojiKeyboardVisible = CGRect(x: 0, y: 0, width: 400, height: 480)   // taller keyboard
        let beforeSwitch = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: normalKeyboardVisible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        let afterSwitch = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: emojiKeyboardVisible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        XCTAssertGreaterThanOrEqual(beforeSwitch.displayedRect.width, normal.displayedRect.width - 0.001)
        XCTAssertGreaterThanOrEqual(afterSwitch.displayedRect.width, normal.displayedRect.width - 0.001)
    }

    // MARK: - Anchor position (top / center / bottom)

    func testAnchorNearTopIsBroughtIntoView() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        for zoomEnabled in [false, true] {
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.02), zoomEnabled: zoomEnabled)
            let anchorView = t.viewPoint(forRemote: CGPoint(x: 0.5, y: 0.02))
            XCTAssertGreaterThanOrEqual(anchorView.y, visible.minY - 0.5, "zoomEnabled \(zoomEnabled)")
            XCTAssertLessThanOrEqual(anchorView.y, visible.maxY + 0.5, "zoomEnabled \(zoomEnabled)")
        }
    }

    func testAnchorNearCenterNeedsNoAdjustment() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 700)   // generous free viewport
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: false)
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        XCTAssertEqual(t.displayedRect, normal.displayedRect)
    }

    func testAnchorNearBottomIsBroughtIntoView() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        for zoomEnabled in [false, true] {
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: squareBounds, remoteAspectSize: squareAspect,
                visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.98), zoomEnabled: zoomEnabled)
            let anchorView = t.viewPoint(forRemote: CGPoint(x: 0.5, y: 0.98))
            XCTAssertLessThanOrEqual(anchorView.y, visible.maxY + 0.5, "zoomEnabled \(zoomEnabled)")
        }
    }

    // MARK: - No-anchor default (vertical center, not a shrink fallback)

    func testNoAnchorDefaultsToVerticalCenterWithoutShrinking() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: nil, zoomEnabled: false)
        XCTAssertEqual(t.displayedRect.size, normal.displayedRect.size, "no anchor is ordinary behavior, not a fallback")
    }

    func testOutOfRangeAnchorFallsBackToVerticalCenterWithoutShrinking() {
        let normal = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 42), zoomEnabled: false)
        XCTAssertEqual(t.displayedRect.size, normal.displayedRect.size)
    }

    // MARK: - Preference toggle while keyboard is already open

    func testTogglingZoomWhileTypingChangesOnlyScaleNotVerticalIntent() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let anchor = CGPoint(x: 0.5, y: 0.9)
        let off = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: anchor, zoomEnabled: false)
        let on = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: anchor, zoomEnabled: true)
        // Both keep the same anchor visible above the keyboard regardless
        // of the toggle.
        for t in [off, on] {
            let anchorView = t.viewPoint(forRemote: anchor)
            XCTAssertLessThanOrEqual(anchorView.y, visible.maxY + 0.5)
        }
        XCTAssertGreaterThanOrEqual(on.displayedRect.width, off.displayedRect.width)
    }

    // MARK: - Too-small viewport falls back safely (genuinely invalid geometry only)

    func testViewportBelowMinimumUsableHeightFallsBackToFitEverything() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 10)   // well under the floor
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        XCTAssertEqual(t.remoteCrop, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThanOrEqual(t.displayedRect.height, visible.height + 0.001)
    }

    // MARK: - Invalid geometry safety

    func testZeroSizedViewBoundsProducesNoNaN() {
        let t = RemoteViewportCalculator.normal(viewBounds: .zero, remoteAspectSize: squareAspect)
        XCTAssertFalse(t.isValid)
        XCTAssertFalse(t.displayedRect.origin.x.isNaN)
        XCTAssertFalse(t.displayedRect.width.isNaN)
    }

    func testZeroRemoteAspectSizeProducesNoNaN() {
        let t = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: .zero)
        XCTAssertFalse(t.isValid)
        XCTAssertFalse(t.displayedRect.width.isNaN)
    }

    func testInvalidTransformMapsSafelyWithoutNaN() {
        let t = RemoteViewportTransform.invalid
        XCTAssertNil(t.remotePoint(forView: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(t.viewPoint(forRemote: CGPoint(x: 0.5, y: 0.5)), .zero)
        XCTAssertFalse(t.containsViewPoint(CGPoint(x: 0, y: 0)))
    }

    func testKeyboardOpenWithZeroVisibleRectFallsBackToNormal() {
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: .zero, anchor: CGPoint(x: 0.5, y: 0.5), zoomEnabled: true)
        XCTAssertEqual(t, RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect))
    }

    // MARK: - Forward (remote -> view) and inverse (view -> remote) mapping

    func testForwardAndInverseMappingRoundTripUnderZoom() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.3, y: 0.4), zoomEnabled: true)
        let remotePoint = CGPoint(x: 0.32, y: 0.42)
        let viewPoint = t.viewPoint(forRemote: remotePoint)
        guard let back = t.remotePoint(forView: viewPoint) else {
            return XCTFail("expected a valid inverse mapping")
        }
        XCTAssertEqual(back.x, remotePoint.x, accuracy: 0.0005)
        XCTAssertEqual(back.y, remotePoint.y, accuracy: 0.0005)
    }

    func testForwardAndInverseMappingRoundTripUnderPan() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.95), zoomEnabled: false)
        let remotePoint = CGPoint(x: 0.5, y: 0.9)
        let viewPoint = t.viewPoint(forRemote: remotePoint)
        guard let back = t.remotePoint(forView: viewPoint) else {
            return XCTFail("expected a valid inverse mapping")
        }
        XCTAssertEqual(back.x, remotePoint.x, accuracy: 0.0005)
        XCTAssertEqual(back.y, remotePoint.y, accuracy: 0.0005)
    }

    func testATappedRemoteLocationMapsToTheExactSameViewPointItWasDrawnAt() {
        // A visible Mac control tapped while zoomed/panned must still
        // receive input at that exact Mac location: the cursor-sprite path
        // (viewPoint) and the touch-input path (remotePoint) must agree.
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.6, y: 0.7), zoomEnabled: true)
        let controlLocation = CGPoint(x: 0.62, y: 0.71)
        let drawnAt = t.viewPoint(forRemote: controlLocation)
        XCTAssertTrue(t.containsViewPoint(drawnAt))
        guard let tappedBack = t.remotePoint(forView: drawnAt) else {
            return XCTFail("expected a valid inverse mapping")
        }
        XCTAssertEqual(tappedBack.x, controlLocation.x, accuracy: 0.0005)
        XCTAssertEqual(tappedBack.y, controlLocation.y, accuracy: 0.0005)
    }

    // MARK: - Portrait / landscape

    func testPortraitAndLandscapeBothProduceValidGeometry() {
        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)
        let aspect = CGSize(width: 1920, height: 1080)
        for bounds in [portrait, landscape] {
            let visible = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.6)
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: bounds, remoteAspectSize: aspect,
                visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.9), zoomEnabled: true)
            XCTAssertTrue(t.isValid, "bounds \(bounds)")
            XCTAssertFalse(t.displayedRect.origin.x.isNaN)
        }
    }

    // MARK: - Minimal-necessary-scale fallback (the portrait regression)

    // A realistic portrait phone: tall/narrow viewport, a widescreen remote
    // display (letterboxed to a modest horizontal band well inside a
    // typical keyboard-free area), keyboard consuming roughly half the
    // height, anchor near the bottom of the Mac display. Translation alone
    // is expected to suffice here — this is the exact shape of geometry
    // the original portrait bug was reported against (a buggy
    // `clampedPan` refused to pan at all whenever content was shorter than
    // the visible span, which is normally true for a letterboxed
    // widescreen display in a tall portrait view).
    private let portraitBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let widescreenAspect = CGSize(width: 1920, height: 1080)
    // A less letterboxed aspect ratio, so a genuinely-too-small visible
    // viewport can be constructed to exercise the scale-reduction path.
    private let standardAspect = CGSize(width: 1024, height: 768)

    func testPortraitBottomAnchorNormalScaleSufficient() {
        let visible = CGRect(x: 0, y: 0, width: 390, height: 422)   // keyboard ~ half the height
        let normal = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: widescreenAspect)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: widescreenAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.95), zoomEnabled: false)
        XCTAssertEqual(t.displayedRect.size, normal.displayedRect.size, "translation alone should suffice here")
        let anchorView = t.viewPoint(forRemote: CGPoint(x: 0.5, y: 0.95))
        XCTAssertLessThanOrEqual(anchorView.y, visible.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(anchorView.y, visible.minY - 0.5)
    }

    func testPortraitBottomAnchorNormalScaleInsufficientTriggersMinimalShrink() {
        // A shorter, less-letterboxed (4:3) remote and a short keyboard-free
        // viewport with the anchor at the very bottom edge: translation
        // alone provably cannot reach the comfort margin (verified by hand
        // against `requiredScaleForComfort`'s own math), so this must
        // shrink — but only as much as necessary.
        let visible = CGRect(x: 0, y: 0, width: 390, height: 250)
        let normal = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: standardAspect)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 1.0), zoomEnabled: false)
        XCTAssertLessThan(t.displayedRect.height, normal.displayedRect.height, "must actually shrink here")
        let anchorView = t.viewPoint(forRemote: CGPoint(x: 0.5, y: 1.0))
        XCTAssertLessThanOrEqual(anchorView.y, visible.maxY + 0.5, "the anchor must end up visible after shrinking")
        XCTAssertGreaterThanOrEqual(anchorView.y, visible.minY - 0.5)
    }

    func testMinimalShrinkStaysWellAboveTheFloorWhenOnlyAModestReductionIsNeeded() {
        // A geometry that does need some shrink (translation alone isn't
        // enough at normal scale) but only a modest one: the search for
        // the minimal necessary scale must land close to 1, not jump to
        // the aggressive `minimumScaleFactor` floor — that's the
        // "minimal-necessary, not generic aspect-fit" requirement in
        // concrete, always-true terms (an anchor sitting exactly on the
        // display's own physical edge can mathematically need a much
        // larger reduction to carve out any comfort margin at all — see
        // the *InsufficientTriggersMinimalShrink test above, which uses
        // such an anchor and asserts only that it ends up visible, not a
        // specific bound on how much shrink that took).
        let visible = CGRect(x: 0, y: 0, width: 390, height: 250)
        let normal = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: standardAspect)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.9), zoomEnabled: false)
        XCTAssertLessThan(t.displayedRect.height, normal.displayedRect.height, "this geometry must still require some shrink")
        XCTAssertGreaterThan(t.displayedRect.height, normal.displayedRect.height * 0.7,
                             "a minimal shrink must stay well clear of the aggressive floor")
    }

    func testLandscapeCaseRemainsAtNormalScale() {
        let landscapeBounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let normal = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: widescreenAspect)
        let visible = CGRect(x: 0, y: 0, width: 844, height: 220)   // keyboard covers a modest landscape band
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: landscapeBounds, remoteAspectSize: widescreenAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.9), zoomEnabled: false)
        XCTAssertEqual(t.displayedRect.size, normal.displayedRect.size, "landscape must not regress into shrinking")
    }

    func testTallerEmojiKeyboardCausesOnlyTheAdditionallyRequiredShrink() {
        let normalKeyboard = CGRect(x: 0, y: 0, width: 390, height: 260)
        let emojiKeyboard = CGRect(x: 0, y: 0, width: 390, height: 210)   // taller keyboard, shorter visible area
        let anchor = CGPoint(x: 0.5, y: 1.0)
        let withNormalKeyboard = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: normalKeyboard, anchor: anchor, zoomEnabled: false)
        let withEmojiKeyboard = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: emojiKeyboard, anchor: anchor, zoomEnabled: false)
        XCTAssertLessThanOrEqual(withEmojiKeyboard.displayedRect.height, withNormalKeyboard.displayedRect.height + 0.01,
                                 "a taller keyboard must never grow the display")
        // Still visible under the taller keyboard, not just smaller.
        let anchorView = withEmojiKeyboard.viewPoint(forRemote: anchor)
        XCTAssertLessThanOrEqual(anchorView.y, emojiKeyboard.maxY + 0.5)
    }

    func testShorterKeyboardRestoresScaleTowardNormal() {
        let normal = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: standardAspect)
        let shortVisible = CGRect(x: 0, y: 0, width: 390, height: 250)   // forces a shrink
        let tallVisible = CGRect(x: 0, y: 0, width: 390, height: 600)    // keyboard dismissed most of the way
        let anchor = CGPoint(x: 0.5, y: 1.0)
        let shrunk = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: shortVisible, anchor: anchor, zoomEnabled: false)
        let restored = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: tallVisible, anchor: anchor, zoomEnabled: false)
        XCTAssertLessThan(shrunk.displayedRect.height, normal.displayedRect.height)
        XCTAssertGreaterThan(restored.displayedRect.height, shrunk.displayedRect.height,
                             "a taller keyboard-free area must restore scale back toward normal")
    }

    func testForwardAndInverseMappingRemainCorrectUnderTheMinimalShrinkFallback() {
        let visible = CGRect(x: 0, y: 0, width: 390, height: 250)
        let t = RemoteViewportCalculator.keyboardOpen(
            viewBounds: portraitBounds, remoteAspectSize: standardAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 1.0), zoomEnabled: false)
        let remotePoint = CGPoint(x: 0.4, y: 0.9)
        let viewPoint = t.viewPoint(forRemote: remotePoint)
        guard let back = t.remotePoint(forView: viewPoint) else {
            return XCTFail("expected a valid inverse mapping under the shrink fallback")
        }
        XCTAssertEqual(back.x, remotePoint.x, accuracy: 0.0005)
        XCTAssertEqual(back.y, remotePoint.y, accuracy: 0.0005)
    }
}
