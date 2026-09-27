import XCTest
import Network

/// Receiver-side QUIC authority and resource bounds
/// (`Shared/QUICReceiverSession.swift`, the QUIC paths of
/// `ReceiverFramePipeline`/`ReceiverPipelineActor`): bounded live
/// connections, one stream per channel, retirement together with the
/// session's Control stream, Forget/Block of not-yet-bound connections,
/// admission-gated media, strict Control framing and stale generations.
/// No QUIC handshake is needed: the Network.framework objects are created
/// but never started (or dial a closed loopback port).
final class QUICReceiverAuthorityTests: XCTestCase {

    // MARK: - Fixtures

    private let queue = DispatchQueue(label: "quic.receiver.authority.tests")

    private func makeNWGroup() -> NWConnectionGroup {
        let options = NWProtocolQUIC.Options(alpn: [QUICTransport.alpn])
        return NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: 9)),
                                 using: NWParameters(quic: options))
    }

    private func makeStream() -> NWConnection {
        NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _controls: [NWConnection] = []
        private var _mediaReady = 0
        func control(_ c: NWConnection) { lock.lock(); _controls.append(c); lock.unlock() }
        func media() { lock.lock(); _mediaReady += 1; lock.unlock() }
        var controls: [NWConnection] { lock.lock(); defer { lock.unlock() }; return _controls }
        var mediaReady: Int { lock.lock(); defer { lock.unlock() }; return _mediaReady }
    }

    private func admitGroup(_ registry: QUICReceiverGroupRegistry, events: Events = Events()) -> QUICReceiverGroup? {
        let group = makeNWGroup()
        let queue = self.queue
        return registry.admit { id in
            QUICReceiverGroup(id: id, group: group, registry: registry, queue: queue,
                              onControlStream: { events.control($0) },
                              onMediaReady: { _ in events.media() })
        }
    }

    // MARK: - Bounded connections

    func testLiveConnectionsAreBounded() throws {
        let registry = QUICReceiverGroupRegistry()
        var admitted: [QUICReceiverGroup] = []
        for _ in 0..<QUICReceiverLimits.maxLiveGroups {
            admitted.append(try XCTUnwrap(admitGroup(registry)))
        }
        XCTAssertNil(admitGroup(registry), "a connection past the bound must be refused")
        XCTAssertEqual(registry.liveCount, QUICReceiverLimits.maxLiveGroups)
        admitted[0].close(nil)
        XCTAssertEqual(registry.liveCount, QUICReceiverLimits.maxLiveGroups - 1)
        XCTAssertNotNil(admitGroup(registry), "closing one frees its slot")
        registry.closeAll(error: nil)
        XCTAssertEqual(registry.liveCount, 0)
    }

    func testCloseIsIdempotentAndLateStreamsAreRefused() throws {
        let registry = QUICReceiverGroupRegistry()
        let events = Events()
        let group = try XCTUnwrap(admitGroup(registry, events: events))
        group.close(.protocolViolation)
        group.close(.protocolViolation)
        XCTAssertTrue(group.isClosed)
        XCTAssertEqual(registry.liveCount, 0)
        // A cancelled connection's late callbacks cannot resurrect it.
        let late = makeStream()
        group.accept(late)
        group.register(makeStream(), channel: .control)
        XCTAssertFalse(group.hasHandedOffControl)
        XCTAssertTrue(events.controls.isEmpty)
    }

    // MARK: - Stream topology

    func testControlIsHandedOffOnceAndMediaIsParked() throws {
        let registry = QUICReceiverGroupRegistry()
        let events = Events()
        let group = try XCTUnwrap(admitGroup(registry, events: events))
        let control = makeStream()
        let video = makeStream()
        group.register(video, channel: .video)
        group.register(control, channel: .control)
        XCTAssertEqual(events.controls.count, 1)
        XCTAssertTrue(events.controls.first === control)
        XCTAssertEqual(events.mediaReady, 1)
        XCTAssertTrue(group.isControlStream(control))
        XCTAssertTrue(registry.owner(ofControlStream: control) === group)
        let media = group.takePendingMedia()
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?.0, .video)
        XCTAssertTrue(group.takePendingMedia().isEmpty, "media is handed over exactly once")
        group.close(nil)
    }

    func testDuplicateChannelClosesTheConnection() throws {
        let registry = QUICReceiverGroupRegistry()
        let events = Events()
        let group = try XCTUnwrap(admitGroup(registry, events: events))
        let first = makeStream()
        group.register(first, channel: .control)
        group.register(makeStream(), channel: .control)
        XCTAssertTrue(group.isClosed, "a second Control stream must fail the connection")
        XCTAssertEqual(events.controls.count, 1, "the duplicate never reaches the session pipeline")
    }

    func testRetiringTheControlStreamClosesItsWholeConnection() throws {
        let registry = QUICReceiverGroupRegistry()
        let group = try XCTUnwrap(admitGroup(registry))
        let control = makeStream()
        group.register(control, channel: .control)
        registry.retire(controlStream: makeStream())
        XCTAssertFalse(group.isClosed, "an unrelated connection's retirement leaves this one alone")
        registry.retire(controlStream: control)
        XCTAssertTrue(group.isClosed)
        XCTAssertNil(registry.owner(ofControlStream: control))
    }

    func testForgetOrBlockClosesConnectionsThatHaveNotBoundAControlStream() throws {
        let registry = QUICReceiverGroupRegistry()
        let unbound = try XCTUnwrap(admitGroup(registry))
        let bound = try XCTUnwrap(admitGroup(registry))
        bound.register(makeStream(), channel: .control)
        registry.closeUnboundGroups(error: .peerRevoked)
        XCTAssertTrue(unbound.isClosed)
        XCTAssertFalse(bound.isClosed, "a bound connection is revoked through the pipeline, like TCP")
        bound.close(nil)
    }

    // MARK: - Pipeline actor

    private func makeActor(registry: QUICReceiverGroupRegistry) -> ReceiverPipelineActor {
        let context = ReconnectContext()
        let uiEffects = ReceiverPipelineActor.UIEffects(
            publishSessionSnapshot: { _ in }, setStatus: { _ in }, setStatusConnected: {},
            applyConnectedUIMirror: { _ in })
        let hostEffects = ReceiverPipelineActor.HostControlEffects(
            clearTransport: {}, ensureTLSListening: {}, requestRemoteConnect: { _, _ in },
            resolvePinnedPeerID: { _ in "mac-A" },
            getReceiveLiveness: { (generation: 0, lastDataReceived: Date()) },
            advertisesAddresses: { false }, beginAdoption: { _, _ in }, onConnectionReady: { _ in },
            sendHello: { _ in }, onPathUpdate: { _, _ in }, sendPing: {},
            checkAddressChangeAndSendHello: { _ in })
        let framePipeline = ReceiverFramePipeline(outputEffects: .init(
            controlMessage: { _ in }, audioPayload: { _ in }, codecConfigurationChanged: { _, _ in },
            presentationFrame: { _, _, _ in }, connectionFailed: { _ in }, connectionClosedByPeer: {}))
        return ReceiverPipelineActor(
            queue: queue, sendTargetBox: StreamReceiver.SendTargetBox(), reconnectContext: context,
            uiEffects: uiEffects, hostEffects: hostEffects, framePipeline: framePipeline, quicGroups: registry)
    }

    func testDroppingTheAdoptedControlStreamClosesItsQUICConnection() async throws {
        let registry = QUICReceiverGroupRegistry()
        let pipeline = makeActor(registry: registry)
        let group = try XCTUnwrap(admitGroup(registry))
        let control = makeStream()
        group.register(control, channel: .control)
        await pipeline.handleIncomingConnection(control)
        let adopted = await pipeline.connection
        XCTAssertTrue(adopted === control)
        await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect)
        XCTAssertTrue(group.isClosed, "the QUIC connection must never outlive its session connection")
        await pipeline.teardownForStop()
    }

    func testReplacingTheSessionRetiresTheSupersededQUICConnection() async throws {
        let registry = QUICReceiverGroupRegistry()
        let pipeline = makeActor(registry: registry)
        let old = try XCTUnwrap(admitGroup(registry))
        let oldControl = makeStream()
        old.register(oldControl, channel: .control)
        await pipeline.handleIncomingConnection(oldControl)
        let newcomer = try XCTUnwrap(admitGroup(registry))
        let newControl = makeStream()
        newcomer.register(newControl, channel: .control)
        await pipeline.handleIncomingConnection(newControl)
        let current = await pipeline.connection
        if current === newControl {
            // Adopted outright (the old dial had already failed): the old
            // QUIC connection is retired at once and can never come back.
            XCTAssertTrue(old.isClosed, "a superseded QUIC connection cannot steal the session later")
        } else {
            // Parked behind a still-live incumbent: when the race is decided
            // against it, its whole QUIC connection goes with it.
            XCTAssertTrue(current === oldControl)
            await pipeline.cancelPendingConnections()
            XCTAssertTrue(newcomer.isClosed, "a losing candidate's QUIC connection is closed")
        }
        await pipeline.disconnectCurrentConnection(reason: .explicitDisconnect)
        XCTAssertTrue(old.isClosed)
        XCTAssertTrue(newcomer.isClosed)
        XCTAssertEqual(registry.liveCount, 0)
        await pipeline.teardownForStop()
    }

    func testMediaOfANonAdoptedConnectionStaysParked() async throws {
        let registry = QUICReceiverGroupRegistry()
        let pipeline = makeActor(registry: registry)
        let group = try XCTUnwrap(admitGroup(registry))
        group.register(makeStream(), channel: .control)
        group.register(makeStream(), channel: .audio)
        await pipeline.attachQUICMedia(from: group)
        XCTAssertEqual(group.takePendingMedia().count, 1,
                       "media is attached only while its Control stream is the adopted session")
        group.close(nil)
        await pipeline.teardownForStop()
    }

    func testRevokeClosesUnboundQUICConnections() async throws {
        let registry = QUICReceiverGroupRegistry()
        let pipeline = makeActor(registry: registry)
        let unbound = try XCTUnwrap(admitGroup(registry))
        await pipeline.revokePeer("mac-A", trustRemoved: true)
        XCTAssertTrue(unbound.isClosed)
        await pipeline.teardownForStop()
    }

    // MARK: - Admission gate

    func testMediaAdmissionGateIsBoundToTheAdoptionGeneration() {
        let gate = ReceiverMediaAdmissionGate()
        XCTAssertFalse(gate.isAdmitted(generation: 1))
        gate.begin(generation: 1)
        XCTAssertFalse(gate.isAdmitted(generation: 1))
        gate.set(admitted: true)
        XCTAssertTrue(gate.isAdmitted(generation: 1))
        XCTAssertFalse(gate.isAdmitted(generation: 2))
        gate.begin(generation: 2)
        XCTAssertFalse(gate.isAdmitted(generation: 2), "a new connection is never admitted by the old one's grant")
        XCTAssertFalse(gate.isAdmitted(generation: 1))
    }

    // MARK: - Frame pipeline QUIC media

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _control: [Data] = []
        private var _audio: [Data] = []
        private var admitted = false
        func control(_ d: Data) { lock.lock(); _control.append(d); lock.unlock() }
        func audio(_ d: Data) { lock.lock(); _audio.append(d); lock.unlock() }
        func admit(_ v: Bool) { lock.lock(); admitted = v; lock.unlock() }
        func isAdmitted() -> Bool { lock.lock(); defer { lock.unlock() }; return admitted }
        var controlMessages: [Data] { lock.lock(); defer { lock.unlock() }; return _control }
        var audioPayloads: [Data] { lock.lock(); defer { lock.unlock() }; return _audio }
    }

    private func makeFramePipeline() -> (ReceiverFramePipeline, Recorder) {
        let recorder = Recorder()
        let pipeline = ReceiverFramePipeline(outputEffects: .init(
            controlMessage: { recorder.control($0) },
            audioPayload: { recorder.audio($0) },
            codecConfigurationChanged: { _, _ in },
            presentationFrame: { _, _, _ in },
            connectionFailed: { _ in },
            connectionClosedByPeer: {},
            mediaAdmitted: { _ in recorder.isAdmitted() }))
        return (pipeline, recorder)
    }

    private func frame(_ payload: Data) -> Data { QUICFrameAssembler.frame(payload) }
    private let audioConfig = AudioMediaFrame.config(AudioConfigFrame(sampleRate: 48_000, channelCount: 2, cookie: Data([1, 2]))).encode()

    func testMediaBeforeAdmissionFailsClosed() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        await pipeline.beginAdoption(generation: 1)
        let accepted = await pipeline.ingestQUICMedia(frame(audioConfig), channel: .audio, generation: 1, connection: group)
        XCTAssertFalse(accepted)
        XCTAssertTrue(group.isClosed, "media before admission closes the QUIC connection")
        XCTAssertTrue(recorder.audioPayloads.isEmpty)
    }

    func testAdmittedAudioReachesTheExistingAudioPath() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        recorder.admit(true)
        await pipeline.beginAdoption(generation: 1)
        let bytes = frame(audioConfig) + frame(audioConfig)
        // Split across receives mid-header and mid-payload.
        _ = await pipeline.ingestQUICMedia(bytes.prefix(2), channel: .audio, generation: 1, connection: group)
        _ = await pipeline.ingestQUICMedia(bytes.dropFirst(2).prefix(7), channel: .audio, generation: 1, connection: group)
        let ok = await pipeline.ingestQUICMedia(Data(bytes.dropFirst(9)), channel: .audio, generation: 1, connection: group)
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.audioPayloads, [audioConfig, audioConfig])
        XCTAssertFalse(group.isClosed)
        group.close(nil)
    }

    func testVideoChannelMediaStateIsOrderedAndAllowedBeforeAdmission() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        await pipeline.beginAdoption(generation: 1)
        let state = Data(#"{"type":"videoState","enabled":true,"width":8,"height":8}"#.utf8)
        let ok = await pipeline.ingestQUICMedia(frame(state), channel: .video, generation: 1, connection: group)
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.controlMessages, [state])
        XCTAssertFalse(group.isClosed)
        // An access unit before admission is refused.
        let annexB = Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
        let refused = await pipeline.ingestQUICMedia(frame(annexB), channel: .video, generation: 1, connection: group)
        XCTAssertFalse(refused)
        XCTAssertTrue(group.isClosed)
    }

    func testOtherControlJSONOnVideoIsAViolation() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        recorder.admit(true)
        await pipeline.beginAdoption(generation: 1)
        let touch = Data(#"{"type":"touch","phase":"began","x":0,"y":0}"#.utf8)
        _ = await pipeline.ingestQUICMedia(frame(touch), channel: .video, generation: 1, connection: group)
        XCTAssertTrue(group.isClosed)
        XCTAssertTrue(recorder.controlMessages.isEmpty)
    }

    func testCrossChannelPayloadsAreViolations() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        recorder.admit(true)
        await pipeline.beginAdoption(generation: 1)
        let audioOnVideo = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        _ = await pipeline.ingestQUICMedia(frame(audioConfig), channel: .video, generation: 1, connection: audioOnVideo)
        XCTAssertTrue(audioOnVideo.isClosed)
        let videoOnAudio = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        _ = await pipeline.ingestQUICMedia(frame(Data([0, 0, 0, 1, 0x65])), channel: .audio, generation: 1, connection: videoOnAudio)
        XCTAssertTrue(videoOnAudio.isClosed)
        let controlAsMedia = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        _ = await pipeline.ingestQUICMedia(frame(audioConfig), channel: .control, generation: 1, connection: controlAsMedia)
        XCTAssertTrue(controlAsMedia.isClosed)
        XCTAssertTrue(recorder.audioPayloads.isEmpty)
    }

    func testHugeDeclaredMediaLengthIsRefusedWithoutAllocation() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        recorder.admit(true)
        await pipeline.beginAdoption(generation: 1)
        for channel in [TransportChannel.video, .audio] {
            let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
            let ok = await pipeline.ingestQUICMedia(Data([0xFF, 0xFF, 0xFF, 0xF0]), channel: channel,
                                                    generation: 1, connection: group)
            XCTAssertFalse(ok)
            XCTAssertTrue(group.isClosed, "\(channel)")
        }
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        let justOver = UInt32(TransportChannel.audio.maxPayloadBytes + 1).bigEndian
        let ok = await pipeline.ingestQUICMedia(withUnsafeBytes(of: justOver) { Data($0) }, channel: .audio,
                                                generation: 1, connection: group)
        XCTAssertFalse(ok)
        XCTAssertTrue(group.isClosed)
    }

    func testStaleGenerationMediaIsIgnored() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        recorder.admit(true)
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        await pipeline.beginAdoption(generation: 2)
        let ok = await pipeline.ingestQUICMedia(frame(audioConfig), channel: .audio, generation: 1, connection: group)
        XCTAssertFalse(ok)
        XCTAssertTrue(recorder.audioPayloads.isEmpty)
        XCTAssertFalse(group.isClosed, "a stale chunk is dropped, not treated as the new session's violation")
        group.close(nil)
    }

    func testQUICControlStreamCarriesControlJSONOnly() async throws {
        let (pipeline, recorder) = makeFramePipeline()
        recorder.admit(true)
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        let control = makeStream()
        await pipeline.beginAdoption(generation: 1)
        await pipeline.finishAdoption(connection: control, generation: 1, initialData: nil, quicConnection: group)
        let welcome = Data(#"{"type":"welcome","pv":22}"#.utf8)
        await pipeline.ingest(frame(welcome), generation: 1)
        XCTAssertEqual(recorder.controlMessages, [welcome])
        XCTAssertFalse(group.isClosed)
        await pipeline.ingest(frame(audioConfig), generation: 1)
        XCTAssertTrue(group.isClosed, "media on the Control stream is a violation")
        XCTAssertTrue(recorder.audioPayloads.isEmpty)
        control.cancel()
    }

    func testQUICControlOversizedDeclaredLengthIsRefused() async throws {
        let (pipeline, _) = makeFramePipeline()
        let group = try XCTUnwrap(admitGroup(QUICReceiverGroupRegistry()))
        let control = makeStream()
        await pipeline.beginAdoption(generation: 1)
        await pipeline.finishAdoption(connection: control, generation: 1, initialData: nil, quicConnection: group)
        let declared = UInt32(QUICFrameLimits.controlMaxPayloadBytes + 1).bigEndian
        await pipeline.ingest(withUnsafeBytes(of: declared) { Data($0) }, generation: 1)
        XCTAssertTrue(group.isClosed)
        control.cancel()
    }

    // MARK: - Preface read classification (physical-iPhone regression)

    /// A read that fails because the stream or its connection went away is a
    /// TRANSPORT failure. On iPhone every such failure ("Socket is not
    /// connected") was reported as `invalidStreamPreface`, hiding the real
    /// fault; only bytes that are not a preface are a protocol violation.
    func testPrefaceReadErrorIsATransportFailureNotAViolation() {
        for error in [NWError.posix(.ENOTCONN), .posix(.ECONNRESET), .posix(.EINVAL), .posix(.ECANCELED)] {
            guard case .transportFailure = QUICReceiverGroup.prefaceReadOutcome(
                data: nil, isComplete: false, error: error) else {
                return XCTFail("\(error) must be a transport failure")
            }
            // Even with partial bytes in hand, a failed read is transport.
            guard case .transportFailure = QUICReceiverGroup.prefaceReadOutcome(
                data: Data([0x4D, 0x45]), isComplete: true, error: error) else {
                return XCTFail("\(error) with partial data must be a transport failure")
            }
        }
    }

    func testPrefaceReadClassifiesPeerBytes() {
        for channel in TransportChannel.allCases {
            XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(
                data: QUICStreamPreface(channel: channel).encode(), isComplete: false, error: nil), .parsed(channel))
        }
        XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(data: Data("GET / HT".utf8), isComplete: false, error: nil),
                       .violation(.invalidStreamPreface))
        XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(
            data: Data([0x4D, 0x45, 0x4F, 0x57, 2, 1, 0, 0]), isComplete: false, error: nil),
                       .violation(.unsupportedTransportVersion))
        XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(
            data: Data([0x4D, 0x45, 0x4F, 0x57, 1, 9, 0, 0]), isComplete: false, error: nil),
                       .violation(.unexpectedChannel))
        // The peer ended the stream before a whole preface: a violation.
        XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(data: Data([0x4D, 0x45]), isComplete: true, error: nil),
                       .violation(.invalidStreamPreface))
        XCTAssertEqual(QUICReceiverGroup.prefaceReadOutcome(data: nil, isComplete: true, error: nil),
                       .violation(.invalidStreamPreface))
    }

    func testReceiverListenerParametersDoNotReuseTheLocalEndpoint() {
        let parameters = QUICReceiverListener.listenerParameters(quic: NWProtocolQUIC.Options(alpn: [QUICTransport.alpn]))
        XCTAssertFalse(parameters.allowLocalEndpointReuse,
                       "the QUIC listener must own UDP 9001 exclusively")
        XCTAssertTrue(parameters.includePeerToPeer)
        XCTAssertEqual(parameters.serviceClass, .interactiveVideo)
    }
}
