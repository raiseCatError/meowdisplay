// Performance Lab (#123): scenarios and runs, pure and Codable.
//
// A scenario says what to stream (mode, panes, fixture workload), how long
// to warm up, how many whole diagnostics windows one trial measures, what
// the operator must set up or do by hand, and which metrics are primary. A
// run is one scenario repeated over N trials (at least three) plus the
// environment, all from the redacted diagnostics types: nothing personal.
//
// Every string in here is a constant in code. The run bundle never holds a
// device name, window title, address or user-entered text other than the
// sanitized variant label.

import Foundation

enum PerformanceLabMode: String, Codable, CaseIterable, Sendable {
    case mirror, extend, window
}

enum PerformanceLabPaneLayout: String, Codable, CaseIterable, Sendable {
    /// Mirror or Extend: no panes.
    case none
    case single
    case multiple
    case floating
}

/// When an operator step is shown.
enum PerformanceLabStepTiming: String, Codable, Sendable {
    /// Once, before the first trial; the run waits for "Ready".
    case beforeRun
    /// Before every trial; the run waits for "Ready".
    case beforeEachTrial
    /// Shown at `atSecond` into the measured part of a trial; the run does
    /// not wait (the operator acts while it measures).
    case duringTrial
}

struct PerformanceLabOperatorStep: Codable, Equatable, Sendable {
    var timing: PerformanceLabStepTiming
    var atSecond: Double?
    var instruction: String
}

/// Per-trial numbers the analysis tool computes (`tools/perf-lab`). The raw
/// values are the tool's metric keys; `tools/perf-lab/scenarios.json`
/// carries this list so both sides are checked against each other.
enum PerformanceLabAnalysisMetric: String, Codable, CaseIterable, Sendable {
    case sourceUniqueFPS = "source_unique_fps"
    case captureCompleteFPS = "capture_complete_fps"
    case submittedFPS = "submitted_fps"
    case encodedFPS = "encoded_fps"
    case sentFPS = "sent_fps"
    case duplicateSubmitFPS = "duplicate_submit_fps"
    case captureIntervalP95 = "capture_interval_p95_ms"
    case submitIntervalP50 = "submit_interval_p50_ms"
    case submitIntervalP95 = "submit_interval_p95_ms"
    case submitIntervalP99 = "submit_interval_p99_ms"
    case submitGapsOver100 = "submit_gaps_over_100ms"
    case submitGapsOver250 = "submit_gaps_over_250ms"
    case submitGapsOver500 = "submit_gaps_over_500ms"
    case sourceAgeP95 = "source_age_p95_ms"
    case encodeP50 = "encode_p50_ms"
    case encodeP95 = "encode_p95_ms"
    case encodeP99 = "encode_p99_ms"
    case sendP95 = "send_p95_ms"
    case encoderBusyHolds = "encoder_busy_holds"
    case sendBackpressureDrops = "send_backpressure_drops"
    case payloadMbps = "payload_mbps"
    case composeP95 = "compose_p95_ms"
    case compositesFPS = "composites_fps"
    case receiverArrivalFPS = "receiver_arrival_fps"
    case receiverArrivalP95 = "receiver_arrival_p95_ms"
    case receiverGapsOver250 = "receiver_gaps_over_250ms"
    case receiverEnqueueFPS = "receiver_enqueue_fps"
    case presenterQueueAgeP95 = "presenter_queue_age_p95_ms"
    case frameIDUniqueFPS = "frame_id_unique_fps"
    case frameIDSkipped = "frame_id_skipped"
    case frameIDDuplicates = "frame_id_duplicates"
    case frameIDUnreadable = "frame_id_unreadable"
    case frameIDUnexamined = "frame_id_unexamined"
    case frameIDIntervalP95 = "frame_id_interval_p95_ms"
    case fixtureDrawnFPS = "fixture_drawn_fps"
    case senderCPUPercentMedian = "sender_cpu_percent_median"
    case senderMemoryMBMax = "sender_memory_mb_max"
    case senderMemoryMBDelta = "sender_memory_mb_delta"
    case generationResets = "generation_resets"
    case restartFrameGapMax = "restart_frame_gap_max_ms"
    case routeChanges = "route_changes"
}

struct PerformanceLabScenario: Codable, Equatable, Sendable, Identifiable {
    var id: String
    /// Bump when the procedure or durations change.
    var version: Int
    var caption: String
    var purpose: String
    var mode: PerformanceLabMode
    var panes: PerformanceLabPaneLayout
    var workload: PerformanceLabWorkloadID
    var warmUpSeconds: Double
    /// Whole diagnostics windows (5 s each) one trial measures.
    var trialWindows: Int
    var primaryMetrics: [PerformanceLabAnalysisMetric]
    var steps: [PerformanceLabOperatorStep]
    /// A capture/presentation restart is part of the procedure (reconnect,
    /// retune, transitions): not a reason to mark the trial incomplete.
    var expectsRestarts: Bool

    var measuredSeconds: Double { Double(trialWindows) * PerformanceLabScenarioCatalog.windowSeconds }

    func steps(_ timing: PerformanceLabStepTiming) -> [PerformanceLabOperatorStep] {
        steps.filter { $0.timing == timing }
    }
}

enum PerformanceLabScenarioCatalog {
    /// The diagnostics recorder's window length (StreamDiagnosticsRecorder default).
    static let windowSeconds = 5.0
    /// Bump when a scenario is added, removed or changed.
    static let version = 1

    private static let enableDiagnostics = PerformanceLabOperatorStep(
        timing: .beforeRun, atSecond: nil,
        instruction: "Turn on Streaming Diagnostics on this Mac and on the receiving device (iPhone/iPad: Settings > Diagnostics > Streaming Diagnostics).")
    private static let recordConditions = PerformanceLabOperatorStep(
        timing: .beforeRun, atSecond: nil,
        instruction: "Write down the conditions the app cannot see: sender power source and display refresh, receiver model and OS, network, other running apps. Keep them the same for every trial.")
    private static let openFixture = PerformanceLabOperatorStep(
        timing: .beforeRun, atSecond: nil,
        instruction: "Click Open Fixture Window and move the fixture onto the streamed display. Make it fill that display (Zoom), unless the scenario says otherwise.")
    private static let metalForFrameIDs = PerformanceLabOperatorStep(
        timing: .beforeRun, atSecond: nil,
        instruction: "Optional, for exact frame-ID counts: turn on the experimental Metal renderer on the receiver. It changes presentation timing, so record it and use the same setting for every run you compare.")
    private static let handsOff = PerformanceLabOperatorStep(
        timing: .beforeEachTrial, atSecond: nil,
        instruction: "Keep hands off both devices while the trial measures.")

    private static func common(_ extra: [PerformanceLabOperatorStep], handsOffTrial: Bool = true) -> [PerformanceLabOperatorStep] {
        [enableDiagnostics, recordConditions, openFixture, metalForFrameIDs] + extra + (handsOffTrial ? [handsOff] : [])
    }

    private static let pacing: [PerformanceLabAnalysisMetric] = [
        .sourceUniqueFPS, .submitIntervalP95, .submitIntervalP99, .submitGapsOver250,
        .receiverArrivalFPS, .receiverArrivalP95, .receiverGapsOver250, .frameIDUniqueFPS, .frameIDSkipped,
    ]
    private static let pipeline: [PerformanceLabAnalysisMetric] = [
        .encodeP95, .sendP95, .sourceAgeP95, .payloadMbps, .encoderBusyHolds, .sendBackpressureDrops,
    ]

    static let all: [PerformanceLabScenario] = [
        .init(id: "mirror.frame-counter", version: 1, caption: "Mirror, frame counter",
              purpose: "Source-unique frame rate and pacing when every display refresh changes the screen (Mirror).",
              mode: .mirror, panes: .none, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: pacing + pipeline,
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start a Mirror session to the receiving device.")]),
              expectsRestarts: false),
        .init(id: "extend.frame-counter", version: 1, caption: "Extend, frame counter",
              purpose: "Source-unique frame rate and pacing on the virtual display (Extend).",
              mode: .extend, panes: .none, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: pacing + pipeline,
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session and put the fixture on the extended display.")]),
              expectsRestarts: false),
        .init(id: "window.single-pane", version: 1, caption: "Window View, one pane",
              purpose: "Composition and pacing with the fixture as the only Window View pane.",
              mode: .window, panes: .single, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.compositesFPS, .composeP95] + pacing + [.encodeP95, .payloadMbps],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start Window View and add only the fixture window as a pane; maximise that pane on the receiver.")]),
              expectsRestarts: false),
        .init(id: "window.multiple-panes", version: 1, caption: "Window View, four panes",
              purpose: "Composition cost and pacing with the fixture plus three static panes.",
              mode: .window, panes: .multiple, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.compositesFPS, .composeP95] + pacing + [.encodeP95, .payloadMbps],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start Window View with the fixture and three other windows that stay still (for example empty Finder windows): four panes in all. Use the same windows for every run.")]),
              expectsRestarts: false),
        .init(id: "window.floating-pane", version: 1, caption: "Window View, floating pane",
              purpose: "Composition with the fixture as a floating pane partly covering a still pane.",
              mode: .window, panes: .floating, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.compositesFPS, .composeP95] + pacing,
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start Window View with one still window as a pane and float the fixture over about half of it.")]),
              expectsRestarts: false),
        .init(id: "mirror.static-to-motion", version: 1, caption: "Mirror, still to motion",
              purpose: "How quickly frames resume after a still screen: 4 s still, 4 s full motion, repeating.",
              mode: .mirror, panes: .none, workload: .staticToMotion, warmUpSeconds: 10, trialWindows: 8,
              primaryMetrics: [.sourceUniqueFPS, .submitGapsOver250, .submitGapsOver500, .receiverGapsOver250,
                               .frameIDUniqueFPS, .frameIDSkipped, .sourceAgeP95, .encodeP95],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start a Mirror session to the receiving device.")]),
              expectsRestarts: false),
        .init(id: "extend.scrolling-text", version: 1, caption: "Extend, scrolling fine text",
              purpose: "Pacing and payload for scrolling text; judge text clarity separately and label it subjective.",
              mode: .extend, panes: .none, workload: .scrollingText, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.sourceUniqueFPS, .submitIntervalP95, .receiverArrivalP95, .frameIDSkipped, .payloadMbps, .encodeP95],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session and put the fixture on the extended display."),
                             .init(timing: .duringTrial, atSecond: 15, instruction: "Note (do not touch): is the scrolling text readable on the receiver? Record it as a subjective observation.")]),
              expectsRestarts: false),
        .init(id: "mirror.high-motion", version: 1, caption: "Mirror, high motion",
              purpose: "Encoder and network load when every pixel changes every frame.",
              mode: .mirror, panes: .none, workload: .highMotion, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: pipeline + [.sourceUniqueFPS, .receiverArrivalFPS, .frameIDUniqueFPS, .frameIDSkipped],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start a Mirror session to the receiving device.")]),
              expectsRestarts: false),
        .init(id: "extend.rapid-interaction", version: 1, caption: "Extend, rapid interaction",
              purpose: "Pacing while the operator scrolls and drags on the receiver over the moving target. Human-driven: compare only runs by the same operator.",
              mode: .extend, panes: .none, workload: .cursorTarget, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.sourceUniqueFPS, .submitIntervalP95, .receiverArrivalP95, .receiverGapsOver250, .frameIDSkipped],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session with input control allowed, and put the fixture on the extended display."),
                             .init(timing: .duringTrial, atSecond: 0, instruction: "Now: on the receiver, follow the moving target with your finger or pointer, dragging and scrolling, until the trial ends.")],
                            handsOffTrial: false),
              expectsRestarts: false),
        .init(id: "extend.reconnection", version: 1, caption: "Extend, reconnection",
              purpose: "Recovery after a connection loss the operator causes on purpose, measured as frame gaps and restarts.",
              mode: .extend, panes: .none, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 8,
              primaryMetrics: [.generationResets, .restartFrameGapMax, .routeChanges, .submitGapsOver500, .receiverGapsOver250, .frameIDSkipped, .sourceUniqueFPS],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session over the route you are testing. Use only a disconnection you can undo safely (for example unplugging USB, or turning Wi-Fi off on the receiver); never a paid or unattended cellular path."),
                             .init(timing: .duringTrial, atSecond: 10, instruction: "Now: disconnect the route the same way as in every trial."),
                             .init(timing: .duringTrial, atSecond: 15, instruction: "Now: reconnect it.")],
                            handsOffTrial: false),
              expectsRestarts: true),
        .init(id: "extend.capture-retune", version: 1, caption: "Extend, capture retuning",
              purpose: "Cost of a capture restart: the operator changes the frame-rate cap mid-trial and back.",
              mode: .extend, panes: .none, workload: .frameCounter, warmUpSeconds: 10, trialWindows: 8,
              primaryMetrics: [.generationResets, .restartFrameGapMax, .submitGapsOver250, .submitGapsOver500, .frameIDSkipped, .sourceUniqueFPS],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session at the frame-rate cap you are testing."),
                             .init(timing: .duringTrial, atSecond: 10, instruction: "Now: change the frame-rate cap to another value."),
                             .init(timing: .duringTrial, atSecond: 25, instruction: "Now: change it back.")],
                            handsOffTrial: false),
              expectsRestarts: true),
        .init(id: "extend.transition-cleanup", version: 1, caption: "Repeated mode transitions",
              purpose: "Resource cleanup across repeated Mirror/Extend switches: memory and CPU after the transitions settle.",
              mode: .extend, panes: .none, workload: .idle, warmUpSeconds: 10, trialWindows: 12,
              primaryMetrics: [.senderMemoryMBMax, .senderMemoryMBDelta, .senderCPUPercentMedian, .generationResets],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session."),
                             .init(timing: .duringTrial, atSecond: 5, instruction: "Now: switch to Mirror and back to Extend five times, waiting for the picture each time, then leave it in Extend.")],
                            handsOffTrial: false),
              expectsRestarts: true),
        .init(id: "extend.sustained", version: 1, caption: "Extend, sustained 10 minutes",
              purpose: "Long-run stability, not peak: frame rate, gaps, CPU, memory and thermal state over 10 minutes.",
              mode: .extend, panes: .none, workload: .highMotion, warmUpSeconds: 30, trialWindows: 120,
              primaryMetrics: [.sourceUniqueFPS, .receiverArrivalFPS, .submitGapsOver250, .receiverGapsOver250,
                               .senderCPUPercentMedian, .senderMemoryMBMax, .senderMemoryMBDelta, .payloadMbps],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session. Note the power source and starting thermal state; keep the room and the devices' placement the same for every trial.")]),
              expectsRestarts: false),
        .init(id: "extend.idle", version: 1, caption: "Extend, idle screen",
              purpose: "What a still screen costs: should be close to no new frames, only the periodic resend.",
              mode: .extend, panes: .none, workload: .idle, warmUpSeconds: 10, trialWindows: 6,
              primaryMetrics: [.sourceUniqueFPS, .submittedFPS, .payloadMbps, .senderCPUPercentMedian],
              steps: common([.init(timing: .beforeRun, atSecond: nil, instruction: "Start an Extend session; move the pointer off the extended display.")]),
              expectsRestarts: false),
    ]

    /// Used only by the software self-test: short, so its golden files stay small.
    static let synthetic = PerformanceLabScenario(
        id: "synthetic.self-test", version: 1, caption: "SYNTHETIC self-test",
        purpose: "SYNTHETIC: a scripted event stream through the real recorder and run controller. It validates the harness, not performance.",
        mode: .extend, panes: .none, workload: .frameCounter, warmUpSeconds: 5, trialWindows: 3,
        primaryMetrics: [.sourceUniqueFPS, .submitIntervalP95, .encodeP95, .payloadMbps, .receiverArrivalFPS, .frameIDUniqueFPS, .frameIDSkipped],
        steps: [.init(timing: .beforeRun, atSecond: nil, instruction: "SYNTHETIC: nothing to set up."),
                .init(timing: .duringTrial, atSecond: 11, instruction: "SYNTHETIC: a scripted 300 ms stall happens in trial 3.")],
        expectsRestarts: false)

    static func scenario(id: String) -> PerformanceLabScenario? {
        if id == synthetic.id { return synthetic }
        return all.first { $0.id == id }
    }
}

// MARK: - Run plan

struct PerformanceLabRunPlan: Codable, Equatable, Sendable {
    static let minimumTrials = 3
    static let defaultTrials = 3
    static let maximumTrials = 20

    var scenario: PerformanceLabScenario
    var trials: Int
    var synthetic: Bool
    /// Optional label for comparisons ("beta-on", "build-b"): lowercase
    /// letters, digits and dashes only, at most 24 characters.
    var variant: String?

    enum ValidationError: Error, Equatable {
        case unknownScenario
        case tooFewTrials(minimum: Int)
        case tooManyTrials(maximum: Int)
    }

    static func make(scenarioID: String, trials: Int = defaultTrials, synthetic: Bool = false,
                     variant: String? = nil) throws -> PerformanceLabRunPlan {
        guard let scenario = PerformanceLabScenarioCatalog.scenario(id: scenarioID) else { throw ValidationError.unknownScenario }
        guard trials >= minimumTrials else { throw ValidationError.tooFewTrials(minimum: minimumTrials) }
        guard trials <= maximumTrials else { throw ValidationError.tooManyTrials(maximum: maximumTrials) }
        return PerformanceLabRunPlan(scenario: scenario, trials: trials, synthetic: synthetic || scenario.id == PerformanceLabScenarioCatalog.synthetic.id,
                                     variant: variant.flatMap(sanitizedVariant))
    }

    static func sanitizedVariant(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let s = String(raw.lowercased().unicodeScalars.filter { allowed.contains($0) }.prefix(24))
        return s.isEmpty ? nil : s
    }

    /// Hex digits only, at most 40 (a git commit); nil otherwise.
    static func sanitizedCommit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 7, s.count <= 40, s.unicodeScalars.allSatisfy({ hex.contains($0) }) else { return nil }
        return s
    }
}
