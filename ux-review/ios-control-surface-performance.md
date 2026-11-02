# Performance audit: receiver controls, 8× zoom and the streaming path

Companion to [`ios-control-surface.md`](ios-control-surface.md). Released
v1.20.0 is reported as responsive in daily use, so the bar here is evidence:
nothing in the streaming path changes in this branch, and anything worth
doing is listed for a separate performance PR.

No physical iPhone, iPad or second Mac was available. Everything below is
either measured on this Mac, read from the code, or marked as needing
hardware.

## What already exists

| Tool | What it gives | Where |
|---|---|---|
| Performance overlay (`PerfOverlay`) | Live fps, Mbps, inter-frame intervals and a bar graph, stalls (frames >50 ms late), e2e P50/P95, Mac encode P50, control RTT, cursor updates/s and drops, Mac encoder/network drops and send-queue depth, capture fps, input P50/P95 (touch sent → CGEvent injected), and on the Metal path decode P50 and photon P50/P95 (capture → on glass). | `Shared/PerfOverlay.swift`, `PerfStats` in `Shared/StreamReceiver.swift` |
| Decode/present counters | Decode durations and display-layer flushes, lock-backed and off the actor path. | `Shared/ReceiverVideoTelemetry.swift` |
| DEBUG pipeline log | `receiverPipeline:` frames decoded/presented per second. | `StreamReceiver` (DEBUG only) |
| Renderer A/B switch | `metalRenderer` user default picks the Metal path (photon metrics) over `AVSampleBufferDisplayLayer` (the default). | `iOS/MetalVideoRenderer.swift` |
| Unit tests | 1,875 macOS-hosted tests of the pure geometry, gesture, input and protocol code. | `MacTests/` |

Not present: `os_signpost` intervals, XCTest performance metrics, and any
automated latency benchmark. The overlay is the only end-to-end measurement,
and it needs a live session.

## Confirmed measurements (this Mac)

MacBook Air, Swift `-O`, three runs each, compiled against the branch's
`Shared/RemoteViewport.swift`:

| Operation | Cost per call |
|---|---|
| Pinch update: `ManualViewportState.pinching` + `applyManualZoom` + `remotePoint` at 1× | ~125 ns |
| Same at 8× | ~124 ns |
| Same at 8×, rotated 30° | ~145 ns |
| `VideoView.layoutSubviews`' diagnostic line: build string + `NSLog` + date format (main thread) | ~9 µs |
| That line's file append (`Log`'s background queue) | ~2.7 µs |

Local gesture math is roughly 1/60,000 of a 120 Hz frame and doesn't depend
on magnification. It isn't a bottleneck at any zoom.

## Code-level findings

- **Zoom doesn't touch the stream.** `VideoView.applyContentGeometry` sets the
  content layer's bounds to the *unzoomed* rect and applies scale and rotation
  as a layer transform. Stream resolution, bitrate, decoder output and the
  Metal drawable (`drawableSize` = decoded pixel-buffer size) are identical at
  1× and 8×. No buffer is allocated or resized when zooming.
- **What zoom does change** is compositing. At 1× the video covers the
  aspect-fit rect; a 16:10 Mac fills a 402 × 874 pt iPhone from about 1.4× in
  landscape and 3.5× in portrait, and when rotated it's sampled at an angle. Compositor work is bounded by the screen's
  pixels, not by the 8× layer size, because off-screen parts are clipped
  (`clipsToBounds`).
- **The open question is the video plane.** The code records an earlier A/B:
  `AVSampleBufferDisplayLayer` reached glass faster than the Metal path
  because iOS gives it a dedicated compositor plane. Whether iOS keeps that
  plane for a scaled or rotated layer isn't documented. If it doesn't, zooming
  could add compositor work and possibly latency. That's a **hypothesis**:
  it can't be measured in the simulator, whose GPU path is the Mac's.
- **Per-frame logging during gestures.** Each pinch, rotate or Move View update
  calls `setNeedsLayout()` + `layoutIfNeeded()`. `layoutSubviews` logs a
  "layout:" line whenever the displayed size changes, which is every update of
  a pinch. At 120 Hz that's ~0.1 % of the main thread's 8.3 ms frame budget
  (if device cost is similar to this Mac's): small, but it also fills the
  1 MB diagnostics log with noise during a long pinch (about 90 KB per 10 s). The line exists for rotation diagnostics and
  only needs bounds and video size.
- **The send path is already bounded and tuned.** VideoToolbox runs RealTime,
  without frame reordering, with a capped frame delay and speed over quality.
  At most 2 encodes and 3 sends are in flight. A busy encoder or full TCP queue
  drops the capture rather than queueing it (counted as Mac enc/net drops).
  ScreenCaptureKit's queue depth is 8.
- **Telemetry memory is bounded.** Interval and latency rings cap at ~120
  samples, and decode durations are cleared every 5 s report. `removeFirst()`
  on a 120-element array is negligible.
- **Input dispatch** is a direct JSON control message per event. On the Mac,
  `handleKeyboardPress` posts down and up under one lock, merged with held
  modifiers. Nothing in this branch adds work to it: Return reuses the existing
  press path.

## Needs hardware

| Question | How to measure |
|---|---|
| Does zoom or rotation cost latency on the default video layer? | Overlay e2e P50/P95 and stalls at 1×, 8× and 8× rotated, 2 minutes each, same scene. Then repeat with `metalRenderer` on for photon P50/P95. |
| Does zoom or rotation cost GPU or frame pacing? | Instruments, Animation Hitches + Core Animation, at 1×/8×/rotated, during a pinch and at rest. |
| Sustained CPU, memory and thermals | 30-minute session with Xcode's gauges and Thermal State, 1× vs 8×. |
| Input latency | Overlay input P50/P95 while typing and dragging, USB vs Wi-Fi. |

## Worth trying in a separate performance PR

1. **Log layout only when bounds or video size change**, not on every
   displayed-size change. Small, local, no behaviour change. Measured at ~9 µs
   per gesture frame on this Mac, so the main gain is a diagnostics log that
   stays useful; low priority.
2. **Add `os_signpost` intervals** around decode, present, input send and
   inject. That makes the questions above answerable in Instruments without
   new UI.
3. **Run the zoom A/B above.** If the video plane is lost under transform,
   consider dropping rotation (not scale) from the default path's transform
   above some threshold, and only with numbers in hand.

## Not worth the risk without evidence

- Retuning encoder properties, in-flight limits or the capture queue depth.
  They're deliberate, and earlier measurements are recorded in the code.
- Changing `maximumDrawableCount` or switching the default renderer. The code
  records that 2 drawables measured worse and that `AVSampleBufferDisplayLayer`
  beats Metal on iOS.
- Moving viewport math off the main thread. It costs ~0.13 µs.
- Replacing the telemetry arrays with ring buffers.
