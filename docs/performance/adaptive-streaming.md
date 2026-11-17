# Adaptive Automatic streaming (issue #123): design, phase 1 logic and phase 2 wiring

**Status: phase 2. The controller is wired into the pipeline behind a Mac setting, "Adaptive
Automatic (Beta)", which is off by default.** Off means today's fixed Automatic policy, byte for
byte. "Use less data" works with the switch off too. Nothing here has been measured on hardware:
every threshold, and any real-world benefit, is **PENDING HARDWARE**. The simulation in
`MacTests/AdaptiveStreamingSimulation.swift` is a model for exercising the controller, not
evidence of real-world gains; its comparison table is in
[`adaptive-streaming-simulation.md`](adaptive-streaming-simulation.md). Section 9 describes the
wiring; section 10 the fixes from the QA 94fdc717 review.

Today, Automatic is a fixed policy (`StreamingModePolicy`): Performance profile, Balanced priority,
Auto codec, Best quality (native raster, 18 Mbps), and the frame rate from `StreamingFPSPolicy`. Phase 1
adds three pure, Foundation-only pieces under `Shared/` that a later phase can wire into the pipeline:

| File | Role |
|---|---|
| `Shared/RefreshNegotiation.swift` | Capability ceiling and starting FPS from every stage. Observed performance is not an input. |
| `Shared/NetworkCost.swift` | Reachability, interface and cost as separate dimensions. Combines sender and receiver evidence into a data policy (normal or saver). Holds the once-only metered suggestion tracker. |
| `Shared/AdaptiveStreamingModel.swift` | Value types: operating point, ladder, thresholds, sample, decision, evidence. |
| `Shared/AdaptiveStreamingController.swift` | The deterministic state machine for one receiver. |

All types are `Sendable` value types. The controller takes the caller's timestamps, so it has no timers,
no globals and no shared state. Each receiver owns its own instance.

## 1. Refresh/FPS negotiation

Inputs: display mode; the source's distinct-frame cadence (Mirror: the physical display's active mode;
Extend: the virtual display's supported refresh; Window view: the compositor's frame budget); the
receiver's `hello.maxFPS`; the receiver's **effective** refresh (new optional input, see §6); the user
ceiling; the profile; H.264's macroblock ceiling at the actual raster (`EncoderCapability`); an
optional receiver decoder pixel rate; the product ceiling of 120.

Rules:

- **Legacy peer** (the receiver sends no effective refresh): the result is exactly today's
  `StreamingFPSPolicy.commonTargetFPS` + `codecEffectiveFPS`. There is no source cap and no
  60-first start. A test checks this across 25,920 input combinations.
- The ceiling is the minimum of all stage limits. An unknown source counts as 60 Hz.
- Never target above the source cadence. A 60 Hz display mirrored to a 120 Hz iPad gets a ceiling of 60.
  Today it gets 120.
- **60 first.** The initial target is the highest allowed rate at or below 60.
- 90 and 120 are allowed only when every stage supports them, the source cadence is known, and the
  tier divides the source cadence evenly. A 120 Hz source allows 60 and 120, not 90.
- The rates below 60 are 20 and 30. When a stage limits the ceiling below 60 (for example H.264 at
  5K), the ceiling itself is also allowed.
- The output keeps `capabilityCeilingFPS` and `initialTargetFPS` separate from any observed
  performance. `legacyFPS` is always included for the fallback.

## 2. Network cost model

There are four independent dimensions. No dimension implies another:

| Dimension | Values | Never inferred from |
|---|---|---|
| Reachability | local / remote / unknown | cost |
| Interface | wifi / wired / cellular / tunnel / unknown | reachability (a tunnel is not cellular) |
| Cost (with confidence low/medium/high) | unmetered / expensive / constrained (Low Data Mode) / unknown | interface (Wi-Fi can be a metered hotspot) |
| Live performance | measured by the controller | the other three |

Confidence levels:

- **high**: the media connection's own path (`NWConnection.currentPath.isExpensive/isConstrained`,
  or the Android `Network` the socket uses).
- **medium**: the process default path, while the media path is not tunnelled.
- **low**: inference, for example a tunnel interface or a route class. Low-confidence evidence never
  changes the policy and never prompts the user.

Combining the two endpoints (`NetworkCost.combine`):

- If either side is clearly metered (≥ medium), the path is metered. The most restrictive clear
  report wins (constrained beats expensive).
- The path is unmetered only when both sides clearly report unmetered.
- Everything else is unknown. Unknown stays unknown.

Data policy (`NetworkCost.dataPolicy`). The "Use less data" preference is checked first:

| Preference | Remembered answer | Clear path cost | Policy |
|---|---|---|---|
| off | any | any | normal |
| on | any | any | saver |
| auto | keepQuality (the higher-quality override) | any | normal (phase 1 rule; the Mac's phase 2 `receiverDataPolicy` still saves on clear Low Data Mode, see "Use less data" below) |
| auto | unanswered / saveData | constrained | saver (Low Data Mode) |
| auto | unanswered / saveData | expensive | saver |
| auto | unanswered / saveData | unmetered, unknown, or low confidence | normal |

When both endpoints report a preference, the more data-saving one wins (on > auto > off). The model
has no "refuse to stream" outcome.

**One-time suggestion** (`NetworkCostSuggestionTracker`): "This connection may use mobile data. Save
data automatically?"

- It asks only when the preference is auto, the answer is unanswered, media is live, and there is
  high-confidence `expensive` evidence.
- It asks at most once per detection episode. An episode ends only after
  `episodeEndGraceSeconds = 120` without the evidence, so a flap or reconnect does not ask again.
- It never asks on unknown, low or medium confidence, or Low Data Mode. Low Data Mode is honoured
  silently.
- It stops after `maxDismissals = 2` dismissals.
- The answer and the dismissal count are `Codable`, so the app can persist them.

## 3. Operating-point ladder

The codec is never changed: it stays as negotiated.

| Dimension | Steps | Start (= today's Best) | Saver top | Change cost in the real pipeline |
|---|---|---|---|---|
| Raster scale (of native, **before** `DecodeCeiling`; a step that would capture the same size as the next higher one is dropped) | 0.5, 0.625, 0.75, 0.875, 1.0 | 1.0 | max(floor, 0.75) | **capture restart** (rate-limited) |
| Bitrate | 2, 3, 4, 6, 8, 10, 12, 15, 18 Mbps (capped at `AdaptiveStreamingLadder.bitrateCeiling` = today's Best) | 18 Mbps | 6 Mbps | encoder reconfigure (VT session recreate + keyframe) |
| FPS | negotiation `allowedTargets` (20, 30, 60, [90], [120]) | `initialTargetFPS` (≤ 60) | 60 | live capture update (`applyEffectiveFPSChange`) |

**Readability floor.** The floor is the smallest raster step that gives at least *p* encoded pixels
per displayed receiver point. *p* = 1.5 (phone), 1.25 (tablet), 1.0 (desktop), and is never more than
the receiver's own scale. The displayed width is aspect-fit. When the receiver is unknown, the floor
is 0.75. The raster goes below the floor only as `lastResortRasterBelowFloor`, after FPS and bitrate
have no lower option.

Examples: iPad 11" in Extend → 0.625. iPhone (852 pt @3x) in Extend → 0.75. A 1512 pt Mac mirrored to
an iPad → 0.5.

## 4. Controller: inputs, causes and decisions

**Inputs** (`AdaptiveStreamingSample`, one per window, all optional unless marked):

- generation and route epoch (required)
- mode and window start/end (required)
- unique source FPS
- capture, encoded, delivered, decoded and enqueued FPS
- encode queue depth and age (the age is the sender's measured mean submit → output encode
  latency)
- drops (encoder / network / receiver-late)
- RTT, jitter
- send backpressure (the fraction of the window at the pending-send cap)
- decode p95
- presentation queue age
- stall count
- payload bytes/s
- thermal state of each endpoint
- power state
- data policy
- active and floating pane counts

The receiver's size, scale and size class are in the configuration.

**Classification**, in priority order. Ratio checks run only when ≥ 10 unique frames/s are expected.

| Cause | Evidence (named thresholds in `AdaptiveStreamingThresholds`) | Severe (acts in 1 window) |
|---|---|---|
| thermal | either side `serious` or worse | `critical` |
| encoder | queue age > 2 frame intervals, encoder drops ≥ 5 %, or encoded < 90 % of expected without backpressure | backpressure ≥ 0.5, ≥ 2 stalls, or delivery < 50 % |
| decoder | decode p95 > 85 % of a frame interval, decoded < 90 % of delivered, or presentation queue > max(3 intervals, 50 ms) | same |
| network | backpressure ≥ 0.15, network drops ≥ 5 %, or (RTT > 1.6 × baseline and +25 ms, or jitter > 1 interval) while delivery < 90 % | same |
| sourceLimited | source unique < 50 % of the target, with no problem above | never |
| healthy | delivery ≥ 95 % of expected | — |
| none | short delivery with no attributable cause | — |

**Decision table** (one change at most per window; every decision carries a reason code and evidence):

| Situation | Response |
|---|---|
| Custom mode | `bypass`, point nil (Custom settings apply unchanged) |
| Explicit user override | `bypass` with the override point |
| Peer without receiver telemetry | `fixedPolicy`: raster 1.0, 18 Mbps, today's FPS, always |
| Sample from an older generation / route epoch | hold (`staleGeneration` / `staleRouteEpoch`) |
| Sample from a newer generation | `reset` to the initial point, all history cleared |
| Invalid window (short, long, out of order, wrong mode, missing delivery FPS) | hold (`insufficientData`) |
| No sample for 6 s | hold (`staleTelemetry`); after 15 s, streaks are also discarded |
| New route epoch | hold for 4 s (`routeChangeSettling`); RTT baseline and streaks are forgotten; an unconfirmed probe is reverted |
| Data saver / thermal / Low Power / Window panes > 1 lower the ladder top | `policyClamp` immediately (may move several dimensions at once) |
| Network, confirmed (2 windows, or 1 if severe) | bitrate down while ≥ 0.02 bits/pixel/frame → FPS above 60 down → raster down to the floor → FPS below 60 → bitrate to minimum → raster below the floor |
| Encoder or decoder overload, confirmed | FPS above 60 down → raster down to the floor → FPS down → raster below the floor. The bitrate never changes. |
| Thermal (serious), confirmed | FPS above 60 down → raster down to the floor → FPS down. Critical also clamps FPS ≤ 30 and raster ≤ max(floor, 0.75). |
| Source limited | hold. No downshift and no upshift credit (the healthy streak is frozen). |
| Healthy for 5 windows, 10 s after the last change, no oscillation back-off | one upshift, as a probe: raster up to the floor → FPS up to 60 → raster up → bitrate up → 90/120. The first step in that order with headroom is taken: a raster step that can't rise (no headroom, or the restart limit) falls through to the cheaper bitrate step. 90/120 is tried only when nothing below it is waiting. Without headroom anywhere, hold. |
| A bad window during a probe (any problem cause, or short delivery with no attributable cause) | revert at once. That dimension is backed off for 30 s, doubling up to 600 s. |
| 3 healthy windows during a probe | `probeConfirmed`; that dimension's back-off is reset |

**Headroom** needed before an upshift:

- Network: backpressure ≤ 0.02, RTT ≤ 1.25 × baseline + 10 ms, and jitter ≤ 0.5 × the new frame
  interval.
- Pipeline: decode p95 ≤ 60 % of the new frame interval, and the encode latency ≤ 60 % of its
  overload limit (2 new frame intervals: the sender keeps two encodes in flight), each scaled by
  the new pixel count.
- **Missing pipeline evidence is "unknown", not "no".** The default display-layer receiver path
  sends no decode time. Then an FPS or raster upshift also needs the network headroom above and
  waits `minDwellSecondsWithoutPipelineEvidence` (20 s) after the last change instead of 10 s; a
  probe that then leaves delivery short is reverted.
- FPS: the capture must be saturated (source frames ≥ 90 % of the current target). The capture
  runs at the current target, so it can't show more source frames than that; whether the source
  can reach a tier at all is in the negotiation (90/120 only from a source whose refresh allows it).

**Stability.** Raster changes restart capture, so the controller spaces them at least 20 s apart
(6 s for a severe downshift). A raster step that is rate-limited holds (`restartRateLimited`). It
does not skip ahead to a cut from 60 to 30 FPS. Three direction flips within 120 s block upshifts
for 60 s (a policy clamp counts as a downward move). This back-off doubles each time, up to 600 s.
In the app, the coordinator also enforces one limit per receiver over the capture restarts it asks
for (section 10): a raise of the raster waits until 20 s after the previous one of those restarts.
The controller's own lower raster (a severe step down or a probe revert) is not held there, so it
applies when the controller decides it. Restarts from outside the coordinator (rotation, capture
recovery, Video On, the lock screen capture move, user setting or mode changes) are neither limited
nor counted.

## 5. Safety and fallback

- **Older peers:** a peer without the effective-refresh key gets today's FPS. A peer without receiver
  telemetry gets today's fixed Automatic point, unchanged.
- **Custom mode** bypasses the controller. An **explicit override** always wins.
- **Data saving** lowers the ladder top. It never stops a stream.
- **Isolation:** each receiver has its own value-type controller. A test runs two controllers side by
  side and checks that each one matches its solo run.
- **Determinism:** the same inputs give the same decisions. Tests check this for the controller and
  for every simulated scenario.

## 6. Simulated vs unverified

| Claim | Status |
|---|---|
| Negotiation matches today's FPS for legacy peers | unit-tested (pure) |
| Controller rules (causes, floor, hysteresis, clamps, isolation, determinism) | unit-tested (pure) |
| Comparison with today's fixed policy | **SIMULATION only** ([`adaptive-streaming-simulation.md`](adaptive-streaming-simulation.md)), using an assumed plant, with samples built by the production builder |
| The thresholds suit real Macs, receivers and networks | **PENDING HARDWARE**: none of them is tuned |
| Real cost of a bitrate change (VT session recreate) vs a raster change (capture restart) | known from the code (`MacSenderVideoEncoder` recreates the session for any change). The latency cost is **unmeasured**. |
| Effective-refresh, cost and telemetry inputs exist on the wire | phase 2: optional keys, no welcome feature (PROTOCOL.md 6.20); encode/decode unit-tested, never run against a real device |

## 7. Phase 2 (wiring) outline

This depends on the stream-diagnostics hooks being built in a separate workstream. The full plan is in
the campaign report. Summary:

- The receiver adds optional keys to messages that already exist: in `hello`, the effective refresh,
  a cost hint and a data preference; in `stats`, the windowed telemetry. No welcome feature is added.
  When a key is absent, the old behaviour applies.
- `MacSender` keeps one controller per pipeline. It feeds the controller from its stats window,
  `pipelineState` drops, the receiver `stats` message and `reportRoute`. It applies:
  - bitrate through the encoder-session recreate;
  - FPS through `applyEffectiveFPSChange`;
  - raster through the existing `reconfigure` path.

## 8. Open questions found in phase 1

- **The bitrate top was above today's.** Resolved in phase 2 (lead decision): the ladder stops at
  `AdaptiveStreamingLadder.bitrateCeiling`, today's Best target of 18 Mbps, and the phase 2 planner
  clamps to it again. A step above it needs measured quality evidence first.
- **The thermal response depends on the model.** The simulated thermal penalty is mild, so the fixed
  policy shows no stalls there. The adaptive controller trades raster and FPS for heat. Whether that
  trade is right needs hardware thermal traces.
- **Legacy peers can't use the FPS ladder.** A peer with telemetry but without the effective-refresh
  key has a single allowed rate, today's. So FPS clamps (thermal, saver) cannot lower it. Phase 2
  should send both keys together.

## 9. Phase 2: what is wired

Files: `Shared/AdaptiveStreamingWiring.swift` (wire keys, receiver state, path-to-cost mapping,
the receiver data policy rule, the diagnostics decision record), `Mac/AdaptiveStreamingSession.swift`
(settings key, planner, per-receiver coordinator, usage monitor). Tests:
`MacTests/AdaptiveStreamingWiringTests.swift`. Wire keys: PROTOCOL.md 6.20.

**The Beta switch.** Settings ▸ Streaming ▸ Adaptive Automatic (Beta) (`adaptiveAutomaticBeta`,
off by default, shown only in Automatic). Changing it rebuilds the streams, like a Streaming Mode
change. It is also the owner's hardware A/B switch. Custom never runs the controller.

**One coordinator per receiver.** Each `MacSender` (one per receiver) owns an
`AdaptiveStreamingCoordinator`. Its plan (`AdaptiveStreamingPlan`: raster scale, bitrate, FPS cap)
is nil unless the controller manages this receiver or "Use less data" is active, and nil always
means today's values. A decision can only reach the pipeline that owns the coordinator.

**Inputs.**

| Input | Source |
|---|---|
| Effective refresh, telemetry flag, cost hint, "Use less data", answer | receiver `hello` (re-sent on change) |
| Delivered FPS, decode p95, RTT, RTT jitter, thermal, Low Power | receiver `stats`, every ~2 s while the Mac announces (`ping` key `adaptive`) |
| Captured frames (≈ source unique frames: ScreenCaptureKit only delivers changed frames), encoder/network drops | the sender's ~2 s ping window |
| Encode latency (mean submit → compressed output) | VideoToolbox output callbacks, timed only while the controller runs (`MacSenderPipelineState`, under the lock the encode path already takes) |
| Sent video frames and bytes | video send completions |
| Send backpressure | network drops ÷ (network drops + sent frames) in the window (an approximation of "share of the window at the pending cap") |
| Sender thermal, Low Power | `ProcessInfo` |
| Sender path cost, route epoch | `MacSenderTransportController.reportRoute` (the live media connection's `NWPath`); the epoch bumps on a route or cost change |
| Source cadence | Mirror: the mirrored display's mode refresh (screen maximum when the mode says 0); Extend: the virtual display's refresh; Window view: none (no source cap). Below 24 Hz the reading counts as unknown (no cap). Also set as the diagnostics `sourceRefreshHz`, so the "source refresh limited" verdict can fire |
| Generation | the connection generation: a reconnect resets the controller and drops telemetry from the old connection |

The controller does not depend on the diagnostics switch.

**Applying a plan change** (`AdaptiveStreamingPlanner.applyPath`, the cheapest path that covers it):

| Change | Path |
|---|---|
| FPS only | live capture update: `applyEffectiveFPSChange()` (`SCStream.updateConfiguration`, then an encoder recreate at the new rate) |
| Bitrate (with or without FPS) | encoder recreate with a keyframe: `applyEffectiveFPSChange(rebuildEncoder: true)` |
| Raster | capture restart for this receiver only (release, stop, start at the new size; the cached frame is discarded). Rate-limited by the coordinator for every origin (section 10). Not used in Window view, whose canvas is fixed: its ladder has no raster steps. A user-driven rebuild (Extend rotation or shape change, recovery) always wins: one that arrives during an adaptive restart is queued and runs right after it; an adaptive restart that arrives during a rebuild waits and runs afterwards only if the capture still has the old raster (`CaptureRebuildArbiter`). Every committed capture start checks its size against the plan and restarts once if a raster change arrived while it was starting |

There is no live `VTSessionSetProperty` bitrate path: that needs hardware validation first
(follow-up). While the lock screen view is shown nothing is applied; the costliest held change is
applied when the view ends (`AdaptiveApplyDeferral`). Frame generations, lock-screen frame validation, ordered control/media, the
`StreamingRestartLedger` (#142) and the H.264 macroblock guard are unchanged: the plan can only
lower today's FPS (`min`), and the H.264 guard is still applied first.

**The source cadence.** With the switch on, the Mac never captures above the source's own refresh
(for example a 60 Hz display mirrored to a 120 Hz iPad runs at 60). The Extend virtual display and
the Window view compositor are still created at today's rate, so the controller can step back up.
Window view sets no source cadence, so it has no source cap.

**Fallbacks.**

| Situation | Behaviour |
|---|---|
| Switch off | today's fixed policy (tested over modes × hellos × source rates × FPS results) |
| Custom | bypass: never managed, never data-saving |
| Receiver without `effHz` + `adaptiveTelemetry` (old iOS/Mac builds, Android) | today's fixed policy, capped at the source cadence while the switch is on |
| Telemetry stops | the controller holds (stale telemetry), then discards its streaks; after 30 s without a sample the receiver gets today's fixed point again (through the usual limits) until telemetry resumes, and then the controller starts again from its initial point |
| Older or equal route epoch | ignored |
| Newer connection generation | controller reset to the initial point |

**"Use less data"** (works with the switch off). The receiver sends its setting and answer in
`hello`; the Mac combines both endpoints' cost evidence (`NetworkCost.combine`) and applies
`NetworkCost.receiverDataPolicy`: saver when the setting is On; in Automatic, saver on clear Low
Data Mode, or on a clearly metered path once the user accepted the one-time suggestion (until
answered, a metered path stays normal and the receiver asks). A receiver that sends no setting
(older builds, Android) is never data-saving. Mac-side evidence counts only for Low Data
Mode set on the Mac (`NetworkCost.macSidePolicyEvidence` drops a Mac `expensive` report); the Mac
reads its own path on hello, before the first capture is configured. Off is full quality always,
Low Data Mode included. The Full Quality / "No" answer only covers mobile data: in Automatic, clear
Low Data Mode still saves. A policy change keeps the controller and its history
(`AdaptiveStreamingController.setDataPolicy`, never a new controller). A change toward saving
applies at once; a return to full quality waits for the saver dwell (section 12). Only the raster
part of the plan a change leads to can wait: a raster raise comes at most once per
`minRestartIntervalSeconds` (20 s) per receiver, re-evaluated every tick (latest wins), while the
FPS and bitrate parts apply at once (bitrate still within its own 4 s limit). A change before the
first capture applies at once in full. Saver with the switch off is a static point that reuses an
existing quality level: Balanced raster and bitrate (75 %, 10 Mbps), at most 60 FPS. With the switch
on, the controller's saver clamp applies instead (raster ≤ max(floor, 0.75), 6 Mbps, 60 FPS).
The iOS suggestion uses `NetworkCostSuggestionTracker`: high-confidence `expensive` evidence on
live media only, once per episode, never on Low Data Mode or a tunnel, answer remembered and
changeable in Settings ▸ Display ▸ Use Less Data (Ask / Save Data / Full Quality). The Mac Receiver
has the setting (Streaming ▸ Data, Automatic / On / Off) and sends `saveData` but never an answer
and never asks (`UseLessDataReporting.preferenceOnly`), so its Automatic saves only on clear Low
Data Mode. Android: not implemented (parity gap).

**Explainability.** Every controller decision with a new reason, and every change, goes to the
diagnostics recorder (`StreamDiagnosticsSnapshot.adaptiveDecisions`, last 32, also in the export:
codes and numbers only) while diagnostics are on. Each plan change writes one log line
(`adaptive: <old> → <new> path=… decision=… data=…`); nothing is logged per frame.

**Data accounting.** Settings ▸ Streaming ▸ Current Stream shows, per device, the video payload
sent since the stream started and its average rate, labelled as app payload (not what a carrier
bills: no TLS/QUIC/IP overhead or retransmits), and the active adaptive or data-saving point.

**Known gaps (phase 2).**
- The receiver sends `deliveredFps`, `dec95` (Metal path only), `jit`, `thermal`, `lowPower`;
  `decodedFps`, `enqFps`, `presAge` and `late` are defined but not sent yet, so the decoder cause
  rarely fires on the default display-layer path.
- Window view pane counts are not fed (the pane clamp never fires), and Window view has no source
  cap (no source cadence is set there).
- The first ~2 s of a session run today's FPS until the controller's first tick (60-first then
  applies as a live FPS update).
- Without `dec95` the decoder cause can't be told from other short delivery, so a decoder-limited
  receiver on the display-layer path is held, not stepped down (the simulation shows this).
- Everything in "PENDING HARDWARE" in section 6, plus: the cost of a live FPS update and of a
  per-receiver capture restart on real Macs, and whether 2 s `stats` change anything measurable.

## 10. Review fixes (QA 94fdc717, review A)

- **Recovery (A1).** The sender's encode latency now reaches the controller, missing decode time is
  handled as unknown (see Headroom), a raster step that can't rise falls through to bitrate, and a
  probe with unexplained short delivery reverts. The production sample builder
  (`AdaptiveStreamingCoordinator.makeSample`) is the only one: the simulation and the tests use it,
  and `AdaptiveStreamingSample.controllerFieldUse` lists, for every sample field, whether production
  sets it or what the fallback is (a test checks the list against the builder).
- **One limiter per receiver (A3, A8).** The coordinator gates every plan change before it reaches
  the pipeline: at most one capture restart per 20 s and one bitrate change per 4 s, whatever the
  origin (controller step, policy clamp, data policy, reset on reconnect, a receiver flipping its
  telemetry keys). Held parts are re-evaluated every tick against the latest wanted plan; FPS
  passes at once. A raster change that keeps the captured size is not a restart. Changed by the
  review of ddcef384 (section 11): the controller's own lower raster is never held, and the limit
  counts from when an adaptive restart really ran. Capture restarts that do not come from the
  coordinator (rotation, recovery, Video On, the lock screen capture move) are not limited or
  counted.
- **Native size (A4).** The controller's raster 1.0 is the size before the decode ceiling; the
  H.264 FPS guard uses the size actually encoded at the top raster. Steps that would capture the
  same size are dropped, so a 5K display mirrored to an iPad with a 4096×2304 ceiling has the
  ladder 0.5, 0.625, 0.75, 1.0, and its configuration no longer changes with each restart.
- **Started size (A5).** The coordinator records the size a capture really started at and checks
  it against the plan's size, instead of trusting the scale read at preparation time.
- **Legacy peers (A6).** With the switch on, the Mirror/Extend source cap applies to every receiver,
  old ones included (documented in PROTOCOL.md 6.20). With it off, a matrix test runs the
  production resolver (`MacSender.effectiveFPS(today:adaptive:)`) and gets today's FPS everywhere.
- **Lock screen and other rebuilders (A7).** A change held by the lock screen view is applied when
  the view ends. Capture recovery, the lock screen capture move, Video On and Mirror display changes
  still start capture outside `CaptureRebuildArbiter`; an adaptive restart that finds capture
  already restarted by one of them (the "already active" error) leaves it running instead of
  entering recovery, and that start's commit re-checks the raster.
- **Re-hellos (A9).** Receivers re-send hello only for a change the Mac uses, at most once per 5 s,
  latest values (PROTOCOL.md 6.20).
- **Off costs nothing.** With the switch off and no data saving: no input building, no replanning,
  no `stats` telemetry parsing, no encode timing, and video sends are counted without a lock (the
  Settings payload figure is published once per ping). A test counts the coordinator's work.
- **A10.** Fixed by the review of ddcef384 (section 11) in `restartCaptureForAdaptiveRaster` only;
  `reconfigure` still writes the same capture fields off `queue` (left for a separate fix).

## 11. Review fixes (ddcef384, review of the recovery fix)

- **Switch off stays today's behaviour (F1).** A capture start notes the size it started at and
  re-reads the source size and ceiling to compare. With the switch off and no data saving, that
  re-read could disagree with how the capture was sized (a display-mode change or a missing mode in
  between) and restart capture once. `captureNeedsRasterRestart` is now false until some plan has
  asked for a raster other than today's (`hasManagedRaster`), so the post-start re-check, the
  deferred restart after a rebuild and the restart itself can't run, log or defer anything then. A
  test drives the real re-check in a `MacSender`, and the switch-off matrix test now also starts a
  capture whose noted size disagrees.
- **Protective steps are never held (F2).** The 20 s limit holds raster raises only; the
  controller's own lower raster (a severe step down or a probe revert) applies at once, so the
  controller never judges windows of a point the pipeline isn't running and never over-corrects.
  As a consequence a receiver flipping its telemetry keys can cause a raise and the step back down
  in one interval (still at most one raise per 20 s).
- **One-dimension decode ceiling (F3).** `AdaptiveCaptureSizing.isClampedByCeiling` uses the same
  rule as `DecodeCeiling.clamp`: both dimensions present and above 0.
- **Telemetry loss (F4).** After 30 s (`telemetryLossSeconds`, five stale periods) without a sample,
  the coordinator stops using the controller's point and today's fixed point returns through the
  usual limits. When samples resume, the controller restarts from its initial point.
- **0 ms round trip (F5).** Receivers send `rtt` in whole milliseconds, so a link under 0.5 ms
  (Thunderbolt, the same Mac) always reports 0, and no baseline was ever set, which blocked every
  step up on the display-layer path. Three 0 samples in a row now make 0 the baseline; one early 0
  (before the first pong) is still ignored. Mac side only, so older receivers benefit; the wire is
  unchanged.
- **Limiter gaps (F6).** Every adaptive raster restart (from a plan change, the post-start re-check,
  the end of the lock screen view or a finished rebuild) records when it really began, for the
  coordinator's limits and the controller's own restart spacing. A data-policy change applies at
  once and only its raster part waits for the limit (since section 12: a change toward saving; a
  return waits for the saver dwell).
- **Lock screen deferral (F7).** A post-start re-check during the lock screen view is held like any
  other adaptive change. Held changes are dropped, not applied, when the sender stops or the
  connection ends; the next capture start re-checks the raster. Frame generations and lock-screen
  frame acceptance are untouched.
- **A10.** `restartCaptureForAdaptiveRaster` now discards the cached frame, releases the stream,
  invalidates the encoder and asks for a keyframe on `queue`.

## 12. Data-policy churn (review of 9ef3878d)

- **The problem.** Since F6 a data-policy change applied at once and only its raster waited. A
  receiver flipping `saveData` (or a flapping `cost` hint) on every hello then cost one pipeline
  update per hello: the FPS cap switching between 60 and today's rate is a live
  `SCStream.updateConfiguration` plus a VideoToolbox session recreate and keyframe; the bitrate part
  was held only because each of those updates restarted the 4 s encoder limit. Capture restarts were
  already bounded by the 20 s limit. Hostile peers have equivalent levers (`maxFPSRequest`), so this
  was a robustness problem for buggy or flapping receivers rather than a new attack.
- **The fix: one gate (`requestDataPolicy`).** Toward saving: at once, as before. Back to full
  quality (Automatic only): once saving has been in effect for `saverMinimumDwellSeconds` (20 s,
  counted from when saver was applied with a capture running) and, if the return restarts capture,
  once the restart limit allows it (at most one more 20 s), so the return lands as one restart.
  Nothing is stored while it waits: the evidence (`dataPolicy`) keeps the latest request and every
  hello, route change and tick re-offers it, so the last request always wins. Saving set before the
  first capture is left at once. Old receivers and Custom are unchanged; the state is per receiver.
- **What it bounds (simulation, `AdaptiveDataPolicyChurnTests`, coordinator updates handed to the
  sender).** 20 flips per second for 120 s: Mirror/Extend 2,400 updates before (about 2,393 FPS
  updates, 6-7 restarts), 13-15 after (6-7 restarts); Window view 2,400 before, 16-17 after. One flip
  per 5 s for 600 s: Mirror 195 before, 75 after (30 restarts both); Window view 120 before, 89
  after. A cost hint flapping every 0.3 s for 90 s: 301 before, 9 after. Capture restarts stay at
  most one per 20 s either way for these cases (switch off, or no telemetry). With the switch on and
  telemetry, turning saving on can lower a raster the controller raised a moment before: at most two
  restarts per 20 s. A re-check restart that never produces the planned size stops after two retries.
- **Residual.** A receiver that keeps flipping slower than the dwell still costs about one restart
  per 20 s (the limiter's bound). A cost blip after a long saving spell (an Android Activity
  recreation can briefly send no `cost`) is one return and one re-entry; the dwell absorbs the next.
- **Switch-off state after saving (part 3).** The re-check gate `hasManagedRaster` was sticky for
  the sender's life, so after a "Use less data" episode with the switch off a capture start whose
  noted size disagreed could still be restarted. It now clears when a capture with no plan is noted
  at today's size, and is set again by the next plan that asks for another raster.
