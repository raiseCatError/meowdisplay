import AVFoundation
import CoreMedia

// PCMPlaybackEngine — the production audio playback path (PROTOCOL.md
// section 5A milestone note): decoded AAC→PCM played through
// `AVAudioEngine`/`AVAudioPlayerNode`, replacing
// `AVSampleBufferAudioRenderer` as the default after a multi-pass forensic
// investigation (see `StreamReceiver`'s audio section) found the legacy
// renderer path was the source of an intermittent playback glitch that
// survived every other layer.
//
// FORENSIC NOTE — scheduling-mode regression: the FIRST working version of
// this engine scheduled every buffer with `scheduleBuffer(_:completionHandler:)`
// (no explicit `at:` time), which chains buffers back-to-back on the
// player node's own internal sample timeline and sounded clean in a
// physical A/B. Productionizing it into a "real timing model" replaced
// that with an independently-computed absolute `AVAudioTime` target PER
// PACKET, derived from that packet's own (millisecond-quantized)
// `capturedAtMs` — and reintroduced the electrical/robotic noise. The math
// explains why: `AudioPacketFrame.capturedAtMs` is a wire `Int64`
// millisecond value, so consecutive packets' capture deltas truncate to
// either 21ms or 22ms (never the true 21.333...ms an AAC-LC packet at
// 48kHz actually spans — see `AudioPacketTiming`/`AudioMediaFrameTests`).
// Targeting each buffer independently from that truncated delta means
// EVERY buffer boundary lands about -0.333ms (~-16 frames, an overlap) or
// +0.667ms (~+32 frames, a gap) away from where the previous buffer
// actually finished — never 0 — at 48 buffer boundaries per second. That
// is `PCMSchedulingMode.preciseScheduled`, kept below as a DEBUG-only A/B
// reference; `PCMSchedulingContinuity` and
// `PCMPlaybackEngineTests.testPreciseSchedulingProducesFrameGapsOrOverlapsAtEveryBoundary`
// derive and assert those exact numbers without needing a device.
//
// `PCMSchedulingMode.continuous` (the new default) fixes this by using the
// capture-timestamp anchor ONLY to place the FIRST buffer of a generation
// (and to detect/react to a major discontinuity or a live A/V-offset
// change); every subsequent buffer is handed to `scheduleBuffer` with no
// explicit time at all, so the player node itself chains them contiguously
// — exactly reproducing the original clean-sounding behavior while still
// keeping the anchor-based architecture (generation isolation, Resync,
// interruption/route recovery) from the last pass.
//
// The wire codec is unchanged: AAC is still the only thing that ever
// crosses the network (PROTOCOL.md 5A) — this is purely a receiver-side
// playback architecture change. `StreamReceiver.decodeReceivedAAC` (the
// same decoder DEBUG diagnostics already validated) feeds this engine.
//
// The legacy `AVSampleBufferAudioRenderer` path remains fully intact and
// selectable in DEBUG builds (Settings → Developer / Audio Diagnostics →
// Playback Path → "Legacy SampleBuffer Renderer") as a reference/fallback,
// never deleted.

/// Pure, testable jitter-buffer policy — separated from any AVFoundation
/// type so it can be tested without live audio hardware.
enum PCMJitterBufferPolicy {
    /// Lead time folded into a fresh generation's playback anchor —
    /// mirrors the legacy renderer path's `audioPrerollSeconds`
    /// (`StreamReceiver.swift`), so both playback paths give the pipeline
    /// the same cushion against ordinary arrival jitter before the first
    /// sample is due to play.
    static let prerollSeconds: Double = 0.064

    /// Hard cap on packets scheduled-but-not-yet-played before the engine
    /// starts dropping the newest arrival rather than let
    /// `AVAudioPlayerNode`'s internal queue grow unbounded — roughly 500ms
    /// of headroom at ~21.33ms/packet (AAC-LC 1024 frames @ 48kHz).
    /// Deliberately NOT "a giant buffer to paper over problems" — this
    /// bounds worst-case added latency, it does not chase it away.
    static let maxPendingPacketCount = 24

    /// True once accepting one more packet would exceed the bound — the
    /// caller must drop rather than enqueue.
    static func isOverflowing(pendingCount: Int) -> Bool {
        pendingCount >= maxPendingPacketCount
    }

    /// A capture-timeline gap this large from the previous packet means a
    /// real discontinuity (packet loss, reordering, a stall) rather than
    /// ordinary ~21.33ms cadence or arrival jitter — worth a controlled
    /// re-anchor rather than silently continuing to chain off a now-stale
    /// anchor. Mirrors `AudioCaptureEncoder`'s sender-side re-anchor
    /// threshold (50ms), loosened slightly for the receiver's coarser
    /// millisecond-quantized `capturedAtMs`.
    static let majorDiscontinuityMs: Double = 100
}

/// Which per-buffer scheduling strategy `PCMPlaybackEngine` uses — DEBUG
/// selectable (Settings → Developer / Audio Diagnostics → PCM Scheduling);
/// a Release build always uses `.continuous`. See this file's top-of-file
/// forensic note for why `.preciseScheduled` regressed audio quality.
enum PCMSchedulingMode: Equatable {
    /// The default and production behavior: only the first buffer of a
    /// generation gets an explicit host-time target (from the capture-time
    /// anchor); every buffer after that chains contiguously on the player
    /// node's own timeline.
    case continuous
    /// DEBUG-only reference/comparison mode: every buffer independently
    /// targets an absolute host time derived from its own capture
    /// timestamp. Known to reintroduce electrical/robotic noise — kept
    /// only so a physical A/B can directly confirm the diagnosis.
    case preciseScheduled

    #if DEBUG
    static var current: PCMSchedulingMode {
        UserDefaults.standard.string(forKey: "audioPCMSchedulingMode") == "preciseScheduled" ? .preciseScheduled : .continuous
    }
    #else
    static var current: PCMSchedulingMode { .continuous }
    #endif
}

/// Pure, testable continuity math for `.preciseScheduled`'s diagnostic
/// logging (GOAL requirement 3) — separated from `PCMPlaybackEngine` so it
/// can be exercised in a unit test with synthetic capture timestamps,
/// without any live `AVAudioEngine`/audio hardware. `deltaFrames == 0`
/// means genuinely gapless; negative means the next buffer's target
/// overlaps the previous one's still-playing audio; positive means a
/// silent gap between them.
enum PCMSchedulingContinuity {
    struct Boundary {
        var previousEndSampleTime: Int64
        var nextStartSampleTime: Int64
        var deltaFrames: Int64
    }

    /// `previousTargetSeconds`/`previousFrameCount` describe the prior
    /// buffer's own independently-computed target and length;
    /// `nextTargetSeconds` is the next buffer's independently-computed
    /// target. All in the same host-time-seconds domain
    /// `PCMPlaybackEngine` schedules from.
    static func boundary(
        previousTargetSeconds: Double, previousFrameCount: Int, previousSampleRate: Double,
        nextTargetSeconds: Double, sampleRate: Double
    ) -> Boundary {
        let previousEndSeconds = previousTargetSeconds + Double(previousFrameCount) / previousSampleRate
        let previousEndSampleTime = Int64((previousEndSeconds * sampleRate).rounded())
        let nextStartSampleTime = Int64((nextTargetSeconds * sampleRate).rounded())
        return Boundary(
            previousEndSampleTime: previousEndSampleTime,
            nextStartSampleTime: nextStartSampleTime,
            deltaFrames: nextStartSampleTime - previousEndSampleTime)
    }
}

/// Confines all mutable state to its own serial queue — the same
/// single-queue-confinement pattern `MacSender`/`StreamReceiver` already
/// use elsewhere in this codebase, not an actor (kept consistent with the
/// project's existing concurrency style; see repo guardrails against
/// actor-converting the sender/receiver architecture).
final class PCMPlaybackEngine {
    private let queue: DispatchQueue
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// Bumped by `reset()` (and the internal `reanchor()` a major
    /// discontinuity or a live A/V-offset change triggers) — every closure
    /// this engine hands to AVFoundation (completion handlers) captures the
    /// generation it was scheduled under and checks it again before
    /// touching shared state, so work from a superseded generation can
    /// never affect a newer one. Mirrors `MacSender.audioGeneration`/
    /// `StreamReceiver.videoGeneration`'s existing stale-work guard.
    private(set) var generation: UInt64 = 0

    /// One stable capture-timeline → host-time mapping per generation,
    /// established from the FIRST packet and never recomputed from later
    /// packets for `.continuous` scheduling — same rationale as
    /// `StreamReceiver`'s `audioAnchor` doc comment: recomputing per-packet
    /// inherits arrival jitter instead of smoothing over it. `.preciseScheduled`
    /// (DEBUG-only) still uses it as the ORIGIN every packet is
    /// independently re-targeted from — that per-packet re-targeting is
    /// exactly the regression this file's forensic note documents.
    private struct Anchor { var captureMs: Double; var hostTime: CFTimeInterval }
    private var anchor: Anchor?
    private var lastCaptureMs: Double?
    private var lastAppliedAVSyncOffsetMs: Int?

    private var pendingCount = 0
    private(set) var starvationCount = 0
    private(set) var overflowDropCount = 0
    private(set) var scheduledCount = 0
    private(set) var reanchorCount = 0

    #if DEBUG
    private var loggedOutputFormat = false
    private var lastPreciseTargetSeconds: Double?
    private var lastPreciseFrameCount: Int?
    private var lastPreciseSampleRate: Double?
    #endif

    init(queueLabel: String = "pcm-playback-engine") {
        queue = DispatchQueue(label: queueLabel)
    }

    /// Milliseconds of audio currently scheduled-but-unplayed — the
    /// engine's counterpart of the legacy path's `queuedMs` diagnostic.
    /// Approximate (packet count × nominal packet duration, not sample-
    /// accurate); good enough for a log line, not for scheduling decisions.
    var queuedMs: Double {
        queue.sync { Double(pendingCount) * (Double(AudioPacketTiming.framesPerPacket) / 48_000) * 1000 }
    }

    /// Enqueues one already-decoded PCM packet. `captureMs` is the
    /// receiver-clock-equivalent capture timestamp — the SAME coordinate
    /// space `StreamReceiver.scheduleDecodedAudio` uses for the legacy
    /// path — and `avSyncOffsetMs` is the live A/V Sync value, applied via
    /// the same `AVSyncOffset.audioDelayMs` the legacy path uses, so
    /// switching playback paths never changes what the slider means.
    func enqueue(_ buffer: AVAudioPCMBuffer, captureMs: Double, avSyncOffsetMs: Int) {
        queue.async { [self] in
            if PCMJitterBufferPolicy.isOverflowing(pendingCount: pendingCount) {
                overflowDropCount += 1
                #if DEBUG
                Log.info("audioTrace: ⚠️ PCM engine queue overflow — dropped newest packet (count=\(overflowDropCount), pending=\(pendingCount))")
                #endif
                return
            }

            ensureEngine(format: buffer.format)
            guard let player else { return }

            // A real discontinuity (packet loss/reordering — never
            // ordinary ~21.33ms cadence or ordinary arrival jitter, which
            // this coarse check tolerates generously) invalidates the
            // current anchor's meaning: keeping the old anchor and just
            // continuing to chain buffers would play a real gap in the
            // capture timeline as if it were contiguous. A controlled
            // re-anchor is the "meaningful threshold" correction GOAL
            // requirement 5 asks for, not a per-packet micro-correction.
            if let lastCaptureMs, anchor != nil {
                let deltaMs = captureMs - lastCaptureMs
                if deltaMs < 0 || deltaMs > PCMJitterBufferPolicy.majorDiscontinuityMs {
                    #if DEBUG
                    Log.info("audioTrace: ⚠️ PCM engine capture-time discontinuity deltaMs=\(Int(deltaMs)) — re-anchoring")
                    #endif
                    reanchorLocked()
                }
            }
            lastCaptureMs = captureMs

            // A live A/V Sync slider change mid-generation is a deliberate
            // user action, not per-packet jitter to smooth over — apply it
            // via one controlled re-anchor rather than smearing a
            // correction across subsequent buffers (GOAL requirement 5:
            // "prefer a controlled flush/re-anchor... over introducing
            // tiny per-packet gaps/overlaps").
            if let lastAppliedAVSyncOffsetMs, lastAppliedAVSyncOffsetMs != avSyncOffsetMs, anchor != nil {
                #if DEBUG
                Log.info("audioTrace: PCM engine A/V offset changed \(lastAppliedAVSyncOffsetMs)ms->\(avSyncOffsetMs)ms — re-anchoring")
                #endif
                reanchorLocked()
            }
            lastAppliedAVSyncOffsetMs = avSyncOffsetMs

            let isFirstOfGeneration = anchor == nil
            if isFirstOfGeneration {
                let now = CACurrentMediaTime()
                let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: avSyncOffsetMs)) / 1000.0
                anchor = Anchor(captureMs: captureMs, hostTime: now + PCMJitterBufferPolicy.prerollSeconds + audioDelaySeconds)
                #if DEBUG
                Log.info("audioTrace: PCM engine generation=\(generation) anchor established captureMs=\(Int(captureMs)) leadMs=\(Int(PCMJitterBufferPolicy.prerollSeconds * 1000)) mode=\(PCMSchedulingMode.current)")
                logOutputFormatOnce()
                #endif
            }
            guard let anchor else { return }

            let myGeneration = generation
            pendingCount += 1
            scheduledCount += 1

            switch PCMSchedulingMode.current {
            case .continuous:
                if isFirstOfGeneration {
                    let audioTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchor.hostTime))
                    player.scheduleBuffer(buffer, at: audioTime, options: []) { [weak self] in
                        self?.completed(generation: myGeneration)
                    }
                } else {
                    // No explicit time: chains contiguously off the player
                    // node's own internal timeline — this is the fix.
                    player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                        self?.completed(generation: myGeneration)
                    }
                }

            case .preciseScheduled:
                let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: avSyncOffsetMs)) / 1000.0
                let targetSeconds = anchor.hostTime + (captureMs - anchor.captureMs) / 1000.0 + audioDelaySeconds
                #if DEBUG
                logPreciseContinuity(targetSeconds: targetSeconds, frameCount: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
                let now = CACurrentMediaTime()
                if targetSeconds < now {
                    Log.info("audioTrace: ⚠️ PCM engine precise-scheduling target already \(Int((now - targetSeconds) * 1000))ms in the past")
                }
                #endif
                let audioTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: targetSeconds))
                player.scheduleBuffer(buffer, at: audioTime, options: []) { [weak self] in
                    self?.completed(generation: myGeneration)
                }
            }

            if !player.isPlaying {
                player.play()
            }
        }
    }

    private func completed(generation myGeneration: UInt64) {
        queue.async { [self] in
            guard myGeneration == generation else { return }
            pendingCount = max(0, pendingCount - 1)
            if pendingCount == 0 {
                // Anomaly-only: the queue drained to zero between this
                // completion and the next `enqueue` call — i.e. a
                // starvation gap, not overflow. Distinct counter from
                // `overflowDropCount` so the two opposite failure modes
                // never get conflated in a log line.
                starvationCount += 1
            }
        }
    }

    private func ensureEngine(format: AVAudioFormat) {
        guard engine == nil else { return }
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        do {
            try newEngine.start()
            engine = newEngine
            player = newPlayer
            #if DEBUG
            Log.info("audioTrace: PCM engine generation=\(generation) started inputFormat=rate=\(format.sampleRate) ch=\(format.channelCount)")
            #endif
        } catch {
            Log.info("audioTrace: ⚠️ PCM engine start failed: \(error)")
        }
    }

    #if DEBUG
    /// GOAL requirement 2/4: confirms the engine's ACTUAL output/hardware
    /// sample rate — never assumed to be 48kHz — since a mismatch between
    /// the assumed and actual rate anywhere in the host-time/sample-time
    /// math would itself produce exactly this kind of artifact.
    private func logOutputFormatOnce() {
        guard !loggedOutputFormat, let engine, let player else { return }
        loggedOutputFormat = true
        let mixerOut = engine.mainMixerNode.outputFormat(forBus: 0)
        let playerOut = player.outputFormat(forBus: 0)
        Log.info("audioTrace: PCM engine output formats mixerRate=\(mixerOut.sampleRate) mixerCh=\(mixerOut.channelCount) playerRate=\(playerOut.sampleRate) playerCh=\(playerOut.channelCount)")
    }

    /// See `PCMSchedulingContinuity` — logs the exact adjacent-buffer gap/
    /// overlap `.preciseScheduled` produces at every boundary.
    private func logPreciseContinuity(targetSeconds: Double, frameCount: Int, sampleRate: Double) {
        if let lastPreciseTargetSeconds, let lastPreciseFrameCount, let lastPreciseSampleRate {
            let boundary = PCMSchedulingContinuity.boundary(
                previousTargetSeconds: lastPreciseTargetSeconds, previousFrameCount: lastPreciseFrameCount,
                previousSampleRate: lastPreciseSampleRate, nextTargetSeconds: targetSeconds, sampleRate: sampleRate)
            Log.info("audioTrace: PCM engine precise continuity previousEndSampleTime=\(boundary.previousEndSampleTime) nextStartSampleTime=\(boundary.nextStartSampleTime) deltaFrames=\(boundary.deltaFrames)\(boundary.deltaFrames != 0 ? " ⚠️" : "")")
        }
        lastPreciseTargetSeconds = targetSeconds
        lastPreciseFrameCount = frameCount
        lastPreciseSampleRate = sampleRate
    }
    #endif

    /// Internal re-anchor: like `reset()`, but does NOT tear down the
    /// engine/player (a discontinuity or a slider drag mid-generation
    /// should not pay for rebuilding `AVAudioEngine`) — only the anchor
    /// and generation, so the very next buffer scheduled re-establishes
    /// timing from current capture time, and any buffer already scheduled
    /// under the old generation whose completion lands after this point is
    /// still correctly ignored. Must be called with `queue` already the
    /// execution context (both call sites are inside the `queue.async`
    /// block in `enqueue`).
    private func reanchorLocked() {
        generation &+= 1
        anchor = nil
        reanchorCount += 1
        // A genuinely clean cut, not a blend of old- and new-anchor audio:
        // stops and clears the player's own schedule (cheap — does not
        // tear down `AVAudioEngine`) so no stale-generation buffer is
        // still mid-playback when the next buffer restarts it at the new
        // anchor. Discarded buffers' completion handlers may never fire,
        // so `pendingCount` is reset here rather than left to drift.
        player?.stop()
        pendingCount = 0
        #if DEBUG
        lastPreciseTargetSeconds = nil
        lastPreciseFrameCount = nil
        lastPreciseSampleRate = nil
        #endif
    }

    /// Flushes all state and bumps the generation — call on Audio Off,
    /// reconnect, codec/playback-path change, Resync, and AVAudioSession
    /// interruption/route-change recovery. Any buffer already scheduled
    /// under the old generation is stopped with the player/engine tear-
    /// down; any completion callback still in flight from the old
    /// generation no-ops against the bumped `generation`. The next
    /// `enqueue` call transparently rebuilds the engine and re-anchors —
    /// no separate "restart" API needed.
    func reset() {
        queue.async { [self] in
            generation &+= 1
            pendingCount = 0
            anchor = nil
            lastCaptureMs = nil
            lastAppliedAVSyncOffsetMs = nil
            player?.stop()
            engine?.stop()
            engine = nil
            player = nil
            #if DEBUG
            loggedOutputFormat = false
            lastPreciseTargetSeconds = nil
            lastPreciseFrameCount = nil
            lastPreciseSampleRate = nil
            Log.info("audioTrace: PCM engine generation=\(generation) reset")
            #endif
        }
    }
}
