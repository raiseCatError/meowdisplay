import XCTest
import Network

/// TCP <-> QUIC migration and multiplexing at the sender's application layer:
/// the hot transport swap resets every connection-scoped authority exactly as
/// any reconnect does (same `AuthenticatedSessionState` /
/// `SenderSessionAuthorizationState` path `switchTransport` drives), late
/// completions from the retired transport cannot touch the new one's
/// counters, and no single application-level send gate serializes Control,
/// Video and Audio.
final class QUICMigrationTests: XCTestCase {

    // MARK: - Connection-scoped authority across a protocol migration

    private let pin = Data([0x01, 0x02, 0x03])

    private func admit(_ state: inout SenderSessionAuthorizationState, generation: UInt64) {
        state.transportBegan(generation: generation)
        _ = state.acceptHello(generation: generation, intendedPeerID: "P", claimedPeerID: "P",
                              authenticatedSPKI: pin, currentPinnedSPKI: pin,
                              receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertTrue(state.receiverResponded(.accepted, generation: generation))
    }

    /// TCP -> QUIC and QUIC -> TCP are the same sequence: the old connection
    /// ends (`invalidateApplicationSession`), the new one begins at a fresh
    /// generation, must pass hello (peer re-authenticated) and admission
    /// again, and never inherits the input grant.
    func testMigrationRequiresFreshAuthenticationAdmissionAndInputGrant() {
        for (from, to) in [(NetworkTransportProtocol.tcp, NetworkTransportProtocol.quic), (.quic, .tcp)] {
            let session = AuthenticatedSessionState()
            var authorization = SenderSessionAuthorizationState()
            let oldGeneration = session.beginTransport()
            admit(&authorization, generation: oldGeneration)
            XCTAssertTrue(session.markApplicationReady(generation: oldGeneration))
            XCTAssertTrue(authorization.grantInput(generation: oldGeneration))
            XCTAssertTrue(authorization.inputAllowed(masterEnabled: true), "\(from)")

            // switchTransport: invalidate, then the new protocol's connection begins.
            session.invalidate(generation: oldGeneration)
            _ = authorization.transportEnded()
            XCTAssertFalse(session.isLive(generation: oldGeneration), "old authority invalidated (\(from)->\(to))")
            let newGeneration = session.beginTransport()
            XCTAssertNotEqual(newGeneration, oldGeneration)
            authorization.transportBegan(generation: newGeneration)
            XCTAssertFalse(authorization.isAdmitted, "admission required again (\(from)->\(to))")
            XCTAssertFalse(authorization.inputAllowed(masterEnabled: true), "input grant reset (\(from)->\(to))")
            XCTAssertFalse(authorization.mayEmitMedia(on: newGeneration), "no media before re-admission")
            XCTAssertFalse(authorization.mayEmitMedia(on: oldGeneration), "stale generation never emits")
            // A stale hello for the retired connection cannot make the new one ready.
            XCTAssertFalse(session.markApplicationReady(generation: oldGeneration))

            admit(&authorization, generation: newGeneration)
            XCTAssertTrue(session.markApplicationReady(generation: newGeneration))
            XCTAssertTrue(authorization.mayEmitMedia(on: newGeneration))
            XCTAssertFalse(authorization.inputAllowed(masterEnabled: true), "the receiver must ask again")
        }
    }

    // MARK: - Epoch-guarded, channel-aware send accounting

    func testLateCompletionFromTheRetiredTransportCannotCorruptNewCounters() {
        let state = MacSenderPipelineState(maxPendingEncodes: 2, maxPendingSends: 3)
        let (_, oldEpoch) = state.beginMediaSend(channel: .video)
        _ = state.beginMediaSend(channel: .video)
        state.resetPendingSendsForNewTransport()
        let (inFlight, newEpoch) = state.beginMediaSend(channel: .video)
        XCTAssertEqual(inFlight, 1)
        XCTAssertNotEqual(oldEpoch, newEpoch)
        // The old transport's completions land now: ignored.
        XCTAssertFalse(state.completeMediaSend(channel: .video, epoch: oldEpoch))
        XCTAssertFalse(state.completeMediaSend(channel: .video, epoch: oldEpoch))
        XCTAssertEqual(state.pendingSendsNow, 1, "the new connection's in-flight frame is still counted")
        XCTAssertTrue(state.completeMediaSend(channel: .video, epoch: newEpoch))
        XCTAssertEqual(state.pendingSendsNow, 0)
    }

    func testVideoBackpressureNeverGatesAudioOrControl() {
        let state = MacSenderPipelineState(maxPendingEncodes: 2, maxPendingSends: 3)
        // Video is backed up at its cap (a large keyframe in flight).
        for _ in 0..<3 { _ = state.beginMediaSend(channel: .video) }
        XCTAssertTrue(state.isBackedUp())
        XCTAssertTrue(state.admitFrame(reason: "pending_sends"), "video still drops old frames as designed")
        // Audio and Control keep flowing and do not move video's counter.
        for _ in 0..<20 {
            let (audioInFlight, epoch) = state.beginMediaSend(channel: .audio)
            XCTAssertGreaterThan(audioInFlight, 0)
            XCTAssertTrue(state.completeMediaSend(channel: .audio, epoch: epoch))
            let (controlInFlight, _) = state.beginMediaSend(channel: .control)
            XCTAssertEqual(controlInFlight, 0, "control is never counted as media backpressure")
        }
        XCTAssertEqual(state.pendingSendsNow, 3)
        XCTAssertEqual(state.pendingAudioSendsNow, 0)
    }

    func testAudioInFlightNeverMakesVideoDrop() {
        let state = MacSenderPipelineState(maxPendingEncodes: 2, maxPendingSends: 1)
        for _ in 0..<10 { _ = state.beginMediaSend(channel: .audio) }
        XCTAssertFalse(state.isBackedUp(), "audio sends are not video backpressure")
        XCTAssertFalse(state.admitFrame(reason: "pending_sends"))
        XCTAssertEqual(state.pendingAudioSendsNow, 10)
    }

    // MARK: - Transport controller

    private final class Delegate: MacSenderTransportDelegate {
        var failures: [QUICTransportFailure] = []
        func transportSessionBecameReady(on connection: NWConnection) {}
        func transportShouldBeginReceiving(on connection: NWConnection) {}
        func transportPathChanged(_ route: ConnectionRoute?) {}
        func transportSessionInvalidated(reason: String) {}
        func transportLinkDied(_ detail: String) {}
        func transportCancelActiveInput() {}
        func transportPeerDeviceKind() -> String? { nil }
        func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) {
            fatalError("not exercised")
        }
        func transportQUICFailed(_ failure: QUICTransportFailure) { failures.append(failure) }
    }

    func testNoConnectionMeansNoProtocolAndNoSend() {
        let queue = DispatchQueue(label: "test.quic.controller")
        let controller = MacSenderTransportController(queue: queue, endpointName: "test", statusSink: MacSenderStatusSink())
        let delegate = Delegate()
        controller.delegate = delegate
        queue.sync {
            XCTAssertNil(controller.activeNetworkProtocol)
            XCTAssertFalse(controller.isQUICApplicationReady)
            for channel in TransportChannel.allCases {
                XCTAssertFalse(controller.send(channel: channel, content: Data([1])) { _ in })
            }
            // Repeated switches never leave overlapping ownership behind.
            for expected in 1...5 {
                controller.resetForTransportSwitch()
                XCTAssertEqual(controller.currentDialGeneration, expected)
                XCTAssertNil(controller.currentConnection)
                XCTAssertNil(controller.activeNetworkProtocol)
            }
            controller.markQUICApplicationReady()   // no session: no effect
            XCTAssertFalse(controller.isQUICApplicationReady)
        }
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    /// Over TCP every channel maps onto the one connection: an installed but
    /// not-yet-ready TCP connection reports TCP and sends nothing early.
    func testTCPConnectionReportsTCPForEveryChannel() {
        let queue = DispatchQueue(label: "test.quic.controller.tcp")
        let controller = MacSenderTransportController(queue: queue, endpointName: "test", statusSink: MacSenderStatusSink())
        queue.sync {
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            controller.installConnection(connection)
            XCTAssertEqual(controller.activeNetworkProtocol, .tcp)
            XCTAssertFalse(controller.send(channel: .video, content: Data([1])) { _ in },
                           "nothing is sent before the connection is ready")
            controller.cancelAndClearConnection()
            XCTAssertNil(controller.activeNetworkProtocol)
        }
    }
}
