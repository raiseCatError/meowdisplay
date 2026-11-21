import XCTest

/// #123 diagnostics review fixes: an off period is not a freeze but a silence
/// while on is one of its real length, a silent peer's summary expires, the switch is cheap and keeps
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
        let snapshot = r.snapshot(at: 4_100)
        let stage = snapshot.stage(.arrivalInterval)
        // Changed with the B5 fix: the in-progress window now starts over at
        // the switch transition (its rate is not diluted by the off time), so
        // the 16 ms interval before the off period is no longer in it.
        XCTAssertEqual(stage?.count, 1, "one 16 ms interval after the switch, no 3 s one")
        XCTAssertEqual(snapshot.windowSeconds, 0.1, accuracy: 1e-9, "the window restarted at 4 s")
        XCTAssertEqual(snapshot.count(.arrivedFrames), 2)
        XCTAssertEqual(stage?.gapsOver250ms, 0)
        XCTAssertLessThan(stage?.max ?? .infinity, 100)
    }

    func testAnOffPeriodLongerThanTwoWindowsIsNeverAFreeze() {
        let (r, sw) = makeRecorder()
        for t in stride(from: 100.0, through: 3_000, by: 100) {
            r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: t)
        }
        sw.set(false)
        _ = r.snapshot(at: 9_000)   // read while off: the off time completes nothing new as a freeze
        sw.set(true)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 14_000)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 14_016)
        let s = r.snapshot(at: 19_100)
        XCTAssertEqual(s.stage(.arrivalInterval)?.gapsOver500ms, 0)
        XCTAssertEqual(s.stage(.arrivalInterval)?.count, 1)
        XCTAssertLessThan(s.stage(.arrivalInterval)?.max ?? .infinity, 100)
    }

    /// Replaces testTwoSkippedWindowsRestartTheIntervalBaselines, which
    /// asserted the B5 bug: a 12 s silence while on was dropped (no gap, and
    /// the window holding the frames before it discarded).
    func testSilenceWhileEnabledIsRecordedAsAFreezeOfItsRealLength() throws {
        let (r, _) = makeRecorder()
        for t in stride(from: 100.0, through: 1_000, by: 100) {
            r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: t)
        }
        // Nothing for 12 s while diagnostics stay on: a freeze.
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 13_000)
        let before = r.snapshot(at: 13_000)
        XCTAssertEqual(before.count(.arrivedFrames), 10, "the frames before the silence are kept, not discarded")
        XCTAssertEqual(before.windowSeconds, 13, accuracy: 1e-9, "the window's real length, silence included")
        r.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 13_016)
        // The window holding the frames after the silence completes at 18 s.
        let after = r.snapshot(at: 18_100)
        let stage = try XCTUnwrap(after.stage(.arrivalInterval))
        XCTAssertEqual(stage.count, 2, "the 12 s freeze and the 16 ms interval")
        XCTAssertEqual(stage.gapsOver500ms, 1)
        XCTAssertEqual(stage.max, 12_000, accuracy: 1e-9)
        XCTAssertEqual(after.count(.arrivedFrames), 2)
        // Every arrival is in exactly one window.
        XCTAssertEqual(r.snapshot(at: 18_200).sessionCounters[DiagnosticsCounter.arrivedFrames.definition.id], 12)

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
        s.frameIDUnexamined = .nan
        s.windowSequence = .infinity
        let wire = s.wireFields
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: wire))
        XCTAssertNotNil(s.wireJSON)
        XCTAssertEqual(wire["arrFps"] as? Double, StreamDiagnosticsPeerSummary.wireValueCeiling)
        XCTAssertEqual(wire["fidSkip"] as? Double, StreamDiagnosticsPeerSummary.wireValueCeiling)
        XCTAssertNil(wire["fidUnx"])
        XCTAssertNil(wire["wseq"])
    }

    func testHostileVersionAndFrameIDKeysNeverTrap() {
        for v: Any in [1e300, -1e300, Double.nan, Double.infinity, Int.max, true, "1", ["v": 1]] {
            XCTAssertNil(StreamDiagnosticsPeerSummary.fromWire(["v": v, "fidUnx": 3], side: .receiver), "v \(v)")
        }
        for value: Any in [1e300, -1e300, Double.nan, Double.infinity, Int.max, UInt64.max] {
            let parsed = StreamDiagnosticsPeerSummary.fromWire(
                ["v": 1, "fidUnx": value, "fidSkip": value, "fidDup": value, "fid95": value, "decN": value,
                 "wid": value, "wseq": value, "wps": value],
                side: .receiver)
            for field in [parsed?.frameIDUnexamined, parsed?.frameIDMissing, parsed?.frameIDDuplicates,
                          parsed?.frameIDIntervalP95Ms, parsed?.decodeSamples, parsed?.windowSeriesID,
                          parsed?.windowSequence, parsed?.peerWindowSequenceAtStart] {
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

    // MARK: - Window series and sequence (B1/B2)

    func testWindowSequenceSeriesAndStartMarkerReachTheWire() throws {
        let (receiver, _) = makeRecorder()
        receiver.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 100)
        let partial = StreamDiagnosticsPeerSummary.from(receiver.snapshot(at: 200)).wireFields
        XCTAssertNotNil(partial["wid"], "the series is known from the start")
        XCTAssertNil(partial["wseq"], "a partial window has no number")
        // The sender's ping told the receiver it completed window 7.
        var ping = StreamDiagnosticsPeerSummary(side: .sender)
        ping.windowSequence = 7
        receiver.updatePeer(ping, at: 300)
        _ = receiver.snapshot(at: 5_000)       // window 1 completes; window 2 begins having heard 7
        let second = StreamDiagnosticsPeerSummary.from(receiver.snapshot(at: 10_000))
        let wire = second.wireFields
        XCTAssertEqual(wire["wseq"] as? Double, 2)
        XCTAssertEqual(wire["wps"] as? Double, 7)
        let parsed = try XCTUnwrap(StreamDiagnosticsPeerSummary.fromWire(wire, side: .receiver))
        XCTAssertEqual(parsed.windowSeriesID, second.windowSeriesID)
        // A new session: a new series, the sequence keeps counting, no marker yet.
        let oldSeries = try XCTUnwrap(second.windowSeriesID)
        receiver.reset(at: 10_000)
        let next = StreamDiagnosticsPeerSummary.from(receiver.snapshot(at: 15_000))
        XCTAssertNotEqual(next.windowSeriesID, oldSeries)
        XCTAssertEqual(next.windowSequence, 3)
        XCTAssertNil(next.peerWindowSequenceAtStart)
        // The sender sends its own sequence only.
        let sender = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                               resourceSampler: nil, nowMs: 0)
        let senderWire = StreamDiagnosticsPeerSummary.from(sender.snapshot(at: 5_000)).wireFields
        XCTAssertEqual(senderWire["wseq"] as? Double, 1)
        XCTAssertNil(senderWire["wid"])
        XCTAssertNil(senderWire["wps"])
    }

    func testRemovedWireKeysAreNeitherSentNorRead() {
        let sender = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                               resourceSampler: nil, nowMs: 0)
        sender.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: 5, pendingEncodes: 1, at: 1)
        sender.recordSubmit(origin: .dropReplay, sourceKey: 1, sourceAgeMs: 5, pendingEncodes: 1, at: 2)
        sender.recordEncodeOutput(durationMs: 4, bytes: 1, keyframe: false, outcome: .sent, at: 3)
        let wire = StreamDiagnosticsPeerSummary.from(sender.snapshot(at: 5_000)).wireFields
        for key in ["dup", "age95", "enc50", "qMax", "fidN"] { XCTAssertNil(wire[key], key) }
        XCTAssertNil(wire["capU"], "no display capture callbacks: not measured, so not sent as 0")
    }

    // MARK: - RTT jitter needs samples (B8)

    func testOneEarlyRTTOutlierNeverCountsAsJitterEvidence() {
        let (r, _) = makeRecorder()
        r.recordRTT(300, at: 1)
        for i in 0..<6 { r.recordRTT(5, at: Double(2 + i)) }
        XCTAssertNil(r.snapshot(at: 10).rttJitterMs, "7 samples: not reported yet")
        r.recordRTT(5, at: 11)
        let jitter = r.snapshot(at: 12).rttJitterMs
        XCTAssertNotNil(jitter)
        XCTAssertLessThan(jitter ?? .infinity, StreamBottleneckClassifier.rttJitterMs,
                          "RFC 3550 start at 0: one 295 ms step moves the estimate by 1/16 of it")
        XCTAssertNil(StreamDiagnosticsPeerSummary.from(StreamDiagnosticsRecorder(
            side: .receiver, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
            resourceSampler: nil, nowMs: 0).snapshot(at: 1)).rttJitterMs)
    }

    // MARK: - Restart gap (B3)

    func testRestartRecordsTheGapToTheFirstFrameAfterIt() throws {
        let sender = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                               resourceSampler: nil, nowMs: 0)
        sender.noteGeneration(1, at: 0)
        sender.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: nil, pendingEncodes: 1, at: 100)
        sender.recordSubmit(origin: .live, sourceKey: 2, sourceAgeMs: nil, pendingEncodes: 1, at: 116)
        // The first submission of the new generation is where MacSender notes it.
        sender.noteGeneration(2, at: 916)
        sender.recordSubmit(origin: .live, sourceKey: 3, sourceAgeMs: nil, pendingEncodes: 1, at: 916)
        sender.recordSubmit(origin: .live, sourceKey: 4, sourceAgeMs: nil, pendingEncodes: 1, at: 932)
        let s = sender.snapshot(at: 1_000)
        let gap = try XCTUnwrap(s.stage(.restartSubmitGap))
        XCTAssertEqual(gap.count, 1)
        XCTAssertEqual(gap.max, 800, accuracy: 1e-9)
        XCTAssertEqual(s.stage(.submitInterval)?.gapsOver500ms, 0, "the restart is not a stall")

        let (receiver, _) = makeRecorder()
        receiver.noteGeneration(1, at: 0)
        receiver.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 100)
        receiver.noteGeneration(2, at: 200)
        receiver.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 450)
        XCTAssertEqual(receiver.snapshot(at: 500).stage(.restartArrivalGap)?.max ?? 0, 350, accuracy: 1e-9)
    }
}
