// ReceiverAudioPresenter — RC-3 Stage E2.
//
// The sole owner of the receiver-side audio SCHEDULING/RENDERING domain that
// used to live as plain `queue`-confined stored properties on
// `StreamReceiver`: the `AVSampleBufferAudioRenderer` /
// `AVSampleBufferRenderSynchronizer` pair (legacy/sample-buffer playback
// path only — see "Playback path boundary" below), the one-shot
// capture-timeline -> host-time `audioAnchor`, the DEBUG-only renderer-error
// KVO observation whose lifetime is tied to the renderer, and the
// CMSampleBuffer construction/enqueue that used to be
// `StreamReceiver.scheduleDecodedAudio`.
//
// E1 (`ReceiverAudioDecoder`) already pulled out the AAC->PCM decode domain;
// this stage deliberately left decode alone and moved everything
// downstream of it instead.
//
// Isolation: NOT an actor, and NOT `@MainActor`. Xcode 27's AVFoundation
// headers declare both `AVSampleBufferAudioRenderer` and
// `AVSampleBufferRenderSynchronizer` as plain `NSObject` subclasses with no
// `MainActor` isolation and no `Sendable` conformance — unlike
// `AVSampleBufferDisplayLayer` (a `CALayer`, hence `ReceiverVideoPresenter`
// is `@MainActor`), these are not UI objects and carry no main-thread
// requirement from the SDK. Every call this session makes into this type
// happens synchronously from `StreamReceiver.queue`, the same single serial
// `DispatchQueue` that owns every other piece of receiver audio state — so,
// exactly like `ReceiverAudioDecoder` and `PCMPlaybackEngine`, this follows
// the project's established single-queue-confinement pattern rather than
// introducing an actor hop into a real-time, per-packet scheduling path
// (which would also violate the "no Task-per-audio-packet" performance
// requirement). `@unchecked Sendable`: every stored property below is
// touched only from `StreamReceiver.queue` — including the DEBUG KVO
// callback, which re-hops to `queue` before touching anything, exactly as
// the pre-extraction code did — never concurrently, and never from this
// type's own async work (there is none).
//
// Input boundary: `AudioTimingSnapshot`, an immutable Sendable struct
// carrying only the values one scheduling decision actually needs
// (`clockOffsetMs`, `avSyncOffsetMs`, `lastVideoLatencySeconds` + its
// staleness wall-clock stamp, and `nowMs`) — captured by the host at the
// same synchronous, `queue`-confined call site the pre-extraction code read
// them from, so there is no semantic gap versus the old inline reads. This
// type has no getter back into `StreamReceiver` and never reads
// `presentationGeneration` (audio scheduling here never branches on it) or
// `ReceiverVideoPresenter`.
//
// Output boundary: stops at `audioRenderer.enqueue(_:)`. It has no
// knowledge of `PCMPlaybackEngine`, `audioFormatDescription`'s lifecycle
// decisions, `audioCodecKind`, or `AVAudioSession` — those all remain
// host-side.
//
// Playback path boundary: production playback is `PCMPlaybackEngine`
// (`activePlaybackPath == .pcmEngine`), which schedules decoded PCM
// directly and never touches this type's renderer/synchronizer/anchor at
// all. This type owns only the DEBUG-selectable `.legacyRenderer` fallback
// path (`StreamReceiver.scheduleAudioPacket`'s `.legacyRenderer` case) plus
// the DEBUG-only PCM-bypass A/B path (`schedulePCMPacket`), which share the
// exact same anchor/renderer/synchronizer machinery pre-extraction. The two
// paths do not share scheduling ownership, so `PCMPlaybackEngine`'s
// architecture is untouched by this stage.
//
// Reset modes: the pre-extraction `resetAudioPlayback(keepingFormat:)`
// tears down renderer/synchronizer/anchor IDENTICALLY regardless of
// `keepingFormat` — that flag only ever gated host-owned state
// (`audioFormatDescription`, `audioCodecKind`, the `AVAudioSession`
// activation, `ReceiverAudioDecoder.reset()`). So, from this type's own
// point of view, there is exactly one full-teardown reset (`reset()`,
// called for every `resetAudioPlayback` call site: Audio Off, reconnect,
// pause, codec change, Resync, playback-path switch, session-disruption
// recovery) plus one narrower, genuinely distinct mode: DEBUG-only
// renderer-error KVO recovery, which — exactly as before — clears ONLY the
// anchor (`clearAnchorOnly()`), never touching the renderer/synchronizer,
// so a transient renderer error does not escalate into a full teardown.
//
// Ordering: every entry point here is a synchronous, `queue`-confined call
// — no command queue/epoch of its own is needed. The only non-`queue`
// producer is the DEBUG KVO callback, which (exactly as pre-extraction)
// re-enters via `queue.async` before touching state, so it can never race a
// synchronous call already in flight; it only ever clears the anchor, which
// is naturally idempotent/order-insensitive with respect to a later
// `reset()` or a fresh anchor establishment. No audio-specific epoch is
// introduced: nothing here can outlive a `reset()` and be mistaken for
// live work, since `reset()` synchronously drops the renderer that any
// stale KVO closure references.
//
@preconcurrency import AVFoundation
import CoreMedia
import QuartzCore

final class ReceiverAudioPresenter: @unchecked Sendable {

    /// Immutable, Sendable snapshot of exactly the host-owned timing values
    /// one audio scheduling decision needs — captured synchronously on
    /// `StreamReceiver.queue` at the same point the pre-extraction code read
    /// these as instance vars. Never includes `presentationGeneration`:
    /// nothing in this type's scheduling logic ever branched on it.
    struct AudioTimingSnapshot: Sendable {
        var clockOffsetMs: Double
        var avSyncOffsetMs: Int
        var lastVideoLatencySeconds: Double?
        var lastVideoLatencyUpdatedAtWallMs: Double
        var nowMs: Double
    }

    /// A stable capture-timeline -> host-time mapping, established ONCE per
    /// generation (first audio packet after a reset) or on `resync()`, and
    /// otherwise left alone. FORENSIC NOTE (unchanged from the
    /// pre-extraction doc comment): an earlier version of this receiver
    /// recomputed this mapping from EVERY displayed video frame's own
    /// arrival time, which is itself jittery — feeding it straight into
    /// audio's schedule made audio inherit video's arrival jitter,
    /// producing the stutter this fix addresses. A one-shot anchor plus
    /// audio's own evenly-spaced capture deltas schedules smoothly
    /// regardless of how jittery video's arrival is.
    private struct MediaAnchor {
        var captureMs: Double
        var hostTime: CFTimeInterval
    }

    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?
    private var audioAnchor: MediaAnchor?
    /// Small bounded preroll folded into a fresh anchor's lead time — ~3 AAC
    /// packets. Enough to absorb ordinary scheduling jitter without the
    /// renderer starving; nowhere near enough to feel like added
    /// interactive latency.
    private let audioPrerollSeconds = 0.064

    #if DEBUG
    private var audioErrorObservation: NSKeyValueObservation?
    /// Total successful `audioRenderer.enqueue` calls this generation —
    /// read back only by `StreamReceiver`'s DEBUG timing-diagnostic trace.
    private var audioEnqueueCount = 0
    private var lastAudioTarget: CFTimeInterval?
    #endif

    /// Re-hops to `queue` before touching any state, matching the
    /// pre-extraction KVO closure exactly — `weak` so a torn-down/replaced
    /// presenter (there is only ever one live instance, owned by
    /// `StreamReceiver`, but the observation itself outlives `reset()`'s nil
    /// of `audioRenderer` until the closure fires) never force-unwraps into
    /// a dangling reference.
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Lazily (re)creates the renderer/synchronizer chain after a reset or
    /// on first use. Called both eagerly, when a fresh `AudioConfigFrame`/
    /// `PCMConfigFrame` arrives (matching pre-extraction `applyAudioConfig`/
    /// `applyPCMConfig`, which built the chain regardless of which playback
    /// path is currently active), and lazily inside `scheduleDecodedAudio`.
    func ensurePlaybackChain(activateSession: () -> Void) {
        guard audioRenderer == nil else { return }
        let renderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        // Ties the synchronizer's virtual clock 1:1 to the host clock from
        // this instant on — every sample buffer's PTS is then simply "the
        // host time it should play at" (see `targetHostTime`), with no
        // separate anchor/rate bookkeeping needed on this end.
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        audioRenderer = renderer
        audioSynchronizer = synchronizer
        activateSession()
        #if DEBUG
        // Anomaly diagnostic (GOAL section 7): `error` is KVO-observable on
        // AVSampleBufferAudioRenderer and fires if the renderer itself hits
        // an unrecoverable playback error — exactly the kind of event that
        // would explain a sudden dead-audio patch without a corresponding
        // network/framing symptom. Anchor-only recovery — NEVER escalated
        // to a full `reset()` — so a transient renderer error re-anchors
        // on the next packet instead of tearing down/rebuilding the chain.
        audioErrorObservation = renderer.observe(\.error, options: [.new]) { [weak self, queue] _, change in
            guard let error = change.newValue ?? nil else { return }
            Log.info("audioTrace: ⚠️ audio renderer reported error: \(error)")
            queue.async { [weak self] in
                self?.clearAnchorOnly()
            }
        }
        #endif
    }

    /// Full teardown — renderer/synchronizer stopped, flushed, and released;
    /// anchor cleared. Called for EVERY `StreamReceiver.resetAudioPlayback`
    /// call site regardless of its `keepingFormat` flag: from this type's
    /// point of view the two are identical (see the file header's "Reset
    /// modes" note) — `keepingFormat` only ever gated host-owned state this
    /// type never touches.
    func reset() {
        audioRenderer?.stopRequestingMediaData()
        if let audioRenderer { audioRenderer.flush() }
        audioSynchronizer?.setRate(0, time: .zero)
        audioRenderer = nil
        audioSynchronizer = nil
        audioAnchor = nil
        #if DEBUG
        lastAudioTarget = nil
        audioErrorObservation = nil
        #endif
    }

    /// Anchor-only recovery — used exclusively by the DEBUG renderer-error
    /// KVO callback. Deliberately narrower than `reset()`: the renderer and
    /// synchronizer stay live, only the capture-timeline mapping is
    /// discarded so the next scheduled sample re-derives it (`resync()`
    /// goes through `reset()` like every other call site — see the file
    /// header's "Reset modes" note; `resetAudioPlayback` tears the chain
    /// down unconditionally regardless of `keepingFormat`).
    func clearAnchorOnly() {
        audioAnchor = nil
    }

    /// Shared core for both the production AAC legacy-renderer path
    /// (`StreamReceiver.scheduleAudioPacket`'s `.legacyRenderer` case) and
    /// the DEBUG-only PCM bypass path (`schedulePCMPacket`): resolves the
    /// capture-timeline anchor, builds one `CMSampleBuffer` from `payload`
    /// against `formatDescription`, and enqueues it. `sampleSizes` is only
    /// consulted when `sampleSizeEntryCount > 0` (compressed formats); pass
    /// `{ [] }` for an uncompressed format whose description already fixes
    /// the frame size.
    func scheduleDecodedAudio(
        capturedAtMs: Int64, payload: Data, sampleCount: Int, duration: CMTime,
        sampleSizeEntryCount: Int, sampleSizes: () -> [Int],
        formatDescription: CMAudioFormatDescription,
        timing: AudioTimingSnapshot,
        activateSession: () -> Void
    ) {
        ensurePlaybackChain(activateSession: activateSession)   // lazily recreates the renderer after resync/reset
        guard let audioRenderer else { return }
        // Mac wall-clock ms -> this receiver's equivalent wall-clock ms
        // (section 8.1: offset = macClock - receiverClock).
        let receiverCaptureMs = Double(capturedAtMs) - timing.clockOffsetMs

        if audioAnchor == nil {
            establishAnchor(captureMs: receiverCaptureMs, timing: timing)
        }
        guard let anchor = audioAnchor else { return }

        let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: timing.avSyncOffsetMs)) / 1000.0
        let target = anchor.hostTime + (receiverCaptureMs - anchor.captureMs) / 1000.0 + audioDelaySeconds
        #if DEBUG
        checkNonMonotonicTarget(target)
        #endif

        var blockBuffer: CMBlockBuffer?
        let blockStatus = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            var buffer: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: raw.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: raw.count, flags: 0, blockBufferOut: &buffer)
            guard createStatus == noErr, let buffer else { return createStatus }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: raw.count)
            blockBuffer = buffer
            return copyStatus
        }
        guard blockStatus == noErr, let blockBuffer else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ CMBlockBuffer creation/copy failed status=\(blockStatus) — sample dropped before reaching the renderer")
            #endif
            return
        }

        let pts = CMTime(seconds: target, preferredTimescale: 1_000_000)
        var timingInfo = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizes = sampleSizes()
        var sample: CMSampleBuffer?
        let createStatus = sizes.withUnsafeMutableBufferPointer { sizesPtr -> OSStatus in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                formatDescription: formatDescription, sampleCount: sampleCount,
                sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: sampleSizeEntryCount,
                sampleSizeArray: sampleSizeEntryCount > 0 ? sizesPtr.baseAddress : nil,
                sampleBufferOut: &sample)
        }
        guard createStatus == noErr, let sample else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ CMSampleBufferCreateReady failed status=\(createStatus) — sample dropped before reaching the renderer")
            #endif
            return
        }
        audioRenderer.enqueue(sample)
        #if DEBUG
        audioEnqueueCount += 1
        #endif
    }

    /// Establishes the ONE anchor mapping audio's capture timeline to host
    /// time for this generation (see `MediaAnchor`'s doc comment) — never
    /// called again until a reset clears it. Folds in a small preroll plus,
    /// if a recent video-latency measurement exists in the snapshot, an
    /// automatic baseline correction so audio settles near video's real
    /// latency instead of an arbitrary fixed lead — computed once, not
    /// chased.
    private func establishAnchor(captureMs: Double, timing: AudioTimingSnapshot) {
        let now = CACurrentMediaTime()
        var lead = audioPrerollSeconds
        var baselineMs = 0.0
        if let lastVideoLatencySeconds = timing.lastVideoLatencySeconds,
           timing.nowMs - timing.lastVideoLatencyUpdatedAtWallMs < 1_000 {
            // Sanity-bounded: a video path that is itself somehow stalled
            // must not inject an enormous lead into audio's schedule.
            baselineMs = min(max(lastVideoLatencySeconds, 0), 0.3) * 1000
            lead = max(lead, baselineMs / 1000)
        }
        audioAnchor = MediaAnchor(captureMs: captureMs, hostTime: now + lead)
        #if DEBUG
        Log.info("audioTrace: anchor established captureMs=\(Int(captureMs)) leadMs=\(Int(lead * 1000)) baselineMs=\(Int(baselineMs))")
        #endif
    }

    #if DEBUG
    /// Anomaly-only (GOAL section 7 "RECEIVER"): the renderer's playout
    /// schedule must be monotonic — a packet scheduled to play before the
    /// previous one means an anchor/offset computation went backwards,
    /// which would sound like a stutter/glitch right at that instant.
    private func checkNonMonotonicTarget(_ target: CFTimeInterval) {
        defer { lastAudioTarget = target }
        if let lastAudioTarget, target < lastAudioTarget {
            Log.info("audioTrace: ⚠️ non-monotonic audio playout target \(target) < previous \(lastAudioTarget)")
        }
    }

    /// Read back only by `StreamReceiver.logAudioTimingDiagnostic` — the
    /// same anchor+target recomputation the pre-extraction diagnostic did
    /// inline, now delegated so the host never holds its own shadow of
    /// `audioAnchor`.
    func debugQueuedMs(receiverCaptureMs: Double, avSyncOffsetMs: Int) -> Double? {
        guard let anchor = audioAnchor else { return nil }
        let audioDelaySeconds = Double(AVSyncOffset.audioDelayMs(for: avSyncOffsetMs)) / 1000.0
        let target = anchor.hostTime + (receiverCaptureMs - anchor.captureMs) / 1000.0 + audioDelaySeconds
        return (target - CACurrentMediaTime()) * 1000
    }

    var debugEnqueueCount: Int { audioEnqueueCount }

    /// Test-only probe (unit tests exclusively — no production call site):
    /// establishes an anchor exactly like `scheduleDecodedAudio` would on
    /// its first packet, and returns the `lead` term in seconds
    /// (`anchor.hostTime - now`, `now` captured internally at the same
    /// instant `establishAnchor` itself would) — deterministic regardless
    /// of how much real wall-clock time a caller then spends before
    /// reading it back, unlike `debugQueuedMs`, which re-samples `now` at
    /// read time and so is only meaningful for a comparison against
    /// another `debugQueuedMs` call on the SAME anchor.
    func debugEstablishAnchorAndReturnLeadSeconds(captureMs: Double, timing: AudioTimingSnapshot) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        establishAnchor(captureMs: captureMs, timing: timing)
        return audioAnchor!.hostTime - now
    }

    func debugResetEnqueueCount() {
        audioEnqueueCount = 0
    }
    #endif
}
