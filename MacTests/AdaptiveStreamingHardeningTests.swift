import XCTest

/// #123 review fixes for the adaptive wiring: hostile peer numbers never trap
/// (F1), data-policy restarts are rate-limited and keep the controller's
/// history (F2), user geometry wins over adaptive restarts (F3), the "Use
/// less data" semantics (F4/F5) and the source-cap lower bound (F7). No
/// capture or encoder runs: the sender side is a fake applier.
final class AdaptiveStreamingHardeningTests: XCTestCase {
    private final class FakeApplier: AdaptiveStreamingApplying {
        var paths: [AdaptiveApplyPath] = []
        func adaptiveApply(_ path: AdaptiveApplyPath) { paths.append(path) }
    }

    private func wire(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every hostile value class from the review. NaN and infinities cannot
    /// go through JSONSerialization, so they are passed as NSNumbers directly
    /// (the parser must not rely on JSON having filtered them).
    private var hostileValues: [(String, Any)] {
        [
            ("1e300", 1e300), ("-1e300", -1e300), ("NaN", Double.nan), ("inf", Double.infinity),
            ("-inf", -Double.infinity), ("-1", -1), ("huge Int", Int.max), ("Int.min", Int.min),
            ("UInt64.max", UInt64.max), ("2^63 as double", 9.223372036854775807e18),
            ("string", "60"), ("bool", true), ("array", [60]), ("nested object", ["v": 60]),
            ("null", NSNull()),
        ]
    }

    // MARK: - F1: hostile numbers

    func testPeerNumberChecksTheDoubleBeforeConverting() {
        for (label, value) in hostileValues {
            XCTAssertNil(PeerNumber.int(value, in: 1...240), label)
            XCTAssertNil(PeerNumber.int(value, in: 0...100_000), label)
        }
        // The full Int range itself never traps on its own edge.
        XCTAssertNil(PeerNumber.int(Double(Int.max), in: Int.min...Int.max))
        XCTAssertNil(PeerNumber.int(-Double(Int.max), in: Int.min...Int.max))
        XCTAssertEqual(PeerNumber.int(120.0, in: 1...240), 120)
        XCTAssertNil(PeerNumber.int(59.5, in: 1...240), "integral by default")
        XCTAssertEqual(PeerNumber.int(59.5, in: 1...240, integral: false), 59)
        XCTAssertEqual(PeerNumber.int(0, in: 0...3), 0)
        XCTAssertNil(PeerNumber.int(0, in: 1...240))
        // Outgoing: clamped before scaling, never infinity.
        XCTAssertEqual(PeerNumber.roundedTenths(1e308, limit: 1_000_000), 1_000_000)
        XCTAssertEqual(PeerNumber.roundedTenths(-1e308, limit: 1_000_000), -1_000_000)
        XCTAssertNil(PeerNumber.roundedTenths(.nan, limit: 1_000_000))
        XCTAssertNil(PeerNumber.roundedTenths(.infinity, limit: 1_000_000))
        XCTAssertEqual(PeerNumber.roundedTenths(12.345, limit: 1_000_000), 12.3)
    }

    func testHelloHostileNumbersReadAsAbsentWithoutTrapping() throws {
        for (label, value) in hostileValues {
            let hz = AdaptiveHelloFields.parse(["effHz": value, "adaptiveTelemetry": 1])
            XCTAssertNil(hz.effectiveRefreshHz, "effHz \(label)")
            XCTAssertFalse(hz.telemetry, "effHz \(label)")
            let flag = AdaptiveHelloFields.parse(["effHz": 60, "adaptiveTelemetry": value])
            XCTAssertEqual(flag.effectiveRefreshHz, 60)
            XCTAssertFalse(flag.telemetry, "adaptiveTelemetry \(label)")
            XCTAssertNil(AdaptiveHelloFields.parse(["cost": value]).cost, "cost \(label)")
            XCTAssertNil(AdaptiveHelloFields.parse(["cost": ["cost": value, "conf": "high"]]).cost, "cost.cost \(label)")
            XCTAssertNil(AdaptiveHelloFields.parse(["saveData": value]).saveData, "saveData \(label)")
            XCTAssertNil(AdaptiveHelloFields.parse(["saveDataAnswer": value]).saveDataAnswer, "saveDataAnswer \(label)")
        }
        // 0 is out of range for effHz; JSON round trip of the finite ones too.
        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["effHz": 0, "adaptiveTelemetry": 1])).effectiveRefreshHz)
        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["effHz": 1e300, "adaptiveTelemetry": 1])).effectiveRefreshHz)
        XCTAssertFalse(AdaptiveHelloFields.parse(try wire(["effHz": 60, "adaptiveTelemetry": 1e300])).telemetry)
        XCTAssertEqual(AdaptiveHelloFields.parse(try wire(["effHz": 240, "adaptiveTelemetry": 1])).effectiveRefreshHz, 240)
    }

    func testStatsHostileNumbersReadAsAbsentWithoutTrapping() throws {
        let numberKeys = ["deliveredFps", "decodedFps", "enqFps", "dec95", "presAge", "late", "rtt", "jit", "thermal"]
        for (label, value) in hostileValues {
            XCTAssertNil(AdaptiveReceiverTelemetry.parse(["win": value]), "win \(label)")
            for key in numberKeys {
                let t = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(["win": 2, key: value]), "\(key) \(label)")
                XCTAssertEqual(t, AdaptiveReceiverTelemetry(windowSeconds: 2), "\(key) \(label) reads as absent")
            }
            if !(value is Bool) {
                XCTAssertNil(AdaptiveReceiverTelemetry.parse(["win": 2, "lowPower": value])?.lowPower, "lowPower \(label)")
            }
        }
        // Zero is a valid count and a valid thermal level; just past the range is not.
        let zero = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try wire(["win": 2, "late": 0, "thermal": 0])))
        XCTAssertEqual(zero.lateDrops, 0)
        XCTAssertEqual(zero.thermal, .nominal)
        let edge = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try wire(["win": 2, "late": 100_001, "thermal": 4])))
        XCTAssertNil(edge.lateDrops)
        XCTAssertNil(edge.thermal)
        XCTAssertEqual(AdaptiveReceiverTelemetry.parse(try wire(["win": 2, "late": 100_000]))?.lateDrops, 100_000)
    }

    func testOutgoingTelemetryIsAlwaysSerializable() throws {
        var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
        t.deliveredFPS = 1e308
        t.decodeP95Ms = .infinity
        t.jitterMs = .nan
        let fields = t.wireFields
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(fields["deliveredFps"] as? Double, AdaptiveStreamingWire.wireValueLimit)
        XCTAssertNil(fields["dec95"])
        XCTAssertNil(fields["jit"])
        // The Mac reads the clamped value as out of range: absent.
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(fields))?.deliveredFPS)
    }

    private func phone(scale: Double, wide: Int = 2732, high: Int = 2048) throws -> PhoneInfo {
        let json = "{\"pixelsWide\":\(wide),\"pixelsHigh\":\(high),\"scale\":\(scale),\"device\":\"iPad\"}"
        return try JSONDecoder().decode(PhoneInfo.self, from: Data(json.utf8))
    }

    func testReceiverDisplayRangeChecksTheScaleBeforeDividing() throws {
        for scale in [1e-300, 1e-10, 0.1, 0.49, 8.01, 1e300, -2] {
            XCTAssertNil(MacSender.adaptiveReceiverDisplay(try phone(scale: scale)), "scale \(scale)")
        }
        XCTAssertNil(MacSender.adaptiveReceiverDisplay(try phone(scale: 0.5, wide: Int.max / 2)), "huge size")
        let ipad = try XCTUnwrap(MacSender.adaptiveReceiverDisplay(try phone(scale: 2)))
        XCTAssertEqual(ipad.pointsWide, 1366)
        XCTAssertEqual(ipad.pointsHigh, 1024)
        XCTAssertNotNil(MacSender.adaptiveReceiverDisplay(try phone(scale: 0.5)))
        XCTAssertNotNil(MacSender.adaptiveReceiverDisplay(try phone(scale: 8)))
    }

    // MARK: - F2: policy flips are rate-limited and keep the history

    private let iPad = AdaptiveReceiverDisplay(pointsWide: 1366, pointsHigh: 1024, scale: 2, sizeClass: .tablet)

    private func inputs() -> AdaptiveStreamingCoordinator.Inputs {
        AdaptiveStreamingCoordinator.Inputs(mode: .extend, profile: .performance, customFPS: nil, receiverMaxFPS: 120,
                                            userMaxFPS: nil, codec: .hevc, receiver: iPad)
    }

    private func window(_ start: Double, _ end: Double) -> AdaptiveStreamingCoordinator.SenderWindow {
        AdaptiveStreamingCoordinator.SenderWindow(start: start, end: end, capturedFrames: 120, encoderDrops: 0,
                                                  networkDrops: 0, thermal: .nominal, lowPower: false)
    }

    private func liveCoordinator(enabled: Bool) -> (AdaptiveStreamingCoordinator, FakeApplier) {
        let coordinator = AdaptiveStreamingCoordinator(enabled: enabled, streamingMode: .automatic, displayMode: .extend)
        let fake = FakeApplier()
        coordinator.applier = fake
        coordinator.setSourceRefresh(120)
        coordinator.noteCaptureStarted(width: 2732, height: 2048, scale: 1)
        return (coordinator, fake)
    }

    /// A scripted hostile/flapping receiver: `saveData` on/off on every
    /// hello, one hello per second for 60 s, the Mac ticking every 2 s.
    func testFlappingSaveDataRestartsCaptureAtMostOncePerInterval() {
        let (coordinator, fake) = liveCoordinator(enabled: false)
        let interval = AdaptiveStreamingCoordinator.policyRestartIntervalSeconds
        var restartTimes: [Double] = []
        var now = 0.0
        while now < 60 {
            let before = fake.paths.count
            coordinator.helloAccepted(AdaptiveHelloFields(saveData: Int(now) % 2 == 0 ? .on : .off), now: now)
            if Int(now) % 2 == 1 {
                coordinator.tick(generation: 1, inputs: inputs(), window: window(now - 2, now), now: now)
            }
            restartTimes += fake.paths[before...].filter { $0 == .captureRestart }.map { _ in now }
            now += 1
        }
        XCTAssertFalse(restartTimes.isEmpty, "the first change applies at once")
        XCTAssertEqual(restartTimes.first, 0)
        for (a, b) in zip(restartTimes, restartTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, interval, "restart storm: \(restartTimes)")
        }
        XCTAssertLessThanOrEqual(restartTimes.count, Int(60 / interval) + 1)
    }

    /// #123 F6, then #123 churn (deliberate change): saving applies at once;
    /// leaving it waits until saving has been in effect for the dwell, and
    /// then the latest request applies whole (one restart, no FPS-only step
    /// first). Before the churn fix, "off" at 3 s returned today's FPS at
    /// once and every later flip was one more FPS update.
    func testPolicyRasterLatestWinsAndAppliesWhenTheIntervalElapses() {
        let (coordinator, fake) = liveCoordinator(enabled: false)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertEqual(fake.paths, [.captureRestart])
        XCTAssertEqual(coordinator.plan?.origin, .dataSaver)
        let saving = coordinator.plan
        // Off inside the dwell: nothing changes yet, the evidence is reported at once.
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 3)
        XCTAssertEqual(coordinator.appliedDataPolicy, .saver)
        XCTAssertEqual(coordinator.dataPolicy.policy, .normal, "the evidence is reported at once")
        XCTAssertEqual(coordinator.plan, saving)
        // On again, off once more: still nothing applied.
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 5)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 6)
        coordinator.tick(generation: 1, inputs: inputs(), window: window(16, 18), now: 18)
        XCTAssertEqual(coordinator.plan, saving)
        XCTAssertEqual(fake.paths, [.captureRestart])
        // The dwell has passed: the next tick applies the latest request whole.
        coordinator.tick(generation: 1, inputs: inputs(), window: window(18, 20), now: 20)
        XCTAssertNil(coordinator.plan)
        XCTAssertEqual(coordinator.appliedDataPolicy, .normal)
        XCTAssertEqual(fake.paths, [.captureRestart, .captureRestart])
    }

    func testPolicyBeforeTheFirstCaptureIsNeverDeferred() {
        let coordinator = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 1)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 2)
        XCTAssertEqual(coordinator.plan?.origin, .dataSaver)
        XCTAssertEqual(coordinator.plan, coordinator.desiredPlan, "nothing held before the first capture")
    }

    func testPolicyChangeKeepsTheControllerAndItsRestartHistory() {
        let (coordinator, fake) = liveCoordinator(enabled: true)
        coordinator.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .auto), now: 0)
        coordinator.tick(generation: 1, inputs: inputs(), window: window(0, 2), now: 2)
        XCTAssertEqual(coordinator.plan?.origin, .controller, "the controller manages this receiver")
        // Saver: the live controller clamps (no new controller, no `.initial`).
        coordinator.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .on), now: 3)
        XCTAssertEqual(coordinator.lastDecision?.action, .policyClamp)
        XCTAssertEqual(coordinator.lastDecision?.reason, .dataSaverClamp)
        XCTAssertEqual(coordinator.plan?.origin, .controller)
        XCTAssertEqual(fake.paths.filter { $0 == .captureRestart }.count, 1)
        // Off right away (#123 churn, deliberate change): leaving saving
        // waits for the dwell, so the tops stay; the point stays where the
        // controller has it either way.
        let clamped = coordinator.plan
        coordinator.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .off), now: 4)
        XCTAssertEqual(coordinator.appliedDataPolicy, .saver)
        XCTAssertEqual(coordinator.dataPolicy.policy, .normal)
        XCTAssertNotEqual(coordinator.lastDecision?.action, .initial, "history kept: no fresh controller")
        XCTAssertEqual(coordinator.plan, clamped)
        // Saver again: the pending return is simply dropped.
        coordinator.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .on), now: 5)
        XCTAssertEqual(coordinator.appliedDataPolicy, .saver)
        XCTAssertEqual(fake.paths.filter { $0 == .captureRestart }.count, 1,
                       "already at or below the saver tops: no restart needed")
        // Off after the dwell: the tops lift, the controller keeps its point and history.
        coordinator.helloAccepted(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .off),
                                  now: 3 + AdaptiveStreamingCoordinator.saverMinimumDwellSeconds)
        XCTAssertEqual(coordinator.appliedDataPolicy, .normal)
        XCTAssertNotEqual(coordinator.lastDecision?.action, .initial)
        XCTAssertEqual(coordinator.plan, clamped)
    }

    // MARK: - F3: user geometry always wins

    func testGeometryQueuedBehindAnAdaptiveRestartRunsNext() {
        var arbiter = CaptureRebuildArbiter()
        XCTAssertTrue(arbiter.requestAdaptiveRaster())
        XCTAssertFalse(arbiter.requestGeometry(), "busy: queued, not dropped")
        XCTAssertTrue(arbiter.pendingGeometry)
        XCTAssertEqual(arbiter.finish(), .geometry)
        XCTAssertTrue(arbiter.requestGeometry())
        XCTAssertEqual(arbiter.finish(), .none)
        XCTAssertFalse(arbiter.isBusy)
    }

    func testAdaptiveRestartWaitsForGeometryAndNeverJumpsTheQueue() {
        var arbiter = CaptureRebuildArbiter()
        XCTAssertTrue(arbiter.requestGeometry())
        XCTAssertFalse(arbiter.requestGeometry(), "a running rebuild loops on the latest hello itself")
        XCTAssertFalse(arbiter.pendingGeometry)
        XCTAssertFalse(arbiter.requestAdaptiveRaster())
        XCTAssertEqual(arbiter.finish(), .adaptiveRaster)

        // Adaptive running, then both a rotation and another adaptive request.
        var busy = CaptureRebuildArbiter()
        XCTAssertTrue(busy.requestAdaptiveRaster())
        XCTAssertFalse(busy.requestGeometry())
        XCTAssertFalse(busy.requestAdaptiveRaster())
        XCTAssertEqual(busy.finish(), .geometry, "geometry first")
        XCTAssertFalse(busy.requestAdaptiveRaster(), "never ahead of a queued geometry")
        XCTAssertTrue(busy.requestGeometry())
        XCTAssertEqual(busy.finish(), .adaptiveRaster)
        XCTAssertTrue(busy.requestAdaptiveRaster())
        XCTAssertEqual(busy.finish(), .none)
        XCTAssertFalse(busy.isBusy)
    }

    func testGeometryTakesAReservedAdaptiveTurnAndAnUnusedTurnIsReleased() {
        var arbiter = CaptureRebuildArbiter()
        XCTAssertTrue(arbiter.requestGeometry())
        XCTAssertFalse(arbiter.requestAdaptiveRaster())
        XCTAssertEqual(arbiter.finish(), .adaptiveRaster)
        // A rotation arrives before the handed-over adaptive restart starts.
        XCTAssertTrue(arbiter.requestGeometry(), "user geometry wins")
        XCTAssertFalse(arbiter.requestAdaptiveRaster(), "the adaptive restart waits again")
        XCTAssertEqual(arbiter.finish(), .adaptiveRaster)
        // The sender decides the restart is no longer needed: releasing the turn frees the pipeline.
        XCTAssertEqual(arbiter.finish(), .none)
        XCTAssertFalse(arbiter.isBusy)
        XCTAssertTrue(arbiter.requestAdaptiveRaster())
    }

    func testDeferredAdaptiveRestartRunsOnlyWhileTheCaptureHasTheOldRaster() {
        let (coordinator, _) = liveCoordinator(enabled: false)
        XCTAssertFalse(coordinator.captureNeedsRasterRestart(today: 1))
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertTrue(coordinator.captureNeedsRasterRestart(today: 1), "started at 1.0, plan wants 0.75")
        // A rotation rebuild restarted capture at the planned scale meanwhile.
        coordinator.noteCaptureStarted(width: 2048, height: 1536, scale: StreamQuality.balanced.scale)
        XCTAssertFalse(coordinator.captureNeedsRasterRestart(today: 1))
    }

    // MARK: - F4/F5: "Use less data" semantics

    /// A receiver build that predates the setting (or before the app has
    /// read it) sends no `saveData`. The Mac Receiver now has the setting
    /// (see `AdaptiveStreamingWiringTests.testMacReceiverHelloCarriesItsUseLessDataPreferenceOnly`).
    func testReceiverWithoutTheSettingSendsNoSaveData() {
        let mac = ReceiverAdaptiveState()
        mac.setEffectiveRefresh(60)
        mac.setPath(NetworkCost.endpointReport(.init(usesWiFi: true, isConstrained: true), reachability: .local))
        let fields = mac.helloFields.wireFields
        XCTAssertNil(fields["saveData"])
        XCTAssertNil(fields["saveDataAnswer"])
        XCTAssertNil(mac.helloFields.saveData)

        let ios = ReceiverAdaptiveState()
        ios.noteHelloSent(ios.helloFields, now: 0)   // the connect hello, before the setting was read
        ios.setSettings(UseLessDataSettings(), suggestionsEnabled: true)
        XCTAssertTrue(ios.consumeHelloResend(now: AdaptiveHelloResendGate.minimumIntervalSeconds),
                      "the first report re-sends hello")
        XCTAssertEqual(ios.helloFields.wireFields["saveData"] as? String, "auto")
    }

    func testOffIsFullQualityEvenInLowDataModeAndNoOnlyCoversMobileData() {
        func coordinator(_ fields: AdaptiveHelloFields, mac: NetworkCost.EndpointReport? = nil) -> AdaptiveStreamingCoordinator {
            let c = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
            if let mac { c.senderPathChanged(mac, epoch: 1, now: 0) }
            c.helloAccepted(fields, now: 0)
            return c
        }
        let lowData = NetworkCost.endpointReport(.init(usesWiFi: true, isConstrained: true), reachability: .local)
        let macConstrained = NetworkCost.endpointReport(.init(usesWired: true, isConstrained: true), reachability: .local)
        let macMetered = NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true), reachability: .local)

        XCTAssertNil(coordinator(AdaptiveHelloFields(cost: lowData, saveData: .off)).plan, "Off: full quality")
        XCTAssertNil(coordinator(AdaptiveHelloFields(saveData: .off), mac: macConstrained).plan)
        XCTAssertEqual(coordinator(AdaptiveHelloFields(cost: lowData, saveData: .auto, saveDataAnswer: .keepQuality)).plan?.origin,
                       .dataSaver, "No / Full Quality on mobile data still saves in Low Data Mode")
        XCTAssertEqual(coordinator(AdaptiveHelloFields(saveData: .auto, saveDataAnswer: .keepQuality), mac: macConstrained).dataPolicy.reason,
                       .lowDataMode, "the Mac's own Low Data Mode counts")
        XCTAssertNil(coordinator(AdaptiveHelloFields(saveData: .auto, saveDataAnswer: .saveData), mac: macMetered).plan,
                     "a metered Mac path alone never changes quality")
        XCTAssertNil(coordinator(AdaptiveHelloFields(), mac: macConstrained).plan, "no setting reported: today")
    }

    func testMacSidePolicyEvidenceKeepsOnlyLowDataMode() {
        let constrained = NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true, isConstrained: true),
                                                     reachability: .local)
        XCTAssertEqual(NetworkCost.macSidePolicyEvidence(constrained), constrained)
        let metered = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true), reachability: .remote)
        let filtered = NetworkCost.macSidePolicyEvidence(metered)
        XCTAssertEqual(filtered.cost, .unknown)
        XCTAssertEqual(filtered.interface, metered.interface)
        let wired = NetworkCost.endpointReport(.init(usesWired: true), reachability: .local)
        XCTAssertEqual(NetworkCost.macSidePolicyEvidence(wired), wired)
    }

    // MARK: - F7: the source cap's lower bound

    func testSourceRefreshBelow24HzIsUnknown() {
        let coordinator = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .automatic, displayMode: .mirror)
        let today = StreamingFPSPolicy.Result(fps: 120, reason: .requested)
        for hz in [1, 5, 15, 23] {
            coordinator.setSourceRefresh(hz)
            XCTAssertNil(coordinator.sourceRefreshHz, "\(hz) Hz")
            XCTAssertEqual(coordinator.resolveFPS(today), today, "no cap from \(hz) Hz")
        }
        coordinator.setSourceRefresh(24)
        XCTAssertEqual(coordinator.resolveFPS(today).fps, 24)
        coordinator.setSourceRefresh(60)
        XCTAssertEqual(coordinator.resolveFPS(today).fps, 60)
    }
}
