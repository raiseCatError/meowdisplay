import XCTest

/// #255 physical QA (9000041): a live view-only session showed no Request Control until a touch
/// was blocked. A session that settles view only now offers it once, unasked, and never sends a
/// request by itself; every Mac policy stays the Mac's.
final class ViewOnlyRequestControlOfferTests: XCTestCase {
    private let pv = WireProtocol.allowInputWireVersion

    private func live() -> ReceiverInputPrompt {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        return prompt
    }

    // MARK: when it is offered

    func testOnlyALiveUnlockedUndecidedSessionOnACurrentMacIsOffered() {
        XCTAssertTrue(ReceiverInputPrompt.offersViewOnly(sessionLive: true, macPV: pv, macState: .off,
                                                         macLocked: false, userTurnedOff: false))
        XCTAssertFalse(ReceiverInputPrompt.offersViewOnly(sessionLive: false, macPV: pv, macState: .off,
                                                          macLocked: false, userTurnedOff: false), "not live")
        XCTAssertFalse(ReceiverInputPrompt.offersViewOnly(sessionLive: true, macPV: pv - 1, macState: .off,
                                                          macLocked: false, userTurnedOff: false),
                       "an older Mac never reports a decision to answer")
        XCTAssertFalse(ReceiverInputPrompt.offersViewOnly(sessionLive: true, macPV: pv, macState: .off,
                                                          macLocked: true, userTurnedOff: false),
                       "the locked cover has its own steps")
        XCTAssertFalse(ReceiverInputPrompt.offersViewOnly(sessionLive: true, macPV: pv, macState: .off,
                                                          macLocked: false, userTurnedOff: true),
                       "this device turned input off itself")
        for state: SessionInputWireState in [.allowed, .requesting, .notAllowed, .requestsDisabled] {
            XCTAssertFalse(ReceiverInputPrompt.offersViewOnly(sessionLive: true, macPV: pv, macState: state,
                                                              macLocked: false, userTurnedOff: false),
                           "\(state): granted, waiting, declined or Never Allow is never re-offered")
        }
    }

    // MARK: what the offer does

    func testTheOfferShowsUntilAnsweredAndSendsNothing() {
        var prompt = live()
        XCTAssertTrue(prompt.offerForViewOnlySession(userTurnedOff: false))
        XCTAssertEqual(prompt.kind, .requestInput)
        XCTAssertTrue(prompt.isUntilAnswered)
        XCTAssertTrue(prompt.isVisible(at: 1_000_000), "no timer fades it")
        prompt.tick(now: 1_000_000)
        XCTAssertEqual(prompt.kind, .requestInput)
        XCTAssertNil(prompt.lastRequestAt, "offering is not asking")
    }

    func testOncePerLiveSession() {
        var prompt = live()
        XCTAssertTrue(prompt.offerForViewOnlySession(userTurnedOff: false))
        _ = prompt.blockedAttempt(now: 10, userTurnedOff: false, autoRequest: false)
        prompt.tick(now: 20)
        XCTAssertNil(prompt.kind)
        XCTAssertFalse(prompt.offerForViewOnlySession(userTurnedOff: false), "no nagging")
        // A new live session (reconnect, another Mac) may offer again.
        prompt.setSessionLive(false)
        prompt.setSessionLive(true)
        XCTAssertTrue(prompt.offerForViewOnlySession(userTurnedOff: false))
    }

    func testNotWhenTurnedOffNotLiveOrAnotherPromptIsUp() {
        var turnedOff = live()
        XCTAssertFalse(turnedOff.offerForViewOnlySession(userTurnedOff: true))
        XCTAssertNil(turnedOff.kind)

        var notLive = ReceiverInputPrompt()
        XCTAssertFalse(notLive.offerForViewOnlySession(userTurnedOff: false))

        var requesting = live()
        requesting.inputStateChanged(.requesting, now: 0)
        XCTAssertFalse(requesting.offerForViewOnlySession(userTurnedOff: false))

        var declined = live()
        declined.inputStateChanged(.notAllowed, now: 0)
        XCTAssertFalse(declined.offerForViewOnlySession(userTurnedOff: false), "Not Now is respected")
    }

    func testABlockedTouchTurnsTheOfferIntoTheUsualFadingPrompt() {
        var prompt = live()
        _ = prompt.offerForViewOnlySession(userTurnedOff: false)
        XCTAssertEqual(prompt.blockedAttempt(now: 100, userTurnedOff: false, autoRequest: false), [])
        XCTAssertFalse(prompt.isUntilAnswered)
        XCTAssertTrue(prompt.isVisible(at: 100 + ReceiverInputPrompt.visibleDuration - 0.1))
        prompt.tick(now: 100 + ReceiverInputPrompt.visibleDuration)
        XCTAssertNil(prompt.kind)
    }

    func testTappingSendsTheOrdinaryRequestOnce() {
        var prompt = live()
        _ = prompt.offerForViewOnlySession(userTurnedOff: false)
        XCTAssertEqual(prompt.requestTapped(now: 5), [.sendRequest])
        XCTAssertEqual(prompt.kind, .requesting)
        XCTAssertEqual(prompt.requestTapped(now: 5.1), [], "rate limited as before")
    }

    func testTheMacsAnswerEndsTheWait() {
        var granted = live()
        _ = granted.offerForViewOnlySession(userTurnedOff: false)
        granted.inputStateChanged(.allowed, now: 50)
        XCTAssertEqual(granted.kind, .enabled)
        granted.tick(now: 50 + ReceiverInputPrompt.enabledDuration)
        XCTAssertNil(granted.kind)

        var never = live()
        _ = never.offerForViewOnlySession(userTurnedOff: false)
        never.inputStateChanged(.requestsDisabled, now: 50)
        XCTAssertEqual(never.kind, .unavailable)
        XCTAssertFalse(never.isUntilAnswered, "Never Allow is said briefly, not pinned")
        never.tick(now: 50 + ReceiverInputPrompt.visibleDuration)
        XCTAssertNil(never.kind)
    }

    func testTheSessionEndingClearsTheOffer() {
        var prompt = live()
        _ = prompt.offerForViewOnlySession(userTurnedOff: false)
        prompt.setSessionLive(false)
        XCTAssertNil(prompt.kind)
        XCTAssertEqual(prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: true), [], "nothing while not live")
    }
}
