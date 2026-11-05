import AppKit
import XCTest

/// Request panels (pairing, input control, display request, Files) appear in
/// front of the person at this Mac without taking focus (#191). These check
/// the window configuration and placement rules. Whether macOS actually shows
/// the panel over a full-screen app, on another Space or with Stage Manager
/// needs a check on a real Mac.
@MainActor
final class SecurityPanelPlacementTests: XCTestCase {
    private let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let right = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    // MARK: Panel configuration

    func testRequestPanelNeverActivatesAndStaysUp() {
        _ = NSApplication.shared
        let panel = SecurityPanelPlacement.makePanel(title: "Pairing Request",
                                                     contentRect: NSRect(x: 0, y: 0, width: 380, height: 240))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "Appearing must never take the keyboard")
        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.closable), "The close button stays: closing is a rejection")
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .modalPanel)
        XCTAssertFalse(panel.hidesOnDeactivate, "Clicking another app must not hide a pending request")
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isVisible, "Making a panel doesn't show it")
        XCTAssertEqual(panel.title, "Pairing Request")
    }

    func testRequestPanelFollowsTheOwnerAcrossSpacesAndFullScreen() {
        _ = NSApplication.shared
        let panel = SecurityPanelPlacement.makePanel(title: "Control Request",
                                                     contentRect: NSRect(x: 0, y: 0, width: 380, height: 1))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace),
                       "Can't be combined with joining every Space")
        XCTAssertFalse(panel.collectionBehavior.contains(.ignoresCycle))
    }

    // MARK: Which display

    func testOpensOnTheDisplayUnderThePointer() {
        let screens: [(id: CGDirectDisplayID?, frame: CGRect)] = [(1, left), (2, right)]
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: screens, pointer: CGPoint(x: 2000, y: 700),
                                                           avoiding: []), 1)
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: screens, pointer: CGPoint(x: 300, y: 300),
                                                           avoiding: []), 0)
    }

    func testNeverOpensOnADisplayADeviceIsViewing() {
        let screens: [(id: CGDirectDisplayID?, frame: CGRect)] = [(1, left), (7, right)]
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: screens, pointer: CGPoint(x: 2000, y: 700),
                                                           avoiding: [7]), 0,
                       "Pointer on a streamed virtual display: the request opens on this Mac's own display")
    }

    func testFallsBackToTheMenuBarDisplay() {
        let screens: [(id: CGDirectDisplayID?, frame: CGRect)] = [(1, left), (2, right)]
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: screens, pointer: CGPoint(x: -500, y: -500),
                                                           avoiding: []), 0)
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: [(7, right), (1, left)],
                                                           pointer: CGPoint(x: -500, y: -500), avoiding: [7]), 1)
    }

    func testOnlyAStreamedDisplayStillShowsTheRequest() {
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: [(7, right)], pointer: .zero, avoiding: [7]), 0,
                       "A request nobody can see would just time out")
        XCTAssertNil(SecurityPanelPlacement.displayIndex(screens: [], pointer: .zero, avoiding: []))
    }

    func testADisplayWithoutAnIDIsAllowed() {
        let screens: [(id: CGDirectDisplayID?, frame: CGRect)] = [(nil, left)]
        XCTAssertEqual(SecurityPanelPlacement.displayIndex(screens: screens, pointer: CGPoint(x: 10, y: 10),
                                                           avoiding: [7]), 0)
    }

    // MARK: Where on the display

    func testCentredAcrossAndAboveTheMiddle() {
        let visible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let origin = SecurityPanelPlacement.origin(for: CGSize(width: 380, height: 240), in: visible)
        XCTAssertEqual(origin.x, 1512 + (2560 - 380) / 2)
        XCTAssertGreaterThan(origin.y + 120, visible.midY, "Above the middle, like NSWindow.center()")
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: CGSize(width: 380, height: 240))))
    }

    func testAnOversizedPanelKeepsItsTitleBarOnScreen() {
        let visible = CGRect(x: 0, y: 25, width: 300, height: 200)
        let origin = SecurityPanelPlacement.origin(for: CGSize(width: 380, height: 240), in: visible)
        XCTAssertEqual(origin.x, 0, "Left edge visible")
        XCTAssertEqual(origin.y + 240, visible.maxY, "Top edge (title bar, close button) visible")
    }

    // MARK: Repeated requests

    func testAShowingPanelOnTheChosenDisplayStaysPut() {
        XCTAssertFalse(SecurityPanelPlacement.shouldMove(isVisible: true, currentDisplay: 1, chosenDisplay: 1),
                       "A repeated request never moves buttons under the cursor")
    }

    func testAShowingPanelOnAnotherDisplayMoves() {
        XCTAssertTrue(SecurityPanelPlacement.shouldMove(isVisible: true, currentDisplay: 0, chosenDisplay: 1))
        XCTAssertTrue(SecurityPanelPlacement.shouldMove(isVisible: true, currentDisplay: nil, chosenDisplay: 1))
    }

    func testAHiddenPanelIsPlacedAfresh() {
        XCTAssertTrue(SecurityPanelPlacement.shouldMove(isVisible: false, currentDisplay: nil, chosenDisplay: 0))
        XCTAssertFalse(SecurityPanelPlacement.shouldMove(isVisible: false, currentDisplay: nil, chosenDisplay: nil))
        XCTAssertFalse(SecurityPanelPlacement.shouldMove(isVisible: true, currentDisplay: 0, chosenDisplay: nil))
    }
}
