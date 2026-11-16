# Streaming diagnostics (#123)

Opt-in, local measurement of the streaming pipeline on the Mac sender and on
the iPhone/iPad and Mac receivers. It exists so a performance problem can be
traced to a stage with evidence before anything is tuned. It does not change
capture cadence, queue depths, the frame-rate limiter or presenter buffering.

Code: `Shared/StreamDiagnostics*.swift` (core, pure Foundation), hooks in
`Mac/MacSender.swift`, `Mac/WindowWorkspaceEngine.swift`,
`Shared/StreamReceiver.swift` and `Shared/ReceiverVideoPresenter.swift`.
Tests: `MacTests/StreamDiagnosticsTests.swift`,
`MacTests/StreamDiagnosticsClassifierExportTests.swift`.

## Turning it on

- Mac: Settings → System → Streaming Diagnostics.
- iPhone/iPad: Settings → Diagnostics → Streaming Diagnostics.
- One command on a QA build (takes effect at the next launch):
  `defaults write com.raisecaterror.meowdisplay.mac.debug streamDiagnosticsEnabled -bool YES`
  (use the bundle id of the build in question).

Off by default. When off, every hook is one lock-protected flag read and
returns: no clock read, no allocation, no counter touched, no signpost
(`testDisabledRecorderTouchesNothing`, `testDisabledHookCostIsSmall`).

Both ends measure independently. The receiver's classifier needs the
sender's target frame rate, which only arrives when diagnostics are on at the
Mac too; otherwise it answers `unknownInsufficientData`.

## Model

Each side keeps one `StreamDiagnosticsRecorder` per session. Durations and
intervals go into fixed-bucket histograms, events into counters, levels into
gauges, all in a 5 s window. The last completed window is what the view,
the export and the wire summary report (`windowIsPartial` is true until the
first window completes). After two empty windows the reported window is an
empty one, so a frozen stream reads as zero, not as its last busy window.

A new capture or presentation generation (`noteGeneration`) restarts every
interval baseline, so a reconnect gap is not counted as a stall. A new
receiver session resets the recorder.

`OSSignposter` intervals (subsystem `com.raisecaterror.meowdisplay`,
category `StreamDiagnostics`): `Encode` (submit to output), `Send` (handed
to transport to completion), `Compose` (Window view). Emitted only while
diagnostics are on. No per-frame `Logger` or `print`.

### Stages

source/display refresh → ScreenCaptureKit capture (status complete / idle /
other) → admission (rate limiter hold, encoder busy, send backpressure,
held-frame release) → encoder submit (origin, source age, in-flight depth) →
encoder output (duration, bytes, keyframe, stale, failure) → send (duration,
bytes, in-flight depth) → [network] → receiver arrival (interval, bytes,
wire spans) → presenter command queue (depth, age) → enqueued for
presentation (or Metal decode → observed presentation) ; Window view:
compose (duration, interval, panes, floats, dimmed panes, panes with a frame).

### Frame accounting

- **Source-unique**: a submission whose ScreenCaptureKit PTS differs from the
  previous submission's (`sender.submit.source_unique`). Display capture only.
- **Duplicate**: same PTS as the previous submission (a replay of pixels
  already encoded).
- **Held / released**: turned away by the rate limiter or a busy encoder and
  kept (`sender.admission.held_*`), and later offered again
  (`sender.admission.held_retry`). A released held frame is late, not a duplicate.
- **Replays**: drop replay and reconnect replay, counted by origin.
- **Window view**: composites carry no capture PTS. The engine counts
  composites made by a change and the ~1/s static resends (duplicates by design).
- **Enqueued for presentation**: `AVSampleBufferDisplayLayer.enqueue` (or the
  Metal handoff). Never called "presented".
- **Observed presentation**: only the experimental Metal path's presented
  handler. It is a different render path and changes timing itself.

## Metric dictionary

Generated from `StreamDiagnosticsMetricDictionary` (the test fails if an id
is missing here). Timebases: `localMonotonic` = this device's uptime;
`senderHostClock` = ScreenCaptureKit PTS against the same host clock;
`senderWallClock` = both ends written by the sender; `wallClockMapped` =
receiver clock mapped onto the sender's with the ping/pong offset;
`sampled` = OS state read once per window.

| id | unit | side | timebase | source | caveat |
| --- | --- | --- | --- | --- | --- |
| `sender.capture.complete_interval_ms` | ms | sender | localMonotonic | MacSender stream(_:didOutputSampleBuffer:) frames with SCFrameStatus.complete (display capture) | ScreenCaptureKit delivers a complete frame only when the screen changed, so long intervals on a static screen are idle, not stalls. Capture runs at about 2x the target rate (DisplayCaptureSettings). |
| `sender.source_age_at_submit_ms` | ms | sender | senderHostClock | MacSender.encode: host clock now minus the ScreenCaptureKit sample PTS of the pixels being submitted | Includes the rate limiter's trailing-edge hold and any replay delay. Window view frames are stamped at composition, so this is composition-to-submit there. |
| `sender.encode_ms` | ms | sender | localMonotonic | VTCompressionSession submit (MacSender.encode) to its output callback | Includes VideoToolbox's own queueing when more than one frame is in flight (StreamingPriority in-flight limit 1/2/3). |
| `sender.submit_interval_ms` | ms | sender | localMonotonic | Successive encoder submissions in MacSender.encode | Counts duplicates and replays too; see the submit counters for source-unique frames. |
| `sender.send_ms` | ms | sender | localMonotonic | MacSender.sendFramed: frame handed to the transport until its send completion | A TCP/QUIC send completion means the local stack accepted the bytes, not that the receiver got them. |
| `sender.window.compose_ms` | ms | sender | localMonotonic | WindowWorkspaceEngine.composeTick around WorkspaceCompositor.compose | CPU-side time to build and render the composite; GPU work that finishes later is not included. |
| `sender.window.compose_interval_ms` | ms | sender | localMonotonic | Successive composites in WindowWorkspaceEngine.composeTick | The engine composes only when a pane changed, plus about one resend per second when static. |
| `receiver.arrival_interval_ms` | ms | receiver | localMonotonic | StreamReceiver.presentDecodedSample: successive complete video frames off the wire | A long gap can be an idle source; compare with the sender's capture and submit rates. |
| `receiver.wire.submit_to_send_ms` | ms | receiver | senderWallClock | Frame header snd minus cap (both written by the sender) | The performance overlay labels this "encode". cap is stamped at encoder submission, not at capture, so this is encode plus packaging, not capture-to-send. |
| `receiver.wire.submit_to_receive_ms` | ms | receiver | wallClockMapped | Receiver wall clock (mapped with the ping/pong offset) minus cap at presentDecodedSample | The performance overlay labels this "latency". It starts at encoder submission (not capture) and ends when the frame is handed to the presenter, before any A/V delay, queueing, decode or display. Offset error is up to about half the best round trip. |
| `receiver.decode_ms` | ms | receiver | localMonotonic | ReceiverVideoDecoder decode duration (experimental Metal path only) | The default AVSampleBufferDisplayLayer path decodes inside the system layer and reports no decode time. |
| `receiver.presenter.queue_age_ms` | ms | receiver | localMonotonic | ReceiverVideoPresenter: command yield until the MainActor pump processes it | Measures the AsyncStream command queue and MainActor scheduling only; the queue is unbounded by design and is not changed here. |
| `receiver.presentation.enqueue_interval_ms` | ms | receiver | localMonotonic | Successive AVSampleBufferDisplayLayer.enqueue calls in ReceiverVideoPresenter | Enqueued for presentation, not presented: the layer decides when a frame reaches the screen. |
| `receiver.presentation.observed_submit_to_glass_ms` | ms | receiver | wallClockMapped | Metal drawable presented handler (StreamReceiver.recordPresented) minus cap | Experimental Metal path only, which itself changes timing. Starts at encoder submission, not capture. Not capture-to-photon. |
| `receiver.rtt_ms` | ms | receiver | localMonotonic | Receiver ping to sender pong on the control channel | Control-message round trip; it rides behind any queued video on the same connection. |
| `receiver.frame_id.unique_interval_ms` | ms | receiver | localMonotonic | PerformanceLabFrameIDProbe: successive decoded frames carrying a new Performance Lab fixture frame ID | Lab fixture on screen and experimental Metal path only (which itself changes timing). At the decoded-frame handoff, not on glass. |
| `sender.capture.complete` | frames | sender | none | SCK callback, status complete with pixels | Display capture only (Mirror, Extend). The closest available proxy for source-unique frames: ScreenCaptureKit sends a complete frame when content changed. |
| `sender.capture.idle` | frames | sender | none | SCK callback, status idle | The source did not change; not a drop. |
| `sender.capture.other_status` | frames | sender | none | SCK callback, status blank/suspended/started/stopped or no pixels |  |
| `sender.admission.admitted` | frames | sender | none | FrameAdmission.offer returned send | Admitted by the rate limiter; may still be dropped by backpressure. |
| `sender.admission.held_rate_limit` | frames | sender | none | FrameAdmission.offer returned hold | Normal rate limiting at about 2x capture headroom: expected to be roughly as many as admitted frames while content moves. |
| `sender.admission.held_encoder_busy` | frames | sender | none | pending_encode backpressure (overlay enc↓) | The encoder already had its in-flight limit of frames. |
| `sender.admission.held_retry` | frames | sender | none | retryHeldFrame offered a held frame again | The trailing-edge hold released the last change on screen. |
| `sender.admission.dropped_pending_sends` | frames | sender | none | pending_sends backpressure (overlay net↓) | The transport still had its limit of unsent video frames. |
| `sender.submit.live` | frames | sender | none | Encoder submission straight from a capture callback |  |
| `sender.submit.held_retry` | frames | sender | none | Encoder submission of a held frame | A delayed but not duplicated frame. |
| `sender.submit.drop_replay` | frames | sender | none | replayLastFrameAfterDrop | Re-encodes the newest pixels after send backpressure cleared. |
| `sender.submit.reconnect_replay` | frames | sender | none | Watchdog keyframe replay on a static screen after reconnect |  |
| `sender.submit.window_composite` | frames | sender | none | Encoder submission of a Window view composite | Uniqueness comes from the compose counters, not the PTS. |
| `sender.submit.source_unique` | frames | sender | none | Submission whose capture PTS differs from the previous submission's | A pixel buffer captured once and submitted once. Display capture only. |
| `sender.submit.duplicate` | frames | sender | none | Submission repeating the previous submission's capture PTS | Replays of pixels already encoded. |
| `sender.submit.uniqueness_unknown` | frames | sender | none | Submission without a capture PTS (Window view composite, replay before any capture) |  |
| `sender.encode.completed` | frames | sender | none | VideoToolbox output callback with noErr |  |
| `sender.encode.failed` | frames | sender | none | Submit or output callback failure |  |
| `sender.encode.stale_discarded` | frames | sender | none | Encoded output from a retired session or generation | Encoded but intentionally never sent. |
| `sender.encode.bytes` | bytes | sender | none | Annex B payload size of each encoded frame | Video payload only; framing, TLS, QUIC/TCP and IP overhead are not counted. |
| `sender.encode.keyframes` | frames | sender | none | Encoded frames that are sync samples |  |
| `sender.send.completed` | frames | sender | none | Video send completion without error |  |
| `sender.send.errors` | frames | sender | none | Video send completion with an error |  |
| `sender.send.bytes` | bytes | sender | none | Framed video bytes whose send completed | App payload, not bytes billed by a network: encryption, transport and tunnel overhead are not included. |
| `sender.window.composites` | frames | sender | none | WindowWorkspaceEngine composites delivered |  |
| `sender.window.static_resends` | frames | sender | none | Composites made by the ~1 s static resend, not by a change | Duplicates by design (heal a lost frame). |
| `session.route_changes` | events | either | none | Route class changed between samples | Sampled about every 2 s. |
| `session.generation_resets` | events | either | none | Capture or presentation generation changed; interval baselines restart |  |
| `session.colour_samples` | events | either | none | A colour metadata extraction (pixel buffer attachments, format description extensions, SPS VUI), taken once per stream generation or format change | Counts extractions, not frames. Never per frame; the Colour metadata group reports what they found. |
| `receiver.arrival.frames` | frames | receiver | none | Complete video frames at presentDecodedSample |  |
| `receiver.arrival.bytes` | bytes | receiver | none | Sample buffer size of each arrived frame | Video payload only. |
| `receiver.presentation.enqueued` | frames | receiver | none | AVSampleBufferDisplayLayer.enqueue or Metal handoff | Enqueued for presentation, never confirmed on glass. |
| `receiver.presentation.stale_discarded` | frames | receiver | none | Presenter generation check discarded a frame |  |
| `receiver.presentation.observed` | frames | receiver | none | Metal drawable presented handler | Experimental Metal path only. The only presentation this app can observe. |
| `receiver.presentation.layer_flushes` | events | receiver | none | Display layer failed and was flushed |  |
| `receiver.frame_id.read` | frames | receiver | none | Decoded frames whose Performance Lab frame-ID strip was read | Metal path only; only while the lab fixture is visible. |
| `receiver.frame_id.unique` | frames | receiver | none | Read frame IDs that differ from the previous read ID | Source-unique fixture frames that reached the decoded-frame handoff. |
| `receiver.frame_id.duplicate` | frames | receiver | none | Read frame IDs equal to the previous read ID | The same source frame handed over again. |
| `receiver.frame_id.skipped` | frames | receiver | none | IDs missing between two successive read IDs | Rate limiting at a lower target FPS skips fixture frames by design. |
| `receiver.frame_id.unreadable` | frames | receiver | none | Decoded frames where a located strip failed its guard or checksum | Blended or heavily compressed frames, or the fixture leaving the screen. |
| `receiver.frame_id.discontinuity` | events | receiver | none | Read ID went backwards or jumped by more than half the counter range | Fixture restarted. |
| `sender.encode.pending` | frames | sender | none | Frames in flight in the encoder, sampled at each submission |  |
| `sender.send.pending` | frames | sender | none | Video frames awaiting send completion, sampled at each send |  |
| `receiver.presenter.queue_depth` | commands | receiver | none | ReceiverVideoPresenter commands yielded but not yet processed, sampled at each yield | Counts only commands yielded while diagnostics were on. |
| `sender.window.tiles` | panes | sender | none | Panes on the canvas at each composite |  |
| `sender.window.floats` | panes | sender | none | Floating panes on the canvas at each composite |  |
| `sender.window.dimmed_tiles` | panes | sender | none | Panes drawn dimmed (offscreen, closed, paused) at each composite |  |
| `sender.window.tiles_with_frame` | panes | sender | none | Panes that had a captured frame at each composite |  |
| `receiver.rtt_jitter_ms` | ms | receiver | localMonotonic | Smoothed absolute difference of successive RTT samples (RFC 3550 style, gain 1/16) | Control-channel jitter, not video arrival jitter. |
| `resource.process_cpu_percent` | % of one core | either | sampled | getrusage(RUSAGE_SELF) user+system time delta over wall time between samples | Whole process, sampled once per window (5 s). Not GPU, encoder or decoder hardware load. |
| `resource.memory_footprint_mb` | MB | either | sampled | task_info TASK_VM_INFO phys_footprint | Whole process. |
| `resource.thermal_state` | state | either | sampled | ProcessInfo.thermalState | Coarse four-level system state. |
| `resource.low_power_mode` | bool | either | sampled | ProcessInfo.isLowPowerModeEnabled |  |
| `resource.battery_state` | state | either | sampled | UIDevice.batteryState (iOS, only while the diagnostics page is open) | Unknown elsewhere. |

### Percentiles and error bounds

Histogram buckets are fixed (`DiagnosticsHistogram.upperEdgesMs`): 0.25 ms
up to 4 ms, 1 ms from 4 to 18 ms (covers the 120 and 60 FPS frame budgets),
then coarser up to 10 s, plus an overflow bucket. A reported p50/p95/p99 is
the upper edge of the bucket holding that rank, clamped to the observed
max: the true value is in (previous edge, reported value]. Max and mean are
exact. Negative values (clock mapping) count as 0; non-finite ones are dropped.

### Timestamps: what the overlay's numbers really are

`MacSender.encode` stamps the frame header `cap` with the wall clock **at
encoder submission**, and `snd` when the encoded frame is packaged. `cap`
is not the ScreenCaptureKit capture time: a frame held by the rate limiter,
re-sent by a drop replay or replayed after a reconnect can be much older than
`cap` says. `cap` is also what lock-screen frame acceptance compares, so its
meaning is not changed here.

- Overlay **"encode"** = `snd − cap` = encode plus Annex B packaging
  (`receiver.wire.submit_to_send_ms`). Not capture-to-send.
- Overlay **"latency"** = receiver wall clock mapped by the ping/pong offset,
  minus `cap`, taken when the frame is handed to the presenter
  (`receiver.wire.submit_to_receive_ms`). It excludes capture-to-submit,
  the A/V sync delay, the presenter queue, decode and display. Offset error is
  up to about half the best round trip (min-RTT sample of the last 15).
- Overlay **"photon"** (Metal only) = presented handler time mapped the same
  way, minus `cap` (`receiver.presentation.observed_submit_to_glass_ms`).
  Still starts at submission, not capture.
- The time from capture to submission is measured on the Mac alone
  (`sender.source_age_at_submit_ms`: host clock now minus the sample PTS).

No synchronized cross-device clock is invented: every stage is timed on one
device, except the two `wallClockMapped` spans, which carry the offset caveat.

### Presenter command queue

`ReceiverVideoPresenter` feeds an `AsyncStream(bufferingPolicy: .unbounded)`
to a MainActor pump. Diagnostics stamp each command when yielded and record
its age when the pump takes it (`receiver.presenter.queue_age_ms`) and the
number in flight (`receiver.presenter.queue_depth`). Only commands yielded
while diagnostics are on are counted; a stamped command always leaves the
count, so toggling never makes the depth drift. The buffering policy is not
changed: flush, generation and reset commands must stay ordered.

## Bottleneck verdicts

`StreamBottleneckClassifier` reads the last window (this side plus the
peer's summary). A verdict needs its **primary** signal met plus at least one
more met signal, each from a metric with at least `minimumSamples` samples in
a window of at least `minimumWindowSeconds`. Two met signals = `medium`
confidence, three or more = `high`; equally strong causes = `low` with
`conflictingEvidence` and the others listed as alternatives. A decoder
verdict suppresses the presentation verdict it explains. Frame budget =
1000 / target FPS.

| verdict | primary signal | supporting signals |
| --- | --- | --- |
| `sourceRefreshLimited` | source refresh < `rateShortfall` × target | complete capture rate ≥ (1 − `refreshMatchTolerance`) × refresh; encoder and send headroom (< `headroomShare`) |
| `senderCaptureLimited` | complete capture rate < `captureShortfall` × min(target, refresh) | capture idle share < `activeSourceIdleShare`; encoder and send headroom |
| `windowCompositionLimited` | compose p95 ≥ budget (Window view only) | compose p50 ≥ budget/2; composites < `captureShortfall` × target |
| `encoderOverloaded` | encoder-busy share ≥ `backpressureShare` | encode p95 ≥ `encodeBudgetFactor` × budget; submit rate < `rateShortfall` × min(target, capture rate) |
| `networkDeliveryLimited` | send backpressure share ≥ `backpressureShare` (or, without it, arrival p95 ≥ `deliveryBudgetFactor` × budget) | send p95 ≥ `deliveryBudgetFactor` × budget; arrival p95 ≥ `deliveryBudgetFactor` × budget; RTT jitter ≥ `rttJitterMs`; sender submit rate ≥ `rateShortfall` × target |
| `receiverDecoderOverloaded` | decode p95 ≥ budget (Metal path only) | presenter queue age p95 ≥ budget; enqueue rate < `rateShortfall` × arrival rate |
| `presentationSchedulingLimited` | presenter queue age p95 ≥ budget | arrival p50 < 1.25 × budget (frames arrive on time); enqueue rate < `rateShortfall` × arrival rate |
| `noBottleneckEvident` | enough data, no cause qualified | |
| `unknownInsufficientData` | window too short, no target FPS, too few samples, or source idle (< `idleFPS`) | |

Threshold constants (`StreamBottleneckClassifier`):

| name | value | why |
| --- | --- | --- |
| `minimumWindowSeconds` | 2 | a shorter window says little about cadence |
| `minimumSamples` | 30 | percentiles from fewer samples are not used |
| `backpressureShare` | 0.05 | 5% of admitted frames turned away at a stage; single drops are normal |
| `headroomShare` | 0.02 | under 2% counts as headroom |
| `encodeBudgetFactor` | 1.5 | with 2-3 frames in flight one budget can be exceeded and still keep up; 1.5 cannot |
| `deliveryBudgetFactor` | 2.0 | delivery/send p95 over two budgets |
| `rateShortfall` | 0.9 | a rate under 90% of what was expected |
| `captureShortfall` | 0.8 | capture/compose under 80% of expected |
| `rttJitterMs` | 20 | control jitter that disturbs a 60 FPS cadence |
| `activeSourceIdleShare` | 0.1 | under 10% idle callbacks = content is changing |
| `idleFPS` | 1 | below this the source is idle |
| `refreshMatchTolerance` | 0.1 | capture within 10% of refresh follows the display |

These thresholds are a first, reasoned set, not tuned against measurements.
Revisit them with Performance Lab data.

## Wire summary (optional)

While diagnostics are on, the sender adds `diag` to its `ping` and the
receiver adds `diag` to its `stats` (PROTOCOL.md 6.1 and 6.2). Old peers
ignore it; absence means nothing changes. Values are aggregate numbers only,
clamped to 0…1,000,000 on receipt; booleans, strings and unknown versions
are dropped.

## Export

User action only (Export button): one local JSON file,
`meowdisplay-stream-diagnostics-<UTC yyyyMMdd-HHmm>.json`, then the share
sheet (iOS) or a save panel (Mac). Nothing is uploaded.

Schema (`schemaVersion` 1, `StreamDiagnosticsExport`):

- `schemaVersion`, `metricDictionaryVersion`, `generatedAt` (rounded down to
  the minute)
- `build`: `appVersion` (marketing version and build, sanitized),
  `osMajor`/`osMinor`/`osPatch`, `platform`, `deviceClass` (mac/iPhone/iPad)
- `sessions[]`: `snapshot` (window, stages, counters, session counters,
  gauges, RTT jitter, `context`, `peer`, `resources`, `colour`) and `verdict`
  (cause, confidence, reason, evidence, alternatives, frame budget)
- `classifierThresholds`, `limitations` (fixed sentences)

`context` holds only enums, numbers and bools: display mode, codec, raster,
target FPS, source refresh, encoder in-flight limit, route **class**
(usb/awdl/lan/remote/unknown), network protocol, `pathExpensive`,
`pathConstrained` (the live `NWPath` flags), presentation path, clock-offset known.

### Privacy guarantees

By construction: no field can hold a window title, app name, file path,
SSID, hostname, IP or endpoint address, device or user name, pairing
material or key, input, screenshot or pixels. Strings in the export are enum
values, metric ids, threshold names, the fixed limitation sentences, the
sanitized app version and the date. Sessions are not identified (no peer
ID). `testExportContainsOnlyAllowedKeysAndValues` walks the encoded JSON and
fails on any key outside a reviewed allowlist, on any allowlisted key that
looks like a forbidden kind of field, and on any string value outside that
set.

## Colour metadata

Issue #241 (SDR / Display P3 colour accuracy) is research only. The code sets
no colour metadata anywhere except the pixel format (`420v` or `BGRA`) and one
`CIRenderDestination` colour space in the Window View compositor, so what the
operating system attaches and what the stream's SPS declares can only be
learned by looking. This group looks. **It reads and reports; it does not
convert, tag or correct anything, changes no capture, encoder, decoder or
render setting, and makes no claim of colour accuracy.**

Implementation: `Shared/StreamDiagnosticsColour.swift`. Sampling is read-only,
only while diagnostics are on, and once per stream generation or format change,
never per frame (the per-frame cost of a hook is the on/off flag, one lock and a
key comparison; `session.colour_samples` counts the extractions).

### What is sampled, and where

| Stage | Hook | What is read |
| --- | --- | --- |
| `capture` | `MacSender.encode`, the Mirror / Extend buffer handed to the encoder; once per capture generation or pixel format | Pixel format FourCC and bit depth, `kCVImageBufferColorPrimariesKey`, `TransferFunctionKey`, `YCbCrMatrixKey`, the attached `CGColorSpace` model and name, whether an ICC profile is attached (a bool, never its bytes). Range is read from the pixel format (`420v` limited, `420f` full, `BGRA` not applicable). |
| `composited` | the same hook while the mode is Window View | The same fields for the composited `BGRA` buffer before encode. Replaces a `capture` sample and the other way round. |
| `encoderFormat` | VideoToolbox output callback, keyframes only; once per generation or format description | The output format description's colour extensions (primaries, transfer, matrix, `FullRangeVideo`, bits per component, ICC presence). |
| `encoderVUI` | the same callback | The SPS in that format description (the parameter set that goes on the wire), parsed for its VUI. |
| `receiverFormat` | `codecConfigurationChanged`, when the receiver builds a format description from the received parameter sets | The same extensions as `encoderFormat`. |
| `receiverVUI` | the same event | The SPS parsed for its VUI. |

On the receiver, the format description only changes when the SPS or PPS
changes, so turn diagnostics on before connecting (or reconnect) to get receiver
samples. The sender samples at the next frame / keyframe after the switch is on.

### SPS VUI parser

A pure parser over `Data` for H.264 and HEVC SPS NAL units (with or without an
Annex B start code). It removes emulation prevention bytes, reads Exp-Golomb
codes, and walks the SPS to `vui_parameters`: H.264 high-profile fields
(`chroma_format_idc`, bit depths, scaling lists, picture order count syntax,
cropping) and the HEVC `profile_tier_level` with sub-layers, scaling list data,
PCM, short-term reference picture sets (including inter-predicted sets) and
long-term references. It then reads `video_signal_type_present_flag`,
`video_full_range_flag`, `colour_description_present_flag`,
`colour_primaries`, `transfer_characteristics` and `matrix_coeffs`.

It is defensive: input over 4096 bytes, a wrong NAL type, a non-base layer, a
truncated stream, an oversized loop count or an impossible Exp-Golomb code gives
`unparsed(reason)` (`empty`, `tooLarge`, `notAnSPS`, `truncated`,
`invalidValue`, `exceedsBound`, `unsupportedLayer`, `unsupportedCodec`,
`noParameterSet`), never a crash and never a guess.

### Values

Every value is a closed enum with `absent`, `unspecified` and `other(code)`:
primaries, transfer, YCbCr matrix, pixel format, plus range (`unknown`,
`limited`, `full`, `notApplicable`), bit depth, colour space model and name, and
the ICC bool. `absent` means the syntax element or attachment was not there (no
VUI, no colour description, no attachment); `unspecified` means the stream said
"unspecified" (code 2). `other(code)` carries an H.273 code point the table
does not name; `other(-1)` is an attachment string this tool does not list.

### Consistency summary

The summary compares stage pairs where both ends were sampled and parsed: the
source buffer against the encoder format description, that against the encoder
SPS VUI, the source buffer against the VUI, and (receiver) its format description
against its VUI. A field is compared only when at least one side states a value;
range is reported only when both stages state one and they differ (an absent
`FullRangeVideo` flag has a documented default, video range).
Each mismatch is a typed code: `differ` (both state values and they differ),
`firstUnlabelled` or `secondUnlabelled` (only one side states it). There is no
verdict on which stage is right. Not counted as differences: BT.709 / SMPTE 170M /
BT.2020 transfer (the same curve), BT.470 BG against SMPTE 170M matrix (both
"601"), `unspecified` against `absent`, and range when either side is not stated or is RGB. An
untagged `BGRA` composite against an SPS that labels a matrix therefore shows
`firstUnlabelled` for `matrix`: informational, and the very thing candidate B
asks about.

### Export

`snapshot.colour` (absent until sampled) holds `stages[]` (`stage`, `metadata`,
`vui`, `unparsed`), `consistency` (`agreement`, `comparisons`, `mismatches[]`) and
`sampleCount`. Enums encode as `{"kind": "...", "code": N}` (`code` only for
`other`). There is no free-form string field; `StreamDiagnosticsColourTests`
runs the same key and value allowlist as the rest of the export over a
populated colour section.

### What to capture on hardware (#241)

PENDING HARDWARE: no value in this section has been observed on a real stream. The unit tests
use synthetic buffers and hand-built parameter sets only.

Per capture: turn Streaming Diagnostics on on the Mac and on the receiver
before connecting, run the stream for about 10 s, open Settings, read the
"Colour metadata" group (Mac and receiver), then Export on both. Repeat for each
combination below, same display, same receiver, same colour profile.

| Capture | Mode | Codec |
| --- | --- | --- |
| 1 | Mirror (or Extend) | H.264 |
| 2 | Mirror (or Extend) | HEVC |
| 3 | Window View | H.264 |
| 4 | Window View | HEVC |

Record the Mac display's colour profile (System Settings > Displays) and the receiver model with each capture.

Which audit candidate each observation confirms or rules out (candidates from the #241 pipeline audit):

| Candidate | What it is | Observation that confirms it | Observation that rules it out |
| --- | --- | --- | --- |
| A | Mirror / Extend: SCK default (display, maybe P3) colour space against what the VUI / receiver assumes | `capture` primaries `displayP3` (or colour space `displayP3`) while `encoderVUI` primaries are `bt709`, `absent` or `unspecified` (a `primaries` mismatch on the capture to VUI pair) | `capture` and `encoderVUI` primaries agree |
| B | Window View: composited buffer untagged, so VideoToolbox picks the RGB to YCbCr matrix | `composited` matrix `absent` (untagged) and `encoderVUI` matrix a value (`firstUnlabelled`), or `encoderVUI` matrix `absent` / `unspecified` while the receiver decodes with a default | `composited` carries a matrix that equals the VUI matrix |
| C | Window View only: the compositor renders into sRGB while SCK captures in the display's space | `composited` space `srgb` and primaries `absent` or `bt709` in Window View while the Mirror capture's `capture` primaries are `displayP3`. The metadata shows the tag; whether wide-gamut content was clipped needs a swatch comparison, so this stays unconfirmed from metadata alone | `composited` carries P3 primaries or a P3 colour space, or Mirror is not P3 either |
| D | Transfer function: sRGB-encoded pixels against a BT.709 transfer tag | `encoderVUI` or `receiverFormat` transfer `bt709` (or `smpte170m`) while `capture` / `composited` transfer or colour space is `srgb` (a `transfer` mismatch is not raised for 709 against 170M, so read the values) | VUI transfer `srgb`, or `unspecified` / `absent` on every stage (then the receiver's default decides; metadata cannot say what it is) |
| E | Range mismatch (video against full) | `encoderVUI` range `full` while `capture` is `420v` (`limited`), or `limited` VUI over a full-range source (`range` `differ`) | `range` agrees across stages, or the VUI does not state a range (`unknown`) |
| F | Metal path ignores tags and does no colour management | Needs a second capture with `metalRenderer` on: identical stage values but a visibly different picture. Metadata cannot confirm it; it can show the stream is tagged identically for both paths | Not applicable to the metadata |
| G | Android relies entirely on the VUI | `encoderVUI` primaries / matrix `absent` or `unspecified` (nothing for Android to read) | VUI fully stated and consistent with the format description. Android itself has no diagnostics here |

Also settle the audit's open questions from the same exports: what the system
attaches to a delivered SCK buffer (`capture`), whether the compositor or
VideoToolbox tags a composited buffer (`composited`), what VUI VideoToolbox
writes (`encoderVUI`), and whether CoreMedia lifts the VUI into the format
description on the receiver (`receiverFormat` against `receiverVUI`).

## Overhead method

- Disabled: one uncontended `NSLock` read per hook (`testDisabledHookCostIsSmall`
  asserts well under 5 µs per call; it is a guard, not a benchmark).
- Enabled: one lock per hook, a binary search over 54 bucket edges and a few
  integer adds; storage is allocated once, and the arrays are copied once per
  5 s window rotation. Resources are sampled once per window.
- To measure on hardware: compare the `Encode`/`Send`/`Compose` signpost
  intervals and the process CPU in Instruments with diagnostics on and off,
  same build, same workload, three runs each. Not done yet (PENDING HARDWARE).

## Measured vs not measured

Measured (app-level, with the caveats above): capture callback status and
cadence, admission outcomes, source age at submit, encode duration, send
completion, Window view composition, arrival cadence, wire spans, presenter
queue depth and age, enqueue cadence, Metal decode and observed presentation
(experimental path only), control RTT and jitter, process CPU, memory,
thermal state, Low Power Mode, battery state (iOS, while the page is open).

Not measured:

- Physical presentation on the default `AVSampleBufferDisplayLayer` path.
- Capture-to-photon or input-to-photon: needs external measurement (camera
  or photodiode) and accounts for display scan-out the app cannot see.
- GPU, hardware encoder or decoder utilisation (no public per-process API used).
- Network bytes billed (TLS, QUIC/TCP, IP, VPN/tunnel overhead are not counted).
- Decode time on the default display-layer path.
- Whether any colour value is right: the colour group reports metadata, not accuracy, and makes no claim about the picture.
- Source display refresh: not read yet. `sourceRefreshHz` stays unset in this
  build, so `sourceRefreshLimited` cannot fire on live data until a hook
  supplies it (the classifier and its tests are ready for it).
- Android receivers: no diagnostics yet; they ignore the `diag` keys.

## Performance Lab frame-ID reader

The `receiver.frame_id.*` metrics come from the Performance Lab
(`docs/performance/performance-lab.md`). They are recorded only while the
lab fixture's frame-ID strip is found in decoded frames, which exist only on
the experimental Metal path (`ReceiverVideoPresenter.presentDecoded`). On
the default display-layer path the system layer decodes internally, no
pixel buffer is reachable without changing rendering, and these metrics
stay at zero. The reader probes one decoded frame in 30 for the strip and
reads every frame only while the strip is found.
