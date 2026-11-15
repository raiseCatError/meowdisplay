import CoreGraphics
import Foundation
import XCTest

/// Pure-logic coverage for the Multi-Display Overview camera: fit-all,
/// world/view mapping for every rotation, pan, anchored zoom, zoom limits,
/// zoom-to-selection and the recovery-button visibility test.
final class OverviewCameraTests: XCTestCase {

    private let portrait = CGSize(width: 400, height: 800)
    private let landscape = CGSize(width: 800, height: 400)
    private let allTurns = [0, 1, 2, 3]

    private func rotation(_ quarterTurns: Int) -> Double { Double(quarterTurns) * Double.pi / 2 }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: Double = 1e-9,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(actual.x), Double(expected.x), accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(Double(actual.y), Double(expected.y), accuracy: accuracy, "y \(message)", file: file, line: line)
    }

    // MARK: Rotation

    func testRotationIsSnappedToMultiplesOfHalfPi() {
        for turns in allTurns {
            XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: rotation(turns)).rotation,
                           rotation(turns), accuracy: 1e-12)
        }
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: 1.4).rotation, Double.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: 3 * Double.pi).rotation, Double.pi, accuracy: 1e-12)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: -Double.pi / 2).rotation,
                       3 * Double.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: .nan).rotation, 0)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 1, rotation: 2 * Double.pi).rotation, 0, accuracy: 1e-12)
    }

    func testInvalidScaleBecomesOne() {
        XCTAssertEqual(OverviewCamera(center: .zero, scale: 0).scale, 1)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: -3).scale, 1)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: .nan).scale, 1)
        XCTAssertEqual(OverviewCamera(center: .zero, scale: .infinity).scale, 1)
    }

    func testQuarterTurnRotatesClockwiseOnScreen() {
        let viewport = CGSize(width: 200, height: 100)
        let camera = OverviewCamera(center: .zero, scale: 1, rotation: Double.pi / 2)
        // World +x (right) points down on screen after a clockwise quarter turn.
        assertPoint(camera.viewPoint(world: CGPoint(x: 10, y: 0), viewport: viewport), CGPoint(x: 100, y: 60))
        // World +y (down) points left.
        assertPoint(camera.viewPoint(world: CGPoint(x: 0, y: 10), viewport: viewport), CGPoint(x: 90, y: 50))
    }

    func testRotateByQuarterTurnsWrapsAround() {
        var camera = OverviewCamera(center: .zero, scale: 1)
        camera.rotate(byQuarterTurns: 5)
        XCTAssertEqual(camera.quarterTurns, 1)
        camera.rotate(byQuarterTurns: -2)
        XCTAssertEqual(camera.quarterTurns, 3)
    }

    // MARK: Mapping

    func testWorldToViewMapsCenterToViewportCentre() {
        for turns in allTurns {
            let camera = OverviewCamera(center: CGPoint(x: -1500, y: 700), scale: 0.137, rotation: rotation(turns))
            assertPoint(camera.viewPoint(world: CGPoint(x: -1500, y: 700), viewport: portrait),
                        CGPoint(x: 200, y: 400), "turns \(turns)")
        }
    }

    func testViewWorldRoundTripForAllRotationsWithNegativeOrigin() {
        let worldPoints = [CGPoint(x: -3200, y: -900), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 0),
                           CGPoint(x: 2559.5, y: 1439.25), CGPoint(x: -1500, y: 700)]
        let viewPoints = [CGPoint(x: 0, y: 0), CGPoint(x: 399, y: 799), CGPoint(x: 200, y: 400),
                          CGPoint(x: -250, y: 1200)]
        for turns in allTurns {
            let camera = OverviewCamera(center: CGPoint(x: -1500, y: 700), scale: 0.137, rotation: rotation(turns))
            for world in worldPoints {
                let view = camera.viewPoint(world: world, viewport: portrait)
                assertPoint(camera.worldPoint(view: view, viewport: portrait), world, "world->view->world turns \(turns)")
            }
            for view in viewPoints {
                let world = camera.worldPoint(view: view, viewport: portrait)
                assertPoint(camera.viewPoint(world: world, viewport: portrait), view, "view->world->view turns \(turns)")
            }
        }
    }

    func testScaleIsViewPointsPerWorldPoint() {
        let camera = OverviewCamera(center: .zero, scale: 0.5)
        assertPoint(camera.viewPoint(world: CGPoint(x: 100, y: -60), viewport: portrait), CGPoint(x: 250, y: 370))
    }

    func testViewRectIsTheAxisAlignedProjection() {
        let camera = OverviewCamera(center: CGPoint(x: 100, y: 50), scale: 2, rotation: Double.pi / 2)
        let rect = camera.viewRect(world: CGRect(x: 0, y: 0, width: 200, height: 100), viewport: portrait)
        // A quarter turn swaps the extents: 100 x 200 world -> 200 x 400 view.
        XCTAssertEqual(Double(rect.width), 200, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.height), 400, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midX), 200, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midY), 400, accuracy: 1e-9)
    }

    // MARK: Fit all

    func testFitAllVeryWideArrangementIsLimitedByWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero, margin: 0.08)
        // margin = 0.08 x 400 = 32; available width 336.
        XCTAssertEqual(camera.scale, 336.0 / 3840.0, accuracy: 1e-12)
        let rect = camera.viewRect(world: bounds, viewport: portrait)
        XCTAssertEqual(Double(rect.minX), 32, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.maxX), 368, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midY), 400, accuracy: 1e-9)
    }

    func testFitAllVeryTallArrangementIsLimitedByHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 1080, height: 3840)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: landscape, safeInsets: .zero, margin: 0.08)
        // margin = 0.08 x 400 = 32; available height 336.
        XCTAssertEqual(camera.scale, 336.0 / 3840.0, accuracy: 1e-12)
        let rect = camera.viewRect(world: bounds, viewport: landscape)
        XCTAssertEqual(Double(rect.minY), 32, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.maxY), 368, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midX), 400, accuracy: 1e-9)
    }

    func testFitAllCentresNegativeOriginBounds() {
        let bounds = CGRect(x: -2560, y: -300, width: 5760, height: 1440)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero)
        XCTAssertEqual(camera.center.x, bounds.midX, accuracy: 1e-9)
        XCTAssertEqual(camera.center.y, bounds.midY, accuracy: 1e-9)
        assertPoint(camera.viewPoint(world: CGPoint(x: bounds.midX, y: bounds.midY), viewport: portrait),
                    CGPoint(x: 200, y: 400))
    }

    func testFitAllNeverStretches() {
        let bounds = CGRect(x: 0, y: 0, width: 3000, height: 700)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero)
        let rect = camera.viewRect(world: bounds, viewport: portrait)
        XCTAssertEqual(Double(rect.width / rect.height), Double(bounds.width / bounds.height), accuracy: 1e-9)
    }

    func testFitAllDefaultMarginIsEightPercentOfTheSmallerSide() {
        XCTAssertEqual(OverviewCamera.defaultMargin, 0.08)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero)
        let rect = camera.viewRect(world: bounds, viewport: portrait)
        XCTAssertEqual(Double(rect.minX), 32, accuracy: 1e-9)
    }

    func testFitAllZeroMarginFillsTheLimitingSide() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero, margin: 0)
        XCTAssertEqual(camera.scale, 1, accuracy: 1e-12)
    }

    func testFitAllCentresInsideTheSafeViewport() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let insets = OverviewInsets(top: 100, left: 20, bottom: 0, right: 0)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: insets, margin: 0.08)
        // Safe rect 380 x 700; margin 32 -> available 316 x 636; width limits.
        XCTAssertEqual(camera.scale, 3.16, accuracy: 1e-12)
        assertPoint(camera.viewPoint(world: CGPoint(x: 50, y: 50), viewport: portrait), CGPoint(x: 210, y: 450))
        let rect = camera.viewRect(world: bounds, viewport: portrait)
        XCTAssertEqual(Double(rect.minX), 52, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.maxX), 368, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(Double(rect.minY), 100 + 32 - 1e-9)
    }

    func testFitAllWithARotationSwapsTheLimitingSide() {
        let bounds = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: .zero, margin: 0.08, quarterTurns: 1)
        XCTAssertEqual(camera.rotation, Double.pi / 2, accuracy: 1e-12)
        // Rotated, the 3840 side runs down the 800-tall viewport: 736 available.
        XCTAssertEqual(camera.scale, 736.0 / 3840.0, accuracy: 1e-12)
        let rect = camera.viewRect(world: bounds, viewport: portrait)
        XCTAssertEqual(Double(rect.height), 736, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midX), 200, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midY), 400, accuracy: 1e-9)
    }

    func testFitAllWithRotationAndInsetsCentresInTheSafeRect() {
        let bounds = CGRect(x: -500, y: -200, width: 1000, height: 400)
        let insets = OverviewInsets(top: 60, left: 0, bottom: 20, right: 30)
        for turns in allTurns {
            let camera = OverviewCamera.fitAll(bounds: bounds, viewport: portrait, safeInsets: insets, quarterTurns: turns)
            // Safe rect: x 0...370, y 60...780, centre (185, 420).
            assertPoint(camera.viewPoint(world: CGPoint(x: bounds.midX, y: bounds.midY), viewport: portrait),
                        CGPoint(x: 185, y: 420), "turns \(turns)")
            let rect = camera.viewRect(world: bounds, viewport: portrait)
            XCTAssertGreaterThanOrEqual(Double(rect.minX), -1e-9)
            XCTAssertLessThanOrEqual(Double(rect.maxX), 370 + 1e-9)
            XCTAssertGreaterThanOrEqual(Double(rect.minY), 60 - 1e-9)
            XCTAssertLessThanOrEqual(Double(rect.maxY), 780 + 1e-9)
        }
    }

    func testFitAllWithDegenerateInputsStaysFinite() {
        let empty = OverviewCamera.fitAll(bounds: .zero, viewport: portrait, safeInsets: .zero)
        XCTAssertEqual(empty.scale, 1)
        let badViewport = OverviewCamera.fitAll(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                viewport: .zero, safeInsets: .zero)
        XCTAssertEqual(badViewport.scale, 1)
        XCTAssertEqual(badViewport.center.x, 50, accuracy: 1e-9)
        let hugeInsets = OverviewCamera.fitAll(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                               viewport: portrait,
                                               safeInsets: OverviewInsets(top: 5000, left: 0, bottom: 5000, right: 0))
        XCTAssertTrue(hugeInsets.scale.isFinite)
        XCTAssertGreaterThan(hugeInsets.scale, 0)
    }

    // MARK: Pan

    func testPanMovesTheContentWithTheFingerForAllRotations() {
        let world = CGPoint(x: -700, y: 300)
        for turns in allTurns {
            var camera = OverviewCamera(center: CGPoint(x: -100, y: 40), scale: 0.4, rotation: rotation(turns))
            let before = camera.viewPoint(world: world, viewport: portrait)
            camera.pan(byView: CGVector(dx: 30, dy: -20))
            let after = camera.viewPoint(world: world, viewport: portrait)
            assertPoint(after, CGPoint(x: before.x + 30, y: before.y - 20), "turns \(turns)")
            XCTAssertEqual(camera.scale, 0.4, "pan never changes the scale")
        }
    }

    func testPanIsNeverClamped() {
        var camera = OverviewCamera.fitAll(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           viewport: portrait, safeInsets: .zero)
        camera.pan(byView: CGVector(dx: 1_000_000, dy: -1_000_000))
        let rect = camera.viewRect(world: CGRect(x: 0, y: 0, width: 1920, height: 1080), viewport: portrait)
        XCTAssertGreaterThan(Double(rect.minX), 900_000)
        XCTAssertLessThan(Double(rect.maxY), -900_000)
    }

    // MARK: Zoom

    private let wideLimits = ZoomLimits(min: 0.001, max: 100)

    func testZoomKeepsTheAnchorWorldPointFixedForAllRotations() {
        let anchor = CGPoint(x: 120, y: 640)
        for turns in allTurns {
            for factor in [0.5, 0.9, 1.0, 1.7, 3.0] {
                var camera = OverviewCamera(center: CGPoint(x: -500, y: 300), scale: 0.2, rotation: rotation(turns))
                let anchorWorld = camera.worldPoint(view: anchor, viewport: portrait)
                camera.zoom(by: factor, anchorView: anchor, viewport: portrait, limits: wideLimits)
                XCTAssertEqual(camera.scale, 0.2 * factor, accuracy: 1e-12)
                let drifted = camera.worldPoint(view: anchor, viewport: portrait)
                XCTAssertLessThan(abs(Double(drifted.x - anchorWorld.x)), 1e-6, "turns \(turns) factor \(factor)")
                XCTAssertLessThan(abs(Double(drifted.y - anchorWorld.y)), 1e-6, "turns \(turns) factor \(factor)")
                let back = camera.viewPoint(world: anchorWorld, viewport: portrait)
                XCTAssertLessThan(abs(Double(back.x - anchor.x)), 1e-6)
                XCTAssertLessThan(abs(Double(back.y - anchor.y)), 1e-6)
            }
        }
    }

    func testZoomAtTheViewportCentreKeepsTheCenter() {
        var camera = OverviewCamera(center: CGPoint(x: 12, y: -34), scale: 1)
        camera.zoom(by: 2, anchorView: CGPoint(x: 200, y: 400), viewport: portrait, limits: wideLimits)
        assertPoint(camera.center, CGPoint(x: 12, y: -34))
    }

    func testZoomClampsToTheLimitsAndStillKeepsTheAnchor() {
        let limits = ZoomLimits(min: 0.1, max: 2)
        let anchor = CGPoint(x: 50, y: 700)
        for turns in allTurns {
            var camera = OverviewCamera(center: CGPoint(x: 300, y: -200), scale: 1, rotation: rotation(turns))
            let anchorWorld = camera.worldPoint(view: anchor, viewport: portrait)

            camera.zoom(by: 100, anchorView: anchor, viewport: portrait, limits: limits)
            XCTAssertEqual(camera.scale, 2, "turns \(turns)")
            assertPoint(camera.worldPoint(view: anchor, viewport: portrait), anchorWorld, accuracy: 1e-6)

            camera.zoom(by: 0.0001, anchorView: anchor, viewport: portrait, limits: limits)
            XCTAssertEqual(camera.scale, 0.1, accuracy: 1e-12, "turns \(turns)")
            assertPoint(camera.worldPoint(view: anchor, viewport: portrait), anchorWorld, accuracy: 1e-6)
        }
    }

    func testZoomIgnoresInvalidFactors() {
        var camera = OverviewCamera(center: CGPoint(x: 1, y: 2), scale: 0.5)
        let original = camera
        for factor in [0.0, -2.0, Double.nan, Double.infinity] {
            camera.zoom(by: factor, anchorView: CGPoint(x: 10, y: 10), viewport: portrait, limits: wideLimits)
            XCTAssertEqual(camera, original)
        }
    }

    func testZoomDoesNotSnapOrPushFurtherWhenAlreadyOutsideTheLimits() {
        let limits = ZoomLimits(min: 1, max: 2)
        let anchor = CGPoint(x: 10, y: 10)

        var tooFarOut = OverviewCamera(center: .zero, scale: 0.5)
        tooFarOut.zoom(by: 0.5, anchorView: anchor, viewport: portrait, limits: limits)
        XCTAssertEqual(tooFarOut.scale, 0.5, "zooming further out does nothing")
        tooFarOut.zoom(by: 1.2, anchorView: anchor, viewport: portrait, limits: limits)
        XCTAssertEqual(tooFarOut.scale, 0.6, accuracy: 1e-12, "zooming in is allowed and does not snap to the limit")

        var tooFarIn = OverviewCamera(center: .zero, scale: 4)
        tooFarIn.zoom(by: 2, anchorView: anchor, viewport: portrait, limits: limits)
        XCTAssertEqual(tooFarIn.scale, 4, "zooming further in does nothing")
        tooFarIn.zoom(by: 0.5, anchorView: anchor, viewport: portrait, limits: limits)
        XCTAssertEqual(tooFarIn.scale, 2, accuracy: 1e-12)
    }

    // MARK: Zoom limits

    func testMinimumIsHalfOfFitAll() {
        let limits = ZoomLimits.limits(fitAllScale: 0.3, focusedDisplayPixelsPerPoint: 2, viewDisplayScale: 3)
        XCTAssertEqual(limits.min, 0.15, accuracy: 1e-12)
    }

    func testMaximumIsEightTimesTheOneToOneScaleOfTheFocusedDisplay() {
        // Retina Mac (2 source px per point) on a 3x receiver: one source
        // pixel == one receiver pixel at 2/3 view points per world point.
        let limits = ZoomLimits.limits(fitAllScale: 0.3, focusedDisplayPixelsPerPoint: 2, viewDisplayScale: 3)
        XCTAssertEqual(limits.max, 8 * 2.0 / 3.0, accuracy: 1e-12)
        // A 1x Mac display on a 2x receiver: 0.5 view points per world point.
        let low = ZoomLimits.limits(fitAllScale: 0.3, focusedDisplayPixelsPerPoint: 1, viewDisplayScale: 2)
        XCTAssertEqual(low.max, 4, accuracy: 1e-12)
    }

    func testMaximumIsFarAboveEightTimesFitAllForASmallFitScale() {
        let fit = 0.02 // a very wide arrangement on a phone
        let limits = ZoomLimits.limits(fitAllScale: fit, focusedDisplayPixelsPerPoint: 2, viewDisplayScale: 3)
        XCTAssertGreaterThan(limits.max, 8 * fit * 10)
        XCTAssertEqual(limits.max / fit, 8 * (2.0 / 3.0) / fit, accuracy: 1e-9)
        XCTAssertEqual(limits.min, 0.01, accuracy: 1e-12)
    }

    func testMaximumNeverDropsBelowFitAll() {
        // A tiny arrangement that fit-all already magnifies beyond 8:1.
        let limits = ZoomLimits.limits(fitAllScale: 5, focusedDisplayPixelsPerPoint: 1, viewDisplayScale: 3)
        XCTAssertEqual(limits.max, 5, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(limits.max, limits.min)
    }

    func testInvalidLimitInputsFallBackToOne() {
        let limits = ZoomLimits.limits(fitAllScale: .nan, focusedDisplayPixelsPerPoint: 0, viewDisplayScale: -1)
        XCTAssertEqual(limits.min, 0.5)
        XCTAssertEqual(limits.max, 8)
    }

    func testClampedKeepsScaleInsideTheRange() {
        let limits = ZoomLimits(min: 0.5, max: 4)
        XCTAssertEqual(limits.clamped(0.1), 0.5)
        XCTAssertEqual(limits.clamped(2), 2)
        XCTAssertEqual(limits.clamped(10), 4)
    }

    // MARK: Zoom to selection

    func testFrameSelectedDisplayCentresAndFitsIt() {
        let all = OverviewCamera.fitAll(bounds: CGRect(x: -1920, y: -500, width: 6400, height: 2000),
                                        viewport: portrait, safeInsets: .zero)
        let display = OverviewDisplay(id: 2, frame: CGRect(x: 1920, y: -200, width: 2560, height: 1440))
        let camera = all.frame(selectedDisplay: display, viewport: portrait, safeInsets: .zero)
        // Margin 0.04 x 400 = 16; available width 368; the width limits.
        XCTAssertEqual(camera.scale, 368.0 / 2560.0, accuracy: 1e-12)
        let rect = camera.viewRect(world: display.frame, viewport: portrait)
        XCTAssertEqual(Double(rect.minX), 16, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.maxX), 384, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midY), 400, accuracy: 1e-9)
        XCTAssertGreaterThan(camera.scale, all.scale)
    }

    func testFrameSelectedDisplayKeepsTheReceiverRotation() {
        var all = OverviewCamera.fitAll(bounds: CGRect(x: 0, y: 0, width: 3840, height: 1080),
                                        viewport: portrait, safeInsets: .zero)
        all.rotate(byQuarterTurns: 1)
        let display = OverviewDisplay(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let camera = all.frame(selectedDisplay: display, viewport: portrait, safeInsets: .zero)
        XCTAssertEqual(camera.quarterTurns, 1)
        let rect = camera.viewRect(world: display.frame, viewport: portrait)
        // Rotated, the 1080 side runs along x: 368 available.
        XCTAssertEqual(camera.scale, min(368.0 / 1080.0, 768.0 / 1920.0), accuracy: 1e-12)
        XCTAssertEqual(Double(rect.midX), 200, accuracy: 1e-9)
        XCTAssertEqual(Double(rect.midY), 400, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(Double(rect.minX), 16 - 1e-9)
        XCTAssertLessThanOrEqual(Double(rect.maxX), 384 + 1e-9)
        XCTAssertGreaterThanOrEqual(Double(rect.minY), 16 - 1e-9)
        XCTAssertLessThanOrEqual(Double(rect.maxY), 784 + 1e-9)
    }

    func testFrameSelectedDisplayRespectsSafeInsets() {
        let all = OverviewCamera(center: .zero, scale: 1)
        let display = OverviewDisplay(id: 1, frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        let insets = OverviewInsets(top: 100, left: 0, bottom: 0, right: 0)
        let camera = all.frame(selectedDisplay: display, viewport: portrait, safeInsets: insets)
        assertPoint(camera.viewPoint(world: CGPoint(x: display.frame.midX, y: display.frame.midY), viewport: portrait),
                    CGPoint(x: 200, y: 450))
    }

    // MARK: Recovery visibility

    private let arrangement = CGRect(x: -1920, y: 0, width: 5760, height: 1080)

    func testArrangementIsVisibleAfterFitAll() {
        let camera = OverviewCamera.fitAll(bounds: arrangement, viewport: portrait, safeInsets: .zero)
        XCTAssertTrue(camera.isArrangementVisible(bounds: arrangement, viewport: portrait))
    }

    func testArrangementPannedFarAwayIsNotVisibleForAllRotations() {
        for turns in allTurns {
            for delta in [CGVector(dx: 5000, dy: 0), CGVector(dx: -5000, dy: 0),
                          CGVector(dx: 0, dy: 5000), CGVector(dx: 0, dy: -5000)] {
                var camera = OverviewCamera.fitAll(bounds: arrangement, viewport: portrait, safeInsets: .zero,
                                                   quarterTurns: turns)
                camera.pan(byView: delta)
                XCTAssertFalse(camera.isArrangementVisible(bounds: arrangement, viewport: portrait),
                               "turns \(turns) delta \(delta)")
            }
        }
    }

    func testArrangementWithASliverInsideIsStillVisible() {
        var camera = OverviewCamera.fitAll(bounds: arrangement, viewport: portrait, safeInsets: .zero)
        let rect = camera.viewRect(world: arrangement, viewport: portrait)
        camera.pan(byView: CGVector(dx: 399 - rect.minX, dy: 0))
        XCTAssertTrue(camera.isArrangementVisible(bounds: arrangement, viewport: portrait))
    }

    func testArrangementJustBeyondTheEdgeIsNotVisible() {
        var camera = OverviewCamera.fitAll(bounds: arrangement, viewport: portrait, safeInsets: .zero)
        let rect = camera.viewRect(world: arrangement, viewport: portrait)
        camera.pan(byView: CGVector(dx: 401 - rect.minX, dy: 0))
        XCTAssertFalse(camera.isArrangementVisible(bounds: arrangement, viewport: portrait))
    }

    func testArrangementCoveringTheWholeViewportIsVisible() {
        var camera = OverviewCamera.fitAll(bounds: arrangement, viewport: portrait, safeInsets: .zero)
        camera.zoom(by: 40, anchorView: CGPoint(x: 200, y: 400), viewport: portrait,
                    limits: ZoomLimits(min: 0.001, max: 1000))
        let rect = camera.viewRect(world: arrangement, viewport: portrait)
        XCTAssertTrue(rect.contains(CGRect(origin: .zero, size: portrait)), "the edges are all off screen")
        XCTAssertTrue(camera.isArrangementVisible(bounds: arrangement, viewport: portrait))
    }

    func testEmptyBoundsAreNeverVisible() {
        let camera = OverviewCamera(center: .zero, scale: 1)
        XCTAssertFalse(camera.isArrangementVisible(bounds: .null, viewport: portrait))
        XCTAssertFalse(camera.isArrangementVisible(bounds: .zero, viewport: portrait))
    }
}
