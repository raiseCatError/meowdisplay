import XCTest

/// Streaming diagnostics (#123): the bottleneck classifier (every verdict,
/// the unknown cases, no single-number verdicts), the optional wire summary,
/// and the export's schema, version and redaction.
final class StreamDiagnosticsClassifierExportTests: XCTestCase {

    /// A healthy 60 FPS session seen from both ends, 5 s window.
    private func healthy() -> StreamClassifierInputs {
        var i = StreamClassifierInputs()
        i.windowSeconds = 5
        i.targetFPS = 60
        i.captureCompleteFPS = 60
        i.captureSamples = 300
        i.captureIdleShare = 0
        i.submitFPS = 60
        i.encodeP50Ms = 6
        i.encodeP95Ms = 9
        i.encodeSamples = 300
        i.encoderBusyShare = 0
        i.sendBackpressureShare = 0
        i.admittedSamples = 300
        i.sendP95Ms = 3
        i.sendSamples = 300
        i.arrivalFPS = 60
        i.arrivalP50Ms = 17
        i.arrivalP95Ms = 20
        i.arrivalSamples = 300
        i.enqueueFPS = 60
        i.presenterQueueAgeP95Ms = 2
        i.presenterQueueSamples = 300
        i.rttJitterMs = 2
        // The Mac's view: its own numbers plus the receiver's summary.
        i.receiverFromPeer = true
        return i
    }

    private func verdict(_ mutate: (inout StreamClassifierInputs) -> Void) -> StreamDiagnosticsVerdict {
        var i = healthy()
        mutate(&i)
        return StreamBottleneckClassifier.classify(i)
    }

    // MARK: - Each verdict

    func testHealthySessionHasNoBottleneck() {
        let v = StreamBottleneckClassifier.classify(healthy())
        XCTAssertEqual(v.cause, .noBottleneckEvident)
        XCTAssertEqual(v.confidence, .medium)
        XCTAssertNil(v.reason)
        XCTAssertEqual(v.frameBudgetMs ?? 0, 1000.0 / 60, accuracy: 0.001)
    }

    /// B7: with nothing from the other device, "no bottleneck" is only low.
    func testNoBottleneckWithoutThePeerIsLowConfidence() {
        let v = verdict {
            $0.receiverFromPeer = false
            $0.arrivalFPS = nil; $0.arrivalP50Ms = nil; $0.arrivalP95Ms = nil; $0.arrivalSamples = 0
            $0.enqueueFPS = nil; $0.presenterQueueAgeP95Ms = nil; $0.presenterQueueSamples = 0; $0.rttJitterMs = nil
        }
        XCTAssertEqual(v.cause, .noBottleneckEvident)
        XCTAssertEqual(v.confidence, .low)
        XCTAssertEqual(v.reason, .peerMissing)
        // A real sender snapshot with no receiver summary says the same.
        let r = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                          resourceSampler: nil, nowMs: 0)
        r.updateContext { $0.targetFPS = 60 }
        var t = 0.0, key: Int64 = 0
        while t < 5_000 {
            key += 1
            r.recordCapture(.complete, at: t)
            r.increment(.admittedLive, at: t)
            r.recordSubmit(origin: .live, sourceKey: key, sourceAgeMs: 5, pendingEncodes: 1, at: t)
            r.recordEncodeOutput(durationMs: 5, bytes: 1_000, keyframe: false, outcome: .sent, at: t)
            r.recordSendCompletion(durationMs: 1, bytes: 1_000, error: false, at: t)
            t += 1000.0 / 60
        }
        let live = StreamBottleneckClassifier.classify(r.snapshot(at: 5_050))
        XCTAssertEqual(live.cause, .noBottleneckEvident)
        XCTAssertEqual(live.confidence, .low)
        XCTAssertEqual(live.reason, .peerMissing)
    }

    /// B13: a numbering receiver sends no window number while its window is
    /// partial; its rates must not be read as a whole window of samples.
    func testAPartialPeerWindowCountsAsNoSamples() {
        let r = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                          resourceSampler: nil, nowMs: 0)
        var peer = StreamDiagnosticsPeerSummary(side: .receiver)
        peer.windowSeriesID = 77
        peer.arrivalFPS = 60; peer.arrivalP95Ms = 18; peer.enqueueFPS = 60; peer.decodeSamples = 300
        r.updatePeer(peer, at: 1_000)
        let partial = StreamClassifierInputs(snapshot: r.snapshot(at: 5_050))
        XCTAssertEqual(partial.arrivalSamples, 0)
        XCTAssertEqual(partial.presenterQueueSamples, 0)
        XCTAssertEqual(partial.decodeSamples, 0)
        peer.windowSequence = 1
        r.updatePeer(peer, at: 5_100)
        let whole = StreamClassifierInputs(snapshot: r.snapshot(at: 5_200))
        XCTAssertGreaterThan(whole.arrivalSamples, 0)
        XCTAssertEqual(whole.decodeSamples, 300)
        // An older receiver numbers nothing and is read as before.
        var legacy = StreamDiagnosticsPeerSummary(side: .receiver)
        legacy.arrivalFPS = 60
        r.updatePeer(legacy, at: 5_300)
        XCTAssertGreaterThan(StreamClassifierInputs(snapshot: r.snapshot(at: 5_400)).arrivalSamples, 0)
    }

    func testEncoderOverloaded() {
        let v = verdict {
            $0.encoderBusyShare = 0.2
            $0.encodeP95Ms = 40
            $0.submitFPS = 42
        }
        XCTAssertEqual(v.cause, .encoderOverloaded)
        XCTAssertEqual(v.confidence, .high)
        XCTAssertEqual(v.evidence.filter(\.met).count, 3)
    }

    func testNetworkDeliveryFromSenderBackpressure() {
        let v = verdict {
            $0.sendBackpressureShare = 0.15
            $0.sendP95Ms = 60
        }
        XCTAssertEqual(v.cause, .networkDeliveryLimited)
    }

    func testNetworkDeliveryFromReceiverViewWithSteadySender() {
        let v = verdict {
            $0.sendBackpressureShare = nil   // receiver without the sender's shares
            $0.arrivalP95Ms = 70
            $0.rttJitterMs = 35
            $0.senderFromPeer = true
        }
        XCTAssertEqual(v.cause, .networkDeliveryLimited)
        XCTAssertTrue(v.evidence.contains { $0.fromPeer })
    }

    func testReceiverDecoderOverloaded() {
        let v = verdict {
            $0.decodeP95Ms = 30
            $0.decodeSamples = 300
            $0.presenterQueueAgeP95Ms = 25
            $0.enqueueFPS = 41
        }
        XCTAssertEqual(v.cause, .receiverDecoderOverloaded)
        XCTAssertFalse(v.alternatives.contains(.presentationSchedulingLimited), "decode explains the queueing")
    }

    func testPresentationSchedulingLimited() {
        let v = verdict {
            $0.presenterQueueAgeP95Ms = 45
            $0.enqueueFPS = 48
        }
        XCTAssertEqual(v.cause, .presentationSchedulingLimited)
    }

    /// B9: 31 complete frames/s against 60 with no idle callbacks is also
    /// what 30 fps content looks like. Capture-limited needs evidence that
    /// the source changed faster than capture delivered.
    func testSenderCaptureLimitedNeedsEvidenceOfSourceDemand() {
        let slow: (inout StreamClassifierInputs) -> Void = {
            $0.captureCompleteFPS = 31
            $0.submitFPS = 31
            $0.arrivalFPS = 31
            $0.enqueueFPS = 31
        }
        let unknown = verdict(slow)
        XCTAssertEqual(unknown.cause, .unknownInsufficientData)
        XCTAssertEqual(unknown.reason, .sourceDemandUnknown)
        let demanded = verdict { slow(&$0); $0.sourceDemandFPS = 60 }
        XCTAssertEqual(demanded.cause, .senderCaptureLimited)
        XCTAssertTrue(demanded.evidence.contains { $0.metric == "derived.source_demand_fps" && $0.met })
        // The source itself changed only 30 times a second: not capture.
        let slowSource = verdict { slow(&$0); $0.sourceDemandFPS = 30 }
        XCTAssertNotEqual(slowSource.cause, .senderCaptureLimited)
        XCTAssertNotEqual(slowSource.reason, .sourceDemandUnknown)
    }

    func testEvidenceLinesUseEachValuesOwnUnit() {
        let share = StreamVerdictEvidence(metric: "derived.encoder_busy_share", value: 0.04, comparison: .atLeast,
                                          threshold: 0.05, met: false, fromPeer: false)
        XCTAssertEqual(StreamDiagnosticsPresentation.evidenceLine(share), "derived.encoder_busy_share = 4.0% (>= 5.0%: not met)")
        let rate = StreamVerdictEvidence(metric: DiagnosticsCounter.captureComplete.definition.id, value: 31, comparison: .below,
                                         threshold: 48, met: true, fromPeer: true)
        XCTAssertEqual(StreamDiagnosticsPresentation.evidenceLine(rate), "sender.capture.complete = 31.0/s (< 48.0/s: met) [peer]")
        let ms = StreamVerdictEvidence(metric: DiagnosticsStage.encode.definition.id, value: 40, comparison: .atLeast,
                                       threshold: 25, met: true, fromPeer: false)
        XCTAssertEqual(StreamDiagnosticsPresentation.evidenceLine(ms), "sender.encode_ms = 40.0 ms (>= 25.0 ms: met)")
        for reason in StreamVerdictReason.allCases { XCTAssertFalse(StreamDiagnosticsPresentation.reasonText(reason).isEmpty) }
    }

    func testSourceRefreshLimited() {
        let v = verdict {
            $0.targetFPS = 120
            $0.sourceRefreshHz = 60
            $0.captureCompleteFPS = 59
            $0.arrivalP50Ms = 17
            $0.arrivalP95Ms = 18
        }
        XCTAssertEqual(v.cause, .sourceRefreshLimited)
        XCTAssertNotEqual(v.cause, .senderCaptureLimited)
    }

    func testWindowCompositionLimited() {
        let v = verdict {
            $0.isWindowMode = true
            $0.composeP50Ms = 14
            $0.composeP95Ms = 28
            $0.composeSamples = 200
        }
        XCTAssertEqual(v.cause, .windowCompositionLimited)
    }

    // MARK: - Unknown and single-number cases

    func testUnknownCases() {
        XCTAssertEqual(verdict { $0.windowSeconds = 1 }.reason, .windowTooShort)
        XCTAssertEqual(verdict { $0.windowSeconds = 1 }.cause, .unknownInsufficientData)
        XCTAssertEqual(verdict { $0.targetFPS = 0 }.reason, .noTargetFrameRate)
        let thin = verdict {
            $0.captureSamples = 10; $0.arrivalSamples = 10; $0.composeSamples = 0
        }
        XCTAssertEqual(thin.cause, .unknownInsufficientData)
        XCTAssertEqual(thin.reason, .tooFewSamples)
        let idle = verdict {
            $0.captureCompleteFPS = 0; $0.submitFPS = 0; $0.arrivalFPS = 0; $0.captureIdleShare = 1
        }
        XCTAssertEqual(idle.reason, .sourceIdle)
        XCTAssertEqual(StreamBottleneckClassifier.classify(StreamClassifierInputs()).cause, .unknownInsufficientData)
    }

    func testOneHighNumberNeverNamesACause() {
        XCTAssertEqual(verdict { $0.encodeP95Ms = 500 }.cause, .noBottleneckEvident)
        XCTAssertEqual(verdict { $0.sendP95Ms = 900 }.cause, .noBottleneckEvident)
        XCTAssertEqual(verdict { $0.decodeP95Ms = 200; $0.decodeSamples = 300 }.cause, .noBottleneckEvident)
        XCTAssertEqual(verdict { $0.rttJitterMs = 400 }.cause, .noBottleneckEvident)
        XCTAssertEqual(verdict { $0.presenterQueueAgeP95Ms = 300; $0.arrivalP50Ms = 40 }.cause, .noBottleneckEvident)
        XCTAssertEqual(verdict { $0.isWindowMode = true; $0.composeP95Ms = 90; $0.composeP50Ms = 2; $0.composeSamples = 300 }.cause,
                       .noBottleneckEvident)
    }

    func testUnderSampledSignalsAreIgnored() {
        // Encoder looks overloaded but only from 10 samples: not used.
        let v = verdict {
            $0.encoderBusyShare = 0.3; $0.encodeP95Ms = 40; $0.submitFPS = 40
            $0.admittedSamples = 10; $0.encodeSamples = 10
        }
        XCTAssertNotEqual(v.cause, .encoderOverloaded)
    }

    func testTiedCausesLowerConfidenceAndListAlternatives() {
        let v = verdict {
            $0.encoderBusyShare = 0.2; $0.encodeP95Ms = 40
            $0.sendBackpressureShare = 0.2; $0.sendP95Ms = 80
        }
        XCTAssertEqual(v.confidence, .low)
        XCTAssertEqual(v.reason, .conflictingEvidence)
        XCTAssertFalse(v.alternatives.isEmpty)
    }

    func testClassifiesFromARealSenderSnapshot() {
        let sw = StreamDiagnosticsSwitch(enabled: true)
        let r = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: sw, resourceSampler: nil, nowMs: 0)
        r.updateContext { $0.targetFPS = 60; $0.displayMode = .mirror }
        var t = 0.0
        var key: Int64 = 0
        while t < 5_000 {
            r.recordCapture(.complete, at: t)
            r.increment(.admittedLive, at: t)
            if Int(t / (1000.0 / 60)) % 4 == 0 {
                r.increment(.heldEncoderBusy, at: t)        // 25% turned away: encoder full
            } else {
                key += 1
                r.recordSubmit(origin: .live, sourceKey: key, sourceAgeMs: 6, pendingEncodes: 2, at: t)
                r.recordEncodeOutput(durationMs: 38, bytes: 30_000, keyframe: false, outcome: .sent, at: t + 38)
                r.recordSendCompletion(durationMs: 2, bytes: 30_000, error: false, at: t + 40)
            }
            t += 1000.0 / 60
        }
        let s = r.snapshot(at: 5_050)
        XCTAssertFalse(s.windowIsPartial)
        let v = StreamBottleneckClassifier.classify(s)
        XCTAssertEqual(v.cause, .encoderOverloaded)
        XCTAssertGreaterThanOrEqual(v.evidence.filter(\.met).count, 2)
    }

    // MARK: - Wire summary

    func testWireSummaryRoundTripsAndClampsUntrustedValues() {
        var s = StreamDiagnosticsPeerSummary(side: .sender)
        s.targetFPS = 60
        s.encodeP95Ms = 12.345
        s.encoderBusyShare = 0.25
        let wire = s.wireFields
        XCTAssertEqual(wire["v"] as? Int, 1)
        XCTAssertEqual(wire["enc95"] as? Double, 12.3)
        let parsed = StreamDiagnosticsPeerSummary.fromWire(wire, side: .sender)
        XCTAssertEqual(parsed?.targetFPS, 60)
        XCTAssertEqual(parsed?.encodeP95Ms, 12.3)
        XCTAssertNotNil(s.wireJSON)

        let hostile: [String: Any] = ["v": 1, "enc95": -5, "tgt": 1e12, "busy": true, "snd95": "x", "capU": Double.nan]
        let clamped = StreamDiagnosticsPeerSummary.fromWire(hostile, side: .sender)
        XCTAssertEqual(clamped?.encodeP95Ms, 0)
        XCTAssertEqual(clamped?.targetFPS, StreamDiagnosticsPeerSummary.wireValueCeiling)
        XCTAssertNil(clamped?.encoderBusyShare, "a bool is not a number")
        XCTAssertNil(clamped?.sendP95Ms)
        XCTAssertNil(clamped?.captureCompleteFPS)

        XCTAssertNil(StreamDiagnosticsPeerSummary.fromWire(["v": 2, "enc95": 3], side: .sender), "unknown version")
        XCTAssertNil(StreamDiagnosticsPeerSummary.fromWire(nil, side: .sender), "absent = old behaviour")
        XCTAssertNil(StreamDiagnosticsPeerSummary.fromWire(["v": 1], side: .receiver))
        // A receiver summary never fills sender fields.
        let r = StreamDiagnosticsPeerSummary.fromWire(["v": 1, "enc95": 3, "arr95": 20], side: .receiver)
        XCTAssertNil(r?.encodeP95Ms)
        XCTAssertEqual(r?.arrivalP95Ms, 20)
    }

    // MARK: - Export

    private func populatedSnapshots() -> [StreamDiagnosticsSnapshot] {
        let sw = StreamDiagnosticsSwitch(enabled: true)
        let sender = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: sw,
                                               resourceSampler: StreamDiagnosticsResourceSampler(), nowMs: 0)
        sender.updateContext {
            $0.displayMode = .window; $0.codec = .hevc; $0.rasterWidth = 2560; $0.rasterHeight = 1600
            $0.targetFPS = 60; $0.route = .remote; $0.networkProtocol = .quic; $0.pathExpensive = true
            $0.pathConstrained = false; $0.encoderInFlightLimit = 2
        }
        sender.recordCapture(.complete, at: 1)
        sender.recordSubmit(origin: .workspace, sourceKey: nil, sourceAgeMs: nil, pendingEncodes: 1, at: 2)
        sender.recordCompose(durationMs: 4, staticResend: false, tiles: 3, floats: 1, dimmed: 1, withFrame: 2, at: 3)
        var peer = StreamDiagnosticsPeerSummary(side: .receiver)
        peer.arrivalFPS = 58
        sender.updatePeer(peer)
        let receiver = StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 5, diagnosticsSwitch: sw, resourceSampler: nil, nowMs: 0)
        receiver.recordArrival(bytes: 1, wireSubmitToSendMs: 4, mappedSubmitToReceiveMs: 30, at: 1)
        receiver.recordRTT(9, at: 2)
        receiver.recordRTT(12, at: 3)
        return [sender.snapshot(at: 6_000), receiver.snapshot(at: 6_000)]
    }

    private func exportJSON() throws -> (StreamDiagnosticsExport, Any) {
        let build = StreamDiagnosticsBuildInfo.current(deviceClass: .mac, appVersion: "2.0 (214)")
        let export = StreamDiagnosticsExport(sessions: populatedSnapshots(), build: build,
                                             now: Date(timeIntervalSince1970: 1_800_000_123))
        let data = try export.jsonData()
        return (export, try JSONSerialization.jsonObject(with: data))
    }

    func testExportSchemaVersionAndRoundTrip() throws {
        let (export, object) = try exportJSON()
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, StreamDiagnosticsExport.currentSchemaVersion)
        XCTAssertEqual(root["metricDictionaryVersion"] as? Int, StreamDiagnosticsMetricDictionary.version)
        XCTAssertEqual(root["generatedAt"] as? String, "2027-01-15T08:02:00Z", "rounded down to the minute")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StreamDiagnosticsExport.self, from: try export.jsonData())
        XCTAssertEqual(decoded, export)
        XCTAssertEqual(decoded.sessions.count, 2)
        XCTAssertEqual(decoded.sessions[0].snapshot.context.route, .remote)
    }

    /// Every key in the export, at any depth, must be one of these (or a
    /// metric id / threshold name). A new field fails here until reviewed
    /// for privacy and added deliberately.
    static let allowedKeys: Set<String> = [
        // StreamDiagnosticsExport / build / session
        "schemaVersion", "metricDictionaryVersion", "generatedAt", "build", "sessions", "classifierThresholds",
        "limitations", "appVersion", "osMajor", "osMinor", "osPatch", "platform", "deviceClass", "snapshot", "verdict",
        // snapshot
        "side", "windowSeconds", "windowIsPartial", "stages", "counters", "sessionCounters", "gauges", "rttJitterMs",
        "context", "peer", "resources",
        // stage / gauge summaries
        "id", "count", "ratePerSecond", "p50", "p95", "p99", "max", "mean", "gapsOver100ms", "gapsOver250ms",
        "gapsOver500ms", "last", "samples",
        // context
        "displayMode", "codec", "rasterWidth", "rasterHeight", "targetFPS", "sourceRefreshHz", "encoderInFlightLimit",
        "route", "networkProtocol", "pathExpensive", "pathConstrained", "presentationPath", "clockOffsetKnown",
        // resources
        "processCPUPercent", "memoryFootprintMB", "thermalState", "lowPowerMode", "batteryState", "sampleIntervalSeconds",
        // verdict
        "cause", "confidence", "reason", "evidence", "alternatives", "frameBudgetMs", "metric", "value", "comparison",
        "threshold", "met", "fromPeer",
        // peer summary
        "captureCompleteFPS", "captureIdleShare", "submitFPS", "encodeP95Ms",
        "sendP95Ms", "encoderBusyShare", "sendBackpressureShare", "composeP95Ms", "composeFPS",
        "arrivalFPS", "arrivalP50Ms", "arrivalP95Ms", "arrivalGapsOver250ms", "enqueueFPS", "presenterQueueAgeP95Ms",
        "decodeP95Ms", "decodeSamples", "rttMs",
        // peer summary, Performance Lab frame-ID reader (numbers only)
        "frameIDUniqueFPS", "frameIDDuplicates", "frameIDMissing", "frameIDUnreadable", "frameIDUnexamined",
        "frameIDIntervalP95Ms",
        // window numbering (snapshot and peer summary): a random per-session
        // number and counters, nothing about the device
        "windowSeriesID", "windowSequence", "peerWindowSequenceAtStart",
    ]

    /// Kinds of field that must never appear, even if someone adds them to
    /// the allowlist by mistake.
    static let forbiddenKeyFragments = [
        "title", "name", "path", "file", "ssid", "host", "address", "addr", "ip", "endpoint", "serial", "pair",
        "spki", "key", "token", "secret", "screenshot", "image", "pixel", "input", "text", "url", "user", "bundle",
    ]

    func testExportContainsOnlyAllowedKeysAndValues() throws {
        let (_, object) = try exportJSON()
        let metricIDs = Set(StreamDiagnosticsMetricDictionary.all.map(\.id))
        let thresholdNames = Set(StreamBottleneckClassifier.thresholds.keys)
        var keys: Set<String> = []
        var strings: [String] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict { keys.insert(k); walk(v) }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let s = value as? String {
                strings.append(s)
            }
        }
        walk(object)
        let unexpected = keys.subtracting(Self.allowedKeys).subtracting(metricIDs).subtracting(thresholdNames)
        XCTAssertTrue(unexpected.isEmpty, "unreviewed export keys: \(unexpected.sorted())")
        for key in Self.allowedKeys {
            // "presentationPath" is the display-layer/Metal enum, not a file path.
            guard key != "presentationPath" else { continue }
            for bad in Self.forbiddenKeyFragments where key.lowercased().contains(bad) {
                // Allowed exceptions that are numbers, not identifiers.
                XCTAssertTrue(["pathExpensive", "pathConstrained", "context"].contains(key), "\(key) looks like a \(bad) field")
            }
        }

        // String values: enum raw values, metric ids, thresholds, the fixed
        // limitation sentences, the app version and the date. Nothing else.
        let enumValues: Set<String> = Set(
            ["sender", "receiver", "mirror", "extend", "window", "unknown", "h264", "hevc", "usb", "awdl", "lan", "remote",
             "tcp", "quic", "displayLayer", "metal", "nominal", "fair", "serious", "critical", "unplugged", "charging",
             "full", "none", "low", "medium", "high", "atLeast", "below", "macOS", "iOS", "mac", "iPhone", "iPad"]
            + StreamBottleneckCause.allCases.map(\.rawValue)
            + StreamVerdictReason.allCases.map(\.rawValue))
        let evidenceIDs = metricIDs.union(StreamBottleneckClassifier.derivedIDs).union(metricIDs.map { $0 + ".p50" })
        let fixed = Set(StreamDiagnosticsExport.limitationsText).union(["2.0 (214)", "2027-01-15T08:02:00Z"])
        for s in strings {
            XCTAssertTrue(enumValues.contains(s) || evidenceIDs.contains(s) || fixed.contains(s), "unexpected string in export: \(s)")
        }
    }

    /// B14: adaptive decisions are exported with times from the recorder's
    /// reset, never time since boot, and carry only codes and numbers.
    func testAdaptiveDecisionTimesCountFromTheResetNotFromBoot() throws {
        let json = #"{"atSeconds": 86523.4, "action": "hold", "reason": "insufficientData", "cause": "insufficientData", "changed": [], "evidence": {"badStreak": 0, "healthyStreak": 0}}"#
        let decision = try JSONDecoder().decode(StreamDiagnosticsAdaptiveDecision.self, from: Data(json.utf8))
        let r = StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                          resourceSampler: nil, nowMs: 86_500_000)
        r.recordAdaptiveDecision(decision)
        let recorded = try XCTUnwrap(r.snapshot(at: 86_600_000).adaptiveDecisions?.first)
        XCTAssertEqual(recorded.atSeconds, 23.4, accuracy: 1e-9, "86523.4 s of uptime is 23.4 s after the reset at 86500 s")
        r.reset(at: 86_530_000)
        r.recordAdaptiveDecision(decision)
        XCTAssertEqual(try XCTUnwrap(r.snapshot(at: 86_600_000).adaptiveDecisions?.first).atSeconds, 0, "never negative")
        // The export of a decision holds no string outside the reviewed sets.
        let export = StreamDiagnosticsExport(sessions: [r.snapshot(at: 86_600_000)],
                                             build: StreamDiagnosticsBuildInfo.current(deviceClass: .mac, appVersion: "2.0 (214)"),
                                             now: Date(timeIntervalSince1970: 1_800_000_123))
        let object = try JSONSerialization.jsonObject(with: try export.jsonData())
        var keys: Set<String> = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict { keys.insert(k); walk(v) }
            } else if let array = value as? [Any] { array.forEach(walk) }
        }
        walk(object)
        // Metric ids (counter and stage names) are reviewed dictionary keys.
        let metricIDs = Set(StreamDiagnosticsMetricDictionary.all.map(\.id))
        let thresholdNames = Set(StreamBottleneckClassifier.thresholds.keys)
        // The adaptive decision's fields, reviewed: codes, counts and factors.
        let decisionKeys: Set<String> = [
            "adaptiveDecisions", "atSeconds", "action", "reason", "cause", "changed", "evidence",
            "badStreak", "healthyStreak", "activeSourceIdleShare", "backpressureShare", "captureShortfall",
            "deliveryBudgetFactor", "encodeBudgetFactor", "headroomShare", "idleFPS", "rateShortfall",
        ]
        let unexpected = keys.subtracting(Self.allowedKeys).subtracting(metricIDs).subtracting(thresholdNames).subtracting(decisionKeys)
        XCTAssertTrue(unexpected.isEmpty, "unreviewed export keys: \(unexpected.sorted())")
        for key in keys.subtracting(metricIDs) {
            for bad in Self.forbiddenKeyFragments where key.lowercased().contains(bad) {
                XCTAssertTrue(["pathExpensive", "pathConstrained", "context", "presentationPath"].contains(key), "\(key) looks like a \(bad) field")
            }
        }
    }

    func testVersionStringIsSanitized() {
        XCTAssertEqual(StreamDiagnosticsBuildInfo.sanitizedVersion("2.0 (214)"), "2.0 (214)")
        XCTAssertEqual(StreamDiagnosticsBuildInfo.sanitizedVersion("/Users/me/x@host.local"), "usersmexhost.local")
        XCTAssertEqual(StreamDiagnosticsBuildInfo.sanitizedVersion(""), "unknown")
        XCTAssertLessThanOrEqual(StreamDiagnosticsBuildInfo.sanitizedVersion(String(repeating: "9", count: 200)).count, 32)
    }

    func testExportWritesOneLocalFileWithAContentFreeName() throws {
        let (export, _) = try exportJSON()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try export.write(to: dir)
        XCTAssertEqual(url.lastPathComponent, "meowdisplay-stream-diagnostics-20270115-0802.json")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }
}
