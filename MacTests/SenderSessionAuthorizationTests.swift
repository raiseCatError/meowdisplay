import XCTest

/// `SenderSessionAuthorization` is the coordinator `MacSender` consults at
/// every choke point: hello verification (`acceptHello`), capture and
/// virtual-display starts (`captureOwner`), every media frame
/// (`mayEmitMedia`/`isAdmitted`), input (`inputAllowed`/`grantInput`) and
/// receiver control messages (`SenderControlAuthority`). These tests drive
/// it through the connection sequences the review called out.
final class SenderSessionAuthorizationTests: XCTestCase {
    private let pinP = Data([0x01, 0x02, 0x03])
    private let pinQ = Data([0x0A, 0x0B, 0x0C])

    /// A verified hello for peer "P" on `generation`.
    private func verifiedHello(_ state: inout SenderSessionAuthorizationState, generation: UInt64,
                               supportsInvitations: Bool = true,
                               needsSenderApproval: Bool = false) -> SenderSessionAuthorizationState.HelloOutcome {
        state.acceptHello(generation: generation, intendedPeerID: "P", claimedPeerID: "P",
                          authenticatedSPKI: pinP, currentPinnedSPKI: pinP,
                          receiverSupportsInvitations: supportsInvitations,
                          needsSenderApproval: needsSenderApproval)
    }

    private func admittedConnection(generation: UInt64 = 1) -> SenderSessionAuthorizationState {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: generation)
        XCTAssertEqual(verifiedHello(&state, generation: generation), .firstConnection)
        XCTAssertTrue(state.receiverResponded(.accepted, generation: generation))
        XCTAssertTrue(state.isAdmitted)
        return state
    }

    // MARK: - Pending sessions: no capture, no frames (Video Off/On)

    func testPendingReceiverAnswerCannotStartCaptureOrEmitFrames() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        XCTAssertEqual(verifiedHello(&state, generation: 1), .firstConnection)
        XCTAssertTrue(state.receiverResponded(.pending, generation: 1))

        // What `applyVideoEnabled(true)` -> `restartVideoCapture` ->
        // `startCapture` and the frame/encode/send gates consult while the
        // receiver's user is still deciding — i.e. a Video Off/On toggle.
        XCTAssertFalse(state.isAdmitted)
        XCTAssertNil(state.captureOwner(requested: nil))
        XCTAssertNil(state.captureOwner(requested: 1))
        XCTAssertFalse(state.mayEmitMedia(on: 1))
        XCTAssertNil(state.admittedGeneration)

        XCTAssertTrue(state.receiverResponded(.accepted, generation: 1))
        XCTAssertEqual(state.captureOwner(requested: nil), 1)
        XCTAssertTrue(state.mayEmitMedia(on: 1))
    }

    func testPendingSenderApprovalCannotStartCaptureOrEmitFrames() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        XCTAssertEqual(verifiedHello(&state, generation: 1, needsSenderApproval: true), .firstConnection)
        XCTAssertTrue(state.receiverResponded(.accepted, generation: 1))

        XCTAssertFalse(state.isAdmitted)
        XCTAssertNil(state.captureOwner(requested: nil))
        XCTAssertFalse(state.mayEmitMedia(on: 1))

        state.senderDecided(accept: true)
        XCTAssertEqual(state.captureOwner(requested: nil), 1)
    }

    func testAuthenticatedButUnverifiedConnectionIsNothing() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        XCTAssertFalse(state.isAdmitted)
        XCTAssertNil(state.captureOwner(requested: 1))
        XCTAssertFalse(state.inputAllowed(masterEnabled: true))
        XCTAssertFalse(state.grantInput(generation: 1))
    }

    // MARK: - Reconnect: connection B inherits nothing from A

    func testConnectionBCannotInheritConnectionAAdmission() {
        var state = admittedConnection(generation: 1)
        state.transportEnded()
        XCTAssertFalse(state.isAdmitted)
        XCTAssertNil(state.captureOwner(requested: nil))

        state.transportBegan(generation: 2)
        XCTAssertEqual(verifiedHello(&state, generation: 2), .newConnection)
        // Same logical session, same verified peer — still not admitted
        // until the receiver accepts on connection B.
        XCTAssertFalse(state.isAdmitted)
        XCTAssertFalse(state.mayEmitMedia(on: 2))
        XCTAssertFalse(state.mayEmitMedia(on: 1))
        XCTAssertNil(state.captureOwner(requested: 1))

        // A's late acceptance can't admit B.
        XCTAssertFalse(state.receiverResponded(.accepted, generation: 1))
        XCTAssertFalse(state.isAdmitted)

        XCTAssertTrue(state.receiverResponded(.accepted, generation: 2))
        XCTAssertTrue(state.isAdmitted(generation: 2))
        XCTAssertFalse(state.isAdmitted(generation: 1))
    }

    func testConnectionBCannotInheritConnectionAInputGrant() {
        var state = admittedConnection(generation: 1)
        XCTAssertTrue(state.grantInput(generation: 1))
        XCTAssertTrue(state.inputAllowed(masterEnabled: true))

        // Route migration straight to B (no invalidate in between).
        XCTAssertTrue(state.transportBegan(generation: 2), "the dropped grant must be reported")
        XCTAssertEqual(verifiedHello(&state, generation: 2), .newConnection)
        XCTAssertTrue(state.receiverResponded(.accepted, generation: 2))
        XCTAssertTrue(state.isAdmitted)
        XCTAssertFalse(state.hasInputGrant)
        XCTAssertFalse(state.inputAllowed(masterEnabled: true))

        // The Mac owner's answer to A's request arriving late is inert.
        XCTAssertFalse(state.grantInput(generation: 1))
        XCTAssertFalse(state.inputAllowed(masterEnabled: true))

        // B asks and is granted on its own.
        XCTAssertTrue(state.grantInput(generation: 2))
        XCTAssertTrue(state.inputAllowed(masterEnabled: true))
        XCTAssertFalse(state.inputAllowed(masterEnabled: false))
    }

    func testInputNeedsCurrentAdmissionAndCurrentGrant() {
        var state = admittedConnection(generation: 1)
        XCTAssertFalse(state.inputAllowed(masterEnabled: true), "admission alone never grants input")
        XCTAssertTrue(state.grantInput(generation: 1))
        XCTAssertTrue(state.inputAllowed(masterEnabled: true))
        XCTAssertTrue(state.revokeInput())
        XCTAssertFalse(state.inputAllowed(masterEnabled: true))
        XCTAssertFalse(state.revokeInput())
    }

    func testLostConnectionDropsGrantAndAdmission() {
        var state = admittedConnection(generation: 1)
        XCTAssertTrue(state.grantInput(generation: 1))
        XCTAssertTrue(state.transportEnded())
        XCTAssertFalse(state.isAdmitted)
        XCTAssertFalse(state.hasInputGrant)
        XCTAssertFalse(state.inputAllowed(masterEnabled: true))
    }

    func testSenderRefusalAndApprovalCarryAcrossConnections() {
        var approved = SenderSessionAuthorizationState()
        approved.transportBegan(generation: 1)
        _ = verifiedHello(&approved, generation: 1, needsSenderApproval: true)
        approved.senderDecided(accept: true)
        approved.transportBegan(generation: 2)
        XCTAssertEqual(verifiedHello(&approved, generation: 2, needsSenderApproval: true), .newConnection)
        XCTAssertTrue(approved.receiverResponded(.accepted, generation: 2))
        XCTAssertTrue(approved.isAdmitted, "the Mac user's approval belongs to the logical session")

        var refused = SenderSessionAuthorizationState()
        refused.transportBegan(generation: 1)
        _ = verifiedHello(&refused, generation: 1, needsSenderApproval: true)
        refused.senderDecided(accept: false)
        refused.transportBegan(generation: 2)
        _ = verifiedHello(&refused, generation: 2)
        refused.receiverResponded(.accepted, generation: 2)
        XCTAssertEqual(refused.gate?.state, .refused(.declined))
        XCTAssertFalse(refused.isAdmitted)
    }

    func testEarlySenderDecisionAppliesToTheFirstConnection() {
        var rejected = SenderSessionAuthorizationState()
        rejected.senderDecided(accept: false)
        rejected.transportBegan(generation: 1)
        _ = verifiedHello(&rejected, generation: 1, needsSenderApproval: true)
        XCTAssertEqual(rejected.gate?.state, .refused(.declined))

        var accepted = SenderSessionAuthorizationState()
        accepted.senderDecided(accept: true)
        accepted.transportBegan(generation: 1)
        _ = verifiedHello(&accepted, generation: 1, needsSenderApproval: true)
        accepted.receiverResponded(.accepted, generation: 1)
        XCTAssertTrue(accepted.isAdmitted)
    }

    func testLegacyReceiverIsAdmittedPerVerifiedConnection() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        _ = verifiedHello(&state, generation: 1, supportsInvitations: false)
        XCTAssertTrue(state.isAdmitted)
        state.transportBegan(generation: 2)
        XCTAssertFalse(state.isAdmitted, "a new connection must re-prove identity first")
        _ = verifiedHello(&state, generation: 2, supportsInvitations: false)
        XCTAssertTrue(state.isAdmitted(generation: 2))
    }

    func testNewAdmissionIsReportedOncePerConnection() {
        var state = admittedConnection(generation: 1)
        let first = state.consumeNewAdmission()
        XCTAssertEqual(first?.generation, 1)
        XCTAssertEqual(first?.first, true)
        XCTAssertNil(state.consumeNewAdmission())
        XCTAssertTrue(state.everAdmitted)

        state.transportBegan(generation: 2)
        _ = verifiedHello(&state, generation: 2)
        XCTAssertNil(state.consumeNewAdmission(), "not admitted yet")
        state.receiverResponded(.accepted, generation: 2)
        let second = state.consumeNewAdmission()
        XCTAssertEqual(second?.generation, 2)
        XCTAssertEqual(second?.first, false)
    }

    func testRepeatedHelloOnSameConnectionChangesNothing() {
        var state = admittedConnection(generation: 1)
        XCTAssertTrue(state.grantInput(generation: 1))
        XCTAssertEqual(verifiedHello(&state, generation: 1), .sameConnection)
        XCTAssertTrue(state.isAdmitted)
        XCTAssertTrue(state.hasInputGrant)
    }

    func testHelloForAnythingButTheLiveTransportIsStale() {
        var state = SenderSessionAuthorizationState()
        XCTAssertEqual(verifiedHello(&state, generation: 1), .stale)
        state.transportBegan(generation: 2)
        XCTAssertEqual(verifiedHello(&state, generation: 1), .stale)
        XCTAssertNil(state.gate)
        XCTAssertNil(state.verifiedGeneration)
    }

    // MARK: - USB and TCP: one identity rule

    func testPCertificateClaimingQFailsBeforeReadinessOrPolicy() {
        // The pipeline was built for P (a USB target resolved through
        // `installIDByUDID`, or a TCP target): P's pinned key completes TLS,
        // then the hello claims Q's install ID.
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        let outcome = state.acceptHello(generation: 1, intendedPeerID: "P", claimedPeerID: "Q",
                                        authenticatedSPKI: pinP, currentPinnedSPKI: pinP,
                                        receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertEqual(outcome, .rejected(.identityMismatch))
        // Nothing was recorded that readiness, admission or a per-peer
        // policy lookup could build on.
        XCTAssertNil(state.verifiedGeneration)
        XCTAssertNil(state.gate)
        XCTAssertFalse(state.isAdmitted)
        XCTAssertFalse(state.grantInput(generation: 1))
        XCTAssertNil(state.captureOwner(requested: 1))
    }

    func testMissingClaimedIdentityIsRejected() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        XCTAssertEqual(state.acceptHello(generation: 1, intendedPeerID: "P", claimedPeerID: nil,
                                         authenticatedSPKI: pinP, currentPinnedSPKI: pinP,
                                         receiverSupportsInvitations: true, needsSenderApproval: false),
                       .rejected(.identityMismatch))
    }

    func testKeyThatIsNoLongerTheCurrentPinIsRejected() {
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        // Forgotten (no pin) and re-paired with a different key.
        XCTAssertEqual(state.acceptHello(generation: 1, intendedPeerID: "P", claimedPeerID: "P",
                                         authenticatedSPKI: pinP, currentPinnedSPKI: nil,
                                         receiverSupportsInvitations: true, needsSenderApproval: false),
                       .rejected(.trustRevokedOrChanged))
        XCTAssertEqual(state.acceptHello(generation: 1, intendedPeerID: "P", claimedPeerID: "P",
                                         authenticatedSPKI: pinP, currentPinnedSPKI: pinQ,
                                         receiverSupportsInvitations: true, needsSenderApproval: false),
                       .rejected(.trustRevokedOrChanged))
        XCTAssertEqual(state.acceptHello(generation: 1, intendedPeerID: "P", claimedPeerID: "P",
                                         authenticatedSPKI: nil, currentPinnedSPKI: pinP,
                                         receiverSupportsInvitations: true, needsSenderApproval: false),
                       .rejected(.trustRevokedOrChanged))
        XCTAssertNil(state.verifiedGeneration)
    }

    func testReconnectReprovesIdentity() {
        var state = admittedConnection(generation: 1)
        state.transportBegan(generation: 2)
        let outcome = state.acceptHello(generation: 2, intendedPeerID: "P", claimedPeerID: "P",
                                        authenticatedSPKI: pinQ, currentPinnedSPKI: pinP,
                                        receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertEqual(outcome, .rejected(.trustRevokedOrChanged))
        XCTAssertFalse(state.receiverResponded(.accepted, generation: 2))
        XCTAssertFalse(state.isAdmitted)
    }

    func testHelloVerificationIsRouteIndependent() {
        XCTAssertEqual(SenderHelloVerification.verify(intendedPeerID: "P", claimedPeerID: "P",
                                                      authenticatedSPKI: pinP, currentPinnedSPKI: pinP), .verified)
        XCTAssertEqual(SenderHelloVerification.verify(intendedPeerID: "P", claimedPeerID: "Q",
                                                      authenticatedSPKI: pinP, currentPinnedSPKI: pinP),
                       .identityMismatch)
        XCTAssertEqual(SenderHelloVerification.verify(intendedPeerID: "P", claimedPeerID: "P",
                                                      authenticatedSPKI: pinQ, currentPinnedSPKI: pinP),
                       .trustRevokedOrChanged)
    }

    // MARK: - Control messages

    func testMacWideAndInputRequestsNeedAnAdmittedSession() {
        let admittedOnly = [
            "touch", "scroll", "pointer", "pencil", "proximity", "keyboard", "gesture",
            WireMessage.nativeAppGesture, WireMessage.allowInputRequest, WireMessage.displayModeRequest,
            WireMessage.videoRequest, WireMessage.streamingProfileRequest, WireMessage.streamingPriorityRequest,
            WireMessage.mirrorDisplayRequest, WireMessage.extendShapeRequest, WireMessage.maxFPSRequest,
            WireMessage.promoteInteractiveWake,
            "someFutureMessage",
        ]
        for type in admittedOnly {
            XCTAssertEqual(SenderControlAuthority.requirement(for: type), .admittedSession, type)
        }
    }

    func testHandshakeLivenessAndTeardownWorkBeforeAdmission() {
        let beforeAdmission = [
            "hello", "ping", "stats", "kf", WireMessage.sessionInviteResponse, WireMessage.sleeping,
            WireMessage.closing, WireMessage.smartTouchProbe, WireMessage.audioRequest,
        ]
        for type in beforeAdmission {
            XCTAssertEqual(SenderControlAuthority.requirement(for: type), .verifiedConnection, type)
        }
    }

    // MARK: - Thread-safe wrapper

    func testWrapperMirrorsState() {
        let authorization = SenderSessionAuthorization()
        authorization.transportBegan(generation: 7)
        XCTAssertEqual(authorization.acceptHello(generation: 7, intendedPeerID: "P", claimedPeerID: "P",
                                                 authenticatedSPKI: pinP, currentPinnedSPKI: pinP,
                                                 receiverSupportsInvitations: true, needsSenderApproval: false),
                       .firstConnection)
        XCTAssertNil(authorization.captureOwner(requested: nil))
        XCTAssertTrue(authorization.receiverResponded(.accepted, generation: 7))
        XCTAssertEqual(authorization.captureOwner(requested: nil), 7)
        XCTAssertTrue(authorization.mayEmitMedia(on: 7))
        XCTAssertTrue(authorization.grantInput(generation: 7))
        XCTAssertTrue(authorization.inputAllowed(masterEnabled: true))
        XCTAssertTrue(authorization.transportBegan(generation: 8))
        XCTAssertFalse(authorization.isAdmitted)
        XCTAssertFalse(authorization.hasInputGrant)
        XCTAssertFalse(authorization.snapshot.isAdmitted)
    }
}
