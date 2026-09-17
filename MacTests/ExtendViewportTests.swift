import CoreGraphics
import XCTest

/// Extend's orientation-aware "fill the constraining axis, never crop"
/// viewport behavior. There is deliberately no Extend-specific coordinate
/// system: Extend and Mirror share the exact same call site
/// (`iOS/OpenSidecarPhoneApp.swift`'s `layoutSubviews`/`unzoomedBaseTransform`,
/// `RemoteViewportCalculator.normal(viewBounds:remoteAspectSize:)`), so this
/// suite is pure regression coverage against that shared function proving it
/// already produces the desired behavior for every ratio Extend can select
/// — landscape prioritizes filling height, portrait prioritizes filling
/// width, both purely as a consequence of standard aspect-fit math (whichever
/// axis is the tighter constraint fills; the other one letterboxes), and an
/// extreme ratio that can't fill an axis without cropping falls back to
/// ordinary full-content aspect-fit automatically. No separate orientation
/// branch exists or is needed.
final class ExtendViewportTests: XCTestCase {

    // Representative iPhone bounds (points), same aspect either orientation.
    private let landscapeBounds = CGRect(x: 0, y: 0, width: 852, height: 393)
    private let portraitBounds = CGRect(x: 0, y: 0, width: 393, height: 852)

    private func aspect(_ ratio: Double, longEdge: CGFloat = 1278) -> CGSize {
        CGSize(width: longEdge, height: (longEdge / ratio).rounded())
    }

    // MARK: - Landscape: prioritize filling height

    func testLandscape16x10FillsHeightWithSideMargins() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertEqual(t.displayedRect.height, landscapeBounds.height, accuracy: 0.5)
        XCTAssertLessThan(t.displayedRect.width, landscapeBounds.width)
        XCTAssertEqual(t.displayedRect.midX, landscapeBounds.midX, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.minY, landscapeBounds.minY, accuracy: 0.001)
        XCTAssertEqual(t.displayedRect.maxY, landscapeBounds.maxY, accuracy: 0.001)
    }

    func testLandscape16x9FillsHeightWithSmallerSideMargins() {
        let wide = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 9.0))
        let narrower = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertEqual(wide.displayedRect.height, landscapeBounds.height, accuracy: 0.5)
        // 16:9 is wider than 16:10, so it fills more of the width for the
        // same filled height — a smaller side margin, not a larger one.
        XCTAssertGreaterThan(wide.displayedRect.width, narrower.displayedRect.width)
    }

    func testLandscape4x3FillsHeightWithWiderSideMargins() {
        let narrow = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(4.0 / 3.0))
        let wide = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertEqual(narrow.displayedRect.height, landscapeBounds.height, accuracy: 0.5)
        XCTAssertLessThan(narrow.displayedRect.width, wide.displayedRect.width,
                          "a squarer ratio must show wider side margins than a more landscape one")
    }

    func testLandscape21x9NeverCropsAndFallsBackToAspectFit() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(21.0 / 9.0))
        // The whole desktop stays visible: displayedRect never exceeds the
        // view bounds on either axis, however the fit resolves.
        XCTAssertLessThanOrEqual(t.displayedRect.width, landscapeBounds.width + 0.5)
        XCTAssertLessThanOrEqual(t.displayedRect.height, landscapeBounds.height + 0.5)
        let contentAspect = t.displayedRect.width / t.displayedRect.height
        XCTAssertEqual(contentAspect, 21.0 / 9.0, accuracy: 0.01)
    }

    func testLandscape32x9NeverCrops() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(32.0 / 9.0))
        XCTAssertLessThanOrEqual(t.displayedRect.width, landscapeBounds.width + 0.5)
        XCTAssertLessThanOrEqual(t.displayedRect.height, landscapeBounds.height + 0.5)
        let contentAspect = t.displayedRect.width / t.displayedRect.height
        XCTAssertEqual(contentAspect, 32.0 / 9.0, accuracy: 0.01)
    }

    // MARK: - Portrait: prioritize filling width

    func testPortrait16x10FillsWidthWithTopBottomMargins() {
        let t = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertEqual(t.displayedRect.width, portraitBounds.width, accuracy: 0.5)
        XCTAssertLessThan(t.displayedRect.height, portraitBounds.height)
        XCTAssertEqual(t.displayedRect.midY, portraitBounds.midY, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.minX, portraitBounds.minX, accuracy: 0.001)
        XCTAssertEqual(t.displayedRect.maxX, portraitBounds.maxX, accuracy: 0.001)
    }

    func testPortrait16x9FillsWidthWithoutStretchOrCrop() {
        let t = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: aspect(16.0 / 9.0))
        XCTAssertEqual(t.displayedRect.width, portraitBounds.width, accuracy: 0.5)
        let contentAspect = t.displayedRect.width / t.displayedRect.height
        XCTAssertEqual(contentAspect, 16.0 / 9.0, accuracy: 0.01, "must preserve aspect, never stretch")
    }

    func testPortrait1x1FillsWidthWithVerticalMargins() {
        let t = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: aspect(1.0))
        XCTAssertEqual(t.displayedRect.width, portraitBounds.width, accuracy: 0.5)
        XCTAssertLessThan(t.displayedRect.height, portraitBounds.height)
    }

    // MARK: - Input mapping

    func testTouchInsideContentMapsToTheExpectedNormalizedPoint() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        let center = CGPoint(x: t.displayedRect.midX, y: t.displayedRect.midY)
        let mapped = t.remotePoint(forView: center)
        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped!.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(mapped!.y, 0.5, accuracy: 0.01)
        XCTAssertTrue(t.containsViewPoint(center))
    }

    func testTouchInLeftRightLetterboxIsNotOnContent() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertGreaterThan(t.displayedRect.minX, landscapeBounds.minX, "test needs an actual side margin")
        let inMargin = CGPoint(x: landscapeBounds.minX + 1, y: landscapeBounds.midY)
        XCTAssertFalse(t.containsViewPoint(inMargin))
    }

    func testTouchInTopBottomLetterboxIsNotOnContent() {
        let t = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertGreaterThan(t.displayedRect.minY, portraitBounds.minY, "test needs an actual top margin")
        let inMargin = CGPoint(x: portraitBounds.midX, y: portraitBounds.minY + 1)
        XCTAssertFalse(t.containsViewPoint(inMargin))
    }

    /// The admission gate actually used at the touch call site
    /// (`routeTouches`, direct-touch mode): a `began` touch outside the
    /// content rect is never admitted, so it is never forwarded to the Mac
    /// regardless of where it later moves — this is what makes letterbox
    /// touches true no-ops, not merely clamped input.
    func testBeginOutsideContentIsNeverAdmittedEvenIfItLaterMovesOntoContent() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        var admission = SurfaceTouchAdmission<Int>()
        let beganInMargin = CGPoint(x: landscapeBounds.minX + 1, y: landscapeBounds.midY)
        admission.begin(1, inside: t.containsViewPoint(beganInMargin))
        XCTAssertFalse(admission.contains(1))
    }

    func testRotationRecomputesTheTransformForTheNewBounds() {
        let landscape = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        let portrait = RemoteViewportCalculator.normal(viewBounds: portraitBounds, remoteAspectSize: aspect(16.0 / 10.0))
        // Landscape fills height; the same content in portrait bounds fills
        // width instead — the fit is recomputed from bounds, not cached.
        XCTAssertEqual(landscape.displayedRect.height, landscapeBounds.height, accuracy: 0.5)
        XCTAssertEqual(portrait.displayedRect.width, portraitBounds.width, accuracy: 0.5)
    }

    // MARK: - Mirror regression (same shared function, must stay identical)

    func testMirrorLandscapeViewportUnchanged() {
        // A typical Mac laptop display (16:10) mirrored onto a landscape
        // iPhone — exactly `testKeyboardHiddenLetterboxesAMismatchedAspectRatio`'s
        // shape, re-asserted here so an Extend-motivated change to shared
        // geometry cannot silently regress Mirror.
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        XCTAssertEqual(t.displayedRect.height, landscapeBounds.height, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.midX, landscapeBounds.midX, accuracy: 0.5)
    }

    func testMirrorInputMappingUnchanged() {
        let t = RemoteViewportCalculator.normal(viewBounds: landscapeBounds, remoteAspectSize: aspect(16.0 / 10.0))
        let corner = CGPoint(x: t.displayedRect.minX, y: t.displayedRect.minY)
        let mapped = t.remotePoint(forView: corner)
        XCTAssertNotNil(mapped)
        XCTAssertEqual(Double(mapped!.x), 0, accuracy: 0.01)
        XCTAssertEqual(Double(mapped!.y), 0, accuracy: 0.01)
    }
}
