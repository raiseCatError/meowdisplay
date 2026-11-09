import XCTest

/// "Show Lock Screen" on the receiver (PROTOCOL.md 6.19): the steps, in order, and what each Mac
/// answer does. The Mac decides everything; the flow only asks.
final class LockScreenFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func locked(_ offer: LockScreenOffer, remoteUnlock: Bool = true,
                        state: MacScreenPrivacy = .locked) -> MacLockNotice {
        MacLockNotice(state: state, remoteUnlock: remoteUnlock, lockScreen: offer)
    }

    /// Asked here and shown: Show Lock Screen, then the Mac's `active`.
    private func shown() -> LockScreenFlow {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.available), now: t0)
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertEqual(flow.phase, .showing)
        return flow
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

    /// Right after the switch the new connection says "locked" before the Mac knows which device
    /// it is (no reason given): that's not a refusal, the flow keeps waiting.
    func testTheNewConnectionsFirstUndecidedNoticeKeepsTheFlowWaiting() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = flow.update(notice: nil, connected: false, now: t0)
        XCTAssertEqual(flow.update(notice: locked(.unavailable(nil), remoteUnlock: false), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .waitingForFullDesktop)
        XCTAssertEqual(flow.update(notice: locked(.needsControl), connected: true, now: t0), .requestControl)
        // A reason is a decision, even right after the switch.
        var refused = LockScreenFlow()
        _ = refused.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = refused.update(notice: locked(.unavailable("turnedOff"), remoteUnlock: false), connected: true, now: t0)
        XCTAssertEqual(refused.phase, .failed("Lock Screen Control is turned off for this device on the Mac."))
    }

    /// Timed out after switching: back to the previous view at once, still locked, once.
    func testATimeoutAfterTheSwitchReturnsToThePreviousView() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        let undecided = locked(.unavailable(nil), remoteUnlock: false)
        XCTAssertEqual(flow.update(notice: undecided, connected: true, now: t0.addingTimeInterval(LockScreenFlow.timeout + 1)),
                       .returnToWindowView)
        XCTAssertEqual(flow.phase, .failed("The Mac didn't respond."))
        XCTAssertFalse(flow.returnToWindowView)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0.addingTimeInterval(LockScreenFlow.timeout + 2)), .none)
    }

    /// Refused after switching (the Ask device's handoff expired, the switch turned off): back to
    /// the previous view at once, with the reason shown.
    func testARefusalAfterTheSwitchReturnsToThePreviousView() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = flow.update(notice: nil, connected: false, now: t0)
        XCTAssertEqual(flow.update(notice: locked(.needsControl), connected: true, now: t0), .requestControl)
        XCTAssertEqual(flow.update(notice: locked(.unavailable("controlBeforeLock"), remoteUnlock: false), connected: true, now: t0),
                       .returnToWindowView)
        XCTAssertEqual(flow.phase, .failed("Control wasn't allowed before the Mac locked."))
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0), .none, "once")
    }

    /// Timed out while the switch's reconnect is still down: the way back waits for a connection.
    func testAFailureWhileDisconnectedReturnsOnceConnected() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        XCTAssertEqual(flow.update(notice: nil, connected: false, now: t0.addingTimeInterval(LockScreenFlow.timeout + 1)), .none)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0.addingTimeInterval(LockScreenFlow.timeout + 2)),
                       .returnToWindowView)
    }

    /// The switch itself didn't happen: nothing to go back from.
    func testCouldNotPerformLeavesNoWayBack() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        flow.couldNotPerform()
        XCTAssertFalse(flow.returnToWindowView)
        XCTAssertEqual(flow.update(notice: locked(.needsFullDesktop), connected: true, now: t0), .none)
    }

    /// Another Mac on the connection: stop, switch nothing.
    func testAbandonOnAnotherMacSwitchesNothing() {
        var flow = LockScreenFlow()
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        flow.abandon()
        XCTAssertEqual(flow.phase, .failed("Connected to a different Mac, so Show Lock Screen stopped."))
        XCTAssertFalse(flow.returnToWindowView)
        XCTAssertFalse(flow.askedOnThisConnection)
        XCTAssertEqual(flow.update(notice: nil, connected: true, now: t0), .none)
        var idle = LockScreenFlow()
        idle.abandon()
        XCTAssertEqual(idle.phase, .idle, "nothing to stop")
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

        var showing = shown()
        _ = showing.update(notice: nil, connected: false, now: t0)
        XCTAssertEqual(showing.phase, .idle)
    }

    // MARK: active, hide

    /// F2: the Mac saying `active` without this device asking on this connection (a view left
    /// from before a reconnect) is never shown: the flow asks the Mac to hide it.
    func testActiveWithoutAskingOnThisConnectionIsNeverShown() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.update(notice: locked(.active), connected: true, now: t0), .show(false))
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active), flow: flow, videoEnabled: true, freshFrame: true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: flow, videoEnabled: true, freshFrame: true))

        // Shown, then the connection drops and comes back saying `active`: not resumed.
        var again = shown()
        _ = again.update(notice: nil, connected: false, now: t0)
        XCTAssertFalse(again.askedOnThisConnection)
        XCTAssertEqual(again.update(notice: locked(.active), connected: true, now: t0), .show(false))
        XCTAssertEqual(again.phase, .idle)
        // Only a fresh tap shows it again.
        XCTAssertEqual(again.begin(notice: locked(.available), now: t0), .show(true))
        XCTAssertEqual(again.update(notice: locked(.active), connected: true, now: t0), .none)
        XCTAssertEqual(again.phase, .showing)

        // Mid-switch to Full Desktop: the new connection's `active` before this device asked on it.
        var switching = LockScreenFlow()
        _ = switching.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = switching.update(notice: nil, connected: false, now: t0)
        XCTAssertEqual(switching.update(notice: locked(.active), connected: true, now: t0), .show(false))
        XCTAssertEqual(switching.phase, .waitingForFullDesktop)

        // A late `active` after Hide doesn't bring it back.
        var hidden = shown()
        XCTAssertEqual(hidden.hide(now: t0), .show(false))
        XCTAssertEqual(hidden.update(notice: locked(.active), connected: true, now: t0), .show(false))
        XCTAssertEqual(hidden.phase, .idle)
    }

    func testHideAsksTheMacToHideAndKeepsTheWayBackUntilUnlock() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.hide(now: t0), .none, "nothing to hide")
        _ = flow.begin(notice: locked(.needsFullDesktop), now: t0)
        _ = flow.update(notice: locked(.available), connected: true, now: t0)
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
        var flow = shown()
        XCTAssertEqual(flow.update(notice: locked(.unavailable("turnedOff"), remoteUnlock: false), connected: true, now: t0), .none)
        XCTAssertEqual(flow.phase, .failed("Lock Screen Control is turned off for this device on the Mac."))
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
        var flow = shown()
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

    // MARK: the cover (MacLockedCoverPolicy)

    /// The cover stays up until the Mac says `active` AND video is on: no flash of the video-off
    /// surface between the two.
    /// Audit S2: a renderer's last picture (the pre-lock desktop) never shows: the cover waits for a
    /// frame that arrived after the video reset.
    func testTheCoverWaitsForAFreshFrame() {
        let showing = shown()
        XCTAssertFalse(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active), flow: showing, videoEnabled: true, freshFrame: false))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: showing, videoEnabled: true, freshFrame: false))
        XCTAssertTrue(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertFalse(MacLockedCoverPolicy.showsCover(notice: nil, flow: LockScreenFlow(), videoEnabled: true, freshFrame: false),
                       "unlocked: the fresh-frame wait never covers the desktop")
    }

    func testTheCoverGivesWayOnlyToActiveWithVideoOn() {
        let idle = LockScreenFlow()
        let showing = shown()
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.available), flow: idle, videoEnabled: false, freshFrame: true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.available), flow: idle, videoEnabled: true, freshFrame: true),
                      "locked and not shown: covered even if video were on")
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: showing, videoEnabled: false, freshFrame: true),
                      "active, video not on yet: still covered")
        XCTAssertFalse(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: idle, videoEnabled: true, freshFrame: true), "not asked here")
        XCTAssertTrue(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertFalse(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active), flow: showing, videoEnabled: false, freshFrame: true))
        XCTAssertFalse(MacLockedCoverPolicy.showsLockScreen(notice: locked(.active, remoteUnlock: false), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active, remoteUnlock: false), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active, state: .switchedOut), flow: showing, videoEnabled: true, freshFrame: true))
        XCTAssertFalse(MacLockedCoverPolicy.showsCover(notice: nil, flow: idle, videoEnabled: true, freshFrame: true), "unlocked, nothing going on")
    }

    /// The switch to Full Desktop drops the connection (`macLock` goes nil): the cover stays, with
    /// the flow's status, until the new connection's Mac says something.
    func testTheCoverStaysThroughTheModeSwitchReconnect() {
        var flow = LockScreenFlow()
        XCTAssertEqual(flow.begin(notice: locked(.needsFullDesktop), now: t0), .switchToFullDesktop)
        _ = flow.update(notice: nil, connected: false, now: t0)
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: nil, flow: flow, videoEnabled: true, freshFrame: true), "dropped mid-switch")
        _ = flow.update(notice: nil, connected: true, now: t0)
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: nil, flow: flow, videoEnabled: true, freshFrame: true), "reconnected, nothing said yet")
        XCTAssertEqual(MacLockedCoverPolicy.coverNotice(nil), MacLockNotice(state: .locked), "drawn as locked, nothing offered")
        XCTAssertEqual(flow.update(notice: locked(.needsControl), connected: true, now: t0), .requestControl)
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.needsControl), flow: flow, videoEnabled: false, freshFrame: true))
        XCTAssertEqual(flow.update(notice: locked(.available), connected: true, now: t0), .show(true))
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.available), flow: flow, videoEnabled: true, freshFrame: true))
        _ = flow.update(notice: locked(.active), connected: true, now: t0)
        XCTAssertTrue(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: flow, videoEnabled: false, freshFrame: true))
        XCTAssertFalse(MacLockedCoverPolicy.showsCover(notice: locked(.active), flow: flow, videoEnabled: true, freshFrame: true))
        // Any other drop ends the flow: no cover without a lock.
        _ = flow.update(notice: nil, connected: false, now: t0)
        XCTAssertFalse(MacLockedCoverPolicy.showsCover(notice: nil, flow: flow, videoEnabled: true, freshFrame: true))
    }

    /// Before the tap, the cover says what Show Lock Screen will do; when it isn't offered, why.
    func testTheCoverSaysWhatWillHappenOrWhyNot() {
        func text(_ offer: LockScreenOffer, remoteUnlock: Bool? = nil) -> String? {
            MacLockedCoverPolicy.offerText(locked(offer, remoteUnlock: remoteUnlock ?? offer.offered))
        }
        XCTAssertEqual(text(.needsControl), text(.available), "control comes back without a prompt: no separate Request Control step")
        XCTAssertTrue(text(.needsFullDesktop)?.hasPrefix("Switches to Full Desktop first") == true)
        XCTAssertTrue(text(.available)?.hasPrefix("Shows the Mac’s own lock screen here") == true)
        XCTAssertNil(text(.active))
        XCTAssertTrue(text(.unavailable("turnedOff"))?.hasPrefix("Lock Screen Control is turned off for this device") == true)
        XCTAssertTrue(text(.unavailable("controlBeforeLock"))?.contains("didn’t have control before the Mac locked") == true)
        XCTAssertTrue(text(.unavailable("windowView"))?.hasPrefix("This view can’t show the lock screen") == true)
        XCTAssertEqual(text(.unavailable("neverAllow")), "This device is set to Never Allow control on the Mac.")
        XCTAssertEqual(text(.unavailable("inputOff")), "Allow Input is off on the Mac.")
        let generic = "It can’t be unlocked from this device. Control can be requested once it’s unlocked."
        for why in [nil, "otherUser", "notAdmitted", "notLocked", "fromTheFuture"] as [String?] {
            XCTAssertEqual(text(.unavailable(why)), generic, "\(String(describing: why))")
        }
        XCTAssertEqual(text(.available, remoteUnlock: false), generic, "remoteUnlock false is never an offer")
        XCTAssertNil(MacLockedCoverPolicy.offerText(locked(.available, state: .switchedOut)), "another user: the detail says it")
        XCTAssertNil(MacLockedCoverPolicy.offerText(locked(.available, state: .unknown)))
    }
}
