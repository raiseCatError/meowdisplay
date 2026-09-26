import XCTest
import AVFoundation
import os

/// Coordinator-level coverage for the receiver's session authority, driven
/// through a real `StreamReceiver`: invitations arrive through
/// `receiveControlMessageForTesting` (as if on a connection authenticated as
/// a given pinned peer) and state is read back with `probeForTesting`.
///
/// * Forget and Block revoke what a Mac could still use — open prompts and
///   remembered acceptances — and an Allow that lands afterwards is inert:
///   nothing admitted, no Always Allow persisted, a Block never overwritten.
/// * An invitation on a connection whose peer no longer resolves to a pin is
///   declined, even with Automatically Allow Connections on.
/// * Wake & Connect's Cancel (`cancelConnectRequest`) withdraws the attempt's
///   `cr` token, "asked for exactly this" window, requested mode and manual
///   recovery run, so a later dial-in meets the normal incoming policy.
///
/// `IncomingSessionPolicyStore` works on `UserDefaults.standard`; every test
/// uses its own peer IDs and the global preference is restored afterwards.
@MainActor
final class StreamReceiverSessionAuthorityTests: XCTestCase {
    private let savedAutomaticallyAllow: Any? =
        UserDefaults.standard.object(forKey: IncomingSessionPolicyStore.automaticallyAllowKey)
    private var peers: [String] = []
    private let pinned = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    override func tearDown() async throws {
        if let savedAutomaticallyAllow {
            UserDefaults.standard.set(savedAutomaticallyAllow, forKey: IncomingSessionPolicyStore.automaticallyAllowKey)
        } else {
            UserDefaults.standard.removeObject(forKey: IncomingSessionPolicyStore.automaticallyAllowKey)
        }
        for peer in peers { IncomingSessionPolicyStore.removePolicy(peerID: peer) }
        try await super.tearDown()
    }

    // MARK: - Forget / Block (F5)

    func testForgetDismissesPromptsAndRevokesRememberedAcceptance() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(true)
        receiver.receiveControlMessageForTesting(try invite("accepted", .sender, .automatic), authenticatedPeerID: peer)
        _ = await probe(receiver)
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("prompt", .sender, .manual), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertTrue(state.admitted)
        XCTAssertEqual(state.acceptedInvitationID, "accepted")
        XCTAssertEqual(state.pendingApprovalIDs, ["prompt"])

        receiver.forgetPeer(peer)
        state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, [], "Forget must dismiss that Mac's prompt")
        XCTAssertFalse(state.admitted)
        XCTAssertNil(state.acceptedInvitationID, "Forget must drop the remembered acceptance")

        receiver.respondToSessionInvitation(id: "prompt", decision: .allowPermanently)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted, "a late Allow after Forget must not admit")
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: peer), "a late Allow after Forget must not persist Always Allow")

        // The session the Mac had accepted can no longer continue without a decision.
        receiver.receiveControlMessageForTesting(try invite("accepted", .sender, .automatic), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
    }

    func testLateAllowAfterBlockIsInertAndKeepsTheBlock() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("prompt", .sender, .manual), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, ["prompt"])

        receiver.setIncomingSessionPolicy(.blocked, peerID: peer)
        state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, [], "Block must dismiss that Mac's prompt")

        receiver.respondToSessionInvitation(id: "prompt", decision: .allowPermanently)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: peer), .blocked,
                       "a late Allow Permanently must never overwrite Block with Always Allow")
    }

    func testBlockRevokesTheRememberedAcceptance() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(true)
        receiver.receiveControlMessageForTesting(try invite("accepted", .sender, .automatic), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertTrue(state.admitted)

        receiver.setIncomingSessionPolicy(.blocked, peerID: peer)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
        XCTAssertNil(state.acceptedInvitationID)

        // Unblocking later must not quietly resume the old acceptance.
        receiver.setIncomingSessionPolicy(nil, peerID: peer)
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("accepted", .sender, .automatic), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
    }

    /// The Block is persisted before its revocation reaches the prompt
    /// (or was written some other way): the answer is still inert.
    func testAllowLandingAfterABlockWasPersistedIsInert() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("prompt", .sender, .manual), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, ["prompt"])
        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: peer)

        receiver.respondToSessionInvitation(id: "prompt", decision: .allowPermanently)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
        XCTAssertEqual(state.pendingApprovalIDs, [])
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: peer), .blocked)
    }

    /// Forget's pin removal lands before its revocation reaches the prompt.
    func testAllowLandingAfterThePinWasRemovedIsInert() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("prompt", .sender, .manual), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, ["prompt"])
        pinned.withLock { _ = $0.remove(peer) }

        receiver.respondToSessionInvitation(id: "prompt", decision: .allowPermanently)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: peer))
    }

    /// Positive control for the late-answer tests: still pinned, not
    /// blocked, so the same answer admits and persists Always Allow.
    func testAllowWhileStillAuthorizedAdmits() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("prompt", .sender, .manual), authenticatedPeerID: peer)
        var state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, ["prompt"])

        receiver.respondToSessionInvitation(id: "prompt", decision: .allowPermanently)
        state = await probe(receiver)
        XCTAssertTrue(state.admitted)
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: peer), .alwaysAllow)
    }

    func testInvitationWithoutAPinnedPeerIsDeclinedEvenWhenAutomaticallyAllowed() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(true)

        receiver.receiveControlMessageForTesting(try invite("unpinned", .sender, .automatic), authenticatedPeerID: nil)
        var state = await probe(receiver)
        XCTAssertFalse(state.admitted, "no resolvable pinned peer must fail closed")
        XCTAssertEqual(state.pendingApprovalIDs, [])

        receiver.receiveControlMessageForTesting(try invite("pinned", .sender, .automatic), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertTrue(state.admitted, "positive control: a pinned peer is admitted by the same policy")
    }

    // MARK: - Wake & Connect Cancel (F6)

    /// `WakeConnectCoordinator.begin` calls `connectPrimary`, and `cancel()`
    /// calls `cancelConnectRequest` — exercised here directly.
    func testCancelWithdrawsTheConnectRequestAndItsRecoveryRun() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)

        receiver.connectPrimary(peerID: peer, mode: .extend)
        var state = await waitForProbe(receiver) { $0.connectRequestToken != nil && $0.phase == .reconnecting }
        XCTAssertNotNil(state.connectRequestToken)
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertEqual(state.outgoingSessionRequestPeerID, peer)
        XCTAssertEqual(state.requestedMode, .extend)
        XCTAssertEqual(state.manualConnectPeerID, peer)
        XCTAssertEqual(state.manualConnectRequest?.peerID, peer)

        receiver.cancelConnectRequest(peerID: peer)
        state = await waitForProbe(receiver) { $0.phase == .disconnected && $0.connectRequestToken == nil }
        XCTAssertNil(state.connectRequestToken, "the cr token must be withdrawn")
        XCTAssertEqual(state.phase, .disconnected, "the manual recovery run must end")
        XCTAssertFalse(state.hasOutgoingSessionRequest)
        XCTAssertNil(state.requestedMode)
        XCTAssertNil(state.manualConnectPeerID)
        XCTAssertNil(state.manualConnectRequest)

        // The Mac dials in afterwards: normal policy (a prompt), never
        // "this device asked for exactly this".
        receiver.receiveControlMessageForTesting(try invite("late", .receiver, .manual), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertFalse(state.admitted)
        XCTAssertEqual(state.pendingApprovalIDs, ["late"])
    }

    /// Cancel tapped immediately, before the request's own hops ran.
    func testCancelRightAfterConnectLeavesNothingBehind() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()

        receiver.connectPrimary(peerID: peer, mode: .mirror)
        receiver.cancelConnectRequest(peerID: peer)
        try await Task.sleep(nanoseconds: 400_000_000)

        let state = await waitForProbe(receiver) { $0.phase == .disconnected && $0.connectRequestToken == nil }
        XCTAssertNil(state.connectRequestToken)
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertFalse(state.hasOutgoingSessionRequest)
        XCTAssertNil(state.requestedMode)
        XCTAssertNil(state.manualConnectRequest)
    }

    /// Positive control for the Cancel test: while the request stands, the
    /// Mac's answer to it is accepted without a second prompt.
    func testOwnStandingRequestIsAnsweredWithoutASecondPrompt() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.connectPrimary(peerID: peer, mode: .mirror)
        _ = await waitForProbe(receiver) { $0.connectRequestToken != nil && $0.hasOutgoingSessionRequest }

        receiver.receiveControlMessageForTesting(try invite("answer", .receiver, .manual), authenticatedPeerID: peer)
        let state = await probe(receiver)
        XCTAssertTrue(state.admitted)
        XCTAssertEqual(state.pendingApprovalIDs, [])

        receiver.cancelConnectRequest(peerID: peer)
        _ = await waitForProbe(receiver) { $0.phase == .disconnected }
    }

    /// A session with the requested Mac admitted some other way (here the
    /// Mac's own automatic dial, by policy) still answers the request: its
    /// "asked for exactly this" window and requested mode must not outlive
    /// that session into a later dial-in.
    func testAdmittedSessionEndsTheOwnRequestWindow() async throws {
        let peer = makePinnedPeer()
        let receiver = makeReceiver()
        IncomingSessionPolicyStore.setAutomaticallyAllow(true)
        receiver.connectPrimary(peerID: peer, mode: .mirror)
        var state = await waitForProbe(receiver) { $0.connectRequestToken != nil && $0.hasOutgoingSessionRequest }
        XCTAssertEqual(state.requestedMode, .mirror)

        receiver.receiveControlMessageForTesting(try invite("mac-started", .sender, .automatic), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertTrue(state.admitted)
        XCTAssertFalse(state.hasOutgoingSessionRequest)
        XCTAssertNil(state.requestedMode)

        IncomingSessionPolicyStore.setAutomaticallyAllow(false)
        receiver.receiveControlMessageForTesting(try invite("later", .receiver, .manual), authenticatedPeerID: peer)
        state = await probe(receiver)
        XCTAssertEqual(state.pendingApprovalIDs, ["later"], "the shortcut must not survive the session that answered it")

        receiver.cancelConnectRequest(peerID: peer)
        _ = await waitForProbe(receiver) { $0.phase == .disconnected }
    }

    // MARK: - Helpers

    private func makePinnedPeer() -> String {
        let peer = "authority-test-\(UUID().uuidString)"
        peers.append(peer)
        pinned.withLock { _ = $0.insert(peer) }
        return peer
    }

    private func makeReceiver() -> StreamReceiver {
        let pinned = self.pinned
        return StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                              deviceKind: "Test", fallbackServiceName: "Test",
                              isPeerPinned: { peerID in pinned.withLock { $0.contains(peerID) } })
    }

    private func invite(_ id: String, _ initiator: SessionRole, _ intent: SessionInvitationIntent) throws -> Data {
        let invitation = SessionInvitation(id: id, initiator: initiator, intent: intent, mode: .extend)
        return try JSONSerialization.data(withJSONObject: invitation.message)
    }

    /// Hops onto the receiver's queue behind everything already enqueued
    /// there, so queue-side effects of earlier calls are always visible.
    private func probe(_ receiver: StreamReceiver) async -> StreamReceiver.ConnectRequestTestProbe {
        await withCheckedContinuation { continuation in
            receiver.probeForTesting { continuation.resume(returning: $0) }
        }
    }

    /// For effects that also cross `Task`s and the pipeline actor.
    private func waitForProbe(_ receiver: StreamReceiver, timeout: TimeInterval = 5,
                              until condition: (StreamReceiver.ConnectRequestTestProbe) -> Bool)
        async -> StreamReceiver.ConnectRequestTestProbe {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = await probe(receiver)
        while !condition(latest), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            latest = await probe(receiver)
        }
        return latest
    }
}
