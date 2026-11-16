import Foundation

// Phase 2 of adaptive Automatic streaming (issue #123): one coordinator per
// `MacSender` (one sender per receiver), so a decision for one receiver can
// only ever reach that receiver's pipeline. It turns the pure phase 1 pieces
// (`RefreshNegotiation`, `NetworkCost`, `AdaptiveStreamingController`) and
// the optional wire keys into a plan the sender applies through its existing
// paths. With the Beta switch off and no data saving it returns nil
// everywhere, and the sender runs exactly today's fixed Automatic policy.
// See docs/performance/adaptive-streaming.md.

/// Settings ▸ Streaming ▸ "Adaptive Automatic (Beta)". Off by default.
enum AdaptiveStreamingSettings {
    static let defaultsKey = "adaptiveAutomaticBeta"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

/// What the sender runs instead of today's fixed values. nil = today.
struct AdaptiveStreamingPlan: Equatable, Sendable, CustomStringConvertible {
    enum Origin: String, Sendable {
        /// The adaptive controller's current operating point.
        case controller
        /// "Use less data": the conservative static point.
        case dataSaver
    }

    /// Multiplies the quality's own capture scale (1.0 in Automatic).
    var rasterScale: Double
    var bitrate: Int
    var fpsCap: Int?
    var origin: Origin

    var description: String {
        String(format: "%@ %.3f×/%.1fMbps/%@", origin.rawValue, rasterScale, Double(bitrate) / 1_000_000,
               fpsCap.map { "\($0)fps" } ?? "-")
    }
}

/// The existing pipeline path a plan change takes (cheapest that covers it).
enum AdaptiveApplyPath: String, Equatable, Sendable {
    case none
    /// FPS: `SCStream.updateConfiguration` + encoder recreate
    /// (`applyEffectiveFPSChange()`).
    case liveFPSUpdate
    /// Bitrate (and FPS with it): VideoToolbox session recreate with a
    /// keyframe (`applyEffectiveFPSChange(rebuildEncoder: true)`).
    case encoderRebuild
    /// Raster: capture restart at the new size.
    case captureRestart
}

enum AdaptiveStreamingPlanner {
    /// The ladder top: today's Best target. Never exceeded.
    static let bitrateCeiling = AdaptiveStreamingLadder.bitrateCeiling
    /// "Use less data" with the controller off: an existing quality level.
    static let saverQuality = StreamQuality.balanced
    static let saverFPSCap = 60

    /// nil = today's behaviour. Custom is never overridden. The controller's
    /// point wins only while it manages this receiver (Beta on and the
    /// receiver sends telemetry); otherwise "Use less data" can still pick
    /// the static saver point.
    static func plan(streamingMode: StreamingMode, adaptiveEnabled: Bool, dataPolicy: NetworkCost.DataPolicy,
                     decision: AdaptiveStreamingDecision?, mode: RefreshNegotiation.DisplayMode) -> AdaptiveStreamingPlan? {
        guard streamingMode == .automatic else { return nil }
        if adaptiveEnabled, let decision, let point = decision.point,
           decision.action != .fixedPolicy, decision.action != .bypass {
            return AdaptiveStreamingPlan(rasterScale: point.rasterScale, bitrate: min(point.bitrate, bitrateCeiling),
                                         fpsCap: point.fps, origin: .controller)
        }
        if dataPolicy == .saver {
            // Window view composes at a fixed canvas: no raster change there.
            return AdaptiveStreamingPlan(rasterScale: mode == .window ? 1.0 : saverQuality.scale,
                                         bitrate: min(saverQuality.bitrate, bitrateCeiling),
                                         fpsCap: saverFPSCap, origin: .dataSaver)
        }
        return nil
    }

    /// Today's result, lowered by the plan and (adaptive on) the source cadence.
    static func resolveFPS(today: StreamingFPSPolicy.Result, plan: AdaptiveStreamingPlan?,
                           sourceCapFPS: Int?) -> StreamingFPSPolicy.Result {
        var fps = today.fps
        if let cap = plan?.fpsCap, cap > 0 { fps = min(fps, cap) }
        if let source = sourceCapFPS, source > 0 { fps = min(fps, source) }
        return fps == today.fps ? today : StreamingFPSPolicy.Result(fps: fps, reason: today.reason)
    }

    static func resolveBitrate(today: Int, plan: AdaptiveStreamingPlan?) -> Int {
        guard let plan else { return today }
        return min(plan.bitrate, today, bitrateCeiling)
    }

    static func resolveScale(today: Double, plan: AdaptiveStreamingPlan?) -> Double {
        today * (plan?.rasterScale ?? 1)
    }

    /// Which path takes `old` to `new`. A raster change restarts capture
    /// (which rebuilds everything); otherwise an FPS change is a live
    /// capture update, and a bitrate change alone (or with FPS) rebuilds the
    /// encoder.
    static func applyPath(from old: AdaptiveStreamingPlan?, to new: AdaptiveStreamingPlan?) -> AdaptiveApplyPath {
        // nil is today's Automatic point: native raster at the Best bitrate.
        let oldRaster = old?.rasterScale ?? 1, newRaster = new?.rasterScale ?? 1
        if abs(oldRaster - newRaster) > 1e-9 { return .captureRestart }
        let today = AdaptiveStreamingLadder.fixedPolicyBitrate
        let bitrateChanged = (old?.bitrate ?? today) != (new?.bitrate ?? today)
        let fpsChanged = old?.fpsCap != new?.fpsCap
        if bitrateChanged { return .encoderRebuild }
        if fpsChanged { return .liveFPSUpdate }
        return .none
    }
}

/// The sender's own side of one pipeline, for `AdaptiveStreamingCoordinator`.
protocol AdaptiveStreamingApplying: AnyObject {
    /// Called on the sender's queue. Must only touch this receiver's pipeline.
    func adaptiveApply(_ path: AdaptiveApplyPath)
}

/// Thread-safe read side for the UI: app payload sent and the current plan.
final class AdaptiveStreamingMonitor: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        /// Encoded video payload handed to the network (app payload, not
        /// carrier-billed bytes: no TLS/QUIC/IP overhead, no retransmits).
        var videoPayloadBytes: Int64
        /// Mean over the time since the first video payload, bits per second.
        var averageBitsPerSecond: Double?
        var plan: AdaptiveStreamingPlan?
        var dataPolicy: NetworkCost.DataPolicy
        var lastReason: AdaptiveStreamingDecision.Reason?
    }

    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var firstSendAt: TimeInterval?
    private var plan: AdaptiveStreamingPlan?
    private var dataPolicy: NetworkCost.DataPolicy = .normal
    private var lastReason: AdaptiveStreamingDecision.Reason?

    func noteVideoPayload(bytes count: Int, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if firstSendAt == nil { firstSendAt = now }
        bytes &+= Int64(max(count, 0))
    }

    func update(plan: AdaptiveStreamingPlan?, dataPolicy: NetworkCost.DataPolicy,
                lastReason: AdaptiveStreamingDecision.Reason?) {
        lock.lock(); defer { lock.unlock() }
        self.plan = plan
        self.dataPolicy = dataPolicy
        if let lastReason { self.lastReason = lastReason }
    }

    func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var average: Double?
        if let firstSendAt, now - firstSendAt >= 1 {
            average = Double(bytes) * 8 / (now - firstSendAt)
        }
        return Snapshot(videoPayloadBytes: bytes, averageBitsPerSecond: average, plan: plan,
                        dataPolicy: dataPolicy, lastReason: lastReason)
    }
}

/// Per-receiver glue between the sender and the phase 1 controller. Every
/// mutating call happens on the sender's queue; the plan and source refresh
/// are also read from capture-start code off the queue, so those two are
/// lock-protected.
final class AdaptiveStreamingCoordinator: @unchecked Sendable {
    /// What configures the controller, rebuilt by the sender on every tick.
    struct Inputs: Equatable, Sendable {
        var mode: RefreshNegotiation.DisplayMode
        var profile: StreamingProfile
        var customFPS: Int?
        var receiverMaxFPS: Int?
        var userMaxFPS: Int?
        var codec: StreamCodec
        var receiver: AdaptiveReceiverDisplay?
    }

    /// The sender's counters for one tick window (~2 s, the ping cadence).
    struct SenderWindow: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        /// ScreenCaptureKit frames with pixels, or composed Window view frames.
        var capturedFrames: Int
        var encoderDrops: Int
        var networkDrops: Int
        var thermal: AdaptiveThermalLevel
        var lowPower: Bool
    }

    let enabled: Bool
    let streamingMode: StreamingMode
    /// This pipeline's display mode (refreshed on every tick).
    private(set) var displayMode: RefreshNegotiation.DisplayMode
    let monitor = AdaptiveStreamingMonitor()
    weak var applier: AdaptiveStreamingApplying?
    /// Where decisions are recorded while diagnostics are on. Set once by
    /// the owning sender right after init, before any input arrives.
    var recorder: StreamDiagnosticsRecorder?
    private let log: (String) -> Void

    /// A source refresh below this is treated as unknown (no source cap):
    /// no real display refreshes that slowly, so a lower reading is noise.
    static let minimumSourceRefreshHz = 24
    /// A restart-class plan change caused by a data-policy change (not by
    /// the controller) is applied at most once per this interval, latest
    /// policy wins: a flapping path or a hostile `saveData`/cost hint can't
    /// cause a capture-restart storm. The controller's own restart limit.
    static let policyRestartIntervalSeconds = AdaptiveStreamingThresholds.standard.minRestartIntervalSeconds

    private let lock = NSLock()
    private var planValue: AdaptiveStreamingPlan?
    private var sourceRefreshValue: Int?
    private var nativeSize: (width: Int, height: Int)?
    /// The capture scale the running capture was started with.
    private var startedScale: Double?

    private(set) var hello: AdaptiveHelloFields?
    /// The policy the evidence asks for (diagnostics and the UI read it).
    private(set) var dataPolicy = NetworkCost.PolicyDecision(policy: .normal, reason: .notReported)
    /// The policy the plan and the controller run. Lags `dataPolicy` only
    /// while a restart-class change waits out the restart limit.
    private(set) var appliedDataPolicy: NetworkCost.DataPolicy = .normal
    /// A policy waiting for the restart limit (latest wins); nil = none.
    private(set) var pendingDataPolicy: NetworkCost.DataPolicy?
    /// When this coordinator last asked for a capture restart (any origin).
    private(set) var lastRestartAt: TimeInterval?
    private(set) var routeEpoch: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private(set) var lastDecision: AdaptiveStreamingDecision?
    private var senderCost: NetworkCost.EndpointReport?
    private var controller: AdaptiveStreamingController?
    private var pendingTelemetry: AdaptiveReceiverTelemetry?
    private var sentFrames = 0
    private var sentBytes = 0
    private var lastRecordedReason: AdaptiveStreamingDecision.Reason?

    init(enabled: Bool, streamingMode: StreamingMode?, displayMode: RefreshNegotiation.DisplayMode,
         recorder: StreamDiagnosticsRecorder? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.enabled = enabled
        self.displayMode = displayMode
        // A sender built without a reported mode is a test or a legacy
        // caller: treat it like Custom (never managed).
        self.streamingMode = streamingMode ?? .custom
        self.recorder = recorder
        self.log = log
    }

    // MARK: Read side (any thread)

    var plan: AdaptiveStreamingPlan? {
        lock.lock(); defer { lock.unlock() }
        return planValue
    }

    var sourceRefreshHz: Int? {
        lock.lock(); defer { lock.unlock() }
        return sourceRefreshValue
    }

    /// True while this pipeline runs the controller: the Mac adds the
    /// announce key to its ping.
    var announcesAdaptive: Bool { enabled && streamingMode == .automatic }

    func resolveFPS(_ today: StreamingFPSPolicy.Result) -> StreamingFPSPolicy.Result {
        lock.lock()
        let plan = planValue
        let source = announcesAdaptive ? sourceRefreshValue : nil
        lock.unlock()
        return AdaptiveStreamingPlanner.resolveFPS(today: today, plan: plan, sourceCapFPS: source)
    }

    func encoderBitrate(today: Int) -> Int {
        AdaptiveStreamingPlanner.resolveBitrate(today: today, plan: plan)
    }

    func captureScale(today: Double) -> Double {
        AdaptiveStreamingPlanner.resolveScale(today: today, plan: plan)
    }

    /// The source's distinct-frame cadence (any thread). Kept for the
    /// diagnostics context even while the controller is off. Below
    /// `minimumSourceRefreshHz` it is unknown (no cap).
    func setSourceRefresh(_ hz: Int?) {
        lock.lock(); defer { lock.unlock() }
        sourceRefreshValue = hz.flatMap { $0 >= Self.minimumSourceRefreshHz ? $0 : nil }
    }

    /// A capture (re)started at `width`×`height` with `scale` applied: the
    /// controller's scale-1.0 raster is that size divided by the scale.
    func noteCaptureStarted(width: Int, height: Int, scale: Double) {
        guard width > 0, height > 0, scale > 0, scale.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        nativeSize = (Int((Double(width) / scale).rounded()) & ~1, Int((Double(height) / scale).rounded()) & ~1)
        startedScale = scale
    }

    /// True when the running capture was started at a different scale than
    /// the plan now asks for (`today` × plan raster): a deferred adaptive
    /// raster restart still has work to do.
    func captureNeedsRasterRestart(today: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let startedScale else { return false }
        return abs(startedScale - today * (planValue?.rasterScale ?? 1)) > 1e-9
    }

    private var captureStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return nativeSize != nil
    }

    // MARK: Inputs (sender queue)

    /// An accepted hello (first or re-sent).
    func helloAccepted(_ fields: AdaptiveHelloFields, now: TimeInterval) {
        hello = fields
        updateDataPolicy(now: now)
        replan(now: now)
    }

    /// The live media connection's path. Older or equal epochs are stale
    /// route callbacks and are ignored.
    @discardableResult
    func senderPathChanged(_ report: NetworkCost.EndpointReport, epoch: UInt64, now: TimeInterval) -> Bool {
        guard epoch > routeEpoch else { return false }
        routeEpoch = epoch
        senderCost = report
        if var controller {
            let decision = controller.routeDidChange(epoch: epoch, now: now)
            self.controller = controller
            note(decision, now: now)
        }
        updateDataPolicy(now: now)
        replan(now: now)
        return true
    }

    func receiverStats(_ telemetry: AdaptiveReceiverTelemetry?) {
        guard let telemetry else { return }
        pendingTelemetry = telemetry
    }

    func noteVideoSent(bytes: Int, now: TimeInterval) {
        sentFrames += 1
        sentBytes += max(bytes, 0)
        monitor.noteVideoPayload(bytes: bytes, now: now)
    }

    /// Once per sender ping window. `generation` is the connection
    /// generation: a newer one (reconnect) resets the controller.
    func tick(generation newGeneration: UInt64, inputs: Inputs?, window: SenderWindow, now: TimeInterval) {
        defer {
            sentFrames = 0
            sentBytes = 0
        }
        if newGeneration != generation {
            generation = newGeneration
            pendingTelemetry = nil
            if var controller {
                let decision = controller.reset(generation: newGeneration, routeEpoch: routeEpoch, now: now)
                self.controller = controller
                note(decision, now: now)
            }
        }
        if let inputs { displayMode = inputs.mode }
        if let pending = pendingDataPolicy, restartAllowed(now: now) {
            applyDataPolicy(pending, now: now)
        }
        guard announcesAdaptive else {
            replan(now: now)
            return
        }
        if let inputs, let configuration = configuration(for: inputs) {
            if var controller {
                if controller.configuration != configuration {
                    let decision = controller.reconfigure(configuration, now: now)
                    self.controller = controller
                    note(decision, now: now)
                }
            } else {
                let created = AdaptiveStreamingController(configuration: configuration, generation: generation,
                                                          routeEpoch: routeEpoch, dataPolicy: appliedDataPolicy)
                controller = created
                note(created.initialDecision(), now: now)
            }
        }
        if var controller {
            let decision: AdaptiveStreamingDecision
            if let telemetry = pendingTelemetry {
                decision = controller.ingest(sample(window: window, telemetry: telemetry,
                                                    mode: controller.configuration.mode, now: now))
                pendingTelemetry = nil
            } else {
                decision = controller.tick(now: now)
            }
            self.controller = controller
            note(decision, now: now)
        }
        replan(now: now)
    }

    // MARK: Internals

    private func configuration(for inputs: Inputs) -> AdaptiveStreamingController.Configuration? {
        lock.lock()
        let native = nativeSize
        let source = sourceRefreshValue
        lock.unlock()
        guard let native, native.width > 0, native.height > 0 else { return nil }
        let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
            mode: inputs.mode, profile: inputs.profile, customFPS: inputs.customFPS, sourceRefreshHz: source,
            receiverMaxFPS: inputs.receiverMaxFPS, receiverEffectiveRefreshHz: hello?.effectiveRefreshHz,
            userMaxFPS: inputs.userMaxFPS, encodeWidth: native.width, encodeHeight: native.height,
            codec: inputs.codec))
        var ladder = AdaptiveStreamingLadder.standard
        if inputs.mode == .window {
            // Window view composes into a fixed canvas: raster is not a
            // dimension there (bitrate and FPS only).
            ladder.rasterSteps = [1.0]
            ladder.saverRasterTop = 1.0
        }
        return AdaptiveStreamingController.Configuration(
            streamingMode: streamingMode, mode: inputs.mode, negotiation: negotiation,
            nativeEncodeWidth: native.width, nativeEncodeHeight: native.height, receiver: inputs.receiver,
            receiverTelemetryAvailable: hello?.telemetry == true, ladder: ladder)
    }

    private func sample(window: SenderWindow, telemetry: AdaptiveReceiverTelemetry,
                        mode: RefreshNegotiation.DisplayMode, now: TimeInterval) -> AdaptiveStreamingSample {
        let seconds = max(now - window.start, 0.001)
        var s = AdaptiveStreamingSample(generation: generation, routeEpoch: routeEpoch, mode: mode,
                                        windowStart: window.start, windowEnd: now)
        let captured = Double(window.capturedFrames) / seconds
        s.sourceUniqueFPS = captured
        s.captureFPS = captured
        s.encodedFPS = Double(sentFrames) / seconds
        s.deliveredFPS = telemetry.deliveredFPS
        s.decodedFPS = telemetry.decodedFPS
        s.enqueuedFPS = telemetry.enqueuedFPS
        s.decodeTimeP95Ms = telemetry.decodeP95Ms
        s.presentationQueueAgeMs = telemetry.presentationAgeMs
        s.drops = AdaptiveStreamingSample.Drops(encoder: window.encoderDrops, network: window.networkDrops,
                                                receiverLate: telemetry.lateDrops ?? 0)
        s.rttMs = telemetry.rttMs
        s.jitterMs = telemetry.jitterMs
        // Share of the frames that reached the send gate and found it full.
        s.sendBackpressure = Double(window.networkDrops) / Double(max(window.networkDrops + sentFrames, 1))
        s.payloadBytesPerSecond = Double(sentBytes) / seconds
        s.senderThermal = window.thermal
        s.receiverThermal = telemetry.thermal
        s.power = window.lowPower || telemetry.lowPower == true ? .lowPower : .normal
        s.dataPolicy = appliedDataPolicy
        return s
    }

    private func updateDataPolicy(now: TimeInterval) {
        // Mac-side evidence: only the Mac's own Low Data Mode counts.
        let sender = senderCost.map(NetworkCost.macSidePolicyEvidence) ?? .unknown
        let path = NetworkCost.combine(sender: sender, receiver: hello?.cost ?? .unknown)
        dataPolicy = NetworkCost.receiverDataPolicy(path: path, preference: hello?.saveData,
                                                    answer: hello?.saveDataAnswer)
        requestDataPolicy(dataPolicy.policy, now: now)
    }

    /// Applies a policy change now, or (restart-class and inside the
    /// restart limit) keeps it pending until `tick` finds the limit elapsed.
    private func requestDataPolicy(_ policy: NetworkCost.DataPolicy, now: TimeInterval) {
        guard policy != appliedDataPolicy else {
            if pendingDataPolicy != nil { log("adaptive: pending data policy cancelled (back to \(policy.rawValue))") }
            pendingDataPolicy = nil
            return
        }
        if policyChangeRestartsCapture(to: policy, now: now), !restartAllowed(now: now) {
            if pendingDataPolicy != policy {
                log("adaptive: data policy \(policy.rawValue) deferred by the restart limit")
            }
            pendingDataPolicy = policy
            return
        }
        applyDataPolicy(policy, now: now)
    }

    /// The controller keeps its history (restart time, backoffs): it is
    /// told the policy, never replaced.
    private func applyDataPolicy(_ policy: NetworkCost.DataPolicy, now: TimeInterval) {
        pendingDataPolicy = nil
        appliedDataPolicy = policy
        guard var controller else { return }
        let decision = controller.setDataPolicy(policy, now: now)
        self.controller = controller
        note(decision, now: now)
    }

    private func restartAllowed(now: TimeInterval) -> Bool {
        guard let lastRestartAt else { return true }
        return now - lastRestartAt >= Self.policyRestartIntervalSeconds
    }

    /// Whether running `policy` would change the raster of a live capture.
    private func policyChangeRestartsCapture(to policy: NetworkCost.DataPolicy, now: TimeInterval) -> Bool {
        guard captureStarted else { return false }
        var decision: AdaptiveStreamingDecision?
        if var copy = controller {
            decision = copy.setDataPolicy(policy, now: now)
        }
        let candidate = AdaptiveStreamingPlanner.plan(
            streamingMode: streamingMode, adaptiveEnabled: announcesAdaptive, dataPolicy: policy,
            decision: decision, mode: displayMode)
        return AdaptiveStreamingPlanner.applyPath(from: plan, to: candidate) == .captureRestart
    }

    private func note(_ decision: AdaptiveStreamingDecision, now: TimeInterval) {
        lastDecision = decision
        guard let recorder, recorder.isEnabled else {
            lastRecordedReason = decision.reason
            return
        }
        if decision.isChange || decision.reason != lastRecordedReason {
            recorder.recordAdaptiveDecision(StreamDiagnosticsAdaptiveDecision(decision, atMs: StreamDiagnosticsClock.nowMs()))
        }
        lastRecordedReason = decision.reason
    }

    private func replan(now: TimeInterval) {
        let managed = controller == nil ? nil : lastDecision
        let newPlan = AdaptiveStreamingPlanner.plan(
            streamingMode: streamingMode, adaptiveEnabled: announcesAdaptive, dataPolicy: appliedDataPolicy,
            decision: managed, mode: displayMode)
        monitor.update(plan: newPlan, dataPolicy: appliedDataPolicy, lastReason: lastDecision?.reason)
        lock.lock()
        let oldPlan = planValue
        guard newPlan != oldPlan else {
            lock.unlock()
            return
        }
        planValue = newPlan
        lock.unlock()
        let path = AdaptiveStreamingPlanner.applyPath(from: oldPlan, to: newPlan)
        if path == .captureRestart, captureStarted { lastRestartAt = now }
        let reason = lastDecision.map { "\($0.action.rawValue)/\($0.reason.rawValue) cause=\($0.cause.rawValue)" } ?? "-"
        log("adaptive: \(oldPlan.map(String.init(describing:)) ?? "today") → \(newPlan.map(String.init(describing:)) ?? "today") "
            + "path=\(path.rawValue) decision=\(reason) data=\(appliedDataPolicy.rawValue) "
            + "evidence=\(dataPolicy.policy.rawValue)/\(dataPolicy.reason.rawValue)")
        if path != .none { applier?.adaptiveApply(path) }
    }
}

/// Who may tear down and rebuild a sender's capture (one at a time), and
/// what runs next (#123 F3). User-driven geometry (an Extend rotation or
/// shape change, a recovery rebuild) always wins over adaptive tuning: a
/// geometry request that arrives while an adaptive raster restart holds the
/// pipeline is queued and runs as soon as it finishes, never dropped; an
/// adaptive restart that arrives while anything holds it waits, and runs
/// only after every queued geometry rebuild. Pure value type: the sender
/// keeps one on `queue`.
struct CaptureRebuildArbiter: Equatable, Sendable {
    enum Owner: Equatable, Sendable {
        case geometry
        case adaptiveRaster
    }

    enum Next: Equatable, Sendable {
        case none
        /// Run the geometry reconfigure for the latest hello.
        case geometry
        /// Run the deferred adaptive raster restart (if still needed).
        case adaptiveRaster
    }

    private(set) var owner: Owner?
    private(set) var pendingGeometry = false
    private(set) var pendingAdaptiveRaster = false
    /// `finish` handed the pipeline to the queued owner, which has not
    /// started yet: its own request takes it (nothing can jump in between),
    /// except that geometry may still take an adaptive turn.
    private(set) var reserved = false

    var isBusy: Bool { owner != nil }

    /// A user-driven geometry rebuild wants the pipeline. True: it owns it
    /// now. False: a geometry rebuild is already running (it loops on the
    /// latest hello itself), or it was queued behind an adaptive restart.
    mutating func requestGeometry() -> Bool {
        switch owner {
        case nil:
            owner = .geometry
            pendingGeometry = false
            return true
        case .geometry:
            guard reserved else { return false }
            reserved = false
            return true
        case .adaptiveRaster:
            if reserved {
                // The adaptive restart has not started: geometry goes first,
                // the adaptive restart waits behind it.
                owner = .geometry
                reserved = false
                pendingAdaptiveRaster = true
                return true
            }
            pendingGeometry = true
            return false
        }
    }

    /// An adaptive raster restart wants the pipeline. True: it owns it now.
    /// False: deferred until the pipeline is free and no geometry waits.
    mutating func requestAdaptiveRaster() -> Bool {
        if owner == .adaptiveRaster, reserved {
            reserved = false
            return true
        }
        guard owner == nil, !pendingGeometry else {
            pendingAdaptiveRaster = true
            return false
        }
        owner = .adaptiveRaster
        pendingAdaptiveRaster = false
        return true
    }

    /// The owner finished or gave up (also: a reserved turn that will not
    /// run). Hands the pipeline to what waits, geometry first, and returns it.
    mutating func finish() -> Next {
        owner = nil
        reserved = false
        if pendingGeometry {
            pendingGeometry = false
            owner = .geometry
            reserved = true
            return .geometry
        }
        if pendingAdaptiveRaster {
            pendingAdaptiveRaster = false
            owner = .adaptiveRaster
            reserved = true
            return .adaptiveRaster
        }
        return .none
    }
}

/// Wording for the Streaming page's per-device rows.
enum AdaptiveUsageText {
    static func payload(_ snapshot: AdaptiveStreamingMonitor.Snapshot) -> String {
        let megabytes = Double(snapshot.videoPayloadBytes) / 1_000_000
        let amount = megabytes >= 1000
            ? String(format: "%.2f GB", megabytes / 1000)
            : String(format: "%.1f MB", megabytes)
        guard let bps = snapshot.averageBitsPerSecond else { return amount }
        return amount + String(format: " · %.1f Mbit/s average", bps / 1_000_000)
    }

    /// nil while today's fixed Automatic point runs.
    static func plan(_ snapshot: AdaptiveStreamingMonitor.Snapshot) -> String? {
        guard let plan = snapshot.plan else { return nil }
        let source = plan.origin == .dataSaver ? "Saving data" : "Adaptive"
        let fps = plan.fpsCap.map { " · up to \($0) fps" } ?? ""
        return "\(source): \(Int((plan.rasterScale * 100).rounded()))% · "
            + String(format: "%.0f Mbit/s", Double(plan.bitrate) / 1_000_000) + fps
    }
}
