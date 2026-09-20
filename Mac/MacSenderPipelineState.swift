import Foundation

// MacSenderPipelineState — the slice of MacSender's encode/send-backpressure
// and per-generation bookkeeping that is written from ScreenCaptureKit's and
// VideoToolbox's own callback threads (never `queue`) and read back on
// `queue`. Everything here shares that one cross-thread invariant, which is
// exactly why it lived under a single `NSLock` (`pipelineLock`) on MacSender
// before this extraction — this type just gives that lock a name and makes
// every field it protects unreachable except through it.
//
// Deliberately excluded (see MacSender): `needsKeyframe`, audio bookkeeping
// beyond the generation counter itself (`audioPacketSeq`, `audioConfigSent`,
// PCM debug state), and anything VTCompressionSession-lifecycle-owning —
// none of those are touched off of `queue`, so none of them share this
// invariant.
final class MacSenderPipelineState: @unchecked Sendable {
    private let lock = NSLock()

    private var pendingEncodes = 0
    let maxPendingEncodes: Int

    private var pendingSends = 0
    let maxPendingSends: Int

    private var dropsEncThisWindowValue = 0
    private var dropsNetThisWindowValue = 0
    private var dropsEncTotalValue = 0
    private var dropsNetTotalValue = 0
    private var dropsEncPingWindowValue = 0
    private var dropsNetPingWindowValue = 0

    private var audioGeneration: UInt64 = 0
    private var captureGeneration: UInt64 = 0

    private var encodeFailureStreakGeneration: UInt64?
    private var encodeFailureStreakCount = 0
    private var encodeLastSuccessGeneration: UInt64?
    private var encoderRecoveryDowngradedGeneration: UInt64?
    let encodeFailureStreakLimit: Int

    private var wakeCaptureAwaitingFirstFrameGenerationValue: UInt64?
    private var wakeCaptureAwaitingEncodedFrameGenerationValue: UInt64?

    // Both throttled-log policies are recorded into from the VideoToolbox
    // encode-submission call (`encode`, on the SCK callback thread, not
    // `queue`) and flushed from `queue` — the same cross-thread invariant as
    // everything else here, which is why they shared `pipelineLock` before.
    private var encodeFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    private var encodeOutputFailureLogPolicy = ThrottledLogPolicy<OSStatus>()

    #if DEBUG
    private var debugVTSubmittedWindowValue = 0
    private var debugVTCompletedWindowValue = 0
    private var debugEncodeLogGeneration: UInt64?
    private var debugEncodeLogCount = 0
    #endif

    init(maxPendingEncodes: Int, maxPendingSends: Int = 3, encodeFailureStreakLimit: Int = 30) {
        self.maxPendingEncodes = maxPendingEncodes
        self.maxPendingSends = maxPendingSends
        self.encodeFailureStreakLimit = encodeFailureStreakLimit
    }

    // MARK: - Generations

    var audioGenerationNow: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return audioGeneration
    }

    /// Bumps and returns the new audio generation, atomically.
    @discardableResult
    func beginAudioGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        audioGeneration &+= 1
        return audioGeneration
    }

    var captureGenerationNow: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return captureGeneration
    }

    func bumpCaptureGeneration() {
        lock.lock(); defer { lock.unlock() }
        captureGeneration &+= 1
    }

    var wakeCaptureAwaitingFirstFrameGeneration: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return wakeCaptureAwaitingFirstFrameGenerationValue }
        set { lock.lock(); wakeCaptureAwaitingFirstFrameGenerationValue = newValue; lock.unlock() }
    }

    var wakeCaptureAwaitingEncodedFrameGeneration: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return wakeCaptureAwaitingEncodedFrameGenerationValue }
        set { lock.lock(); wakeCaptureAwaitingEncodedFrameGenerationValue = newValue; lock.unlock() }
    }

    // MARK: - Backpressure admission

    func isBackedUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingEncodes >= maxPendingEncodes || pendingSends >= maxPendingSends
    }

    /// Mirrors the previous `shouldDropFrame` counter/admission logic exactly
    /// (reason is "pending_encode" or "pending_sends"); the caller still owns
    /// deciding whether to arm the drop-replay timer for a net drop.
    func admitFrame(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let drop: Bool
        switch reason {
        case "pending_encode": drop = pendingEncodes >= maxPendingEncodes
        case "pending_sends": drop = pendingSends >= maxPendingSends
        default: drop = false
        }
        guard drop else { return false }
        switch reason {
        case "pending_encode":
            dropsEncThisWindowValue += 1
            dropsEncTotalValue += 1
            dropsEncPingWindowValue += 1
        case "pending_sends":
            dropsNetThisWindowValue += 1
            dropsNetTotalValue += 1
            dropsNetPingWindowValue += 1
        default: break
        }
        return true
    }

    func incrementPendingEncodes() {
        lock.lock(); pendingEncodes += 1; lock.unlock()
    }

    func decrementPendingEncodes() {
        lock.lock(); pendingEncodes = max(0, pendingEncodes - 1); lock.unlock()
    }

    func resetPendingEncodes() {
        lock.lock(); pendingEncodes = 0; lock.unlock()
    }

    var pendingSendsNow: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingSends
    }

    func setPendingSends(_ value: Int) {
        lock.lock(); pendingSends = value; lock.unlock()
    }

    /// Increments and returns the new value, so debug callers can peak-track
    /// it without a second locked read.
    @discardableResult
    func incrementPendingSends() -> Int {
        lock.lock(); defer { lock.unlock() }
        pendingSends += 1
        return pendingSends
    }

    /// Applies `TransportSafety.decrementedPendingCount` and returns the new
    /// value, matching the previous inline send-completion bookkeeping.
    @discardableResult
    func decrementPendingSends() -> Int {
        lock.lock(); defer { lock.unlock() }
        pendingSends = TransportSafety.decrementedPendingCount(pendingSends)
        return pendingSends
    }

    // MARK: - Drop counters (HUD/PHONE-STATS/ping snapshots)

    var dropsEncThisWindow: Int { lock.lock(); defer { lock.unlock() }; return dropsEncThisWindowValue }
    var dropsNetThisWindow: Int { lock.lock(); defer { lock.unlock() }; return dropsNetThisWindowValue }
    var dropsEncTotal: Int { lock.lock(); defer { lock.unlock() }; return dropsEncTotalValue }
    var dropsNetTotal: Int { lock.lock(); defer { lock.unlock() }; return dropsNetTotalValue }

    /// Resets and returns the enc/net ping-window counters together, as the
    /// existing `schedulePing` snapshot-then-reset call site needs.
    func drainPingWindowDrops() -> (enc: Int, net: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (enc: dropsEncPingWindowValue, net: dropsNetPingWindowValue)
        dropsEncPingWindowValue = 0
        dropsNetPingWindowValue = 0
        return result
    }

    /// Snapshots and resets the enc/net this-window counters together, as the
    /// existing PHONE-STATS log line's read-then-reset needs.
    func drainThisWindowDrops() -> (enc: Int, net: Int) {
        lock.lock()
        defer { lock.unlock() }
        let result = (enc: dropsEncThisWindowValue, net: dropsNetThisWindowValue)
        dropsEncThisWindowValue = 0
        dropsNetThisWindowValue = 0
        return result
    }

    // MARK: - Encoder failure-streak / recovery bookkeeping

    /// Records the failure into the output-failure throttled-log policy and
    /// runs the exact per-generation failure-streak update from `encode`'s
    /// completion closure, atomically. Returns the log action to perform and
    /// whether this failure should trigger a one-time FPS-downgrade recovery
    /// attempt for `generation`.
    func recordEncodeOutputFailure(
        _ status: OSStatus, at time: TimeInterval, generation: UInt64
    ) -> (logAction: ThrottledLogPolicy<OSStatus>.Action, shouldAttemptRecovery: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let logAction = encodeOutputFailureLogPolicy.record(status, at: time)
        if encodeFailureStreakGeneration != generation {
            encodeFailureStreakGeneration = generation
            encodeFailureStreakCount = 0
        }
        encodeFailureStreakCount += 1
        let shouldAttemptRecovery = encodeLastSuccessGeneration != generation
            && encodeFailureStreakCount >= encodeFailureStreakLimit
            && encoderRecoveryDowngradedGeneration != generation
        if shouldAttemptRecovery { encoderRecoveryDowngradedGeneration = generation }
        return (logAction, shouldAttemptRecovery)
    }

    func recordEncodeSuccess(generation: UInt64) {
        lock.lock(); encodeLastSuccessGeneration = generation; lock.unlock()
    }

    func flushEncodeOutputFailureLog(at time: TimeInterval) -> ThrottledLogPolicy<OSStatus>.Report? {
        lock.lock(); defer { lock.unlock() }
        return encodeOutputFailureLogPolicy.flush(at: time)
    }

    /// Records a synchronous `VTCompressionSessionEncodeFrame` submission
    /// failure and decrements `pendingEncodes` for the frame that never made
    /// it into the pipeline, atomically (matches the previous single locked
    /// region in `encode`).
    func recordEncodeSubmitFailure(
        _ status: OSStatus, at time: TimeInterval
    ) -> ThrottledLogPolicy<OSStatus>.Action {
        lock.lock()
        defer { lock.unlock() }
        pendingEncodes = max(0, pendingEncodes - 1)
        return encodeFailureLogPolicy.record(status, at: time)
    }

    func flushEncodeSubmitFailureLog(at time: TimeInterval) -> ThrottledLogPolicy<OSStatus>.Report? {
        lock.lock(); defer { lock.unlock() }
        return encodeFailureLogPolicy.flush(at: time)
    }

    #if DEBUG
    func incrementDebugVTSubmitted() {
        lock.lock(); debugVTSubmittedWindowValue += 1; lock.unlock()
    }

    func incrementDebugVTCompletedWindow() {
        lock.lock(); debugVTCompletedWindowValue += 1; lock.unlock()
    }

    /// Reports the log slot to use for this frame within `generation`'s
    /// first-5-frames debug window, mirroring the previous inline
    /// `debugEncodeLogGeneration`/`Count` bookkeeping.
    func nextDebugEncodeLogNumber(generation: UInt64) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if debugEncodeLogGeneration != generation {
            debugEncodeLogGeneration = generation
            debugEncodeLogCount = 0
        }
        guard debugEncodeLogCount < 5 else { return nil }
        debugEncodeLogCount += 1
        return debugEncodeLogCount
    }

    /// Snapshots and resets the debug submitted/completed window counters, as
    /// the existing `senderPipeline` log line's read-then-reset needs.
    func drainDebugVTWindow() -> (submitted: Int, completed: Int) {
        lock.lock()
        defer { lock.unlock() }
        let result = (submitted: debugVTSubmittedWindowValue, completed: debugVTCompletedWindowValue)
        debugVTSubmittedWindowValue = 0
        debugVTCompletedWindowValue = 0
        return result
    }
    #endif
}
