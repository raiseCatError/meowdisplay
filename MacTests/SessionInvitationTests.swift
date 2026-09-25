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

    // MARK: - Receiver-requested mode

    func testReceiverRequestedModeSurvivesPlanning() {
        for requested in [ReceiverDisplayMode.mirror, .extend] {
            let parsed = SessionModePlanning.requestedMode(requested.rawValue)
            XCTAssertEqual(parsed, requested)
            // Auto-approved: the request wins over the Mac's current mode.
            XCTAssertEqual(SessionModePlanning.mode(senderChoice: nil, receiverRequested: parsed,
                                                    current: requested == .mirror ? .extend : .mirror), requested)
        }
    }

    func testManualApprovalOverridesRequestedMode() {
        let choice = SessionApprovalPlan.plan(for: SenderApprovalDecision.allowMirror).mode
        XCTAssertEqual(SessionModePlanning.mode(senderChoice: choice, receiverRequested: .extend, current: .extend), .mirror)
        let permanent = SessionApprovalPlan.plan(for: SenderApprovalDecision.allowPermanently).mode
        XCTAssertEqual(SessionModePlanning.mode(senderChoice: permanent, receiverRequested: .mirror, current: .extend), .mirror)
    }

    func testMissingOrUnknownRequestedModeFallsBackToCurrent() {
        XCTAssertNil(SessionModePlanning.requestedMode(nil))
        XCTAssertNil(SessionModePlanning.requestedMode("sideways"))
        XCTAssertEqual(SessionModePlanning.mode(senderChoice: nil, receiverRequested: nil, current: .extend), .extend)
    }

    func testPromptDefaultFollowsLateRequestedMode() {
        var approvals = PendingSessionApprovals()
        approvals.begin(approval("1", peer: "a"))
        approvals.updateMode(id: "1", mode: .mirror)
        XCTAssertEqual(approvals.first?.mode, .mirror)
        approvals.updateMode(id: "stale", mode: .extend)
        XCTAssertEqual(approvals.first?.mode, .mirror)
    }

    func testAllowPermanentlyDoesNotPersistMode() {
        let plan = SessionApprovalPlan.plan(for: SenderApprovalDecision.allowPermanently)
        if let policy = plan.persistPolicy { IncomingSessionPolicyStore.setPolicy(policy, peerID: "a", defaults: defaults) }
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(domain.count, 1, "only the connection policy is stored")
        XCTAssertEqual(domain.values.first as? [String: String], ["a": "alwaysAllow"])
    }

    func testHelloRequestedModeExpiresWithOutgoingRequest() {
        let state = ReceiverHelloState()
        let now = Date()
        state.setRequestedMode(.mirror, until: now.addingTimeInterval(30))
        XCTAssertEqual(state.requestedMode(now: now), .mirror)
        XCTAssertNil(state.requestedMode(now: now.addingTimeInterval(30)))
        state.setRequestedMode(nil, until: .distantPast)
        XCTAssertNil(state.requestedMode(now: now))
    }

    // MARK: - Admission boundary (regressions from the first manual test)

    private func existing(_ invitation: SessionInvitation, admitted: Bool = false) -> ReceiverRequestAdmission.ExistingSession {
        .init(admitted: admitted, invitation: invitation)
    }

    /// The reported race: the Mac's own auto-connect attempt for the receiver
    /// was already dialing when the receiver's explicit Connect arrived and
    /// absorbed it, so the Mac's manual-approval policy never applied.
    func testReceiverRequestReplacesUnadmittedAutomaticAttemptAndStillNeedsApproval() {
        let auto = SessionInvitation(initiator: .sender, intent: .automatic, mode: .extend)
        let action = ReceiverRequestAdmission.decide(policy: .askUser, existing: existing(auto))
        XCTAssertEqual(action, .replace(needsSenderApproval: true))
    }

    func testReceiverRequestMatrixOnMacSender() {
        func decide(_ peer: IncomingSessionPeerPolicy?, global: Bool) -> ReceiverRequestAdmission.Action {
            ReceiverRequestAdmission.decide(
                policy: IncomingSessionPolicy.resolve(peerPolicy: peer, automaticallyAllow: global, intent: .manual),
                existing: nil)
        }
        for global in [true, false] {
            XCTAssertEqual(decide(.blocked, global: global), .drop)
            XCTAssertEqual(decide(.alwaysAllow, global: global), .start(needsSenderApproval: false))
        }
        XCTAssertEqual(decide(nil, global: true), .start(needsSenderApproval: false))
        XCTAssertEqual(decide(nil, global: false), .start(needsSenderApproval: true))
    }

    func testExistingSessionsThatAlreadyCoverTheRequestAreKept() {
        let admittedAuto = SessionInvitation(initiator: .sender, intent: .automatic, mode: .extend)
        XCTAssertEqual(ReceiverRequestAdmission.decide(policy: .askUser, existing: existing(admittedAuto, admitted: true)),
                       .alreadyHandled)
        let duplicateKnock = SessionInvitation(initiator: .receiver, intent: .manual, mode: .extend)
        XCTAssertEqual(ReceiverRequestAdmission.decide(policy: .askUser, existing: existing(duplicateKnock)), .alreadyHandled)
        let macInvite = SessionInvitation(initiator: .sender, intent: .manual, mode: .mirror)
        XCTAssertEqual(ReceiverRequestAdmission.decide(policy: .accept, existing: existing(macInvite)), .alreadyHandled)
        XCTAssertEqual(ReceiverRequestAdmission.decide(policy: .block, existing: existing(admittedAuto)), .drop)
    }

    /// Global OFF + explicit receiver Connect: the receiver accepting its own
    /// returning invitation must not admit the session, nor allow input,
    /// until the Mac's user approves.
    func testExplicitReceiverRequestCannotBeAdmittedBeforeMacApproval() {
        guard case .start(let needsApproval) = ReceiverRequestAdmission.decide(
            policy: IncomingSessionPolicy.resolve(peerPolicy: nil, automaticallyAllow: false, intent: .manual),
            existing: nil) else { return XCTFail("expected a start") }
        let planned = SessionStartPlanning.plan(continuation: nil, initiator: .receiver, userInitiated: true,
                                                needsSenderApproval: needsApproval, mode: .extend)
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true,
                                        needsSenderApproval: planned.needsSenderApproval)
        gate.receiverResponded(.accepted)   // receiver's own-request correlation
        XCTAssertEqual(gate.state, .waiting)
        XCTAssertEqual(gate.progress, .waitingForSender)
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: true,
                                                           sessionAdmitted: gate.state == .admitted))
        gate.senderDecided(accept: true)
        XCTAssertEqual(gate.state, .admitted)
    }

    func testLegacyReceiverRequestStillWaitsForMacApproval() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: false, needsSenderApproval: true)
        XCTAssertEqual(gate.state, .waiting)
        gate.senderDecided(accept: false)
        XCTAssertEqual(gate.state, .refused(.declined))
    }

    func testSenderInviteWaitsForReceiverPrompt() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: false)
        gate.receiverResponded(.pending)
        XCTAssertNotEqual(gate.state, .admitted)
        gate.receiverResponded(.declined)
        gate.receiverResponded(.accepted)
        XCTAssertEqual(gate.state, .refused(.declined))
    }

    func testAutomaticAttemptUnderManualPolicyIsNeverAdmitted() {
        let decision = IncomingSessionPolicy.resolve(peerPolicy: nil, automaticallyAllow: false, intent: .automatic)
        XCTAssertEqual(decision, .decline)
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: false)
        gate.receiverResponded(.declined)
        XCTAssertEqual(gate.state, .refused(.declined))
    }

    func testPendingSessionRejectsInputWhateverTheGrant() {
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: true, sessionAdmitted: false))
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: false, sessionAdmitted: true))
        XCTAssertTrue(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: true, sessionAdmitted: true))
    }

    // MARK: - Continuations

    func testExplicitOrUnrelatedAttemptsNeverInheritAContinuation() {
        let approved = SessionContinuation.carrying(
            SessionInvitation(initiator: .receiver, intent: .manual, mode: .extend),
            admitted: true, awaitingLocalApproval: false)
        let explicit = SessionStartPlanning.plan(continuation: approved, initiator: .sender, userInitiated: true,
                                                 needsSenderApproval: false, mode: .mirror)
        XCTAssertNotEqual(explicit.invitation.id, approved.invitation.id)
        let autoConnect = SessionStartPlanning.plan(continuation: nil, initiator: .sender, userInitiated: false,
                                                    needsSenderApproval: false, mode: .mirror)
        XCTAssertEqual(autoConnect.invitation.initiator, .sender)
        XCTAssertEqual(autoConnect.invitation.intent, .automatic)
        XCTAssertNotEqual(autoConnect.invitation.id, approved.invitation.id)
    }

    func testRebuildCarriesPendingApprovalUnchanged() {
        let pending = SessionInvitation(initiator: .receiver, intent: .manual, mode: .extend)
        let carried = SessionContinuation.carrying(pending, admitted: false, awaitingLocalApproval: true)
        let rebuilt = SessionStartPlanning.plan(continuation: carried, initiator: .sender, userInitiated: false,
                                                needsSenderApproval: false, mode: .mirror)
        XCTAssertEqual(rebuilt.invitation, pending)
        XCTAssertTrue(rebuilt.needsSenderApproval, "a mode rebuild must never admit a pending request")
        let admitted = SessionContinuation.carrying(pending, admitted: true, awaitingLocalApproval: false)
        XCTAssertEqual(admitted.invitation.intent, .automatic)
    }
}
