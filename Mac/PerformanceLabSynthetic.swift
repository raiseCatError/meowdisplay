// Performance Lab (#123): the software-only self-test.
//
// SYNTHETIC. A fixed, scripted event stream (60 FPS, deterministic
// durations and sizes, one scripted 300 ms stall in trial 3, scripted
// receiver summaries: 5 s receiver windows sent every 2 s, so each window is
// reported two or three times with a changing jitter, the way a receiver
// does under adaptive streaming) is fed through the real StreamDiagnosticsRecorder and
// the real PerformanceLabRunController on an injected clock, and written as
// a real run bundle. It exercises the harness end to end without a device,
// capture, encoder or network. It measures nothing: every output says
// SYNTHETIC, and the numbers are the script's.
//
// The bundle it writes is checked byte for byte against
// tools/perf-lab/tests/golden/synthetic-run (PerformanceLabSyntheticTests),
// and the analysis tool's report of that bundle against
// tools/perf-lab/tests/golden/synthetic-report.md (tools/perf-lab tests).

import Foundation

@MainActor
enum PerformanceLabSyntheticRun {
    /// 2026-11-17T00:00:00Z: fixed so the bundle is reproducible.
    static let createdAt = Date(timeIntervalSince1970: 1_794_873_600)
    static let build = StreamDiagnosticsBuildInfo(appVersion: "synthetic", osMajor: 0, osMinor: 0, osPatch: 0,
                                                  platform: .macOS, deviceClass: .mac)
    static let frameMs = 1000.0 / 60
    static let startMs = 1_000_000.0

    /// Runs the synthetic scenario, writes its bundle under `parent` and
    /// returns the bundle folder.
    static func run(under parent: URL) throws -> URL {
        let diagnosticsSwitch = StreamDiagnosticsSwitch(enabled: true)
        let time = SyntheticClock(ms: startMs)
        let recorder = StreamDiagnosticsRecorder(side: .sender, windowSeconds: PerformanceLabScenarioCatalog.windowSeconds,
                                                 diagnosticsSwitch: diagnosticsSwitch, resourceSampler: nil, nowMs: time.ms,
                                                 seriesID: 4141)
        recorder.updateContext { context in
            context.displayMode = .extend
            context.codec = .hevc
            context.rasterWidth = 2732
            context.rasterHeight = 2048
            context.targetFPS = 60
            context.encoderInFlightLimit = 2
            context.route = .usb
            context.networkProtocol = .tcp
            context.pathExpensive = false
            context.pathConstrained = false
        }
        let controller = PerformanceLabRunController(dependencies: .init(
            recorder: { recorder },
            diagnosticsEnabled: { true },
            nowMs: { time.ms },
            now: { createdAt },
            build: build,
            commit: nil,
            outputParent: parent,
            fixture: { nil }))
        let plan = try PerformanceLabRunPlan.make(scenarioID: PerformanceLabScenarioCatalog.synthetic.id, trials: 3)
        controller.start(plan)

        var frame = 0
        var lastKey: Int64 = 0
        var stallFramesLeft = 0
        var trial3MeasuringFrames = 0
        // Scripted receiver: window u covers frames [300(u-1), 300u); it
        // starts with the sender window number the last "ping" carried.
        var lastPingSequence: UInt64?
        var markers: [Int: UInt64] = [:]
        var stallReceiverWindow: Int?
        let limitMs = startMs + 10 * 60 * 1000
        while controller.isRunning, time.ms < limitMs {
            if case .waitingForOperator = controller.phase { controller.operatorReady() }
            let trial: Int
            switch controller.phase {
            case .warmingUp(let t, _), .measuring(let t, _, _): trial = t
            default: trial = 1
            }
            if case .measuring(3, _, _) = controller.phase {
                trial3MeasuringFrames += 1
                // A scripted 300 ms stall, 11 s into trial 3's measurement:
                // inside the trial's sender windows whenever the first one
                // starts (up to 5 s after arming), and inside a receiver
                // window that began after the trial did (one that began
                // before it is not the trial's, and is left out).
                if trial3MeasuringFrames == 660 {
                    stallFramesLeft = 18
                    stallReceiverWindow = frame / receiverWindowFrames + 1
                }
            }

            time.ms += frameMs
            let clock = time.ms
            if stallFramesLeft > 0 {
                stallFramesLeft -= 1
            } else {
                emitFrame(frame, trial: trial, recorder: recorder, clock: clock, lastKey: &lastKey)
            }
            frame += 1
            if frame % pingFrames == 0 {
                // The sender's ping: its snapshot (which rotates, as the
                // real one does) carries its last completed window number.
                lastPingSequence = recorder.snapshot(at: clock).windowSequence
            }
            if frame % receiverWindowFrames == 0 {
                markers[frame / receiverWindowFrames + 1] = lastPingSequence
            }
            let completedReceiverWindow = frame / receiverWindowFrames
            if frame % statsFrames == 0, completedReceiverWindow >= 1 {
                recorder.updatePeer(receiverSummary(trial: trial, window: completedReceiverWindow, send: frame / statsFrames,
                                                    marker: markers[completedReceiverWindow],
                                                    stalled: completedReceiverWindow == stallReceiverWindow), at: clock)
            }
            if frame % 30 == 0 { controller.tick() }
        }
        guard case .finished(let folder) = controller.phase else { throw SyntheticError.didNotFinish }
        return folder
    }

    enum SyntheticError: Error { case didNotFinish }

    /// Scripted cadences, in frames at 60 FPS.
    static let pingFrames = 120            // the sender's ~2 s ping
    static let statsFrames = 120           // the receiver's ~2 s stats (adaptive cadence)
    static let receiverWindowFrames = 300  // the receiver's 5 s window
    static let receiverSeriesID = 4242.0

    @MainActor
    private final class SyntheticClock {
        var ms: Double
        init(ms: Double) { self.ms = ms }
    }

    private static func emitFrame(_ frame: Int, trial: Int, recorder: StreamDiagnosticsRecorder, clock: Double,
                                  lastKey: inout Int64) {
        recorder.recordCapture(.complete, at: clock)
        recorder.increment(.admittedLive, at: clock)
        if frame % 120 == 60 { recorder.increment(.heldEncoderBusy, at: clock) }
        let duplicate = frame % 30 == 29
        let key = duplicate ? lastKey : Int64(frame)
        lastKey = key
        recorder.recordSubmit(origin: duplicate ? .dropReplay : .live, sourceKey: key,
                              sourceAgeMs: 6 + Double(frame % 5), pendingEncodes: 1, at: clock)
        let encodeMs = 5 + Double(frame % 7) * 0.5 + Double(trial - 1) * 0.25
        let bytes = 18_000 + (frame % 10) * 500
        recorder.recordEncodeOutput(durationMs: encodeMs, bytes: bytes, keyframe: frame % 300 == 0, outcome: .sent,
                                    at: clock + encodeMs)
        let sendMs = 1 + Double(frame % 3) * 0.5
        recorder.recordSendCompletion(durationMs: sendMs, bytes: bytes + 16, error: false, at: clock + encodeMs + sendMs)
    }

    /// What a receiver might report about its window `window`; scripted,
    /// slightly different per trial. The jitter is a session value and
    /// changes with every send, as the real one does.
    private static func receiverSummary(trial: Int, window: Int, send: Int, marker: UInt64?, stalled: Bool) -> StreamDiagnosticsPeerSummary {
        var s = StreamDiagnosticsPeerSummary(side: .receiver)
        let t = Double(trial)
        s.windowSeriesID = receiverSeriesID
        s.windowSequence = Double(window)
        s.peerWindowSequenceAtStart = marker.map { Double($0) }
        s.arrivalFPS = 59.8 - 0.2 * t - Double(window % 3) * 0.1
        s.arrivalP50Ms = 17
        s.arrivalP95Ms = 18 + t
        s.arrivalGapsOver250ms = stalled ? 1 : 0
        s.enqueueFPS = 59.8 - 0.2 * t
        s.presenterQueueAgeP95Ms = 2.5
        s.rttMs = 4
        s.rttJitterMs = 0.75 + Double(send % 3) * 0.05
        s.frameIDUniqueFPS = 58 - 0.5 * t
        s.frameIDDuplicates = 2
        s.frameIDMissing = t
        s.frameIDUnreadable = 0
        s.frameIDUnexamined = 0
        s.frameIDIntervalP95Ms = 18
        return s
    }
}
