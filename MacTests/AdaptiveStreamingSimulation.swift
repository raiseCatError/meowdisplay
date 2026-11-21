import Foundation

// SIMULATION ONLY. A deliberately simple, deterministic plant model used to
// exercise `AdaptiveStreamingController` against scripted conditions and to
// compare it with today's fixed Automatic policy. Nothing here is hardware
// evidence: every capacity, cost and curve below is an assumption chosen to
// make the scenarios legible, not a measurement of any Mac, iPad or network.
//
// Model (one step per measurement window, default 2 s):
// - Source: produces `sourceUniqueFPS(t)` distinct frames per second (never
//   more than its refresh). The stream encodes min(target FPS, source) of them.
// - Encoder: a pixel-throughput ceiling (pixels/s). Demand above it lowers the
//   encoded rate proportionally, grows encode queue age and counts encoder
//   drops. Thermal state `critical` throttles it to 60 %.
// - Link: capacity C(t) in bits/s with base RTT and jitter. The encoder emits
//   `bitrate × motion` bits/s (motion = how much of 60 FPS is actually being
//   encoded; an idle screen costs ~10 % of the target). Demand above C drops
//   frames proportionally (the sender's pending-send cap), sets backpressure
//   and inflates RTT; jitter grows with link utilisation.
// - Receiver: frames whose jitter exceeds one frame interval are late and
//   not presented; a decoder pixel-throughput ceiling bounds decoded FPS and
//   sets decode p95 and presentation-queue age.
// - Thermal: a heat value rises with encoder utilisation above an
//   equilibrium and maps to nominal/fair/serious/critical.
// - Noise: a fixed-seed linear congruential generator adds ±3 % to capacity
//   and RTT, so runs are repeatable bit for bit.
//
// Samples: the plant's truth is turned into exactly what production has (the
// sender's ping window, its send and encode-latency counters, and the
// receiver's `stats` keys as the official receivers send them, through the
// wire encoding), and the controller's sample is built by the production
// builder `AdaptiveStreamingCoordinator.makeSample`. So the simulation can't
// feed the controller a field production never sets (#123 A1). Receivers on
// the default display-layer path send no `dec95`; a scenario can opt into it
// (the Metal path).
//
// Metrics: delivered unique FPS = presented frames that were distinct source
// frames; stall time = window × the fraction of expected unique frames that
// were not presented; bytes = delivered payload bytes (not billed bytes).

struct AdaptiveSimulationScenario {
    struct Thermal {
        var initialHeat: Double
        /// Encoder utilisation at which heat stays constant.
        var equilibriumUtilisation: Double
        /// Heat change per second per unit of utilisation above equilibrium.
        var rate: Double
    }

    var name: String
    var summary: String
    var duration: Double = 300
    var window: Double = 2
    var mode: RefreshNegotiation.DisplayMode = .extend
    var nativeWidth = 2388
    var nativeHeight = 1668
    var receiver: AdaptiveReceiverDisplay? = AdaptiveSimulationScenario.iPad11
    var receiverMaxFPS: Int? = 60
    var receiverEffectiveHz: Int? = 60
    var sourceHz = 60
    var codec: StreamCodec = .hevc
    var receiverTelemetry = true
    var capacityMbps: (Double) -> Double = { _ in 300 }
    var baseRttMs: (Double) -> Double = { _ in 4 }
    var jitterMs: (Double) -> Double = { _ in 1 }
    var sourceUniqueFPS: ((Double) -> Double)?
    var encoderMegapixelsPerSecond = 1200.0
    var decoderMegapixelsPerSecond = 1000.0
    var thermal: Thermal?
    var dataPolicy: (Double) -> NetworkCost.DataPolicy = { _ in .normal }
    var routeEpoch: (Double) -> UInt64 = { _ in 1 }
    var staleRouteCallbacks: [(time: Double, epoch: UInt64)] = []
    var telemetryPresent: (Double) -> Bool = { _ in true }
    var activePanes = 1
    var floatingPanes = 0
    var noiseSeed: UInt64 = 1
    /// The receiver reports decode p95 (`dec95`): the Metal path only.
    var receiverSendsDecodeP95 = false

    static let iPad11 = AdaptiveReceiverDisplay(pointsWide: 1194, pointsHigh: 834, scale: 2, sizeClass: .tablet)
    static let iPhone = AdaptiveReceiverDisplay(pointsWide: 852, pointsHigh: 393, scale: 3, sizeClass: .phone)

    var negotiationInput: RefreshNegotiation.Input {
        RefreshNegotiation.Input(mode: mode, sourceRefreshHz: sourceHz, receiverMaxFPS: receiverMaxFPS,
                                 receiverEffectiveRefreshHz: receiverEffectiveHz,
                                 encodeWidth: nativeWidth, encodeHeight: nativeHeight, codec: codec)
    }

    var negotiation: RefreshNegotiation.Result { RefreshNegotiation.negotiate(negotiationInput) }

    var controllerConfiguration: AdaptiveStreamingController.Configuration {
        AdaptiveStreamingController.Configuration(
            mode: mode, negotiation: negotiation, nativeEncodeWidth: nativeWidth, nativeEncodeHeight: nativeHeight,
            receiver: receiver, receiverTelemetryAvailable: receiverTelemetry)
    }
}

struct AdaptiveSimulationMetrics: Equatable {
    var deliveredUniqueFPS = 0.0
    var stallSeconds = 0.0
    var megabytes = 0.0
    var meanRaster = 0.0
    var secondsAbove60 = 0.0
    var secondsBelowFloor = 0.0
    var changes = 0
    var restartClassChanges = 0
    var flips = 0
    var finalPoint = AdaptiveOperatingPoint(rasterScale: 1, bitrate: 0, fps: 0)
}

struct AdaptiveSimulationRun {
    var metrics: AdaptiveSimulationMetrics
    var decisions: [AdaptiveStreamingDecision]
    /// Adaptation changes (downshift/upshift/probeRevert) per window.
    var adaptationChangesPerWindow: [Int]
    var points: [AdaptiveOperatingPoint]
}

/// Fixed-seed linear congruential generator.
struct AdaptiveSimulationNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    /// Uniform in [-1, 1].
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

enum AdaptiveSimulationPolicy: String {
    case adaptive
    case fixed
}

struct AdaptiveSimulationPlant {
    let scenario: AdaptiveSimulationScenario
    private var noise: AdaptiveSimulationNoise
    private(set) var heat: Double

    init(scenario: AdaptiveSimulationScenario) {
        self.scenario = scenario
        noise = AdaptiveSimulationNoise(seed: scenario.noiseSeed)
        heat = scenario.thermal?.initialHeat ?? 0
    }

    struct Outcome {
        var sample: AdaptiveStreamingSample
        var presentedUniqueFPS: Double
        var expectedUniqueFPS: Double
        var bytes: Double
    }

    static func thermalLevel(heat: Double) -> AdaptiveThermalLevel {
        switch heat {
        case ..<0.4: return .nominal
        case ..<0.6: return .fair
        case ..<0.8: return .serious
        default: return .critical
        }
    }

    mutating func step(point: AdaptiveOperatingPoint, start: Double, generation: UInt64,
                       dataPolicy: NetworkCost.DataPolicy) -> Outcome {
        let s = scenario
        let window = s.window
        let raster = point.raster(nativeWidth: s.nativeWidth, nativeHeight: s.nativeHeight)
        let pixels = Double(raster.width * raster.height)
        let sourceFPS = min(Double(s.sourceHz), s.sourceUniqueFPS?(start) ?? Double(s.sourceHz))
        let wanted = min(Double(point.fps), sourceFPS)
        let thermalLevel = s.thermal.map { _ in Self.thermalLevel(heat: heat) }

        // Encoder
        let throttle = thermalLevel == .critical ? 0.6 : 1.0
        let encoderCapacity = s.encoderMegapixelsPerSecond * 1_000_000 * throttle
        let encoderUtilisation = wanted * pixels / encoderCapacity
        let encoded = encoderUtilisation > 1 ? wanted / encoderUtilisation : wanted
        let encodeMs = pixels / encoderCapacity * 1000
        let encodeQueueAge = encoderUtilisation < 0.95
            ? encodeMs * (1 + encoderUtilisation)
            : min(500, encodeMs * (2 + 20 * (encoderUtilisation - 0.95)))
        let encoderDrops = max(0, wanted - encoded) * window

        // Link
        let capacityNoise = 1 + 0.03 * noise.next()
        let rttNoise = 1 + 0.03 * noise.next()
        let capacity = s.capacityMbps(start) * 1_000_000 * capacityNoise
        let motion = min(1, 0.1 + 0.9 * encoded / 60)
        let demand = Double(point.bitrate) * motion
        let loss = demand > capacity ? 1 - capacity / demand : 0
        let delivered = encoded * (1 - loss)
        let utilisation = min(demand / capacity, 1)
        let rtt = (s.baseRttMs(start) + 2 + utilisation * utilisation * 20 + (loss > 0 ? 80 + 300 * loss : 0)) * rttNoise
        let jitter = s.jitterMs(start) * (0.5 + 0.5 * utilisation) + (loss > 0 ? 20 : 0)
        let intervalMs = 1000 / Double(max(point.fps, 1))
        let lateFraction = jitter > intervalMs ? min(0.5, (jitter - intervalMs) / (4 * intervalMs)) : 0

        // Receiver
        let decoderCapacity = s.decoderMegapixelsPerSecond * 1_000_000
        let decoderUtilisation = delivered * pixels / decoderCapacity
        let decoded = decoderUtilisation > 1 ? delivered / decoderUtilisation : delivered
        let decodeMs = pixels / decoderCapacity * 1000
        let decodeP95 = decodeMs * 1.3 * (decoderUtilisation > 0.9 ? 1.5 : 1)
        let presented = decoded * (1 - lateFraction)

        // Thermal
        if let thermal = s.thermal {
            heat = min(1, max(0, heat + thermal.rate * (min(encoderUtilisation, 1) - thermal.equilibriumUtilisation) * window))
        }

        // What production sees. Sender: its ping window and send counters
        // (frames that found the send gate full are network drops, the rest
        // are sent) and the mean encode latency. Receiver: `stats` keys as
        // the official receivers send them, through the wire encoding;
        // `deliveredFps` counts frames reaching the presentation hand-off
        // (decoded), and there is no `late`, `decodedFps`, `enqFps` or
        // `presAge` yet.
        let networkDrops = Int((encoded * loss * window).rounded())
        let sentFrames = Int((encoded * (1 - loss) * window).rounded())
        let senderWindow = AdaptiveStreamingCoordinator.SenderWindow(
            start: start, end: start + window, capturedFrames: Int((wanted * window).rounded()),
            encoderDrops: Int(encoderDrops.rounded()), networkDrops: networkDrops,
            thermal: thermalLevel ?? .nominal, lowPower: false,
            encodeLatencyMs: encoded > 0 ? encodeQueueAge : nil)
        var receiverTelemetry = AdaptiveReceiverTelemetry(windowSeconds: window)
        receiverTelemetry.deliveredFPS = decoded
        receiverTelemetry.decodeP95Ms = s.receiverSendsDecodeP95 ? decodeP95 : nil
        receiverTelemetry.jitterMs = jitter
        receiverTelemetry.thermal = .nominal
        receiverTelemetry.lowPower = false
        var statsKeys = receiverTelemetry.wireFields
        statsKeys[AdaptiveStreamingWire.rttKey] = rtt.rounded()
        let parsed = AdaptiveReceiverTelemetry.parse(statsKeys) ?? receiverTelemetry
        let sample = AdaptiveStreamingCoordinator.makeSample(
            generation: generation, routeEpoch: s.routeEpoch(start), mode: s.mode, window: senderWindow,
            sentFrames: sentFrames, sentBytes: Int((min(demand, capacity) / 8 * window).rounded()),
            telemetry: parsed, dataPolicy: dataPolicy, now: start + window)
        // Window view pane counts are not fed in production, so the
        // scenario's panes never reach the controller here either.
        return Outcome(sample: sample, presentedUniqueFPS: presented, expectedUniqueFPS: wanted,
                       bytes: min(demand, capacity) / 8 * window)
    }
}

enum AdaptiveSimulation {
    static func run(_ scenario: AdaptiveSimulationScenario, policy: AdaptiveSimulationPolicy) -> AdaptiveSimulationRun {
        var runner = Runner(scenario: scenario, policy: policy)
        while !runner.isFinished { runner.advance() }
        return runner.finish()
    }

    /// Two receivers stepped in lockstep, each with its own controller and
    /// plant. Used to show isolation: each result must equal its solo run.
    static func runPair(_ a: AdaptiveSimulationScenario, _ b: AdaptiveSimulationScenario)
        -> (AdaptiveSimulationRun, AdaptiveSimulationRun) {
        var first = Runner(scenario: a, policy: .adaptive)
        var second = Runner(scenario: b, policy: .adaptive)
        while !first.isFinished || !second.isFinished {
            if !first.isFinished { first.advance() }
            if !second.isFinished { second.advance() }
        }
        return (first.finish(), second.finish())
    }

    struct Runner {
        let scenario: AdaptiveSimulationScenario
        let policy: AdaptiveSimulationPolicy
        private var plant: AdaptiveSimulationPlant
        private var controller: AdaptiveStreamingController
        private var point: AdaptiveOperatingPoint
        private var time = 0.0
        private var epoch: UInt64
        private var staleIndex = 0
        private var decisions: [AdaptiveStreamingDecision] = []
        private var perWindow: [Int] = []
        private var points: [AdaptiveOperatingPoint] = []
        private var metrics = AdaptiveSimulationMetrics()
        private var presentedFrames = 0.0
        private var rasterTime = 0.0
        private var lastDirection: Int?

        init(scenario: AdaptiveSimulationScenario, policy: AdaptiveSimulationPolicy) {
            self.scenario = scenario
            self.policy = policy
            plant = AdaptiveSimulationPlant(scenario: scenario)
            epoch = scenario.routeEpoch(0)
            controller = AdaptiveStreamingController(configuration: scenario.controllerConfiguration, generation: 1,
                                                     routeEpoch: epoch, dataPolicy: scenario.dataPolicy(0))
            switch policy {
            case .adaptive:
                let initial = controller.initialDecision()
                decisions.append(initial)
                point = initial.point ?? AdaptiveStreamingController.fixedAutomaticPoint(scenario.negotiation)
            case .fixed:
                point = AdaptiveStreamingController.fixedAutomaticPoint(scenario.negotiation)
            }
        }

        var isFinished: Bool { time >= scenario.duration - 1e-9 }

        mutating func advance() {
            let start = time
            let end = start + scenario.window
            var adaptationChanges = 0

            if policy == .adaptive {
                let currentEpoch = scenario.routeEpoch(start)
                if currentEpoch != epoch {
                    epoch = currentEpoch
                    record(controller.routeDidChange(epoch: currentEpoch, now: start), &adaptationChanges)
                }
                while staleIndex < scenario.staleRouteCallbacks.count,
                      scenario.staleRouteCallbacks[staleIndex].time < end {
                    let callback = scenario.staleRouteCallbacks[staleIndex]
                    record(controller.routeDidChange(epoch: callback.epoch, now: callback.time), &adaptationChanges)
                    staleIndex += 1
                }
            }

            let outcome = plant.step(point: point, start: start, generation: 1, dataPolicy: scenario.dataPolicy(start))
            presentedFrames += outcome.presentedUniqueFPS * scenario.window
            metrics.stallSeconds += outcome.expectedUniqueFPS > 0
                ? scenario.window * max(0, 1 - outcome.presentedUniqueFPS / outcome.expectedUniqueFPS) : 0
            metrics.megabytes += outcome.bytes / 1_000_000
            rasterTime += point.rasterScale * scenario.window
            if point.fps > 60 { metrics.secondsAbove60 += scenario.window }
            if policy == .adaptive, point.rasterScale < controller.rasterFloor - 1e-9 {
                metrics.secondsBelowFloor += scenario.window
            }
            points.append(point)

            if policy == .adaptive {
                let decision = scenario.telemetryPresent(start)
                    ? controller.ingest(outcome.sample)
                    : controller.tick(now: end)
                record(decision, &adaptationChanges)
            }
            perWindow.append(adaptationChanges)
            time = end
        }

        private mutating func record(_ decision: AdaptiveStreamingDecision, _ adaptationChanges: inout Int) {
            decisions.append(decision)
            guard decision.isChange, let next = decision.point else { return }
            if [.downshift, .upshift, .probeRevert].contains(decision.action) { adaptationChanges += 1 }
            metrics.changes += 1
            if decision.cost == .captureRestart { metrics.restartClassChanges += 1 }
            let direction = Self.direction(from: point, to: next)
            if let direction {
                if let last = lastDirection, last != direction { metrics.flips += 1 }
                lastDirection = direction
            }
            point = next
        }

        /// +1 when every dimension moved up or held, -1 when any moved down.
        private static func direction(from a: AdaptiveOperatingPoint, to b: AdaptiveOperatingPoint) -> Int? {
            if b.rasterScale < a.rasterScale - 1e-9 || b.bitrate < a.bitrate || b.fps < a.fps { return -1 }
            if b.rasterScale > a.rasterScale + 1e-9 || b.bitrate > a.bitrate || b.fps > a.fps { return 1 }
            return nil
        }

        mutating func finish() -> AdaptiveSimulationRun {
            metrics.deliveredUniqueFPS = presentedFrames / max(time, 1e-9)
            metrics.meanRaster = rasterTime / max(time, 1e-9)
            metrics.finalPoint = point
            return AdaptiveSimulationRun(metrics: metrics, decisions: decisions,
                                         adaptationChangesPerWindow: perWindow, points: points)
        }
    }
}

// MARK: - Scripted scenarios

extension AdaptiveSimulationScenario {
    static var all: [AdaptiveSimulationScenario] {
        [healthyLAN60, proMotion120WithHeadroom, advertised120Source60, bandwidthCollapse, jitteryRemote,
         meteredPath, encoderLimitedMac, decoderLimitedReceiver, decoderLimitedMetalReceiver, thermalRamp, idleToMotion,
         windowViewMultiPane, routeFlap, telemetryDropout]
    }

    static var healthyLAN60: Self {
        Self(name: "Healthy LAN 60 Hz", summary: "iPad 60 Hz, Extend, 300 Mbps, 4 ms RTT")
    }

    static var proMotion120WithHeadroom: Self {
        var s = Self(name: "120 Hz source + ProMotion, headroom",
                     summary: "Extend at 120 Hz to a 120 Hz receiver, ample encoder/decoder/link")
        s.receiverMaxFPS = 120
        s.receiverEffectiveHz = 120
        s.sourceHz = 120
        s.encoderMegapixelsPerSecond = 1500
        s.decoderMegapixelsPerSecond = 1500
        return s
    }

    static var advertised120Source60: Self {
        var s = Self(name: "120 advertised, 60 Hz source",
                     summary: "Mirror of a 60 Hz 1512x982 pt Mac display to a 120 Hz receiver")
        s.mode = .mirror
        s.nativeWidth = 3024
        s.nativeHeight = 1964
        s.receiverMaxFPS = 120
        s.receiverEffectiveHz = 120
        s.sourceHz = 60
        return s
    }

    static var bandwidthCollapse: Self {
        var s = Self(name: "Bandwidth collapse and recovery", summary: "300 Mbps, 8 Mbps from 80-180 s, then 300 Mbps")
        s.capacityMbps = { $0 >= 80 && $0 < 180 ? 8 : 300 }
        return s
    }

    static var jitteryRemote: Self {
        var s = Self(name: "Jittery remote", summary: "Tailscale-style path: 40 Mbps, 45 ms RTT, 40 ms jitter")
        s.capacityMbps = { _ in 40 }
        s.baseRttMs = { _ in 45 }
        s.jitterMs = { _ in 40 }
        s.noiseSeed = 7
        return s
    }

    static var meteredPath: Self {
        var s = Self(name: "Metered path (saver)", summary: "iPhone on cellular: 12 Mbps, 60 ms RTT, auto data saver")
        s.receiver = iPhone
        s.nativeWidth = 1704
        s.nativeHeight = 786
        s.capacityMbps = { _ in 12 }
        s.baseRttMs = { _ in 60 }
        s.jitterMs = { _ in 8 }
        s.dataPolicy = { _ in meteredPolicy }
        s.noiseSeed = 3
        return s
    }

    /// The policy `NetworkCost` picks for a receiver that clearly reports
    /// an expensive cellular path, with the default "Use less data: auto".
    static var meteredPolicy: NetworkCost.DataPolicy {
        let path = NetworkCost.combine(
            sender: NetworkCost.EndpointReport(reachability: .remote, interface: .wifi,
                                               cost: .init(cost: .unmetered, confidence: .high)),
            receiver: NetworkCost.EndpointReport(reachability: .remote, interface: .cellular,
                                                 cost: .init(cost: .expensive, confidence: .high)))
        return NetworkCost.dataPolicy(path: path, preference: .auto, answer: .unanswered).policy
    }

    static var encoderLimitedMac: Self {
        var s = Self(name: "Encoder-limited Mac", summary: "Encoder ceiling 180 Mpx/s (native 60 needs 240)")
        s.encoderMegapixelsPerSecond = 180
        return s
    }

    static var decoderLimitedReceiver: Self {
        var s = Self(name: "Decoder-limited old receiver", summary: "Decoder ceiling 150 Mpx/s (native 60 needs 240)")
        s.decoderMegapixelsPerSecond = 150
        return s
    }

    /// The same receiver on the Metal path, which reports `dec95`.
    static var decoderLimitedMetalReceiver: Self {
        var s = decoderLimitedReceiver
        s.name = "Decoder-limited old receiver (Metal path)"
        s.summary = "As above, but the receiver reports decode p95 (dec95)"
        s.receiverSendsDecodeP95 = true
        return s
    }

    static var thermalRamp: Self {
        var s = Self(name: "Thermal ramp", summary: "Sender heats with encoder load; critical throttles the encoder")
        s.encoderMegapixelsPerSecond = 450
        s.thermal = Thermal(initialHeat: 0.35, equilibriumUtilisation: 0.25, rate: 0.006)
        return s
    }

    static var idleToMotion: Self {
        var s = Self(name: "Idle to motion", summary: "1 fps idle to 100 s, 12 fps typing to 200 s, then full motion")
        s.sourceUniqueFPS = { $0 < 100 ? 1 : ($0 < 200 ? 12 : 60) }
        s.capacityMbps = { _ in 300 }
        return s
    }

    static var windowViewMultiPane: Self {
        var s = Self(name: "Window View multi-pane",
                     summary: "4 panes + 1 float, 60 fps composition budget, 120 Hz receiver")
        s.mode = .window
        s.receiverMaxFPS = 120
        s.receiverEffectiveHz = 120
        s.sourceHz = 60
        s.activePanes = 4
        s.floatingPanes = 1
        s.encoderMegapixelsPerSecond = 900
        return s
    }

    static var routeFlap: Self {
        var s = Self(name: "Route flap",
                     summary: "iPhone Wi-Fi to cellular at 100 s, back at 160 s; stale callbacks at 104 s and 166 s")
        s.receiver = iPhone
        s.nativeWidth = 1704
        s.nativeHeight = 786
        s.routeEpoch = { $0 < 100 ? 1 : ($0 < 160 ? 2 : 3) }
        s.staleRouteCallbacks = [(104, 1), (166, 2)]
        s.capacityMbps = { $0 >= 100 && $0 < 160 ? 10 : 200 }
        s.baseRttMs = { $0 >= 100 && $0 < 160 ? 60 : 5 }
        s.dataPolicy = { $0 >= 100 && $0 < 160 ? meteredPolicy : .normal }
        s.noiseSeed = 5
        return s
    }

    static var telemetryDropout: Self {
        var s = Self(name: "Telemetry dropout", summary: "No samples 100-140 s while the link drops to 10 Mbps (110-140 s)")
        s.telemetryPresent = { !($0 >= 100 && $0 < 140) }
        s.capacityMbps = { $0 >= 110 && $0 < 170 ? 10 : 300 }
        return s
    }

    /// Two receivers on one Mac: a healthy LAN iPad and a congested iPhone.
    static var twoReceivers: (Self, Self) {
        var b = bandwidthCollapse
        b.name = "Two receivers: B (iPhone, collapse)"
        b.receiver = iPhone
        b.nativeWidth = 1704
        b.nativeHeight = 786
        b.noiseSeed = 11
        var a = healthyLAN60
        a.name = "Two receivers: A (iPad, healthy)"
        return (a, b)
    }
}
