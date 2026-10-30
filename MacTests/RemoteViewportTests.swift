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

    // MARK: - Manual viewport zoom/pan

    func testIdentityManualStateReturnsBaseTransformUnchanged() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let result = RemoteViewportCalculator.applyManualZoom(to: base, state: .identity)
        XCTAssertEqual(result, base, "identity manual state must be an exact pass-through, not merely numerically equal")
    }

    func testManualZoomAboveOneMagnifiesTheDisplayedRect() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let state = ManualViewportState(scale: 2, panX: 0, panY: 0)
        let result = RemoteViewportCalculator.applyManualZoom(to: base, state: state)
        XCTAssertEqual(result.displayedRect.width, base.displayedRect.width * 2, accuracy: 0.001)
        XCTAssertEqual(result.displayedRect.height, base.displayedRect.height * 2, accuracy: 0.001)
    }

    func testManualScaleClampsBelowOneUpToOne() {
        let clamped = ManualViewportState(scale: 0.3, panX: 0, panY: 0).clamped(against: squareBounds)
        XCTAssertEqual(clamped.scale, 1)
    }

    func testManualScaleClampsAtMaximum() {
        let clamped = ManualViewportState(scale: 10, panX: 0, panY: 0).clamped(against: squareBounds)
        XCTAssertEqual(clamped.scale, ManualViewportState.maxScale)
    }

    func testMinimumScaleKeepsPanWithinHalfTheContent() {
        // 100% no longer forces the view back to center; an edge may reach
        // the viewport's center and no further.
        let clamped = ManualViewportState(scale: 1, panX: 999, panY: -999).clamped(against: squareBounds)
        XCTAssertEqual(clamped.panX, squareBounds.width / 2)
        XCTAssertEqual(clamped.panY, -squareBounds.height / 2)
    }

    func testZoomedPanStopsWhenAnEdgeReachesTheViewportCenter() {
        let state = ManualViewportState(scale: 2, panX: 10_000, panY: -10_000)
        let clamped = state.clamped(against: squareBounds)
        let width = squareBounds.width * clamped.scale
        let height = squareBounds.height * clamped.scale
        XCTAssertEqual(clamped.panX, width / 2, accuracy: 0.001)
        XCTAssertEqual(clamped.panY, -height / 2, accuracy: 0.001)
    }

    func testPinchZoomsAroundTheGestureMidpoint() {
        let base = squareBounds   // 400x800
        let midpoint = CGPoint(x: base.midX, y: base.midY)
        let result = ManualViewportState.pinching(
            from: .identity, initialBase: base,
            initialMidpoint: midpoint, currentMidpoint: midpoint, scaleRatio: 2)
        XCTAssertEqual(result.scale, 2, accuracy: 0.001)
        // Pinching around dead-center keeps the content centered, i.e. no pan.
        XCTAssertEqual(result.panX, 0, accuracy: 0.5)
        XCTAssertEqual(result.panY, 0, accuracy: 0.5)
    }

    func testPinchKeepsContentUnderAnOffCenterMidpointApproximatelyFixed() {
        let base = squareBounds
        let anchor = CGPoint(x: base.minX + 100, y: base.minY + 200)   // off-center
        let start = ManualViewportState.pinching(
            from: .identity, initialBase: base,
            initialMidpoint: anchor, currentMidpoint: anchor, scaleRatio: 1.8)
        let baseTransform = RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1), displayedRect: base)
        let zoomed = RemoteViewportCalculator.applyManualZoom(
            to: baseTransform, state: start)
        // The content that sat under `anchor` before zooming should still be
        // very close to `anchor` after, up to whatever clamping required.
        guard let remoteUnderAnchorBefore = baseTransform.remotePoint(forView: anchor) else {
            return XCTFail("expected a valid pre-zoom mapping")
        }
        let viewPointAfter = zoomed.viewPoint(forRemote: remoteUnderAnchorBefore)
        XCTAssertEqual(viewPointAfter.x, anchor.x, accuracy: 1.0)
        XCTAssertEqual(viewPointAfter.y, anchor.y, accuracy: 1.0)
    }

    func testPanWhileZoomedTranslatesTheDisplayedRect() {
        let base = squareBounds
        let zoomedIn = ManualViewportState(scale: 2, panX: 0, panY: 0)
        let start = CGPoint(x: base.midX, y: base.midY)
        let dragged = CGPoint(x: base.midX + 20, y: base.midY - 15)
        let panned = ManualViewportState.pinching(
            from: zoomedIn, initialBase: base,
            initialMidpoint: start, currentMidpoint: dragged, scaleRatio: 1)
        XCTAssertEqual(panned.scale, zoomedIn.scale, accuracy: 0.001, "a pure drag must not also change scale")
        XCTAssertEqual(panned.panX, 20, accuracy: 0.5)
        XCTAssertEqual(panned.panY, -15, accuracy: 0.5)
    }

    func testResetToIdentityReturnsExactlyToTheBaseTransform() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        var state = ManualViewportState(scale: 2.4, panX: 30, panY: -12)
        XCTAssertNotEqual(RemoteViewportCalculator.applyManualZoom(to: base, state: state), base)
        state = .identity
        XCTAssertEqual(RemoteViewportCalculator.applyManualZoom(to: base, state: state), base)
    }

    func testManualZoomRecomputesValidlyAfterAnOrientationChange() {
        // A state clamped/valid in portrait must still clamp to something
        // finite and valid once the base rect changes shape (rotation).
        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)
        let state = ManualViewportState(scale: 2.5, panX: 150, panY: 300).clamped(against: portrait)
        let recomputed = state.clamped(against: landscape)
        XCTAssertTrue(recomputed.scale.isFinite && recomputed.panX.isFinite && recomputed.panY.isFinite)
        XCTAssertGreaterThanOrEqual(recomputed.scale, ManualViewportState.minScale)
        XCTAssertLessThanOrEqual(recomputed.scale, ManualViewportState.maxScale)
    }

    func testManualZoomComposesOnTopOfTheKeyboardOpenPresentation() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 500)
        let base = RemoteViewportCalculator.keyboardOpen(
            viewBounds: squareBounds, remoteAspectSize: squareAspect,
            visibleRect: visible, anchor: CGPoint(x: 0.5, y: 0.9), zoomEnabled: false)
        let manual = ManualViewportState(scale: 1.5, panX: 0, panY: 0)
        let result = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.displayedRect.width, base.displayedRect.width * 1.5, accuracy: 0.001,
                       "manual zoom must magnify the keyboard-adjusted rect, not replace it")
    }

    func testManualZoomNeverProducesNaNOrInvalidGeometry() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        for scale: CGFloat in [-5, 0, 0.001, 1, 1.5, 3, 999] {
            for pan: CGFloat in [-1e6, 0, 1e6] {
                let state = ManualViewportState(scale: scale, panX: pan, panY: pan)
                let result = RemoteViewportCalculator.applyManualZoom(to: base, state: state)
                XCTAssertFalse(result.displayedRect.origin.x.isNaN)
                XCTAssertFalse(result.displayedRect.origin.y.isNaN)
                XCTAssertFalse(result.displayedRect.width.isNaN)
                XCTAssertFalse(result.displayedRect.height.isNaN)
            }
        }
    }

    func testForwardAndInverseMappingRemainCorrectUnderManualZoomAndPan() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let state = ManualViewportState(scale: 2, panX: 30, panY: -20).clamped(against: base.displayedRect)
        let t = RemoteViewportCalculator.applyManualZoom(to: base, state: state)
        for remotePoint in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.8)] {
            let viewPoint = t.viewPoint(forRemote: remotePoint)
            guard let back = t.remotePoint(forView: viewPoint) else {
                return XCTFail("expected a valid inverse mapping under manual zoom/pan")
            }
            XCTAssertEqual(back.x, remotePoint.x, accuracy: 0.0005)
            XCTAssertEqual(back.y, remotePoint.y, accuracy: 0.0005)
        }
    }

    func testForwardAndInverseMappingRemainCorrectUnderCombinedTransform() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let state = ManualViewportState(scale: 2, panX: 30, panY: -20,
                                        rotationRadians: .pi / 3)
        let transform = RemoteViewportCalculator.applyManualZoom(to: base, state: state)
        for remote in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.8)] {
            let view = transform.viewPoint(forRemote: remote)
            let mapped = try? XCTUnwrap(transform.remotePoint(forView: view))
            XCTAssertEqual(mapped?.x ?? -.infinity, remote.x, accuracy: 0.0005)
            XCTAssertEqual(mapped?.y ?? -.infinity, remote.y, accuracy: 0.0005)
        }
    }

    func testPinchPanAndRotationPreserveGestureAnchor() throws {
        let initial = ManualViewportState(scale: 1.4, panX: 15, panY: -10,
                                          rotationRadians: .pi / 8)
        let start = CGPoint(x: 420, y: 470)
        let current = CGPoint(x: 445, y: 450)
        let result = ManualViewportState.pinching(
            from: initial, initialBase: squareBounds,
            initialMidpoint: start, currentMidpoint: current,
            scaleRatio: 1.25, rotationDelta: .pi / 6)
        let before = RemoteViewportCalculator.applyManualZoom(
            to: RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        displayedRect: squareBounds), state: initial)
        let after = RemoteViewportCalculator.applyManualZoom(
            to: RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        displayedRect: squareBounds), state: result)
        let remote = try XCTUnwrap(before.remotePoint(forView: start))
        let anchored = after.viewPoint(forRemote: remote)
        XCTAssertEqual(anchored.x, current.x, accuracy: 1)
        XCTAssertEqual(anchored.y, current.y, accuracy: 1)
    }

    func testRotationSnapEngagesOnceInsideSevenDegreeZone() {
        let nearQuarter = ViewportRotationSnap.snappedAngle(84 * .pi / 180, enabled: true)
        XCTAssertEqual(nearQuarter.angle, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(nearQuarter.targetQuarter, 1)
        XCTAssertNil(ViewportRotationSnap.snappedAngle(80 * .pi / 180, enabled: true).targetQuarter)
        XCTAssertNil(ViewportRotationSnap.snappedAngle(89 * .pi / 180, enabled: false).targetQuarter)
    }

    func testVideoOffIgnoresButPreservesManualViewportState() {
        let base = RemoteViewportCalculator.normal(viewBounds: squareBounds, remoteAspectSize: squareAspect)
        let stored = ManualViewportState(scale: 2, panX: 40, panY: -25,
                                         rotationRadians: .pi / 2)
        XCTAssertEqual(VideoInteractionPolicy.viewportTransform(
            base: base, state: stored, videoEnabled: false), base)
        XCTAssertEqual(VideoInteractionPolicy.viewportTransform(
            base: base, state: stored, videoEnabled: true),
                       RemoteViewportCalculator.applyManualZoom(to: base, state: stored))
        XCTAssertEqual(stored.rotationRadians, .pi / 2)
    }

    func testVideoOffForcesEffectiveAppTargetsWithoutChangingStoredValue() {
        let stored = ReceiverGestureTarget.viewport
        XCTAssertEqual(VideoInteractionPolicy.effectiveTarget(stored: stored, videoEnabled: false), .app)
        XCTAssertEqual(VideoInteractionPolicy.effectiveTarget(stored: stored, videoEnabled: true), .viewport)
        XCTAssertEqual(stored, .viewport)
    }

    /// Disabled must be a true no-op: unlike `.viewport`, turning video off
    /// must never promote it into `.app` (that would fire a keyboard
    /// command the user explicitly asked to disable).
    func testDisabledGestureTargetNeverPromotesToApp() {
        XCTAssertEqual(VideoInteractionPolicy.effectiveTarget(stored: .disabled, videoEnabled: false), .disabled)
        XCTAssertEqual(VideoInteractionPolicy.effectiveTarget(stored: .disabled, videoEnabled: true), .disabled)
    }

    /// Backward compatibility: `ReceiverGestureTarget` gained `.disabled`
    /// after `.viewport`/`.app` shipped and persisted. Previously-stored raw
    /// values must keep decoding to the same cases.
    func testReceiverGestureTargetDecodesPreviouslyPersistedRawValues() {
        XCTAssertEqual(ReceiverGestureTarget(rawValue: "viewport"), .viewport)
        XCTAssertEqual(ReceiverGestureTarget(rawValue: "app"), .app)
        XCTAssertEqual(ReceiverGestureTarget(rawValue: "disabled"), .disabled)
    }

    func testSurfaceAdmissionRejectsOutsideBeginAndKeepsInsideSequenceOutside() {
        var admission = SurfaceTouchAdmission<Int>()
        admission.begin(1, inside: false)
        XCTAssertFalse(admission.contains(1))
        admission.begin(2, inside: true)
        XCTAssertTrue(admission.contains(2), "movement outside must not cancel a sequence admitted at begin")
        admission.end(2)
        XCTAssertFalse(admission.contains(2))
    }

    func testDoubleTapResetRestoreIncludesRotation() throws {
        let transformed = ManualViewportState(scale: 1.8, panX: 20, panY: -15,
                                              rotationRadians: .pi / 2)
        let reset = try XCTUnwrap(ViewportResetRestorePolicy.toggled(
            current: transformed, memory: nil, base: squareBounds))
        XCTAssertEqual(reset.current, .identity)
        let restored = try XCTUnwrap(ViewportResetRestorePolicy.toggled(
            current: reset.current, memory: reset.memory, base: squareBounds))
        XCTAssertEqual(restored.current.rotationRadians, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(restored.current.scale, transformed.scale, accuracy: 0.0001)
    }
}

/// Local pinch-to-zoom up to 8×: geometry stays finite, the content under
/// the fingers stays put, touches still land on the right Mac point, and
/// pan, rotation and reset keep working at every magnification.
final class HighMagnificationViewportTests: XCTestCase {
    /// The un-zoomed presentation of a 16:10 Mac on a portrait iPhone.
    private let portraitBase = RemoteViewportCalculator.normal(
        viewBounds: CGRect(x: 0, y: 0, width: 402, height: 874), remoteAspectSize: CGSize(width: 1728, height: 1080))
    private let scales: [CGFloat] = [1, 3, 4, 6, 8]

    private func zoomed(_ state: ManualViewportState, base: RemoteViewportTransform? = nil) -> RemoteViewportTransform {
        RemoteViewportCalculator.applyManualZoom(to: base ?? portraitBase, state: state)
    }

    private func assertFinite(_ rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
    }

    /// Whether `point` lies on the displayed (rotated) picture, edges
    /// included: the clamp lets an edge travel exactly to the center, which
    /// `CGRect.contains` (open at the max edges) would count as off.
    private func isOnPicture(_ point: CGPoint, _ transform: RemoteViewportTransform) -> Bool {
        let rect = transform.displayedRect
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let c = cos(-transform.rotationRadians)
        let s = sin(-transform.rotationRadians)
        let tolerance: CGFloat = 1e-6
        return abs(dx * c - dy * s) <= rect.width / 2 + tolerance
            && abs(dx * s + dy * c) <= rect.height / 2 + tolerance
    }

    /// How far inside the picture's nearest edge the view's center sits for
    /// `state` as given, without clamping it: negative means off the picture.
    private func edgeGap(_ state: ManualViewportState, rotation: CGFloat, base: CGRect) -> CGFloat {
        let c = cos(-rotation)
        let s = sin(-rotation)
        let localX = -state.panX * c + state.panY * s
        let localY = -state.panX * s - state.panY * c
        return min(base.width * state.scale / 2 - abs(localX), base.height * state.scale / 2 - abs(localY))
    }

    /// The clamp at any angle, not only quarter turns: the view's center
    /// always ends up on the picture, a pan already on it is kept exactly,
    /// a pan that was off it lands on the picture's edge (give or take the
    /// 0.01pt rest snap), and clamping twice changes nothing. The grid
    /// includes near-zero components, where the rest snap meets the edge.
    func testClampKeepsTheCenterOnThePictureAtArbitraryAngles() {
        let base = portraitBase.displayedRect
        let center = CGPoint(x: base.midX, y: base.midY)
        let fractions: [CGFloat] = [-1.5, -1.05, -0.7, -0.45, -0.2, 0, 0.2, 0.45, 0.7, 1.05, 1.5]
        let degreesList = Array(stride(from: -180.0, through: 180.0, by: 7.5)) + [0.1, -1, 44.9, 89.9]
        for degrees in degreesList {
            let rotation = CGFloat(degrees) * .pi / 180
            for scale in scales {
                let reach = base.width * scale
                let offsets = fractions.map { $0 * reach } + [-0.004, 0.004]
                for panX in offsets {
                    for panY in offsets {
                        let state = ManualViewportState(scale: scale, panX: panX, panY: panY, rotationRadians: rotation)
                        let clamped = state.clamped(against: base)
                        let transform = zoomed(clamped)
                        XCTAssertTrue(isOnPicture(center, transform), "\(degrees)° \(scale)× \(state)")
                        XCTAssertEqual(clamped.clamped(against: base), clamped, "\(degrees)° \(scale)×")
                        let before = edgeGap(state, rotation: clamped.rotationRadians, base: base)
                        if before >= 0, abs(state.panX) >= 0.01, abs(state.panY) >= 0.01 {
                            XCTAssertEqual(clamped.panX, state.panX, "\(degrees)° \(scale)×")
                            XCTAssertEqual(clamped.panY, state.panY, "\(degrees)° \(scale)×")
                        } else if before < 0 {
                            // Clamped onto the edge, not pulled further in.
                            let after = edgeGap(clamped, rotation: clamped.rotationRadians, base: base)
                            XCTAssertGreaterThanOrEqual(after, -1e-6, "\(degrees)° \(scale)× \(state)")
                            XCTAssertLessThanOrEqual(after, 0.01, "\(degrees)° \(scale)× \(state)")
                        }
                    }
                }
            }
        }
    }

    /// The pre-existing failure the rotated-frame clamp fixes: tilted 30°,
    /// zoomed and dragged far along a diagonal, the bounding-box limits let
    /// the whole picture leave the screen.
    func testTiltedDiagonalExtremePanNoLongerLosesThePicture() {
        let base = portraitBase.displayedRect
        let center = CGPoint(x: base.midX, y: base.midY)
        for scale in scales {
            let state = ManualViewportState(scale: scale, panX: 1e6, panY: 1e6, rotationRadians: .pi / 6)
                .clamped(against: base)
            XCTAssertTrue(isOnPicture(center, zoomed(state)), "\(scale)×")
        }
    }

    func testMaximumManualZoomIsEightTimesAndClampsAbove() {
        XCTAssertEqual(ManualViewportState.maxScale, 8)
        let over = ManualViewportState(scale: 50).clamped(against: portraitBase.displayedRect)
        XCTAssertEqual(over.scale, 8)
        XCTAssertEqual(ManualViewportState(scale: 0.2).clamped(against: portraitBase.displayedRect).scale, 1)
        XCTAssertEqual(ManualViewportState(scale: .nan).clamped(against: portraitBase.displayedRect).scale, 1)
        XCTAssertEqual(ManualViewportState(scale: .infinity).clamped(against: portraitBase.displayedRect).scale, 1)
    }

    /// The Separate Zoom While Typing cap is untouched.
    func testZoomWhileTypingKeepsItsOwnLimit() {
        XCTAssertEqual(RemoteViewportCalculator.defaultMaxZoom, 1.5)
    }

    func testPinchKeepsTheContentUnderTheMidpointAtEveryScale() throws {
        let base = portraitBase.displayedRect
        let midpoint = CGPoint(x: base.minX + base.width * 0.73, y: base.minY + base.height * 0.31)
        let before = try XCTUnwrap(portraitBase.remotePoint(forView: midpoint))
        for scale in scales {
            let state = ManualViewportState.pinching(from: .identity, initialBase: base, initialMidpoint: midpoint,
                                                     currentMidpoint: midpoint, scaleRatio: scale)
            XCTAssertEqual(state.scale, scale, accuracy: 1e-9)
            let transform = zoomed(state)
            assertFinite(transform.displayedRect)
            XCTAssertEqual(transform.displayedRect.width, base.width * scale, accuracy: 1e-6)
            let after = try XCTUnwrap(transform.remotePoint(forView: midpoint))
            XCTAssertEqual(after.x, before.x, accuracy: 1e-9, "\(scale)×")
            XCTAssertEqual(after.y, before.y, accuracy: 1e-9, "\(scale)×")
        }
    }

    /// A slow two-finger spread from 1× to 8× and back moves smoothly: no
    /// jumps, no NaN, and the anchored content never drifts.
    func testContinuousPinchToEightAndBackIsSmoothAndAnchored() throws {
        let base = portraitBase.displayedRect
        let midpoint = CGPoint(x: base.midX + 40, y: base.midY - 25)
        let anchor = try XCTUnwrap(portraitBase.remotePoint(forView: midpoint))
        var previous: CGFloat = 1
        let ratios = (0...200).map { step -> CGFloat in
            let t = CGFloat(step) / 100
            return t <= 1 ? pow(8, t) : pow(8, 2 - t)
        }
        for ratio in ratios {
            let state = ManualViewportState.pinching(from: .identity, initialBase: base, initialMidpoint: midpoint,
                                                     currentMidpoint: midpoint, scaleRatio: ratio)
            XCTAssertLessThan(abs(state.scale - previous), 0.17, "jump at ratio \(ratio)")
            previous = state.scale
            let mapped = try XCTUnwrap(zoomed(state).remotePoint(forView: midpoint))
            XCTAssertEqual(mapped.x, anchor.x, accuracy: 1e-9)
            XCTAssertEqual(mapped.y, anchor.y, accuracy: 1e-9)
        }
        XCTAssertEqual(previous, 1, accuracy: 1e-9)
    }

    /// Zoomed further than 8× in one gesture, the pinch stops at 8× without
    /// throwing the content away from the fingers.
    func testPinchingPastTheCapStaysAtEightAndOnScreen() {
        let base = portraitBase.displayedRect
        let midpoint = CGPoint(x: base.midX, y: base.midY)
        let state = ManualViewportState.pinching(from: ManualViewportState(scale: 6), initialBase: base,
                                                 initialMidpoint: midpoint, currentMidpoint: midpoint, scaleRatio: 40)
        XCTAssertEqual(state.scale, 8)
        XCTAssertTrue(zoomed(state).containsViewPoint(midpoint))
    }

    /// However far the user drags, an edge of the Mac can only reach the
    /// middle of the view: the content can't be lost off screen.
    func testExtremePanIsClampedSoTheMacStaysReachable() throws {
        let base = portraitBase.displayedRect
        let center = CGPoint(x: base.midX, y: base.midY)
        for scale in scales {
            for (dx, dy) in [(1e9, 1e9), (-1e9, 1e9), (1e9, -1e9), (-1e9, -1e9), (CGFloat.infinity, .nan)] {
                let state = ManualViewportState(scale: scale, panX: dx, panY: dy).clamped(against: base)
                XCTAssertTrue(state.panX.isFinite && state.panY.isFinite)
                let transform = zoomed(state)
                assertFinite(transform.displayedRect)
                XCTAssertTrue(isOnPicture(center, transform), "\(scale)× pan (\(dx), \(dy))")
                XCTAssertNotNil(transform.remotePoint(forView: center))
            }
        }
    }

    /// A pan that arrives through the gesture is bounded the same way.
    func testExtremeDragAtEightTimesIsBounded() {
        let base = portraitBase.displayedRect
        let start = CGPoint(x: base.midX, y: base.midY)
        let state = ManualViewportState.pinching(from: ManualViewportState(scale: 8), initialBase: base,
                                                 initialMidpoint: start,
                                                 currentMidpoint: CGPoint(x: start.x + 50_000, y: start.y - 50_000),
                                                 scaleRatio: 1)
        let limits = try? XCTUnwrap(state.panLimits(against: base))
        XCTAssertEqual(abs(state.panX), limits?.x ?? -1, accuracy: 1e-6)
        XCTAssertEqual(abs(state.panY), limits?.y ?? -1, accuracy: 1e-6)
        XCTAssertTrue(isOnPicture(start, zoomed(state)))
    }

    /// Reset returns to exactly the normal presentation from any zoom, and
    /// the restore toggle brings the same 8× view back.
    func testResetAndRestoreAtEveryScale() {
        let base = portraitBase.displayedRect
        for scale in scales.dropFirst() {
            let zoomedState = ManualViewportState(scale: scale, panX: 30, panY: -12, rotationRadians: .pi / 7)
                .clamped(against: base)
            let reset = ViewportResetRestorePolicy.toggled(current: zoomedState, memory: nil, base: base)
            XCTAssertEqual(reset?.current, .identity)
            XCTAssertEqual(zoomed(reset?.current ?? zoomedState), portraitBase)
            let restored = ViewportResetRestorePolicy.toggled(current: .identity, memory: reset?.memory, base: base)
            XCTAssertEqual(restored?.current, zoomedState)
        }
    }

    /// Touch → Mac → view round trip at high zoom, with and without
    /// rotation: a visible Mac control tapped at 8× receives the tap at
    /// that exact point.
    func testPointerMappingIsExactAtHighMagnificationAndRotation() throws {
        let base = portraitBase.displayedRect
        let view = CGRect(x: 0, y: 0, width: 402, height: 874)
        for scale in scales {
            for rotation: CGFloat in [0, .pi / 2, -.pi / 3, .pi] {
                let state = ManualViewportState(scale: scale, panX: -base.width * 0.9, panY: base.height * 0.4,
                                                rotationRadians: rotation).clamped(against: base)
                let transform = zoomed(state)
                for fx in stride(from: 0.05, through: 0.95, by: 0.15) {
                    for fy in stride(from: 0.05, through: 0.95, by: 0.15) {
                        let touch = CGPoint(x: view.width * fx, y: view.height * fy)
                        guard transform.containsViewPoint(touch) else { continue }
                        let mac = try XCTUnwrap(transform.remotePoint(forView: touch))
                        let back = transform.viewPoint(forRemote: mac)
                        XCTAssertEqual(back.x, touch.x, accuracy: 1e-6, "\(scale)× \(rotation)")
                        XCTAssertEqual(back.y, touch.y, accuracy: 1e-6, "\(scale)× \(rotation)")
                    }
                }
            }
        }
    }

    /// At 8× one point of finger travel moves 1/8 as far across the Mac as
    /// at 1×: magnification makes pointing finer, never coarser.
    func testOnePointOfTravelIsFinerAtEightTimes() throws {
        let base = portraitBase.displayedRect
        let center = CGPoint(x: base.midX, y: base.midY)
        func step(at scale: CGFloat) throws -> CGFloat {
            let transform = zoomed(ManualViewportState(scale: scale))
            let a = try XCTUnwrap(transform.remotePoint(forView: center))
            let b = try XCTUnwrap(transform.remotePoint(forView: CGPoint(x: center.x + 1, y: center.y)))
            return b.x - a.x
        }
        XCTAssertEqual(try step(at: 8), try step(at: 1) / 8, accuracy: 1e-12)
    }

    /// Rotation stays available at 8× and snaps exactly like at 1×.
    func testRotationAtEightTimesKeepsScaleAndAnchor() throws {
        let base = portraitBase.displayedRect
        let midpoint = CGPoint(x: base.midX - 30, y: base.midY + 10)
        let start = ManualViewportState.pinching(from: .identity, initialBase: base, initialMidpoint: midpoint,
                                                 currentMidpoint: midpoint, scaleRatio: 8)
        let anchor = try XCTUnwrap(zoomed(start).remotePoint(forView: midpoint))
        let rotated = ManualViewportState.pinching(from: start, initialBase: base, initialMidpoint: midpoint,
                                                   currentMidpoint: midpoint, scaleRatio: 1,
                                                   rotationDelta: .pi / 2)
        XCTAssertEqual(rotated.scale, 8, accuracy: 1e-9)
        XCTAssertEqual(rotated.rotationRadians, .pi / 2, accuracy: 1e-9)
        let mapped = try XCTUnwrap(zoomed(rotated).remotePoint(forView: midpoint))
        XCTAssertEqual(mapped.x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, anchor.y, accuracy: 1e-9)
    }

    /// Rotating the device, resizing an iPad window or opening the keyboard
    /// changes the base. An 8× state re-clamps against the new base into
    /// valid, finite geometry that still covers the view's center.
    func testEightTimesSurvivesOrientationWindowAndKeyboardChanges() {
        let mac = CGSize(width: 1728, height: 1080)
        let views = [CGRect(x: 0, y: 0, width: 402, height: 874), CGRect(x: 0, y: 0, width: 874, height: 402),
                     CGRect(x: 0, y: 0, width: 1032, height: 1376), CGRect(x: 0, y: 0, width: 507, height: 688),
                     CGRect(x: 0, y: 0, width: 320, height: 240)]
        let state = ManualViewportState(scale: 8, panX: 5_000, panY: -5_000, rotationRadians: .pi / 4)
        for view in views {
            let normal = RemoteViewportCalculator.normal(viewBounds: view, remoteAspectSize: mac)
            let typing = RemoteViewportCalculator.keyboardOpen(
                viewBounds: view, remoteAspectSize: mac,
                visibleRect: CGRect(x: 0, y: 0, width: view.width, height: view.height * 0.55),
                anchor: CGPoint(x: 0.5, y: 0.8), zoomEnabled: true)
            for base in [normal, typing] where base.isValid {
                let clamped = state.clamped(against: base.displayedRect)
                XCTAssertEqual(clamped.scale, 8)
                let transform = RemoteViewportCalculator.applyManualZoom(to: base, state: clamped)
                assertFinite(transform.displayedRect)
                let center = CGPoint(x: base.displayedRect.midX, y: base.displayedRect.midY)
                XCTAssertTrue(isOnPicture(center, transform), "\(view.size)")
            }
        }
    }

    /// Unusable geometry never yields NaN at any scale.
    func testDegenerateGeometryNeverProducesNaN() {
        let degenerate = RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1), displayedRect: .zero)
        for scale in scales {
            let transform = RemoteViewportCalculator.applyManualZoom(to: degenerate, state: ManualViewportState(scale: scale))
            XCTAssertNil(transform.remotePoint(forView: .zero))
            let state = ManualViewportState.pinching(from: ManualViewportState(scale: scale), initialBase: .zero,
                                                     initialMidpoint: .zero, currentMidpoint: CGPoint(x: 10, y: 10),
                                                     scaleRatio: .nan)
            XCTAssertEqual(state.scale, scale)
        }
    }
}
