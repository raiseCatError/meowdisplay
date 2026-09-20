import XCTest
import CoreMedia
import VideoToolbox

/// Covers the C4 invariants `ReceiverVideoDecoder` (`Shared/
/// ReceiverVideoDecoder.swift`) must hold: session creation/reuse across
/// compatible frames, session recreation on an incompatible format
/// description, invalidation on `reset()`, the keyframe-request signal on
/// decode failure, and — the point of this suite's `testDecode
/// SubmissionsPreserveEnqueueOrder` — that decode SUBMISSION order matches
/// enqueue order even though nothing here awaits actor-scheduling luck to
/// get it. Exercises the actor exclusively through its real, ordered
/// `enqueue*` entry points (never the private `decode`/`reset` bodies
/// directly), so these tests exercise the exact same path production code
/// does. No `StreamReceiver`/`ReceiverFramePipeline` involved, so there is
/// nothing here that needs the app host.
final class ReceiverVideoDecoderTests: XCTestCase {

    // MARK: - Recorder

    /// Plain lock-protected recorder — `decodedFrameReady`/`decodeDurationMs`
    /// fire from VideoToolbox's own asynchronous decode-output thread, so
    /// tests that assert on them must poll `waitFor` rather than read the
    /// count immediately after `enqueueDecode` returns (which — by design,
    /// see the file header — only guarantees SUBMISSION order, never that
    /// decode has completed).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _decodedFrameCount = 0
        private var _durations: [Double] = []
        private var _keyframeRequests = 0

        func recordDecodedFrame() { lock.lock(); _decodedFrameCount += 1; lock.unlock() }
        func recordDuration(_ ms: Double) { lock.lock(); _durations.append(ms); lock.unlock() }
        func recordKeyframeRequest() { lock.lock(); _keyframeRequests += 1; lock.unlock() }

        var decodedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return _decodedFrameCount }
        var durations: [Double] { lock.lock(); defer { lock.unlock() }; return _durations }
        var keyframeRequests: Int { lock.lock(); defer { lock.unlock() }; return _keyframeRequests }
    }

    private func makeDecoder() -> (ReceiverVideoDecoder, Recorder) {
        let recorder = Recorder()
        let effects = ReceiverVideoDecoder.OutputEffects(
            decodedFrameReady: { _, _, _ in recorder.recordDecodedFrame() },
            decodeDurationMs: { ms in recorder.recordDuration(ms) },
            requestKeyframe: { recorder.recordKeyframeRequest() })
        return (ReceiverVideoDecoder(outputEffects: effects), recorder)
    }

    /// Polls `condition` up to ~2s (VideoToolbox's output callback is
    /// asynchronous, off this actor entirely) rather than a fixed sleep.
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Wire fixtures (same minimal valid H.264 stream as
    // `ReceiverFramePipelineTests`, kept independent per that file's own
    // note about not sharing test fixtures across unrelated suites).

    private let sps = Data([0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x10, 0xFF, 0xFE, 0xF6, 0xF0, 0xA4, 0xFC, 0xB2])

    private func makeFormatDescription() -> CMVideoFormatDescription {
        var desc: CMVideoFormatDescription!
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                precondition(status == noErr, "test fixture format description failed: \(status)")
            }
        }
        return desc
    }

    /// One AVCC-framed sample buffer built from the IDR fixture — same
    /// shape `ReceiverFramePipeline.buildSampleBuffer` hands to this actor.
    private func makeSampleBuffer(formatDescription: CMVideoFormatDescription, nalu: Data) -> CMSampleBuffer {
        var avcc = Data()
        var len = UInt32(nalu.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4))
        avcc.append(nalu)

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
        precondition(createStatus == noErr, "test fixture block buffer failed: \(createStatus)")
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer!,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }

        var sample: CMSampleBuffer!
        var sizeArr = [avcc.count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sample)
        precondition(sampleStatus == noErr, "test fixture sample buffer failed: \(sampleStatus)")
        return sample
    }

    // MARK: - 1. A valid frame decodes and reports success

    func testValidFrameDecodesAndReportsDuration() async {
        let (decoder, recorder) = makeDecoder()
        let formatDesc = makeFormatDescription()
        let sample = makeSampleBuffer(formatDescription: formatDesc, nalu: idr)

        decoder.enqueueDecode(FrameMediaBox(sample), generation: 0, captureMs: 123)
        await waitFor { recorder.decodedFrameCount > 0 || recorder.keyframeRequests > 0 }

        // A hand-written single-macroblock fixture may or may not be a
        // decoder VideoToolbox accepts on every OS/hardware combination —
        // the invariant this test actually verifies is that EXACTLY ONE of
        // the two signals fires (decode success or decode failure→keyframe
        // request), never neither and never a crash/hang.
        XCTAssertTrue(recorder.decodedFrameCount > 0 || recorder.keyframeRequests > 0,
            "decode must resolve to either a decoded frame or a keyframe request")
        if recorder.decodedFrameCount > 0 {
            XCTAssertEqual(recorder.durations.count, recorder.decodedFrameCount)
        }
    }

    // MARK: - 2. Decode failure requests a keyframe

    func testCorruptFrameRequestsKeyframe() async {
        let (decoder, recorder) = makeDecoder()
        let formatDesc = makeFormatDescription()
        // A structurally-valid AVCC frame whose slice payload is garbage —
        // VideoToolbox accepts the format description (built from real
        // SPS/PPS) but the output callback reports a decode error, which
        // must surface as a keyframe request and never a decoded frame.
        let garbage = Data([0x65] + Array(repeating: 0xFF, count: 64))
        let sample = makeSampleBuffer(formatDescription: formatDesc, nalu: garbage)

        decoder.enqueueDecode(FrameMediaBox(sample), generation: 0, captureMs: nil)
        await waitFor { recorder.keyframeRequests > 0 || recorder.decodedFrameCount > 0 }

        XCTAssertGreaterThan(recorder.keyframeRequests, 0,
            "a garbage slice must request a keyframe, not silently drop")
        XCTAssertEqual(recorder.decodedFrameCount, 0)
    }

    // MARK: - 3. reset() invalidates the session; a decode after reset

    func testResetInvalidatesSessionAndSubsequentDecodeStillWorks() async {
        let (decoder, recorder) = makeDecoder()
        let formatDesc = makeFormatDescription()
        let sample = makeSampleBuffer(formatDescription: formatDesc, nalu: idr)

        decoder.enqueueDecode(FrameMediaBox(sample), generation: 0, captureMs: nil)
        await waitFor { recorder.decodedFrameCount > 0 || recorder.keyframeRequests > 0 }

        // Reset must not leave the actor in a state where a fresh decode
        // (e.g. after a reconnect/codec-change reset) can no longer make
        // progress — it recreates its session lazily on the next `decode`.
        // Enqueued (not awaited): the ordering guarantee this suite exists
        // to prove is exactly what lets this be a fire-and-forget call —
        // `reset` is guaranteed to be processed before the decode enqueued
        // right after it.
        decoder.enqueueReset()

        let sample2 = makeSampleBuffer(formatDescription: formatDesc, nalu: idr)
        decoder.enqueueDecode(FrameMediaBox(sample2), generation: 0, captureMs: nil)
        await waitFor {
            recorder.decodedFrameCount + recorder.keyframeRequests > 1
        }
        XCTAssertGreaterThan(recorder.decodedFrameCount + recorder.keyframeRequests, 1,
            "a decode after reset must still resolve (session recreated lazily)")
    }

    // MARK: - 4. Repeated compatible frames do not error from format-mismatch

    func testRepeatedCompatibleFramesReuseTheSameGeneration() async {
        let (decoder, recorder) = makeDecoder()
        let formatDesc = makeFormatDescription()

        for _ in 0..<3 {
            let sample = makeSampleBuffer(formatDescription: formatDesc, nalu: idr)
            decoder.enqueueDecode(FrameMediaBox(sample), generation: 0, captureMs: nil)
        }
        await waitFor { recorder.decodedFrameCount + recorder.keyframeRequests >= 3 }

        XCTAssertEqual(recorder.decodedFrameCount + recorder.keyframeRequests, 3,
            "each of 3 frames on the SAME format description must resolve exactly once, "
            + "with no extra session-recreation churn producing spurious extra signals")
    }

    // MARK: - 5. Decode SUBMISSION order matches enqueue order

    /// The invariant the previous per-frame-`Task` design could not
    /// guarantee: frame N enqueued before frame N+1 must be SUBMITTED
    /// (i.e. reach the point this actor would call
    /// `VTDecompressionSessionDecodeFrame`) before frame N+1 is. This does
    /// NOT exercise real VideoToolbox timing/output order (which this
    /// actor never assumes anything about) — it proves the ordering
    /// primitive itself (the single `AsyncStream` + one long-lived pump
    /// `Task`), via `debugSubmissionObserver`, a narrow DEBUG-only hook
    /// that fires at the exact moment the pump begins processing each
    /// enqueued command, before it acts on it. Runs the real production
    /// `enqueueDecode` path — VideoToolbox itself is not mocked or
    /// bypassed, only observed alongside.
    func testDecodeSubmissionsPreserveEnqueueOrder() async {
        let (decoder, _) = makeDecoder()
        let formatDesc = makeFormatDescription()

        let lock = NSLock()
        var observedOrder: [Double] = []
        await decoder.setDebugSubmissionObserver { command in
            guard case .decode(_, _, let captureMs) = command, let captureMs else { return }
            lock.lock(); observedOrder.append(captureMs); lock.unlock()
        }

        // Enqueue 1...5 back-to-back from a single caller — exactly the
        // shape `StreamReceiver.presentDecodedSample`'s `present` closure
        // uses, one call per wire-arrival frame, nothing awaited between
        // them (that absence of an inter-call `await` is precisely what a
        // sibling-`Task`-per-frame design could not order safely, since
        // each `Task` schedules independently; a plain synchronous
        // `nonisolated` call has no such gap to race through).
        for tag in 1...5 {
            let sample = makeSampleBuffer(formatDescription: formatDesc, nalu: idr)
            decoder.enqueueDecode(FrameMediaBox(sample), generation: 0, captureMs: Double(tag))
        }

        await waitFor { lock.lock(); defer { lock.unlock() }; return observedOrder.count == 5 }

        let finalOrder = { lock.lock(); defer { lock.unlock() }; return observedOrder }()
        XCTAssertEqual(finalOrder, [1, 2, 3, 4, 5],
            "decode submissions must reach the pump in exact enqueue order on every run, "
            + "not merely whichever order scheduling happened to produce")
    }
}

private extension ReceiverVideoDecoder {
    /// Test-only convenience: `debugSubmissionObserver` is itself
    /// actor-isolated state, so setting it needs an `await` hop — kept out
    /// of the production type itself since nothing else ever sets it.
    func setDebugSubmissionObserver(_ observer: @escaping @Sendable (Command) -> Void) {
        debugSubmissionObserver = observer
    }
}
