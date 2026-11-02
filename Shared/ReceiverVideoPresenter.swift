// ReceiverVideoPresenter — RC-3 Stage D.
//
// The sole authoritative owner of the presentation domain that used to live
// as plain `queue`-confined code and stored properties directly on
// `StreamReceiver`: `AVSampleBufferDisplayLayer` enqueue/flush/
// flushAndRemoveImage, the Metal-vs-direct-display routing decision's
// EXECUTION (the decision itself — `useMetalPath` / whether an
// `onDecodedFrame` sink is wired up — stays host policy, read once per
// frame in `StreamReceiver.presentDecodedSample` and handed down as
// `viaMetalPath`, exactly like C4 left the metal-vs-displayLayer choice
// host-side), and `videoGeneration`, the presentation-level generation
// that gates both paths' delayed-present closures against a superseded
// resync/reset.
//
// Ordering: exactly the same primitive C3/C4 established — one
// `AsyncStream<Command>` fed by `nonisolated` synchronous `enqueue*` entry
// points (never a `Task` per call site) and one long-lived pump `Task`
// (started once, in `init`) that drains it strictly in enqueue order. This
// orders `enqueuePresentSample`/`enqueuePresentDecoded` against
// `enqueueFlush`/`enqueueFlushAndRemoveImage`/`enqueueAdvanceGeneration` —
// a resync/reset enqueued after a frame is guaranteed to apply after that
// frame reaches the display layer, and a frame enqueued before a
// resync/reset (but whose generation the resync/reset then supersedes) is
// discarded rather than presented out of turn. Every call site in
// `StreamReceiver` that used to touch `displayLayer` directly, or mutate
// `videoGeneration` directly, now goes through one of these entry points
// instead — see `StreamReceiver`'s `resetStreamState`,
// `resetDecoderForVideoStateChange`, `resync`, `setRenderingPaused`, its
// `makeFramePipelineOutputEffects().codecConfigurationChanged`, and
// `presentDecodedSample`.
//
// Stale-generation safety: `StreamReceiver` still keeps its own
// `presentationGeneration` counter — a `queue`-confined SHADOW of this
// actor's `videoGeneration`, incremented at the exact same call sites, in
// the exact same order, immediately before enqueueing the matching
// `.advanceGeneration` command here. This is a deliberate, narrow
// exception to "this actor is the sole owner": the shadow exists ONLY so
// `presentDecodedSample` can snapshot "the generation this frame belongs
// to" with a synchronous, zero-hop read on its own hot path (no per-frame
// actor `await`, matching the "no Task-per-frame / no per-frame hop"
// requirement) — it is never read back to make a presentation DECISION.
// The actual gating decision — whether a `.presentSample`/`.presentDecoded`
// command's carried `generation` still matches — is made entirely inside
// this actor, against its own `videoGeneration`, at the moment the pump
// processes that command. Because both counters are incremented 1:1 from
// the same `queue`-confined call sites in the same order, the shadow and
// the authoritative copy are always in lockstep by the time any command
// referencing either is actually processed.
//
// Metal path + stale VT callback: a decode routed through
// `ReceiverVideoDecoder` carries the SAME `generation` value all the way
// through `VTDecompressionSessionDecodeFrame`'s asynchronous output
// callback (see that actor's file header) and arrives back here via
// `enqueuePresentDecoded`, where it is checked against `videoGeneration`
// exactly like a direct-display frame. A decode that completes after a
// resync/reset superseded its generation is discarded here rather than
// handed to `onDecodedFrame` — this closes the pre-existing "stale VT
// callback" gap the independent C4 review flagged (the decoder itself
// still carries no generation concept of its own; it only threads this
// actor's opaque tag through).
//
// Direct-display path: `StreamReceiver.presentDecodedSample` still applies
// the constant per-connection A/V-sync delay (`queue.asyncAfter`) BEFORE
// calling `enqueuePresentSample` — the delay is why a plain "commands
// arrive in FIFO order" guarantee alone would not be enough to keep a
// delayed frame from landing after a resync that fired while it was still
// pending; the carried `generation` is what actually discards it in that
// case (see "Stale-generation safety" above).
//
// MainActor: empirically required, not assumed — building this against
// the real SDK under strict concurrency surfaces `AVSampleBufferDisplayLayer.
// flush()`/`enqueue(_:)`/`flushAndRemoveImage()` as `@MainActor`-isolated
// (Xcode 16 SDK). The `queue`-confined code this replaces called them from
// a plain serial `DispatchQueue`, off `MainActor` entirely — the compiler
// simply had no way to see that under the OLD (non-`actor`) design, since
// nothing there was isolation-checked; it was never actually verified
// thread-safe, only conventionally disciplined. This type is therefore a
// plain `@MainActor final class`, not a same-domain-as-everything-else
// custom actor — the ordering primitive (one `AsyncStream` + one pump
// `Task`) is identical either way, but the pump itself now runs ON
// `MainActor`, and every `enqueue*` entry point stays `nonisolated` and
// synchronous so `StreamReceiver`'s `queue`-confined callers (and
// VideoToolbox's own decode-output thread, for `enqueuePresentDecoded`)
// never pay a `MainActor` hop to SUBMIT a command — only the pump's own
// processing (already inherently async) runs there. No per-frame `Task`,
// no blocking `MainActor` on decode completion; `displayLayer.videoGravity
// = .resizeAspect` stays exactly where it was, a one-time `@MainActor` set
// in `StreamReceiver.init` before `start()`/any frame exists.
import Foundation
import AVFoundation
import CoreMedia

// Receiver Swift6-B2.2: `@unchecked Sendable` so `StreamReceiver` can hand a
// direct (non-`self`) reference to this instance into `ReceiverVideoDecoder`'s
// `decodedFrameReady` effect (see that actor's file, and the construction
// order note in `StreamReceiver.init`), replacing a deferred `[weak self]`
// lookup through `StreamReceiver` that Swift 6 rejects (`StreamReceiver`
// itself is not `Sendable`). This is not a blanket escape hatch: every
// public entry point (`enqueue*`) is already `nonisolated` and thread-safe
// by construction (see the file header's "Ordering" and "MainActor"
// sections) — the ONLY mutable state, `videoGeneration`, is written and read
// exclusively from this class's own `runCommandPump`/`presentSample`/
// `presentDecoded`, never from a capturing closure directly, so no new
// unsynchronized access is introduced by allowing this type to cross an
// isolation boundary as a plain reference.
@MainActor
final class ReceiverVideoPresenter: @unchecked Sendable {

    /// One ordered unit of work — see the file header's Ordering section.
    /// `Sendable` so `nonisolated` callers can hand it to the stream
    /// continuation without hopping onto the actor first.
    enum Command: Sendable {
        case presentSample(FrameMediaBox<CMSampleBuffer>, generation: UInt64, viaMetalPath: Bool, captureMs: Double?)
        case presentDecoded(FrameMediaBox<CVPixelBuffer>, generation: UInt64, captureMs: Double?)
        case flush
        case flushAndRemoveImage
        case advanceGeneration
    }

    /// The narrow output surface this actor calls out to for everything
    /// downstream of a presentation decision — never a dumping ground for
    /// unrelated `StreamReceiver` concerns, exactly like `ReceiverFramePipeline.
    /// OutputEffects`/`ReceiverVideoDecoder.OutputEffects`.
    struct OutputEffects: Sendable {
        /// Route a presentation-ready sample buffer through
        /// `ReceiverVideoDecoder` instead of displaying it directly — the
        /// Metal renderer path. `generation` is passed straight through to
        /// `ReceiverVideoDecoder.enqueueDecode`, opaque to that actor too.
        var decodeViaVideoDecoder: @Sendable (FrameMediaBox<CMSampleBuffer>, _ generation: UInt64, _ captureMs: Double?) -> Void
        /// A decoded frame (Metal path) survived the generation check —
        /// the app-facing sink (`StreamReceiver.onDecodedFrame`).
        var decodedFrameReady: @Sendable (FrameMediaBox<CVPixelBuffer>, _ captureMs: Double?) -> Void
        /// `displayLayer.status == .failed` was observed and flushed —
        /// feeds `ReceiverVideoTelemetry`'s flush-count telemetry exactly
        /// as before (Receiver Swift6-B1 moved that counter's storage
        /// there).
        var decodeFlushIncurred: @Sendable () -> Void
        /// A sample buffer actually reached `displayLayer.enqueue` on the
        /// direct-display path (not merely routed there) — feeds
        /// `ReceiverVideoTelemetry`'s DEBUG-only presented-window
        /// telemetry. Present unconditionally (unlike that counter itself)
        /// purely so this struct's initializer never needs `#if DEBUG`
        /// inside its argument list; `StreamReceiver` wires it to a no-op
        /// outside DEBUG.
        var debugFramePresented: @Sendable () -> Void
    }

    /// Same object `StreamReceiver.displayLayer` holds — injected once at
    /// construction, exactly like `videoDecoder`/`framePipeline` are handed
    /// their dependencies. `nonisolated(unsafe)`: assigned exactly once,
    /// from `init` (itself `nonisolated` — see its doc comment), before
    /// any concurrent access is possible; every READ of it thereafter is
    /// still only ever from this class's own `MainActor`-isolated methods
    /// (`runCommandPump`/`presentSample`/`presentDecoded`) — this escape
    /// hatch exists purely because `AVSampleBufferDisplayLayer` is not
    /// `Sendable`, not because this class relaxes its own isolation
    /// discipline around it.
    private nonisolated(unsafe) let displayLayer: AVSampleBufferDisplayLayer

    nonisolated let outputEffects: OutputEffects

    /// The presentation generation — see "Stale-generation safety" above.
    /// This IS the authoritative copy; `StreamReceiver.
    /// presentationGeneration` is a synchronized shadow, never the other
    /// way around.
    private var videoGeneration: UInt64 = 0

    /// The ordering primitive — see the file header. `.unbounded`:
    /// commands are cheap value types (a boxed buffer reference plus a few
    /// scalars), and this must never drop or block a `nonisolated` caller
    /// on `queue`.
    private let commands: AsyncStream<Command>
    private nonisolated let commandContinuation: AsyncStream<Command>.Continuation

    #if DEBUG
    /// Test-only: fires with each `Command` at the moment the pump begins
    /// processing it — i.e. immediately before this actor would act on it.
    /// Proves enqueue-to-processing ordering without a real
    /// `AVSampleBufferDisplayLayer`. Set only by
    /// `ReceiverVideoPresenterTests`; never read or set in production code.
    var debugSubmissionObserver: (@Sendable (Command) -> Void)?
    #endif

    /// `nonisolated`: constructed from `StreamReceiver`'s `lazy var
    /// presenter`, which — like `videoDecoder`/`framePipeline` — is first
    /// touched from `queue`-confined code, never from `MainActor`. Storing
    /// `displayLayer`/`outputEffects` and starting the pump `Task` neither
    /// needs nor performs any `displayLayer` access itself, so this is
    /// safe: nothing MainActor-isolated runs until the pump `Task` itself
    /// hops there to await `runCommandPump`.
    nonisolated init(displayLayer: AVSampleBufferDisplayLayer, outputEffects: OutputEffects) {
        self.displayLayer = displayLayer
        self.outputEffects = outputEffects
        var continuation: AsyncStream<Command>.Continuation!
        self.commands = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.commandContinuation = continuation
        Task { [weak self] in await self?.runCommandPump() }
    }

    /// The single, long-lived consumer — started exactly once, in `init`.
    /// Never suspends waiting for `displayLayer` to actually render;
    /// `enqueue`/`flush`/`flushAndRemoveImage` are the same fire-and-return
    /// calls the code this replaces made from `queue`.
    private func runCommandPump() async {
        for await command in commands {
            #if DEBUG
            debugSubmissionObserver?(command)
            #endif
            switch command {
            case .presentSample(let box, let generation, let viaMetalPath, let captureMs):
                presentSample(box, generation: generation, viaMetalPath: viaMetalPath, captureMs: captureMs)
            case .presentDecoded(let box, let generation, let captureMs):
                presentDecoded(box, generation: generation, captureMs: captureMs)
            case .flush:
                displayLayer.flush()
            case .flushAndRemoveImage:
                displayLayer.flushAndRemoveImage()
            case .advanceGeneration:
                videoGeneration &+= 1
            }
        }
    }

    // MARK: - Ordered entry points (nonisolated, synchronous — see file header)

    /// Enqueues one presentation-ready sample buffer, in call order.
    /// `StreamReceiver.presentDecodedSample`'s sole entry point for both
    /// the direct-display and Metal-routed cases — `viaMetalPath` is
    /// decided host-side (reading `useMetalPath`/`onDecodedFrame`, a
    /// policy read, not a presentation-ordering concern) and carried here
    /// verbatim so this actor never re-derives it.
    nonisolated func enqueuePresentSample(
        _ box: FrameMediaBox<CMSampleBuffer>, generation: UInt64, viaMetalPath: Bool, captureMs: Double?
    ) {
        commandContinuation.yield(.presentSample(box, generation: generation, viaMetalPath: viaMetalPath, captureMs: captureMs))
    }

    /// Enqueues a decoded (Metal path) pixel buffer — the far end of
    /// `OutputEffects.decodeViaVideoDecoder`, reached via
    /// `ReceiverVideoDecoder.OutputEffects.decodedFrameReady`. Ordered
    /// against every other command exactly like a direct-display frame:
    /// VideoToolbox's own output callback fires off its decode thread, not
    /// `queue`, so this call may arrive interleaved with host-thread
    /// `enqueueFlush`/`enqueueAdvanceGeneration` calls in real time — the
    /// generation check in `presentDecoded`, not arrival order, is what
    /// makes that safe.
    nonisolated func enqueuePresentDecoded(_ box: FrameMediaBox<CVPixelBuffer>, generation: UInt64, captureMs: Double?) {
        commandContinuation.yield(.presentDecoded(box, generation: generation, captureMs: captureMs))
    }

    /// Enqueues a plain flush — `StreamReceiver.setRenderingPaused`'s
    /// resume path (`displayLayer.flush()` on backgrounded-linger resume).
    nonisolated func enqueueFlush() {
        commandContinuation.yield(.flush)
    }

    /// Enqueues a flush that also retires the currently-displayed image —
    /// the reconnect/adoption reset (`resetStreamState`), video-state-off
    /// (`resetDecoderForVideoStateChange`), and codec-configuration-change
    /// (`codecConfigurationChanged`) call sites. Ordered against
    /// `enqueuePresentSample`/`enqueuePresentDecoded` exactly like a plain
    /// flush.
    nonisolated func enqueueFlushAndRemoveImage() {
        commandContinuation.yield(.flushAndRemoveImage)
    }

    /// Enqueues a presentation-generation bump — `resetStreamState` (new
    /// connection) and `resync()`. Always paired, at its call site, with a
    /// same-order increment of `StreamReceiver.presentationGeneration`
    /// (the shadow — see the file header's "Stale-generation safety").
    nonisolated func enqueueAdvanceGeneration() {
        commandContinuation.yield(.advanceGeneration)
    }

    // MARK: - Presentation

    /// Only ever called by `runCommandPump`, in enqueue order. A stale
    /// `generation` (a resync/reset already advanced past it, processed
    /// earlier in this same ordered stream) discards the frame instead of
    /// presenting or decoding it — see "Stale-generation safety" above.
    private func presentSample(
        _ box: FrameMediaBox<CMSampleBuffer>, generation: UInt64, viaMetalPath: Bool, captureMs: Double?
    ) {
        guard generation == videoGeneration else { return }
        if viaMetalPath {
            outputEffects.decodeViaVideoDecoder(box, generation, captureMs)
            return
        }
        let sample = box.value
        // Display immediately: low latency, no PTS scheduling — same
        // attachment this class's code used to set inline in
        // `StreamReceiver.presentDecodedSample`.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed {
            Log.info("display layer failed (\(String(describing: displayLayer.error))) — flushing")
            outputEffects.decodeFlushIncurred()
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
        #if DEBUG
        outputEffects.debugFramePresented()
        #endif
    }

    /// Only ever called by `runCommandPump`. Same stale-generation
    /// discard as `presentSample` — this is what closes the pre-existing
    /// stale VT callback gap (see the file header).
    @MainActor
    private func presentDecoded(_ box: FrameMediaBox<CVPixelBuffer>, generation: UInt64, captureMs: Double?) {
        guard generation == videoGeneration else { return }
        outputEffects.decodedFrameReady(box, captureMs)
    }
}
