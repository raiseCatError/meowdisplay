import XCTest

/// #123 review A (QA 94fdc717): the adaptive controller recovers on the
/// evidence production really has (A1), one restart limiter per receiver
/// whatever asks (A3/A8), raster steps against the true size before the
/// decode ceiling (A4), the started size checked against the plan (A5), the
/// legacy FPS at the real call site (A6), lock-screen deferral (A7),
/// coalesced re-hellos (A9) and a switch-off state that does no work. No
/// capture or encoder runs: the sender side is a recording fake.
final class AdaptiveStreamingRecoveryTests: XCTestCase {
    private final class RecordingApplier: AdaptiveStreamingApplying {
        var now = 0.0
        /// The plan the coordinator runs when it applies (set it to record rasters).
        var plan: (() -> AdaptiveStreamingPlan?)?
        var applied: [(time: Double, path: AdaptiveApplyPath)] = []
        var rasters: [Double] = []
        func adaptiveApply(_ path: AdaptiveApplyPath) {
            applied.append((now, path))
            rasters.append(plan?()?.rasterScale ?? 1)
        }
        func times(_ path: AdaptiveApplyPath) -> [Double] { applied.filter { $0.path == path }.map(\.time) }
    }

    private let iPad = AdaptiveReceiverDisplay(pointsWide: 1366, pointsHigh: 1024, scale: 2, sizeClass: .tablet)
    private let iPadSizing = AdaptiveCaptureSizing(sourceWidth: 2732, sourceHeight: 2048, todayScale: 1,
                                                   maxWide: nil, maxHigh: nil)

    private func inputs(mode: RefreshNegotiation.DisplayMode = .extend, receiverMax: Int = 60,
                        codec: StreamCodec = .hevc) -> AdaptiveStreamingCoordinator.Inputs {
        AdaptiveStreamingCoordinator.Inputs(mode: mode, profile: .performance, customFPS: nil,
                                            receiverMaxFPS: receiverMax, userMaxFPS: nil, codec: codec, receiver: iPad)
    }

    private func telemetryHello(hz: Int = 60, saveData: NetworkCost.DataPreference? = .auto) -> AdaptiveHelloFields {
        AdaptiveHelloFields(effectiveRefreshHz: hz, telemetry: true, cost: nil, saveData: saveData, saveDataAnswer: nil)
    }

    /// A receiver `stats` message with exactly the keys the official
    /// receivers send on the default display-layer path (no `dec95`),
    /// through real JSON.
    private func realStats(delivered: Double, rtt: Double = 8, jitter: Double = 1,
                           thermal: AdaptiveThermalLevel = .nominal, dec95: Double? = nil) throws -> [String: Any] {
        var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
        t.deliveredFPS = delivered
        t.decodeP95Ms = dec95
        t.jitterMs = jitter
        t.thermal = thermal
        t.lowPower = false
        var keys = t.wireFields
        keys["type"] = "stats"
        keys["rtt"] = rtt
        let data = try JSONSerialization.data(withJSONObject: keys)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func managed(sourceHz: Int = 60, hello: AdaptiveHelloFields? = nil,
                         sizing: AdaptiveCaptureSizing? = nil, started: (Int, Int) = (2732, 2048),
                         inputs makeInputs: AdaptiveStreamingCoordinator.Inputs? = nil)
        -> (AdaptiveStreamingCoordinator, RecordingApplier) {
        let coordinator = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .automatic, displayMode: .extend)
        let fake = RecordingApplier()
        coordinator.applier = fake
        coordinator.setSourceRefresh(sourceHz)
        coordinator.noteCaptureStarted(sizing: sizing ?? iPadSizing, width: started.0, height: started.1)
        coordinator.helloAccepted(hello ?? telemetryHello(), now: 0)
        fake.now = 2
        coordinator.tick(generation: 1, inputs: makeInputs ?? inputs(), window: window(0, 2), now: 2)
        return (coordinator, fake)
    }

    private func window(_ start: Double, _ end: Double, captured: Int = 120, encDrops: Int = 0, netDrops: Int = 0,
                        encodeLatencyMs: Double? = 5) -> AdaptiveStreamingCoordinator.SenderWindow {
        AdaptiveStreamingCoordinator.SenderWindow(start: start, end: end, capturedFrames: captured,
                                                  encoderDrops: encDrops, networkDrops: netDrops,
                                                  thermal: .nominal, lowPower: false, encodeLatencyMs: encodeLatencyMs)
    }

    /// One 2 s window ending at `end`, fed the way `MacSender` feeds it.
    private func feed(_ c: AdaptiveStreamingCoordinator, _ fake: RecordingApplier, end: Double,
                      generation: UInt64 = 1, sent: Int, captured: Int = 120, netDrops: Int = 0,
                      stats: [String: Any], inputs makeInputs: AdaptiveStreamingCoordinator.Inputs? = nil) {
        fake.now = end
        for _ in 0..<sent { c.noteVideoSent(bytes: 30_000, now: end - 1) }
        c.receiverStats(json: stats)
        c.tick(generation: generation, mode: .extend, inputs: makeInputs ?? inputs(),
               window: window(end - 2, end, captured: captured, netDrops: netDrops), now: end)
    }

    private func congest(_ c: AdaptiveStreamingCoordinator, _ fake: RecordingApplier, from: inout Double,
                         until done: (AdaptiveStreamingCoordinator) -> Bool) throws {
        var guardCount = 0
        while !done(c), guardCount < 100 {
            from += 2
            feed(c, fake, end: from, sent: 100, netDrops: 20, stats: try realStats(delivered: 50, rtt: 80))
            guardCount += 1
        }
        XCTAssertTrue(done(c), "congestion never reached the expected point")
    }

    // MARK: - A1: the sample production builds

    func testEverySampleFieldTheControllerReliesOnIsSetByTheProductionBuilder() throws {
        let telemetry = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try realStats(delivered: 58)))
        let sample = AdaptiveStreamingCoordinator.makeSample(
            generation: 3, routeEpoch: 2, mode: .extend, window: window(10, 12, encodeLatencyMs: 6),
            sentFrames: 118, sentBytes: 3_000_000, telemetry: telemetry, dataPolicy: .normal, now: 12)
        let manifest = AdaptiveStreamingSample.controllerFieldUse
        let children = Mirror(reflecting: sample).children.compactMap { child -> (String, Any)? in
            child.label.map { ($0, child.value) }
        }
        XCTAssertEqual(Set(children.map(\.0)), Set(manifest.keys),
                       "every sample field is classified: a new field must say who sets it or what its fallback is")
        for (label, value) in children {
            guard manifest[label] == .setByProduction else { continue }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                XCTAssertFalse(mirror.children.isEmpty, "\(label) is relied on but the production builder leaves it nil")
            }
        }
        // The sender's measured encode latency reaches the controller (it
        // never did before #123 A1), and the receiver's real keys arrive.
        XCTAssertEqual(sample.encodeQueueAgeMs, 6)
        XCTAssertEqual(sample.deliveredFPS, 58)
        XCTAssertEqual(sample.rttMs, 8)
        XCTAssertNil(sample.decodeTimeP95Ms, "the display-layer path sends no dec95: an explicit unknown")
        XCTAssertEqual(sample.sendBackpressure, 0)
    }

    func testRecoversToFullQualityAfterANetworkStepDownWithOnlyRealReceiverKeys() throws {
        let (c, fake) = managed()
        var now = 2.0
        try congest(c, fake, from: &now) { ($0.plan?.rasterScale ?? 1) < 1 }
        let rasterDownAt = now
        XCTAssertLessThan(c.plan?.bitrate ?? 0, 18_000_000)

        var firstUpshift: (time: Double, reason: AdaptiveStreamingDecision.Reason)?
        while now < rasterDownAt + 600 {
            now += 2
            feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
            if firstUpshift == nil, let d = c.lastDecision, d.action == .upshift { firstUpshift = (now, d.reason) }
            if c.plan == AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller) {
                break
            }
        }
        XCTAssertEqual(c.plan, AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller),
                       "raster and bitrate both came back")
        // A1(c): the raster can't rise inside the restart limit, so the
        // cheaper bitrate step goes first instead of holding.
        XCTAssertEqual(firstUpshift?.reason, .upshiftBitrate)
        XCTAssertLessThan(firstUpshift?.time ?? .infinity,
                          rasterDownAt + AdaptiveStreamingCoordinator.restartIntervalSeconds)
        let restarts = fake.times(.captureRestart)
        for (a, b) in zip(restarts, restarts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, AdaptiveStreamingCoordinator.restartIntervalSeconds)
        }
    }

    func testMissingDecodeEvidenceWaitsLongerButStillUpshifts() {
        func firstUpshiftDelay(decodeKnown: Bool) -> Double? {
            let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
                mode: .extend, sourceRefreshHz: 60, receiverMaxFPS: 60, receiverEffectiveRefreshHz: 60,
                encodeWidth: 2388, encodeHeight: 1668, codec: .hevc))
            var controller = AdaptiveStreamingController(configuration: .init(
                mode: .extend, negotiation: negotiation, nativeEncodeWidth: 2388, nativeEncodeHeight: 1668,
                receiver: AdaptiveReceiverDisplay(pointsWide: 1194, pointsHigh: 834, scale: 2, sizeClass: .tablet),
                receiverTelemetryAvailable: true), generation: 1, routeEpoch: 1)
            func sample(_ index: Int, fps: Double, thermal: AdaptiveThermalLevel = .nominal) -> AdaptiveStreamingSample {
                var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
                t.deliveredFPS = fps
                t.rttMs = 8
                t.jitterMs = 1
                t.thermal = thermal
                t.decodeP95Ms = decodeKnown ? 4 : nil
                let end = Double(index) * 2 + 2
                return AdaptiveStreamingCoordinator.makeSample(
                    generation: 1, routeEpoch: 1, mode: .extend,
                    // Production truth: the capture runs at the current target.
                    window: .init(start: end - 2, end: end, capturedFrames: Int(fps * 2), encoderDrops: 0,
                                  networkDrops: 0, thermal: .nominal, lowPower: false, encodeLatencyMs: 4),
                    sentFrames: Int(fps * 2), sentBytes: 2_000_000, telemetry: t, dataPolicy: .normal, now: end)
            }
            // Critical thermal clamps FPS to 30 at once; then it cools.
            let clamp = controller.ingest(sample(0, fps: 60, thermal: .critical))
            XCTAssertEqual(clamp.action, .policyClamp)
            XCTAssertEqual(clamp.point?.fps, 30)
            for index in 1..<40 {
                let decision = controller.ingest(sample(index, fps: 30))
                if decision.action == .upshift {
                    XCTAssertEqual(decision.reason, .upshiftFPS)
                    return Double(index) * 2 + 2 - 2
                }
            }
            return nil
        }
        let known = firstUpshiftDelay(decodeKnown: true)
        let unknown = firstUpshiftDelay(decodeKnown: false)
        XCTAssertNotNil(known)
        XCTAssertNotNil(unknown, "missing decode evidence must not block recovery forever")
        XCTAssertGreaterThanOrEqual(unknown ?? 0, AdaptiveStreamingThresholds.standard.minDwellSecondsWithoutPipelineEvidence)
        XCTAssertLessThan(known ?? .infinity, unknown ?? 0, "partial evidence waits longer")
    }

    func testHighRefreshIsReachedOnTheEvidenceRealReceiversSend() {
        let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
            mode: .extend, sourceRefreshHz: 120, receiverMaxFPS: 120, receiverEffectiveRefreshHz: 120,
            encodeWidth: 2388, encodeHeight: 1668, codec: .hevc))
        var controller = AdaptiveStreamingController(configuration: .init(
            mode: .extend, negotiation: negotiation, nativeEncodeWidth: 2388, nativeEncodeHeight: 1668,
            receiver: iPad, receiverTelemetryAvailable: true), generation: 1, routeEpoch: 1)
        XCTAssertEqual(controller.point.fps, 60, "60 first")
        var reached: Double?
        for index in 0..<60 where reached == nil {
            let fps = Double(controller.point.fps)
            var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
            t.deliveredFPS = fps
            t.rttMs = 6
            t.jitterMs = 1
            t.thermal = .nominal
            let end = Double(index) * 2 + 2
            let sample = AdaptiveStreamingCoordinator.makeSample(
                generation: 1, routeEpoch: 1, mode: .extend,
                // Production truth: a capture at 60 shows at most 60 source frames.
                window: .init(start: end - 2, end: end, capturedFrames: Int(fps * 2), encoderDrops: 0,
                              networkDrops: 0, thermal: .nominal, lowPower: false, encodeLatencyMs: 5),
                sentFrames: Int(fps * 2), sentBytes: 4_000_000, telemetry: t, dataPolicy: .normal, now: end)
            _ = controller.ingest(sample)
            if controller.point.fps == 120 { reached = end }
        }
        XCTAssertNotNil(reached, "90/120 is no longer unreachable without dec95")
    }

    func testAProbeThatLeavesDeliveryShortWithNoOtherCauseIsReverted() {
        let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
            mode: .extend, sourceRefreshHz: 120, receiverMaxFPS: 120, receiverEffectiveRefreshHz: 120,
            encodeWidth: 2388, encodeHeight: 1668, codec: .hevc))
        var controller = AdaptiveStreamingController(configuration: .init(
            mode: .extend, negotiation: negotiation, nativeEncodeWidth: 2388, nativeEncodeHeight: 1668,
            receiver: iPad, receiverTelemetryAvailable: true), generation: 1, routeEpoch: 1)
        func sample(_ index: Int, delivered: Double) -> AdaptiveStreamingSample {
            var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
            t.deliveredFPS = delivered
            t.rttMs = 6
            t.jitterMs = 1
            t.thermal = .nominal
            let end = Double(index) * 2 + 2
            return AdaptiveStreamingCoordinator.makeSample(
                generation: 1, routeEpoch: 1, mode: .extend,
                window: .init(start: end - 2, end: end, capturedFrames: controller.point.fps * 2, encoderDrops: 0,
                              networkDrops: 0, thermal: .nominal, lowPower: false, encodeLatencyMs: 5),
                sentFrames: Int(Double(controller.point.fps) * 2), sentBytes: 4_000_000, telemetry: t,
                dataPolicy: .normal, now: end)
        }
        var index = 0
        while controller.point.fps < 120, index < 60 {
            _ = controller.ingest(sample(index, delivered: Double(controller.point.fps)))
            index += 1
        }
        XCTAssertEqual(controller.point.fps, 120)
        // The receiver presents only 100 of 120: no drop, backpressure, RTT
        // or decode evidence, just short delivery. The probe caused it.
        let decision = controller.ingest(sample(index, delivered: 100))
        XCTAssertEqual(decision.action, .probeRevert)
        XCTAssertEqual(decision.point?.fps, 60)
    }

    func testUseLessDataOffWithTheControllerOnRestoresQuality() throws {
        let (c, fake) = managed()
        c.helloAccepted(telemetryHello(saveData: .on), now: 3)
        XCTAssertEqual(c.plan?.bitrate, AdaptiveStreamingLadder.standard.saverBitrateTop)
        XCTAssertLessThan(c.plan?.rasterScale ?? 1, 1)
        c.helloAccepted(telemetryHello(saveData: .off), now: 4)
        var now = 4.0
        while now < 600, c.plan != AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller) {
            now += 2
            feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
        }
        XCTAssertEqual(c.plan, AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller))
    }

    // MARK: - A3/A8: one limiter per receiver

    /// A hostile paired receiver alternates hellos with and without the
    /// telemetry keys before every Mac tick while reporting critical thermal
    /// state: each managed/unmanaged flip (fixed policy at raster 1.0, then a
    /// reset to the thermal-clamped point) would otherwise restart capture.
    ///
    /// #123 F2 (deliberate change): the controller's own lower raster is no
    /// longer held, so each raise can be followed by the step back down; a
    /// raise still never comes within the interval of the previous restart,
    /// so the flips get at most two restarts per interval.
    func testAHostilePeerCannotForceMoreThanOneRaisePerInterval() throws {
        let (c, fake) = managed()
        fake.plan = { [unowned c] in c.plan }
        var now = 2.0
        for round in 0..<150 {
            now += 2
            fake.now = now
            c.helloAccepted(round % 2 == 0 ? telemetryHello() : AdaptiveHelloFields(saveData: .auto), now: now)
            c.receiverStats(json: try realStats(delivered: 60, thermal: .critical))
            c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 2, now), now: now)
        }
        let restarts = fake.applied.indices.filter { fake.applied[$0].path == .captureRestart }
        XCTAssertFalse(restarts.isEmpty, "the flips do want restarts")
        var previousRaster = 1.0
        var previousTime: Double?
        var raises = 0
        for index in restarts {
            let time = fake.applied[index].time, raster = fake.rasters[index]
            if raster > previousRaster + 1e-9 {
                raises += 1
                if let previousTime {
                    XCTAssertGreaterThanOrEqual(time - previousTime, AdaptiveStreamingCoordinator.restartIntervalSeconds,
                                                "a raise inside the interval: \(restarts.map { fake.applied[$0].time })")
                }
            }
            previousRaster = raster
            previousTime = time
        }
        let intervals = Int(300 / AdaptiveStreamingCoordinator.restartIntervalSeconds) + 1
        XCTAssertLessThanOrEqual(raises, intervals)
        XCTAssertLessThanOrEqual(restarts.count, 2 * intervals)
    }

    func testAResetOnReconnectWaitsForTheRestartInterval() throws {
        let (c, fake) = managed()
        var now = 2.0
        try congest(c, fake, from: &now) { ($0.plan?.rasterScale ?? 1) < 1 }
        let rasterDownAt = now
        XCTAssertEqual(fake.times(.captureRestart), [rasterDownAt])
        // Reconnect: the controller resets to the initial point (raster 1.0).
        now += 2
        feed(c, fake, end: now, generation: 2, sent: 120, stats: try realStats(delivered: 60))
        XCTAssertEqual(c.desiredPlan?.rasterScale, 1, "reset to the initial point")
        XCTAssertLessThan(c.plan?.rasterScale ?? 1, 1, "held: inside the restart interval")
        while now < rasterDownAt + AdaptiveStreamingCoordinator.restartIntervalSeconds + 2 {
            now += 2
            feed(c, fake, end: now, generation: 2, sent: 120, stats: try realStats(delivered: 60))
        }
        XCTAssertEqual(c.plan?.rasterScale, 1, "applied once the interval passed")
        let restarts = fake.times(.captureRestart)
        XCTAssertEqual(restarts.count, 2)
        XCTAssertGreaterThanOrEqual(restarts[1] - restarts[0], AdaptiveStreamingCoordinator.restartIntervalSeconds)
    }

    func testBitrateRebuildsAreSpacedLatestWins() throws {
        let (c, fake) = managed()
        var now = 2.0
        // Severe backpressure: the controller lowers the bitrate every window.
        for _ in 0..<12 {
            now += 2
            feed(c, fake, end: now, sent: 60, netDrops: 70, stats: try realStats(delivered: 25, rtt: 120))
        }
        XCTAssertGreaterThan(fake.times(.encoderRebuild).count, 1)
        // A bitrate rebuild never follows any other encoder rebuild (every
        // path rebuilds the encoder) inside the interval.
        for (index, entry) in fake.applied.enumerated() where entry.path == .encoderRebuild && index > 0 {
            XCTAssertGreaterThanOrEqual(entry.time - fake.applied[index - 1].time,
                                        AdaptiveStreamingCoordinator.encoderRebuildIntervalSeconds,
                                        "\(fake.applied.map { "\($0.time) \($0.path)" })")
        }
        // Latest wins: what runs now is what the controller last asked for,
        // or will be at the next allowed tick.
        now += 2
        feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
        now += 2
        feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
        XCTAssertEqual(c.plan?.bitrate, c.desiredPlan?.bitrate)
    }

    // MARK: - A4: raster steps against the size before the decode ceiling

    private let fiveK = AdaptiveCaptureSizing(sourceWidth: 5120, sourceHeight: 2880, todayScale: 1,
                                              maxWide: 4096, maxHigh: 2304)

    func testFiveKMirrorSkipsNoOpStepsAndKeepsTheH264Guard() {
        XCTAssertEqual(AdaptiveStreamingCoordinator.distinctRasterSteps(AdaptiveStreamingLadder.standard.rasterSteps,
                                                                        sizing: fiveK),
                       [0.5, 0.625, 0.75, 1.0], "0.875 captures the same 4096×2304 as 1.0")
        let (c, _) = managed(sizing: fiveK, started: (4096, 2304), inputs: inputs(mode: .mirror, codec: .h264))
        let configuration = c.controllerConfiguration
        XCTAssertEqual(configuration?.nativeEncodeWidth, 5120, "native is the size before the ceiling")
        XCTAssertEqual(configuration?.nativeEncodeHeight, 2880)
        XCTAssertEqual(configuration?.maxEncodeWidth, 4096)
        XCTAssertEqual(configuration?.ladder.rasterSteps, [0.5, 0.625, 0.75, 1.0])
        // H.264 guard at the size really encoded at the top (4096×2304), not
        // at the 5K source.
        let atTop = EncoderCapability.codecSafeFPS(width: 4096, height: 2304)
        XCTAssertEqual(configuration?.negotiation.capabilityCeilingFPS, min(60, atTop))
        XCTAssertGreaterThan(configuration?.negotiation.capabilityCeilingFPS ?? 0,
                             EncoderCapability.codecSafeFPS(width: 5120, height: 2880))

        // A restart at 0.75 (3840×2160, under the ceiling) leaves the
        // configuration alone: no swing, no `reconfigure` per restart.
        c.noteCaptureStarted(sizing: fiveK, width: 3840, height: 2160)
        c.tick(generation: 1, mode: .mirror, inputs: inputs(mode: .mirror, codec: .h264), window: window(2, 4), now: 4)
        XCTAssertEqual(c.controllerConfiguration, configuration)
    }

    func testARasterChangeThatKeepsTheCapturedSizeNeverRestarts() {
        let c = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .automatic, displayMode: .mirror)
        c.noteCaptureStarted(sizing: fiveK, width: 4096, height: 2304)
        let top = AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller)
        var noOp = top; noOp.rasterScale = 0.875
        var real = top; real.rasterScale = 0.75
        XCTAssertEqual(c.applyPath(from: top, to: noOp), .none)
        noOp.bitrate = 15_000_000
        XCTAssertEqual(c.applyPath(from: top, to: noOp), .encoderRebuild)
        XCTAssertEqual(c.applyPath(from: top, to: real), .captureRestart)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: top, to: noOp), .captureRestart,
                       "the pure planner can't know the ceiling; the coordinator can")
    }

    // MARK: - A5: the started size against the plan

    func testACaptureThatNeverStartsAtThePlannedSizeIsNotRestartedWithoutEnd() {
        let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .extend)
        c.applier = RecordingApplier()
        c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        var restarts = 0
        for _ in 0..<10 where c.captureNeedsRasterRestart(today: 1) {
            restarts += 1
            c.noteCaptureStarted(sizing: iPadSizing, width: 2000, height: 1500)   // never the planned size
        }
        XCTAssertEqual(restarts, AdaptiveStreamingCoordinator.maximumUnmatchedStarts + 1,
                       "the first check and two retries, then the running capture is kept")
        // Saving ends; the plan's raster changes, so one more attempt is allowed.
        c.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 100)
        XCTAssertNil(c.plan)
        restarts = 0
        for _ in 0..<10 where c.captureNeedsRasterRestart(today: 1) {
            restarts += 1
            c.noteCaptureStarted(sizing: iPadSizing, width: 2000, height: 1500)
        }
        XCTAssertLessThanOrEqual(restarts, AdaptiveStreamingCoordinator.maximumUnmatchedStarts + 1)
        XCTAssertFalse(c.hasManagedRaster, "with no plan the switch-off state returns even when no start matched")
    }

    func testACaptureSizedBeforeAPlanChangeIsRestartedOnceAfterwards() {
        let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .extend)
        let fake = RecordingApplier()
        c.applier = fake
        c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
        XCTAssertFalse(c.captureNeedsRasterRestart(today: 1))
        // A rotation rebuild sizes its capture at 1.0 (off the queue)…
        let sizedAtOldPlan = iPadSizing.captureSize(scale: c.captureScale(today: 1))
        // …then "Use less data" turns on before the capture starts.
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertEqual(c.plan?.rasterScale, StreamQuality.balanced.scale)
        let size = sizedAtOldPlan
        c.noteCaptureStarted(sizing: iPadSizing, width: size?.width ?? 0, height: size?.height ?? 0)
        XCTAssertTrue(c.captureNeedsRasterRestart(today: 1),
                      "the capture has the old raster although it started after the plan changed")
        // The restart (run through the arbiter after the rebuild) starts at the plan's size.
        var arbiter = CaptureRebuildArbiter()
        XCTAssertTrue(arbiter.requestGeometry())
        XCTAssertFalse(arbiter.requestAdaptiveRaster(), "waits for the rebuild that owns the pipeline")
        XCTAssertEqual(arbiter.finish(), .adaptiveRaster)
        let planned = iPadSizing.captureSize(scale: c.captureScale(today: 1))
        c.noteCaptureStarted(sizing: iPadSizing, width: planned?.width ?? 0, height: planned?.height ?? 0)
        XCTAssertFalse(c.captureNeedsRasterRestart(today: 1), "once, then done")
        XCTAssertTrue(arbiter.requestAdaptiveRaster())
        XCTAssertEqual(arbiter.finish(), .none)
    }

    // MARK: - A6: legacy FPS at the real call site

    func testSwitchOffResolvesTodaysFPSThroughTheProductionResolverAcrossTheMatrix() {
        let sizes = [(2388, 1668), (2796, 1572), (5120, 2880), (1704, 786)]
        let profiles: [(StreamingProfile, Int?)] = [(.efficiency, nil), (.performance, nil), (.custom, 30), (.custom, 120)]
        var todays: [(StreamingFPSPolicy.Result, Int, Int)] = []
        for receiverMax in [nil, 30, 60, 90, 120, 144] as [Int?] {
            for user in [nil, 24, 60, 90] as [Int?] {
                for codec in StreamCodec.allCases {
                    for (width, height) in sizes {
                        for (profile, custom) in profiles {
                            let common = StreamingFPSPolicy.commonTargetFPS(
                                profile: profile, requestedFPS: custom, receiverMaxFPS: receiverMax, userMaxFPS: user)
                            todays.append((MacSender.todayEffectiveFPS(commonTarget: common, codec: codec,
                                                                       width: width, height: height), width, height))
                        }
                    }
                }
            }
        }
        var checked = 0
        for streamingMode in [StreamingMode.automatic, .custom] {
            for mode in RefreshNegotiation.DisplayMode.allCases {
                for source in [nil, 30, 48, 50, 60, 120] as [Int?] {
                    for hello in [AdaptiveHelloFields(), AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true)] {
                        let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: streamingMode, displayMode: mode)
                        c.setSourceRefresh(source)
                        c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
                        c.helloAccepted(hello, now: 0)
                        c.tick(generation: 1, mode: mode, inputs: inputs(mode: mode), window: window(0, 2), now: 2)
                        // #123 F1: a start whose size the note re-derives
                        // differently (the display mode changed or was
                        // missing between sizing and preparation) never
                        // restarts capture with the switch off.
                        c.noteCaptureStarted(sizing: iPadSizing, width: 2560, height: 1600)
                        if c.captureNeedsRasterRestart(today: 1) {
                            XCTFail("\(streamingMode) \(mode): the switch-off state asked for a capture restart")
                        }
                        for (today, _, _) in todays {
                            let resolved = MacSender.effectiveFPS(today: today, adaptive: c)
                            if resolved != today { XCTFail("\(streamingMode) \(mode) source \(String(describing: source)): \(resolved) != \(today)") }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// Documented in PROTOCOL.md 6.20: with the switch on, the source cap
    /// applies to old receivers too (Mirror/Extend never above the source).
    func testSwitchOnCapsAnOldReceiverAtTheSource() {
        let c = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .automatic, displayMode: .mirror)
        c.setSourceRefresh(50)
        c.helloAccepted(AdaptiveHelloFields(), now: 0)
        XCTAssertEqual(MacSender.effectiveFPS(today: .init(fps: 120, reason: .requested), adaptive: c).fps, 50)
        XCTAssertEqual(MacSender.effectiveFPS(today: .init(fps: 30, reason: .userCeiling), adaptive: c).fps, 30)
        XCTAssertNil(c.plan, "the fixed policy otherwise")
    }

    // MARK: - A7: lock screen deferral

    func testChangesDeferredByTheLockScreenAreKeptAndTheCostliestRunsOnce() {
        var deferral = AdaptiveApplyDeferral()
        XCTAssertEqual(deferral.take(), .none)
        deferral.record(.liveFPSUpdate)
        deferral.record(.encoderRebuild)
        XCTAssertEqual(deferral.pending, .encoderRebuild)
        deferral.record(.captureRestart)
        deferral.record(.liveFPSUpdate)
        XCTAssertEqual(deferral.take(), .captureRestart, "a restart also rebuilds the encoder at the new FPS")
        XCTAssertEqual(deferral.take(), .none, "applied once")
    }

    // MARK: - A9: re-hello coalescing

    func testReHellosAreCoalescedAndOnlyForChangesTheMacUses() {
        var gate = AdaptiveHelloResendGate()
        let gap = AdaptiveHelloResendGate.minimumIntervalSeconds
        var fields = AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true,
                                         cost: NetworkCost.endpointReport(.init(usesWiFi: true), reachability: .local),
                                         saveData: .auto, saveDataAnswer: nil)
        XCTAssertFalse(gate.shouldResend(fields, now: 0), "nothing sent yet")
        gate.noteSent(fields, now: 0)
        XCTAssertFalse(gate.shouldResend(fields, now: 100))

        // Interface kind only (Wi-Fi to wired, both unmetered): the Mac
        // doesn't use it, so no re-hello.
        fields.cost = NetworkCost.endpointReport(.init(usesWired: true), reachability: .local)
        XCTAssertFalse(gate.shouldResend(fields, now: 100))

        // A flapping refresh: at most one re-hello per interval, latest wins.
        var sent: [Double] = []
        var now = 100.0
        while now < 130 {
            fields.effectiveRefreshHz = Int(now * 2) % 2 == 0 ? 60 : 120
            if gate.shouldResend(fields, now: now) {
                gate.noteSent(fields, now: now)
                sent.append(now)
            }
            now += 0.5
        }
        for (a, b) in zip(sent, sent.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, gap) }
        XCTAssertLessThanOrEqual(sent.count, Int(30 / gap) + 1)
        // Back to what was last sent before the interval passed: nothing to send.
        fields.effectiveRefreshHz = gate.lastSent?.effectiveRefreshHz
        XCTAssertFalse(gate.shouldResend(fields, now: now + gap))
        // A real cost change goes out after the interval.
        fields.cost = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true), reachability: .remote)
        XCTAssertTrue(gate.shouldResend(fields, now: now + gap))
    }

    // MARK: - Switch off: no work

    func testSwitchOffWithoutDataSavingDoesNoWork() throws {
        for streamingMode in [StreamingMode.automatic, .custom] {
            let c = AdaptiveStreamingCoordinator(enabled: streamingMode == .custom, streamingMode: streamingMode,
                                                 displayMode: .extend)
            let fake = RecordingApplier()
            c.applier = fake
            c.setSourceRefresh(60)
            c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
            var inputsEvaluated = 0
            var windowsEvaluated = 0
            func makeInputs() -> AdaptiveStreamingCoordinator.Inputs? { inputsEvaluated += 1; return inputs() }
            func makeWindow(_ end: Double) -> AdaptiveStreamingCoordinator.SenderWindow {
                windowsEvaluated += 1
                return window(end - 2, end)
            }
            let hellos = [AdaptiveHelloFields(), telemetryHello(saveData: nil), telemetryHello(saveData: .off),
                          telemetryHello(saveData: .auto)]
            let stats = try realStats(delivered: 20, rtt: 200)
            var now = 0.0
            for round in 0..<60 {
                c.helloAccepted(hellos[round % hellos.count], now: now)
                for _ in 0..<120 { c.noteVideoSent(bytes: 30_000, now: now) }
                c.receiverStats(json: stats)
                now += 2
                c.tick(generation: UInt64(1 + round / 20), mode: .extend, inputs: makeInputs(),
                       window: makeWindow(now), now: now)
            }
            XCTAssertEqual(inputsEvaluated, 0, "\(streamingMode): no input building")
            XCTAssertEqual(windowsEvaluated, 0, "\(streamingMode): no window building")
            XCTAssertEqual(c.work, AdaptiveStreamingCoordinator.WorkCounters(), "\(streamingMode): no replanning or parsing")
            XCTAssertNil(c.controllerConfiguration, "\(streamingMode): no controller")
            XCTAssertNil(c.plan)
            XCTAssertTrue(fake.applied.isEmpty)
            // 7,200 video sends: the monitor was written once per tick at most, never per frame.
            XCTAssertLessThanOrEqual(c.monitor.writeCount, 60, "\(streamingMode)")
            XCTAssertEqual(c.monitor.snapshot(now: now).videoPayloadBytes, 60 * 120 * 30_000,
                           "the payload shown in Settings is still counted")
        }
    }

    // MARK: - Review of ddcef384 (F1–F7)

    /// F1: with the switch off and no data saving, the size a capture
    /// started at is never compared with a re-derived one: no restart, no
    /// work, nothing applied, whatever the note reads.
    func testSwitchOffNeverAsksForARasterRestartWhenTheStartedSizeLooksWrong() {
        let startedSizes = [(2560, 1600), (2732, 2048), (1366, 1024), (2, 2), (3000, 2000)]
        let notedSizings = [iPadSizing, fiveK,
                            AdaptiveCaptureSizing(sourceWidth: 3024, sourceHeight: 1964, todayScale: 1, maxWide: 2732, maxHigh: 2048)]
        for streamingMode in [StreamingMode.automatic, .custom] {
            for sizing in notedSizings {
                for (width, height) in startedSizes {
                    let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: streamingMode, displayMode: .mirror)
                    let fake = RecordingApplier()
                    c.applier = fake
                    c.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 60, telemetry: true, saveData: .off), now: 0)
                    c.noteCaptureStarted(sizing: sizing, width: width, height: height)
                    for round in 1...5 {
                        let now = Double(round) * 2
                        c.tick(generation: 1, mode: .mirror, inputs: inputs(mode: .mirror), window: window(now - 2, now),
                               now: now)
                    }
                    XCTAssertFalse(c.captureNeedsRasterRestart(today: 1), "\(streamingMode) \(width)x\(height)")
                    XCTAssertFalse(c.hasManagedRaster)
                    XCTAssertTrue(fake.applied.isEmpty)
                    XCTAssertEqual(c.work, AdaptiveStreamingCoordinator.WorkCounters())
                }
            }
        }
        // Once a plan asked for another raster, a wrong start is caught again.
        let saving = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
        saving.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
        saving.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertTrue(saving.hasManagedRaster)
        XCTAssertTrue(saving.captureNeedsRasterRestart(today: 1))
    }

    /// F2: a failed raster probe is undone at once, not 20 s later, so the
    /// controller never judges windows of a point the pipeline isn't running
    /// (and never steps down again from the reverted point on them).
    func testAFailedRasterProbeIsRevertedAtOnceAndThePipelineRunsTheControllersPoint() throws {
        let (c, fake) = managed()
        var now = 2.0
        try congest(c, fake, from: &now) { ($0.plan?.rasterScale ?? 1) < 1 }
        var probeAt: Double?
        while probeAt == nil, now < 900 {
            now += 2
            feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
            if let d = c.lastDecision, d.action == .upshift, d.changed.contains(.raster) { probeAt = now }
        }
        let probe = try XCTUnwrap(probeAt, "the controller probes the raster back up")
        XCTAssertEqual(fake.times(.captureRestart).last, probe)
        let probed = try XCTUnwrap(c.plan?.rasterScale)
        // Two seconds later the receiver presents only 40 of 60 frames with no
        // other cause: the probe failed.
        now += 2
        feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 40))
        XCTAssertEqual(c.lastDecision?.action, .probeRevert)
        XCTAssertEqual(fake.times(.captureRestart).last, now, "the revert restarts capture at once")
        XCTAssertLessThan(c.plan?.rasterScale ?? 1, probed)
        XCTAssertEqual(c.plan?.rasterScale, c.lastDecision?.point?.rasterScale, "no drift")
        XCTAssertEqual(c.plan, c.desiredPlan)
    }

    /// F3: a hello with only one decode-ceiling dimension clamps nothing
    /// (`DecodeCeiling.clamp`), so no ladder step is dropped as "the same size".
    func testAOneDimensionCeilingClampsNothing() {
        for (wide, high) in [(4096, nil), (nil, 2304), (4096, 0), (0, 2304), (-1, 2304)] as [(Int?, Int?)] {
            let sizing = AdaptiveCaptureSizing(sourceWidth: 5120, sourceHeight: 2880, todayScale: 1, maxWide: wide, maxHigh: high)
            XCTAssertFalse(sizing.isClampedByCeiling(scale: 1))
            XCTAssertFalse(sizing.capturesTheSame(1, 0.875))
            XCTAssertEqual(AdaptiveStreamingCoordinator.distinctRasterSteps(AdaptiveStreamingLadder.standard.rasterSteps,
                                                                            sizing: sizing),
                           AdaptiveStreamingLadder.standard.rasterSteps)
            let clamped = DecodeCeiling.clamp(width: 5120, height: 2880, maxWide: wide, maxHigh: high)
            XCTAssertEqual(sizing.captureSize(scale: 1), AdaptivePixelSize(width: clamped.width, height: clamped.height))
        }
        XCTAssertTrue(fiveK.isClampedByCeiling(scale: 1), "both dimensions: clamped as before")
    }

    /// F4: when the receiver's stats stop after a step down, the fixed
    /// point comes back through the usual limits; when they resume, the
    /// controller manages again from its initial point.
    func testStoppedTelemetryReturnsToTheFixedPointAndResumesFromTheStart() throws {
        let (c, fake) = managed()
        fake.plan = { [unowned c] in c.plan }
        var now = 2.0
        try congest(c, fake, from: &now) { ($0.plan?.rasterScale ?? 1) < 1 }
        let lastStats = now
        while now < lastStats + AdaptiveStreamingCoordinator.telemetryLossSeconds - 2 {
            now += 2
            fake.now = now
            c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 2, now), now: now)
        }
        XCTAssertFalse(c.telemetryLost)
        XCTAssertLessThan(c.plan?.rasterScale ?? 1, 1, "a short gap holds the point")
        while now < lastStats + AdaptiveStreamingCoordinator.telemetryLossSeconds
                + AdaptiveStreamingCoordinator.restartIntervalSeconds + 2 {
            now += 2
            fake.now = now
            c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 2, now), now: now)
        }
        XCTAssertTrue(c.telemetryLost)
        XCTAssertNil(c.plan, "today's fixed point")
        let restarts = fake.times(.captureRestart)
        for (a, b) in zip(restarts, restarts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, AdaptiveStreamingCoordinator.restartIntervalSeconds)
        }
        now += 2
        feed(c, fake, end: now, sent: 120, stats: try realStats(delivered: 60))
        XCTAssertFalse(c.telemetryLost)
        XCTAssertEqual(c.plan?.origin, .controller, "managed again")
        XCTAssertEqual(c.plan?.rasterScale, 1, "from the initial point, not the old lowered one")
    }

    /// F5: a link under 0.5 ms always reports `rtt` 0; it still gets a
    /// baseline and can step up. One early 0 (before the first pong) never
    /// becomes the baseline.
    func testASubMillisecondLinkThatAlwaysReportsZeroRTTStillStepsUp() {
        let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
            mode: .extend, sourceRefreshHz: 60, receiverMaxFPS: 60, receiverEffectiveRefreshHz: 60,
            encodeWidth: 2388, encodeHeight: 1668, codec: .hevc))
        func makeController() -> AdaptiveStreamingController {
            AdaptiveStreamingController(configuration: .init(
                mode: .extend, negotiation: negotiation, nativeEncodeWidth: 2388, nativeEncodeHeight: 1668,
                receiver: iPad, receiverTelemetryAvailable: true), generation: 1, routeEpoch: 1)
        }
        func sample(_ index: Int, fps: Double, rtt: Double, thermal: AdaptiveThermalLevel = .nominal) -> AdaptiveStreamingSample {
            var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
            t.deliveredFPS = fps
            t.rttMs = rtt
            t.jitterMs = 0
            t.thermal = thermal
            let end = Double(index) * 2 + 2
            return AdaptiveStreamingCoordinator.makeSample(
                generation: 1, routeEpoch: 1, mode: .extend,
                window: .init(start: end - 2, end: end, capturedFrames: Int(fps * 2), encoderDrops: 0,
                              networkDrops: 0, thermal: .nominal, lowPower: false, encodeLatencyMs: 4),
                sentFrames: Int(fps * 2), sentBytes: 2_000_000, telemetry: t, dataPolicy: .normal, now: end)
        }
        var controller = makeController()
        XCTAssertEqual(controller.ingest(sample(0, fps: 60, rtt: 0, thermal: .critical)).point?.fps, 30)
        var upshifted = false
        for index in 1..<60 where !upshifted {
            upshifted = controller.ingest(sample(index, fps: 30, rtt: 0)).action == .upshift
        }
        XCTAssertTrue(upshifted, "0 ms every window is a real baseline")

        var early = makeController()
        _ = early.ingest(sample(0, fps: 60, rtt: 0))
        _ = early.ingest(sample(1, fps: 60, rtt: 20))
        XCTAssertEqual(early.ingest(sample(2, fps: 60, rtt: 20)).evidence.baselineRttMs, 20,
                       "one 0 before the first pong is not a baseline")
    }

    /// F6 (a): a restart that really runs later than its plan (held by the
    /// lock screen view, or re-run after a capture start) counts for the
    /// limit from when it ran.
    func testARestartThatRunsLateCountsForTheLimitFromWhenItRan() {
        let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .extend)
        let fake = RecordingApplier()
        c.applier = fake
        c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertEqual(fake.times(.captureRestart), [0])
        // The lock screen view held it; it runs when the view ends at 19.
        c.noteAdaptiveRestartBegan(now: 19)
        fake.now = 25
        c.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 25)
        XCTAssertEqual(c.plan?.rasterScale, StreamQuality.balanced.scale, "20 s from the restart at 19, not from 0")
        var now = 25.0
        while now < 38 {
            now += 1
            fake.now = now
            c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 1, now), now: now)
        }
        XCTAssertEqual(c.plan?.rasterScale, StreamQuality.balanced.scale)
        now = 39
        fake.now = now
        c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 1, now), now: now)
        XCTAssertNil(c.plan)
        XCTAssertEqual(fake.times(.captureRestart), [0, 39])
    }

    /// F6 (b), PROTOCOL.md 6.20: while the restart limit holds the raster
    /// part of a data-policy change, its FPS and bitrate parts apply at once.
    /// #123 churn (deliberate change): this now holds for a change toward
    /// saving only. A return from saving waits for the dwell and then lands
    /// whole: when its restart would be held (here the saver restart ran
    /// late, at 10), the whole return waits for it, one restart, no separate
    /// FPS and bitrate update first.
    func testADataPolicyChangeHoldsOnlyItsRasterPart() {
        let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .extend)
        let fake = RecordingApplier()
        c.applier = fake
        c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertEqual(c.plan?.fpsCap, AdaptiveStreamingPlanner.saverFPSCap)
        let saving = c.plan
        // The saver restart really ran at 10 (the lock screen view held it).
        c.noteAdaptiveRestartBegan(now: 10)
        let dwell = AdaptiveStreamingCoordinator.saverMinimumDwellSeconds
        fake.now = dwell
        c.helloAccepted(AdaptiveHelloFields(saveData: .off), now: dwell)
        XCTAssertEqual(c.appliedDataPolicy, .saver, "the return would be split by the restart limit: it waits whole")
        XCTAssertEqual(c.plan, saving)
        XCTAssertEqual(fake.applied.map(\.path), [.captureRestart])
        fake.now = 30
        c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(28, 30), now: 30)
        XCTAssertNil(c.plan)
        XCTAssertEqual(c.appliedDataPolicy, .normal)
        XCTAssertEqual(fake.applied.map(\.path), [.captureRestart, .captureRestart])
        XCTAssertEqual(fake.times(.captureRestart), [0, 30])
        // Saving again one second after that restart: its FPS cap applies at
        // once, its bitrate after the 4 s encoder limit, its raster after 20 s.
        fake.now = 31
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 31)
        XCTAssertEqual(c.appliedDataPolicy, .saver)
        XCTAssertEqual(c.plan?.fpsCap, AdaptiveStreamingPlanner.saverFPSCap)
        XCTAssertEqual(c.plan?.rasterScale, 1)
        XCTAssertEqual(fake.applied.last?.path, .liveFPSUpdate)
        var now = 31.0
        while now < 50 {
            now += 1
            fake.now = now
            c.tick(generation: 1, mode: .extend, inputs: inputs(), window: window(now - 1, now), now: now)
        }
        XCTAssertEqual(fake.times(.encoderRebuild).last, 35)
        XCTAssertEqual(fake.times(.captureRestart), [0, 30, 50])
        XCTAssertEqual(c.plan, c.desiredPlan)
    }
}
