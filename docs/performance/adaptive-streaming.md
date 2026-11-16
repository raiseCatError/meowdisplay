# Adaptive Automatic streaming (issue #123): design and phase 1 logic

**Status: phase 1. Pure logic and tests only. Nothing in the app calls this code yet.** Nothing here has
been measured on hardware. The simulation in `MacTests/AdaptiveStreamingSimulation.swift` is a model
for exercising the controller, not evidence of real-world gains.

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
| auto | keepQuality (the higher-quality override) | any | normal |
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
| Raster scale (of native, post-`DecodeCeiling`) | 0.5, 0.625, 0.75, 0.875, 1.0 | 1.0 | max(floor, 0.75) | **capture restart** (rate-limited) |
| Bitrate | 2, 3, 4, 6, 8, 10, 12, 15, 18, 24 Mbps | 18 Mbps | 6 Mbps | encoder reconfigure (VT session recreate + keyframe) |
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
- encode queue depth and age
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
| Healthy for 5 windows, 10 s after the last change, no oscillation back-off | one upshift, as a probe: raster up to the floor → FPS up to 60 → raster up → bitrate up → 90/120. Strict order: only the first dimension below its top (and not backed off) is tried. Without headroom, hold. |
| A bad window during a probe | revert at once. That dimension is backed off for 30 s, doubling up to 600 s. |
| 3 healthy windows during a probe | `probeConfirmed`; that dimension's back-off is reset |

**Headroom** needed before an upshift:

- Network: backpressure ≤ 0.02, RTT ≤ 1.25 × baseline + 10 ms, and jitter ≤ 0.5 × the new frame
  interval.
- Pipeline: encode queue age and decode p95, each scaled by the new pixel count, ≤ 60 % of the new
  frame interval.
- Rates above 60: the source must produce at least 90 % of the tier.

**Stability.** Raster changes restart capture, so they are spaced at least 20 s apart (6 s for a
severe downshift). A raster step that is rate-limited holds (`restartRateLimited`). It does not skip
ahead to a cut from 60 to 30 FPS. Three direction flips within 120 s block upshifts for 60 s. This
back-off doubles each time, up to 600 s.

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
| Comparison with today's fixed policy | **SIMULATION only** (`$C/reports/123-adaptive-simulation.md`), using an assumed plant |
| The thresholds suit real Macs, receivers and networks | **PENDING HARDWARE**: none of them is tuned |
| Real cost of a bitrate change (VT session recreate) vs a raster change (capture restart) | known from the code (`MacSenderVideoEncoder` recreates the session for any change). The latency cost is **unmeasured**. |
| Effective-refresh, cost and telemetry inputs exist on the wire | **not yet**: phase 2 (optional keys, no welcome feature) |

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
