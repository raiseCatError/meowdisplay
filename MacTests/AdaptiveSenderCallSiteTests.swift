import CoreGraphics
import XCTest

/// #123 review of ddcef384: the adaptive raster re-check at its real call
/// sites in a real `MacSender` (no network, no ScreenCaptureKit). F1: with
/// the Beta switch off and no data saving, a capture whose start note reads
/// a different size than it was sized at (a display-mode change, or no mode,
/// between sizing and preparation) is never restarted, logged, deferred or
/// reported. F7: a re-check during the lock screen view is held, and held
/// changes are dropped, not applied, when the connection ends or the
/// sender stops.
final class AdaptiveSenderCallSiteTests: XCTestCase {
    private final class SentLog: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        var record: @Sendable (String) -> Void {
            { [weak self] json in
                guard let self else { return }
                self.lock.withLock { self.messages.append(json) }
            }
        }

        var count: Int { lock.withLock { messages.count } }
    }

    /// A display ID no Mac has: `CGDisplayCopyDisplayMode` returns nil for
    /// it, so the note falls back to the size given here, as it does for a
    /// display that went away or asleep between sizing and preparation.
    private let missingDisplay: CGDirectDisplayID = 0x7EAD_BEEF

    private func admittedSender(adaptiveAutomatic: Bool = false)
        async throws -> (MacSender, SentLog, () -> Void) {
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        LoginSessionConsole.shared.set(onConsole: true)
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-adaptive-call-site-tests")
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: "adaptive-call-site-test-ipad")
        // Never dialed: the endpoint only satisfies the initializer.
        let sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                               name: "Adaptive Call Site Test iPad", mode: .mirror,
                               streamingMode: .automatic, adaptiveAutomatic: adaptiveAutomatic)
        let sent = SentLog()
        let hello: [String: Any] = ["type": "hello", "pixelsWide": 2732, "pixelsHigh": 2048, "scale": 2.0,
                                    "device": "iPad", "id": "adaptive-call-site-test-ipad", "pv": WireProtocol.version]
        _ = try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: sent.record)
        try await sender.settleForTesting()
        return (sender, sent, { keychain.delete() })
    }

    func testSwitchOffRecheckNeverRestartsLogsOrSendsForAMismatchedStartSize() async throws {
        let (sender, sent, cleanup) = try await admittedSender()
        defer { cleanup() }
        XCTAssertFalse(sender.adaptive.announcesAdaptive, "the Beta switch is off")
        let sentBefore = sent.count
        let writesBefore = sender.adaptive.monitor.writeCount
        // Sized from one mode (2732×2048), noted against another (3024×1964).
        for (displayWidth, displayHeight) in [(3024, 1964), (1366, 1024), (2732, 2048)] {
            for lockScreenShown in [false, true] {
                let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
                    displayID: missingDisplay, displayWidth: displayWidth, displayHeight: displayHeight,
                    pixelsWide: 2732, pixelsHigh: 2048, lockScreenShown: lockScreenShown)
                XCTAssertFalse(probe.restartRequested, "\(displayWidth)x\(displayHeight): no capture restart")
                XCTAssertEqual(probe.deferred, .none, "nothing held for the lock screen view")
                XCTAssertFalse(probe.hasManagedRaster)
                XCTAssertEqual(probe.work, AdaptiveStreamingCoordinator.WorkCounters(), "no adaptive work")
            }
        }
        try await sender.settleForTesting()
        XCTAssertEqual(sent.count, sentBefore, "nothing new on the wire")
        XCTAssertEqual(sender.adaptive.monitor.writeCount, writesBefore)
        XCTAssertNil(sender.adaptive.plan)
    }

    func testRecheckDuringTheLockScreenViewIsHeldAndDroppedWhenTheConnectionEnds() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        // "Use less data" on (works with the switch off): the plan asks for
        // the Balanced raster, but this capture started at the old one.
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048,
            saveData: .on, lockScreenShown: true)
        XCTAssertTrue(probe.hasManagedRaster)
        XCTAssertFalse(probe.restartRequested, "not while the lock screen view is shown")
        XCTAssertEqual(probe.deferred, .captureRestart, "held, not lost")
        try await sender.loseConnectionForTesting()
        let afterConnectionEnd = try await sender.adaptiveLockScreenDeferralForTesting
        XCTAssertEqual(afterConnectionEnd, .none, "dropped with the connection, never applied on the way out")
    }

    // MARK: - #123 churn, part 3: the switch-off state at the real call sites

    private func helloJSON(_ fields: AdaptiveHelloFields) throws -> Data {
        var object = fields.wireFields
        object["type"] = "hello"
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func report(_ flags: NetworkCost.PathFlags, _ reachability: NetworkCost.Reachability = .local)
        -> NetworkCost.EndpointReport {
        NetworkCost.endpointReport(flags, reachability: reachability)
    }

    /// The state a sender with the switch off and no data saving must keep:
    /// nothing planned, held, armed or computed, whatever happened.
    private func assertSwitchOffState(_ state: MacSender.AdaptiveCallSiteState, monitorWrites: Int, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.plan, label, file: file, line: line)
        XCTAssertNil(state.desiredPlan, label, file: file, line: line)
        XCTAssertEqual(state.appliedDataPolicy, .normal, label, file: file, line: line)
        XCTAssertFalse(state.hasManagedRaster, label, file: file, line: line)
        XCTAssertEqual(state.work, AdaptiveStreamingCoordinator.WorkCounters(), "\(label): no adaptive work",
                       file: file, line: line)
        XCTAssertEqual(state.deferred, .none, label, file: file, line: line)
        XCTAssertEqual(state.monitorWrites, monitorWrites, label, file: file, line: line)
    }

    /// Switch off, no data saving: hellos with and without every optional key
    /// (and hostile values), route changes with new epochs across Wi-Fi,
    /// cable and remote with metered and Low Data Mode flags appearing, ticks
    /// with and without the lock screen view, a reconnect on the same sender
    /// and a capture start whose noted size disagrees: nothing adaptive runs,
    /// nothing is held or armed, nothing goes on the wire.
    func testSwitchOffWithoutDataSavingStaysTodayAcrossHellosRoutesReconnectsAndTheLockScreen() async throws {
        let (sender, sent, cleanup) = try await admittedSender()
        defer { cleanup() }
        let writes = try await sender.adaptiveCallSiteStateForTesting.monitorWrites
        let wifi = report(.init(usesWiFi: true))
        let cable = report(.init(usesWired: true))
        let remote = report(.init(usesWiFi: true), .remote)
        let metered = report(.init(usesCellular: true, isExpensive: true), .remote)
        let lowData = report(.init(usesWiFi: true, isExpensive: true, isConstrained: true))
        let vpnLowData = report(.init(usesWiFi: true, isTunnel: true, isConstrained: true), .remote)
        let telemetry = AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true)
        // Each phase pairs hellos with Mac routes that together never ask for
        // saving (Low Data Mode only counts with `saveData` on or auto).
        let phases: [(String, [AdaptiveHelloFields], [NetworkCost.EndpointReport])] = [
            ("no saveData", [AdaptiveHelloFields(), telemetry,
                             AdaptiveHelloFields(cost: lowData), AdaptiveHelloFields(cost: metered),
                             AdaptiveHelloFields(effectiveRefreshHz: 60, telemetry: true, cost: vpnLowData)],
             [wifi, cable, remote, metered, lowData, vpnLowData]),
            ("saveData off", [AdaptiveHelloFields(saveData: .off), AdaptiveHelloFields(cost: lowData, saveData: .off),
                              AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, cost: vpnLowData, saveData: .off)],
             [wifi, lowData, cable, vpnLowData]),
            ("saveData auto, nothing clear", [AdaptiveHelloFields(saveData: .auto),
                                              AdaptiveHelloFields(cost: wifi, saveData: .auto),
                                              AdaptiveHelloFields(cost: metered, saveData: .auto),
                                              AdaptiveHelloFields(cost: metered, saveData: .auto, saveDataAnswer: .keepQuality)],
             [wifi, cable, remote, metered]),
        ]
        var now = 1_000.0
        var epoch: UInt64 = 0
        var round = 0
        for (label, hellos, routes) in phases {
            for hello in hellos {
                for route in routes {
                    round += 1
                    if round == 20 {
                        // A reconnect on the same sender (a route migration swaps only the socket).
                        let reHello: [String: Any] = ["type": "hello", "pixelsWide": 2732, "pixelsHigh": 2048,
                                                      "scale": 2.0, "device": "iPad",
                                                      "id": "adaptive-call-site-test-ipad", "pv": WireProtocol.version]
                        _ = try await sender.admitConnectionForTesting(
                            helloJSON: try JSONSerialization.data(withJSONObject: reHello),
                            pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: sent.record)
                    }
                    let sentBefore = sent.count
                    epoch += 1
                    now += 1
                    try await sender.adaptiveRouteChangeForTesting(route, epoch: epoch, now: now)
                    try await sender.adaptiveHelloForTesting(try helloJSON(hello), now: now)
                    let state = try await sender.adaptiveCallSiteStateForTesting
                    XCTAssertEqual(state.requestedDataPolicy, .normal, "\(label): the matrix asks for no saving")
                    now += 2
                    let lockScreen = round % 3 == 0
                    try await sender.adaptiveTickForTesting(now: now, lockScreenShown: lockScreen)
                    if lockScreen { try await sender.endLockScreenViewForTesting() }
                    try await sender.settleForTesting()
                    XCTAssertEqual(sent.count, sentBefore, "\(label): nothing on the wire")
                }
            }
        }
        // Hostile values read as absent.
        for raw in [["type": "hello", "saveData": 5, "cost": "x", "effHz": 1e300] as [String: Any],
                    ["type": "hello", "saveData": "always", "saveDataAnswer": ["v": 1], "adaptiveTelemetry": true]] {
            now += 2
            try await sender.adaptiveHelloForTesting(try JSONSerialization.data(withJSONObject: raw), now: now)
            try await sender.adaptiveTickForTesting(now: now)
        }
        assertSwitchOffState(try await sender.adaptiveCallSiteStateForTesting, monitorWrites: writes, "after the matrix")
        // A start whose noted size disagrees is still never restarted.
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 3024, displayHeight: 1964, pixelsWide: 2732, pixelsHigh: 2048,
            lockScreenShown: true)
        XCTAssertFalse(probe.restartRequested)
        XCTAssertEqual(probe.deferred, .none)
    }

    /// Data saving on, then off, with the switch off: once the capture runs
    /// at today's size again the sender is back in the switch-off state, and
    /// a later start whose noted size disagrees is never restarted (before
    /// this fix the re-check stayed armed for the sender's life).
    func testAfterDataSavingEndsTheSenderIsBackInTheSwitchOffState() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        // Saving asked for before the capture runs, so the return needs no dwell.
        try await sender.adaptiveHelloForTesting(try helloJSON(AdaptiveHelloFields(saveData: .on)), now: 0)
        let saving = try await sender.adaptiveCallSiteStateForTesting
        XCTAssertEqual(saving.plan?.origin, .dataSaver, "the documented nuance: saving acts with the switch off")
        XCTAssertTrue(saving.hasManagedRaster)
        // The capture starts at the saver size, then saving ends.
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2048, pixelsHigh: 1536)
        XCTAssertFalse(probe.restartRequested, "started at the planned size")
        try await sender.adaptiveHelloForTesting(try helloJSON(AdaptiveHelloFields(saveData: .off)), now: 1)
        let returned = try await sender.adaptiveCallSiteStateForTesting
        XCTAssertNil(returned.plan)
        XCTAssertTrue(returned.hasManagedRaster, "armed until a capture runs at today's size")
        // The restart back to today's size (what the pipeline runs for it).
        let restarted = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048)
        XCTAssertFalse(restarted.restartRequested)
        XCTAssertFalse(restarted.hasManagedRaster, "back in the switch-off state")
        // Now a start noted against another mode is left alone, as with the switch off from the start.
        for (displayWidth, displayHeight) in [(3024, 1964), (1366, 1024)] {
            for lockScreenShown in [false, true] {
                let later = try await sender.adaptiveCaptureStartRecheckForTesting(
                    displayID: missingDisplay, displayWidth: displayWidth, displayHeight: displayHeight,
                    pixelsWide: 2732, pixelsHigh: 2048, lockScreenShown: lockScreenShown)
                XCTAssertFalse(later.restartRequested, "\(displayWidth)x\(displayHeight)")
                XCTAssertEqual(later.deferred, .none)
                XCTAssertFalse(later.hasManagedRaster)
            }
        }
    }

    /// The Beta switch turned on and then off rebuilds every session
    /// (`restartAll`, OpenSidecarMacApp.swift), so the sender after it is a
    /// new one: identical to a sender whose switch was never on, even though
    /// the earlier one had managed the raster.
    func testASenderBuiltAfterTheSwitchWentOnAndOffIsTheSwitchOffState() async throws {
        let (earlier, _, cleanupEarlier) = try await admittedSender(adaptiveAutomatic: true)
        defer { cleanupEarlier() }
        XCTAssertTrue(earlier.adaptive.announcesAdaptive)
        _ = try await earlier.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048,
            saveData: .on)
        XCTAssertTrue(earlier.adaptive.hasManagedRaster)
        earlier.stop()
        let (rebuilt, _, cleanupRebuilt) = try await admittedSender(adaptiveAutomatic: false)
        defer { cleanupRebuilt() }
        let (never, _, cleanupNever) = try await admittedSender(adaptiveAutomatic: false)
        defer { cleanupNever() }
        var states: [MacSender.AdaptiveCallSiteState] = []
        for sender in [rebuilt, never] {
            XCTAssertFalse(sender.adaptive.announcesAdaptive)
            try await sender.adaptiveHelloForTesting(
                try helloJSON(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true, saveData: .off)), now: 10)
            try await sender.adaptiveTickForTesting(now: 12)
            _ = try await sender.adaptiveCaptureStartRecheckForTesting(
                displayID: missingDisplay, displayWidth: 3024, displayHeight: 1964, pixelsWide: 2732, pixelsHigh: 2048)
            let state = try await sender.adaptiveCallSiteStateForTesting
            assertSwitchOffState(state, monitorWrites: state.monitorWrites, "switch off")
            states.append(state)
        }
        XCTAssertEqual(states[0], states[1], "the same as never having switched on")
    }

    /// #123 churn: a return from saving that matures while the lock screen
    /// view is shown is applied by the tick, held by the view like any other
    /// adaptive change, and run when the view ends: never lost.
    func testAReturnFromSavingThatMaturesDuringTheLockScreenViewRunsWhenItEnds() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        // A capture runs at today's size, then saving starts (dwell from 0).
        _ = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048)
        try await sender.adaptiveHelloForTesting(try helloJSON(AdaptiveHelloFields(saveData: .on)), now: 0)
        try await sender.adaptiveHelloForTesting(try helloJSON(AdaptiveHelloFields(saveData: .off)), now: 3)
        try await sender.adaptiveTickForTesting(now: 10, lockScreenShown: true)
        let waiting = try await sender.adaptiveCallSiteStateForTesting
        XCTAssertEqual(waiting.appliedDataPolicy, .saver, "inside the dwell")
        XCTAssertEqual(waiting.requestedDataPolicy, .normal)
        let saverPath = waiting.deferred
        try await sender.adaptiveTickForTesting(now: 22, lockScreenShown: true)
        let held = try await sender.adaptiveCallSiteStateForTesting
        XCTAssertEqual(held.appliedDataPolicy, .normal, "the tick applied the return")
        XCTAssertNil(held.plan)
        XCTAssertEqual(held.deferred, .captureRestart, "held by the lock screen view (was \(saverPath))")
        try await sender.endLockScreenViewForTesting()
        let ended = try await sender.adaptiveCallSiteStateForTesting
        XCTAssertEqual(ended.deferred, .none, "run when the view ended")
        XCTAssertNil(ended.plan)
    }

    func testChangesHeldForTheLockScreenViewAreDroppedOnStop() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048,
            saveData: .on, lockScreenShown: true)
        XCTAssertEqual(probe.deferred, .captureRestart)
        sender.stop()
        let afterStop = try await sender.adaptiveLockScreenDeferralForTesting
        XCTAssertEqual(afterStop, .none)
    }

    // MARK: - #123 Beta off: the real `stats` handler

    /// A receiver `stats` exactly as origin/dev's receiver sent it (literal
    /// keys), plus every adaptive telemetry key a newer receiver adds while
    /// a Mac announces adaptive mode, with values that would ask a running
    /// controller for a step down (low delivery, late frames, high jitter,
    /// serious thermal, Low Power).
    private func statsWithTelemetry() throws -> Data {
        let object: [String: Any] = [
            "type": "stats", "transport": "wifi", "fps": 18, "mbps": 4.2, "e2e50": 140, "e2e95": 420,
            "enc50": 9, "rtt": 85, "stalls": 7, "cur": 0, "curLost": 0, "inp50": 0, "capFps": 60,
            "dec50": 6, "ph50": 0, "ph95": 0, "offsetKnown": true,
            "win": 2, "deliveredFps": 18, "decodedFps": 18, "enqFps": 18, "dec95": 45, "presAge": 300,
            "late": 40, "jit": 60, "thermal": 2, "lowPower": true,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Gap: no test drove the real `case "stats"` handler with telemetry keys
    /// and the Beta switch off. Through `handleCurrentConnectionControl` (the
    /// live connection's control path), repeated `stats` with every
    /// telemetry key, around ticks, a telemetry hello and a reconnect: the
    /// coordinator returns at its `announcesAdaptive` guard. Nothing is
    /// parsed, planned, armed or held, no capture or encoder change is asked
    /// for, and nothing goes on the wire. Fails if the guard in
    /// `AdaptiveStreamingCoordinator.receiverStats(json:)` is removed or the
    /// handler parses or applies telemetry another way while switched off.
    func testSwitchOffRealStatsHandlerWithTelemetryKeysStopsAtTheGuard() async throws {
        let (sender, sent, cleanup) = try await admittedSender()
        defer { cleanup() }
        XCTAssertFalse(sender.adaptive.announcesAdaptive, "the Beta switch is off: no `adaptive` key in the ping")
        let writes = try await sender.adaptiveCallSiteStateForTesting.monitorWrites
        let stats = try statsWithTelemetry()
        // Even a hello that offers telemetry, as a newer receiver's does.
        try await sender.adaptiveHelloForTesting(
            try helloJSON(AdaptiveHelloFields(effectiveRefreshHz: 120, telemetry: true)), now: 1_000)
        var now = 1_000.0
        for round in 0..<6 {
            if round == 3 {
                // A reconnect on the same sender.
                let reHello: [String: Any] = ["type": "hello", "pixelsWide": 2732, "pixelsHigh": 2048,
                                              "scale": 2.0, "device": "iPad",
                                              "id": "adaptive-call-site-test-ipad", "pv": WireProtocol.version]
                _ = try await sender.admitConnectionForTesting(
                    helloJSON: try JSONSerialization.data(withJSONObject: reHello),
                    pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: sent.record)
            }
            let sentBefore = sent.count
            try await sender.receiveControlForTesting(stats)
            try await sender.settleForTesting()
            assertSwitchOffState(try await sender.adaptiveCallSiteStateForTesting, monitorWrites: writes,
                                 "stats \(round), before the tick")
            now += 2
            try await sender.adaptiveTickForTesting(now: now)
            try await sender.settleForTesting()
            assertSwitchOffState(try await sender.adaptiveCallSiteStateForTesting, monitorWrites: writes,
                                 "stats \(round), after the tick")
            XCTAssertEqual(sent.count, sentBefore, "stats \(round): nothing on the wire")
            XCTAssertFalse(sender.adaptive.announcesAdaptive)
        }
        // A hostile `stats` (wrong types, out-of-range numbers) is no different.
        let hostile: [String: Any] = ["type": "stats", "win": 1e300, "deliveredFps": "x", "thermal": 99,
                                      "lowPower": 1, "rtt": -5, "jit": ["v": 1]]
        try await sender.receiveControlForTesting(try JSONSerialization.data(withJSONObject: hostile))
        try await sender.adaptiveTickForTesting(now: now + 2)
        assertSwitchOffState(try await sender.adaptiveCallSiteStateForTesting, monitorWrites: writes, "hostile stats")
    }

    /// The control for the test above: the same `stats` through the same
    /// path reaches the coordinator and is parsed once the switch is on, so
    /// the switch-off result is the guard, not a message dropped earlier.
    func testSwitchOnRealStatsHandlerParsesTheSameTelemetry() async throws {
        let (sender, _, cleanup) = try await admittedSender(adaptiveAutomatic: true)
        defer { cleanup() }
        XCTAssertTrue(sender.adaptive.announcesAdaptive)
        let before = try await sender.adaptiveCallSiteStateForTesting.work.telemetryParsed
        try await sender.receiveControlForTesting(try statsWithTelemetry())
        try await sender.settleForTesting()
        let after = try await sender.adaptiveCallSiteStateForTesting.work.telemetryParsed
        XCTAssertEqual(after, before + 1, "the real handler hands telemetry to the coordinator")
    }

    // MARK: - #123 Beta off: the real ping

    /// The `ping` origin/dev's `schedulePing` builds (`git show
    /// origin/dev:Mac/MacSender.swift`), written out for a freshly admitted
    /// session with input latencies 3.2, 5.4 and 8.6 ms: no drops, nothing
    /// pending, no frames captured. The DEBUG build (the one tests run)
    /// appends the two audio keys there too.
    private static let originDevPing = "{\"type\":\"ping\",\"drops\":0,\"encDrops\":0,\"netDrops\":0,\"pending\":0,"
        + "\"inp50\":5.0,\"inp95\":9.0,\"capFps\":0,\"audioPkts\":0,\"audioKbps\":0}"
    private static let originDevPingKeys: Set<String> = [
        "type", "drops", "encDrops", "netDrops", "pending", "inp50", "inp95", "capFps", "audioPkts", "audioKbps",
    ]
    private static let pingLatencies: [Double] = [8.6, 3.2, 5.4]

    /// Diagnostics add their own `diag` key; these tests are about the Beta switch.
    private func withDiagnosticsOff(_ body: () async throws -> Void) async rethrows {
        let diagnostics = StreamDiagnosticsSwitch.shared
        let wasOn = diagnostics.isEnabled
        diagnostics.set(false)
        defer { diagnostics.set(wasOn) }
        try await body()
    }

    /// The JSON `schedulePing` really sends (`buildPingJSON`) with the Beta
    /// switch off is byte for byte origin/dev's, every window. Fails if the
    /// switch-off ping gains, loses, renames or reorders a key, or changes a
    /// value's formatting (for example the `adaptive` key with the switch
    /// off, or `inp50` as an integer).
    func testSwitchOffPingIsByteForByteOriginDevs() async throws {
        try await withDiagnosticsOff {
            let (sender, _, cleanup) = try await admittedSender()
            defer { cleanup() }
            XCTAssertFalse(sender.adaptive.announcesAdaptive, "the Beta switch is off")
            for window in 0..<3 {
                let ping = try await sender.pingJSONForTesting(inputLatencies: Self.pingLatencies)
                XCTAssertEqual(ping, Self.originDevPing, "window \(window)")
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ping.utf8)) as? [String: Any])
                XCTAssertEqual(Set(object.keys), Self.originDevPingKeys, "window \(window)")
            }
        }
    }

    /// Control for the test above: the same sender path with the switch on
    /// announces adaptive mode, so the test above sees the switch, not a
    /// ping built some other way.
    func testSwitchOnPingAddsOnlyTheAnnounceKey() async throws {
        try await withDiagnosticsOff {
            let (sender, _, cleanup) = try await admittedSender(adaptiveAutomatic: true)
            defer { cleanup() }
            XCTAssertTrue(sender.adaptive.announcesAdaptive)
            let ping = try await sender.pingJSONForTesting(inputLatencies: Self.pingLatencies)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ping.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Self.originDevPingKeys.union(["adaptive"]))
            XCTAssertEqual(object["adaptive"] as? Int, 1)
            XCTAssertTrue(AdaptiveStreamingWire.isAnnounced(inPing: object))
            XCTAssertEqual(ping, String(Self.originDevPing.dropLast()) + ",\"adaptive\":1}")
        }
    }
}
