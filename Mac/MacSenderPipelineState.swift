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
    /// Audio sends still in flight. Tracked apart from `pendingSends` (which
    /// is VIDEO backpressure only) so audio never makes video drop frames
    /// and video backpressure never gates audio — the app-level half of not
    /// recreating head-of-line blocking over QUIC's independent streams.
    private var pendingAudioSends = 0
    /// Bumped whenever the transport is replaced; a send completion carrying
    /// an older epoch belongs to a retired connection and must not touch
    /// the new connection's counters.
    private var sendEpoch: UInt64 = 0

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

    // MARK: - Channel-aware, epoch-guarded send accounting

    var pendingAudioSendsNow: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingAudioSends
    }

    var sendEpochNow: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return sendEpoch
    }

    /// The transport was replaced (redial, transport switch): every counter
    /// restarts at zero under a fresh epoch. Returns the new epoch.
    @discardableResult
    func resetPendingSendsForNewTransport() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        pendingSends = 0
        pendingAudioSends = 0
        sendEpoch &+= 1
        return sendEpoch
    }

    /// Accounts one media send on `channel` (Control is never counted: it is
    /// not subject to media backpressure). Returns the channel's new
    /// in-flight count and the epoch the completion must present.
    func beginMediaSend(channel: TransportChannel) -> (inFlight: Int, epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        switch channel {
        case .video:
            pendingSends += 1
            return (pendingSends, sendEpoch)
        case .audio:
            pendingAudioSends += 1
            return (pendingAudioSends, sendEpoch)
        case .control:
            return (0, sendEpoch)
        }
    }

    /// Completion of a send started by `beginMediaSend`. Ignored (returns
    /// false) when it belongs to an older transport epoch.
    @discardableResult
    func completeMediaSend(channel: TransportChannel, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == sendEpoch else { return false }
        switch channel {
        case .video: pendingSends = TransportSafety.decrementedPendingCount(pendingSends)
        case .audio: pendingAudioSends = TransportSafety.decrementedPendingCount(pendingAudioSends)
        case .control: break
        }
        return true
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
        return (logAction, recordFailureStreakLocked(generation: generation))
    }

    /// Caller holds `lock`. One failed encode — asynchronous output or
    /// synchronous submission — toward `generation`'s zero-success streak.
    private func recordFailureStreakLocked(generation: UInt64) -> Bool {
        if encodeFailureStreakGeneration != generation {
            encodeFailureStreakGeneration = generation
            encodeFailureStreakCount = 0
        }
        encodeFailureStreakCount += 1
        let shouldAttemptRecovery = encodeLastSuccessGeneration != generation
            && encodeFailureStreakCount >= encodeFailureStreakLimit
            && encoderRecoveryDowngradedGeneration != generation
        if shouldAttemptRecovery { encoderRecoveryDowngradedGeneration = generation }
        return shouldAttemptRecovery
    }

    /// The failing encoder of `generation` was replaced by one of another
    /// codec (the one-time HEVC -> H.264 fallback): give the replacement its
    /// own streak and its own one-time recovery, as a fresh generation has.
    func rearmEncodeFailureRecovery(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard encodeFailureStreakGeneration == generation else { return }
        encodeFailureStreakCount = 0
        if encoderRecoveryDowngradedGeneration == generation { encoderRecoveryDowngradedGeneration = nil }
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
    ///
    /// With a `generation`, the rejected submission also counts toward that
    /// generation's zero-success streak: a session that refuses every frame
    /// synchronously is as broken as one that fails every output.
    func recordEncodeSubmitFailure(
        _ status: OSStatus, at time: TimeInterval, generation: UInt64? = nil
    ) -> (logAction: ThrottledLogPolicy<OSStatus>.Action, shouldAttemptRecovery: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pendingEncodes = max(0, pendingEncodes - 1)
        let logAction = encodeFailureLogPolicy.record(status, at: time)
        guard let generation else { return (logAction, false) }
        return (logAction, recordFailureStreakLocked(generation: generation))
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
