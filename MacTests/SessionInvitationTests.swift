import XCTest

final class SessionInvitationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SessionInvitationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Incoming policy

    func testAutomaticallyAllowDefaultsOn() {
        XCTAssertTrue(IncomingSessionPolicyStore.automaticallyAllow(defaults: defaults))
    }

    func testPolicyMatrix() {
        let cases: [(IncomingSessionPeerPolicy?, Bool, SessionInvitationIntent, IncomingSessionDecision)] = [
            (.blocked, true, .automatic, .block), (.blocked, true, .manual, .block),
            (.blocked, false, .automatic, .block), (.blocked, false, .manual, .block),
            (.alwaysAllow, true, .automatic, .accept), (.alwaysAllow, true, .manual, .accept),
            (.alwaysAllow, false, .automatic, .accept), (.alwaysAllow, false, .manual, .accept),
            (nil, true, .automatic, .accept), (nil, true, .manual, .accept),
            (nil, false, .automatic, .decline), (nil, false, .manual, .askUser),
        ]
        for (peer, global, intent, expected) in cases {
            XCTAssertEqual(IncomingSessionPolicy.resolve(peerPolicy: peer, automaticallyAllow: global, intent: intent),
                           expected, "peer=\(String(describing: peer)) global=\(global) intent=\(intent)")
        }
    }

    func testStoreDecisionsFollowPersistedPolicy() {
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "a", intent: .manual, defaults: defaults), .accept)
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "a", intent: .manual, defaults: defaults), .askUser)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "a", intent: .automatic, defaults: defaults), .decline)
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "a", defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "a", intent: .automatic, defaults: defaults), .accept)
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "a", defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "a", intent: .manual, defaults: defaults), .block)
    }

    func testReturningToDefaultAndForgetRemoveOverride() {
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "a", defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(nil, peerID: "a", defaults: defaults)
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "a", defaults: defaults))

        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "a", defaults: defaults)
        var removed: [String] = []
        ForgetDeviceAction.perform(
            peerID: "a", forgetTrust: { _ in }, removeRemoteEndpoint: { _ in }, removeWakeMetadata: { _ in },
            removeSessionPolicy: {
                removed.append($0)
                IncomingSessionPolicyStore.removePolicy(peerID: $0, defaults: self.defaults)
            })
        XCTAssertEqual(removed, ["a"])
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "a", defaults: defaults))
    }

    func testPoliciesPersistAcrossStoreReads() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "a", defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "b", defaults: defaults)
        let reopened = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllow(defaults: reopened))
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "a", defaults: reopened), .alwaysAllow)
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "b", defaults: reopened), .blocked)
    }

    func testPolicyIsKeyedByStablePeerIDOnly() {
        // Names and addresses never enter the store; only the pinned install ID.
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "install-1", defaults: defaults)
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "Jai's iPad", defaults: defaults))
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "install-1", defaults: defaults), .blocked)
    }

    func testUnauthenticatedPeerNeverPrompts() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: nil, intent: .manual, defaults: defaults), .decline)
    }

    // MARK: - Roles

    func testInitiatorNeverDecidesStreamDirection() {
        for initiator in [SessionRole.sender, .receiver] {
            let invitation = SessionInvitation(initiator: initiator, intent: .manual, mode: .extend)
            XCTAssertEqual(invitation.initiator, initiator)
            XCTAssertEqual(SessionInvitation.streamSource, .sender)
            XCTAssertEqual(SessionInvitation.streamDestination, .receiver)
        }
    }

    func testInvitationWireRoundTrip() throws {
        let invitation = SessionInvitation(initiator: .receiver, intent: .manual, mode: .mirror,
                                           awaitingSenderApproval: true)
        let data = try JSONSerialization.data(withJSONObject: invitation.message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(SessionInvitation(message: object), invitation)

        let response = SessionInvitationResponse(id: invitation.id, result: .pending)
        XCTAssertEqual(SessionInvitationResponse(message: response.message), response)
        XCTAssertNil(SessionInvitation(message: ["type": WireMessage.sessionInvite, "id": "x"]))
    }

    func testInvitationCarriesSenderSelectedMode() {
        XCTAssertEqual(SessionInvitation(initiator: .sender, intent: .manual, mode: .mirror).mode, .mirror)
        XCTAssertEqual(SessionInvitation(initiator: .sender, intent: .manual, mode: .extend).mode, .extend)
    }

    // MARK: - Approval plans

    func testSenderApprovalPlans() {
        XCTAssertEqual(SessionApprovalPlan.plan(for: SenderApprovalDecision.rejectPermanently),
                       SessionApprovalPlan(accept: false, persistPolicy: .blocked, mode: nil, result: .blocked))
        XCTAssertEqual(SessionApprovalPlan.plan(for: SenderApprovalDecision.rejectForSession),
                       SessionApprovalPlan(accept: false, persistPolicy: nil, mode: nil, result: .declined))
        XCTAssertEqual(SessionApprovalPlan.plan(for: SenderApprovalDecision.allowMirror),
                       SessionApprovalPlan(accept: true, persistPolicy: nil, mode: .mirror, result: .accepted))
        XCTAssertEqual(SessionApprovalPlan.plan(for: SenderApprovalDecision.allowExtend),
                       SessionApprovalPlan(accept: true, persistPolicy: nil, mode: .extend, result: .accepted))
        // Allow Permanently persists the connection policy only — no mode.
        XCTAssertEqual(SessionApprovalPlan.plan(for: SenderApprovalDecision.allowPermanently),
                       SessionApprovalPlan(accept: true, persistPolicy: .alwaysAllow, mode: nil, result: .accepted))
    }

    func testReceiverApprovalPlansNeverChooseMode() {
        for decision in [ReceiverApprovalDecision.rejectPermanently, .rejectForSession, .allow, .allowPermanently] {
            XCTAssertNil(SessionApprovalPlan.plan(for: decision).mode)
        }
        XCTAssertEqual(SessionApprovalPlan.plan(for: ReceiverApprovalDecision.allowPermanently).persistPolicy, .alwaysAllow)
        XCTAssertEqual(SessionApprovalPlan.plan(for: ReceiverApprovalDecision.rejectPermanently).persistPolicy, .blocked)
        XCTAssertNil(SessionApprovalPlan.plan(for: ReceiverApprovalDecision.rejectForSession).persistPolicy)
        XCTAssertNil(SessionApprovalPlan.plan(for: ReceiverApprovalDecision.allow).persistPolicy)
    }

    func testRejectForSessionPersistsNothing() {
        let plan = SessionApprovalPlan.plan(for: SenderApprovalDecision.rejectForSession)
        if let policy = plan.persistPolicy { IncomingSessionPolicyStore.setPolicy(policy, peerID: "a", defaults: defaults) }
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "a", defaults: defaults))
    }

    // MARK: - Pending lifecycle

    private func approval(_ id: String, peer: String, at date: Date = Date()) -> PendingSessionApproval {
        PendingSessionApproval(id: id, peerID: peer, peerName: peer, localRole: .sender, mode: .extend, createdAt: date)
    }

    func testDuplicateRequestCoalesces() {
        var approvals = PendingSessionApprovals()
        XCTAssertTrue(approvals.begin(approval("1", peer: "a")).started)
        XCTAssertFalse(approvals.begin(approval("1", peer: "a")).started)
        XCTAssertEqual(approvals.entries.count, 1)
    }

    func testNewerRequestFromSamePeerSupersedesAndStaleAnswerIsIgnored() {
        var approvals = PendingSessionApprovals()
        approvals.begin(approval("old", peer: "a"))
        XCTAssertEqual(approvals.begin(approval("new", peer: "a")).superseded, "old")
        XCTAssertNil(approvals.resolve(id: "old"))
        XCTAssertEqual(approvals.resolve(id: "new")?.id, "new")
        XCTAssertNil(approvals.resolve(id: "new"), "an answer can only resolve once")
    }

    func testSimultaneousDifferentPeers() {
        var approvals = PendingSessionApprovals()
        approvals.begin(approval("1", peer: "a"))
        approvals.begin(approval("2", peer: "b"))
        XCTAssertEqual(approvals.entries.map(\.id), ["1", "2"])
        XCTAssertEqual(approvals.resolve(id: "2")?.peerID, "b")
        XCTAssertEqual(approvals.first?.id, "1")
    }

    func testCancelAndForgetRemovePending() {
        var approvals = PendingSessionApprovals()
        approvals.begin(approval("1", peer: "a"))
        approvals.begin(approval("2", peer: "b"))
        XCTAssertEqual(approvals.removeAll(peerID: "a").map(\.id), ["1"])
        XCTAssertNil(approvals.resolve(id: "1"))
    }

    func testTimeoutExpiresOnlyOldRequests() {
        var approvals = PendingSessionApprovals()
        let now = Date()
        approvals.begin(approval("old", peer: "a", at: now.addingTimeInterval(-PendingSessionApprovals.timeout)))
        approvals.begin(approval("fresh", peer: "b", at: now))
        XCTAssertEqual(approvals.expire(now: now).map(\.id), ["old"])
        XCTAssertEqual(approvals.entries.map(\.id), ["fresh"])
    }

    // MARK: - Sender admission gate

    func testLegacyReceiverNeedsNoInvitation() {
        XCTAssertEqual(SessionAdmissionGate(receiverSupportsInvitations: false, needsSenderApproval: false).state, .admitted)
    }

    func testReceiverAcceptAdmits() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertEqual(gate.state, .waiting)
        XCTAssertNil(gate.progress, "no waiting UI before the receiver asks its user")
        gate.receiverResponded(.pending)
        XCTAssertEqual(gate.progress, .waitingForReceiver)
        gate.receiverResponded(.accepted)
        XCTAssertEqual(gate.state, .admitted)
    }

    func testReceiverRejectionRefusesAndLaterAcceptCannotRevive() {
        for result in [SessionInvitationResult.declined, .blocked, .cancelled] {
            var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: false)
            gate.receiverResponded(result)
            gate.receiverResponded(.accepted)
            XCTAssertEqual(gate.state, .refused(result))
        }
    }

    func testReceiverInitiatedRequestWaitsForSender() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: true)
        gate.receiverResponded(.accepted)
        XCTAssertEqual(gate.progress, .waitingForSender)
        gate.senderDecided(accept: true)
        XCTAssertEqual(gate.state, .admitted)

        var rejected = SessionAdmissionGate(receiverSupportsInvitations: false, needsSenderApproval: true)
        rejected.senderDecided(accept: false)
        XCTAssertEqual(rejected.state, .refused(.declined))
    }

    func testReceiverCancelWhileSenderDecides() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: true)
        gate.receiverResponded(.accepted)
        gate.receiverResponded(.cancelled)
        gate.senderDecided(accept: true)
        XCTAssertEqual(gate.state, .refused(.cancelled))
    }

    // MARK: - Receiver admission

    func testReceiverAdmissionResetsPerConnectionButRecognizesContinuation() {
        var admission = ReceiverSessionAdmission()
        let invitation = SessionInvitation(initiator: .sender, intent: .manual, mode: .extend)
        admission.admit(invitationID: invitation.id, peerID: "mac")
        XCTAssertTrue(admission.admitted)
        admission.beginConnection()
        XCTAssertFalse(admission.admitted)
        XCTAssertTrue(admission.isContinuation(of: invitation, peerID: "mac"))
        XCTAssertFalse(admission.isContinuation(of: invitation, peerID: "other-mac"))
        XCTAssertFalse(admission.isContinuation(
            of: SessionInvitation(initiator: .sender, intent: .automatic, mode: .extend), peerID: "mac"))
        admission.revoke()
        XCTAssertFalse(admission.isContinuation(of: invitation, peerID: "mac"))
    }

    func testLegacySenderAdmittedOnlyWhenBackgroundAttemptWouldBe() {
        XCTAssertTrue(ReceiverSessionAdmission.admitsLegacySender(peerID: "mac", defaults: defaults))
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, defaults: defaults)
        XCTAssertFalse(ReceiverSessionAdmission.admitsLegacySender(peerID: "mac", defaults: defaults))
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "mac", defaults: defaults)
        XCTAssertTrue(ReceiverSessionAdmission.admitsLegacySender(peerID: "mac", defaults: defaults))
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "mac", defaults: defaults)
        XCTAssertFalse(ReceiverSessionAdmission.admitsLegacySender(peerID: "mac", defaults: defaults))
    }

    // MARK: - Input stays separate

    func testEverySessionStartsWithInputOff() {
        // Connection approval never touches input: a fresh session grant box
        // is off regardless of how the session was admitted.
        for _ in [SenderApprovalDecision.allowPermanently, .allowMirror, .allowExtend] {
            let grant = SessionInputGrantBox()
            XCTAssertFalse(grant.get())
            XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: grant.get()))
        }
    }

    func testAllowPermanentlyDoesNotTouchInputPolicy() {
        let plan = SessionApprovalPlan.plan(for: SenderApprovalDecision.allowPermanently)
        if let policy = plan.persistPolicy { IncomingSessionPolicyStore.setPolicy(policy, peerID: "a", defaults: defaults) }
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: "a", defaults: defaults), .ask)
    }

    func testProtocolVersionAdvertisesInvitations() {
        XCTAssertGreaterThanOrEqual(WireProtocol.version, WireProtocol.sessionInvitationWireVersion)
    }
}
