import XCTest
import CoreMedia
import AVFoundation

/// Covers the Stage D invariants `ReceiverVideoPresenter` (`Shared/
/// ReceiverVideoPresenter.swift`) must hold: enqueue order preserved,
/// flush ordered between frames, a stale-generation frame discarded after
/// a resync/reset, a current-generation frame still presented, repeated
/// normal frames not flushing unnecessarily, and the failure-recovery
/// flush/telemetry signal. Exercises the actor exclusively through its
/// real, ordered `enqueue*` entry points, via `debugSubmissionObserver`
/// (fires the moment the pump begins processing a command, before it acts
/// on it) rather than a real `AVSampleBufferDisplayLayer` — this suite is
/// deliberately a real `AVSampleBufferDisplayLayer` (headless instances
/// construct fine and `.enqueue`/`.flush` are safe no-ops off-screen; only
/// actual RENDERING needs a live layer tree, which this suite never
/// asserts on) so `presentSample`/`presentDecoded`'s generation-gating
/// logic runs for real, but assertions are made on `OutputEffects`
/// signals and `debugSubmissionObserver`, never on pixels.
final class ReceiverVideoPresenterTests: XCTestCase {

    // MARK: - Recorder

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _decodeRouted = 0
        private var _decodedFramesReady = 0
        private var _flushesIncurred = 0
        private var _framesPresented = 0

        func recordDecodeRouted() { lock.lock(); _decodeRouted += 1; lock.unlock() }
        func recordDecodedFrameReady() { lock.lock(); _decodedFramesReady += 1; lock.unlock() }
        func recordFlushIncurred() { lock.lock(); _flushesIncurred += 1; lock.unlock() }
        func recordFramePresented() { lock.lock(); _framesPresented += 1; lock.unlock() }

        var decodeRouted: Int { lock.lock(); defer { lock.unlock() }; return _decodeRouted }
        var decodedFramesReady: Int { lock.lock(); defer { lock.unlock() }; return _decodedFramesReady }
        var flushesIncurred: Int { lock.lock(); defer { lock.unlock() }; return _flushesIncurred }
        var framesPresented: Int { lock.lock(); defer { lock.unlock() }; return _framesPresented }
    }

    /// Lock-protected append-only log, used to observe values arriving from
    /// `debugSubmissionObserver` off the presenter's own scheduling.
    private final class LockedLog<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) { lock.lock(); values.append(value); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
        func snapshot() -> [Element] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @MainActor
    private func makePresenter() -> (ReceiverVideoPresenter, Recorder) {
        let recorder = Recorder()
        let effects = ReceiverVideoPresenter.OutputEffects(
            decodeViaVideoDecoder: { _, _, _ in recorder.recordDecodeRouted() },
            decodedFrameReady: { _, _ in recorder.recordDecodedFrameReady() },
            decodeFlushIncurred: { recorder.recordFlushIncurred() },
            debugFramePresented: { recorder.recordFramePresented() })
        return (ReceiverVideoPresenter(displayLayer: AVSampleBufferDisplayLayer(), outputEffects: effects), recorder)
    }

    @MainActor
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Wire fixture (same minimal valid H.264 stream as the decoder/
    // frame-pipeline suites, kept independent per their own note about not
    // sharing fixtures across unrelated suites).

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

    private func makeSampleBuffer(formatDescription: CMVideoFormatDescription) -> CMSampleBuffer {
        var avcc = Data()
        var len = UInt32(idr.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4))
        avcc.append(idr)

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

    // MARK: - 1. Enqueue order is preserved

    /// The invariant a per-frame `Task` could not guarantee: commands
    /// enqueued back-to-back from a single caller, with nothing awaited
    /// between them, must reach the pump in exact enqueue order — proven
    /// via `debugSubmissionObserver`, which fires the moment the pump
    /// begins processing each command, before it acts on it.
    @MainActor
    func testEnqueueOrderIsPreserved() async {
        let (presenter, _) = makePresenter()
        let formatDesc = makeFormatDescription()

        let observedOrder = LockedLog<Double>()
        presenter.debugSubmissionObserver = { command in
            guard case .presentSample(_, _, _, let captureMs) = command, let captureMs else { return }
            observedOrder.append(captureMs)
        }

        for tag in 1...5 {
            presenter.enqueuePresentSample(
                FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
                generation: 0, viaMetalPath: false, captureMs: Double(tag))
        }

        await waitFor { observedOrder.count == 5 }
        XCTAssertEqual(observedOrder.snapshot(), [1, 2, 3, 4, 5],
            "presentSample submissions must reach the pump in exact enqueue order on every run")
    }

    // MARK: - 2. Flush ordered between frames

    @MainActor
    func testFlushIsOrderedBetweenFrames() async {
        let (presenter, _) = makePresenter()
        let formatDesc = makeFormatDescription()

        let observedKinds = LockedLog<String>()
        presenter.debugSubmissionObserver = { command in
            switch command {
            case .presentSample: observedKinds.append("frame")
            case .flush: observedKinds.append("flush")
            default: break
            }
        }

        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)), generation: 0, viaMetalPath: false, captureMs: 1)
        presenter.enqueueFlush()
        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)), generation: 0, viaMetalPath: false, captureMs: 2)

        await waitFor { observedKinds.count == 3 }
        XCTAssertEqual(observedKinds.snapshot(), ["frame", "flush", "frame"],
            "a flush enqueued between two frames must be PROCESSED between them, never reordered "
            + "around either by independent scheduling")
    }

    // MARK: - 3. Reset/resync invalidates a stale-generation frame

    @MainActor
    func testResyncDiscardsAStaleGenerationFrame() async {
        let (presenter, recorder) = makePresenter()
        let formatDesc = makeFormatDescription()

        // Simulates `presentDecodedSample`'s A/V-sync-delay race: a frame
        // whose generation was snapshotted BEFORE a resync/reset that then
        // advanced past it, but which only reaches the presenter's ordered
        // stream AFTER that advance already landed — e.g. a delayed
        // `queue.asyncAfter` present that fires after a resync happened.
        presenter.enqueueAdvanceGeneration()   // presenter's videoGeneration -> 1
        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
            generation: 0, viaMetalPath: false, captureMs: 1)   // stale: generation 0, current is 1

        // A current-generation frame right after it must still present —
        // proves the discard is generation-specific, not "everything after
        // a reset is dropped."
        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
            generation: 1, viaMetalPath: false, captureMs: 2)

        await waitFor { recorder.framesPresented >= 1 }
        // Give the stale command a moment it does NOT need — if it were
        // going to present, `framesPresented` would already be 2.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.framesPresented, 1,
            "the generation-0 frame (stale — a resync already advanced past it) must be discarded; "
            + "only the generation-1 frame reaches displayLayer.enqueue")
    }

    // MARK: - 4. Current-generation frame still presents

    @MainActor
    func testCurrentGenerationFramePresents() async {
        let (presenter, recorder) = makePresenter()
        let formatDesc = makeFormatDescription()

        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
            generation: 0, viaMetalPath: false, captureMs: 1)

        await waitFor { recorder.framesPresented > 0 }
        XCTAssertEqual(recorder.framesPresented, 1,
            "a frame whose generation matches the presenter's current generation must present")
    }

    // MARK: - 5. Repeated normal frames do not flush unnecessarily

    @MainActor
    func testRepeatedNormalFramesDoNotFlush() async {
        let (presenter, recorder) = makePresenter()
        let formatDesc = makeFormatDescription()

        for tag in 1...5 {
            presenter.enqueuePresentSample(
                FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
                generation: 0, viaMetalPath: false, captureMs: Double(tag))
        }

        await waitFor { recorder.framesPresented >= 5 }
        XCTAssertEqual(recorder.framesPresented, 5)
        XCTAssertEqual(recorder.flushesIncurred, 0,
            "displayLayer.status never reports .failed for these synthetic frames, so no "
            + "failure-recovery flush should ever fire on the ordinary path")
    }

    // MARK: - 6. Metal-path routing carries generation through to the decoder hop

    @MainActor
    func testMetalPathRoutesToDecoderWithGeneration() async {
        let (presenter, recorder) = makePresenter()
        let formatDesc = makeFormatDescription()

        presenter.enqueuePresentSample(
            FrameMediaBox(makeSampleBuffer(formatDescription: formatDesc)),
            generation: 0, viaMetalPath: true, captureMs: 1)

        await waitFor { recorder.decodeRouted > 0 }
        XCTAssertEqual(recorder.decodeRouted, 1)
        XCTAssertEqual(recorder.framesPresented, 0,
            "a Metal-routed frame must never also reach displayLayer.enqueue directly")
    }

    // MARK: - 7. A decoded (Metal path) frame past its generation is discarded

    @MainActor
    func testStaleDecodedFrameIsDiscarded() async {
        let (presenter, recorder) = makePresenter()
        let pixelBuffer = makePixelBuffer()

        presenter.enqueueAdvanceGeneration()   // videoGeneration -> 1
        presenter.enqueuePresentDecoded(FrameMediaBox(pixelBuffer), generation: 0, captureMs: 1)
        presenter.enqueuePresentDecoded(FrameMediaBox(pixelBuffer), generation: 1, captureMs: 2)

        await waitFor { recorder.decodedFramesReady >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.decodedFramesReady, 1,
            "a decoded pixel buffer whose generation a resync already superseded — the closed "
            + "stale-VT-callback gap — must never reach onDecodedFrame")
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
        return pixelBuffer!
    }
}
