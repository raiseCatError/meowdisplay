import XCTest

/// Window mode in View Only (owner report 2026-10-30): choosing a pane stays local, a touch meant
/// for the Mac never leaves the device and offers Request Control instead, and the request flow
/// keeps its states, rate limits and no-replay rule.
final class PaneRequestControlTests: XCTestCase {
    private let pv = WireProtocol.allowInputWireVersion

    func testSelectingAPaneIsNotAnAttemptAtTheMac() {
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: false, selectedPane: true))
        XCTAssertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: false, selectedPane: false),
                      "a tap in the already selected pane is meant for the window")
        XCTAssertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 3, moveViewActive: false))
    }

    func testLocalPanAndZoomAreNeverAttempts() {
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 2, moveViewActive: false), "two fingers: pan and zoom")
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: true), "Move View is local")
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 0, moveViewActive: false))
    }

    func testViewOnlyForwardsNothingUntilTheMacGrantsControl() {
        for state: SessionInputWireState in [.off, .requesting, .notAllowed, .requestsDisabled] {
            XCTAssertFalse(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv, macState: state), "\(state)")
        }
        XCTAssertTrue(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv, macState: .allowed),
                      "granted: input works at once, still in Window mode")
        XCTAssertFalse(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: false, macPV: pv, macState: .allowed))
        XCTAssertFalse(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: false, localAllow: true, macPV: pv, macState: .allowed),
                       "disconnected or reconnecting: nothing leaves the device")
        XCTAssertTrue(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv - 1, macState: .off),
                      "a Mac too old to report control keeps today's behavior")
    }

    func testTheRequestIsNeverSpammedAndADenialOffersASafeRetry() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertEqual(prompt.blockedAttempt(now: 10, userTurnedOff: false, autoRequest: false), [], "an attempt only shows the pill")
        XCTAssertEqual(prompt.kind, .requestInput)
        XCTAssertEqual(prompt.requestTapped(now: 11), [.sendRequest])
        prompt.inputStateChanged(.requesting, now: 11.1)
        XCTAssertEqual(prompt.kind, .requesting)
        XCTAssertEqual(prompt.requestTapped(now: 11.5), [], "no second request while one waits")
        prompt.inputStateChanged(.notAllowed, now: 13)
        XCTAssertEqual(prompt.kind, .requestInput, "denied: Request Control again, not stuck")
        XCTAssertEqual(prompt.requestTapped(now: 13.2), [.sendRequest], "retry after the minimum interval")
        prompt.inputStateChanged(.requesting, now: 13.3)
        prompt.inputStateChanged(.allowed, now: 15)
        XCTAssertEqual(prompt.kind, .enabled, "granted is shown briefly; the touch that asked is not replayed")
        XCTAssertEqual(prompt.blockedAttempt(now: 15.5, userTurnedOff: false, autoRequest: true), [], "allowed: nothing blocked")
    }

    func testDisconnectClearsThePillAndReconnectStartsClean() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        _ = prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: false)
        prompt.setSessionLive(false)
        XCTAssertNil(prompt.kind)
        XCTAssertEqual(prompt.blockedAttempt(now: 2, userTurnedOff: false, autoRequest: false), [])
        XCTAssertNil(prompt.kind, "no pill without a live session")
        prompt.setSessionLive(true)
        _ = prompt.blockedAttempt(now: 3, userTurnedOff: false, autoRequest: false)
        XCTAssertEqual(prompt.kind, .requestInput)
    }

    /// Owner report 2026-10-31 (iPad): scrolling only panned a zoomed pane.
    func testATwoFingerDragScrollsTheMacWithControlAndMovesThePaneOtherwise() {
        XCTAssertTrue(WorkspaceTwoFingerPolicy.scrollsMac(isPinch: false, inputReachesMac: true, moveViewActive: false))
        XCTAssertFalse(WorkspaceTwoFingerPolicy.scrollsMac(isPinch: true, inputReachesMac: true, moveViewActive: false), "a pinch zooms the pane")
        XCTAssertFalse(WorkspaceTwoFingerPolicy.scrollsMac(isPinch: false, inputReachesMac: false, moveViewActive: false), "View Only: pan stays local")
        XCTAssertFalse(WorkspaceTwoFingerPolicy.scrollsMac(isPinch: false, inputReachesMac: true, moveViewActive: true), "Move View moves the view")
    }

    /// Owner report 2026-10-31 (iPad, Chrome): web text 13 groups deep never scrolled.
    func testDeepWebContentIsStillScrollable() {
        let chrome = ["AXStaticText"] + Array(repeating: "AXGroup", count: 20) + ["AXWebArea", "AXGroup", "AXWindow"]
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: chrome), .scrollable(container: "AXWebArea"))
    }
}
