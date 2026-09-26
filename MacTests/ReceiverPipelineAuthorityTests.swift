import XCTest
import Network
import os

/// Coordinator-level coverage for what `ReceiverPipelineActor` does with
/// this device's own Connect requests and with revocation, driven through
/// the real actor with fake host effects (`PipelineTestHost`):
///
/// * a Remote Access knock says `.manual` only while the user's own request
///   drives the recovery run — never for automatic recovery after a lost
///   connection, and never again once that request was answered or
///   withdrawn;
/// * withdrawing a request (Wake & Connect's Cancel) ends the run it
///   started, and never touches a live session;
/// * Forget/Block cancel parked candidate connections, and a candidate whose
///   pin disappeared while it waited is never adopted.
@MainActor
final class ReceiverPipelineAuthorityTests: XCTestCase {

    // MARK: - Knock intent (F4)

    func testAutomaticRecoveryAfterALostConnectionKnocksAutomatic() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        await establishSession(pipeline, host: host, peerID: "mac-A")

        await pipeline.setConnected(false)   // transport lost; nobody tapped anything

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .reconnecting)
        XCTAssertEqual(host.knocks.first, PipelineTestKnock(peerID: "mac-A", intent: .automatic))
        XCTAssertTrue(host.knocks.allSatisfy { $0.intent == .automatic }, "\(host.knocks)")
        await stopRecovery(pipeline)
    }

    func testExplicitConnectRequestKnocksManual() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let request = host.recordRequest(peerID: "mac-A")

        await pipeline.requestManualReconnectTransition(requestID: request.id)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .reconnecting)
        XCTAssertEqual(host.knocks.first, PipelineTestKnock(peerID: "mac-A", intent: .manual))
        await stopRecovery(pipeline)
    }

    /// The Mac answered the request (a session came up). Recovery after that
    /// session is lost is automatic — even though the request record and a
    /// stale `manualConnectPeerID` are still around here, which is exactly
    /// how `.manual` could otherwise leak into it.
    func testRecoveryAfterTheRequestWasAnsweredKnocksAutomatic() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let request = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: request.id)
        XCTAssertEqual(host.knocks.first?.intent, .manual)

        await establishSession(pipeline, host: host, peerID: "mac-A")
        host.clearKnocks()
        await pipeline.setConnected(false)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .reconnecting)
        XCTAssertEqual(host.knocks.first?.peerID, "mac-A")
        XCTAssertFalse(host.knocks.isEmpty)
        XCTAssertTrue(host.knocks.allSatisfy { $0.intent == .automatic },
                      "automatic recovery must never be upgraded to manual intent: \(host.knocks)")
        await stopRecovery(pipeline)
    }

    func testRecoveryAfterTheRequestWasCancelledKnocksAutomatic() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let request = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: request.id)

        host.withdrawRequest()
        await pipeline.endManualRun(requestID: request.id)
        host.clearKnocks()

        await establishSession(pipeline, host: host, peerID: "mac-A")
        await pipeline.setConnected(false)

        XCTAssertFalse(host.knocks.isEmpty)
        XCTAssertTrue(host.knocks.allSatisfy { $0.intent == .automatic }, "\(host.knocks)")
        await stopRecovery(pipeline)
    }

    /// Joining a run automatic recovery already started makes its next
    /// knocks manual (the user did ask), and withdrawing hands the run back
    /// to automatic recovery without ending it.
    func testRequestJoiningAnAutomaticRunIsManualOnlyUntilWithdrawn() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        await establishSession(pipeline, host: host, peerID: "mac-A")
        await pipeline.setConnected(false)
        XCTAssertEqual(host.knocks.first?.intent, .automatic)

        let request = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: request.id)
        let joined = await eventually { host.knocks.contains { $0.intent == .manual } }
        XCTAssertTrue(joined, "the joined run's next knock should carry the user's request: \(host.knocks)")

        host.withdrawRequest()
        await pipeline.endManualRun(requestID: request.id)
        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .reconnecting, "automatic recovery the request only joined keeps running")
        host.clearKnocks()
        let knockedAgain = await eventually { !host.knocks.isEmpty }
        XCTAssertTrue(knockedAgain)
        XCTAssertTrue(host.knocks.allSatisfy { $0.intent == .automatic }, "\(host.knocks)")
        await stopRecovery(pipeline)
    }

    // MARK: - Withdrawal (F6)

    func testWithdrawnRequestEndsTheRunItStarted() async throws {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let request = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: request.id)

        host.withdrawRequest()
        await pipeline.endManualRun(requestID: request.id)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .disconnected)
        host.clearKnocks()
        // The run's next attempt was due after 0.5 s; nothing may knock now.
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(host.knocks, [])
    }

    /// A newer explicit request (Wake & Connect switched to another Mac)
    /// takes over the manual run the earlier one started, so its Cancel still
    /// ends that run instead of leaving it to knock on as automatic recovery.
    func testLaterRequestTakesOverTheManualRunItJoined() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let first = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: first.id)
        let second = host.recordRequest(peerID: "mac-B")
        await pipeline.requestManualReconnectTransition(requestID: second.id)

        host.withdrawRequest()
        await pipeline.endManualRun(requestID: second.id)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .disconnected)
    }

    /// Cancel landing before the request's own `Task` reached the actor.
    func testRequestWithdrawnBeforeItReachesThePipelineStartsNothing() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let request = host.recordRequest(peerID: "mac-A")
        host.withdrawRequest()

        await pipeline.requestManualReconnectTransition(requestID: request.id)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .disconnected)
        XCTAssertEqual(host.knocks, [])
    }

    func testWithdrawingNeverTearsDownALiveSession() async {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        await establishSession(pipeline, host: host, peerID: "mac-B")
        let request = host.recordRequest(peerID: "mac-A")
        await pipeline.requestManualReconnectTransition(requestID: request.id)

        host.withdrawRequest()
        await pipeline.endManualRun(requestID: request.id)

        let phase = await pipeline.currentPhase
        XCTAssertEqual(phase, .connected)
        XCTAssertEqual(host.knocks, [])
    }

    // MARK: - Parked candidates (F5)

    func testForgetCancelsAParkedCandidate() async throws {
        let rig = try await makeParkedCandidateRig()
        rig.host.unpin(peerID: "mac-A")   // Forget removes the pin first

        await rig.pipeline.revokePeer("mac-A", trustRemoved: true)

        let cancelled = await eventually { rig.candidate.state == .cancelled }
        XCTAssertTrue(cancelled, "a parked candidate of a forgotten Mac must be cancelled")
        let current = await rig.pipeline.connection
        XCTAssertFalse(current === rig.candidate)
        await close(rig)
    }

    func testBlockCancelsThatMacsParkedCandidateAndKeepsAnotherMacsSession() async throws {
        let rig = try await makeParkedCandidateRig()

        await rig.pipeline.revokePeer("mac-A", trustRemoved: false)

        let cancelled = await eventually { rig.candidate.state == .cancelled }
        XCTAssertTrue(cancelled)
        let current = await rig.pipeline.connection
        XCTAssertTrue(current === rig.incumbent, "Block of mac-A must not end mac-B's session")
        let phase = await rig.pipeline.currentPhase
        XCTAssertEqual(phase, .connected)
        await close(rig)
    }

    /// The candidate proves itself only after its pin disappeared: it must
    /// be refused at adoption, even without an explicit revocation.
    func testCandidateUnpinnedWhileParkedIsNeverAdopted() async throws {
        let rig = try await makeParkedCandidateRig()
        rig.host.unpin(peerID: "mac-A")

        rig.candidateMacSide.send(content: Self.controlFrame, completion: .contentProcessed { _ in })

        let cancelled = await eventually { rig.candidate.state == .cancelled }
        XCTAssertTrue(cancelled)
        let current = await rig.pipeline.connection
        XCTAssertTrue(current === rig.incumbent)
        await close(rig)
    }

    /// Positive control for the test above: a still-pinned candidate that
    /// proves itself does replace the session.
    func testPinnedCandidateThatProvesItselfIsAdopted() async throws {
        let rig = try await makeParkedCandidateRig()

        rig.candidateMacSide.send(content: Self.controlFrame, completion: .contentProcessed { _ in })

        let adopted = await eventually { await rig.pipeline.connection === rig.candidate }
        XCTAssertTrue(adopted)
        await close(rig)
    }

    // MARK: - Helpers

    /// A live session with `peerID`, as after its connection became ready.
    private func establishSession(_ pipeline: ReceiverPipelineActor, host: PipelineTestHost,
                                  peerID: String) async {
        host.context.update { $0.authenticatedPeerIDHint = peerID }
        await pipeline.setConnected(true)
    }

    private func stopRecovery(_ pipeline: ReceiverPipelineActor) async {
        await pipeline.teardownForStop()
        await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect)
    }

    private func close(_ rig: ParkedCandidateRig) async {
        await stopRecovery(rig.pipeline)
        rig.incumbent.cancel()
        rig.candidate.cancel()
        rig.candidateMacSide.cancel()
        rig.listener.cancel()
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    /// One length-prefixed control message, as a Mac's reply to hello.
    private static let controlFrame: Data = {
        let body = Data(#"{"type":"welcome","pv":21}"#.utf8)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }()

    /// mac-B's live session (the incumbent) plus mac-A's newcomer parked
    /// behind it, ready and waiting to prove itself — over loopback TCP,
    /// with the listener's side of each connection standing in for the Mac.
    private func makeParkedCandidateRig() async throws -> ParkedCandidateRig {
        let host = PipelineTestHost()
        let pipeline = host.makePipeline()
        let accepted = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = host.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            accepted.withLock { $0.append(connection) }
        }
        let listening = OSAllocatedUnfairLock(initialState: false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.withLock { $0 = true } }
        }
        listener.start(queue: queue)
        let ready = await eventually { listening.withLock { $0 } }
        XCTAssertTrue(ready, "the loopback listener never became ready")
        let port = try XCTUnwrap(listener.port)

        let incumbent = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        host.pin(incumbent, as: "mac-B")
        await pipeline.handleIncomingConnection(incumbent)
        let connected = await eventually { await pipeline.currentPhase == .connected }
        XCTAssertTrue(connected, "the incumbent never became the live session")

        let candidate = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        host.pin(candidate, as: "mac-A")
        await pipeline.handleIncomingConnection(candidate)
        let parked = await eventually {
            candidate.state == .ready && accepted.withLock { $0.count } == 2
        }
        XCTAssertTrue(parked, "the candidate never became ready")
        let current = await pipeline.connection
        XCTAssertTrue(current === incumbent, "a newcomer must be parked while the incumbent is live")
        let candidateMacSide = try XCTUnwrap(accepted.withLock { $0.count == 2 ? $0[1] : nil })
        return ParkedCandidateRig(host: host, pipeline: pipeline, listener: listener, incumbent: incumbent,
                                  candidate: candidate, candidateMacSide: candidateMacSide)
    }
}

// MARK: - Fake host

private struct PipelineTestKnock: Equatable, Sendable {
    let peerID: String
    let intent: SessionInvitationIntent
}

/// Records knocks and plays `TrustStore`: a connection's pinned peer is
/// whatever the test mapped it to, until `unpin` (what Forget does). Every
/// effect runs synchronously inside the actor call that triggers it, so
/// awaiting that call is enough to observe it.
private final class PipelineTestHost: Sendable {
    let queue = DispatchQueue(label: "receiver.pipeline.authority.tests")
    let context = ReconnectContext()
    private let recordedKnocks = OSAllocatedUnfairLock<[PipelineTestKnock]>(initialState: [])
    private let pins = OSAllocatedUnfairLock<[ObjectIdentifier: String]>(initialState: [:])

    var knocks: [PipelineTestKnock] { recordedKnocks.withLock { $0 } }

    func clearKnocks() { recordedKnocks.withLock { $0.removeAll() } }

    func pin(_ connection: NWConnection, as peerID: String) {
        let key = ObjectIdentifier(connection)
        pins.withLock { $0[key] = peerID }
    }

    func unpin(peerID: String) {
        pins.withLock { entries in entries = entries.filter { $0.value != peerID } }
    }

    func pinnedPeer(of connection: NWConnection) -> String? {
        let key = ObjectIdentifier(connection)
        return pins.withLock { $0[key] }
    }

    /// What `StreamReceiver.requestConnect`/`connectPrimary` record before
    /// handing the request to the actor.
    func recordRequest(peerID: String?) -> ManualConnectRequest {
        let request = ManualConnectRequest(peerID: peerID)
        context.update {
            $0.manualConnectPeerID = peerID
            $0.manualConnectRequest = request
        }
        return request
    }

    /// What `StreamReceiver.cancelConnectRequest` withdraws synchronously.
    func withdrawRequest() {
        context.update {
            $0.manualConnectPeerID = nil
            $0.manualConnectRequest = nil
        }
    }

    func makePipeline() -> ReceiverPipelineActor {
        let context = self.context
        let uiEffects = ReceiverPipelineActor.UIEffects(
            publishSessionSnapshot: { _ in },
            setStatus: { _ in },
            setStatusConnected: {},
            // As in the app: a lost connection has no authenticated peer.
            applyConnectedUIMirror: { connected in
                if !connected { context.update { $0.authenticatedPeerIDHint = nil } }
            })
        let hostEffects = ReceiverPipelineActor.HostControlEffects(
            clearTransport: {},
            ensureTLSListening: {},
            requestRemoteConnect: { [self] peerID, intent in
                let knock = PipelineTestKnock(peerID: peerID, intent: intent)
                recordedKnocks.withLock { $0.append(knock) }
            },
            resolvePinnedPeerID: { [self] connection in pinnedPeer(of: connection) },
            getReceiveLiveness: { (generation: 0, lastDataReceived: Date()) },
            advertisesAddresses: { false },
            beginAdoption: { _, _ in },
            onConnectionReady: { [self] connection in
                let peerID = pinnedPeer(of: connection)
                context.update { $0.authenticatedPeerIDHint = peerID }
            },
            sendHello: { _ in },
            onPathUpdate: { _, _ in },
            sendPing: {},
            checkAddressChangeAndSendHello: { _ in })
        let framePipeline = ReceiverFramePipeline(outputEffects: .init(
            controlMessage: { _ in },
            audioPayload: { _ in },
            codecConfigurationChanged: { _, _ in },
            presentationFrame: { _, _, _ in },
            connectionFailed: { _ in },
            connectionClosedByPeer: {}))
        return ReceiverPipelineActor(
            queue: queue, sendTargetBox: StreamReceiver.SendTargetBox(), reconnectContext: context,
            uiEffects: uiEffects, hostEffects: hostEffects, framePipeline: framePipeline)
    }
}

private struct ParkedCandidateRig {
    let host: PipelineTestHost
    let pipeline: ReceiverPipelineActor
    let listener: NWListener
    let incumbent: NWConnection
    let candidate: NWConnection
    let candidateMacSide: NWConnection
}
