import XCTest

/// "Show Lock Screen" on the receiver (PROTOCOL.md 6.19): the steps, in order, and what each Mac
/// answer does. The Mac decides everything; the flow only asks.
final class LockScreenFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func locked(_ offer: LockScreenOffer, remoteUnlock: Bool = true,
                        state: MacScreenPrivacy = .locked) -> MacLockNotice {
        MacLockNotice(state: state, remoteUnlock: remoteUnlock, lockScreen: offer)
    }

    // MARK: begin

    func testNothingStartsWithoutRemoteUnlockEvenIfTheOfferSaysAvailable() {
        var flow = LockScreenFlow()
        let notice = MacLockNotice(state: .locked, remoteUnlock: false, lockScreen: .available)
        XCTAssertEqual(flow.begin(notice: notice, now: t0), .none)
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertEqual(flow.begin(notice: nil, now: t0), .none)
        XCTAssertEqual(flow.begin(notice: locked(.unavailable("turnedOff")), now: t0), .none)
        XCTAssertEqual(flow.phase, .idle)
    }

    func testAvailableShowsAtOnceThenWaitsForTheMacToSayActive() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.begin(notice: locked(.available), now: t0), .show(true))
        XCTAssertEqual(flow.phase, .waitingForActive)
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .waitingForActive, "available is not showing")
        XCTAssertEqual(flow.update(notice: locked(.active), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .showing)
        XCTAssertTrue(flow.isShowing)
    }

    func testNeedsControlRequestsControlThenShowsWhenAvailable() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.begin(notice: locked(.needsControl), now: t0), .requestControl)
        XCTAssertEqual(flow.phase, .waitingForControl)
        XCTAssertEqual(flow.update(notice: locked(.needsControl), connected: true, now: t0), .none)
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .show(true))
        XCTAssertEqual(flow.phase, .waitingForActive)
    }

    // MARK: Window view

    func testWindowViewToFullDesktopToControlToShowToUnlockReturnsOnce() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.begin(notice: locked(.needsFullDesktop), now: t0), .switchToFullDesktop)
        XCTAssertEqual(flow.phase, .waitingForFullDesktop)
        XCTAssertTrue(flow.returnToWindowView)
        // The mode switch reconnects.
        XCTAssertEqual(flow.update(notice: nil, connected: false, now: t0.addingTimeInterval(1)), .none)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0.addingTimeInterval(2)), .none)
        XCTAssertEqual(flow.phase, .waitingForFullDesktop)
        XCTAssertEqual(flow.update(notice: locked(.needsControl), connected: true, now: t0.addingTimeInterval(3)), .requestControl)
        XCTAssertEqual(flow.phase, .waitingForControl)
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0.addingTimeInterval(4)), .show(true))
        XCTAssertEqual(flow.update(notice: locked(.active), connected: true, now: t0.addingTimeInterval(5)), .none)
        XCTAssertEqual(flow.phase, .showing)
        // The Mac unlocks: back to Window view, once.
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0.addingTimeInterval(6)), .returnToWindowView)
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(flow.returnToWindowView)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0.addingTimeInterval(7)), .none)
    }

    func testAfterTheSwitchAvailableShowsDirectly() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .show(true))
        XCTAssertEqual(flow.phase, .waitingForActive)
    }

    func testAnExplicitUnlockedNoticeAlsoReturns() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        XCTAssertEqual(flow.update(notice: locked(.available, state: .unlocked), connected: true, now: t0),
                       .returnToWindowView)
        XCTAssertEqual(flow.phase, .idle)
    }

    func testDisconnectDuringTheModeSwitchKeepsTheFlowAnyOtherDisconnectResets() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        XCTAssertEqual(flow.update(notice: nil, connected: false, now: t0), .none)
        XCTAssertEqual(flow.phase, .waitingForFullDesktop)
        XCTAssertTrue(flow.returnToWindowView)

        var other = LockScreenFlow()
        _ = other.begin(notice: locked(.needsControl), now: t0)
        XCTAssertEqual(other.update(notice: nil, connected: false, now: t0), .none)
        XCTAssertEqual(other.phase, .idle)
        XCTAssertEqual(other.update(notice: nil, connected: true, now: t0), .none, "a reset flow doesn't return anywhere")

        var showing = LockScreenFlow()
        _ = showing.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertEqual(showing.phase, .showing)
        _ = showing.update(notice: nil, connected: false, now: t0)
        XCTAssertEqual(showing.phase, .idle)
    }

    // MARK: active, hide

    func testActiveFromTheMacIsShowingEvenWithoutAskingHere() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.update(notice: locked(.active), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .showing)
    }

    func testHideAsksTheMacToHideAndKeepsTheWayBackUntilUnlock() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.hide(now: t0), .none, "nothing to hide")
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertEqual(flow.hide(now: t0), .show(false))
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertTrue(flow.returnToWindowView)
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .none)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0), .returnToWindowView)
        XCTAssertFalse(flow.returnToWindowView)
    }

    func testUnlockWithoutAWindowViewTripEmitsNothing() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.available), now: t0)
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .idle)
    }

    // MARK: Mac says no

    func testTurnedOffWhileShowingFailsWithoutRetrying() {
        var flow = LockScreenFlow()
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertEqual(flow.update(notice: locked(.unavailable("turnedOff"), remoteUnlock: false), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .failed("Lock Screen Control is off for this device on the Mac."))
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .none, "no automatic retry")
    }

    func testReasonsWhileWaiting() {
        var control = LockScreenFlow()
        _ = control.begin(notice: locked(.needsControl), now: t0)
        _ = control.update(notice: locked(.unavailable("controlBeforeLock"), remoteUnlock: false), connected: true, now: t0)
        XCTAssertEqual(control.phase, .failed("Control wasn't allowed before the Mac locked."))

        var other = LockScreenFlow()
        _ = other.begin(notice: locked(.available), now: t0)
        _ = other.update(notice: locked(.unavailable("windowView"), remoteUnlock: false), connected: true, now: t0)
        XCTAssertEqual(other.phase, .failed("The Mac isn't offering its lock screen to this device."))

        var nilReason = LockScreenFlow()
        _ = nilReason.begin(notice: locked(.available), now: t0)
        _ = nilReason.update(notice: locked(.unavailable(nil), remoteUnlock: false), connected: true, now: t0)
        XCTAssertEqual(nilReason.phase, .failed("The Mac isn't offering its lock screen to this device."))
    }

    func testFailedCanBeTriedAgainByHandAndDismissed() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.available), now: t0)
        _ = flow.update(notice: locked(.unavailable("turnedOff"), remoteUnlock: false), connected: true, now: t0)
        XCTAssertEqual(flow.begin(notice: locked(.available), now: t0), .show(true))
        XCTAssertEqual(flow.phase, .waitingForActive)
        flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.available), now: t0)
        _ = flow.update(notice: locked(.unavailable(nil), remoteUnlock: false), connected: true, now: t0)
        flow.dismissFailure()
        XCTAssertEqual(flow.phase, .idle)
    }

    // MARK: time

    func testEveryWaitingPhaseTimesOutAfterThirtySeconds() {
        let steps: [(MacLockNotice, LockScreenFlow.Phase)] = [
            (locked(.available), .waitingForActive),
            (locked(.needsControl), .waitingForControl),
            (locked(.needsFullDesktop), .waitingForFullDesktop),
        ]
        for (notice, phase) in steps {
            var flow = LockScreenFlow()
            _ = flow.begin(notice: notice, now: t0)
            XCTAssertEqual(flow.phase, phase)
            _ = flow.tick(now: t0.addingTimeInterval(29.9))
            XCTAssertEqual(flow.phase, phase, "not yet")
            _ = flow.tick(now: t0.addingTimeInterval(30))
            XCTAssertEqual(flow.phase, .failed("The Mac didn't respond."))
        }
    }

    func testTheClockRestartsAtEachStep() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsControl), now: t0)
        _ = flow.update(notice: locked(.available), connected: true, now: t0.addingTimeInterval(25))
        _ = flow.tick(now: t0.addingTimeInterval(50))
        XCTAssertEqual(flow.phase, .waitingForActive)
        _ = flow.tick(now: t0.addingTimeInterval(55))
        XCTAssertEqual(flow.phase, .failed("The Mac didn't respond."))
    }

    func testShowingNeverTimesOut() {
        var flow = LockScreenFlow()
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        _ = flow.tick(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(flow.phase, .showing)
    }

    func testCouldNotPerformFailsAWaitingFlow() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        flow.couldNotPerform()
        if case .failed = flow.phase {} else { XCTFail("expected failed, got \(flow.phase)") }
    }

    // MARK: the cover only gives way to the Mac's own word

    func testShowsMacLockScreenOnlyWhenTheMacSaysActive() {
        XCTAssertTrue(locked(.active).showsMacLockScreen)
        XCTAssertFalse(locked(.available).showsMacLockScreen)
        XCTAssertFalse(locked(.active, remoteUnlock: false).showsMacLockScreen)
        XCTAssertFalse(locked(.active, state: .switchedOut).showsMacLockScreen)
        XCTAssertFalse(locked(.active, state: .unlocked).showsMacLockScreen)
    }
}
