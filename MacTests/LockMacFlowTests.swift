import XCTest

/// Lock Mac: which path a tap takes, and that nothing locks before the Mac reports control
/// granted (LockMacFlow.swift).
final class LockMacFlowTests: XCTestCase {
    private func inputs(canLock: Bool = true, connected: Bool = true, granted: Bool = false,
                        _ state: SessionInputWireState) -> LockMacFlow.Inputs {
        LockMacFlow.Inputs(canLock: canLock, connected: connected,
                           controlGranted: granted && state == .allowed, inputState: state)
    }

    // MARK: Paths

    func testPathPerControlState() {
        XCTAssertEqual(LockMacFlow.path(for: inputs(granted: true, .allowed)), .lockNow)
        XCTAssertEqual(LockMacFlow.path(for: inputs(.off)), .requestThenLock)
        XCTAssertEqual(LockMacFlow.path(for: inputs(.notAllowed)), .requestThenLock)
        XCTAssertEqual(LockMacFlow.path(for: inputs(.requesting)), .waitForRequest)
        XCTAssertEqual(LockMacFlow.path(for: inputs(.requestsDisabled)), .unavailable(.requestsDisabled))
        XCTAssertEqual(LockMacFlow.path(for: inputs(canLock: false, granted: true, .allowed)), .unavailable(.notSupported))
        XCTAssertEqual(LockMacFlow.path(for: inputs(connected: false, .off)), .unavailable(.notConnected))
    }

    func testAllowedWithoutLiveControlIsNeverLockNow() {
        let i = LockMacFlow.Inputs(canLock: true, connected: true, controlGranted: false, inputState: .allowed)
        XCTAssertNotEqual(LockMacFlow.path(for: i), .lockNow)
    }

    // MARK: Control already granted

    func testGrantedConfirmsThenLocksOnce() {
        var flow = LockMacFlow()
        let i = inputs(granted: true, .allowed)
        flow.begin(i)
        XCTAssertEqual(flow.phase, .confirming(.lockNow))
        XCTAssertEqual(flow.confirmButtonTitle, "Lock Mac")
        XCTAssertEqual(flow.confirm(i), [.lock])
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertEqual(flow.confirm(i), [], "a second confirm does nothing")
        XCTAssertEqual(flow.inputsChanged(i), [])
    }

    func testCancelSendsNothing() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        XCTAssertEqual(flow.confirmButtonTitle, "Request Control & Lock Mac")
        flow.cancel()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertEqual(flow.confirm(inputs(.off)), [], "nothing left to confirm")
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [], "a later grant locks nothing")
    }

    // MARK: Request Control, then lock

    func testRequestsControlThenLocksWhenAllowed() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        XCTAssertEqual(flow.confirm(inputs(.off)), [.requestControl], "no lock yet")
        XCTAssertTrue(flow.isAwaiting)
        XCTAssertEqual(flow.inputsChanged(inputs(.requesting)), [])
        XCTAssertTrue(flow.isAwaiting)
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [.lock])
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [], "locks exactly once")
    }

    func testDeclinedCancelsWithoutLocking() {
        for terminal in [SessionInputWireState.notAllowed, .requestsDisabled, .off] {
            var flow = LockMacFlow()
            flow.begin(inputs(.off))
            _ = flow.confirm(inputs(.off))
            XCTAssertEqual(flow.inputsChanged(inputs(.requesting)), [])
            XCTAssertEqual(flow.inputsChanged(inputs(terminal)), [], "\(terminal)")
            XCTAssertEqual(flow.notice, .declined, "\(terminal)")
            XCTAssertEqual(LockMacFlow.text(.declined), "The Mac didn't allow control. Nothing was locked.")
        }
    }

    func testStaleDeclinedStateIsNotTheAnswer() {
        var flow = LockMacFlow()
        flow.begin(inputs(.notAllowed))
        _ = flow.confirm(inputs(.notAllowed))
        XCTAssertEqual(flow.inputsChanged(inputs(.notAllowed)), [])
        XCTAssertTrue(flow.isAwaiting, "the old Not Allowed is not this request's answer")
        _ = flow.inputsChanged(inputs(.requesting))
        _ = flow.inputsChanged(inputs(.notAllowed))
        XCTAssertEqual(flow.notice, .declined)
    }

    func testAutoDeniedWithoutAPromptIsDeclined() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        _ = flow.confirm(inputs(.off))
        _ = flow.inputsChanged(inputs(.notAllowed))
        XCTAssertEqual(flow.notice, .declined)
    }

    func testTimeoutCancelsWithoutLocking() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        _ = flow.confirm(inputs(.off))
        flow.timedOut()
        XCTAssertEqual(flow.notice, .timedOut)
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [], "a late grant locks nothing")
        XCTAssertGreaterThanOrEqual(LockMacFlow.timeout, 46, "longer than the Mac's 45 s prompt")
    }

    func testDisconnectWhileWaitingCancels() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        _ = flow.confirm(inputs(.off))
        XCTAssertEqual(flow.inputsChanged(inputs(connected: false, .requesting)), [])
        XCTAssertEqual(flow.notice, .disconnected)
        var flow2 = LockMacFlow()
        flow2.begin(inputs(.off))
        _ = flow2.confirm(inputs(.off))
        _ = flow2.inputsChanged(inputs(canLock: false, .requesting))
        XCTAssertEqual(flow2.notice, .disconnected, "the Mac's lock feature went away with the session")
    }

    func testStopWaitingSendsNothingFurther() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        _ = flow.confirm(inputs(.off))
        flow.cancel()
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [])
    }

    // MARK: Pending elsewhere, unavailable

    func testAlreadyRequestingWaitsWithoutADuplicateRequest() {
        var flow = LockMacFlow()
        flow.begin(inputs(.requesting))
        XCTAssertEqual(flow.phase, .confirming(.waitForRequest))
        XCTAssertEqual(flow.confirm(inputs(.requesting)), [], "no second request")
        XCTAssertTrue(flow.isAwaiting)
        XCTAssertEqual(flow.inputsChanged(inputs(granted: true, .allowed)), [.lock])
    }

    func testWaitingOnSomeoneElsesRequestThatEndsDeclines() {
        var flow = LockMacFlow()
        flow.begin(inputs(.requesting))
        _ = flow.confirm(inputs(.requesting))
        _ = flow.inputsChanged(inputs(.notAllowed))
        XCTAssertEqual(flow.notice, .declined)
    }

    func testUnavailableShowsAnExplanationAndNeverConfirms() {
        var flow = LockMacFlow()
        flow.begin(inputs(.requestsDisabled))
        XCTAssertEqual(flow.notice, .unavailable(.requestsDisabled))
        XCTAssertFalse(flow.isConfirming)
        XCTAssertEqual(flow.confirm(inputs(.requestsDisabled)), [])
        XCTAssertTrue(LockMacFlow.text(.unavailable(.requestsDisabled)).contains("isn't accepting control requests"))
    }

    // MARK: Consent follows the dialog that was shown

    func testChangedSituationAsksAgainInsteadOfActingOnTheOldDialog() {
        var flow = LockMacFlow()
        flow.begin(inputs(granted: true, .allowed))
        XCTAssertEqual(flow.phase, .confirming(.lockNow))
        // Control was revoked while the dialog was up: confirming must not lock, nor request.
        XCTAssertEqual(flow.confirm(inputs(.off)), [])
        XCTAssertEqual(flow.phase, .confirming(.requestThenLock), "shows the new question")
        XCTAssertEqual(flow.confirm(inputs(.off)), [.requestControl])
    }

    func testDialogFollowsStateChangesWhileShowing() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        XCTAssertEqual(flow.inputsChanged(inputs(.requestsDisabled)), [])
        XCTAssertEqual(flow.notice, .unavailable(.requestsDisabled))
    }

    func testBeginIsIgnoredWhileWaiting() {
        var flow = LockMacFlow()
        flow.begin(inputs(.off))
        _ = flow.confirm(inputs(.off))
        flow.begin(inputs(.off))
        XCTAssertTrue(flow.isAwaiting)
    }
}
