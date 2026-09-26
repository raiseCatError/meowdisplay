import XCTest

/// The Mac-side and shared decisions behind receiver connect requests,
/// approval prompts and their revocation: what a Remote Access knock may
/// ask for, when the Mac's approval prompt may appear, and what Forget,
/// Block and a new connection take away.
final class SessionAuthorityRevocationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SessionAuthorityRevocationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Remote Access knock intent

    func testKnockIntentRoundTrips() {
        XCTAssertEqual(RemoteConnectRequestIntent.intent(fromFrame: RemoteConnectRequestIntent.frame(for: .manual)),
                       .manual)
        XCTAssertEqual(RemoteConnectRequestIntent.intent(fromFrame: RemoteConnectRequestIntent.frame(for: .automatic)),
                       .automatic)
    }

    func testKnockWithoutAValidFrameIsAutomatic() {
        let manual = RemoteConnectRequestIntent.frame(for: .manual)
        func framed(_ json: String) -> Data {
            let body = Data(json.utf8)
            var length = UInt32(body.count).bigEndian
            var data = Data(bytes: &length, count: 4)
            data.append(body)
            return data
        }
        let cases: [(String, Data?)] = [
            ("older receiver: no frame at all", nil),
            ("empty read", Data()),
            ("header only", manual.prefix(4)),
            ("truncated body", manual.dropLast()),
            ("trailing bytes", manual + Data([0x7B])),
            ("wrong type", framed(#"{"type":"hello","intent":"manual"}"#)),
            ("unknown intent", framed(#"{"type":"remoteConnectRequest","intent":"urgent"}"#)),
            ("not JSON", framed("manual")),
            ("oversized", framed(#"{"type":"remoteConnectRequest","intent":"manual","pad":""#
                                 + String(repeating: "x", count: 300) + #""}"#)),
        ]
        for (name, frame) in cases {
            XCTAssertEqual(RemoteConnectRequestIntent.intent(fromFrame: frame), .automatic, name)
        }
    }

    /// Automatic Remote Access recovery on the receiver sends an `automatic`
    /// frame (or, from an older build, none). Whatever this Mac's policy,
    /// that can start a session or be dropped — never become a prompt.
    func testAutomaticRecoveryKnockNeverBecomesAManualPrompt() {
        let frames: [Data?] = [nil, RemoteConnectRequestIntent.frame(for: .automatic)]
        let policies: [IncomingSessionPeerPolicy?] = [nil, .alwaysAllow, .blocked]
        for autoAllow in [true, false] {
            IncomingSessionPolicyStore.setAutomaticallyAllow(autoAllow, defaults: defaults)
            for policy in policies {
                IncomingSessionPolicyStore.setPolicy(policy, peerID: "P", defaults: defaults)
                for frame in frames {
                    let intent = RemoteConnectRequestIntent.intent(fromFrame: frame)
                    let action = ReceiverRequestAdmission.decide(peerID: "P", intent: intent, existing: nil,
                                                                 defaults: defaults)
                    XCTAssertNotEqual(action, .start(needsSenderApproval: true),
                                      "autoAllow=\(autoAllow) policy=\(String(describing: policy))")
                    XCTAssertNotEqual(action, .replace(needsSenderApproval: true))
                }
            }
        }
        // The only way to the prompt is an explicit request.
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(nil, peerID: "P", defaults: defaults)
        XCTAssertEqual(ReceiverRequestAdmission.decide(
            peerID: "P", intent: RemoteConnectRequestIntent.intent(fromFrame: RemoteConnectRequestIntent.frame(for: .manual)),
            existing: nil, defaults: defaults), .start(needsSenderApproval: true))
        XCTAssertEqual(ReceiverRequestAdmission.decide(peerID: "P", intent: .automatic, existing: nil,
                                                       defaults: defaults), .drop)
    }

    // MARK: - Mac approval prompt only after authentication

    private let invitation = SessionInvitation(id: "inv-1", initiator: .receiver, intent: .manual, mode: .extend)

    func testSpoofedBonjourMetadataCannotRaiseTheApprovalPrompt() {
        // Before the hello: the TXT record names "P", nothing is verified.
        XCTAssertNil(SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: true, alreadyPresented: false,
            intendedPeerID: "P", authenticatedPeerID: nil, pinnedName: "Pat's iPad"))
        // A different authenticated peer answered the dial.
        XCTAssertNil(SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: true, alreadyPresented: false,
            intendedPeerID: "P", authenticatedPeerID: "Q", pinnedName: "Pat's iPad"))
        // No pin (forgotten) means no trusted name to show.
        XCTAssertNil(SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: true, alreadyPresented: false,
            intendedPeerID: "P", authenticatedPeerID: "P", pinnedName: nil))
    }

    func testApprovalPromptAppearsOnceAfterVerifiedHelloWithThePinnedName() {
        let approval = SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: true, alreadyPresented: false,
            intendedPeerID: "P", authenticatedPeerID: "P", pinnedName: "Pat's iPad")
        XCTAssertEqual(approval?.id, "inv-1")
        XCTAssertEqual(approval?.peerID, "P")
        XCTAssertEqual(approval?.peerName, "Pat's iPad")
        XCTAssertEqual(approval?.localRole, .sender)
        XCTAssertEqual(approval?.mode, .extend)
        XCTAssertNil(SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: true, alreadyPresented: true,
            intendedPeerID: "P", authenticatedPeerID: "P", pinnedName: "Pat's iPad"), "re-hello")
        XCTAssertNil(SenderApprovalPrompting.approval(
            invitation: invitation, awaitingLocalApproval: false, alreadyPresented: false,
            intendedPeerID: "P", authenticatedPeerID: "P", pinnedName: "Pat's iPad"), "nothing to approve")
    }

    // MARK: - Late answers after Forget / Block

    func testLateAllowAfterForgetOrBlockIsNotAuthorized() {
        XCTAssertTrue(PendingApprovalRevalidation.isStillAuthorized(isPinned: true, currentPolicy: nil))
        XCTAssertTrue(PendingApprovalRevalidation.isStillAuthorized(isPinned: true, currentPolicy: .alwaysAllow))
        XCTAssertFalse(PendingApprovalRevalidation.isStillAuthorized(isPinned: false, currentPolicy: nil),
                       "forgotten")
        XCTAssertFalse(PendingApprovalRevalidation.isStillAuthorized(isPinned: true, currentPolicy: .blocked),
                       "blocked")
        XCTAssertFalse(PendingApprovalRevalidation.isStillAuthorized(isPinned: false, currentPolicy: .alwaysAllow))
    }

    // MARK: - Remembered acceptance

    func testRevokingAPeerDropsItsRememberedAcceptance() {
        var admission = ReceiverSessionAdmission()
        admission.beginConnection()
        admission.admit(invitationID: "inv-1", peerID: "P")
        XCTAssertTrue(admission.isContinuation(of: invitation, peerID: "P"))

        XCTAssertFalse(admission.revoke(peerID: "Q", currentPeerID: "P"), "another peer's revocation")
        XCTAssertTrue(admission.admitted)

        // Later a pre-pv 21 Mac Q is admitted on a new connection; P's
        // acceptance is still remembered.
        admission.beginConnection()
        admission.admit(invitationID: nil, peerID: "Q")
        XCTAssertTrue(admission.isContinuation(of: invitation, peerID: "P"))

        // Forget/Block of P drops P's remembered acceptance, so a later
        // continuation needs a fresh answer — and leaves Q's admission alone.
        XCTAssertTrue(admission.revoke(peerID: "P", currentPeerID: "Q"))
        XCTAssertTrue(admission.admitted, "Q's live admission is not P's to lose")
        XCTAssertFalse(admission.isContinuation(of: invitation, peerID: "P"))
        XCTAssertFalse(admission.revoke(peerID: "P", currentPeerID: "Q"), "nothing left to revoke")
    }

    func testRevokingTheCurrentPeerDropsItsAdmission() {
        var admission = ReceiverSessionAdmission()
        admission.beginConnection()
        admission.admit(invitationID: nil, peerID: "P")   // legacy sender: nothing remembered
        XCTAssertTrue(admission.revoke(peerID: "P", currentPeerID: "P"))
        XCTAssertFalse(admission.admitted)
    }

    // MARK: - Per-connection admission gate

    func testGateRequiresFreshReceiverAcceptancePerConnection() {
        var gate = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: true)
        gate.receiverResponded(.accepted)
        gate.senderDecided(accept: true)
        XCTAssertEqual(gate.state, .admitted)
        gate.beginConnection(receiverSupportsInvitations: true)
        XCTAssertEqual(gate.state, .waiting)
        XCTAssertTrue(gate.senderApproved, "the Mac user's decision is about the logical session")
        gate.receiverResponded(.accepted)
        XCTAssertEqual(gate.state, .admitted)

        var refused = SessionAdmissionGate(receiverSupportsInvitations: true, needsSenderApproval: false)
        refused.receiverResponded(.blocked)
        refused.beginConnection(receiverSupportsInvitations: true)
        XCTAssertEqual(refused.state, .refused(.blocked))

        var legacy = SessionAdmissionGate(receiverSupportsInvitations: false, needsSenderApproval: false)
        legacy.beginConnection(receiverSupportsInvitations: false)
        XCTAssertEqual(legacy.state, .admitted)
    }

    // MARK: - Input requests across a connection change

    func testConnectionChangeRetiresAPendingInputRequestWithoutACooldown() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        guard let stale = lifecycle.beginRequest(now: now) else { return XCTFail("first request") }
        lifecycle.invalidatePending()
        XCTAssertFalse(lifecycle.isPending)
        // The Mac owner's answer (or the prompt's dismissal) for the old
        // connection resolves nothing and starts no cooldown...
        XCTAssertFalse(lifecycle.resolve(generation: stale, decision: .allowSession, now: now))
        XCTAssertFalse(lifecycle.resolve(generation: stale, decision: .notNow, now: now))
        XCTAssertNil(lifecycle.cooldownUntil)
        // ...and the new connection may ask straight away.
        XCTAssertNotNil(lifecycle.beginRequest(now: now))
    }

    func testConnectionChangeDoesNotLiftAnExistingCooldown() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        guard let generation = lifecycle.beginRequest(now: now) else { return XCTFail("first request") }
        XCTAssertTrue(lifecycle.resolve(generation: generation, decision: .notNow, now: now))
        lifecycle.invalidatePending()
        XCTAssertNil(lifecycle.beginRequest(now: now.addingTimeInterval(1)),
                     "reconnecting must not become a way around Not Now")
    }
}
