import XCTest

/// #123 churn: a receiver that keeps flipping "Use less data", or whose
/// network cost hint flaps, must not cost the Mac a capture or encoder update
/// per hello. Saving still applies at once; a return to full quality waits
/// until saving has been in effect for `saverMinimumDwellSeconds`, then lands
/// whole; the latest request always wins. Coordinator level with an injected
/// clock and a recording fake for the sender (`AdaptiveSenderCallSiteTests`
/// drives the real call sites). Most scenarios also run with a zero dwell,
/// which is exactly the behaviour before this fix, to show what it bounds.
/// The printed counts are simulation results, not device measurements.
final class AdaptiveDataPolicyChurnTests: XCTestCase {
    private final class RecordingApplier: AdaptiveStreamingApplying {
        var now = 0.0
        var applied: [(time: Double, path: AdaptiveApplyPath)] = []
        func adaptiveApply(_ path: AdaptiveApplyPath) { applied.append((now, path)) }
        func times(_ path: AdaptiveApplyPath) -> [Double] { applied.filter { $0.path == path }.map(\.time) }
        var trace: [String] { applied.map { String(format: "%.2f %@", $0.time, $0.path.rawValue) } }
        var summary: String {
            let counts = [AdaptiveApplyPath.liveFPSUpdate, .encoderRebuild, .captureRestart].map {
                "\($0.rawValue)=\(times($0).count)"
            }
            return "\(applied.count) updates (" + counts.joined(separator: " ") + ")"
        }
    }

    private let iPad = AdaptiveReceiverDisplay(pointsWide: 1366, pointsHigh: 1024, scale: 2, sizeClass: .tablet)
    private let iPadSizing = AdaptiveCaptureSizing(sourceWidth: 2732, sourceHeight: 2048, todayScale: 1,
                                                   maxWide: nil, maxHigh: nil)
    private let dwell = AdaptiveStreamingCoordinator.saverMinimumDwellSeconds
    private let restartInterval = AdaptiveStreamingCoordinator.restartIntervalSeconds

    private func inputs(_ mode: RefreshNegotiation.DisplayMode, receiverMax: Int = 120) -> AdaptiveStreamingCoordinator.Inputs {
        AdaptiveStreamingCoordinator.Inputs(mode: mode, profile: .performance, customFPS: nil,
                                            receiverMaxFPS: receiverMax, userMaxFPS: nil, codec: .hevc, receiver: iPad)
    }

    private func window(_ end: Double) -> AdaptiveStreamingCoordinator.SenderWindow {
        AdaptiveStreamingCoordinator.SenderWindow(start: end - 2, end: end, capturedFrames: 120, encoderDrops: 0,
                                                  networkDrops: 0, thermal: .nominal, lowPower: false,
                                                  encodeLatencyMs: 5)
    }

    /// A coordinator whose capture is running. `legacy`: zero dwell, the
    /// behaviour before the churn fix.
    private func live(mode: RefreshNegotiation.DisplayMode = .mirror, enabled: Bool = false,
                      streamingMode: StreamingMode = .automatic, legacy: Bool = false,
                      captureRunning: Bool = true) -> (AdaptiveStreamingCoordinator, RecordingApplier) {
        let c = AdaptiveStreamingCoordinator(
            enabled: enabled, streamingMode: streamingMode, displayMode: mode,
            saverDwellSeconds: legacy ? 0 : AdaptiveStreamingCoordinator.saverMinimumDwellSeconds)
        let fake = RecordingApplier()
        c.applier = fake
        c.setSourceRefresh(120)
        if captureRunning {
            if mode == .window {
                c.noteCaptureStarted(width: 2732, height: 2048, scale: 1)
            } else {
                c.noteCaptureStarted(sizing: iPadSizing, width: 2732, height: 2048)
            }
        }
        return (c, fake)
    }

    private enum Event {
        case hello(AdaptiveHelloFields)
        case route(NetworkCost.EndpointReport, epoch: UInt64)
        case tick
    }

    /// Plays timed events with a Mac tick every 2 s from `start` up to `end`
    /// (a tick goes first when it falls on an event's time). `managedStats`
    /// feeds healthy receiver telemetry and 60 sent frames per second before
    /// each tick.
    private func play(_ c: AdaptiveStreamingCoordinator, _ fake: RecordingApplier, mode: RefreshNegotiation.DisplayMode,
                      _ timed: [(Double, Event)], from start: Double = 2, until end: Double, managedStats: Bool = false,
                      after each: ((Double) -> Void)? = nil) {
        var events = timed.enumerated().map { (time: $0.element.0, order: $0.offset + 1, event: $0.element.1) }
        var t = start
        while t <= end + 1e-9 {
            events.append((time: t, order: 0, event: .tick))
            t += 2
        }
        events.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        for item in events {
            fake.now = item.time
            switch item.event {
            case .hello(let fields):
                c.helloAccepted(fields, now: item.time)
            case .route(let report, let epoch):
                c.senderPathChanged(report, epoch: epoch, now: item.time)
            case .tick:
                if managedStats {
                    for _ in 0..<120 { c.noteVideoSent(bytes: 30_000, now: item.time - 1) }
                    var telemetry = AdaptiveReceiverTelemetry(windowSeconds: 2)
                    telemetry.deliveredFPS = 60
                    telemetry.rttMs = 8
                    telemetry.jitterMs = 1
                    telemetry.thermal = .nominal
                    telemetry.lowPower = false
                    c.receiverStats(telemetry)
                }
                c.tick(generation: 1, mode: mode, inputs: inputs(mode, receiverMax: managedStats ? 60 : 120),
                       window: window(item.time), now: item.time)
            }
            each?(item.time)
        }
    }

    /// Alternating hellos every `period` for `duration`, arranged so the last one asks for `last`.
    private func flips(every period: Double, for duration: Double, last: NetworkCost.DataPreference,
                       base: AdaptiveHelloFields = AdaptiveHelloFields()) -> [(Double, Event)] {
        let count = Int((duration / period).rounded())
        return (0..<count).map { index in
            let asksLast = (count - 1 - index) % 2 == 0
            var fields = base
            fields.saveData = asksLast ? last : (last == .on ? .off : .on)
            return (Double(index) * period, .hello(fields))
        }
    }

    /// Capture restarts at least the restart interval apart, and at most
    /// three pipeline updates per interval (plus one) over `duration`.
    private func assertBounded(_ fake: RecordingApplier, duration: Double, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let restarts = fake.times(.captureRestart)
        for (a, b) in zip(restarts, restarts.dropFirst()) where b - a < restartInterval - 1e-6 {
            XCTFail("\(label): restarts \(restarts)", file: file, line: line)
        }
        let windows = Int((duration / restartInterval).rounded(.up)) + 1
        XCTAssertLessThanOrEqual(fake.applied.count, 3 * windows, "\(label): \(fake.trace)", file: file, line: line)
    }

    // MARK: - Hostile or buggy flipping

    /// 20 hellos per second for two minutes, every display mode, the Beta
    /// switch off and on (a receiver without telemetry keys: the static saver
    /// point either way). Before the fix: one FPS update per hello.
    func testFlippingOnEveryHelloIsBoundedInEveryModeAndTheLastRequestWins() {
        let duration = 120.0
        let settled = duration + 2 * dwell + restartInterval
        for mode in RefreshNegotiation.DisplayMode.allCases {
            for enabled in [false, true] {
                for last in [NetworkCost.DataPreference.off, .on] {
                    let label = "\(mode) switch=\(enabled) last=\(last.rawValue)"
                    let script = flips(every: 0.05, for: duration, last: last)
                    let (c, fake) = live(mode: mode, enabled: enabled)
                    var countAtEnd = 0
                    play(c, fake, mode: mode, script, until: settled) { now in
                        if now <= duration { countAtEnd = fake.applied.count }
                    }
                    assertBounded(fake, duration: settled, label)
                    XCTAssertEqual(c.appliedDataPolicy, last == .on ? .saver : .normal, "\(label): the last request wins")
                    XCTAssertEqual(c.plan, c.desiredPlan, "\(label): nothing left held")
                    if last == .on {
                        XCTAssertEqual(c.plan?.origin, .dataSaver, label)
                    } else {
                        XCTAssertNil(c.plan, "\(label): back to today")
                    }
                    let (old, oldFake) = live(mode: mode, enabled: enabled, legacy: true)
                    play(old, oldFake, mode: mode, script, until: settled)
                    XCTAssertGreaterThan(oldFake.applied.count, 1_000, "\(label): before the fix, one update per hello")
                    XCTAssertEqual(old.plan, c.plan, "\(label): the same final plan as before the fix")
                    print("churn sim: 20 Hz flips, \(label): fixed \(fake.summary) (\(countAtEnd) while flipping), "
                        + "before the fix \(oldFake.summary)")
                }
            }
        }
    }

    /// One flip per 5 s for ten minutes: what a Swift receiver's re-hello
    /// gate lets through at most. Restarts stay at the limiter's bound, the
    /// FPS and encoder updates between them mostly go.
    func testOneFlipEveryFiveSecondsIsBounded() {
        let duration = 600.0
        for mode in [RefreshNegotiation.DisplayMode.mirror, .window] {
            let script = flips(every: 5, for: duration, last: .off)
            let (c, fake) = live(mode: mode)
            play(c, fake, mode: mode, script, until: duration + 2 * dwell)
            assertBounded(fake, duration: duration + 2 * dwell, "\(mode)")
            XCTAssertNil(c.plan)
            let (old, oldApplier) = live(mode: mode, legacy: true)
            play(old, oldApplier, mode: mode, script, until: duration + 2 * dwell)
            XCTAssertLessThan(fake.applied.count, oldApplier.applied.count, "\(mode)")
            XCTAssertLessThanOrEqual(fake.times(.captureRestart).count, oldApplier.times(.captureRestart).count + 1,
                                     "\(mode)")
            print("churn sim: one flip per 5 s for 600 s, \(mode): fixed \(fake.summary), before the fix \(oldApplier.summary)")
        }
    }

    // MARK: - Legitimate use

    /// One toggle applies exactly as before the fix: saving on from a
    /// steady state, saving off after it has been on for a while, and saving
    /// set before the first capture then turned off.
    func testASingleToggleAppliesAsPromptlyAsBeforeTheFix() {
        typealias Script = (events: [(Double, Event)], captureAt: Double?)
        let scripts: [(String, Script)] = [
            ("on from steady", ([(10, .hello(AdaptiveHelloFields(saveData: .off))),
                                 (31, .hello(AdaptiveHelloFields(saveData: .on)))], 0)),
            ("off after a long saving spell", ([(0, .hello(AdaptiveHelloFields(saveData: .on))),
                                                (45, .hello(AdaptiveHelloFields(saveData: .off)))], 0)),
            ("set before the capture, off right after it started",
             ([(0, .hello(AdaptiveHelloFields(saveData: .on))), (5, .hello(AdaptiveHelloFields(saveData: .off)))], 3)),
        ]
        for mode in RefreshNegotiation.DisplayMode.allCases {
            for (label, script) in scripts {
                var traces: [[String]] = []
                var plans: [[AdaptiveStreamingPlan?]] = []
                for legacy in [false, true] {
                    let (c, fake) = live(mode: mode, legacy: legacy, captureRunning: script.captureAt == 0)
                    var seen: [AdaptiveStreamingPlan?] = []
                    var events = script.events
                    if let at = script.captureAt, at > 0 {
                        // The first capture starts at `at`, sized by the plan then.
                        events.append((at, .tick))
                    }
                    play(c, fake, mode: mode, events, until: 60) { now in
                        if let at = script.captureAt, at > 0, abs(now - at) < 1e-9, mode != .window {
                            let scale = c.captureScale(today: 1)
                            let size = self.iPadSizing.captureSize(scale: scale)
                            c.noteCaptureStarted(sizing: self.iPadSizing, width: size?.width ?? 0, height: size?.height ?? 0)
                        } else if let at = script.captureAt, at > 0, abs(now - at) < 1e-9 {
                            c.noteCaptureStarted(width: 2732, height: 2048, scale: 1)
                        }
                        seen.append(c.plan)
                    }
                    traces.append(fake.trace)
                    plans.append(seen)
                }
                XCTAssertEqual(traces[0], traces[1], "\(mode) \(label): the same updates at the same times")
                XCTAssertEqual(plans[0], plans[1], "\(mode) \(label): the same plan after every event")
            }
        }
    }

    /// Saving always applies at once: while a return waits (it is simply
    /// dropped), and right after a return (FPS at once; bitrate and raster
    /// as soon as their own limits allow).
    func testSavingAlwaysAppliesAtOnce() {
        let (c, fake) = live()
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 0)
        let saving = c.plan
        XCTAssertEqual(saving?.origin, .dataSaver)
        XCTAssertEqual(fake.trace, ["0.00 captureRestart"])
        for (time, preference) in [(5.0, NetworkCost.DataPreference.off), (6, .on), (7, .off), (8, .on)] {
            fake.now = time
            c.helloAccepted(AdaptiveHelloFields(saveData: preference), now: time)
            XCTAssertEqual(c.appliedDataPolicy, .saver)
            XCTAssertEqual(c.plan, saving)
        }
        XCTAssertEqual(fake.applied.count, 1, "nothing for the flips inside the dwell")
        // A return after the dwell, then saving again a moment later.
        fake.now = 25
        c.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 25)
        XCTAssertNil(c.plan)
        fake.now = 25.5
        c.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 25.5)
        XCTAssertEqual(c.appliedDataPolicy, .saver, "at once")
        XCTAssertEqual(c.plan?.fpsCap, AdaptiveStreamingPlanner.saverFPSCap, "the FPS cap at once")
        XCTAssertEqual(c.desiredPlan, saving)
        play(c, fake, mode: .mirror, [], from: 26, until: 46)
        XCTAssertEqual(fake.times(.encoderRebuild), [30], "the bitrate after the 4 s encoder limit")
        XCTAssertEqual(fake.times(.captureRestart), [0, 25, 46], "the raster after the 20 s restart limit")
        XCTAssertEqual(c.plan, saving)
    }

    /// A return that waits is never lost: with no further hello the next
    /// tick after the dwell applies it, a route change applies it as well,
    /// and the last request wins whichever comes first.
    func testAWaitingReturnIsAppliedByATickOrARouteChangeAndTheLastRequestWins() {
        let wifi = NetworkCost.endpointReport(.init(usesWiFi: true), reachability: .local)
        let macLowData = NetworkCost.endpointReport(.init(usesWiFi: true, isConstrained: true), reachability: .local)
        let receiverLowData = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true, isConstrained: true),
                                                         reachability: .local)
        // Ticks only.
        let (byTick, tickFake) = live()
        play(byTick, tickFake, mode: .mirror, [(0, .hello(AdaptiveHelloFields(saveData: .on))),
                                                (3, .hello(AdaptiveHelloFields(saveData: .off)))], until: 18)
        XCTAssertEqual(byTick.appliedDataPolicy, .saver)
        tickFake.now = 20
        byTick.tick(generation: 1, mode: .mirror, inputs: inputs(.mirror), window: window(20), now: 20)
        XCTAssertNil(byTick.plan)
        XCTAssertEqual(tickFake.times(.captureRestart), [0, 20])

        // Route changes: a stale epoch changes nothing, a new one re-offers the return.
        let (byRoute, routeFake) = live()
        byRoute.helloAccepted(AdaptiveHelloFields(cost: receiverLowData, saveData: .auto), now: 0)
        XCTAssertEqual(byRoute.appliedDataPolicy, .saver, "Low Data Mode on the receiver's own path")
        byRoute.helloAccepted(AdaptiveHelloFields(cost: wifi, saveData: .auto), now: 3)
        byRoute.senderPathChanged(wifi, epoch: 1, now: 8)
        XCTAssertEqual(byRoute.appliedDataPolicy, .saver, "inside the dwell")
        XCTAssertFalse(byRoute.senderPathChanged(wifi, epoch: 1, now: 21), "a stale epoch")
        XCTAssertEqual(byRoute.appliedDataPolicy, .saver)
        routeFake.now = 21
        XCTAssertTrue(byRoute.senderPathChanged(wifi, epoch: 2, now: 21))
        XCTAssertEqual(byRoute.appliedDataPolicy, .normal, "the route change applied the waiting return")
        XCTAssertNil(byRoute.plan)
        // The Mac's own Low Data Mode arrives with the next route: saving at once.
        routeFake.now = 22
        byRoute.senderPathChanged(macLowData, epoch: 3, now: 22)
        XCTAssertEqual(byRoute.appliedDataPolicy, .saver)
        XCTAssertEqual(byRoute.plan?.fpsCap, AdaptiveStreamingPlanner.saverFPSCap)
    }

    /// Cost hints that flap (Wi-Fi to a Data Saver hotspot and back, a VPN
    /// going up and down, at Android's send-at-once pace), and the blip an
    /// Android Activity recreation can cause (the hint briefly absent).
    func testFlappingCostHintsAreCoalesced() {
        let wifi = NetworkCost.endpointReport(.init(usesWiFi: true), reachability: .local)
        let hotspotDataSaver = NetworkCost.endpointReport(.init(usesWiFi: true, isExpensive: true, isConstrained: true),
                                                          reachability: .local)
        let vpnDataSaver = NetworkCost.endpointReport(.init(usesWiFi: true, isTunnel: true, isConstrained: true),
                                                      reachability: .remote)
        for (label, a, b) in [("hotspot", hotspotDataSaver, wifi), ("vpn", vpnDataSaver, wifi)] {
            var script: [(Double, Event)] = []
            var time = 0.0
            var index = 0
            while time < 90 {
                script.append((time, .hello(AdaptiveHelloFields(cost: index % 2 == 0 ? a : b, saveData: .auto))))
                time += 0.3
                index += 1
            }
            let last = index % 2 == 0 ? NetworkCost.DataPolicy.normal : .saver
            let (c, fake) = live()
            play(c, fake, mode: .mirror, script, until: 90 + 2 * dwell)
            assertBounded(fake, duration: 90 + 2 * dwell, label)
            XCTAssertEqual(c.appliedDataPolicy, last, "\(label): the last hint wins")
            let (old, oldFake) = live(legacy: true)
            play(old, oldFake, mode: .mirror, script, until: 90 + 2 * dwell)
            XCTAssertGreaterThan(oldFake.applied.count, 3 * fake.applied.count, label)
            print("churn sim: cost hint flapping every 0.3 s for 90 s (\(label)): fixed \(fake.summary), "
                + "before the fix \(oldFake.summary)")
        }

        // Activity recreation: Data Saver steady, the hint briefly absent, then back.
        let steady = AdaptiveHelloFields(cost: hotspotDataSaver, saveData: .auto)
        let blip = AdaptiveHelloFields(cost: nil, saveData: .auto)
        let (c, fake) = live()
        play(c, fake, mode: .mirror, [(0, .hello(steady)), (5, .hello(blip)), (5.1, .hello(steady))], until: 30)
        XCTAssertEqual(fake.times(.captureRestart), [0], "a blip inside the dwell costs nothing")
        XCTAssertEqual(fake.applied.count, 1)
        let before = fake.applied.count
        play(c, fake, mode: .mirror, [(100, .hello(blip)), (100.1, .hello(steady)), (104, .hello(blip)),
                                      (104.1, .hello(steady))], from: 32, until: 130)
        // Residual (documented): after a long saving spell one blip is one
        // return (a restart) and one re-entry (FPS at once, bitrate after
        // 4 s, raster after 20 s); the dwell absorbs the next blip.
        XCTAssertLessThanOrEqual(fake.applied.count - before, 4, fake.trace.description)
        XCTAssertLessThanOrEqual(fake.times(.captureRestart).filter { $0 >= 100 }.count, 2)
        XCTAssertEqual(c.appliedDataPolicy, .saver)
        XCTAssertEqual(c.plan, c.desiredPlan)
    }

    /// With the Beta switch on and a receiver the controller manages, a
    /// flip only lifts or lowers the ladder tops; the controller's own
    /// spacing bounds what reaches the pipeline.
    func testManagedFlippingIsBounded() {
        let duration = 120.0
        let base = AdaptiveHelloFields(effectiveRefreshHz: 60, telemetry: true)
        let script = flips(every: 0.05, for: duration, last: .off, base: base)
        let (c, fake) = live(mode: .extend, enabled: true)
        play(c, fake, mode: .extend, script, until: duration, managedStats: true)
        let restarts = fake.times(.captureRestart)
        let windows = Int(duration / restartInterval) + 1
        XCTAssertLessThanOrEqual(restarts.count, 2 * windows, "\(restarts)")
        XCTAssertLessThanOrEqual(fake.applied.count, 4 * windows, fake.trace.description)
        print("churn sim: 20 Hz flips, managed receiver (switch on): \(fake.summary)")
    }

    // MARK: - Unchanged behaviour

    /// Old receivers (no `saveData`) never save data whatever their cost
    /// hint or the Mac's path, and Custom never uses a plan: both behave
    /// exactly as before the fix, step by step.
    func testOldPeersAndCustomModeBehaveExactlyAsBeforeTheFix() {
        let wifi = NetworkCost.endpointReport(.init(usesWiFi: true), reachability: .local)
        let lowData = NetworkCost.endpointReport(.init(usesCellular: true, isExpensive: true, isConstrained: true),
                                                 reachability: .local)
        var oldPeer: [(Double, Event)] = []
        var custom: [(Double, Event)] = []
        for index in 0..<400 {
            let time = Double(index) * 0.25
            let cost = index % 2 == 0 ? lowData : wifi
            // No `saveData`; some hellos with no optional key at all, some with only a cost hint.
            oldPeer.append((time, .hello(index % 3 == 0 ? AdaptiveHelloFields() : AdaptiveHelloFields(cost: cost))))
            if index % 7 == 0 { oldPeer.append((time + 0.1, .route(index % 2 == 0 ? lowData : wifi, epoch: UInt64(index + 1)))) }
            custom.append((time, .hello(AdaptiveHelloFields(cost: cost, saveData: index % 2 == 0 ? .on : .off))))
        }
        let cases: [(String, StreamingMode, [(Double, Event)])] = [
            ("old peer", .automatic, oldPeer), ("custom", .custom, custom),
        ]
        for (label, streamingMode, script) in cases {
            for mode in RefreshNegotiation.DisplayMode.allCases {
                for enabled in [false, true] {
                    var steps: [[String]] = [[], []]
                    for (slot, legacy) in [false, true].enumerated() {
                        let (c, fake) = live(mode: mode, enabled: enabled, streamingMode: streamingMode, legacy: legacy)
                        play(c, fake, mode: mode, script, until: 100) { now in
                            steps[slot].append("\(now) \(String(describing: c.plan)) \(c.appliedDataPolicy) \(fake.applied.count)")
                        }
                        if label == "old peer" {
                            XCTAssertEqual(c.appliedDataPolicy, .normal, "\(label) \(mode)")
                        }
                        XCTAssertNil(c.plan, "\(label) \(mode) switch=\(enabled)")
                        XCTAssertTrue(fake.applied.isEmpty, "\(label) \(mode) switch=\(enabled)")
                    }
                    XCTAssertEqual(steps[0], steps[1], "\(label) \(mode) switch=\(enabled): identical step by step")
                }
            }
        }
    }

    /// The dwell is per receiver: one receiver flipping never delays another's change.
    func testOneReceiversFlippingNeverAffectsAnother() {
        let (flapper, flapperFake) = live()
        let (other, otherFake) = live()
        var script: [(Double, Event)] = flips(every: 0.05, for: 30, last: .off)
        script.sort { $0.0 < $1.0 }
        play(flapper, flapperFake, mode: .mirror, script, until: 30) { now in
            if abs(now - 10) < 1e-9 {
                otherFake.now = 10
                other.helloAccepted(AdaptiveHelloFields(saveData: .on), now: 10)
            }
            if abs(now - 12) < 1e-9 {
                otherFake.now = 12
                other.helloAccepted(AdaptiveHelloFields(saveData: .off), now: 12)
            }
        }
        XCTAssertEqual(otherFake.trace, ["10.00 captureRestart"], "its own saving at once")
        XCTAssertEqual(other.appliedDataPolicy, .saver, "its own return waits for its own dwell")
        XCTAssertEqual(other.saverInEffectSince, 10)
        XCTAssertNotEqual(flapper.saverInEffectSince, other.saverInEffectSince)
    }
}
