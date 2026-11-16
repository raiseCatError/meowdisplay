import XCTest

/// #123 diagnostics review fixes: an off period or a long idle spell is not
/// a freeze, a silent peer's summary expires, the switch is cheap and keeps
/// its semantics, replays never use a stale capture timestamp, the wire
/// summary is always serializable, and the Performance Lab frame-ID reader
/// re-baselines on a new session or stream generation.
final class StreamDiagnosticsHardeningTests: XCTestCase {
    private func makeRecorder(enabled: Bool = true, window: Double = 5)
        -> (StreamDiagnosticsRecorder, StreamDiagnosticsSwitch) {
        let sw = StreamDiagnosticsSwitch(enabled: enabled)
        return (StreamDiagnosticsRecorder(side: .receiver, windowSeconds: window, diagnosticsSwitch: sw,
                                          resourceSampler: nil, nowMs: 0), sw)
    }

    // MARK: - Re-enable gap and skipped windows

    func testReEnablingDoesNotRecordTheOffPeriodAsAFreeze() {
        let (r, sw) = makeRecorder()
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 1_000)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 1_016)
        sw.set(false)
        // Off for 3 s (inside one window), then on again.
        sw.set(true)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 4_000)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 4_016)
        let stage = r.snapshot(at: 4_100).stage(.arrivalInterval)
        XCTAssertEqual(stage?.count, 2, "two 16 ms intervals, no 3 s one")
        XCTAssertEqual(stage?.gapsOver250ms, 0)
        XCTAssertLessThan(stage?.max ?? .infinity, 100)
    }

    func testTwoSkippedWindowsRestartTheIntervalBaselines() {
        let (r, _) = makeRecorder()
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 1_000)
        // Nothing for 12 s (more than two 5 s windows): idle, not a freeze.
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 13_000)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 13_016)
        // The window holding those two arrivals completes at 18 s.
        let stage = r.snapshot(at: 18_100).stage(.arrivalInterval)
        XCTAssertEqual(stage?.count, 1, "only the 16 ms interval")
        XCTAssertEqual(stage?.gapsOver500ms, 0)
        XCTAssertLessThan(stage?.max ?? .infinity, 100)

        // A real 600 ms stall inside a window is still recorded.
        let (live, _) = makeRecorder()
        live.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 100)
        live.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 700)
        XCTAssertEqual(live.snapshot(at: 800).stage(.arrivalInterval)?.gapsOver500ms, 1)
    }

    func testSwitchSemanticsAndEnableEpoch() {
        let sw = StreamDiagnosticsSwitch(enabled: false)
        XCTAssertFalse(sw.isEnabled)
        let start = sw.enableEpoch
        sw.set(true)
        XCTAssertTrue(sw.isEnabled)
        XCTAssertEqual(sw.enableEpoch, start + 1)
        sw.set(true)
        XCTAssertEqual(sw.enableEpoch, start + 1, "already on: no new epoch")
        sw.set(false)
        XCTAssertFalse(sw.isEnabled)
        sw.set(true)
        XCTAssertEqual(sw.enableEpoch, start + 2)
        XCTAssertFalse(StreamDiagnosticsSwitch().isEnabled, "off by default")
    }

    func testSwitchIsSafeUnderConcurrentReadsAndWrites() {
        let sw = StreamDiagnosticsSwitch(enabled: false)
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            if i % 50 == 0 { sw.set(i % 100 == 0) } else { _ = sw.isEnabled }
        }
        sw.set(true)
        XCTAssertTrue(sw.isEnabled)
    }

    // MARK: - Peer expiry

    func testPeerSummaryExpiresAfterTwoWindowsWithoutAnUpdate() {
        let (r, _) = makeRecorder(window: 5)
        var peer = StreamDiagnosticsPeerSummary(side: .sender)
        peer.encodeP95Ms = 7
        r.updatePeer(peer, at: 1_000)
        XCTAssertEqual(r.snapshot(at: 6_000).peer?.encodeP95Ms, 7)
        XCTAssertEqual(r.snapshot(at: 11_000).peer?.encodeP95Ms, 7, "exactly two windows: still fresh")
        XCTAssertNil(r.snapshot(at: 11_001).peer, "the peer stopped reporting")
        r.updatePeer(peer, at: 12_000)
        XCTAssertNotNil(r.snapshot(at: 12_500).peer)
    }

    // MARK: - Resource sample outside the lock

    func testResourceSampleIsTakenWhenAWindowCompletes() {
        let sw = StreamDiagnosticsSwitch(enabled: true)
        let r = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: sw,
                                          resourceSampler: StreamDiagnosticsResourceSampler(), nowMs: 0)
        r.increment(.keyframes, at: 1)
        XCTAssertNil(r.snapshot(at: 2).resources)
        r.increment(.keyframes, at: 5_001)
        XCTAssertNotNil(r.snapshot(at: 5_002).resources, "sampled after the rotating call released the lock")
        // A rotation from snapshot itself is visible in that same snapshot.
        XCTAssertNotNil(r.snapshot(at: 10_500).resources)
    }

    // MARK: - Wire summary is always serializable

    func testWireSummaryClampsBeforeScaling() throws {
        var s = StreamDiagnosticsPeerSummary(side: .receiver)
        s.arrivalFPS = Double.greatestFiniteMagnitude
        s.rttMs = -1e308
        s.frameIDMissing = 1e300
        s.frameIDReadCount = .nan
        let wire = s.wireFields
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: wire))
        XCTAssertNotNil(s.wireJSON)
        XCTAssertEqual(wire["arrFps"] as? Double, StreamDiagnosticsPeerSummary.wireValueCeiling)
        XCTAssertEqual(wire["fidSkip"] as? Double, StreamDiagnosticsPeerSummary.wireValueCeiling)
        XCTAssertNil(wire["fidN"])
    }

    func testHostileVersionAndFrameIDKeysNeverTrap() {
        for v: Any in [1e300, -1e300, Double.nan, Double.infinity, Int.max, true, "1", ["v": 1]] {
            XCTAssertNil(StreamDiagnosticsPeerSummary.fromWire(["v": v, "fidN": 3], side: .receiver), "v \(v)")
        }
        for value: Any in [1e300, -1e300, Double.nan, Double.infinity, Int.max, UInt64.max] {
            let parsed = StreamDiagnosticsPeerSummary.fromWire(
                ["v": 1, "fidN": value, "fidSkip": value, "fidDup": value, "fid95": value, "decN": value],
                side: .receiver)
            for field in [parsed?.frameIDReadCount, parsed?.frameIDMissing, parsed?.frameIDDuplicates,
                          parsed?.frameIDIntervalP95Ms, parsed?.decodeSamples] {
                if let field {
                    XCTAssertTrue((0...StreamDiagnosticsPeerSummary.wireValueCeiling).contains(field), "\(value)")
                }
            }
        }
        // The classifier converts peer counts through PeerNumber: bounded input, no trap.
        var peer = StreamDiagnosticsPeerSummary(side: .receiver)
        peer.decodeSamples = StreamDiagnosticsPeerSummary.wireValueCeiling
        peer.arrivalFPS = StreamDiagnosticsPeerSummary.wireValueCeiling
        let (r, _) = makeRecorder()
        let sender = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5,
                                               diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                               resourceSampler: nil, nowMs: 0)
        sender.updatePeer(peer, at: 1)
        _ = StreamClassifierInputs(snapshot: sender.snapshot(at: 6_000))
        _ = r
    }

    // MARK: - Replay source accounting (Window view never uses a stale PTS)

    func testWindowViewReplayNeverUsesAStaleCaptureTimestamp() {
        let stale = 1_234.5
        for origin in [DiagnosticsSubmitOrigin.dropReplay, .reconnectReplay, .live, .heldRetry, .workspace] {
            XCTAssertNil(MacSender.diagnosticsSourcePTS(origin: origin, windowMode: true,
                                                        lastCapturePTS: stale, livePTS: 99), "\(origin)")
        }
        XCTAssertEqual(MacSender.diagnosticsSourcePTS(origin: .dropReplay, windowMode: false,
                                                      lastCapturePTS: stale, livePTS: 99), stale)
        XCTAssertEqual(MacSender.diagnosticsSourcePTS(origin: .live, windowMode: false,
                                                      lastCapturePTS: stale, livePTS: 99), 99)
        XCTAssertNil(MacSender.diagnosticsSourcePTS(origin: .reconnectReplay, windowMode: false,
                                                    lastCapturePTS: nil, livePTS: 99),
                     "a cleared timestamp is unknown, never reused")

        // Through the recorder: an unknown key is never counted as a duplicate.
        let (r, _) = makeRecorder()
        let key = { (pts: Double?) in pts.map { Int64(($0 * 1_000_000).rounded()) } }
        r.recordSubmit(origin: .live, sourceKey: key(stale), sourceAgeMs: nil, pendingEncodes: 0, at: 1)
        let replay = MacSender.diagnosticsSourcePTS(origin: .dropReplay, windowMode: true, lastCapturePTS: stale, livePTS: nil)
        r.recordSubmit(origin: .dropReplay, sourceKey: key(replay), sourceAgeMs: nil, pendingEncodes: 0, at: 2)
        let s = r.snapshot(at: 3)
        XCTAssertEqual(s.count(.submitDuplicate), 0)
        XCTAssertEqual(s.count(.submitUniquenessUnknown), 1)
    }

    // MARK: - Performance Lab reader reset

    private func strip(counter: UInt32) -> PerformanceLabLumaImage {
        var image = PerformanceLabLumaImage(width: 800, height: 120, fill: 200)
        image.drawStrip(counter: counter, segment: 2, x: 20, y: 10, width: 756,
                        height: 756 / PerformanceLabFrameIDCodec.stripModules * PerformanceLabFrameIDCodec.stripHeightModules)
        return image
    }

    func testFrameIDReaderRebaselinesOnANewGenerationOrSession() {
        let probe = PerformanceLabFrameIDProbe()
        let (r, _) = makeRecorder()
        probe.observe(strip(counter: 10), recorder: r, generation: 1, nowMs: 16)
        probe.observe(strip(counter: 11), recorder: r, generation: 1, nowMs: 32)
        XCTAssertTrue(probe.isLocked)
        // Reconnect mid-trial: the fixture counter has moved on by 500.
        probe.observe(strip(counter: 511), recorder: r, generation: 2, nowMs: 48)
        probe.observe(strip(counter: 513), recorder: r, generation: 2, nowMs: 64)
        var snapshot = r.snapshot(at: 70)
        XCTAssertEqual(snapshot.count(.frameIDSkipped), 1, "only the real skip (512), not the reconnect jump")
        XCTAssertEqual(snapshot.count(.frameIDRead), 4)
        XCTAssertEqual(probe.tally.read, 4, "the tally keeps counting")

        // A new receiver session (new recorder) also re-baselines.
        let (next, _) = makeRecorder()
        probe.observe(strip(counter: 900), recorder: next, generation: 2, nowMs: 80)
        snapshot = next.snapshot(at: 90)
        XCTAssertEqual(snapshot.count(.frameIDSkipped), 0)
        XCTAssertEqual(snapshot.count(.frameIDUnique), 1)
    }
}
