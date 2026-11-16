// Streaming diagnostics (#123): the metric dictionary.
//
// Every number the diagnostics recorder keeps, exports or shows is one of
// the identifiers below, with its unit, the side that measures it, the code
// point it comes from, the clock it is measured on and its caveat. The
// export, the developer view and docs/performance/diagnostics.md are all
// checked against this list by `StreamDiagnosticsTests`, so a metric cannot
// be added without saying what it really measures.
//
// Pure Foundation. Compiled into every app target and into MacTests.

import Foundation

/// Which end of a session measured a number.
enum StreamDiagnosticsSide: String, Codable, Sendable, CaseIterable {
    case sender
    case receiver
}

/// The clock a metric is read on. No metric compares two devices' clocks
/// except the two `wallClockMapped` ones, which say so.
enum StreamDiagnosticsTimebase: String, Codable, Sendable {
    /// `DispatchTime` uptime on the measuring device (monotonic, stops in sleep).
    case localMonotonic
    /// ScreenCaptureKit sample PTS (host time clock) against the same host clock.
    case senderHostClock
    /// Both ends of the span are sender wall-clock milliseconds carried in the
    /// frame header (`cap`, `snd`): one clock, no mapping.
    case senderWallClock
    /// Receiver wall clock mapped onto the sender's with the ping/pong
    /// offset: error bounded by about half the best round trip.
    case wallClockMapped
    /// A count or a gauge; no clock.
    case none
    /// Sampled operating-system state.
    case sampled
}

/// One metric's definition. Strings here are constants in code, never data
/// from a session.
struct StreamDiagnosticsMetricDefinition: Equatable, Sendable {
    let id: String
    let unit: String
    let side: StreamDiagnosticsSide?
    let source: String
    let timebase: StreamDiagnosticsTimebase
    let caveat: String
}

// MARK: - Stages (durations and intervals, kept as histograms)

/// A measured duration or inter-event interval. Raw values index fixed-size
/// storage in the recorder; never reorder without updating nothing else —
/// the export uses `id`, not the raw value.
enum DiagnosticsStage: Int, CaseIterable, Sendable {
    // Sender
    case captureInterval
    case sourceAgeAtSubmit
    case encode
    case submitInterval
    case send
    case compose
    case composeInterval
    // Receiver
    case arrivalInterval
    case wireSubmitToSend
    case mappedSubmitToReceive
    case decode
    case presenterQueueAge
    case presentationEnqueueInterval
    case observedSubmitToGlass
    case rtt

    /// Stages that are intervals between successive events: they also count
    /// gaps over 100/250/500 ms.
    var isInterval: Bool {
        switch self {
        case .captureInterval, .submitInterval, .composeInterval, .arrivalInterval, .presentationEnqueueInterval:
            return true
        default:
            return false
        }
    }

    var definition: StreamDiagnosticsMetricDefinition {
        switch self {
        case .captureInterval:
            return .init(id: "sender.capture.complete_interval_ms", unit: "ms", side: .sender,
                         source: "MacSender stream(_:didOutputSampleBuffer:) frames with SCFrameStatus.complete (display capture)",
                         timebase: .localMonotonic,
                         caveat: "ScreenCaptureKit delivers a complete frame only when the screen changed, so long intervals on a static screen are idle, not stalls. Capture runs at about 2x the target rate (DisplayCaptureSettings).")
        case .sourceAgeAtSubmit:
            return .init(id: "sender.source_age_at_submit_ms", unit: "ms", side: .sender,
                         source: "MacSender.encode: host clock now minus the ScreenCaptureKit sample PTS of the pixels being submitted",
                         timebase: .senderHostClock,
                         caveat: "Includes the rate limiter's trailing-edge hold and any replay delay. Window view frames are stamped at composition, so this is composition-to-submit there.")
        case .encode:
            return .init(id: "sender.encode_ms", unit: "ms", side: .sender,
                         source: "VTCompressionSession submit (MacSender.encode) to its output callback",
                         timebase: .localMonotonic,
                         caveat: "Includes VideoToolbox's own queueing when more than one frame is in flight (StreamingPriority in-flight limit 1/2/3).")
        case .submitInterval:
            return .init(id: "sender.submit_interval_ms", unit: "ms", side: .sender,
                         source: "Successive encoder submissions in MacSender.encode",
                         timebase: .localMonotonic,
                         caveat: "Counts duplicates and replays too; see the submit counters for source-unique frames.")
        case .send:
            return .init(id: "sender.send_ms", unit: "ms", side: .sender,
                         source: "MacSender.sendFramed: frame handed to the transport until its send completion",
                         timebase: .localMonotonic,
                         caveat: "A TCP/QUIC send completion means the local stack accepted the bytes, not that the receiver got them.")
        case .compose:
            return .init(id: "sender.window.compose_ms", unit: "ms", side: .sender,
                         source: "WindowWorkspaceEngine.composeTick around WorkspaceCompositor.compose",
                         timebase: .localMonotonic,
                         caveat: "CPU-side time to build and render the composite; GPU work that finishes later is not included.")
        case .composeInterval:
            return .init(id: "sender.window.compose_interval_ms", unit: "ms", side: .sender,
                         source: "Successive composites in WindowWorkspaceEngine.composeTick",
                         timebase: .localMonotonic,
                         caveat: "The engine composes only when a pane changed, plus about one resend per second when static.")
        case .arrivalInterval:
            return .init(id: "receiver.arrival_interval_ms", unit: "ms", side: .receiver,
                         source: "StreamReceiver.presentDecodedSample: successive complete video frames off the wire",
                         timebase: .localMonotonic,
                         caveat: "A long gap can be an idle source; compare with the sender's capture and submit rates.")
        case .wireSubmitToSend:
            return .init(id: "receiver.wire.submit_to_send_ms", unit: "ms", side: .receiver,
                         source: "Frame header snd minus cap (both written by the sender)",
                         timebase: .senderWallClock,
                         caveat: "The performance overlay labels this \"encode\". cap is stamped at encoder submission, not at capture, so this is encode plus packaging, not capture-to-send.")
        case .mappedSubmitToReceive:
            return .init(id: "receiver.wire.submit_to_receive_ms", unit: "ms", side: .receiver,
                         source: "Receiver wall clock (mapped with the ping/pong offset) minus cap at presentDecodedSample",
                         timebase: .wallClockMapped,
                         caveat: "The performance overlay labels this \"latency\". It starts at encoder submission (not capture) and ends when the frame is handed to the presenter, before any A/V delay, queueing, decode or display. Offset error is up to about half the best round trip.")
        case .decode:
            return .init(id: "receiver.decode_ms", unit: "ms", side: .receiver,
                         source: "ReceiverVideoDecoder decode duration (experimental Metal path only)",
                         timebase: .localMonotonic,
                         caveat: "The default AVSampleBufferDisplayLayer path decodes inside the system layer and reports no decode time.")
        case .presenterQueueAge:
            return .init(id: "receiver.presenter.queue_age_ms", unit: "ms", side: .receiver,
                         source: "ReceiverVideoPresenter: command yield until the MainActor pump processes it",
                         timebase: .localMonotonic,
                         caveat: "Measures the AsyncStream command queue and MainActor scheduling only; the queue is unbounded by design and is not changed here.")
        case .presentationEnqueueInterval:
            return .init(id: "receiver.presentation.enqueue_interval_ms", unit: "ms", side: .receiver,
                         source: "Successive AVSampleBufferDisplayLayer.enqueue calls in ReceiverVideoPresenter",
                         timebase: .localMonotonic,
                         caveat: "Enqueued for presentation, not presented: the layer decides when a frame reaches the screen.")
        case .observedSubmitToGlass:
            return .init(id: "receiver.presentation.observed_submit_to_glass_ms", unit: "ms", side: .receiver,
                         source: "Metal drawable presented handler (StreamReceiver.recordPresented) minus cap",
                         timebase: .wallClockMapped,
                         caveat: "Experimental Metal path only, which itself changes timing. Starts at encoder submission, not capture. Not capture-to-photon.")
        case .rtt:
            return .init(id: "receiver.rtt_ms", unit: "ms", side: .receiver,
                         source: "Receiver ping to sender pong on the control channel",
                         timebase: .localMonotonic,
                         caveat: "Control-message round trip; it rides behind any queued video on the same connection.")
        }
    }
}

// MARK: - Counters

/// Monotonic event counts (per window and per session).
enum DiagnosticsCounter: Int, CaseIterable, Sendable {
    // Sender capture
    case captureComplete
    case captureIdle
    case captureOtherStatus
    // Sender admission (FrameAdmission / pipeline backpressure)
    case admittedLive
    case heldByRateLimit
    case heldEncoderBusy
    case heldRetryFired
    case droppedPendingSends
    // Sender encoder submissions, by origin
    case submitLive
    case submitHeldRetry
    case submitDropReplay
    case submitReconnectReplay
    case submitWorkspace
    // Sender submissions, by uniqueness
    case submitSourceUnique
    case submitDuplicate
    case submitUniquenessUnknown
    // Sender encoder output and send
    case encodeCompleted
    case encodeFailed
    case encodeStaleDiscarded
    case encodedBytes
    case keyframes
    case sendCompleted
    case sendErrors
    case sentBytes
    // Sender Window view
    case composeFrames
    case composeStaticResends
    // Both
    case routeChanges
    case generationResets
    // Receiver
    case arrivedFrames
    case arrivedBytes
    case enqueuedForPresentation
    case presenterStaleDiscarded
    case observedPresentations
    case displayLayerFlushes

    var definition: StreamDiagnosticsMetricDefinition {
        let s = StreamDiagnosticsSide.sender, r = StreamDiagnosticsSide.receiver
        switch self {
        case .captureComplete:
            return .init(id: "sender.capture.complete", unit: "frames", side: s, source: "SCK callback, status complete with pixels", timebase: .none,
                         caveat: "Display capture only (Mirror, Extend). The closest available proxy for source-unique frames: ScreenCaptureKit sends a complete frame when content changed.")
        case .captureIdle:
            return .init(id: "sender.capture.idle", unit: "frames", side: s, source: "SCK callback, status idle", timebase: .none,
                         caveat: "The source did not change; not a drop.")
        case .captureOtherStatus:
            return .init(id: "sender.capture.other_status", unit: "frames", side: s, source: "SCK callback, status blank/suspended/started/stopped or no pixels", timebase: .none,
                         caveat: "")
        case .admittedLive:
            return .init(id: "sender.admission.admitted", unit: "frames", side: s, source: "FrameAdmission.offer returned send", timebase: .none,
                         caveat: "Admitted by the rate limiter; may still be dropped by backpressure.")
        case .heldByRateLimit:
            return .init(id: "sender.admission.held_rate_limit", unit: "frames", side: s, source: "FrameAdmission.offer returned hold", timebase: .none,
                         caveat: "Normal rate limiting at about 2x capture headroom: expected to be roughly as many as admitted frames while content moves.")
        case .heldEncoderBusy:
            return .init(id: "sender.admission.held_encoder_busy", unit: "frames", side: s, source: "pending_encode backpressure (overlay enc↓)", timebase: .none,
                         caveat: "The encoder already had its in-flight limit of frames.")
        case .heldRetryFired:
            return .init(id: "sender.admission.held_retry", unit: "frames", side: s, source: "retryHeldFrame offered a held frame again", timebase: .none,
                         caveat: "The trailing-edge hold released the last change on screen.")
        case .droppedPendingSends:
            return .init(id: "sender.admission.dropped_pending_sends", unit: "frames", side: s, source: "pending_sends backpressure (overlay net↓)", timebase: .none,
                         caveat: "The transport still had its limit of unsent video frames.")
        case .submitLive:
            return .init(id: "sender.submit.live", unit: "frames", side: s, source: "Encoder submission straight from a capture callback", timebase: .none, caveat: "")
        case .submitHeldRetry:
            return .init(id: "sender.submit.held_retry", unit: "frames", side: s, source: "Encoder submission of a held frame", timebase: .none,
                         caveat: "A delayed but not duplicated frame.")
        case .submitDropReplay:
            return .init(id: "sender.submit.drop_replay", unit: "frames", side: s, source: "replayLastFrameAfterDrop", timebase: .none,
                         caveat: "Re-encodes the newest pixels after send backpressure cleared.")
        case .submitReconnectReplay:
            return .init(id: "sender.submit.reconnect_replay", unit: "frames", side: s, source: "Watchdog keyframe replay on a static screen after reconnect", timebase: .none,
                         caveat: "")
        case .submitWorkspace:
            return .init(id: "sender.submit.window_composite", unit: "frames", side: s, source: "Encoder submission of a Window view composite", timebase: .none,
                         caveat: "Uniqueness comes from the compose counters, not the PTS.")
        case .submitSourceUnique:
            return .init(id: "sender.submit.source_unique", unit: "frames", side: s, source: "Submission whose capture PTS differs from the previous submission's", timebase: .none,
                         caveat: "A pixel buffer captured once and submitted once. Display capture only.")
        case .submitDuplicate:
            return .init(id: "sender.submit.duplicate", unit: "frames", side: s, source: "Submission repeating the previous submission's capture PTS", timebase: .none,
                         caveat: "Replays of pixels already encoded.")
        case .submitUniquenessUnknown:
            return .init(id: "sender.submit.uniqueness_unknown", unit: "frames", side: s, source: "Submission without a capture PTS (Window view composite, replay before any capture)", timebase: .none,
                         caveat: "")
        case .encodeCompleted:
            return .init(id: "sender.encode.completed", unit: "frames", side: s, source: "VideoToolbox output callback with noErr", timebase: .none, caveat: "")
        case .encodeFailed:
            return .init(id: "sender.encode.failed", unit: "frames", side: s, source: "Submit or output callback failure", timebase: .none, caveat: "")
        case .encodeStaleDiscarded:
            return .init(id: "sender.encode.stale_discarded", unit: "frames", side: s, source: "Encoded output from a retired session or generation", timebase: .none,
                         caveat: "Encoded but intentionally never sent.")
        case .encodedBytes:
            return .init(id: "sender.encode.bytes", unit: "bytes", side: s, source: "Annex B payload size of each encoded frame", timebase: .none,
                         caveat: "Video payload only; framing, TLS, QUIC/TCP and IP overhead are not counted.")
        case .keyframes:
            return .init(id: "sender.encode.keyframes", unit: "frames", side: s, source: "Encoded frames that are sync samples", timebase: .none, caveat: "")
        case .sendCompleted:
            return .init(id: "sender.send.completed", unit: "frames", side: s, source: "Video send completion without error", timebase: .none, caveat: "")
        case .sendErrors:
            return .init(id: "sender.send.errors", unit: "frames", side: s, source: "Video send completion with an error", timebase: .none, caveat: "")
        case .sentBytes:
            return .init(id: "sender.send.bytes", unit: "bytes", side: s, source: "Framed video bytes whose send completed", timebase: .none,
                         caveat: "App payload, not bytes billed by a network: encryption, transport and tunnel overhead are not included.")
        case .composeFrames:
            return .init(id: "sender.window.composites", unit: "frames", side: s, source: "WindowWorkspaceEngine composites delivered", timebase: .none, caveat: "")
        case .composeStaticResends:
            return .init(id: "sender.window.static_resends", unit: "frames", side: s, source: "Composites made by the ~1 s static resend, not by a change", timebase: .none,
                         caveat: "Duplicates by design (heal a lost frame).")
        case .routeChanges:
            return .init(id: "session.route_changes", unit: "events", side: nil, source: "Route class changed between samples", timebase: .none, caveat: "Sampled about every 2 s.")
        case .generationResets:
            return .init(id: "session.generation_resets", unit: "events", side: nil, source: "Capture or presentation generation changed; interval baselines restart", timebase: .none, caveat: "")
        case .arrivedFrames:
            return .init(id: "receiver.arrival.frames", unit: "frames", side: r, source: "Complete video frames at presentDecodedSample", timebase: .none, caveat: "")
        case .arrivedBytes:
            return .init(id: "receiver.arrival.bytes", unit: "bytes", side: r, source: "Sample buffer size of each arrived frame", timebase: .none,
                         caveat: "Video payload only.")
        case .enqueuedForPresentation:
            return .init(id: "receiver.presentation.enqueued", unit: "frames", side: r, source: "AVSampleBufferDisplayLayer.enqueue or Metal handoff", timebase: .none,
                         caveat: "Enqueued for presentation, never confirmed on glass.")
        case .presenterStaleDiscarded:
            return .init(id: "receiver.presentation.stale_discarded", unit: "frames", side: r, source: "Presenter generation check discarded a frame", timebase: .none, caveat: "")
        case .observedPresentations:
            return .init(id: "receiver.presentation.observed", unit: "frames", side: r, source: "Metal drawable presented handler", timebase: .none,
                         caveat: "Experimental Metal path only. The only presentation this app can observe.")
        case .displayLayerFlushes:
            return .init(id: "receiver.presentation.layer_flushes", unit: "events", side: r, source: "Display layer failed and was flushed", timebase: .none, caveat: "")
        }
    }
}

// MARK: - Gauges

/// Sampled levels (last, max, mean per window).
enum DiagnosticsGauge: Int, CaseIterable, Sendable {
    case pendingEncodes
    case pendingSends
    case presenterQueueDepth
    case windowTiles
    case windowFloats
    case windowCoveredTiles
    case windowTilesWithFrame

    var definition: StreamDiagnosticsMetricDefinition {
        switch self {
        case .pendingEncodes:
            return .init(id: "sender.encode.pending", unit: "frames", side: .sender, source: "Frames in flight in the encoder, sampled at each submission", timebase: .none, caveat: "")
        case .pendingSends:
            return .init(id: "sender.send.pending", unit: "frames", side: .sender, source: "Video frames awaiting send completion, sampled at each send", timebase: .none, caveat: "")
        case .presenterQueueDepth:
            return .init(id: "receiver.presenter.queue_depth", unit: "commands", side: .receiver, source: "ReceiverVideoPresenter commands yielded but not yet processed, sampled at each yield", timebase: .none,
                         caveat: "Counts only commands yielded while diagnostics were on.")
        case .windowTiles:
            return .init(id: "sender.window.tiles", unit: "panes", side: .sender, source: "Panes on the canvas at each composite", timebase: .none, caveat: "")
        case .windowFloats:
            return .init(id: "sender.window.floats", unit: "panes", side: .sender, source: "Floating panes on the canvas at each composite", timebase: .none, caveat: "")
        case .windowCoveredTiles:
            return .init(id: "sender.window.dimmed_tiles", unit: "panes", side: .sender, source: "Panes drawn dimmed (offscreen, closed, paused) at each composite", timebase: .none, caveat: "")
        case .windowTilesWithFrame:
            return .init(id: "sender.window.tiles_with_frame", unit: "panes", side: .sender, source: "Panes that had a captured frame at each composite", timebase: .none, caveat: "")
        }
    }
}

// MARK: - Dictionary

enum StreamDiagnosticsMetricDictionary {
    /// Bump when an id is renamed or its meaning changes.
    static let version = 1

    /// Metrics that are not a stage, counter or gauge.
    static let derived: [StreamDiagnosticsMetricDefinition] = [
        .init(id: "receiver.rtt_jitter_ms", unit: "ms", side: .receiver, source: "Smoothed absolute difference of successive RTT samples (RFC 3550 style, gain 1/16)",
              timebase: .localMonotonic, caveat: "Control-channel jitter, not video arrival jitter."),
        .init(id: "resource.process_cpu_percent", unit: "% of one core", side: nil, source: "getrusage(RUSAGE_SELF) user+system time delta over wall time between samples",
              timebase: .sampled, caveat: "Whole process, sampled once per window (5 s). Not GPU, encoder or decoder hardware load."),
        .init(id: "resource.memory_footprint_mb", unit: "MB", side: nil, source: "task_info TASK_VM_INFO phys_footprint",
              timebase: .sampled, caveat: "Whole process."),
        .init(id: "resource.thermal_state", unit: "state", side: nil, source: "ProcessInfo.thermalState",
              timebase: .sampled, caveat: "Coarse four-level system state."),
        .init(id: "resource.low_power_mode", unit: "bool", side: nil, source: "ProcessInfo.isLowPowerModeEnabled",
              timebase: .sampled, caveat: ""),
        .init(id: "resource.battery_state", unit: "state", side: nil, source: "UIDevice.batteryState (iOS, only while the diagnostics page is open)",
              timebase: .sampled, caveat: "Unknown elsewhere."),
    ]

    static var all: [StreamDiagnosticsMetricDefinition] {
        DiagnosticsStage.allCases.map(\.definition)
            + DiagnosticsCounter.allCases.map(\.definition)
            + DiagnosticsGauge.allCases.map(\.definition)
            + derived
    }

    static func definition(id: String) -> StreamDiagnosticsMetricDefinition? {
        all.first { $0.id == id }
    }
}
