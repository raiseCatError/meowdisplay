import CoreGraphics
import Foundation
import XCTest

/// The overview's Mac cursor: what the Mac sends (rounding, 10 Hz, only on change, watch expiry),
/// what the receiver accepts, and where the glyph is drawn.
final class OverviewCursorTests: XCTestCase {
    private let listed: [(id: UInt32, frame: CGRect)] = [
        (id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        (id: 2, frame: CGRect(x: -2560, y: -300, width: 2560, height: 1440)),
    ]

    private func sample(_ x: Double, _ y: Double, display: UInt32? = 1) -> OverviewCursorSample {
        OverviewCursorSample(x: x, y: y, display: display)
    }

    private func watchingThrottle(at now: Double = 100) -> OverviewCursorThrottle {
        var throttle = OverviewCursorThrottle()
        throttle.watch(on: true, now: now)
        return throttle
    }

    // MARK: Sample

    func testSampleRoundsToATenthAndFindsTheListedDisplay() {
        let made = OverviewCursorSample.make(point: CGPoint(x: 100.04, y: 200.06), listed: listed)
        XCTAssertEqual(made, OverviewCursorSample(x: 100.0, y: 200.1, display: 1))
        let left = OverviewCursorSample.make(point: CGPoint(x: -1000.26, y: 0), listed: listed)
        XCTAssertEqual(left, OverviewCursorSample(x: -1000.3, y: 0, display: 2))
    }

    func testSampleOnNoListedDisplayOmitsTheDisplayAndNonFiniteIsRejected() {
        XCTAssertNil(OverviewCursorSample.make(point: CGPoint(x: 5000, y: 5000), listed: listed)?.display)
        XCTAssertNotNil(OverviewCursorSample.make(point: CGPoint(x: 5000, y: 5000), listed: listed))
        XCTAssertNil(OverviewCursorSample.make(point: CGPoint(x: Double.nan, y: 0), listed: listed))
        XCTAssertNil(OverviewCursorSample.make(point: CGPoint(x: 0, y: Double.infinity), listed: listed))
    }

    func testWireCarriesTypeCoordinatesAndOptionalDisplay() {
        let withDisplay = sample(1.5, -2.5, display: 7).wire
        XCTAssertEqual(withDisplay["type"] as? String, "overviewCursor")
        XCTAssertEqual(withDisplay["x"] as? Double, 1.5)
        XCTAssertEqual(withDisplay["y"] as? Double, -2.5)
        XCTAssertEqual(withDisplay["d"] as? Int, 7)
        XCTAssertNil(sample(1, 2, display: nil).wire["d"])
    }

    // MARK: Throttle

    func testNothingIsSentWithoutAWatch() {
        var throttle = OverviewCursorThrottle()
        XCTAssertNil(throttle.admit(sample(1, 1), now: 100))
        XCTAssertFalse(throttle.isWatching(now: 100))
    }

    func testFirstSampleAfterTheWatchGoesOutAtOnce() {
        var throttle = watchingThrottle()
        XCTAssertEqual(throttle.admit(sample(1, 1), now: 100), sample(1, 1))
    }

    func testAtMostTenPerSecond() {
        var throttle = watchingThrottle()
        XCTAssertNotNil(throttle.admit(sample(1, 1), now: 100))
        XCTAssertNil(throttle.admit(sample(2, 1), now: 100.05))
        XCTAssertNil(throttle.admit(sample(3, 1), now: 100.099))
        // The held-back position is sent at the next opportunity, not lost.
        XCTAssertEqual(throttle.admit(sample(3, 1), now: 100.11), sample(3, 1))
        var sent = 0
        var time = 200.0
        var x = 0.0
        var busy = watchingThrottle(at: 200)
        while time < 201 {
            x += 1
            if busy.admit(sample(x, 0), now: time) != nil { sent += 1 }
            time += 0.01
        }
        XCTAssertLessThanOrEqual(sent, 10)
        XCTAssertGreaterThanOrEqual(sent, 9)
    }

    func testOnlyWhenTheRoundedPositionOrDisplayChanged() {
        var throttle = watchingThrottle()
        XCTAssertNotNil(throttle.admit(sample(10, 10), now: 100))
        XCTAssertNil(throttle.admit(sample(10, 10), now: 101))
        XCTAssertNil(throttle.admit(nil, now: 102))
        XCTAssertNotNil(throttle.admit(sample(10.1, 10), now: 103))
        XCTAssertNotNil(throttle.admit(sample(10.1, 10, display: 2), now: 104))
        XCTAssertNotNil(throttle.admit(sample(10.1, 10, display: nil), now: 105))
    }

    func testRoundingHelperKeepsOneDecimal() {
        XCTAssertEqual(OverviewCursorSample.rounded(12.34), 12.3)
        XCTAssertEqual(OverviewCursorSample.rounded(-12.36), -12.4)
        XCTAssertEqual(OverviewCursorSample.rounded(5), 5)
    }

    // MARK: Watch expiry

    func testWatchExpiresAfter120SecondsWithoutARenewal() {
        var throttle = watchingThrottle(at: 100)
        XCTAssertTrue(throttle.isWatching(now: 219.9))
        XCTAssertFalse(throttle.isWatching(now: 220))
        XCTAssertNil(throttle.admit(sample(1, 1), now: 220))
    }

    func testARenewalExtendsTheWatchWithoutResendingTheSamePosition() {
        var throttle = watchingThrottle(at: 100)
        XCTAssertNotNil(throttle.admit(sample(1, 1), now: 100))
        throttle.watch(on: true, now: 160)
        XCTAssertTrue(throttle.isWatching(now: 270))
        XCTAssertNil(throttle.admit(sample(1, 1), now: 270))
        XCTAssertFalse(throttle.isWatching(now: 280))
    }

    func testWatchOffStopsAndTheNextWatchSendsAgain() {
        var throttle = watchingThrottle(at: 100)
        XCTAssertNotNil(throttle.admit(sample(1, 1), now: 100))
        throttle.watch(on: false, now: 101)
        XCTAssertFalse(throttle.isWatching(now: 101))
        XCTAssertNil(throttle.admit(sample(2, 2), now: 102))
        throttle.watch(on: true, now: 103)
        XCTAssertEqual(throttle.admit(sample(1, 1), now: 103), sample(1, 1))
    }

    func testResetEndsTheWatch() {
        var throttle = watchingThrottle()
        throttle.reset()
        XCTAssertFalse(throttle.isWatching(now: 100))
    }

    // MARK: Receiver parsing

    func testParseReadsPointAndDisplay() {
        let cursor = OverviewCursor.parse(["x": 12.5, "y": -30, "d": 4])
        XCTAssertEqual(cursor, OverviewCursor(point: CGPoint(x: 12.5, y: -30), display: 4))
    }

    func testParseWithoutDisplayHasNoDisplay() {
        XCTAssertEqual(OverviewCursor.parse(["x": 1, "y": 2]), OverviewCursor(point: CGPoint(x: 1, y: 2), display: nil))
        XCTAssertNotNil(OverviewCursor.parse(["x": 1, "y": 2, "d": "x"]))
        XCTAssertNil(OverviewCursor.parse(["x": 1, "y": 2, "d": "x"])?.display)
        XCTAssertNil(OverviewCursor.parse(["x": 1, "y": 2, "d": -3])?.display)
    }

    func testParseRejectsMissingNonFiniteAndAbsurdCoordinates() {
        XCTAssertNil(OverviewCursor.parse(["y": 2]))
        XCTAssertNil(OverviewCursor.parse(["x": 1]))
        XCTAssertNil(OverviewCursor.parse(["x": "1", "y": 2]))
        XCTAssertNil(OverviewCursor.parse(["x": Double.nan, "y": 2]))
        XCTAssertNil(OverviewCursor.parse(["x": 1, "y": Double.infinity]))
        XCTAssertNil(OverviewCursor.parse(["x": 1e12, "y": 2]))
    }

    func testWorkspaceEventParsesTheCursorMessage() {
        guard case .overviewCursor(let cursor)? = WorkspaceEvent.parse(type: DisplayActionsWire.overviewCursor,
                                                                       ["x": 3.0, "y": 4.0, "d": 9]) else {
            return XCTFail("expected an overviewCursor event")
        }
        XCTAssertEqual(cursor.display, 9)
        XCTAssertNil(WorkspaceEvent.parse(type: DisplayActionsWire.overviewCursor, ["x": Double.nan, "y": 4.0]))
    }

    func testWatchRequestShape() {
        let on = WorkspaceRequests.overviewCursorWatch(on: true)
        XCTAssertEqual(on["type"] as? String, "overviewCursorWatch")
        XCTAssertEqual(on["on"] as? Bool, true)
        XCTAssertEqual(WorkspaceRequests.overviewCursorWatch(on: false)["on"] as? Bool, false)
    }

    // MARK: Glyph placement

    func testGlyphIsDrawnAtTheCameraPointInsideTheViewport() {
        let viewport = CGSize(width: 400, height: 700)
        let camera = OverviewCamera(center: CGPoint(x: 1000, y: 500), scale: 0.5)
        let tip = OverviewCursorGlyph.viewPoint(world: CGPoint(x: 1100, y: 540), camera: camera, viewport: viewport)
        XCTAssertEqual(Double(tip?.x ?? -1), 250, accuracy: 0.001)
        XCTAssertEqual(Double(tip?.y ?? -1), 370, accuracy: 0.001)
    }

    func testGlyphIsNotDrawnOutsideTheViewport() {
        let viewport = CGSize(width: 400, height: 700)
        let camera = OverviewCamera(center: CGPoint(x: 1000, y: 500), scale: 0.5)
        XCTAssertNil(OverviewCursorGlyph.viewPoint(world: CGPoint(x: 5000, y: 500), camera: camera, viewport: viewport))
        XCTAssertNil(OverviewCursorGlyph.viewPoint(world: CGPoint(x: 1000, y: -2000), camera: camera, viewport: viewport))
    }

    func testGlyphNeedsAViewportAndFiniteInputs() {
        let camera = OverviewCamera(center: .zero, scale: 1)
        XCTAssertNil(OverviewCursorGlyph.viewPoint(world: .zero, camera: camera, viewport: .zero))
        XCTAssertNil(OverviewCursorGlyph.viewPoint(world: CGPoint(x: Double.nan, y: 0), camera: camera,
                                                   viewport: CGSize(width: 100, height: 100)))
    }

    func testGlyphFollowsTheCameraAndKeepsOnScreenSizeFixed() {
        // Zooming moves the glyph's position but the size is a constant, never scaled.
        let viewport = CGSize(width: 400, height: 700)
        let near = OverviewCamera(center: .zero, scale: 0.1)
        let far = OverviewCamera(center: .zero, scale: 2)
        let a = OverviewCursorGlyph.viewPoint(world: CGPoint(x: 50, y: 0), camera: near, viewport: viewport)
        let b = OverviewCursorGlyph.viewPoint(world: CGPoint(x: 50, y: 0), camera: far, viewport: viewport)
        XCTAssertEqual(Double(a?.x ?? 0), 205, accuracy: 0.001)
        XCTAssertEqual(Double(b?.x ?? 0), 300, accuracy: 0.001)
        XCTAssertEqual(OverviewCursorGlyph.pointSize, 18)
    }
}
