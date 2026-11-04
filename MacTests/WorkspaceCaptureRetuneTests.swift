import CoreGraphics
import XCTest

/// Window view resizes a pane's capture when its window's frame changes (#138).
final class WorkspaceCaptureRetuneTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let fullScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testAWindowEnteringOrLeavingFullScreenRetunes() {
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: fullScreen],
                                                    oldStates: ["a": "live"], newStates: ["a": "live"]))
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: fullScreen], newFrames: [7: window],
                                                    oldStates: ["a": "live"], newStates: ["a": "live"]))
    }

    func testAResizedOrMovedWindowRetunes() {
        // A move can land on a display with another scale, which changes the capture size.
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: window.insetBy(dx: 10, dy: 0)],
                                                    oldStates: [:], newStates: [:]))
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: window.offsetBy(dx: 2000, dy: 0)],
                                                    oldStates: [:], newStates: [:]))
    }

    func testATileGoingOffScreenOrComingBackRetunes() {
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: window],
                                                    oldStates: ["a": "live"], newStates: ["a": "offscreen"]))
        XCTAssertTrue(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: window],
                                                    oldStates: ["a": "offscreen"], newStates: ["a": "live"]))
    }

    func testAnUnchangedListingDoesNot() {
        XCTAssertFalse(WorkspaceCaptureRetune.needed(oldFrames: [7: window, 9: fullScreen], newFrames: [7: window, 9: fullScreen],
                                                     oldStates: ["a": "live", "b": "waiting"], newStates: ["a": "live", "b": "live"]))
    }

    func testANewOrRemovedTileIsLeftToItsOwnCaptureSetup() {
        // A new window's capture starts at the right size; a removed one stops.
        XCTAssertFalse(WorkspaceCaptureRetune.needed(oldFrames: [7: window], newFrames: [7: window, 9: fullScreen],
                                                     oldStates: ["a": "live"], newStates: ["a": "live", "b": "waiting"]))
        XCTAssertFalse(WorkspaceCaptureRetune.needed(oldFrames: [7: window, 9: fullScreen], newFrames: [7: window],
                                                     oldStates: ["a": "live", "b": "live"], newStates: ["a": "live"]))
    }
}
