// Streaming diagnostics (#123): what the developer view shows, as pure
// formatting functions (tested in MacTests), plus a thin SwiftUI panel used
// by the Mac Settings and the iOS receiver Settings. Developer-facing and
// English-only, like the connection log.

import Foundation
import SwiftUI

struct StreamDiagnosticsRow: Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var count: String
    var rate: String
    var p50: String
    var p95: String
    var p99: String
    var max: String
    var note: String?
}

enum StreamDiagnosticsPresentation {
    /// Honest names: "enqueued for presentation", never "presented"; the
    /// overlay's "encode"/"latency" labels are spelled out.
    static func label(for stage: DiagnosticsStage) -> String {
        switch stage {
        case .captureInterval: return "Capture, complete frames (interval)"
        case .sourceAgeAtSubmit: return "Source age at encoder submit"
        case .encode: return "Encode (submit to output)"
        case .submitInterval: return "Encoder submissions (interval)"
        case .send: return "Send (handed to transport to completion)"
        case .compose: return "Window view compose"
        case .composeInterval: return "Window view composites (interval)"
        case .arrivalInterval: return "Frame arrivals (interval)"
        case .wireSubmitToSend: return "Submit to send, sender clock (overlay \"encode\")"
        case .mappedSubmitToReceive: return "Submit to receive, mapped clock (overlay \"latency\")"
        case .decode: return "Decode (Metal path only)"
        case .presenterQueueAge: return "Presenter command queue age"
        case .presentationEnqueueInterval: return "Enqueued for presentation (interval)"
        case .observedSubmitToGlass: return "Submit to glass, observed (Metal path only)"
        case .rtt: return "Control round trip"
        case .frameIDUniqueInterval: return "Lab fixture, new frame IDs (interval, Metal path only)"
        }
    }

    static func ms(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// Stages measured on `snapshot.side` that saw at least one sample.
    static func rows(for snapshot: StreamDiagnosticsSnapshot) -> [StreamDiagnosticsRow] {
        DiagnosticsStage.allCases.compactMap { stage in
            guard stage.definition.side == snapshot.side, let s = snapshot.stage(stage), s.count > 0 else { return nil }
            var note: String?
            if stage.isInterval, let g100 = s.gapsOver100ms, let g250 = s.gapsOver250ms, let g500 = s.gapsOver500ms,
               g100 + g250 + g500 > 0 {
                note = "gaps >100/250/500 ms: \(g100)/\(g250)/\(g500)"
            }
            return StreamDiagnosticsRow(
                id: s.id, label: label(for: stage), count: "\(s.count)",
                rate: String(format: "%.1f/s", s.ratePerSecond),
                p50: ms(s.p50), p95: ms(s.p95), p99: ms(s.p99), max: ms(s.max), note: note)
        }
    }

    static func title(for cause: StreamBottleneckCause) -> String {
        switch cause {
        case .senderCaptureLimited: return "Mac capture is delivering fewer frames than expected"
        case .sourceRefreshLimited: return "Source only updates at its display refresh"
        case .windowCompositionLimited: return "Window view composition is the bottleneck"
        case .encoderOverloaded: return "Mac encoder queue saturated"
        case .networkDeliveryLimited: return "Network delivery or send backpressure"
        case .receiverDecoderOverloaded: return "Receiver decode time high"
        case .presentationSchedulingLimited: return "Presentation queue age growing"
        case .noBottleneckEvident: return "No bottleneck evident"
        case .unknownInsufficientData: return "Unclassified: not enough data"
        }
    }

    static func reasonText(_ reason: StreamVerdictReason) -> String {
        switch reason {
        case .windowTooShort: return "The measurement window is shorter than \(Int(StreamBottleneckClassifier.minimumWindowSeconds)) s."
        case .noTargetFrameRate: return "No target frame rate is known here. Turn diagnostics on on the Mac as well."
        case .tooFewSamples: return "Fewer than \(StreamBottleneckClassifier.minimumSamples) samples in the window."
        case .sourceIdle: return "The source is idle: nothing changed on screen, so there is no cadence to judge."
        case .conflictingEvidence: return "More than one cause has equally strong evidence."
        }
    }

    static func evidenceLine(_ e: StreamVerdictEvidence) -> String {
        let name = e.metric
        let op = e.comparison == .atLeast ? ">=" : "<"
        let mark = e.met ? "met" : "not met"
        return "\(name) = \(ms(e.value)) (\(op) \(ms(e.threshold)): \(mark))\(e.fromPeer ? " [peer]" : "")"
    }

    static func verdictLines(_ v: StreamDiagnosticsVerdict) -> [String] {
        var lines = ["\(title(for: v.cause)) — confidence \(v.confidence.rawValue)"]
        if let reason = v.reason { lines.append(reasonText(reason)) }
        if let budget = v.frameBudgetMs { lines.append("Frame budget \(ms(budget)) ms") }
        lines += v.evidence.map(evidenceLine)
        if !v.alternatives.isEmpty {
            lines.append("Also qualified: " + v.alternatives.map(\.rawValue).joined(separator: ", "))
        }
        return lines
    }

    /// Frame accounting in the window: unique vs duplicates vs held vs enqueued.
    static func accountingLines(_ s: StreamDiagnosticsSnapshot) -> [String] {
        func n(_ c: DiagnosticsCounter) -> Int64 { s.count(c) }
        switch s.side {
        case .sender:
            var lines = [
                "Capture: complete \(n(.captureComplete)), idle \(n(.captureIdle)), other \(n(.captureOtherStatus))",
                "Admission: admitted \(n(.admittedLive)), held by rate limit \(n(.heldByRateLimit)), encoder busy \(n(.heldEncoderBusy)), send backpressure \(n(.droppedPendingSends)), held released \(n(.heldRetryFired))",
                "Submitted: source-unique \(n(.submitSourceUnique)), duplicate \(n(.submitDuplicate)), unknown \(n(.submitUniquenessUnknown)); replays \(n(.submitDropReplay) + n(.submitReconnectReplay))",
                "Encoded \(n(.encodeCompleted)) (stale \(n(.encodeStaleDiscarded)), failed \(n(.encodeFailed)), keyframes \(n(.keyframes))); sent \(n(.sendCompleted)), \(String(format: "%.2f", Double(n(.sentBytes)) * 8 / max(s.windowSeconds, 0.001) / 1_000_000)) Mbit/s payload",
            ]
            if n(.composeFrames) > 0 {
                lines.append("Window view: composites \(n(.composeFrames)), static resends \(n(.composeStaticResends))")
            }
            return lines
        case .receiver:
            return [
                "Arrived \(n(.arrivedFrames)), \(String(format: "%.2f", Double(n(.arrivedBytes)) * 8 / max(s.windowSeconds, 0.001) / 1_000_000)) Mbit/s payload",
                "Enqueued for presentation \(n(.enqueuedForPresentation)), stale discarded \(n(.presenterStaleDiscarded)), layer flushes \(n(.displayLayerFlushes))",
                "Observed presentations (Metal only) \(n(.observedPresentations))",
            ]
        }
    }

    static func resourceLine(_ r: StreamDiagnosticsResourceSample?) -> String? {
        guard let r else { return nil }
        var parts: [String] = []
        if let cpu = r.processCPUPercent { parts.append(String(format: "CPU %.0f%% of a core", cpu)) }
        if let mem = r.memoryFootprintMB { parts.append(String(format: "memory %.0f MB", mem)) }
        parts.append("thermal \(r.thermalState.rawValue)")
        if r.lowPowerMode { parts.append("Low Power Mode") }
        if let b = r.batteryState { parts.append("battery \(b.rawValue)") }
        return parts.joined(separator: ", ")
    }

    static func windowLine(_ s: StreamDiagnosticsSnapshot) -> String {
        String(format: "Last %.1f s%@", s.windowSeconds, s.windowIsPartial ? " (partial window)" : "")
    }
}

/// The compact stage table, verdict and accounting for one snapshot.
struct StreamDiagnosticsPanel: View {
    let snapshot: StreamDiagnosticsSnapshot

    var body: some View {
        let verdict = StreamBottleneckClassifier.classify(snapshot)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: StreamDiagnosticsPresentation.windowLine(snapshot))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(StreamDiagnosticsPresentation.verdictLines(verdict).enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(index == 0 ? .callout.weight(.semibold) : .caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(verbatim: "stage · count · rate · p50 / p95 / p99 / max ms")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(StreamDiagnosticsPresentation.rows(for: snapshot)) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.label).font(.caption)
                    Text(verbatim: "\(row.count) · \(row.rate) · \(row.p50) / \(row.p95) / \(row.p99) / \(row.max)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let note = row.note {
                        Text(verbatim: note).font(.caption2.monospaced()).foregroundStyle(.orange)
                    }
                }
            }
            Divider()
            ForEach(Array(StreamDiagnosticsPresentation.accountingLines(snapshot).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
            }
            if let resources = StreamDiagnosticsPresentation.resourceLine(snapshot.resources) {
                Text(verbatim: resources).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}
