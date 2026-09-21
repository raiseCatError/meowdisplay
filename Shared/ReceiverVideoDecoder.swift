// ReceiverVideoDecoder — RC-3 Stage C4.
//
// The sole authoritative owner of the VideoToolbox decode domain that used
// to live as plain `queue`-confined stored properties on `StreamReceiver`:
// the production `VTDecompressionSession` (Metal renderer path only —
// `AVSampleBufferDisplayLayer` decodes internally and never touches this
// actor), its DEBUG-only independent luma-probe session, and the decode-
// generation state (format-description/session recreation, error counting)
// that must move with them. `StreamReceiver.presentDecodedSample` still
// decides WHETHER to route a frame through hardware decode at all (the
// Metal-vs-displayLayer path selection stays host policy, not this actor's
// concern — see the file header of `ReceiverFramePipeline` for the matching
// C3 boundary) and owns `videoGeneration`, the presentation-level generation
// that gates BOTH paths' delayed-present closures; that is a shared
// presentation concern, not decode-specific (`resync()` bumps it without
// touching a decoder at all), so it deliberately stays host-side rather
// than migrating in here — see the STOP CONDITIONS note in the C4 report.
//
// RC-3 Stage D update: `videoGeneration` now lives on `ReceiverVideoPresenter`
// (see its file header), still host-side policy, not this actor's. Its
// value at the moment a frame is submitted is threaded through opaquely as
// `generation` on `enqueueDecode`/`Command.decode`/`decodedFrameReady` —
// this actor never reads or compares it, only carries it — so the
// presenter can discard a decode whose output arrives after a later
// resync/reset superseded it, closing the pre-existing "stale VT callback"
// gap the C4 review flagged without this actor gaining any generation
// concept of its own.
//
// Input boundary: `ReceiverFramePipeline` already emits presentation-ready
// `CMSampleBuffer`s, boxed the same way it hands them to the host
// (`FrameMediaBox`, reused here rather than inventing a second wrapper).
// This actor reads a fresh format description directly off that sample —
// it never reaches back into `ReceiverFramePipeline`'s own SPS/PPS/VPS
// ownership.
//
// Output boundary: stops at the decoded `CVPixelBuffer` (boxed with the
// same `FrameMediaBox` generic). `AVSampleBufferDisplayLayer` ownership,
// `displayLayer.enqueue`/`flush`, and every MainActor presentation decision
// stay entirely on `StreamReceiver` (Stage D) — this actor never touches
// `displayLayer`.
//
// Ordering: `VTDecompressionSessionDecodeFrame` submission must happen in
// wire-arrival order. An independent `Task { await decoder.decode(...) }`
// PER FRAME does NOT guarantee this — sibling `Task`s created back-to-back
// from a serial caller are not guaranteed to reach an actor's mailbox in
// creation order (the same reason a Task-per-input-event design was
// rejected for the synchronous input surface). Instead every entry point
// below (`enqueueDecode`/`enqueueReset`/`enqueueFormatDescriptionChanged`/
// `enqueueProbeDecodedLuma`) is `nonisolated` and SYNCHRONOUS: it appends
// one `Command` onto a single `AsyncStream`, in call order, and returns
// immediately with no `Task` allocated at the call site. Exactly one
// long-lived pump `Task` (started once, in `init`) drains that stream and
// executes each `Command` on this actor strictly in enqueue order — see
// `runCommandPump`. This orders `.reset`/`.noteFormatDescriptionChanged`
// against `.decode` too: a codec-change reset enqueued before a frame's
// decode is guaranteed to apply before that frame reaches VideoToolbox,
// which an unstructured `Task` per call site could not guarantee either.
//
// The pump only ever waits for `VTDecompressionSessionDecodeFrame` to
// RETURN (the synchronous submission call) before advancing to the next
// command — it never waits for that frame's decoded output. The
// decoded-frame OUTPUT callback fires off VideoToolbox's own decode
// thread, asynchronously and not necessarily in submission order (this
// actor never assumed output ordering; neither did the code it replaces),
// so its `outputCallback` closure never touches actor-isolated state
// directly — it captures a `Sendable` copy of `outputEffects` and, on the
// rare failure path, hops back in via `Task` purely to update the error
// counter used for throttled logging.
//
import Foundation
import CoreMedia
import VideoToolbox

actor ReceiverVideoDecoder {

    /// One ordered unit of work — see the file header's Ordering section.
    /// `Sendable` so `nonisolated` callers can hand it to the stream
    /// continuation without hopping onto the actor first. Not `private`:
    /// `debugSubmissionObserver` (DEBUG-only, test-only) needs to name this
    /// type from `ReceiverVideoDecoderTests`, in a different file.
    enum Command: Sendable {
        case decode(FrameMediaBox<CMSampleBuffer>, generation: UInt64, captureMs: Double?)
        case reset
        case noteFormatDescriptionChanged
        #if DEBUG
        case probeDecodedLuma(FrameMediaBox<CMSampleBuffer>)
        #endif
    }

    /// The narrow, purpose-built output surface this actor calls out to for
    /// everything downstream of a decoded frame — never a dumping ground
    /// for unrelated `StreamReceiver` concerns. Every closure is
    /// responsible for hopping onto the host's own `queue` before touching
    /// queue-confined state, exactly like `ReceiverFramePipeline.
    /// OutputEffects`.
    struct OutputEffects: Sendable {
        /// A frame decoded successfully — the Metal renderer path's sink,
        /// now routed through `ReceiverVideoPresenter` (Stage D) rather
        /// than directly to `StreamReceiver.onDecodedFrame`. `generation`
        /// is the presentation generation captured at the SAME point
        /// `StreamReceiver.presentDecodedSample` captured it for the
        /// direct-display path — threaded verbatim through `enqueueDecode`
        /// and this actor's `decode`, opaque to this actor the whole way,
        /// so the presenter can discard a decode that completes after a
        /// resync/reset superseded it. Closes the pre-existing "stale VT
        /// callback" gap the C4 review flagged (see this file's header).
        var decodedFrameReady: @Sendable (FrameMediaBox<CVPixelBuffer>, _ generation: UInt64, _ captureMs: Double?) -> Void
        /// One decode's wall-clock duration, ms — feeds `StreamReceiver`'s
        /// own `ReceiverVideoTelemetry` decode-duration ring exactly as
        /// before (Receiver Swift6-B1 moved the ring's storage there).
        var decodeDurationMs: @Sendable (Double) -> Void
        /// Decode failed (submission or output callback) — joined mid-GOP,
        /// or a genuinely corrupt frame. `StreamReceiver.
        /// requestKeyframeIfNeeded` already rate-limits actually sending
        /// one; this actor only ever signals the need, never sends control
        /// traffic itself (never touches `SendTarget`).
        var requestKeyframe: @Sendable () -> Void
    }

    // MARK: - State moved together from StreamReceiver (C4)

    private var decompressionSession: VTDecompressionSession?
    private var decodeErrorCount = 0
    #if DEBUG
    // BLACK-VIDEO forensics: an independent, diagnostic-only decode of the
    // first few frames after every format-description change — separate
    // from `decompressionSession` (the production Metal-path decoder) and
    // from the actual render path (`displayLayer.enqueue`, which decodes
    // internally and is never bypassed by this). Answers "did the
    // receiver's OWN H.264/HEVC decode of these NALUs produce a real
    // image, or black?" independent of whatever `AVSampleBufferDisplayLayer`
    // does with the same bytes.
    private var debugProbeDecompressionSession: VTDecompressionSession?
    private var debugDecodedFramesSinceFormatChange = 0
    #endif

    nonisolated let outputEffects: OutputEffects

    /// The ordering primitive — see the file header. `.unbounded`:
    /// commands are cheap value types (a boxed sample buffer reference,
    /// captureMs, or a tag), and this must never drop or block a
    /// `nonisolated` caller on `queue`.
    private let commands: AsyncStream<Command>
    private nonisolated let commandContinuation: AsyncStream<Command>.Continuation

    #if DEBUG
    /// Test-only: fires with each `Command` at the moment the pump begins
    /// processing it — i.e. immediately before this actor would act on it
    /// (call into VideoToolbox, invalidate a session, etc). Proves
    /// enqueue-to-processing ordering without intercepting VideoToolbox
    /// itself. Set only by `ReceiverVideoDecoderTests`; never read or set
    /// in production code.
    var debugSubmissionObserver: (@Sendable (Command) -> Void)?
    #endif

    init(outputEffects: OutputEffects) {
        self.outputEffects = outputEffects
        var continuation: AsyncStream<Command>.Continuation!
        self.commands = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.commandContinuation = continuation
        Task { [weak self] in await self?.runCommandPump() }
    }

    /// The single, long-lived consumer — started exactly once, in `init`.
    /// Never suspends waiting for a decoded frame; only ever suspends
    /// between commands (waiting on the stream) or, synchronously within
    /// one command, on `VTDecompressionSessionDecodeFrame`'s own (fast,
    /// non-blocking) submission call.
    private func runCommandPump() async {
        for await command in commands {
            #if DEBUG
            debugSubmissionObserver?(command)
            #endif
            switch command {
            case .decode(let box, let generation, let captureMs):
                decode(box, generation: generation, captureMs: captureMs)
            case .reset:
                reset()
            case .noteFormatDescriptionChanged:
                noteFormatDescriptionChanged()
            #if DEBUG
            case .probeDecodedLuma(let box):
                probeDecodedLuma(box)
            #endif
            }
        }
    }

    // MARK: - Ordered entry points (nonisolated, synchronous — see file header)

    /// Enqueues one frame for hardware decode, in call order. The Metal
    /// path's sole entry point — `StreamReceiver.presentDecodedSample`
    /// calls this directly from its own `queue`-confined `present` closure,
    /// never wrapped in a `Task`.
    nonisolated func enqueueDecode(_ box: FrameMediaBox<CMSampleBuffer>, generation: UInt64, captureMs: Double?) {
        commandContinuation.yield(.decode(box, generation: generation, captureMs: captureMs))
    }

    /// Enqueues a full session invalidation — video-state-off, codec
    /// change, or the reconnect/adoption reset in `StreamReceiver.
    /// resetStreamState`. Ordered against `enqueueDecode`: a reset
    /// enqueued before a frame is guaranteed to apply before that frame
    /// reaches VideoToolbox.
    nonisolated func enqueueReset() {
        commandContinuation.yield(.reset)
    }

    /// Enqueues the DEBUG-probe re-arm that follows a fresh SPS/PPS (or
    /// VPS/SPS/PPS) format description. A no-op command outside DEBUG
    /// (see `noteFormatDescriptionChanged`'s body) — callers still only
    /// invoke this under `#if DEBUG`, matching the code it replaces.
    nonisolated func enqueueFormatDescriptionChanged() {
        commandContinuation.yield(.noteFormatDescriptionChanged)
    }

    #if DEBUG
    /// Enqueues the BLACK-VIDEO forensics probe — see `probeDecodedLuma`.
    nonisolated func enqueueProbeDecodedLuma(_ box: FrameMediaBox<CMSampleBuffer>) {
        commandContinuation.yield(.probeDecodedLuma(box))
    }
    #endif

    // MARK: - Reset seam

    /// A fresh SPS/PPS (or VPS/SPS/PPS) format description just landed —
    /// mirrors what was inline in `StreamReceiver.
    /// makeFramePipelineOutputEffects`'s `codecConfigurationChanged`
    /// closure: re-arm the DEBUG luma probe for the new generation. The
    /// production `decompressionSession` does NOT reset here — it
    /// self-heals in `ensureSession` via `VTDecompressionSessionCanAccept
    /// FormatDescription`, exactly as before.
    private func noteFormatDescriptionChanged() {
        #if DEBUG
        debugDecodedFramesSinceFormatChange = 0
        if let session = debugProbeDecompressionSession {
            VTDecompressionSessionInvalidate(session)
            debugProbeDecompressionSession = nil
        }
        #endif
    }

    /// Invalidates every session this actor owns — called at every point
    /// the old inline code did: video-state-off, codec change, and the
    /// reconnect/adoption reset in `StreamReceiver.resetStreamState`. Never
    /// leaves a stale session that could accept a newer, mismatched stream.
    private func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        decodeErrorCount = 0
        #if DEBUG
        if let session = debugProbeDecompressionSession {
            VTDecompressionSessionInvalidate(session)
            debugProbeDecompressionSession = nil
        }
        debugDecodedFramesSinceFormatChange = 0
        #endif
    }

    // MARK: - Explicit decode (Metal renderer path)

    private func ensureSession(formatDescription formatDesc: CMFormatDescription) {
        if let session = decompressionSession {
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
                return
            }
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        // NV12: the decoder's native output — BGRA would add a conversion
        // pass inside VideoToolbox (measured ~7ms); the YUV→RGB happens in
        // the renderer's fragment shader instead (~free).
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: formatDesc, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        if status != noErr { Log.info("VTDecompressionSessionCreate failed: \(status)") }
        decompressionSession = session
    }

    /// Synchronous hardware decode submission — only ever called by
    /// `runCommandPump`, in enqueue order (see the file header). The
    /// OUTPUT callback below fires asynchronously off VideoToolbox's own
    /// decode thread and is never assumed to preserve that order (VT
    /// itself does not guarantee it, and the code this replaces never
    /// relied on it either) — it only ever calls back out through
    /// `Sendable` `outputEffects` closures, never touches actor state
    /// directly, and captures no unmanaged reference to this actor.
    private func decode(_ box: FrameMediaBox<CMSampleBuffer>, generation: UInt64, captureMs: Double?) {
        let sample = box.value
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample) else { return }
        ensureSession(formatDescription: formatDesc)
        guard let session = decompressionSession else { return }
        let t0 = Date()
        let effects = outputEffects
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                effects.decodeDurationMs(Date().timeIntervalSince(t0) * 1000)
                effects.decodedFrameReady(FrameMediaBox(imageBuffer), generation, captureMs)
            } else {
                Task { await self?.recordDecodeFailure(status: status, fromCallback: true) }
                effects.requestKeyframe()
            }
        }
        if status != noErr {
            recordDecodeFailure(status: status, fromCallback: false)
            effects.requestKeyframe()
        }
    }

    private func recordDecodeFailure(status: OSStatus, fromCallback: Bool) {
        if decodeErrorCount % 60 == 0 {
            Log.info(fromCallback
                ? "decode output error: \(status)"
                : "decode call error: \(status) (\(decodeErrorCount) total)")
        }
        decodeErrorCount += 1
    }

    #if DEBUG
    /// BLACK-VIDEO forensics (iOS decoder stage) — see the type-level doc
    /// comment. Runs regardless of `useMetalPath`, on every frame
    /// `StreamReceiver` hands it, for the first 5 frames of each format
    /// generation. Only ever called by `runCommandPump`.
    private func probeDecodedLuma(_ box: FrameMediaBox<CMSampleBuffer>) {
        let sample = box.value
        guard debugDecodedFramesSinceFormatChange < 5,
              let formatDesc = CMSampleBufferGetFormatDescription(sample) else { return }
        debugDecodedFramesSinceFormatChange += 1
        let frameNumber = debugDecodedFramesSinceFormatChange
        if let session = debugProbeDecompressionSession,
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
            VTDecompressionSessionInvalidate(session)
            debugProbeDecompressionSession = nil
        }
        if debugProbeDecompressionSession == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: formatDesc, decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &session)
            guard status == noErr, let session else {
                Log.info("extendDebug: iOS decode probe session create failed status=\(status)")
                return
            }
            debugProbeDecompressionSession = session
        }
        guard let session = debugProbeDecompressionSession else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                Log.info("extendDebug: iOS decode probe frame #\(frameNumber) failed status=\(status)")
                return
            }
            let luma = Self.debugAverageLuma(imageBuffer)
            Log.info("extendDebug: iOS decode probe frame #\(frameNumber) "
                + "\(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer)) "
                + "avgLuma=\(luma.map { String(format: "%.1f", $0) } ?? "n/a")")
        }
        if status != noErr {
            Log.info("extendDebug: iOS decode probe submit failed frame #\(frameNumber) status=\(status)")
        }
    }

    /// See `MacSender.debugAverageLuma` (identical purpose, independent
    /// copy — the two live in different compilation targets). A cheap,
    /// sparse-sampled average luma, never a full-frame scan.
    private static func debugAverageLuma(_ pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(width / 32, 1), stepY = max(height / 32, 1)
        var sum = 0.0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                sum += Double(buf[y * stride + x])
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }
    #endif
}
