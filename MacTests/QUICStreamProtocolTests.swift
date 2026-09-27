import XCTest

/// The pure QUIC wire layer (`Shared/QUICTransportProtocol.swift`): stream
/// preface, bounded deframing, per-connection channel topology, the Video
/// channel's JSON allow-list, and the authenticated capability / discovery
/// hint models. No network involved.
final class QUICStreamProtocolTests: XCTestCase {

    // MARK: - Constants

    func testTransportIdentityConstants() {
        XCTAssertEqual(QUICTransport.alpn, "meowdisplay-quic/1")
        XCTAssertEqual(QUICTransport.applicationVersion, 1)
        XCTAssertEqual(QUICTransport.udpPort, WireCrypto.tlsPort)
        XCTAssertEqual(QUICTransport.udpPort, 9001)
        XCTAssertEqual(QUICTransport.bonjourServiceType, "_meowdisp-q._udp")
        XCTAssertEqual(TransportChannel.control.rawValue, 0x01)
        XCTAssertEqual(TransportChannel.video.rawValue, 0x02)
        XCTAssertEqual(TransportChannel.audio.rawValue, 0x03)
        XCTAssertTrue(TransportChannel.control.receiverMayWrite)
        XCTAssertFalse(TransportChannel.video.receiverMayWrite)
        XCTAssertFalse(TransportChannel.audio.receiverMayWrite)
    }

    func testApplicationErrorCodesAreStable() {
        XCTAssertEqual(QUICApplicationError.invalidStreamPreface.rawValue, 0x100)
        XCTAssertEqual(QUICApplicationError.unsupportedTransportVersion.rawValue, 0x101)
        XCTAssertEqual(QUICApplicationError.duplicateChannel.rawValue, 0x102)
        XCTAssertEqual(QUICApplicationError.unexpectedChannel.rawValue, 0x103)
        XCTAssertEqual(QUICApplicationError.sessionNotAdmitted.rawValue, 0x104)
        XCTAssertEqual(QUICApplicationError.protocolViolation.rawValue, 0x105)
        XCTAssertEqual(QUICApplicationError.peerRevoked.rawValue, 0x106)
    }

    // MARK: - Preface

    func testValidPrefacesRoundTripForEveryChannel() {
        for channel in TransportChannel.allCases {
            let bytes = QUICStreamPreface(channel: channel).encode()
            XCTAssertEqual(Array(bytes), [0x4D, 0x45, 0x4F, 0x57, 0x01, channel.rawValue, 0x00, 0x00])
            XCTAssertEqual(QUICStreamPreface.parse(bytes),
                           .parsed(QUICStreamPreface(channel: channel), consumed: 8))
        }
    }

    func testPrefaceParsesOnlyTheFirstEightBytes() {
        var bytes = QUICStreamPreface(channel: .video).encode()
        bytes.append(contentsOf: [0, 0, 0, 1, 0xAA])
        XCTAssertEqual(QUICStreamPreface.parse(bytes),
                       .parsed(QUICStreamPreface(channel: .video), consumed: 8))
    }

    func testBadMagicIsRejected() {
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x58, 1, 1, 0, 0])),
                       .rejected(.invalidStreamPreface))
        XCTAssertEqual(QUICStreamPreface.parse(Data("GET / HT".utf8)), .rejected(.invalidStreamPreface))
    }

    func testBadVersionIsRejected() {
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x57, 2, 1, 0, 0])),
                       .rejected(.unsupportedTransportVersion))
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x57, 0, 1, 0, 0])),
                       .rejected(.unsupportedTransportVersion))
    }

    func testNonzeroFlagsAreRejected() {
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x57, 1, 1, 0, 1])),
                       .rejected(.invalidStreamPreface))
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x57, 1, 1, 0x80, 0])),
                       .rejected(.invalidStreamPreface))
    }

    func testUnknownChannelIsRejected() {
        for channel: UInt8 in [0x00, 0x04, 0x7F, 0xFF] {
            XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x45, 0x4F, 0x57, 1, channel, 0, 0])),
                           .rejected(.unexpectedChannel), "channel \(channel)")
        }
    }

    func testSplitPrefaceWaitsForMoreDataButRefusesAWrongPrefix() {
        let full = QUICStreamPreface(channel: .audio).encode()
        for cut in 0..<8 {
            XCTAssertEqual(QUICStreamPreface.parse(full.prefix(cut)), .needMoreData, "cut \(cut)")
        }
        XCTAssertEqual(QUICStreamPreface.parse(Data([0x4D, 0x00])), .rejected(.invalidStreamPreface))
    }

    // MARK: - Framing

    private func frame(_ payload: Data) -> Data { QUICFrameAssembler.frame(payload) }

    func testFrameMatchesTheTCPWireFormat() {
        XCTAssertEqual(Array(frame(Data([0xAB, 0xCD]))), [0, 0, 0, 2, 0xAB, 0xCD])
    }

    func testMultipleFramesInOneReceive() throws {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 1024)
        let chunk = frame(Data("a".utf8)) + frame(Data("bb".utf8)) + frame(Data("ccc".utf8))
        XCTAssertEqual(try assembler.append(chunk), [Data("a".utf8), Data("bb".utf8), Data("ccc".utf8)])
        XCTAssertEqual(assembler.bufferedByteCount, 0)
        XCTAssertNoThrow(try assembler.finish())
    }

    func testSplitFrameAcrossReceives() throws {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 1024)
        let whole = frame(Data("hello world".utf8))
        var produced: [Data] = []
        for byte in whole {
            produced += try assembler.append(Data([byte]))
        }
        XCTAssertEqual(produced, [Data("hello world".utf8)])
    }

    func testTruncatedFrameAtEndOfStreamIsAViolation() throws {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 1024)
        XCTAssertEqual(try assembler.append(frame(Data("abcdef".utf8)).prefix(7)), [])
        XCTAssertThrowsError(try assembler.finish()) { error in
            XCTAssertEqual(error as? QUICFrameAssembler.Failure, .truncatedAtEndOfStream)
        }
    }

    func testOversizedDeclaredLengthIsRefusedBeforeBuffering() {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 1024)
        // Only the 4-byte header arrives: the declared 4 GiB-1 is refused
        // immediately, without waiting for (or reserving) any payload.
        XCTAssertThrowsError(try assembler.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))) { error in
            XCTAssertEqual(error as? QUICFrameAssembler.Failure,
                           .frameTooLarge(declared: 0xFFFF_FFFF, limit: 1024))
        }
        var exact = QUICFrameAssembler(maxPayloadBytes: 4)
        XCTAssertThrowsError(try exact.append(Data([0, 0, 0, 5])))
        XCTAssertEqual(try exact.append(Data([0, 0, 0, 4, 1, 2, 3, 4])), [Data([1, 2, 3, 4])])
    }

    func testEmptyFrameIsAViolation() {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 1024)
        XCTAssertThrowsError(try assembler.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? QUICFrameAssembler.Failure, .emptyFrame)
        }
    }

    func testBufferingIsBounded() throws {
        var assembler = QUICFrameAssembler(maxPayloadBytes: 16, receiveChunkBytes: 8)
        XCTAssertEqual(assembler.maxBufferedBytes, 4 + 16 + 8)
        // A legal partial frame is buffered...
        XCTAssertEqual(try assembler.append(Data([0, 0, 0, 16]) + Data(repeating: 1, count: 10)), [])
        // ...but a chunk that would push past one maximal frame + one chunk is refused.
        XCTAssertThrowsError(try assembler.append(Data(repeating: 1, count: 20))) { error in
            XCTAssertEqual(error as? QUICFrameAssembler.Failure, .bufferOverflow)
        }
    }

    func testChannelCaps() {
        XCTAssertEqual(TransportChannel.control.maxPayloadBytes, 1 << 20)
        XCTAssertEqual(TransportChannel.audio.maxPayloadBytes, 1 << 20)
        XCTAssertEqual(QUICFrameAssembler(channel: .video).maxPayloadBytes, QUICFrameLimits.videoMaxPayloadBytes)
    }

    /// The Video cap must admit every legitimate access unit — bounded by the
    /// raw 4:2:0 picture at the largest decode ceiling any receiver
    /// advertises (MacReceiver 4096x2304, iOS 4096 wide) — and still be finite.
    func testVideoCapCoversTheLargestLegitimateKeyframe() {
        let macReceiverRaw = 4096 * 2304 * 3 / 2
        let squareRaw = 4096 * 4096 * 3 / 2
        XCTAssertGreaterThan(QUICFrameLimits.videoMaxPayloadBytes, macReceiverRaw)
        XCTAssertGreaterThan(QUICFrameLimits.videoMaxPayloadBytes, squareRaw)
        XCTAssertEqual(QUICFrameLimits.maxRawVideoFrameBytes, squareRaw)
        XCTAssertLessThanOrEqual(QUICFrameLimits.videoMaxPayloadBytes, 32 << 20)
        XCTAssertGreaterThanOrEqual(QUICFrameLimits.maxVideoEdgePixels, 4096)
    }

    // MARK: - Channel topology

    func testRegistryAcceptsOneOfEachChannel() {
        var registry = QUICChannelRegistry()
        for channel in [TransportChannel.video, .control, .audio] {
            XCTAssertNil(registry.beginStream(initiatedBy: .sender))
            XCTAssertNil(registry.register(channel))
        }
        XCTAssertTrue(registry.has(.control) && registry.has(.video) && registry.has(.audio))
    }

    func testDuplicateChannelIsRejected() {
        var registry = QUICChannelRegistry()
        XCTAssertNil(registry.register(.video))
        XCTAssertEqual(registry.register(.video), .duplicateChannel)
        XCTAssertNil(registry.register(.control))
        XCTAssertEqual(registry.register(.control), .duplicateChannel)
    }

    func testTooManyStreamsIsRejected() {
        var registry = QUICChannelRegistry()
        for _ in 0..<QUICChannelRegistry.maxStreams {
            XCTAssertNil(registry.beginStream(initiatedBy: .sender))
        }
        XCTAssertEqual(registry.beginStream(initiatedBy: .sender), .protocolViolation)
    }

    func testWrongDirectionStreamIsRejected() {
        var registry = QUICChannelRegistry()
        XCTAssertEqual(registry.beginStream(initiatedBy: .receiver), .protocolViolation)
        XCTAssertEqual(registry.openedStreams, 0)
    }

    // MARK: - Video channel JSON allow-list

    func testVideoChannelAllowsOnlyMediaStateJSON() {
        let videoState = Data(#"{"type":"videoState","enabled":true,"width":10,"height":10}"#.utf8)
        let codecState = Data(#"{"type":"streamCodecState","codec":"hevc"}"#.utf8)
        let touch = Data(#"{"type":"touch","phase":"began","x":0.1,"y":0.1}"#.utf8)
        XCTAssertTrue(QUICVideoChannelPolicy.isAllowedJSON(videoState))
        XCTAssertTrue(QUICVideoChannelPolicy.isAllowedJSON(codecState))
        XCTAssertFalse(QUICVideoChannelPolicy.isAllowedJSON(touch))
        XCTAssertFalse(QUICVideoChannelPolicy.isAllowedJSON(Data("{not json".utf8)))
        // Annex-B with a telemetry prefix contains NULs: never mistaken for JSON.
        let annexB = Data(#"{"cap":1}"#.utf8) + Data([0, 0, 0, 1, 0x65, 0x88])
        XCTAssertFalse(QUICVideoChannelPolicy.looksLikeJSON(annexB))
        XCTAssertTrue(QUICVideoChannelPolicy.looksLikeJSON(videoState))
    }

    // MARK: - Capability / hint

    func testMissingCapabilityMeansTCPOnly() {
        let old = QUICPeerCapability(message: ["type": "hello", "pv": 21])
        XCTAssertFalse(old.supportsCompatibleQUIC)
        XCTAssertFalse(old.announcesIncompatibleQUIC)
        let tcpOnly = QUICPeerCapability(message: ["transports": ["tcp"]])
        XCTAssertFalse(tcpOnly.supportsCompatibleQUIC)
    }

    func testCompatibleAndIncompatibleCapability() {
        XCTAssertTrue(QUICPeerCapability(message: ["transports": ["tcp", "quic"], "qv": 1]).supportsCompatibleQUIC)
        let future = QUICPeerCapability(message: ["transports": ["tcp", "quic"], "qv": 2])
        XCTAssertFalse(future.supportsCompatibleQUIC)
        XCTAssertTrue(future.announcesIncompatibleQUIC)
        // QUIC listed without a version is not a usable capability either.
        XCTAssertFalse(QUICPeerCapability(message: ["transports": ["quic"]]).supportsCompatibleQUIC)
    }

    func testAdvertisedFieldsAreAdditive() {
        let on = QUICPeerCapability.advertisedFields(quicAvailable: true)
        XCTAssertEqual(on["transports"] as? [String], ["tcp", "quic"])
        XCTAssertEqual(on["qv"] as? Int, 1)
        XCTAssertTrue(QUICPeerCapability(message: on).supportsCompatibleQUIC)
        let off = QUICPeerCapability.advertisedFields(quicAvailable: false)
        XCTAssertEqual(off["transports"] as? [String], ["tcp"])
        XCTAssertNil(off["qv"])
    }

    func testDiscoveryHintCarriesNoTrustAndNoConnectToken() {
        let fields = QUICDiscoveryHint.txtFields(installID: "abc", protocolVersion: 22)
        XCTAssertEqual(Set(fields.keys), ["id", "pv", "qv"])
        XCTAssertNil(fields["cr"], "the one-shot connect token stays on _opensidecar._tcp only")
        let hint = QUICDiscoveryHint(txt: fields)
        XCTAssertEqual(hint?.peerID, "abc")
        XCTAssertEqual(hint?.isCompatible, true)
        XCTAssertNil(QUICDiscoveryHint(txt: ["id": "abc"]))
        XCTAssertNil(QUICDiscoveryHint(txt: ["qv": "1"]))
        XCTAssertEqual(QUICDiscoveryHint(txt: ["id": "x", "qv": "9"])?.isCompatible, false)
    }
}
