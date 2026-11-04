import XCTest

/// Issue #128: a Mac-side Connect tap must not be absorbed by an automatic
/// attempt this Mac started on its own. A receiver without Automatically
/// Allow declines that attempt's `automatic` invitation instead of asking
/// its user, so the tap would end in "declined" with no prompt shown.
final class ExplicitConnectAdmissionTests: XCTestCase {
    private func existing(failed: Bool = false, admitted: Bool = false,
                          initiator: SessionRole = .sender, intent: SessionInvitationIntent = .automatic,
                          isContinuation: Bool = false) -> ExplicitConnectAdmission.Existing {
        .init(failed: failed, admitted: admitted,
              invitation: SessionInvitation(initiator: initiator, intent: intent, mode: .extend),
              isContinuation: isContinuation)
    }

    func testNoSessionStartsTheExplicitAttempt() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: nil), .start)
    }

    func testFailedSessionNeverAbsorbsTheTap() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(failed: true)), .start)
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(failed: true, intent: .manual)), .start)
    }

    func testUnadmittedAutomaticAttemptIsReplaced() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing()), .replace)
    }

    /// Repeated taps: the second one finds the first tap's manual attempt
    /// and leaves it alone, so there is never a second dial or prompt.
    func testExplicitAttemptInProgressIsKept() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(intent: .manual)), .keep)
    }

    func testAdmittedSessionIsKept() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(admitted: true)), .keep)
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(admitted: true, intent: .manual)), .keep)
    }

    /// A receiver's own request belongs to the receiver's flow
    /// (`ReceiverRequestAdmission`), whatever its intent.
    func testReceiverInitiatedSessionIsKept() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(initiator: .receiver)), .keep)
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(initiator: .receiver, intent: .manual)), .keep)
    }

    /// A rebuild or wait-for-wake session carries an admitted invitation the
    /// receiver accepts without asking; a fresh manual one could prompt again.
    func testContinuationOfAnAdmittedSessionIsKept() {
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: existing(isContinuation: true)), .keep)
    }

    /// Replacement is only ever triggered from the automatic side, so the
    /// explicit attempt that replaced it is itself never replaced: the decision
    /// cannot alternate between two sessions.
    func testReplacementCannotRepeat() {
        let replaced = existing()
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: replaced), .replace)
        let replacement = existing(intent: .manual)
        XCTAssertEqual(ExplicitConnectAdmission.decide(existing: replacement), .keep)
    }
}
