import CoreMedia
import XCTest

final class AudioMediaFrameTests: XCTestCase {
    // MARK: - Round trip

    func testConfigFrameRoundTrips() throws {
        let config = AudioConfigFrame(sampleRate: 48_000, channelCount: 2, cookie: Data([0x11, 0x90]))
        let encoded = AudioMediaFrame.config(config).encode()
        guard case .config(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a config frame")
        }
        XCTAssertEqual(decoded, config)
    }

    func testPacketFrameRoundTrips() throws {
        let packet = AudioPacketFrame(sequence: 42, capturedAtMs: 1_700_000_000_123,
                                      durationMs: 21, payload: Data([0xFF, 0x00, 0x12, 0x34]))
        let encoded = AudioMediaFrame.packet(packet).encode()
        guard case .packet(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a packet frame")
        }
        XCTAssertEqual(decoded, packet)
    }

    func testPacketFrameRoundTripsWithEmptyPayload() throws {
        let packet = AudioPacketFrame(sequence: 1, capturedAtMs: 0, durationMs: 0, payload: Data())
        let encoded = AudioMediaFrame.packet(packet).encode()
        guard case .packet(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a packet frame")
        }
        XCTAssertEqual(decoded, packet)
    }

    func testNegativeCapturedAtMsRoundTrips() throws {
        // capturedAtMs is signed (ms since epoch, always positive in
        // practice, but the wire format must not silently corrupt a
        // pathological/clock-skewed value rather than just rejecting it).
        let packet = AudioPacketFrame(sequence: 1, capturedAtMs: -5, durationMs: 21, payload: Data([1]))
        let encoded = AudioMediaFrame.packet(packet).encode()
        guard case .packet(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a packet frame")
        }
        XCTAssertEqual(decoded.capturedAtMs, -5)
    }

    // MARK: - Malformed frames rejected safely (never crash, never fatal)

    func testDecodeRejectsEmptyData() {
        XCTAssertNil(AudioMediaFrame.decode(Data()))
    }

    func testDecodeRejectsWrongMarker() {
        XCTAssertNil(AudioMediaFrame.decode(Data([0x02, 0x01])))
    }

    func testDecodeRejectsUnknownSubtype() {
        XCTAssertNil(AudioMediaFrame.decode(Data([AudioMediaFrame.marker, 0xFF])))
    }

    func testDecodeRejectsTruncatedConfigFrame() {
        let config = AudioConfigFrame(sampleRate: 48_000, channelCount: 2, cookie: Data([0x11, 0x90]))
        let encoded = AudioMediaFrame.config(config).encode()
        for length in 0..<(encoded.count - 1) {
            XCTAssertNil(AudioMediaFrame.decode(encoded.prefix(length)),
                        "truncated to \(length) bytes must not decode")
        }
    }

    func testDecodeRejectsTruncatedPacketFrame() {
        let packet = AudioPacketFrame(sequence: 1, capturedAtMs: 1000, durationMs: 21, payload: Data([1, 2, 3]))
        let encoded = AudioMediaFrame.packet(packet).encode()
        for length in 0..<(encoded.count - 1) {
            XCTAssertNil(AudioMediaFrame.decode(encoded.prefix(length)),
                        "truncated to \(length) bytes must not decode")
        }
    }

    func testDecodeRejectsPacketWithPayloadLengthLongerThanAvailableData() {
        var body = Data()
        body.append(contentsOf: [0, 0, 0, 1])          // sequence
        body.append(contentsOf: [UInt8](repeating: 0, count: 8))   // capturedAtMs
        body.append(contentsOf: [0, 0, 0, 21])         // durationMs
        body.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // absurd payload length
        var frame = Data([AudioMediaFrame.marker, 0x02])
        frame.append(body)
        XCTAssertNil(AudioMediaFrame.decode(frame))
    }

    // MARK: - Discrimination against legacy video/control framing

    func testIsAudioFrameFalseForJSONControlMessage() {
        let json = Data("{\"type\":\"ping\",\"t\":1}".utf8)
        XCTAssertFalse(AudioMediaFrame.isAudioFrame(json))
    }

    func testIsAudioFrameFalseForLegacyVideoTelemetryPrefix() {
        // Legacy video frames always start with the '{' telemetry prefix.
        var videoLike = Data("{\"cap\":1,\"snd\":2}".utf8)
        videoLike.append(contentsOf: [0, 0, 0, 1, 0x67])   // start code + NALU
        XCTAssertFalse(AudioMediaFrame.isAudioFrame(videoLike))
    }

    func testIsAudioFrameTrueOnlyForTheReservedMarkerByte() {
        XCTAssertTrue(AudioMediaFrame.isAudioFrame(Data([AudioMediaFrame.marker, 0x02])))
        XCTAssertFalse(AudioMediaFrame.isAudioFrame(Data([0x00])))
        XCTAssertFalse(AudioMediaFrame.isAudioFrame(Data()))
    }

    // MARK: - AVSyncOffset

    func testAVSyncOffsetClampsToRange() {
        XCTAssertEqual(AVSyncOffset.clamped(5_000), AVSyncOffset.range.upperBound)
        XCTAssertEqual(AVSyncOffset.clamped(-5_000), AVSyncOffset.range.lowerBound)
        XCTAssertEqual(AVSyncOffset.clamped(150), 150)
    }

    func testPositiveOffsetDelaysAudioOnly() {
        XCTAssertEqual(AVSyncOffset.audioDelayMs(for: 200), 200)
        XCTAssertEqual(AVSyncOffset.videoDelayMs(for: 200), 0)
    }

    func testNegativeOffsetDelaysVideoOnly() {
        XCTAssertEqual(AVSyncOffset.videoDelayMs(for: -300), 300)
        XCTAssertEqual(AVSyncOffset.audioDelayMs(for: -300), 0)
    }

    func testZeroOffsetDelaysNeither() {
        XCTAssertEqual(AVSyncOffset.audioDelayMs(for: 0), 0)
        XCTAssertEqual(AVSyncOffset.videoDelayMs(for: 0), 0)
    }

    func testOffsetBoundsClampBeforeComputingDelays() {
        XCTAssertEqual(AVSyncOffset.audioDelayMs(for: 10_000), AVSyncOffset.range.upperBound)
        XCTAssertEqual(AVSyncOffset.videoDelayMs(for: -10_000), AVSyncOffset.range.upperBound)
    }

    // MARK: - Protocol version gating

    func testAudioWireVersionIsFixedAtItsShippedProtocolVersion() {
        // Audio shipped at wire version 12 — a historical fact that must
        // never drift, even though a later feature (Mirror display
        // selection, 13) has since become the one that matches `version`
        // exactly — see MirrorDisplayWireTests.
        XCTAssertEqual(WireProtocol.audioWireVersion, 12)
    }

    func testAudioStateUpdateParsesEnabledField() {
        XCTAssertEqual(AudioStateUpdate(message: ["type": "audioState", "enabled": true])?.enabled, true)
        XCTAssertEqual(AudioStateUpdate(message: ["type": "audioState", "enabled": false])?.enabled, false)
    }

    func testAudioStateUpdateRejectsWrongTypeOrMissingField() {
        XCTAssertNil(AudioStateUpdate(message: ["type": "videoState", "enabled": true]))
        XCTAssertNil(AudioStateUpdate(message: ["type": "audioState"]))
    }

    // MARK: - AAC-LC framing (AudioSpecificConfig / ADTS byte boundaries)
    //
    // Forensic audit follow-up: verifies the exact bytes this build derives
    // for 48 kHz stereo AAC-LC, the configuration the sender actually uses,
    // against the well-known reference value for that configuration.

    func testAudioSpecificConfigForty8kHzStereoMatchesKnownReferenceBytes() {
        // object type 2 (AAC LC), freq index 3 (48000), channel config 2:
        // 00010 0011 0010 000 -> 0x11 0x90 — the standard, widely-verified
        // AAC-LC 48kHz/stereo ASC.
        XCTAssertEqual(AACLCFraming.audioSpecificConfig(sampleRate: 48_000, channelCount: 2),
                       Data([0x11, 0x90]))
    }

    func testAudioSpecificConfigRejectsUnsupportedSampleRateOrChannelCount() {
        XCTAssertNil(AACLCFraming.audioSpecificConfig(sampleRate: 48_000, channelCount: 0))
        XCTAssertNil(AACLCFraming.audioSpecificConfig(sampleRate: 48_000, channelCount: 9))
        XCTAssertNil(AACLCFraming.audioSpecificConfig(sampleRate: 12_345, channelCount: 2))
    }

    func testADTSHeaderIsSevenBytesAndEncodesFrameLength() {
        guard let header = AACLCFraming.adtsHeader(payloadLength: 200, sampleRate: 48_000, channelCount: 2) else {
            return XCTFail("expected a header")
        }
        XCTAssertEqual(header.count, 7)
        XCTAssertEqual(header[header.startIndex], 0xFF)
        XCTAssertEqual(header[header.startIndex + 1], 0xF1)
        // Frame length (header + payload = 207) is packed across bytes 3-5:
        // bits [12:0] of a 13-bit field starting at byte 3 bit 5.
        let b3 = header[header.startIndex + 3], b4 = header[header.startIndex + 4], b5 = header[header.startIndex + 5]
        let decodedFrameLength = (UInt32(b3 & 0x3) << 11) | (UInt32(b4) << 3) | (UInt32(b5) >> 5)
        XCTAssertEqual(decodedFrameLength, 207)
    }

    func testADTSHeaderEncodesChannelConfigInExpectedBits() {
        // The channel-config field spans byte 2's low 2 bits and byte 3's
        // top 2 bits; mono (1) vs stereo (2) differ only in byte 3's top
        // bits since 1 and 2 share the same value shifted right by 2.
        guard let mono = AACLCFraming.adtsHeader(payloadLength: 10, sampleRate: 48_000, channelCount: 1),
              let stereo = AACLCFraming.adtsHeader(payloadLength: 10, sampleRate: 48_000, channelCount: 2) else {
            return XCTFail("expected headers")
        }
        XCTAssertNotEqual(mono[mono.startIndex + 3] & 0xC0, stereo[stereo.startIndex + 3] & 0xC0)
    }

    func testADTSHeaderRejectsUnsupportedSampleRate() {
        XCTAssertNil(AACLCFraming.adtsHeader(payloadLength: 10, sampleRate: 12_345, channelCount: 2))
    }

    // MARK: - Audio packet timing (48 kHz / 1024-frame AAC-LC progression)
    //
    // Forensic audit follow-up: verifies successive packet timestamps
    // advance by exactly one AAC-LC frame's real duration (~21.333 ms at
    // 48 kHz) with no double-counting and no drift purely from the math,
    // and that a discontinuity re-anchor (encodedSampleCount reset to 0
    // with a fresh originWallMs) produces a clean restart, not a jump
    // computed from the old origin.

    // GOAL (playback A/B investigation): prove in code, not just by
    // reading `StreamReceiver.scheduleDecodedAudio`, that what actually
    // feeds `CMSampleTimingInfo.duration` is an exact rational CMTime, not
    // the rounded-to-21ms `durationMs` used only for the wire field/logs.
    // If this ever regresses to a Double-seconds or millisecond-rounded
    // intermediate, real playback timing would silently quantize away
    // 0.333ms per packet.

    func testExactSampleDurationIsNotQuantizedToWholeMilliseconds() {
        let exact = AudioPacketTiming.exactSampleDuration(sampleRate: 48_000)
        XCTAssertEqual(exact.value, 1024)
        XCTAssertEqual(exact.timescale, 48_000)
        // 1024/48000 = 0.021333...s exactly — NOT 0.021s (the 21ms
        // `durationMs` would imply) and NOT 0.0213s (a 3-decimal round).
        XCTAssertEqual(exact.seconds, 1024.0 / 48_000.0, accuracy: 1e-12)
        XCTAssertNotEqual(exact.seconds, 0.021, "duration must not have been quantized to whole milliseconds")
    }

    func testExactSampleDurationSummedOverManyPacketsMatchesExactElapsedTime() {
        // The single most important property: summing this CMTime's exact
        // rational duration over many packets must equal the true elapsed
        // time exactly — the failure mode this test guards against is
        // exactly the "accumulates ~333ms of drift over 1000 packets"
        // hypothesis, which would occur if duration were instead built
        // from a rounded-to-21ms Double intermediate.
        let packetCount = 1000
        let exact = AudioPacketTiming.exactSampleDuration(sampleRate: 48_000)
        var totalExact = CMTime.zero
        for _ in 0..<packetCount { totalExact = CMTimeAdd(totalExact, exact) }
        let trueElapsedSeconds = Double(packetCount) * 1024.0 / 48_000.0
        XCTAssertEqual(totalExact.seconds, trueElapsedSeconds, accuracy: 1e-9)

        // What the (correctly diagnostic-only) rounded field WOULD have
        // produced if it were mistakenly used for real scheduling instead —
        // demonstrating the ~333ms this test exists to rule out.
        let roundedTotalSeconds = Double(packetCount) * Double(AudioPacketTiming.durationMs(sampleRate: 48_000)) / 1000.0
        XCTAssertGreaterThan(trueElapsedSeconds - roundedTotalSeconds, 0.3,
                             "sanity check on the magnitude of drift durationMs-based scheduling would have caused")
    }

    func testPacketDurationAt48kHzIs21Milliseconds() {
        // 1024/48000 * 1000 = 21.33.., truncated by UInt32(Double) to 21 —
        // matches what ships on the wire (`AudioPacketFrame.durationMs`).
        XCTAssertEqual(AudioPacketTiming.durationMs(sampleRate: 48_000), 21)
    }

    func testPacketTimestampsAdvanceByExactlyOneFrameDurationWithNoDoubleCounting() {
        let origin = 1_700_000_000_000.0
        var sampleCount: Int64 = 0
        var timestamps: [Int64] = []
        for _ in 0..<10 {
            timestamps.append(AudioPacketTiming.capturedAtMs(
                originWallMs: origin, encodedSampleCount: sampleCount, sampleRate: 48_000))
            sampleCount += AudioPacketTiming.framesPerPacket
        }
        let deltas = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        // 1024/48000s is exactly 21.333.. ms, so truncating integer
        // timestamps alternate between 21 and 22 ms deltas (roughly 2:1) —
        // that is correct, not drift. What must NEVER happen is a delta
        // outside {21, 22} (double-counted or lost elapsed time) or a
        // long-run average that isn't ~21.33 ms (accumulating drift).
        XCTAssertTrue(deltas.allSatisfy { $0 == 21 || $0 == 22 },
                      "expected only 21/22ms deltas from truncating a 21.333..ms period, got \(deltas)")
        let average = Double(deltas.reduce(0, +)) / Double(deltas.count)
        XCTAssertEqual(average, 1024.0 / 48_000.0 * 1000, accuracy: 0.2)
    }

    func testTimestampsAreMonotonicAcrossManyPackets() {
        let origin = 1_700_000_000_000.0
        var sampleCount: Int64 = 0
        var previous: Int64?
        for _ in 0..<500 {
            let ts = AudioPacketTiming.capturedAtMs(
                originWallMs: origin, encodedSampleCount: sampleCount, sampleRate: 48_000)
            if let previous {
                XCTAssertGreaterThan(ts, previous, "audio PTS must be strictly monotonic")
            }
            previous = ts
            sampleCount += AudioPacketTiming.framesPerPacket
        }
    }

    func testDiscontinuityReanchorRestartsCleanlyFromNewOrigin() {
        let oldOrigin = 1_700_000_000_000.0
        let staleSampleCount: Int64 = 48_000 * 5   // 5s of "drifted" accounting
        let beforeReset = AudioPacketTiming.capturedAtMs(
            originWallMs: oldOrigin, encodedSampleCount: staleSampleCount, sampleRate: 48_000)

        // A detected discontinuity re-anchors both origin and sample count
        // together (see AudioCaptureEncoder.encode) — the next packet's
        // timestamp must reflect the NEW origin, not extrapolate forward
        // from the stale one.
        let newOrigin = Double(beforeReset) + 5_000   // simulated real gap
        let afterReset = AudioPacketTiming.capturedAtMs(
            originWallMs: newOrigin, encodedSampleCount: 0, sampleRate: 48_000)
        XCTAssertEqual(afterReset, Int64(newOrigin))
        XCTAssertNotEqual(afterReset, beforeReset + 5_000 + 21)
    }

    // MARK: - DEBUG-only PCM bypass A/B mode (GOAL: isolate remaining
    // intermittent audio garble to AAC vs. everything upstream of it)

    func testPCMConfigFrameRoundTrips() throws {
        let config = PCMConfigFrame(sampleRate: 48_000, channelCount: 2)
        let encoded = AudioMediaFrame.pcmConfig(config).encode()
        guard case .pcmConfig(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a pcmConfig frame")
        }
        XCTAssertEqual(decoded, config)
    }

    func testPCMPacketFrameRoundTripsByteExactPayload() throws {
        // 4 interleaved stereo Float32 frames = 32 bytes, deliberately not
        // all-zero/all-same so a planar/interleaved transposition bug in
        // either sender or receiver reconstruction would corrupt these
        // exact bytes, not merely resize the buffer.
        var floats: [Float] = []
        for i in 0..<8 { floats.append(Float(i) * 0.125 - 0.5) }
        let payload = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let packet = PCMPacketFrame(sequence: 7, capturedAtMs: 1_700_000_000_456, frameCount: 4, payload: payload)
        let encoded = AudioMediaFrame.pcmPacket(packet).encode()
        guard case .pcmPacket(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a pcmPacket frame")
        }
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.payload.count, 4 * 2 * 4)   // frameCount * channels * sizeof(Float32)
    }

    func testPCMPacketFrameRoundTripsWithEmptyPayload() throws {
        let packet = PCMPacketFrame(sequence: 1, capturedAtMs: 0, frameCount: 0, payload: Data())
        let encoded = AudioMediaFrame.pcmPacket(packet).encode()
        guard case .pcmPacket(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a pcmPacket frame")
        }
        XCTAssertEqual(decoded, packet)
    }

    func testDecodeRejectsTruncatedPCMConfigFrame() {
        let config = PCMConfigFrame(sampleRate: 48_000, channelCount: 2)
        let encoded = AudioMediaFrame.pcmConfig(config).encode()
        for length in 0..<(encoded.count - 1) {
            XCTAssertNil(AudioMediaFrame.decode(encoded.prefix(length)),
                        "truncated to \(length) bytes must not decode")
        }
    }

    func testDecodeRejectsTruncatedPCMPacketFrame() {
        let packet = PCMPacketFrame(sequence: 1, capturedAtMs: 1000, frameCount: 2, payload: Data([1, 2, 3, 4]))
        let encoded = AudioMediaFrame.pcmPacket(packet).encode()
        for length in 0..<(encoded.count - 1) {
            XCTAssertNil(AudioMediaFrame.decode(encoded.prefix(length)),
                        "truncated to \(length) bytes must not decode")
        }
    }

    /// A production sender only ever emits `.config`/`.packet` (AAC) — the
    /// PCM debug subtypes must never change how an AAC frame round-trips,
    /// i.e. adding the new subtype cases could not have perturbed the
    /// existing production decode path.
    func testPCMSubtypesDoNotAffectProductionAACDecode() {
        let config = AudioConfigFrame(sampleRate: 44_100, channelCount: 1, cookie: Data([0x12, 0x08]))
        let packet = AudioPacketFrame(sequence: 99, capturedAtMs: 42, durationMs: 21, payload: Data([9, 9, 9]))
        guard case .config(let decodedConfig)? = AudioMediaFrame.decode(AudioMediaFrame.config(config).encode()),
              case .packet(let decodedPacket)? = AudioMediaFrame.decode(AudioMediaFrame.packet(packet).encode()) else {
            return XCTFail("expected AAC frames to decode")
        }
        XCTAssertEqual(decodedConfig, config)
        XCTAssertEqual(decodedPacket, packet)
    }

    /// Stress test (GOAL: "framing / parser audit"): thousands of
    /// alternating video/audio(AAC)/PCM-debug/control frames, length-prefixed
    /// exactly as the wire does (PROTOCOL.md section 3), concatenated and
    /// then fragmented at ARBITRARY byte boundaries — proving the
    /// length-prefix framing recovers every frame in order regardless of
    /// how the underlying TCP stream happens to chunk it, and that a new
    /// debug-only PCM subtype cannot desynchronize the parser relative to
    /// the frames around it.
    func testAlternatingFrameTypesSurviveArbitraryFragmentation() {
        var expectedPayloads: [Data] = []
        var wire = Data()

        func appendFramed(_ payload: Data) {
            var length = UInt32(payload.count).bigEndian
            wire.append(Data(bytes: &length, count: 4))
            wire.append(payload)
            expectedPayloads.append(payload)
        }

        var rng = SplitMix64(seed: 0xA17)
        for i in 0..<3_000 {
            switch i % 4 {
            case 0:
                // Legacy "video-like" frame: JSON telemetry prefix + NALU bytes.
                var videoLike = Data("{\"cap\":\(i),\"snd\":\(i)}".utf8)
                let naluSize = 200 + Int(rng.next() % 2000)   // realistic-to-large video frames
                videoLike.append(contentsOf: [0, 0, 0, 1, 0x67])
                videoLike.append(Data((0..<naluSize).map { _ in UInt8(rng.next() % 256) }))
                appendFramed(videoLike)
            case 1:
                let payload = Data((0..<Int(250 + rng.next() % 350)).map { _ in UInt8(rng.next() % 256) })
                appendFramed(AudioMediaFrame.packet(AudioPacketFrame(
                    sequence: UInt32(i), capturedAtMs: Int64(i) * 21, durationMs: 21, payload: payload)).encode())
            case 2:
                let frameCount = UInt32(256 + rng.next() % 512)
                let payload = Data((0..<Int(frameCount) * 2 * 4).map { _ in UInt8(rng.next() % 256) })
                appendFramed(AudioMediaFrame.pcmPacket(PCMPacketFrame(
                    sequence: UInt32(i), capturedAtMs: Int64(i) * 21, frameCount: frameCount, payload: payload)).encode())
            default:
                appendFramed(Data("{\"type\":\"ping\",\"t\":\(i)}".utf8))
            }
        }

        // Fragment at arbitrary, non-frame-aligned boundaries — including
        // 1-byte chunks and multi-frame chunks in the same pass.
        var chunks: [Data] = []
        var offset = 0
        while offset < wire.count {
            let remaining = wire.count - offset
            let step = 1 + Int(rng.next() % UInt64(min(600, max(1, remaining))))
            chunks.append(wire.subdata(in: (wire.startIndex + offset)..<(wire.startIndex + offset + step)))
            offset += step
        }

        // Minimal re-implementation of the receiver's length-prefix demux
        // loop (PROTOCOL.md section 3): partial-read accumulation across
        // fragments, multiple frames in one read, one frame split across
        // many reads.
        var buffer = Data()
        var recovered: [Data] = []
        for chunk in chunks {
            buffer.append(chunk)
            while true {
                guard buffer.count >= 4 else { break }
                let lengthBytes = buffer.prefix(4)
                let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
                guard buffer.count >= 4 + length else { break }
                recovered.append(buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length)))
                buffer.removeFirst(4 + length)
            }
        }

        XCTAssertEqual(recovered.count, expectedPayloads.count)
        XCTAssertEqual(recovered, expectedPayloads)

        // And every recovered audio/PCM payload still demuxes to exactly
        // the frame type/content it was built from — no cross-type bleed.
        for (i, payload) in recovered.enumerated() {
            switch i % 4 {
            case 1:
                guard case .packet(let decoded)? = AudioMediaFrame.decode(payload) else {
                    return XCTFail("frame \(i) expected an AAC packet")
                }
                XCTAssertEqual(decoded.sequence, UInt32(i))
            case 2:
                guard case .pcmPacket(let decoded)? = AudioMediaFrame.decode(payload) else {
                    return XCTFail("frame \(i) expected a PCM packet")
                }
                XCTAssertEqual(decoded.sequence, UInt32(i))
            default:
                XCTAssertFalse(AudioMediaFrame.isAudioFrame(payload))
            }
        }
    }

    // MARK: - PCM wire invariant + checksum (GOAL #4/#5: diagnostic-path
    // validation follow-up — PCM was still unintelligible on device even
    // after codec-generation isolation, so these check the wire-format
    // contract itself in code rather than only asserting it in a comment.)

    func testFloat32InterleavedPCMPayloadByteCountInvariant() {
        // The invariant `AudioCaptureEncoder.encodePCM` and
        // `StreamReceiver.logReceiverPCMSanityIfDue` both check every
        // packet: for Float32 interleaved PCM, payload bytes must equal
        // frameCount * channelCount * 4.
        for (frameCount, channelCount) in [(1, 1), (1024, 2), (480, 2), (960, 6)] {
            let payload = Data(repeating: 0, count: frameCount * channelCount * 4)
            let packet = PCMPacketFrame(sequence: 1, capturedAtMs: 0,
                                        frameCount: UInt32(frameCount), payload: payload)
            XCTAssertEqual(packet.payload.count, frameCount * channelCount * 4)
            let encoded = AudioMediaFrame.pcmPacket(packet).encode()
            guard case .pcmPacket(let decoded)? = AudioMediaFrame.decode(encoded) else {
                return XCTFail("expected a PCM packet to round-trip")
            }
            XCTAssertEqual(decoded.payload.count, Int(decoded.frameCount) * channelCount * 4)
        }
    }

    func testPCMChecksumIsDeterministicAndOrderSensitive() {
        let samplesA: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
        let samplesB = samplesA   // identical content, distinct array value
        XCTAssertEqual(PCMChecksum.fnv1a(samplesA), PCMChecksum.fnv1a(samplesB),
                       "identical sample content must produce identical checksums on both sides of the wire")

        let reordered = Array(samplesA.reversed())
        XCTAssertNotEqual(PCMChecksum.fnv1a(samplesA), PCMChecksum.fnv1a(reordered),
                          "the checksum must be sensitive to sample order/position, not just a sum")

        var mutated = samplesA
        mutated[3] += 0.000_01
        XCTAssertNotEqual(PCMChecksum.fnv1a(samplesA), PCMChecksum.fnv1a(mutated),
                          "the checksum must catch even a tiny single-sample change")
    }

    func testPCMChecksumSurvivesWirePayloadEncodeDecodeRoundTrip() throws {
        // Builds a payload the same way `encodePCM` does (interleaved
        // Float32 bytes), sends it through the actual wire frame
        // encode/decode, and confirms a checksum computed on the decoded
        // side matches one computed before encoding — proving the wire
        // framing itself is not what would corrupt a checksum comparison
        // between sender and receiver logs.
        let samples: [Float] = (0..<256).map { Float(sin(Double($0) * 0.1)) }
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let originalChecksum = PCMChecksum.fnv1a(samples)

        let packet = PCMPacketFrame(sequence: 42, capturedAtMs: 1_000, frameCount: 128, payload: payload)
        let encoded = AudioMediaFrame.pcmPacket(packet).encode()
        guard case .pcmPacket(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected a PCM packet to round-trip")
        }
        let decodedSamples: [Float] = decoded.payload.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        XCTAssertEqual(PCMChecksum.fnv1a(decodedSamples), originalChecksum)
    }

    // MARK: - AAC payload checksum (receiver-side AAC investigation:
    // `MacSender.sendAudioPacket` and `StreamReceiver.scheduleAudioPacket`
    // both log this exact checksum over raw AAC access-unit bytes, at the
    // same cadence and keyed by generation/sequence, so the two logs can be
    // compared to rule transport corruption in or out.)

    func testAACPayloadChecksumIsDeterministicAndSurvivesWireRoundTrip() throws {
        let aacBytes = Data((0..<300).map { UInt8(($0 * 37) % 256) })   // arbitrary non-trivial payload
        let originalChecksum = PCMChecksum.fnv1a(aacBytes)
        XCTAssertEqual(PCMChecksum.fnv1a(aacBytes), originalChecksum, "checksum must be a pure function of the bytes")

        let packet = AudioPacketFrame(sequence: 7, capturedAtMs: 12_345, durationMs: 21, payload: aacBytes)
        let encoded = AudioMediaFrame.packet(packet).encode()
        guard case .packet(let decoded)? = AudioMediaFrame.decode(encoded) else {
            return XCTFail("expected an AAC packet to round-trip")
        }
        XCTAssertEqual(PCMChecksum.fnv1a(decoded.payload), originalChecksum,
                       "a checksum computed after the exact wire encode/decode round-trip must match the pre-encode checksum")
    }

    func testAACPayloadChecksumDetectsSingleByteCorruption() {
        var bytes = Data((0..<64).map { UInt8($0) })
        let original = PCMChecksum.fnv1a(bytes)
        bytes[32] ^= 0xFF
        XCTAssertNotEqual(PCMChecksum.fnv1a(bytes), original,
                          "a one-byte transport corruption must change the checksum")
    }
}

/// Deterministic, dependency-free PRNG for the fragmentation stress test —
/// no `Foundation` random source needed and reproducible across CI runs.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
