import Foundation

/// Receiver Swift6-B1: a narrow, lock-backed owner for the decode/
/// presentation telemetry counters that used to live directly on
/// `StreamReceiver` (`decodeWindow`, `decodeFlushes`, and the DEBUG-only
/// `debugFramesPresentedWindow`). These feed only `PerfStats.decodeP50`,
/// `PerfStats.decodeFlushes`, and a DEBUG diagnostic log line — nothing here
/// participates in decode/presentation correctness, frame ordering, A/V
/// sync, or any transport/recovery decision. Read the B1 audit in
/// `Shared/StreamReceiver.swift` (`makeVideoDecoderOutputEffects`/
/// `makeVideoPresenterOutputEffects`) for the closures this replaces.
///
/// A plain synchronous class, not an actor: telemetry callbacks land on the
/// per-frame decode/presentation hot path and must never pay for an actor
/// hop. Modeled on `StreamReceiver.SendTargetBox` — the only mutable state
/// is protected by one `NSLock`, exactly three private stored properties are
/// ever touched outside a critical section (never), and the class exposes
/// only atomic methods, never a raw getter/setter pair for anything that
/// needs to stay a single operation.
///
/// Invariant: every read of and write to this class's mutable state happens
/// inside `lock`/`unlock`. Callers on `StreamReceiver.queue` and `@Sendable`
/// decoder/presenter effect closures (which may run on VideoToolbox's own
/// callback thread) interact with this state ONLY through the methods below.
final class ReceiverVideoTelemetry: @unchecked Sendable {
    private let lock = NSLock()

    /// VTDecompressionSession decode durations (ms), one per decoded frame,
    /// since the last 5s Mac-facing stats report — mirrors the old
    /// `StreamReceiver.decodeWindow`, feeding `PerfStats.decodeP50`.
    private var decodeDurationsMs: [Double] = []

    /// Display-layer (`AVSampleBufferDisplayLayer`) flush-on-failure count
    /// since the current connection — mirrors the old cumulative
    /// `StreamReceiver.decodeFlushes`, feeding `PerfStats.decodeFlushes`.
    /// Cumulative until `reset()`, never windowed — same as before.
    private var flushCount = 0

    #if DEBUG
    /// Frames that actually reached `displayLayer.enqueue` on the direct-
    /// display path this ~1s debug window — mirrors the old
    /// `StreamReceiver.debugFramesPresentedWindow`, feeding only the
    /// `receiverPipeline:` DEBUG log line.
    private var presentedWindowCount = 0
    #endif

    // MARK: - Hot-path writers (per decoded/presented frame)

    /// Record one decode's wall-clock duration. Called from the
    /// `ReceiverVideoDecoder.OutputEffects.decodeDurationMs` closure — no
    /// `Task`, no actor hop, no queue re-entry; a tiny uncontended lock
    /// operation only.
    func recordDecodeDuration(_ ms: Double) {
        lock.lock(); defer { lock.unlock() }
        decodeDurationsMs.append(ms)
    }

    /// One display-layer flush was incurred. Called from
    /// `ReceiverVideoPresenter.OutputEffects.decodeFlushIncurred`.
    func incrementFlushCount() {
        lock.lock(); defer { lock.unlock() }
        flushCount += 1
    }

    #if DEBUG
    /// One frame reached the display layer on the direct-display path.
    /// Called from `ReceiverVideoPresenter.OutputEffects.debugFramePresented`.
    func incrementDebugPresentedCount() {
        lock.lock(); defer { lock.unlock() }
        presentedWindowCount += 1
    }
    #endif

    // MARK: - Host-side (StreamReceiver.queue) readers

    /// Snapshot of this window's decode-duration samples, for
    /// `percentile(_:_:)` — non-destructive, exactly like the old inline
    /// `percentile(decodeWindow, 0.5)` read (the window itself is cleared
    /// separately, on its own 5s cadence, by `clearDecodeDurationWindow()`
    /// — the two were never one atomic operation in the original code
    /// either, since only `StreamReceiver.queue` ever read or cleared it).
    func snapshotDecodeDurationsMs() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return decodeDurationsMs
    }

    /// The cumulative flush count, for `PerfStats.decodeFlushes`.
    func currentFlushCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return flushCount
    }

    /// Clears the rolling decode-duration window — same 5s Mac-facing-report
    /// cadence as the old `decodeWindow.removeAll(keepingCapacity:)`.
    func clearDecodeDurationWindow() {
        lock.lock(); defer { lock.unlock() }
        decodeDurationsMs.removeAll(keepingCapacity: true)
    }

    #if DEBUG
    /// Atomic read-then-reset of the debug presented-frame count, for the
    /// `receiverPipeline:` log line's ~1s window — one lock-protected
    /// compound operation, preserving the old code's implicit atomicity
    /// (it ran single-threaded on `queue`, so "read the value, then zero
    /// it" was never actually racy before either; this keeps that same
    /// read-then-clear shape as one call instead of two).
    func drainDebugPresentedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = presentedWindowCount
        presentedWindowCount = 0
        return value
    }
    #endif

    /// New-connection reset — same cadence and same two fields as the old
    /// `StreamReceiver.resetStreamState()` (`decodeFlushes = 0`,
    /// `decodeWindow.removeAll()`). One atomic operation so a concurrent
    /// decode-duration/flush callback can never land between the two
    /// individual resets and see a half-cleared state.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        decodeDurationsMs.removeAll(keepingCapacity: true)
        flushCount = 0
    }
}
