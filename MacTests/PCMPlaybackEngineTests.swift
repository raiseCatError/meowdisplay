import XCTest

// Pure, hardware-independent coverage of `PCMJitterBufferPolicy` — the only
// piece of `PCMPlaybackEngine` that's meaningfully unit-testable without a
// live `AVAudioEngine`/audio hardware. The engine's generation/reset,
// anchor, and actual scheduling behavior are exercised by physical device
// testing instead (see the PCM Engine productionization pass's final
// report) — forcing those into brittle AVFoundation-internals tests would
// not add real coverage.
final class PCMPlaybackEngineTests: XCTestCase {
    func testNotOverflowingBelowTheBound() {
        XCTAssertFalse(PCMJitterBufferPolicy.isOverflowing(pendingCount: 0))
        XCTAssertFalse(PCMJitterBufferPolicy.isOverflowing(pendingCount: PCMJitterBufferPolicy.maxPendingPacketCount - 1))
    }

    func testOverflowingAtAndAboveTheBound() {
        XCTAssertTrue(PCMJitterBufferPolicy.isOverflowing(pendingCount: PCMJitterBufferPolicy.maxPendingPacketCount))
        XCTAssertTrue(PCMJitterBufferPolicy.isOverflowing(pendingCount: PCMJitterBufferPolicy.maxPendingPacketCount + 1))
    }

    func testBoundIsGenerousButNotUnbounded() {
        // ~500ms of headroom at ~21.33ms/packet (AAC-LC 1024 frames @
        // 48kHz) — enough to absorb a real network stall, not "a giant
        // buffer to paper over problems" (explicitly ruled out by spec).
        let impliedMs = Double(PCMJitterBufferPolicy.maxPendingPacketCount) * (1024.0 / 48_000.0) * 1000
        XCTAssertGreaterThan(impliedMs, 300, "bound should tolerate more than a fleeting hiccup")
        XCTAssertLessThan(impliedMs, 1_500, "bound should not silently add a second of latency")
    }

    func testPrerollIsASmallBoundedLead() {
        // Mirrors the legacy renderer path's `audioPrerollSeconds` (64ms) —
        // both playback paths should give the pipeline the same cushion.
        XCTAssertEqual(PCMJitterBufferPolicy.prerollSeconds, 0.064, accuracy: 0.001)
    }

    // MARK: - Scheduling-mode regression (GOAL: "Debug PCM Engine" sounded
    // clean; productionizing it into per-packet `AVAudioTime` targeting
    // ("Precise Scheduled") reintroduced electrical/robotic noise).
    //
    // This is a synthetic, code-level exercise of the EXACT math
    // `PCMPlaybackEngine`'s `.preciseScheduled` mode uses — real
    // `AudioPacketTiming.capturedAtMs` (the same production function that
    // computes what actually goes on the wire) feeding
    // `PCMSchedulingContinuity.boundary` (the same production continuity
    // math the engine logs from) — run without any live `AVAudioEngine`/
    // physical device, to answer "what are the actual deltaFrames values"
    // directly from code.

    func testPreciseSchedulingProducesFrameGapsOrOverlapsAtEveryBoundary() {
        let sampleRate = 48_000.0
        let framesPerPacket = Int(AudioPacketTiming.framesPerPacket)   // 1024
        let originWallMs = 1_700_000_000_000.0

        var previousTargetSeconds: Double?
        var overlapCount = 0
        var gapCount = 0
        var exactZeroCount = 0
        var observedDeltas: [Int64] = []

        for packetIndex in 0..<200 {
            // The exact production formula for a wire capture timestamp
            // (`AudioCaptureEncoder.encode`'s `capturedAtMs`, mirrored on
            // the receiver as `receiverCaptureMs`) — an `Int64`
            // millisecond truncation of the true elapsed time.
            let capturedAtMs = AudioPacketTiming.capturedAtMs(
                originWallMs: originWallMs, encodedSampleCount: Int64(packetIndex * framesPerPacket), sampleRate: sampleRate)
            // `PCMPlaybackEngine.enqueue`'s `.preciseScheduled` formula:
            // targetSeconds = anchor.hostTime + (captureMs - anchor.captureMs) / 1000 (+ A/V offset, zero here).
            // Anchor pinned at host time 0 for this synthetic exercise —
            // only the RELATIVE math (which is what produces the
            // gap/overlap) matters, not an absolute host time.
            let targetSeconds = Double(capturedAtMs - Int64(originWallMs)) / 1000.0

            if let previousTargetSeconds {
                let boundary = PCMSchedulingContinuity.boundary(
                    previousTargetSeconds: previousTargetSeconds, previousFrameCount: framesPerPacket, previousSampleRate: sampleRate,
                    nextTargetSeconds: targetSeconds, sampleRate: sampleRate)
                observedDeltas.append(boundary.deltaFrames)
                if boundary.deltaFrames < 0 { overlapCount += 1 }
                else if boundary.deltaFrames > 0 { gapCount += 1 }
                else { exactZeroCount += 1 }
            }
            previousTargetSeconds = targetSeconds
        }

        // The decisive result: essentially EVERY boundary is either a
        // small overlap or a small gap — genuinely gapless (delta == 0)
        // boundaries are rare-to-none, because 1024/48000s (21.333...ms)
        // never evenly divides into whole milliseconds.
        XCTAssertGreaterThan(overlapCount + gapCount, 190,
                             "expected nearly every one of 199 boundaries to be a non-zero gap/overlap, got \(overlapCount) overlaps + \(gapCount) gaps + \(exactZeroCount) exact (deltas: \(observedDeltas.prefix(10))...)")
        // Magnitude check: truncating 21.333...ms to 21ms or 22ms means
        // each boundary's error is bounded to roughly ±0.333/±0.667ms,
        // i.e. a handful of frames at 48kHz — not large individually, but
        // present at EVERY one of ~48 buffer boundaries per second, which
        // is what produces a continuous, not intermittent, artifact.
        for delta in observedDeltas {
            XCTAssertLessThanOrEqual(abs(delta), 32, "unexpectedly large per-boundary error: \(delta) frames")
        }
    }

    func testSchedulingContinuityBoundaryMathIsExactForAKnownCase() {
        // A hand-computed case, independent of `AudioPacketTiming`, so the
        // continuity math itself (not the capture-timestamp truncation
        // behavior) is pinned down precisely.
        // Previous buffer: target 0.0s, 1024 frames @ 48kHz -> ends at
        // exactly 1024 samples. Next buffer targets exactly that same
        // instant -> perfectly contiguous, deltaFrames must be 0.
        let contiguous = PCMSchedulingContinuity.boundary(
            previousTargetSeconds: 0, previousFrameCount: 1024, previousSampleRate: 48_000,
            nextTargetSeconds: 1024.0 / 48_000.0, sampleRate: 48_000)
        XCTAssertEqual(contiguous.deltaFrames, 0)

        // Next buffer targets 21ms instead of the true 21.333...ms ->
        // overlaps the tail of the previous buffer.
        let overlapping = PCMSchedulingContinuity.boundary(
            previousTargetSeconds: 0, previousFrameCount: 1024, previousSampleRate: 48_000,
            nextTargetSeconds: 0.021, sampleRate: 48_000)
        XCTAssertLessThan(overlapping.deltaFrames, 0)

        // Next buffer targets 22ms instead -> a silent gap after the
        // previous buffer.
        let gapped = PCMSchedulingContinuity.boundary(
            previousTargetSeconds: 0, previousFrameCount: 1024, previousSampleRate: 48_000,
            nextTargetSeconds: 0.022, sampleRate: 48_000)
        XCTAssertGreaterThan(gapped.deltaFrames, 0)
    }
}
