import XCTest

/// Session Actions: touch and hold Settings on iPhone/iPad (ReceiverSessionActions.swift).
final class ReceiverSessionActionsTests: XCTestCase {

    // MARK: When it is offered

    func testOfferedOnlyForAConnectedSessionOnScreen() {
        XCTAssertTrue(ReceiverSessionActionsPolicy.available(sessionConnected: true, sessionOnScreen: true))
        XCTAssertFalse(ReceiverSessionActionsPolicy.available(sessionConnected: false, sessionOnScreen: true),
                       "recovering or disconnected: the interruption card owns that")
        XCTAssertFalse(ReceiverSessionActionsPolicy.available(sessionConnected: true, sessionOnScreen: false),
                       "Home over a kept session, or the demo")
    }

    func testHoldNeverOpensOverAPaletteOrAFadedControl() {
        XCTAssertTrue(ReceiverSessionActionsPolicy.holdOpens(available: true, paletteOpen: false, settingsControlVisible: true))
        XCTAssertFalse(ReceiverSessionActionsPolicy.holdOpens(available: true, paletteOpen: true, settingsControlVisible: true),
                       "a wheel segment can sit over the gear")
        XCTAssertFalse(ReceiverSessionActionsPolicy.holdOpens(available: true, paletteOpen: false, settingsControlVisible: false),
                       "Auto-hide faded the control: a touch there belongs to the Mac")
        XCTAssertFalse(ReceiverSessionActionsPolicy.holdOpens(available: false, paletteOpen: false, settingsControlVisible: true))
    }

    func testBackToHomeOnlyWithARetainedSurface() {
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: true, presentation: .session),
                       [.backToHome, .disconnect])
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: false, presentation: .session),
                       [.disconnect])
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: true,
                                                            presentation: .homeKeepingSession(macPeerID: "mac")),
                       [.disconnect], "already on Home")
    }

    // MARK: Input gating

    func testNoInputReachesTheMacWhileTheOverlayIsUp() {
        var state = ReceiverSessionActionsState()
        func reaches() -> Bool {
            BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true,
                                                      macPV: WireProtocol.allowInputWireVersion, macState: .allowed,
                                                      surfaceInteractive: state.surfaceInteractive(.session))
        }
        XCTAssertTrue(reaches())
        XCTAssertTrue(state.open(keyboardActive: false))
        XCTAssertFalse(state.surfaceInteractive(.session))
        XCTAssertFalse(reaches())
        _ = state.dismiss()
        XCTAssertTrue(reaches(), "Cancel gives input back")
    }

    func testHomeStillBlocksInputAfterTheOverlayCloses() {
        var state = ReceiverSessionActionsState()
        _ = state.open(keyboardActive: false)
        _ = state.choose(.backToHome)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.surfaceInteractive(.homeKeepingSession(macPeerID: "mac")))
    }

    // MARK: Dismiss and restore

    func testCancelRestoresTheKeyboardThatWasOpen() {
        var state = ReceiverSessionActionsState()
        XCTAssertTrue(state.open(keyboardActive: true))
        XCTAssertFalse(state.open(keyboardActive: false), "already open: keeps what it saved")
        XCTAssertTrue(state.dismiss())
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.dismiss(), "nothing to dismiss twice")

        XCTAssertTrue(state.open(keyboardActive: false))
        XCTAssertFalse(state.dismiss(), "a closed keyboard stays closed")
    }

    func testChoosingAnActionClosesTheOverlay() {
        var state = ReceiverSessionActionsState()
        XCTAssertNil(state.choose(.disconnect), "nothing to choose while closed")

        _ = state.open(keyboardActive: true)
        XCTAssertEqual(state.choose(.backToHome), .backToHome(reopenKeyboardOnResume: true))
        XCTAssertFalse(state.isPresented)

        _ = state.open(keyboardActive: true)
        XCTAssertEqual(state.choose(.disconnect), .disconnect)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.dismiss(), "a disconnect leaves nothing to restore")
    }

    func testSessionEndingUnderTheOverlayRestoresNothing() {
        var state = ReceiverSessionActionsState()
        _ = state.open(keyboardActive: true)
        state.sessionEnded()
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.dismiss())
        XCTAssertTrue(state.surfaceInteractive(.session))
    }

    func testHapticFollowsTheHapticsSetting() {
        XCTAssertTrue(ControlHapticPolicy.shouldPlay(.sessionActions, enabled: true))
        XCTAssertFalse(ControlHapticPolicy.shouldPlay(.sessionActions, enabled: false))
    }
}
