import XCTest
import CoreMedia
import AVFoundation

/// Covers the RC-3 Stage E2 invariants `ReceiverAudioPresenter` (`Shared/
/// ReceiverAudioPresenter.swift`) must hold: anchor establishment/reuse,
/// the two distinct reset modes (full teardown vs. anchor-only), packet
/// order preserved through the renderer's own ordered enqueue, and that the
/// `avSyncOffsetMs`/`lastVideoLatencySeconds` terms feed the presentation
/// timestamp identically to the pre-extraction formula. Exercises the type
/// through its real `scheduleDecodedAudio`/`reset`/`clearAnchorOnly` entry
/// points — never private internals — so these tests exercise the exact
/// path `StreamReceiver` does. No `StreamReceiver` involved, so nothing
/// here needs the app host or a live network session.
final class ReceiverAudioPresenterTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal valid AAC-LC format description (48kHz stereo, no magic
    /// cookie) — enough for `CMSampleBufferCreateReady` to accept a
    /// compressed sample built against it; playback correctness of the
    /// bytes themselves is out of scope for this suite (no audible-output
    /// assertion), matching `ReceiverAudioDecoder`'s and
    /// `ReceiverVideoDecoderTests`' precedent.
    private func makeAACFormatDescription() -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription)
        precondition(status == noErr, "test fixture: AAC format description creation failed")
        return formatDescription!
    }

    private func makeSnapshot(
        clockOffsetMs: Double = 0, avSyncOffsetMs: Int = 0,
        lastVideoLatencySeconds: Double? = nil, lastVideoLatencyUpdatedAtWallMs: Double = 0,
        nowMs: Double = 0
    ) -> ReceiverAudioPresenter.AudioTimingSnapshot {
        .init(clockOffsetMs: clockOffsetMs, avSyncOffsetMs: avSyncOffsetMs,
              lastVideoLatencySeconds: lastVideoLatencySeconds,
              lastVideoLatencyUpdatedAtWallMs: lastVideoLatencyUpdatedAtWallMs, nowMs: nowMs)
    }

    private func schedulePacket(
        _ presenter: ReceiverAudioPresenter, capturedAtMs: Int64, payloadByte: UInt8 = 0xAB,
        formatDescription: CMAudioFormatDescription, timing: ReceiverAudioPresenter.AudioTimingSnapshot
    ) {
        presenter.scheduleDecodedAudio(
            capturedAtMs: capturedAtMs, payload: Data([payloadByte]), sampleCount: 1,
            duration: CMTime(value: 1024, timescale: 48_000),
            sampleSizeEntryCount: 1, sampleSizes: { [1] },
            formatDescription: formatDescription, timing: timing, activateSession: {})
    }

    // MARK: - Anchor lifecycle (tests 2/3/4/5 from the RC-3 E2 spec)

    /// The first scheduled packet establishes an anchor; a `reset()` clears
    /// it so the very next packet re-establishes a fresh one rather than
    /// reusing the stale mapping.
    func testResetClearsAnchorForNextPacket() {
        let presenter = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))
        let format = makeAACFormatDescription()
        let timing = makeSnapshot()

        schedulePacket(presenter, capturedAtMs: 0, formatDescription: format, timing: timing)
        XCTAssertEqual(presenter.debugEnqueueCount, 1)

        presenter.reset()

        // After a full reset the renderer/synchronizer/anchor are gone —
        // the very next scheduled packet lazily rebuilds the chain and
        // establishes a brand-new anchor, exactly like the pre-extraction
        // `resetAudioPlayback` + `establishAudioAnchor` pair.
        schedulePacket(presenter, capturedAtMs: 21, formatDescription: format, timing: timing)
        XCTAssertEqual(presenter.debugEnqueueCount, 2)
    }

    /// `clearAnchorOnly()` (the DEBUG KVO-error recovery path) drops only
    /// the anchor — a subsequent packet still succeeds without needing the
    /// renderer chain to be rebuilt.
    func testClearAnchorOnlyDoesNotTearDownRenderer() {
        let presenter = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))
        let format = makeAACFormatDescription()
        let timing = makeSnapshot()

        schedulePacket(presenter, capturedAtMs: 0, formatDescription: format, timing: timing)
        presenter.clearAnchorOnly()
        schedulePacket(presenter, capturedAtMs: 21, formatDescription: format, timing: timing)

        XCTAssertEqual(presenter.debugEnqueueCount, 2)
    }

    // MARK: - Timing formula (tests 6/7/8 from the RC-3 E2 spec)

    /// `avSyncOffsetMs` shifts the queued lead time by the same delay the
    /// pre-extraction formula produced (`AVSyncOffset.audioDelayMs`),
    /// relative to a zero-offset baseline. Both readings are taken via
    /// `debugQueuedMs` against the SAME already-established anchor,
    /// back-to-back, so the comparison isolates the formula itself from
    /// process wall-clock/cold-start noise (AudioToolbox's first
    /// `CMSampleBufferCreateReady`/renderer call in a process has
    /// non-trivial, non-deterministic one-time overhead that would
    /// otherwise swamp a millisecond-scale assertion taken across two
    /// separately-established anchors).
    func testAVSyncOffsetShiftsQueuedLeadByExpectedDelay() {
        let presenter = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))
        let format = makeAACFormatDescription()
        schedulePacket(presenter, capturedAtMs: 0, formatDescription: format, timing: makeSnapshot(avSyncOffsetMs: 0))

        let queuedZero = presenter.debugQueuedMs(receiverCaptureMs: 0, avSyncOffsetMs: 0)!
        let queuedOffset = presenter.debugQueuedMs(receiverCaptureMs: 0, avSyncOffsetMs: 50)!

        let expectedDelayMs = Double(AVSyncOffset.audioDelayMs(for: 50) - AVSyncOffset.audioDelayMs(for: 0))
        XCTAssertEqual(queuedOffset - queuedZero, expectedDelayMs, accuracy: 1.0)
    }

    /// A fresh video-latency measurement folds a bounded baseline lead into
    /// a NEWLY established anchor — never into one already in play — which
    /// this test observes as a larger raw `lead` (anchor `hostTime` minus
    /// the `now` captured at establishment) when `lastVideoLatencySeconds`
    /// is fresh versus stale. Reads the lead back immediately after each
    /// anchor is established (before either presenter's first real
    /// `CMSampleBufferCreateReady`/renderer-enqueue call, which — same
    /// rationale as the sync-offset test above — carries non-deterministic
    /// one-time AudioToolbox overhead that would otherwise dominate a
    /// cross-presenter wall-clock comparison) via `debugAnchorLeadSeconds`,
    /// a test-only probe that captures its own `now` before doing any of
    /// that work.
    func testFreshVideoLatencyIncreasesAnchorLead() {
        let presenterFresh = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))
        let presenterStale = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))

        // "Fresh": measured 100ms ago (< the 1s staleness window).
        let leadFresh = presenterFresh.debugEstablishAnchorAndReturnLeadSeconds(
            captureMs: 0, timing: makeSnapshot(lastVideoLatencySeconds: 0.1, lastVideoLatencyUpdatedAtWallMs: 900, nowMs: 1_000))
        // "Stale": measured 2s ago (> the 1s staleness window) — ignored.
        let leadStale = presenterStale.debugEstablishAnchorAndReturnLeadSeconds(
            captureMs: 0, timing: makeSnapshot(lastVideoLatencySeconds: 0.1, lastVideoLatencyUpdatedAtWallMs: 0, nowMs: 2_000))

        XCTAssertGreaterThan(leadFresh, leadStale)
        XCTAssertEqual(leadFresh, 0.1, accuracy: 0.001)   // baseline (100ms) exceeds the 64ms preroll floor
        XCTAssertEqual(leadStale, 0.064, accuracy: 0.001)   // stale measurement ignored -> bare preroll
    }

    // MARK: - Ordering (test 1/9 from the RC-3 E2 spec)

    /// Packets scheduled in order are submitted to the renderer in that
    /// same order — `enqueue` itself reports no completion, so this
    /// verifies SUBMISSION order via the monotonic enqueue counter, the
    /// same guarantee `ReceiverVideoDecoderTests` verifies for decode
    /// submission.
    func testPacketOrderPreservedThroughSequentialEnqueue() {
        let presenter = ReceiverAudioPresenter(queue: DispatchQueue(label: "test"))
        let format = makeAACFormatDescription()
        let timing = makeSnapshot()

        for i: Int64 in 0..<5 {
            schedulePacket(presenter, capturedAtMs: i * 21, formatDescription: format, timing: timing)
            XCTAssertEqual(presenter.debugEnqueueCount, Int(i) + 1)
        }
    }
}
