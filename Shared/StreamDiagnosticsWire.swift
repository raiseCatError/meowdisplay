// Streaming diagnostics (#123): the optional `diag` object on existing
// messages (PROTOCOL.md "Streaming diagnostics summary").
//
// The sender adds it to its `ping`, the receiver to its `stats`, only while
// diagnostics are on at that end. Old peers ignore the unknown key; absence
// means "no diagnostics", never a behaviour change. Values are aggregates
// only: numbers, no names, addresses or content. Read values are clamped:
// an authenticated peer is still not trusted to send sane numbers.

import Foundation

/// What one end reports about its own last diagnostics window.
struct StreamDiagnosticsPeerSummary: Codable, Equatable, Sendable {
    static let wireKey = "diag"
    static let wireVersion = 1

    var side: StreamDiagnosticsSide
    // Both: which completed window this is (absent while it is partial)
    var windowSequence: Double?
    // Sender-reported
    var targetFPS: Double?
    var captureCompleteFPS: Double?
    var captureIdleShare: Double?
    var sourceRefreshHz: Double?
    var submitFPS: Double?
    var encodeP95Ms: Double?
    var sendP95Ms: Double?
    var encoderBusyShare: Double?
    var sendBackpressureShare: Double?
    var composeP95Ms: Double?
    var composeFPS: Double?
    // Receiver-reported: the window's series (recorder session) and the
    // sender's window sequence the receiver had when this window began
    var windowSeriesID: Double?
    var peerWindowSequenceAtStart: Double?
    // Receiver-reported
    var arrivalFPS: Double?
    var arrivalP50Ms: Double?
    var arrivalP95Ms: Double?
    var arrivalGapsOver250ms: Double?
    var enqueueFPS: Double?
    var presenterQueueAgeP95Ms: Double?
    var decodeP95Ms: Double?
    var decodeSamples: Double?
    var rttMs: Double?
    var rttJitterMs: Double?
    // Receiver-reported, Performance Lab frame-ID reader (only while it
    // followed or searched for a strip; unique/duplicate/missing/interval
    // only when it read one)
    var frameIDUniqueFPS: Double?
    var frameIDDuplicates: Double?
    var frameIDMissing: Double?
    var frameIDUnreadable: Double?
    var frameIDUnexamined: Double?
    var frameIDIntervalP95Ms: Double?

    init(side: StreamDiagnosticsSide) {
        self.side = side
    }

    // Computed: key paths are not Sendable, so no stored static table.
    // Built once per message (every 2-5 s), never per frame.
    private static var senderKeys: [(String, WritableKeyPath<StreamDiagnosticsPeerSummary, Double?>)] { [
        ("wseq", \.windowSequence),
        ("tgt", \.targetFPS), ("capU", \.captureCompleteFPS), ("idle", \.captureIdleShare),
        ("hz", \.sourceRefreshHz), ("sub", \.submitFPS), ("enc95", \.encodeP95Ms),
        ("snd95", \.sendP95Ms), ("busy", \.encoderBusyShare), ("bp", \.sendBackpressureShare),
        ("cmp95", \.composeP95Ms), ("cmpFps", \.composeFPS),
    ] }
    private static var receiverKeys: [(String, WritableKeyPath<StreamDiagnosticsPeerSummary, Double?>)] { [
        ("wid", \.windowSeriesID), ("wseq", \.windowSequence), ("wps", \.peerWindowSequenceAtStart),
        ("arrFps", \.arrivalFPS), ("arr50", \.arrivalP50Ms), ("arr95", \.arrivalP95Ms),
        ("gap250", \.arrivalGapsOver250ms), ("enqFps", \.enqueueFPS), ("qAge95", \.presenterQueueAgeP95Ms),
        ("dec95", \.decodeP95Ms), ("decN", \.decodeSamples),
        ("rtt", \.rttMs), ("jit", \.rttJitterMs),
        ("fidU", \.frameIDUniqueFPS), ("fidDup", \.frameIDDuplicates), ("fidSkip", \.frameIDMissing),
        ("fidBad", \.frameIDUnreadable), ("fidUnx", \.frameIDUnexamined), ("fid95", \.frameIDIntervalP95Ms),
    ] }

    /// Largest value accepted from the wire for any field.
    static let wireValueCeiling = 1_000_000.0

    /// The wire object: `{"v":1, ...}` with values rounded to 0.1. Each
    /// value is clamped to ±`wireValueCeiling` BEFORE it is scaled, so a
    /// huge local value can never become infinity (JSONSerialization raises
    /// an Objective-C exception on one, which would crash the app).
    var wireFields: [String: Any] {
        var out: [String: Any] = ["v": Self.wireVersion]
        for (key, path) in side == .sender ? Self.senderKeys : Self.receiverKeys {
            if let value = self[keyPath: path], let rounded = PeerNumber.roundedTenths(value, limit: Self.wireValueCeiling) {
                out[key] = rounded
            }
        }
        return out
    }

    /// A JSON fragment for the sender's hand-built ping string.
    var wireJSON: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: wireFields, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses the `diag` object a peer on `side` sent; nil when absent,
    /// malformed or of an unknown version.
    static func fromWire(_ object: Any?, side: StreamDiagnosticsSide) -> StreamDiagnosticsPeerSummary? {
        guard let dict = object as? [String: Any],
              PeerNumber.int(dict["v"], in: 0...1_000_000) == wireVersion else { return nil }
        var summary = StreamDiagnosticsPeerSummary(side: side)
        var any = false
        for (key, path) in side == .sender ? senderKeys : receiverKeys {
            // Finite non-bool numbers only; clamped, never converted to Int.
            guard let value = PeerNumber.double(dict[key]) else { continue }
            summary[keyPath: path] = Swift.min(Swift.max(value, 0), wireValueCeiling)
            any = true
        }
        return any ? summary : nil
    }

    /// Builds what this end reports from its own snapshot.
    static func from(_ snapshot: StreamDiagnosticsSnapshot) -> StreamDiagnosticsPeerSummary {
        var s = StreamDiagnosticsPeerSummary(side: snapshot.side)
        s.windowSequence = snapshot.windowSequence.map { Double(Swift.min($0, UInt64(wireValueCeiling))) }
        func p(_ stage: DiagnosticsStage, _ q: KeyPath<StreamDiagnosticsStageSummary, Double>) -> Double? {
            guard let st = snapshot.stage(stage), st.count > 0 else { return nil }
            return st[keyPath: q]
        }
        switch snapshot.side {
        case .sender:
            // Shares are of frames the rate limiter admitted: backpressure
            // is checked only after admission.
            let offered = Double(snapshot.count(.admittedLive))
            let callbacks = Double(snapshot.count(.captureComplete) + snapshot.count(.captureIdle) + snapshot.count(.captureOtherStatus))
            s.targetFPS = snapshot.context.targetFPS > 0 ? Double(snapshot.context.targetFPS) : nil
            // Capture keys only when there was display capture (none in Window view).
            s.captureCompleteFPS = callbacks > 0 ? snapshot.rate(.captureComplete) : nil
            s.captureIdleShare = callbacks > 0 ? Double(snapshot.count(.captureIdle)) / callbacks : nil
            s.sourceRefreshHz = snapshot.context.sourceRefreshHz
            s.submitFPS = snapshot.stage(.submitInterval)?.ratePerSecond
            s.encodeP95Ms = p(.encode, \.p95)
            s.sendP95Ms = p(.send, \.p95)
            s.encoderBusyShare = offered > 0 ? Double(snapshot.count(.heldEncoderBusy)) / offered : nil
            s.sendBackpressureShare = offered > 0 ? Double(snapshot.count(.droppedPendingSends)) / offered : nil
            s.composeP95Ms = p(.compose, \.p95)
            s.composeFPS = snapshot.count(.composeFrames) > 0 ? snapshot.rate(.composeFrames) : nil
        case .receiver:
            s.windowSeriesID = snapshot.windowSeriesID.map { Double($0) }
            s.peerWindowSequenceAtStart = snapshot.peerWindowSequenceAtStart.map { Double(Swift.min($0, UInt64(wireValueCeiling))) }
            s.arrivalFPS = snapshot.rate(.arrivedFrames)
            s.arrivalP50Ms = p(.arrivalInterval, \.p50)
            s.arrivalP95Ms = p(.arrivalInterval, \.p95)
            s.arrivalGapsOver250ms = snapshot.stage(.arrivalInterval)?.gapsOver250ms.map(Double.init)
            s.enqueueFPS = snapshot.rate(.enqueuedForPresentation)
            s.presenterQueueAgeP95Ms = p(.presenterQueueAge, \.p95)
            s.decodeP95Ms = p(.decode, \.p95)
            s.decodeSamples = snapshot.stage(.decode).map { Double($0.count) }
            s.rttMs = p(.rtt, \.p50)
            s.rttJitterMs = snapshot.rttJitterMs
            // Performance Lab: only when the frame-ID reader saw the fixture.
            // Unique, duplicate and missing need a read strip: without one
            // they are "not measured" (absent), never 0.
            let read = snapshot.count(.frameIDRead)
            let unreadable = snapshot.count(.frameIDUnreadable)
            let unexamined = snapshot.count(.frameIDUnexamined)
            if read > 0 {
                s.frameIDUniqueFPS = snapshot.rate(.frameIDUnique)
                s.frameIDDuplicates = Double(snapshot.count(.frameIDDuplicate))
                s.frameIDMissing = Double(snapshot.count(.frameIDSkipped))
                s.frameIDIntervalP95Ms = p(.frameIDUniqueInterval, \.p95)
            }
            if read > 0 || unreadable > 0 || unexamined > 0 {
                s.frameIDUnreadable = Double(unreadable)
                s.frameIDUnexamined = Double(unexamined)
            }
        }
        return s
    }
}
