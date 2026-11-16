# Performance Lab (#123)

A repeatable way to benchmark MeowDisplay streaming on real hardware: a
deterministic source fixture, fixed scenarios, timed trials made of whole
diagnostics windows, a run bundle per run, and an analysis tool that writes
the issue's standard report. It sits on top of the streaming diagnostics
(`docs/performance/diagnostics.md`) and changes nothing in capture, encoding,
transport or presentation.

No benchmark numbers are recorded in this document or in the repository.
Every measurement listed under [Pending hardware](#pending-hardware) still
has to be made on real devices.

Code: `Shared/PerformanceLab*.swift` (pure model, workload schedule,
frame-ID codec and reader), `Mac/PerformanceLab*.swift` (fixture window, run
controller, panel, synthetic self-test), `tools/perf-lab/` (analysis tool,
scenario catalog, golden files). Tests: `MacTests/PerformanceLab*Tests.swift`,
`tools/perf-lab/test_perf_lab.py`.

## Parts

### Source fixture (Mac)

Performance Lab panel → **Open Fixture Window**. It is never opened
automatically. The window draws one of six versioned workloads
(`PerformanceLabWorkload`, seed fixed, schedule fixed):

| workload | what changes | signature |
| --- | --- | --- |
| `frame-counter` | every display refresh: counter, moving bar | `frame-counter@1:counter/60` |
| `static-to-motion` | 4 s still, 4 s full-frame motion, repeating | `static-to-motion@1:still/4,highMotion/4` |
| `scrolling-text` | generated fine text scrolling at 120 pt/s | `scrolling-text@1:scrollingText/60` |
| `high-motion` | 16×9 cells, every cell recoloured every frame | `high-motion@1:highMotion/60` |
| `cursor-target` | a 24 pt target on a fixed 4 s path over a still page | `cursor-target@1:cursorTarget/60` |
| `idle` | nothing after the first frame | `idle@1:still/60` |

The text is pseudo-words from a fixed syllable table: no user content. A
frame ID is the number of frames the fixture actually changed, so a still
segment keeps its ID and stays truly static.

**Frame-ID strip.** Every fixture frame carries, across its full width, a
one-row barcode of large black/white modules (`PerformanceLabFrameIDCodec`):
quiet zone, guard `101`, 4-bit magic, 4-bit segment, 20-bit frame counter in
Gray code, CRC-16/CCITT, guard `101`, quiet zone; 54 modules wide, 4 modules
tall, with the counter also shown as text. Luma only, so chroma subsampling
does not matter; tests decode it after scaling (3 to 51 px per module),
noise, blur, video-range levels, BGRA colour and inside cluttered Window view
content, and find no false positives in random or bar-pattern images.

### Receiver frame-ID reader

`PerformanceLabFrameIDProbe` reads the strip from decoded frames and records
`receiver.frame_id.*` (read, unique, duplicate, skipped, unreadable,
unexamined, discontinuity, interval between unique IDs) into the receiver's
diagnostics recorder. These travel to the Mac in the existing optional `diag`
summary (`fidU`, `fidDup`, `fidSkip`, `fidBad`, `fidUnx`, `fid95`;
PROTOCOL.md 6.2.1), so the Mac's run bundle holds them.

`skipped` counts only IDs provably missing between two read IDs: a frame that
arrived but could not be read may have carried a missing ID, so it is
subtracted. When the reader loses the strip (30 misses) it re-baselines; the
frames that go by unread while it searches again are `unexamined`, never
skipped. Unique, duplicate and skipped are reported only for windows in which
a strip was read ("n/a" otherwise).

Limitation: a decoded pixel buffer exists only on the receiver's
**experimental Metal path** (`ReceiverVideoPresenter.presentDecoded`). The
default `AVSampleBufferDisplayLayer` path decodes inside the system layer;
reaching its pixels would mean changing rendering, which the lab never does.
So exact frame-ID counts need the Metal renderer turned on (iOS Settings),
which itself changes presentation timing: record it and use the same setting
for every run you compare. Without it, `frame_id_*` metrics read "n/a",
never 0.

Cost: only while diagnostics are on. Unlocked, it probes one frame in 30
(about 96 rows); once it finds the strip it reads two or three rows per frame;
after 30 frames without the strip it goes back to probing.

### Scenarios

`PerformanceLabScenarioCatalog` (also `tools/perf-lab/scenarios.json`, which
a test keeps identical). Each trial = warm-up, then whole 5 s diagnostics
windows. Minimum three trials per run, enforced; default three.

| id | mode | panes | workload | warm-up | measured per trial | needs the operator to |
| --- | --- | --- | --- | --- | --- | --- |
| `mirror.frame-counter` | Mirror | – | frame-counter | 10 s | 30 s | start Mirror |
| `extend.frame-counter` | Extend | – | frame-counter | 10 s | 30 s | start Extend |
| `window.single-pane` | Window | 1 | frame-counter | 10 s | 30 s | add only the fixture as a pane |
| `window.multiple-panes` | Window | 4 | frame-counter | 10 s | 30 s | add the fixture + 3 still windows |
| `window.floating-pane` | Window | float | frame-counter | 10 s | 30 s | float the fixture over a still pane |
| `mirror.static-to-motion` | Mirror | – | static-to-motion | 10 s | 40 s | start Mirror |
| `extend.scrolling-text` | Extend | – | scrolling-text | 10 s | 30 s | note text clarity (subjective) |
| `mirror.high-motion` | Mirror | – | high-motion | 10 s | 30 s | start Mirror |
| `extend.rapid-interaction` | Extend | – | cursor-target | 10 s | 30 s | drag/scroll on the receiver for the whole trial |
| `extend.reconnection` | Extend | – | frame-counter | 10 s | 40 s | disconnect at 10 s, reconnect at 15 s |
| `extend.capture-retune` | Extend | – | frame-counter | 10 s | 40 s | change the FPS cap at 10 s and back at 25 s |
| `extend.transition-cleanup` | Extend | – | idle | 10 s | 60 s | switch Mirror/Extend five times from 5 s |
| `extend.sustained` | Extend | – | high-motion | 30 s | 600 s | keep conditions fixed for 10 minutes |
| `extend.idle` | Extend | – | idle | 10 s | 30 s | move the pointer away |

Each scenario lists its primary metrics (shown first in reports).

### Run controller and run bundle

Settings → System → Streaming Diagnostics → **Performance Lab…** (shown
while diagnostics are on). Pick a scenario, trials (3–20), an optional
variant label (`beta-on`; lowercase letters, digits, dashes), the folder
(default `~/Library/Application Support/MeowDisplay/PerformanceLab`), and
the session if several devices stream. **Start Run**:

1. Setup steps are shown; the run waits for **Ready**.
2. Per trial: per-trial steps (if any) → **Ready** → warm-up → the next
   `trialWindows` whole recorder windows that *start after* the warm-up.
   Prompts for during-trial steps appear on schedule; the run does not wait
   for them. Nothing is automated: no synthetic input, no display, mode,
   network or power change. The panel's 0.5 s poll runs in the common
   run-loop modes, so a held menu or a modal panel does not make it miss a
   window.
3. After the last sender window the trial waits up to two windows for
   receiver windows that began inside it (it stops as soon as the receiver
   reports a window that began after the trial ended).
4. Every planned trial is written whatever happened: `complete`,
   `incomplete` (missing windows, window gap, unexpected restart, no
   receiver summary, stalled), `failed` (no session, diagnostics off) or
   `cancelled` (the trial running when the operator cancelled, even during
   its warm-up, and every later trial with `notStarted`). A run cancelled
   before its first trial began writes nothing.

**Receiver windows.** The receiver sends its last completed 5 s window in
every `stats` (every ~5 s, or ~2 s under adaptive streaming), so one window
usually arrives two or three times. Each window has a number and a series
(new per receiver session), and the trial keeps each (series, number) once,
so receiver sums are sums over distinct windows. A receiver window is kept
only if it provably began inside the trial: the receiver reports the sender
window number it had last heard when the window began (`wps`); a number at
least the one the sender had completed when the trial's first window began
proves it by causality alone, without comparing the two devices' clocks.
`receiverAlignment` is `aligned` when every kept window was proven this way,
`partial` when some were kept by arrival time (at least two windows after the
trial began) because the receiver sent no marker. A receiver that sends no
window numbers at all (an older build) is merged by equality only;
`receiverCounting` is then `possiblyDoubleCounted` and the report says so.
`receiverWindowsMissed` counts window numbers between kept windows that never
arrived.

**Expected restarts.** In scenarios that expect a restart (reconnection,
capture retune, transitions) a window that starts later than the previous one
ended because of a capture or presentation restart is recorded
(`expectedRestarts`, `restartUnmeasuredSeconds`: time no window covers,
because the recorder restarts its window at a restart) and does not make the
trial incomplete; `sender.restart.frame_gap_ms` holds the last frame before
each restart to the first after it. A restart in any other scenario, or a
discontinuity without one, is still `windowGap`/`unexpectedRestart`.

Bundle: `perf-lab-<scenario>-<yyyyMMdd-HHmm>[-<variant>][-synthetic]/`
with `manifest.json` (format `meowdisplay-performance-lab-run`, schema 1:
plan with the full scenario, workload and signature, frame-ID version,
environment, histogram edges, the metric dictionary with every caveat,
classifier thresholds, limitations, trial statuses) and `trial-NN.json`
(format `meowdisplay-performance-lab-trial`, schema 1: every window's
snapshot and verdict, sender histograms merged bucket by bucket over the
trial, summed counters and the gaps of the sender's own interval stages, one
receiver `diag` summary per receiver window kept (with its arrival time
relative to the trial's first window), the receiver alignment and counting
fields above, the fixture's own drawn-frame count and draw intervals when the
fixture was open in this app).

Environment = sender app version, OS and device class, the git commit when
supplied (`--commit`), and the sender's session context at the first measured
window: mode, codec, raster, target FPS, encoder in-flight limit, route
class, protocol, `pathExpensive`/`pathConstrained`. Mac model, receiver model
and OS, network, power and room conditions are not recorded: the operator
writes them into the report.

### One command (QA build already running)

```
python3 tools/perf-lab/perf_lab.py start extend.frame-counter --trials 3 --commit auto
```

It writes `performanceLabStartRequest` into the app's defaults
(`--bundle-id`, default `com.raisecaterror.meowdisplay.mac.debug`) and posts
the Darwin notification `com.raisecaterror.meowdisplay.performance-lab.start`.
The app (only with Streaming Diagnostics on) validates the request, opens the
panel and starts the run at its first operator step. `--dry-run` prints the
two commands. A cold launch can take `-performanceLabScenario <id>
[-performanceLabTrials N]` instead. `perf_lab.py list` lists scenario ids.

### Analysis

```
python3 tools/perf-lab/perf_lab.py validate <bundle>
python3 tools/perf-lab/perf_lab.py report <bundle> [--allow-partial] [--out report.md]
python3 tools/perf-lab/perf_lab.py compare <bundle-A> <bundle-B> [--allow-partial]
```

- Validates format and schema version (refuses others), the metric
  dictionary version, that every listed trial belongs to the run and is
  listed once and within the plan, that each histogram's percentiles match
  its buckets, and privacy: no key may look like personal data and every
  string value, at any depth, must be one the app writes (the allow-list
  ships with the tool in `scenarios.json`, generated from the app; the app
  version, variant, commit and date have strict formats). A listed trial
  whose file is missing, and a planned trial that is not listed, stay in the
  report as `failed` (`missingTrialData`). A trial labelled `complete` must
  list no issues, at least `requestedWindows` windows and a measured time
  above 0, or the bundle is refused (the minimum-trials gate counts complete
  trials). A malformed bundle, a file over 64 MB, a bundle over 128 MB in
  total (a trial of the longest scenario is about 1.8 MB), anything that is
  not a regular file (a FIFO, a folder, a device), a trial file outside the
  bundle folder, any other file-system error, and an `--out` path that cannot
  be written (for example in a missing folder) are refused with exit 2 and
  one line, never a traceback or a hang.
- Per trial: source-unique, capture, submit, encode, send rates; frame time
  at submission p50/p95/p99; capture interval, source age, encode and send
  p50/p95/p99 exact to the bucket; gaps over 100/250/500 ms per interval stage;
  payload Mbit/s (app bytes); encoder-busy holds and send-backpressure drops;
  Window view compose; receiver arrival rate, arrival p95, gaps over 250 ms,
  enqueue rate, presenter queue age; frame-ID unique rate, skipped,
  duplicates, unreadable, unique-interval p95; fixture draw rate; sender CPU
  median and memory max/delta; restarts and route changes; classifier verdict
  per window. Every label says what is measured (for example "enqueued for
  presentation, not presented"; "submit to output", not "latency").
- Across trials, complete trials only: median, p95 and p99 (nearest rank, so
  with fewer than 20 trials p95 is the maximum), min, max, spread, CV. Every
  trial, complete or not, is listed with its values. Fewer complete trials
  than the minimum (3, the tool's own constant; a bundle can raise it, never
  lower it) is refused (exit 2) unless `--allow-partial`, which marks every
  output PARTIAL. No complete trial at all is always refused.
- Receiver sums (gaps, frame-ID counts) are over distinct receiver windows.
  Counters a display mode cannot produce read "n/a", not 0 (capture and
  source-unique rates in Window view, composites outside it).
- `compare`: per metric, A and B median [min–max] (n), B − A and %, and
  "not distinguishable (ranges overlap)" whenever the trial ranges overlap.
  It lists every environment difference and says NOT COMPARABLE for
  different scenarios.
- Reports name bundles by folder name only, never a local path.

## Running a scenario on real hardware

1. Build the candidate (same build for every run you compare). Note the
   commit.
2. Mac: Settings → System → Streaming Diagnostics on. Receiver: Settings →
   Diagnostics → Streaming Diagnostics on. For frame-ID counts, also the
   Metal renderer on the receiver (and in every run you compare).
3. Fix the conditions: power source and battery, display refresh, receiver
   brightness, other apps, network (AP, band, distance; USB/AWDL/LAN/remote),
   thermal state at start. Write them down.
4. Start the session in the scenario's mode.
5. Open the Performance Lab panel, choose the scenario, **Open Fixture
   Window**, move it onto the streamed display and Zoom it (Window view
   scenarios: make it a pane or a float as described).
6. **Start Run** (or `perf_lab.py start …`), follow each step, press
   **Ready**, keep hands off unless the scenario says otherwise.
7. When it finishes, **Show Bundle in Finder**, then
   `perf_lab.py report <bundle> --out report.md`. Fill the "operator to fill"
   lines (hardware, network, subjective observations) by hand.
8. For an A/B question, run both variants with the same conditions,
   alternate or randomise the order, then `perf_lab.py compare A B`.

## Measured vs not measurable

Measured (app level, with the diagnostics caveats): everything in the
analysis list above, on the clocks the metric dictionary names.

Not measurable by the app; needs external equipment or another method:

- **Physical presentation / capture-to-photon / input-to-photon**: needs a
  high-speed camera or photodiode with a stated method and clock sync. The
  fixture's visible counter and strip are designed to be filmed: a camera
  seeing both screens reads the same frame number on each.
- Presentation on glass on the default display-layer path (only "enqueued").
- GPU, hardware encoder/decoder utilisation; network bytes billed (TLS, QUIC,
  IP, tunnels); receiver CPU and memory (in the receiver's own diagnostics
  export, not in the Mac's bundle); audio and A/V sync; video quality metrics
  (PSNR/SSIM/VMAF need matched source frames; not implemented).
- Source display refresh: not read by any hook yet (`sourceRefreshHz`).

## Fairness rules for competitor comparison

Follow issue #123 "Protocol v0", item 5. In short: same hardware, network and
time window; similar *effective* resolution, frame rate and bitrate; record
each product's exact version, settings and licence; randomise order;
separate default-vs-default from tuned-vs-tuned; say when features, codecs or
frame rates are not comparable; never infer a general claim from one setup.
Only metrics with the same definition may be compared: a competitor exposes
none of MeowDisplay's internal stage metrics, so competitor comparisons are
limited to externally measured numbers (camera/photodiode latency, filmed
frame-counter cadence, power draw) and labelled subjective observations.
This repository contains no competitor numbers.

## Privacy of run bundles

Bundles are written only where the operator chooses (default: this Mac's
Application Support), are never uploaded, and contain aggregate numbers and
fixed strings only: enum values, metric ids, the metric dictionary, scenario
text, limitation sentences, the sanitized app version and variant label, the
hex commit, and minute-rounded dates. Numbers include a random receiver
window series per session, never anything tied to the device; no time since
boot. No device or user name, window title,
app name, path, address, SSID, pairing material, input or pixels.
`PerformanceLabRunTests.testRunBundleContainsOnlyReviewedKeysAndConstantStrings`
fails on any unreviewed key, any key that looks like a forbidden kind of
field, or any string that is not a constant from code; the analysis tool
applies the same check to keys and to every string value, with the constants
from `scenarios.json` (generated by `testScenarioCatalogJSONMatchesTheTool`). The session picker shows device names in
the panel only.

## Self-test (software only, SYNTHETIC)

No device, capture, encoder or network. A scripted 60 FPS event stream
(fixed durations and sizes, one 300 ms stall in trial 3, scripted receiver
summaries) goes through the real `StreamDiagnosticsRecorder` and the real
`PerformanceLabRunController` on an injected clock, and is written as a real
bundle. Every output says SYNTHETIC; it validates the harness, not
performance.

- Swift half (checks the bundle byte for byte against
  `tools/perf-lab/tests/golden/synthetic-run/` and the catalog against
  `tools/perf-lab/scenarios.json`):
  `xcodebuild test -scheme OpenSidecarMac -destination platform=macOS -only-testing:OpenSidecarMacTests/PerformanceLabRunTests -only-testing:OpenSidecarMacTests/PerformanceLabScenarioTests -only-testing:OpenSidecarMacTests/PerformanceLabFrameIDTests`
  (add the repository's usual derived-data and code-signing flags).
  `TEST_RUNNER_PERF_LAB_UPDATE_GOLDEN=1` regenerates the golden files after an
  intended change; review the diff.
- Python half: `tools/perf-lab/selftest` (runs
  `python3 -m unittest discover -s tools/perf-lab -p 'test_*.py'`, then
  `perf_lab.py selftest`, which re-renders the report of the golden bundle and
  diffs it against `tests/golden/synthetic-report.md`). Regenerate that report
  with `python3 tools/perf-lab/perf_lab.py report tools/perf-lab/tests/golden/synthetic-run --out tools/perf-lab/tests/golden/synthetic-report.md`.
- The Mac panel's **Run Synthetic Self-Test** writes the same SYNTHETIC
  bundle to the chosen folder.

These are local commands; no CI workflow runs them.

## Pending hardware

Nothing below has been measured. Each needs the scenario run on real devices
with the steps above.

| measurement | scenario(s) | needs |
| --- | --- | --- |
| Source-unique FPS and submission frame-time p50/p95/p99, Mirror and Extend | `mirror.frame-counter`, `extend.frame-counter` | Mac + iPhone/iPad, each route available (USB, AWDL, LAN, remote) |
| Exact frame-ID unique/skipped/duplicate counts | all fixture scenarios | receiver with the Metal renderer on |
| Fixture strip legibility after real HEVC/H.264 encoding at each raster | any | real encoder; check `frame_id_unreadable` stays near 0 |
| Window view compose cost and pacing, 1 / 4 / floating panes | `window.*` | Mac + receiver in Window view |
| Recovery after still screen | `mirror.static-to-motion` | Mac + receiver |
| Scrolling text pacing and clarity (subjective) | `extend.scrolling-text` | Mac + receiver, operator judgement |
| Encoder/network load under full motion | `mirror.high-motion` | Mac + receiver |
| Pacing under live interaction | `extend.rapid-interaction` | operator on the receiver |
| Reconnect gaps and restarts | `extend.reconnection` | a route the operator can drop and restore safely |
| Capture restart cost | `extend.capture-retune` | Mac + receiver |
| Resource cleanup over repeated transitions | `extend.transition-cleanup` | Mac + receiver |
| 10-minute stability, CPU, memory, thermal | `extend.sustained` | Mac + receiver, fixed room and power |
| Idle cost | `extend.idle` | Mac + receiver |
| Overhead of the frame-ID reader on the receiver | any, Metal path, reader on vs off | Instruments on the receiver |
| Capture-to-photon / input-to-photon | any fixture scenario | high-speed camera or photodiode |
| The one-command start and the panel flow on a QA build | any | a running QA build (UI not visually verified) |
| H.264 vs HEVC, priority 1/2/3, 60/90/120 Hz sources, Beta adaptive on/off | any, via `compare` | each configuration on real devices |
