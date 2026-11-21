import AVFoundation
import XCTest

/// Phase 2 wiring of adaptive Automatic (#123): wire keys, the receiver's
/// telemetry/hello state, the Mac coordinator and planner. No capture or
/// encoder session is started: the sender side is a fake `applier`.
final class AdaptiveStreamingWiringTests: XCTestCase {
    // MARK: - Helpers

    private final class FakeApplier: AdaptiveStreamingApplying {
        var paths: [AdaptiveApplyPath] = []
        func adaptiveApply(_ path: AdaptiveApplyPath) { paths.append(path) }
    }

    /// Through real JSON, so bool/number bridging is what the wire produces.
    private func wire(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let iPad = AdaptiveReceiverDisplay(pointsWide: 1366, pointsHigh: 1024, scale: 2, sizeClass: .tablet)

    private func inputs(mode: RefreshNegotiation.DisplayMode = .extend) -> AdaptiveStreamingCoordinator.Inputs {
        AdaptiveStreamingCoordinator.Inputs(mode: mode, profile: .performance, customFPS: nil, receiverMaxFPS: 120,
                                            userMaxFPS: nil, codec: .hevc, receiver: iPad)
    }

    private func telemetryHello(saveData: NetworkCost.DataPreference? = .auto) -> AdaptiveHelloFields {
        AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, cost: nil, saveData: saveData, saveDataAnswer: nil)
    }

    /// A coordinator with a live controller (one tick done), and its fake.
    private func managedCoordinator(enabled: Bool = true, mode: RefreshNegotiation.DisplayMode = .extend,
                                    streamingMode: StreamingMode = .automatic,
                                    recorder: StreamDiagnosticsRecorder? = nil)
        -> (AdaptiveStreamingCoordinator, FakeApplier) {
        let coordinator = AdaptiveStreamingCoordinator(enabled: enabled, streamingMode: streamingMode, displayMode: mode)
        coordinator.recorder = recorder
        let fake = FakeApplier()
        coordinator.applier = fake
        coordinator.setSourceRefresh(120)
        coordinator.noteCaptureStarted(width: 2732, height: 2048, scale: 1)
        coordinator.helloAccepted(telemetryHello(), now: 0)
        coordinator.tick(generation: 1, inputs: inputs(mode: mode), window: window(0, 2), now: 2)
        return (coordinator, fake)
    }

    private func window(_ start: Double, _ end: Double, captured: Int = 120, encDrops: Int = 0,
                        netDrops: Int = 0) -> AdaptiveStreamingCoordinator.SenderWindow {
        AdaptiveStreamingCoordinator.SenderWindow(start: start, end: end, capturedFrames: captured,
                                                  encoderDrops: encDrops, networkDrops: netDrops,
                                                  thermal: .nominal, lowPower: false)
    }

    private func telemetry(delivered: Double) -> AdaptiveReceiverTelemetry {
        var t = AdaptiveReceiverTelemetry(windowSeconds: 2)
        t.deliveredFPS = delivered
        t.rttMs = 8
        t.jitterMs = 1
        t.thermal = .nominal
        t.lowPower = false
        return t
    }

    /// One 2 s window ending at `end`: `sent` frames reached the network.
    private func feed(_ coordinator: AdaptiveStreamingCoordinator, end: Double, generation: UInt64 = 1,
                      sent: Int, delivered: Double, encDrops: Int = 0, netDrops: Int = 0) {
        for _ in 0..<sent { coordinator.noteVideoSent(bytes: 30_000, now: end - 1) }
        coordinator.receiverStats(telemetry(delivered: delivered))
        coordinator.tick(generation: generation, inputs: inputs(),
                         window: window(end - 2, end, encDrops: encDrops, netDrops: netDrops), now: end)
    }

    // MARK: - Wire: hello

    func testHelloKeysRoundTripThroughJSON() throws {
        let fields = AdaptiveHelloFields(
            effectiveRefreshHz: 120, telemetry: true,
            cost: NetworkCost.EndpointReport(reachability: .local, interface: .cellular,
                                             cost: NetworkCost.CostEvidence(cost: .expensive, confidence: .high)),
            saveData: .auto, saveDataAnswer: .keepQuality)
        let object = try wire(fields.wireFields)
        XCTAssertEqual(object["effHz"] as? Int, 120)
        XCTAssertEqual(object["adaptiveTelemetry"] as? Int, 1)
        XCTAssertEqual(object["saveData"] as? String, "auto")
        XCTAssertEqual(object["saveDataAnswer"] as? String, "keepQuality")
        let cost = try XCTUnwrap(object["cost"] as? [String: Any])
        XCTAssertEqual(Set(cost.keys), ["cost", "conf", "iface"], "class, confidence and interface kind only")
        let parsed = AdaptiveHelloFields.parse(object)
        XCTAssertEqual(parsed.effectiveRefreshHz, 120)
        XCTAssertTrue(parsed.telemetry)
        XCTAssertEqual(parsed.saveData, .auto)
        XCTAssertEqual(parsed.saveDataAnswer, .keepQuality)
        XCTAssertEqual(parsed.cost?.cost, NetworkCost.CostEvidence(cost: .expensive, confidence: .high))
        XCTAssertEqual(parsed.cost?.interface, .cellular)
        XCTAssertEqual(parsed.cost?.reachability, .unknown, "the receiver never reports reachability")
    }

    func testHelloWithoutKeysIsAnOldPeer() throws {
        let parsed = AdaptiveHelloFields.parse(try wire(["type": "hello", "pixelsWide": 2732, "maxFPS": 120]))
        XCTAssertEqual(parsed, AdaptiveHelloFields())
        XCTAssertNil(parsed.effectiveRefreshHz)
        XCTAssertFalse(parsed.telemetry)
        XCTAssertNil(parsed.saveData)
        XCTAssertTrue(AdaptiveHelloFields().wireFields.isEmpty)
    }

    func testHelloGarbageReadsAsAbsent() throws {
        let garbage: [[String: Any]] = [
            ["effHz": "120", "adaptiveTelemetry": 1],
            ["effHz": true, "adaptiveTelemetry": 1],
            ["effHz": 0, "adaptiveTelemetry": 1],
            ["effHz": 999, "adaptiveTelemetry": 1],
            ["effHz": 59.5, "adaptiveTelemetry": 1],
            ["effHz": -60, "adaptiveTelemetry": 1],
        ]
        for object in garbage {
            let parsed = AdaptiveHelloFields.parse(try wire(object))
            XCTAssertNil(parsed.effectiveRefreshHz, "\(object)")
            XCTAssertFalse(parsed.telemetry, "telemetry travels with a valid effective refresh: \(object)")
        }
        // The flag alone (no effHz) is not telemetry.
        XCTAssertFalse(AdaptiveHelloFields.parse(try wire(["adaptiveTelemetry": 1])).telemetry)
        XCTAssertFalse(AdaptiveHelloFields.parse(try wire(["effHz": 60, "adaptiveTelemetry": true])).telemetry)
        XCTAssertFalse(AdaptiveHelloFields.parse(try wire(["effHz": 60, "adaptiveTelemetry": "1"])).telemetry)
        XCTAssertFalse(AdaptiveHelloFields.parse(try wire(["effHz": 60, "adaptiveTelemetry": 0])).telemetry)
        // A later telemetry version still means telemetry.
        XCTAssertTrue(AdaptiveHelloFields.parse(try wire(["effHz": 60, "adaptiveTelemetry": 2])).telemetry)

        let badCosts: [Any] = [
            "expensive", 3, ["cost": "free", "conf": "high"], ["cost": "expensive", "conf": "certain"],
            ["cost": "expensive"], ["cost": 2, "conf": "high"],
        ]
        for cost in badCosts {
            XCTAssertNil(AdaptiveHelloFields.parse(try wire(["cost": cost])).cost, "\(cost)")
        }
        let unknownInterface = AdaptiveHelloFields.parse(
            try wire(["cost": ["cost": "constrained", "conf": "medium", "iface": "satellite"]]))
        XCTAssertEqual(unknownInterface.cost?.interface, .unknown)
        XCTAssertEqual(unknownInterface.cost?.cost.cost, .constrained)

        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["saveData": "maybe"])).saveData)
        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["saveData": 1])).saveData)
        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["saveDataAnswer": "unanswered"])).saveDataAnswer)
        XCTAssertNil(AdaptiveHelloFields.parse(try wire(["saveDataAnswer": "yes"])).saveDataAnswer)
    }

    // MARK: - Wire: stats and ping

    func testStatsTelemetryRoundTripsAndOmitsAbsentValues() throws {
        var t = AdaptiveReceiverTelemetry(windowSeconds: 2.04)
        t.deliveredFPS = 59.94
        t.decodedFPS = 59
        t.enqueuedFPS = 58.5
        t.decodeP95Ms = 7.25
        t.presentationAgeMs = 12
        t.lateDrops = 3
        t.jitterMs = 1.5
        t.thermal = .serious
        t.lowPower = true
        var object = t.wireFields
        object["rtt"] = 9.0
        let parsed = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try wire(object)))
        XCTAssertEqual(parsed.windowSeconds, 2.0, accuracy: 0.051)
        XCTAssertEqual(parsed.deliveredFPS ?? 0, 59.9, accuracy: 0.001)
        XCTAssertEqual(parsed.decodedFPS, 59)
        XCTAssertEqual(parsed.enqueuedFPS, 58.5)
        XCTAssertEqual(parsed.decodeP95Ms ?? 0, 7.3, accuracy: 0.001)
        XCTAssertEqual(parsed.presentationAgeMs, 12)
        XCTAssertEqual(parsed.lateDrops, 3)
        XCTAssertEqual(parsed.rttMs, 9)
        XCTAssertEqual(parsed.jitterMs, 1.5)
        XCTAssertEqual(parsed.thermal, .serious)
        XCTAssertEqual(parsed.lowPower, true)

        let minimal = AdaptiveReceiverTelemetry(windowSeconds: 2).wireFields
        XCTAssertEqual(Set(minimal.keys), ["win"])
    }

    func testStatsWithoutWindowIsAnOldReceiver() throws {
        // Today's stats message, exactly as old receivers send it.
        let old: [String: Any] = ["type": "stats", "transport": "WiFi", "fps": 60, "mbps": 12.3, "rtt": 8,
                                  "stalls": 0, "offsetKnown": true]
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(old)))
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(["win": "2"])))
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(["win": true])))
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(["win": 0.1])))
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(["win": 3600])))
    }

    func testStatsGarbageValuesReadAsAbsent() throws {
        let parsed = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try wire([
            "win": 2, "deliveredFps": "60", "decodedFps": -1, "enqFps": 5000, "dec95": true, "presAge": -3,
            "late": 2.5, "jit": "x", "thermal": 9, "lowPower": 1, "rtt": -4,
        ])))
        XCTAssertNil(parsed.deliveredFPS)
        XCTAssertNil(parsed.decodedFPS)
        XCTAssertNil(parsed.enqueuedFPS)
        XCTAssertNil(parsed.decodeP95Ms)
        XCTAssertNil(parsed.presentationAgeMs)
        XCTAssertNil(parsed.lateDrops)
        XCTAssertNil(parsed.jitterMs)
        XCTAssertNil(parsed.thermal)
        XCTAssertNil(parsed.lowPower, "a number is not a bool")
        XCTAssertNil(parsed.rttMs)
        XCTAssertNil(AdaptiveReceiverTelemetry.parse(try wire(["win": 2, "thermal": 1.5]))?.thermal)
    }

    func testPingAnnounceKey() throws {
        XCTAssertTrue(AdaptiveStreamingWire.isAnnounced(inPing: try wire(["type": "ping", "adaptive": 1])))
        XCTAssertFalse(AdaptiveStreamingWire.isAnnounced(inPing: try wire(["type": "ping"])))
        XCTAssertFalse(AdaptiveStreamingWire.isAnnounced(inPing: try wire(["type": "ping", "adaptive": true])))
        XCTAssertFalse(AdaptiveStreamingWire.isAnnounced(inPing: try wire(["type": "ping", "adaptive": "1"])))
        XCTAssertFalse(AdaptiveStreamingWire.isAnnounced(inPing: try wire(["type": "ping", "adaptive": 2])))
        XCTAssertEqual(AdaptiveStreamingWire.pingSuffix(announcing: false), "")
        // The suffix the Mac appends must keep its hand-built ping valid JSON.
        let ping = "{\"type\":\"ping\",\"capFps\":60\(AdaptiveStreamingWire.pingSuffix(announcing: true))}"
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ping.utf8)) as? [String: Any])
        XCTAssertTrue(AdaptiveStreamingWire.isAnnounced(inPing: object))
    }

    // MARK: - Receiver: cadence, telemetry window, effective refresh

    func testAnnounceSwitchesStatsToTwoSecondCadence() throws {
        let state = ReceiverAdaptiveState()
        XCTAssertEqual(state.statsEveryWindows(now: 0), 5, "no announce: today's 5 s cadence")
        state.observeMacPing(try wire(["type": "ping", "adaptive": 1]), now: 10)
        XCTAssertEqual(state.statsEveryWindows(now: 11), 2)
        state.observeMacPing(try wire(["type": "ping"]), now: 12)
        XCTAssertEqual(state.statsEveryWindows(now: 12), 5, "a ping without the key ends it")
        state.observeMacPing(try wire(["type": "ping", "adaptive": 1]), now: 20)
        XCTAssertEqual(state.statsEveryWindows(now: 25.9), 2)
        XCTAssertEqual(state.statsEveryWindows(now: 26), 5, "no ping for 6 s ends it")
        state.observeMacPing(try wire(["type": "ping", "adaptive": 1]), now: 30)
        state.resetSession()
        XCTAssertEqual(state.statsEveryWindows(now: 30), 5, "a new session starts unannounced")
    }

    func testTelemetryKeysOnlyWhileAnnounced() throws {
        let state = ReceiverAdaptiveState()
        for i in 0..<120 { state.noteFrame(now: Double(i) / 60) }
        XCTAssertTrue(state.drainTelemetryFields(now: 2, decodeP95Ms: nil).isEmpty,
                      "stats to a Mac that does not announce stay exactly as before")
        state.observeMacPing(try wire(["type": "ping", "adaptive": 1]), now: 2)
        for i in 0..<100 { state.noteFrame(now: 2 + Double(i) / 50) }
        state.noteRTT(10)
        state.noteRTT(14)
        state.noteRTT(12)
        let fields = state.drainTelemetryFields(now: 4, decodeP95Ms: 6)
        let t = try XCTUnwrap(AdaptiveReceiverTelemetry.parse(try wire(fields)))
        XCTAssertEqual(t.windowSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(t.deliveredFPS ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(t.jitterMs ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(t.decodeP95Ms, 6)
        XCTAssertNotNil(t.thermal)
        XCTAssertNotNil(t.lowPower)
    }

    func testTelemetryWindowRejectsShortWindows() {
        var window = AdaptiveReceiverTelemetryWindow()
        XCTAssertNil(window.drain(now: 1, decodeP95Ms: nil, thermal: nil, lowPower: nil), "no frame yet")
        window.noteFrame(now: 1)
        XCTAssertNil(window.drain(now: 1.2, decodeP95Ms: nil, thermal: nil, lowPower: nil))
        window.noteFrame(now: 1.5)
        let t = window.drain(now: 3.2, decodeP95Ms: 0, thermal: .fair, lowPower: false)
        XCTAssertEqual(t?.windowSeconds ?? 0, 2, accuracy: 0.001, "the next window starts where the last ended")
        XCTAssertNil(t?.decodeP95Ms, "zero means not measured")
        XCTAssertNil(t?.jitterMs)
    }

    func testEffectiveRefreshResolution() {
        XCTAssertEqual(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 120, lowPowerMode: false), 120)
        XCTAssertEqual(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 120, lowPowerMode: true), 60)
        XCTAssertEqual(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 60, lowPowerMode: true), 60)
        XCTAssertEqual(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 48, lowPowerMode: false), 48)
        XCTAssertNil(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 0, lowPowerMode: false))
        XCTAssertEqual(ReceiverEffectiveRefresh.resolve(maximumFramesPerSecond: 500, lowPowerMode: false), 240)
    }

    /// #123 A9 changed this test: a re-send is now gated on a change the
    /// Mac uses since the last hello that went out, at most once per
    /// `AdaptiveHelloResendGate.minimumIntervalSeconds` (latest values win),
    /// instead of once per raw change.
    func testHelloIsResentWhenEffectiveRefreshPathOrPreferenceChanges() {
        let state = ReceiverAdaptiveState()
        let gap = AdaptiveHelloResendGate.minimumIntervalSeconds
        XCTAssertFalse(state.consumeHelloResend(now: 0), "no hello sent yet: the first one carries everything")
        XCTAssertTrue(state.helloFields.wireFields["effHz"] == nil, "no refresh known: legacy hello")
        XCTAssertNil(state.helloFields.wireFields["adaptiveTelemetry"], "the flag never travels alone")
        state.noteHelloSent(state.helloFields, now: 0)

        state.setEffectiveRefresh(120)
        XCTAssertFalse(state.consumeHelloResend(now: 1), "inside the interval: waits")
        XCTAssertTrue(state.consumeHelloResend(now: gap))
        state.noteHelloSent(state.helloFields, now: gap)
        XCTAssertFalse(state.consumeHelloResend(now: 2 * gap), "sent: nothing changed since")
        state.setEffectiveRefresh(120)
        XCTAssertFalse(state.consumeHelloResend(now: 3 * gap), "same value: nothing to send")
        state.setEffectiveRefresh(60)   // Low Power Mode capped ProMotion
        XCTAssertTrue(state.consumeHelloResend(now: 3 * gap))
        XCTAssertEqual(state.helloFields.wireFields["effHz"] as? Int, 60)
        XCTAssertEqual(state.helloFields.wireFields["adaptiveTelemetry"] as? Int, 1)
        state.noteHelloSent(state.helloFields, now: 3 * gap)

        let wifi = NetworkCost.endpointReport(NetworkCost.PathFlags(usesWiFi: true), reachability: .local)
        state.setPath(wifi)
        XCTAssertTrue(state.consumeHelloResend(now: 4 * gap), "the cost class is new")
        state.noteHelloSent(state.helloFields, now: 4 * gap)
        state.setPath(wifi)
        XCTAssertFalse(state.consumeHelloResend(now: 5 * gap))

        state.setSettings(UseLessDataSettings(preference: .on, answer: .unanswered, dismissals: 0))
        XCTAssertTrue(state.consumeHelloResend(now: 5 * gap))
        XCTAssertEqual(state.helloFields.wireFields["saveData"] as? String, "on")

        state.setEffectiveRefresh(120)
        state.noteHelloSent(state.helloFields, now: 5 * gap)
        XCTAssertFalse(state.consumeHelloResend(now: 6 * gap), "a hello that went out anyway carried the change")
    }

    // MARK: - "Use less data" on each receiver

    func testUseLessDataReportingDecidesWhatHelloCarries() {
        for preference in NetworkCost.DataPreference.allCases {
            for answer in NetworkCost.MeteredAnswer.allCases {
                let settings = UseLessDataSettings(preference: preference, answer: answer, dismissals: 0)
                let none = UseLessDataReporting.none.helloValues(settings)
                XCTAssertNil(none.saveData)
                XCTAssertNil(none.answer)
                let mac = UseLessDataReporting.preferenceOnly.helloValues(settings)
                XCTAssertEqual(mac.saveData, preference)
                XCTAssertNil(mac.answer, "the Mac Receiver has no suggestion: never an answer")
                let ios = UseLessDataReporting.preferenceAndAnswer.helloValues(settings)
                XCTAssertEqual(ios.saveData, preference)
                XCTAssertEqual(ios.answer, answer == .unanswered ? nil : answer)
            }
        }
    }

    /// The Mac Receiver's hello with each preference (and a stale answer in
    /// its defaults, which it must never send), the Mac's resulting policy,
    /// and the debounced re-hello on a change.
    func testMacReceiverHelloCarriesItsUseLessDataPreferenceOnly() throws {
        let lowDataMode = NetworkCost.endpointReport(.init(usesWiFi: true, isConstrained: true), reachability: .local)
        let meteredWiFi = NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true), reachability: .local)
        let expected: [NetworkCost.DataPreference: (lowData: NetworkCost.DataPolicy, metered: NetworkCost.DataPolicy)] = [
            .auto: (.saver, .normal), .on: (.saver, .saver), .off: (.normal, .normal),
        ]
        for preference in NetworkCost.DataPreference.allCases {
            let state = ReceiverAdaptiveState()
            state.setEffectiveRefresh(60)
            state.setSettings(UseLessDataSettings(preference: preference, answer: .saveData, dismissals: 0),
                              suggestionsEnabled: false, reporting: .preferenceOnly)
            for (path, policy) in [(lowDataMode, expected[preference]?.lowData), (meteredWiFi, expected[preference]?.metered)] {
                state.setPath(path)
                let object = try wire(state.helloFields.wireFields)
                XCTAssertEqual(object["saveData"] as? String, preference.rawValue)
                XCTAssertNil(object["saveDataAnswer"], "\(preference)")
                XCTAssertNotNil(object["cost"], "the shared path evidence rides along")
                let coordinator = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .extend)
                coordinator.helloAccepted(AdaptiveHelloFields.parse(object), now: 0)
                XCTAssertEqual(coordinator.dataPolicy.policy, policy, "\(preference) \(path.cost.cost)")
            }
        }

        // The setting never opened: Automatic, like iOS.
        let fresh = ReceiverAdaptiveState()
        fresh.setSettings(UseLessDataSettings.load(UserDefaults(suiteName: "adaptive2.\(UUID().uuidString)")!),
                          suggestionsEnabled: false, reporting: .preferenceOnly)
        XCTAssertEqual(fresh.helloFields.saveData, .auto)

        // A stored dismissal count is bounded on load and when applied: a
        // corrupted value must not be replayed one by one at launch.
        let corrupted = UserDefaults(suiteName: "adaptive2.\(UUID().uuidString)")!
        corrupted.set(Int.max, forKey: UseLessDataSettings.dismissalsKey)
        XCTAssertEqual(UseLessDataSettings.load(corrupted).dismissals, NetworkCostSuggestionTracker.maxDismissals)
        corrupted.set(-5, forKey: UseLessDataSettings.dismissalsKey)
        XCTAssertEqual(UseLessDataSettings.load(corrupted).dismissals, 0)
        let bounded = ReceiverAdaptiveState()
        bounded.setSettings(UseLessDataSettings(preference: .auto, answer: .unanswered, dismissals: Int.max))

        // A change re-sends hello through the debounced gate.
        fresh.noteHelloSent(fresh.helloFields, now: 0)
        fresh.setSettings(UseLessDataSettings(preference: .off), suggestionsEnabled: false, reporting: .preferenceOnly)
        XCTAssertFalse(fresh.consumeHelloResend(now: 1), "inside the interval")
        XCTAssertTrue(fresh.consumeHelloResend(now: AdaptiveHelloResendGate.minimumIntervalSeconds))
    }

    // MARK: - Path to cost evidence

    func testPathFlagsMapToCostEvidence() {
        func report(_ flags: NetworkCost.PathFlags) -> NetworkCost.EndpointReport {
            NetworkCost.endpointReport(flags, reachability: .local)
        }
        XCTAssertEqual(report(.init(usesCellular: true, isExpensive: true)).cost,
                       NetworkCost.CostEvidence(cost: .expensive, confidence: .high))
        XCTAssertEqual(report(.init(usesCellular: true, isExpensive: true)).interface, .cellular)
        XCTAssertEqual(report(.init(usesWiFi: true)).cost, NetworkCost.CostEvidence(cost: .unmetered, confidence: .high))
        XCTAssertEqual(report(.init(usesWiFi: true, isExpensive: true)).cost.cost, .expensive, "a hotspot is Wi-Fi")
        XCTAssertEqual(report(.init(usesWired: true, isExpensive: true, isConstrained: true)).cost.cost, .constrained)
        XCTAssertEqual(report(.init(usesLoopback: true, isExpensive: true)).cost,
                       NetworkCost.CostEvidence(cost: .unmetered, confidence: .high), "USB is wired")
        // A tunnel is never cellular, and "not expensive" through it proves nothing.
        let tunnel = report(.init(isTunnel: true))
        XCTAssertEqual(tunnel.interface, .tunnel)
        XCTAssertEqual(tunnel.cost, .unknown)
        XCTAssertEqual(report(.init(isTunnel: true, isExpensive: true)).cost,
                       NetworkCost.CostEvidence(cost: .expensive, confidence: .medium))
        XCTAssertEqual(report(.init()).cost, .unknown, "unknown stays unknown")
        XCTAssertTrue(NetworkCost.isTunnelInterfaceName("utun4"))
        XCTAssertFalse(NetworkCost.isTunnelInterfaceName("en0"))
    }

    // MARK: - Data policy and the saver plan

    func testReceiverDataPolicyMatrix() {
        func path(_ cost: NetworkCost.Cost, _ confidence: NetworkCost.Confidence = .high) -> NetworkCost.PathAssessment {
            NetworkCost.PathAssessment(reachability: .local, interface: .unknown,
                                       cost: NetworkCost.CostEvidence(cost: cost, confidence: confidence))
        }
        typealias C = (NetworkCost.PathAssessment, NetworkCost.DataPreference?, NetworkCost.MeteredAnswer?,
                       NetworkCost.DataPolicy, NetworkCost.PolicyReason)
        let cases: [C] = [
            (path(.constrained), nil, nil, .normal, .notReported),            // old receiver: today
            (path(.expensive), nil, .saveData, .normal, .notReported),
            (path(.unmetered), .on, nil, .saver, .preferenceOn),
            (path(.constrained), .off, nil, .normal, .preferenceOff),
            (path(.constrained), .auto, nil, .saver, .lowDataMode),
            (path(.expensive), .auto, nil, .normal, .awaitingAnswer),         // the suggestion asks first
            (path(.expensive), .auto, .saveData, .saver, .meteredPath),
            (path(.expensive), .auto, .keepQuality, .normal, .higherQualityOverride),
            // Lead decision: "No" / Full Quality covers mobile data only; Low Data Mode still saves.
            (path(.constrained), .auto, .keepQuality, .saver, .lowDataMode),
            (path(.constrained, .medium), .auto, .keepQuality, .saver, .lowDataMode),
            (path(.constrained, .low), .auto, .keepQuality, .normal, .higherQualityOverride),
            (path(.expensive, .low), .auto, .saveData, .normal, .notClearlyMetered),
            (path(.unknown), .auto, .saveData, .normal, .notClearlyMetered),
        ]
        for (index, c) in cases.enumerated() {
            let decision = NetworkCost.receiverDataPolicy(path: c.0, preference: c.1, answer: c.2)
            XCTAssertEqual(decision.policy, c.3, "case \(index)")
            XCTAssertEqual(decision.reason, c.4, "case \(index)")
        }
    }

    func testPlannerSaverPlanAndCustomBypass() {
        let saver = AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: false,
                                                  dataPolicy: .saver, decision: nil, mode: .extend)
        XCTAssertEqual(saver, AdaptiveStreamingPlan(rasterScale: StreamQuality.balanced.scale,
                                                    bitrate: StreamQuality.balanced.bitrate, fpsCap: 60,
                                                    origin: .dataSaver))
        XCTAssertEqual(AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: false,
                                                     dataPolicy: .saver, decision: nil, mode: .window)?.rasterScale,
                       1.0, "Window view keeps its canvas")
        for adaptive in [false, true] {
            XCTAssertNil(AdaptiveStreamingPlanner.plan(streamingMode: .custom, adaptiveEnabled: adaptive,
                                                       dataPolicy: .saver, decision: nil, mode: .extend),
                         "Custom is never overridden")
            XCTAssertNil(AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: adaptive,
                                                       dataPolicy: .normal, decision: nil, mode: .extend))
        }
        // The controller's fixed policy (no telemetry) is today, unless saving data.
        let fixed = AdaptiveStreamingDecision(action: .fixedPolicy, point: AdaptiveOperatingPoint(rasterScale: 1, bitrate: 18_000_000, fps: 120),
                                              previous: nil, changed: [], cost: .none, reason: .legacyPeerFixedPolicy,
                                              cause: .none, evidence: AdaptiveStreamingEvidence())
        XCTAssertNil(AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: true,
                                                   dataPolicy: .normal, decision: fixed, mode: .mirror))
        XCTAssertEqual(AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: true,
                                                     dataPolicy: .saver, decision: fixed, mode: .mirror)?.origin, .dataSaver)
    }

    func testSaverWorksWithAdaptiveOffForThatReceiverOnly() {
        let saving = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
        let other = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
        let savingFake = FakeApplier(), otherFake = FakeApplier()
        saving.applier = savingFake
        other.applier = otherFake
        saving.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        other.helloAccepted(AdaptiveHelloFields(saveData: .auto), now: 0)
        let today = StreamingFPSPolicy.Result(fps: 120, reason: .requested)
        XCTAssertEqual(saving.resolveFPS(today).fps, 60)
        XCTAssertEqual(saving.encoderBitrate(today: 18_000_000), StreamQuality.balanced.bitrate)
        XCTAssertEqual(saving.captureScale(today: 1), StreamQuality.balanced.scale)
        XCTAssertEqual(savingFake.paths, [.captureRestart])
        XCTAssertEqual(other.resolveFPS(today), today)
        XCTAssertTrue(otherFake.paths.isEmpty)

        // Turning "Use less data" off again (or "Full Quality") returns to today.
        saving.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 1)
        XCTAssertNil(saving.plan)
        XCTAssertEqual(saving.resolveFPS(today), today)
        XCTAssertEqual(savingFake.paths, [.captureRestart, .captureRestart])

        let custom = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .custom, displayMode: .mirror)
        custom.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        XCTAssertNil(custom.plan, "Custom bypasses saving too")
    }

    func testSenderMeteredPathAloneNeverChangesQuality() {
        // Lead decision (#123 F4): a metered Mac path (`isExpensive`) alone
        // never changes quality, answered or not.
        let coordinator = AdaptiveStreamingCoordinator(enabled: false, streamingMode: .automatic, displayMode: .mirror)
        let metered = NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true), reachability: .local)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .auto), now: 0)
        coordinator.senderPathChanged(metered, epoch: 1, now: 0)
        XCTAssertEqual(coordinator.dataPolicy.reason, .notClearlyMetered)
        XCTAssertNil(coordinator.plan)
        coordinator.helloAccepted(AdaptiveHelloFields(saveData: .auto, saveDataAnswer: .saveData), now: 1)
        XCTAssertNil(coordinator.plan)
        // The receiver's own metered path with its answer still saves, and
        // the full-quality choice is reversible and respected.
        let cellular = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true), reachability: .local)
        coordinator.helloAccepted(AdaptiveHelloFields(cost: cellular, saveData: .auto, saveDataAnswer: .saveData), now: 2)
        XCTAssertEqual(coordinator.plan?.origin, .dataSaver)
        coordinator.helloAccepted(AdaptiveHelloFields(cost: cellular, saveData: .auto, saveDataAnswer: .keepQuality), now: 3)
        XCTAssertNil(coordinator.plan, "the full-quality choice is reversible and respected")
    }

    // MARK: - Adaptive off is today

    func testAdaptiveOffResolvesExactlyTodaysFPSAndQuality() {
        let todays: [StreamingFPSPolicy.Result] = [
            .init(fps: 120, reason: .requested), .init(fps: 60, reason: .receiverCapability),
            .init(fps: 48, reason: .encoderThroughput), .init(fps: 30, reason: .userCeiling),
            .init(fps: 90, reason: .requested),
        ]
        let hellos: [AdaptiveHelloFields] = [
            AdaptiveHelloFields(),
            telemetryHello(saveData: nil),
            telemetryHello(saveData: .off),
            AdaptiveHelloFields(effectiveRefreshHz: 60, telemetry: true, cost: nil, saveData: .auto, saveDataAnswer: .keepQuality),
        ]
        for streamingMode in [StreamingMode.automatic, .custom] {
            for mode in RefreshNegotiation.DisplayMode.allCases {
                for hello in hellos {
                    for source in [nil, 24, 60, 120] as [Int?] {
                        let coordinator = AdaptiveStreamingCoordinator(enabled: false, streamingMode: streamingMode,
                                                                       displayMode: mode)
                        let fake = FakeApplier()
                        coordinator.applier = fake
                        coordinator.setSourceRefresh(source)
                        coordinator.noteCaptureStarted(width: 2732, height: 2048, scale: 1)
                        coordinator.helloAccepted(hello, now: 0)
                        for tick in 1...4 {
                            coordinator.receiverStats(telemetry(delivered: 20))
                            coordinator.tick(generation: 1, inputs: inputs(mode: mode),
                                             window: window(Double(tick - 1) * 2, Double(tick) * 2, netDrops: 50),
                                             now: Double(tick) * 2)
                        }
                        XCTAssertFalse(coordinator.announcesAdaptive)
                        XCTAssertNil(coordinator.plan)
                        XCTAssertTrue(fake.paths.isEmpty)
                        for today in todays {
                            XCTAssertEqual(coordinator.resolveFPS(today), today)
                        }
                        for scale in [1.0, 0.75, 0.5] {
                            XCTAssertEqual(coordinator.captureScale(today: scale), scale)
                        }
                        for bitrate in [18_000_000, 10_000_000, 6_000_000] {
                            XCTAssertEqual(coordinator.encoderBitrate(today: bitrate), bitrate)
                        }
                    }
                }
            }
        }
    }

    func testAdaptiveOnInCustomIsNeverManaged() {
        let (coordinator, fake) = managedCoordinator(streamingMode: .custom)
        XCTAssertFalse(coordinator.announcesAdaptive)
        feed(coordinator, end: 4, sent: 100, delivered: 50, netDrops: 20)
        XCTAssertNil(coordinator.plan)
        XCTAssertTrue(fake.paths.isEmpty)
    }

    func testPeerWithoutTelemetryKeepsTheFixedPolicyCappedAtTheSource() {
        let coordinator = AdaptiveStreamingCoordinator(enabled: true, streamingMode: .automatic, displayMode: .mirror)
        let fake = FakeApplier()
        coordinator.applier = fake
        coordinator.setSourceRefresh(60)
        coordinator.noteCaptureStarted(width: 3024, height: 1964, scale: 1)
        coordinator.helloAccepted(AdaptiveHelloFields(), now: 0)
        coordinator.tick(generation: 1, inputs: inputs(mode: .mirror), window: window(0, 2), now: 2)
        XCTAssertEqual(coordinator.lastDecision?.action, .fixedPolicy)
        XCTAssertNil(coordinator.plan)
        XCTAssertTrue(fake.paths.isEmpty)
        // Adaptive on never captures above the source's cadence.
        XCTAssertEqual(coordinator.resolveFPS(.init(fps: 120, reason: .requested)).fps, 60)
        XCTAssertEqual(coordinator.encoderBitrate(today: 18_000_000), 18_000_000)
    }

    // MARK: - Applying decisions

    func testApplyPathPerDecisionClass() {
        let base = AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller)
        var fps = base; fps.fpsCap = 30
        var bitrate = base; bitrate.bitrate = 15_000_000
        var raster = base; raster.rasterScale = 0.875
        var both = fps; both.bitrate = 15_000_000
        var rasterAndBitrate = raster; rasterAndBitrate.bitrate = 15_000_000
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: base), .none)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: fps), .liveFPSUpdate)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: bitrate), .encoderRebuild)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: both), .encoderRebuild)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: raster), .captureRestart)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: rasterAndBitrate), .captureRestart)
        // nil is today's point (native raster, Best bitrate): starting the
        // controller at Best costs no encoder rebuild.
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: nil, to: base), .liveFPSUpdate)
        XCTAssertEqual(AdaptiveStreamingPlanner.applyPath(from: base, to: nil), .liveFPSUpdate)
    }

    func testControllerStartsSixtyFirstThroughALiveFPSUpdate() {
        let (coordinator, fake) = managedCoordinator()
        XCTAssertTrue(coordinator.announcesAdaptive)
        XCTAssertEqual(coordinator.plan, AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 60, origin: .controller))
        XCTAssertEqual(fake.paths, [.liveFPSUpdate])
        XCTAssertEqual(coordinator.resolveFPS(.init(fps: 120, reason: .requested)).fps, 60)
    }

    func testNetworkDownshiftRebuildsTheEncoderAndRasterRestartsCapture() {
        // Network: backpressure lowers the bitrate (encoder rebuild).
        let (network, networkFake) = managedCoordinator()
        var end = 4.0
        for _ in 0..<2 {
            feed(network, end: end, sent: 100, delivered: 50, netDrops: 20)
            end += 2
        }
        XCTAssertEqual(network.lastDecision?.changed, [.bitrate])
        XCTAssertEqual(network.plan?.bitrate, 15_000_000)
        XCTAssertEqual(networkFake.paths, [.liveFPSUpdate, .encoderRebuild])

        // Encoder overload: the raster goes down (capture restart), never the bitrate.
        let (overload, overloadFake) = managedCoordinator()
        end = 4
        for _ in 0..<2 {
            feed(overload, end: end, sent: 80, delivered: 40, encDrops: 12)
            end += 2
        }
        XCTAssertEqual(overload.lastDecision?.changed, [.raster])
        XCTAssertEqual(overload.plan?.bitrate, 18_000_000)
        XCTAssertLessThan(overload.plan?.rasterScale ?? 1, 1)
        XCTAssertEqual(overloadFake.paths, [.liveFPSUpdate, .captureRestart])
    }

    func testEveryChangeTakesThePathOfItsDimension() {
        let (coordinator, fake) = managedCoordinator()
        var end = 4.0
        var expected: [AdaptiveApplyPath] = [.liveFPSUpdate]
        let script: [(sent: Int, delivered: Double, enc: Int, net: Int)] =
            Array(repeating: (100, 50, 0, 20), count: 6) + Array(repeating: (80, 40, 12, 0), count: 6)
            + Array(repeating: (120, 60, 0, 0), count: 30)
        for step in script {
            let before = coordinator.plan
            feed(coordinator, end: end, sent: step.sent, delivered: step.delivered, encDrops: step.enc, netDrops: step.net)
            end += 2
            if coordinator.plan != before {
                expected.append(AdaptiveStreamingPlanner.applyPath(from: before, to: coordinator.plan))
                let changed = coordinator.lastDecision?.changed ?? []
                if changed.contains(.raster) {
                    XCTAssertEqual(expected.last, .captureRestart)
                } else if changed.contains(.bitrate) {
                    XCTAssertEqual(expected.last, .encoderRebuild)
                } else if changed.contains(.fps) {
                    XCTAssertEqual(expected.last, .liveFPSUpdate)
                }
            }
        }
        XCTAssertEqual(fake.paths, expected)
        XCTAssertTrue(fake.paths.contains(.encoderRebuild))
        XCTAssertTrue(fake.paths.contains(.captureRestart))
        for path in fake.paths { XCTAssertNotEqual(path, .none) }
        XCTAssertLessThanOrEqual(coordinator.plan?.bitrate ?? 0, AdaptiveStreamingPlanner.bitrateCeiling)
    }

    func testOneReceiversDecisionNeverTouchesAnother() {
        // #123 A1 changed this test: the healthy 120 Hz receiver now probes
        // 120 on its own evidence (before the fix it never could), so
        // isolation is checked against its solo run instead of "no change".
        let (congested, congestedFake) = managedCoordinator()
        let (healthy, healthyFake) = managedCoordinator()
        let (solo, soloFake) = managedCoordinator()
        var end = 4.0
        for _ in 0..<12 {
            feed(congested, end: end, sent: 100, delivered: 50, netDrops: 20)
            feed(healthy, end: end, sent: 120, delivered: 60)
            feed(solo, end: end, sent: 120, delivered: 60)
            end += 2
        }
        XCTAssertGreaterThan(congestedFake.paths.count, 1)
        XCTAssertEqual(healthyFake.paths, soloFake.paths, "only its own decisions, nothing from the other receiver")
        XCTAssertEqual(healthy.plan, solo.plan)
        XCTAssertGreaterThanOrEqual(healthy.plan?.fpsCap ?? 0, 60, "never stepped down")
        XCTAssertEqual(healthy.plan?.bitrate, 18_000_000)
        XCTAssertEqual(healthy.plan?.rasterScale, 1)
    }

    func testBitrateLadderNeverExceedsTodaysBest() {
        XCTAssertEqual(AdaptiveStreamingLadder.bitrateCeiling, StreamQuality.best.bitrate)
        XCTAssertEqual(AdaptiveStreamingLadder.standard.bitrateSteps.max(), AdaptiveStreamingLadder.bitrateCeiling)
        let high = AdaptiveStreamingDecision(action: .upshift, point: AdaptiveOperatingPoint(rasterScale: 1, bitrate: 24_000_000, fps: 60),
                                             previous: nil, changed: [.bitrate], cost: .encoderReconfigure,
                                             reason: .upshiftBitrate, cause: .healthy, evidence: AdaptiveStreamingEvidence())
        XCTAssertEqual(AdaptiveStreamingPlanner.plan(streamingMode: .automatic, adaptiveEnabled: true,
                                                     dataPolicy: .normal, decision: high, mode: .extend)?.bitrate,
                       18_000_000)
        XCTAssertEqual(AdaptiveStreamingPlanner.resolveBitrate(
            today: 18_000_000, plan: AdaptiveStreamingPlan(rasterScale: 1, bitrate: 24_000_000, fpsCap: nil, origin: .controller)),
                       18_000_000)
    }

    // MARK: - Generation and route epoch

    func testNewGenerationResetsTheController() {
        let (coordinator, fake) = managedCoordinator()
        feed(coordinator, end: 4, sent: 100, delivered: 50, netDrops: 20)
        feed(coordinator, end: 6, sent: 100, delivered: 50, netDrops: 20)
        XCTAssertEqual(coordinator.plan?.bitrate, 15_000_000)
        // Reconnect: telemetry from the old connection is dropped and the
        // controller starts over at the initial point.
        coordinator.receiverStats(telemetry(delivered: 10))
        coordinator.tick(generation: 2, inputs: inputs(), window: window(6, 8), now: 8)
        XCTAssertEqual(coordinator.generation, 2)
        // #123 A8 changed this test: the reset's bitrate change waits for the
        // 4 s encoder-rebuild limit (the 15 Mbps rebuild ran at 6 s), then applies.
        XCTAssertEqual(coordinator.desiredPlan?.bitrate, 18_000_000)
        XCTAssertEqual(coordinator.plan?.bitrate, 15_000_000)
        coordinator.tick(generation: 2, inputs: inputs(), window: window(8, 10), now: 10)
        XCTAssertEqual(coordinator.plan?.bitrate, 18_000_000)
        XCTAssertEqual(fake.paths.last, .encoderRebuild)
        XCTAssertNotEqual(coordinator.lastDecision?.action, .downshift)
    }

    func testStaleRouteEpochIsIgnored() {
        let (coordinator, _) = managedCoordinator()
        let wifi = NetworkCost.endpointReport(.init(usesWiFi: true), reachability: .local)
        // The Mac's own Low Data Mode (the only Mac-side evidence that counts, #123 F4).
        let cellular = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true, isConstrained: true),
                                                  reachability: .remote)
        XCTAssertTrue(coordinator.senderPathChanged(wifi, epoch: 2, now: 3))
        XCTAssertEqual(coordinator.lastDecision?.reason, .routeChangeSettling)
        XCTAssertFalse(coordinator.senderPathChanged(cellular, epoch: 1, now: 3.5), "older epoch: stale callback")
        XCTAssertFalse(coordinator.senderPathChanged(cellular, epoch: 2, now: 3.6), "same epoch: already seen")
        XCTAssertEqual(coordinator.routeEpoch, 2)
        XCTAssertEqual(coordinator.dataPolicy.reason, .notClearlyMetered, "the stale cellular report changed nothing")
        XCTAssertTrue(coordinator.senderPathChanged(cellular, epoch: 3, now: 4))
        XCTAssertEqual(coordinator.dataPolicy.reason, .lowDataMode)
    }

    // MARK: - One-time suggestion

    func testSuggestionShownOncePerEpisodeOnlyOnReliableMeteredEvidence() {
        let state = ReceiverAdaptiveState()
        state.setSettings(UseLessDataSettings(), suggestionsEnabled: true)
        let cellular = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true), reachability: .local)
        state.setPath(cellular)
        XCTAssertFalse(state.checkSuggestion(now: 1), "no live media yet")
        state.noteFrame(now: 2)
        XCTAssertTrue(state.checkSuggestion(now: 2))
        state.noteFrame(now: 4)
        XCTAssertFalse(state.checkSuggestion(now: 4), "once per episode")
        state.noteFrame(now: 30)
        XCTAssertFalse(state.checkSuggestion(now: 30))
        let saved = state.recordSuggestion(answer: .saveData)
        XCTAssertEqual(saved.answer, .saveData)
        XCTAssertEqual(state.helloFields.saveDataAnswer, .saveData)
        state.noteFrame(now: 500)
        XCTAssertFalse(state.checkSuggestion(now: 500), "answered: never again")

        let lowData = ReceiverAdaptiveState()
        lowData.setSettings(UseLessDataSettings(), suggestionsEnabled: true)
        lowData.setPath(NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true, isConstrained: true),
                                                   reachability: .local))
        lowData.noteFrame(now: 1)
        XCTAssertFalse(lowData.checkSuggestion(now: 1), "Low Data Mode is honoured silently")

        let tunnel = ReceiverAdaptiveState()
        tunnel.setSettings(UseLessDataSettings(), suggestionsEnabled: true)
        tunnel.setPath(NetworkCost.endpointReport(.init(isTunnel: true, isExpensive: true), reachability: .remote))
        tunnel.noteFrame(now: 1)
        XCTAssertFalse(tunnel.checkSuggestion(now: 1), "medium-confidence evidence never asks")

        let macReceiver = ReceiverAdaptiveState()
        macReceiver.setPath(cellular)
        macReceiver.noteFrame(now: 1)
        XCTAssertFalse(macReceiver.checkSuggestion(now: 1), "no prompt UI: never asks")

        let off = ReceiverAdaptiveState()
        off.setSettings(UseLessDataSettings(preference: .off), suggestionsEnabled: true)
        off.setPath(cellular)
        off.noteFrame(now: 1)
        XCTAssertFalse(off.checkSuggestion(now: 1))
    }

    func testUseLessDataSettingsPersist() throws {
        let suite = "AdaptiveStreamingWiringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UseLessDataSettings.load(defaults), UseLessDataSettings(), "default: Automatic, unanswered")
        let chosen = UseLessDataSettings(preference: .on, answer: .keepQuality, dismissals: 1)
        chosen.save(defaults)
        XCTAssertEqual(UseLessDataSettings.load(defaults), chosen)
        defaults.set("bogus", forKey: UseLessDataSettings.preferenceKey)
        XCTAssertEqual(UseLessDataSettings.load(defaults).preference, .auto)
    }

    // MARK: - Explainability and data accounting

    func testDecisionsAreRecordedOnlyWhileDiagnosticsAreOn() throws {
        let on = StreamDiagnosticsRecorder(side: .sender, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                           resourceSampler: nil)
        let (coordinator, _) = managedCoordinator(recorder: on)
        feed(coordinator, end: 4, sent: 100, delivered: 50, netDrops: 20)
        feed(coordinator, end: 6, sent: 100, delivered: 50, netDrops: 20)
        let decisions = try XCTUnwrap(on.snapshot().adaptiveDecisions)
        XCTAssertEqual(decisions.first?.action, .initial)
        let downshift = try XCTUnwrap(decisions.first { $0.action == .downshift })
        XCTAssertEqual(downshift.reason, .networkBitrateDown)
        XCTAssertEqual(downshift.cause, .network)
        XCTAssertEqual(downshift.bitrateMbps, 15)
        XCTAssertNotNil(downshift.evidence.sendBackpressure)

        let off = StreamDiagnosticsRecorder(side: .sender, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: false),
                                            resourceSampler: nil)
        let (quiet, _) = managedCoordinator(recorder: off)
        feed(quiet, end: 4, sent: 100, delivered: 50, netDrops: 20)
        XCTAssertNil(off.snapshot().adaptiveDecisions)

        // The export carries them as codes and numbers only.
        let export = StreamDiagnosticsExport(sessions: [on.snapshot()],
                                             build: StreamDiagnosticsBuildInfo.current(deviceClass: .mac))
        let json = try XCTUnwrap(String(data: try export.jsonData(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"adaptiveDecisions\""))
        XCTAssertTrue(json.contains("\"networkBitrateDown\""))
        on.reset()
        XCTAssertNil(on.snapshot().adaptiveDecisions)
    }

    func testDataAccountingCountsVideoPayloadPerReceiver() {
        let (coordinator, _) = managedCoordinator()
        for _ in 0..<100 { coordinator.noteVideoSent(bytes: 50_000, now: 10) }
        // #123: sends are counted on the sender queue without a lock and
        // reach the monitor once per tick (this line was added).
        coordinator.publishUsage()
        let snapshot = coordinator.monitor.snapshot(now: 14)
        XCTAssertEqual(snapshot.videoPayloadBytes, 5_000_000)
        XCTAssertEqual(snapshot.averageBitsPerSecond ?? 0, 10_000_000, accuracy: 1)
        XCTAssertEqual(AdaptiveUsageText.payload(snapshot), "5.0 MB · 10.0 Mbit/s average")
        XCTAssertEqual(AdaptiveUsageText.plan(snapshot), "Adaptive: 100% · 18 Mbit/s · up to 60 fps")
        let fresh = AdaptiveStreamingMonitor().snapshot(now: 0)
        XCTAssertEqual(fresh.videoPayloadBytes, 0)
        XCTAssertNil(fresh.averageBitsPerSecond)
        XCTAssertNil(AdaptiveUsageText.plan(fresh))
    }

    func testResolveFPSKeepsTodaysReasonAndTakesTheLowestCap() {
        let today = StreamingFPSPolicy.Result(fps: 120, reason: .receiverCapability)
        let plan = AdaptiveStreamingPlan(rasterScale: 1, bitrate: 18_000_000, fpsCap: 90, origin: .controller)
        XCTAssertEqual(AdaptiveStreamingPlanner.resolveFPS(today: today, plan: plan, sourceCapFPS: nil).fps, 90)
        XCTAssertEqual(AdaptiveStreamingPlanner.resolveFPS(today: today, plan: plan, sourceCapFPS: 60),
                       StreamingFPSPolicy.Result(fps: 60, reason: .receiverCapability))
        XCTAssertEqual(AdaptiveStreamingPlanner.resolveFPS(today: .init(fps: 30, reason: .userCeiling), plan: plan,
                                                           sourceCapFPS: 60).fps, 30, "never raises today's rate")
        XCTAssertEqual(AdaptiveStreamingPlanner.resolveFPS(today: today, plan: nil, sourceCapFPS: nil), today)
    }

    // MARK: - #123 Beta off: the receiver against a Mac that does not announce

    /// The `stats` keys origin/dev's receiver sends (Shared/StreamReceiver.swift
    /// before #123), written out rather than taken from production code.
    private static let preFeatureStatsKeys: Set<String> = [
        "type", "transport", "fps", "mbps", "e2e50", "e2e95", "enc50", "rtt", "stalls", "cur", "curLost",
        "inp50", "capFps", "dec50", "ph50", "ph95", "offsetKnown",
    ]

    /// A ping exactly as a switch-off Mac builds it (origin/dev's
    /// `schedulePing` string; the DEBUG build adds the two audio keys).
    private static let switchOffMacPings = [
        "{\"type\":\"ping\",\"drops\":3,\"encDrops\":1,\"netDrops\":2,\"pending\":1,\"inp50\":4.0,\"inp95\":9.0,\"capFps\":60}",
        "{\"type\":\"ping\",\"drops\":0,\"encDrops\":0,\"netDrops\":0,\"pending\":0,\"inp50\":0.0,\"inp95\":0.0,\"capFps\":0,\"audioPkts\":100,\"audioKbps\":128}",
    ]

    private func pingObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Gap: no receiver test checked the `stats` a Mac without the announce
    /// receives. Drives `ReceiverAdaptiveState` (the only adaptive input to
    /// the receiver's `stats` block) the way a live session does, with
    /// injected time: one-second FPS windows with 60 frames each, RTT
    /// samples, an effective refresh and a Low Data Mode path for the hello,
    /// and a switch-off Mac's ping every 2 s. Each window runs the receiver's
    /// counter rule and merge; `stats` must go out on windows 5, 10, 15 ...
    /// only, carrying exactly the pre-feature keys. Also covers a new session
    /// after a Mac that did announce. Fails if a key-less ping ever counts as
    /// an announce, if the cadence is not 5 without one, or if telemetry keys
    /// are returned to a Mac that never announced.
    func testAgainstAMacWithoutTheAnnounceStatsKeepThePreFeatureKeysAndFiveWindowCadence() throws {
        let state = ReceiverAdaptiveState()
        state.setEffectiveRefresh(120)
        state.setPath(NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true, isConstrained: true),
                                                 reachability: .local))
        state.noteHelloSent(state.helloFields, now: 0)

        func runSession(from start: Double, windows: Int, label: String) throws -> [Int] {
            var sentOn: [Int] = []
            var counter = 0
            for window in 1...windows {
                let windowStart = start + Double(window - 1)
                for frame in 0..<60 { state.noteFrame(now: windowStart + Double(frame) / 60) }
                state.noteRTT(Double(10 + window % 7))
                if window % 2 == 0 {
                    let ping = Self.switchOffMacPings[window % Self.switchOffMacPings.count]
                    state.observeMacPing(try pingObject(ping), now: windowStart + 0.5)
                }
                let now = windowStart + 1
                // The receiver's rule (Shared/StreamReceiver.swift, `stats`).
                counter += 1
                if counter >= state.statsEveryWindows(now: now) {
                    counter = 0
                    let telemetry = state.drainTelemetryFields(now: now, decodeP95Ms: 7)
                    XCTAssertTrue(telemetry.isEmpty, "\(label) window \(window): no telemetry keys, got \(telemetry.keys)")
                    var message: [String: Any] = Dictionary(uniqueKeysWithValues: Self.preFeatureStatsKeys.map { ($0, 0) })
                    message.merge(telemetry) { current, _ in current }
                    XCTAssertEqual(Set(message.keys), Self.preFeatureStatsKeys, "\(label) window \(window)")
                    sentOn.append(window)
                }
            }
            return sentOn
        }

        XCTAssertEqual(try runSession(from: 10, windows: 60, label: "switch-off Mac"),
                       Array(stride(from: 5, through: 60, by: 5)), "every 5 windows, as before #123")

        // A session with a Mac that announced, then a new session with one that does not.
        state.observeMacPing(try pingObject("{\"type\":\"ping\",\"capFps\":60,\"adaptive\":1}"), now: 100)
        XCTAssertEqual(state.statsEveryWindows(now: 100.5), 2, "control: the announce is seen")
        state.resetSession()
        XCTAssertEqual(try runSession(from: 101, windows: 20, label: "after a session that announced"),
                       [5, 10, 15, 20])
    }

    /// The same through the receiver's real control handler: a switch-off
    /// Mac's ping, delivered to a real `StreamReceiver`, ends an announce
    /// at once (control: an announcing ping first switches the cadence to
    /// 2), so `stats` returns to every 5 windows with no telemetry keys.
    /// Reads `ReceiverAdaptiveState.shared` right after the queue has
    /// handled each ping, well inside the 6 s announce lifetime.
    @MainActor
    func testRealReceiverPingHandlerKeepsTodaysCadenceForASwitchOffMac() async throws {
        let shared = ReceiverAdaptiveState.shared
        shared.resetSession()
        defer { shared.resetSession() }
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "Test", fallbackServiceName: "Test")
        func deliver(_ json: String) async {
            receiver.receiveControlMessageForTesting(Data(json.utf8), authenticatedPeerID: nil)
            await withCheckedContinuation { continuation in
                receiver.probeForTesting { _ in continuation.resume() }
            }
        }
        for ping in Self.switchOffMacPings {
            await deliver(ping)
            let now = StreamDiagnosticsClock.nowSeconds()
            XCTAssertEqual(shared.statsEveryWindows(now: now), 5)
            XCTAssertTrue(shared.drainTelemetryFields(now: now, decodeP95Ms: nil).isEmpty)
        }
        await deliver("{\"type\":\"ping\",\"capFps\":60,\"adaptive\":1}")
        XCTAssertEqual(shared.statsEveryWindows(now: StreamDiagnosticsClock.nowSeconds()), 2,
                       "control: the real handler reads the announce")
        await deliver(Self.switchOffMacPings[0])
        let now = StreamDiagnosticsClock.nowSeconds()
        XCTAssertEqual(shared.statsEveryWindows(now: now), 5, "a ping without the key ends the announce at once")
        XCTAssertTrue(shared.drainTelemetryFields(now: now, decodeP95Ms: nil).isEmpty)
    }

    // MARK: - #123 Beta off: the real receiver `stats` window

    @MainActor
    private func endStatsWindow(_ receiver: StreamReceiver, fps: Int, stats: PerfStats,
                                now: TimeInterval) async throws -> [String: Any]? {
        let data = await withCheckedContinuation { continuation in
            receiver.endStatsWindowForTesting(fps: fps, stats: stats, now: now) { continuation.resume(returning: $0) }
        }
        guard let data else { return nil }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func windowStats() -> PerfStats {
        var stats = PerfStats()
        stats.mbps = 4.26
        stats.e2eP50 = 41.4
        stats.e2eP95 = 87.6
        stats.encodeP50 = 6.5
        stats.stalls = 2
        stats.cursorPerSec = 30
        stats.cursorLost = 1
        stats.decodeP50 = 3.4
        return stats
    }

    /// The `stats` a real `StreamReceiver` builds (`endStatsWindow`, the
    /// block `presentDecodedSample` runs at the end of each one-second
    /// window) against a Mac that does not announce, with injected time:
    /// windows 5, 10, 15 ... report (origin/dev's `statsReportCounter >= 5`),
    /// with exactly origin/dev's keys and its value rules (`mbps` to 0.1,
    /// latencies rounded, `capFps`/`inp50` from the Mac's last ping). The
    /// switch-off pings go through the real ping handler. Fails if the
    /// cadence or the key set drifts from origin/dev with no announce.
    @MainActor
    func testRealReceiverStatsAgainstASwitchOffMacAreOriginDevsKeysAndCadence() async throws {
        let shared = ReceiverAdaptiveState.shared
        shared.resetSession()
        defer { shared.resetSession() }
        let diagnostics = StreamDiagnosticsSwitch.shared
        let diagnosticsWasOn = diagnostics.isEnabled
        diagnostics.set(false)
        defer { diagnostics.set(diagnosticsWasOn) }
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "Test", fallbackServiceName: "Test")
        func deliver(_ json: String) async {
            receiver.receiveControlMessageForTesting(Data(json.utf8), authenticatedPeerID: nil)
            await withCheckedContinuation { continuation in
                receiver.probeForTesting { _ in continuation.resume() }
            }
        }
        // origin/dev's keys, from `git show origin/dev:Shared/StreamReceiver.swift`.
        let originDevKeys: Set<String> = [
            "type", "transport", "fps", "mbps", "e2e50", "e2e95", "enc50", "rtt", "stalls", "cur", "curLost",
            "inp50", "capFps", "dec50", "ph50", "ph95", "offsetKnown",
        ]
        let stats = windowStats()
        var sentOn: [Int] = []
        for window in 1...20 {
            let now = 1_000 + Double(window)
            for frame in 0..<60 { shared.noteFrame(now: now - 1 + Double(frame) / 60) }
            shared.noteRTT(Double(10 + window % 7))
            if window % 2 == 0 { await deliver(Self.switchOffMacPings[0]) }
            guard let message = try await endStatsWindow(receiver, fps: 60, stats: stats, now: now) else { continue }
            sentOn.append(window)
            XCTAssertEqual(Set(message.keys), originDevKeys, "window \(window)")
            XCTAssertEqual(message["type"] as? String, "stats")
            XCTAssertEqual(message["fps"] as? Int, 60)
            XCTAssertEqual(message["mbps"] as? Double, 4.3)
            XCTAssertEqual(message["e2e50"] as? Double, 41)
            XCTAssertEqual(message["e2e95"] as? Double, 88)
            XCTAssertEqual(message["enc50"] as? Double, 7)
            XCTAssertEqual(message["rtt"] as? Double, 0)
            XCTAssertEqual(message["stalls"] as? Int, 2)
            XCTAssertEqual(message["cur"] as? Int, 30)
            XCTAssertEqual(message["curLost"] as? Int, 1)
            XCTAssertEqual(message["inp50"] as? Double, 4, "from the Mac's last ping")
            XCTAssertEqual(message["capFps"] as? Int, 60, "from the Mac's last ping")
            XCTAssertEqual(message["dec50"] as? Double, 3)
            XCTAssertEqual(message["ph50"] as? Double, 0)
            XCTAssertEqual(message["ph95"] as? Double, 0)
            XCTAssertEqual(message["offsetKnown"] as? Bool, false)
            XCTAssertNotNil(message["transport"] as? String)
        }
        XCTAssertEqual(sentOn, [5, 10, 15, 20], "every 5 windows, as on origin/dev")
    }

    /// Control for the test above: the same real `stats` window with a Mac
    /// that announces (its ping seen at the injected time) reports every 2
    /// windows and adds the telemetry keys, so the test above sees the
    /// announce, not a path that never merges telemetry.
    @MainActor
    func testRealReceiverStatsWithAnAnnouncingMacAddTelemetryEveryTwoWindows() async throws {
        let shared = ReceiverAdaptiveState.shared
        shared.resetSession()
        defer { shared.resetSession() }
        let diagnostics = StreamDiagnosticsSwitch.shared
        let diagnosticsWasOn = diagnostics.isEnabled
        diagnostics.set(false)
        defer { diagnostics.set(diagnosticsWasOn) }
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "Test", fallbackServiceName: "Test")
        let stats = windowStats()
        var sentOn: [Int] = []
        for window in 1...10 {
            let now = 1_000 + Double(window)
            shared.observeMacPing(try pingObject("{\"type\":\"ping\",\"capFps\":60,\"adaptive\":1}"), now: now - 0.5)
            for frame in 0..<60 { shared.noteFrame(now: now - 1 + Double(frame) / 60) }
            guard let message = try await endStatsWindow(receiver, fps: 60, stats: stats, now: now) else { continue }
            sentOn.append(window)
            XCTAssertTrue(Self.preFeatureStatsKeys.isSubset(of: Set(message.keys)), "window \(window)")
            XCTAssertNotNil(message[AdaptiveStreamingWire.windowKey], "window \(window): telemetry keys added")
            XCTAssertNotNil(AdaptiveReceiverTelemetry.parse(message), "window \(window)")
        }
        XCTAssertEqual(sentOn, [2, 4, 6, 8, 10], "every 2 windows while announced")
    }
}
