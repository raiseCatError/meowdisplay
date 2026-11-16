### Benchmark run: 2026-11-17 / synthetic-run — SYNTHETIC self-test [SYNTHETIC]

> SYNTHETIC: scripted events, not a measurement. This validates the harness, not performance.

- Status: completed — 3 of 3 trials complete
- Objective/hypothesis: SYNTHETIC: a scripted event stream through the real recorder and run controller. It validates the harness, not performance. (operator: state the hypothesis)
- Apps/versions/commit SHAs + comparator links/licenses: MeowDisplay synthetic, commit not recorded (pass --commit to `start`); no comparator in this bundle
- Sender Mac / receiver hardware and OS: sender macOS 0.0.0 (mac); Mac model, receiver model and OS: not in the bundle (operator to fill)
- Test scenes + script/reference link + duration/warm-up: scenario `synthetic.self-test` v1, fixture workload `frame-counter@1:counter/60`, frame ID v1; warm-up 5 s, then 3 × 5 s windows per trial (docs/performance/performance-lab.md)
- Display mode; stream resolution/refresh/FPS/bitrate/codec/audio: extend; raster 2732x2048; target 60 FPS; codec hevc; encoder in-flight limit 2; source refresh not read by this build; bitrate: see payload below; audio: not recorded
- Transport: route class usb, tcp, expensive=False, constrained=False; control RTT p50 median 4 ms (receiver windows); AP/infrastructure, loss and bandwidth: operator to fill
- Controls: sender thermal states seen: not sampled; power, background apps, shaper: operator to fill
- Trials (n >= 3): all trials listed, raw evidence below

| trial | status | issues | measured s | windows | receiver windows | raw evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | complete | none | 15.02 | 3 | 3 | `synthetic-run/trial-01.json` |
| 2 | complete | none | 15.00 | 3 | 3 | `synthetic-run/trial-02.json` |
| 3 | complete | none | 15.00 | 3 | 3 | `synthetic-run/trial-03.json` |

- Results: statistics over complete trials only (median; p95/p99 are nearest-rank over trials, so with fewer than 20 trials p95 is the maximum; spread = max − min; CV = sample stdev / mean). Per-trial values list every trial.

Primary metrics:

| metric | unit | median | p95 | min–max | spread | CV | n | per trial (all, in order) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Sender: source-unique submissions (new capture PTS) (`source_unique_fps`) | frames/s | 57.99 | 58.01 | 56.87–58.01 | 1.14 | 1.1% | 3 | T1 58.01, T2 57.99, T3 56.87 |
| Sender: frame time at encoder submission, p95 (`submit_interval_p95_ms`) | ms | 16.67 | 17 | 16.67–17 | 0.33 | 1.1% | 3 | T1 16.67, T2 16.67, T3 17 |
| Sender: encode, submit to output, p95 (`encode_p95_ms`) | ms | 8.25 | 8.50 | 8–8.50 | 0.50 | 3.0% | 3 | T1 8, T2 8.25, T3 8.50 |
| Sender: video payload sent (app bytes, no transport overhead) (`payload_mbps`) | Mbit/s | 9.73 | 9.73 | 9.53–9.73 | 0.19 | 1.2% | 3 | T1 9.73, T2 9.73, T3 9.53 |
| Receiver: frame arrivals (median of its 5 s windows) (`receiver_arrival_fps`) | frames/s | 59.30 | 59.50 | 59.10–59.50 | 0.40 | 0.3% | 3 | T1 59.50, T2 59.30, T3 59.10 |
| Receiver: unique fixture frame IDs at decode handoff, Metal path (median) (`frame_id_unique_fps`) | frames/s | 57 | 57.50 | 56.50–57.50 | 1.00 | 0.9% | 3 | T1 57.50, T2 57, T3 56.50 |
| Receiver: fixture frame IDs provably missing between two read IDs (sum over its distinct windows) (`frame_id_skipped`) | frames | 6 | 9 | 3–9 | 6 | 50.0% | 3 | T1 3, T2 6, T3 9 |

All metrics:

| metric | unit | median | p95 | min–max | spread | CV | n | per trial (all, in order) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Sender: ScreenCaptureKit complete frames (`capture_complete_fps`) | frames/s | 59.99 | 60.00 | 58.80–60.00 | 1.20 | 1.2% | 3 | T1 60.00, T2 59.99, T3 58.80 |
| Sender: encoder submissions, all origins (`submitted_fps`) | frames/s | 59.99 | 60.00 | 58.80–60.00 | 1.20 | 1.2% | 3 | T1 60.00, T2 59.99, T3 58.80 |
| Sender: encoder outputs (`encoded_fps`) | frames/s | 60.00 | 60.05 | 58.80–60.05 | 1.25 | 1.2% | 3 | T1 60.00, T2 60.05, T3 58.80 |
| Sender: video sends completed (local stack accepted) (`sent_fps`) | frames/s | 59.99 | 60.00 | 58.80–60.00 | 1.20 | 1.2% | 3 | T1 60.00, T2 59.99, T3 58.80 |
| Sender: duplicate submissions (same capture PTS) (`duplicate_submit_fps`) | frames/s | 2.00 | 2.00 | 1.93–2.00 | 0.07 | 1.9% | 3 | T1 2.00, T2 2.00, T3 1.93 |
| Sender: complete-capture interval p95 (`capture_interval_p95_ms`) | ms | 16.67 | 17 | 16.67–17 | 0.33 | 1.1% | 3 | T1 16.67, T2 16.67, T3 17 |
| Sender: frame time at encoder submission, p50 (`submit_interval_p50_ms`) | ms | 16.67 | 17 | 16.67–17 | 0.33 | 1.1% | 3 | T1 16.67, T2 16.67, T3 17 |
| Sender: frame time at encoder submission, p99 (`submit_interval_p99_ms`) | ms | 16.67 | 17 | 16.67–17 | 0.33 | 1.1% | 3 | T1 16.67, T2 16.67, T3 17 |
| Sender: submission gaps over 100 ms (may be idle source) (`submit_gaps_over_100ms`) | gaps | 0 | 1 | 0–1 | 1 | 173.2% | 3 | T1 0, T2 0, T3 1 |
| Sender: submission gaps over 250 ms (may be idle source) (`submit_gaps_over_250ms`) | gaps | 0 | 1 | 0–1 | 1 | 173.2% | 3 | T1 0, T2 0, T3 1 |
| Sender: submission gaps over 500 ms (may be idle source) (`submit_gaps_over_500ms`) | gaps | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |
| Sender: capture PTS to encoder submit, p95 (`source_age_p95_ms`) | ms | 10 | 10 | 10–10 | 0 | 0.0% | 3 | T1 10, T2 10, T3 10 |
| Sender: encode, submit to output, p50 (`encode_p50_ms`) | ms | 7 | 7 | 7–7 | 0 | 0.0% | 3 | T1 7, T2 7, T3 7 |
| Sender: encode, submit to output, p99 (`encode_p99_ms`) | ms | 8.25 | 8.50 | 8–8.50 | 0.50 | 3.0% | 3 | T1 8, T2 8.25, T3 8.50 |
| Sender: send, handed to transport to completion, p95 (`send_p95_ms`) | ms | 2 | 2 | 2–2 | 0 | 0.0% | 3 | T1 2, T2 2, T3 2 |
| Sender: frames held because the encoder was busy (`encoder_busy_holds`) | frames | 7 | 8 | 7–8 | 1 | 7.9% | 3 | T1 8, T2 7, T3 7 |
| Sender: frames dropped for send backpressure (`send_backpressure_drops`) | frames | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |
| Sender: Window view compose p95 (CPU side) (`compose_p95_ms`) | ms | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Sender: Window view composites (`composites_fps`) | frames/s | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Receiver: arrival interval p95 (median of its 5 s windows) (`receiver_arrival_p95_ms`) | ms | 20 | 21 | 19–21 | 2 | 5.0% | 3 | T1 19, T2 20, T3 21 |
| Receiver: arrival gaps over 250 ms (sum over its distinct windows) (`receiver_gaps_over_250ms`) | gaps | 0 | 1 | 0–1 | 1 | 173.2% | 3 | T1 0, T2 0, T3 1 |
| Receiver: enqueued for presentation, not presented (median) (`receiver_enqueue_fps`) | frames/s | 59.40 | 59.60 | 59.20–59.60 | 0.40 | 0.3% | 3 | T1 59.60, T2 59.40, T3 59.20 |
| Receiver: presenter queue age p95 (worst window) (`presenter_queue_age_p95_ms`) | ms | 2.50 | 2.50 | 2.50–2.50 | 0.00 | 0.0% | 3 | T1 2.50, T2 2.50, T3 2.50 |
| Receiver: repeated fixture frame IDs (sum over its distinct windows) (`frame_id_duplicates`) | frames | 6 | 6 | 6–6 | 0 | 0.0% | 3 | T1 6, T2 6, T3 6 |
| Receiver: unreadable frame-ID strips (sum over its distinct windows) (`frame_id_unreadable`) | frames | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |
| Receiver: frames not read while the reader searched for the strip again (sum) (`frame_id_unexamined`) | frames | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |
| Receiver: interval between unique fixture frames p95 (median) (`frame_id_interval_p95_ms`) | ms | 18 | 18 | 18–18 | 0 | 0.0% | 3 | T1 18, T2 18, T3 18 |
| Fixture: frames the fixture window drew (`fixture_drawn_fps`) | frames/s | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Sender: process CPU, % of one core (median of 5 s samples) (`sender_cpu_percent_median`) | % | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Sender: process memory footprint, max (`sender_memory_mb_max`) | MB | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Sender: memory footprint, last minus first sample (`sender_memory_mb_delta`) | MB | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Capture/presentation restarts (`generation_resets`) | events | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |
| Sender: last frame before a restart to the first after it, max (`restart_frame_gap_max_ms`) | ms | n/a | n/a | n/a–n/a | n/a | n/a | 0 | T1 n/a, T2 n/a, T3 n/a |
| Route class changes (`route_changes`) | events | 0 | 0 | 0–0 | 0 | n/a | 3 | T1 0, T2 0, T3 0 |

Sender stage timings, exact to the histogram bucket over each trial's windows (p50 / p95 / p99 / max, ms):

| stage | what it measures | T1 | T2 | T3 |
| --- | --- | --- | --- | --- |
| `sender.capture.complete_interval_ms` | MacSender stream(_:didOutputSampleBuffer:) frames with SCFrameStatus.complete (display capture). ScreenCaptureKit delivers a complete frame only when the screen changed, so long intervals on a static screen are idle, not stalls. Capture runs at about 2x the target rate (DisplayCaptureSettings). | 16.67 / 16.67 / 16.67 / 16.67 (n=901) | 16.67 / 16.67 / 16.67 / 16.67 (n=900) | 17 / 17 / 17 / 316.7 (n=882) |
| `sender.source_age_at_submit_ms` | MacSender.encode: host clock now minus the ScreenCaptureKit sample PTS of the pixels being submitted. Includes the rate limiter's trailing-edge hold and any replay delay. Display capture only: Window view composites have no capture PTS, so nothing is recorded there. | 8 / 10 / 10 / 10 (n=901) | 8 / 10 / 10 / 10 (n=900) | 8 / 10 / 10 / 10 (n=882) |
| `sender.submit_interval_ms` | Successive encoder submissions in MacSender.encode. Counts duplicates and replays too; see the submit counters for source-unique frames. | 16.67 / 16.67 / 16.67 / 16.67 (n=901) | 16.67 / 16.67 / 16.67 / 16.67 (n=900) | 17 / 17 / 17 / 316.7 (n=882) |
| `sender.encode_ms` | VTCompressionSession submit (MacSender.encode) to its output callback. Includes VideoToolbox's own queueing when more than one frame is in flight (StreamingPriority in-flight limit 1/2/3). | 7 / 8 / 8 / 8 (n=901) | 7 / 8.25 / 8.25 / 8.25 (n=901) | 7 / 8.50 / 8.50 / 8.50 (n=882) |
| `sender.send_ms` | MacSender.sendFramed: frame handed to the transport until its send completion. A TCP/QUIC send completion means the local stack accepted the bytes, not that the receiver got them. | 1.50 / 2 / 2 / 2 (n=901) | 1.50 / 2 / 2 / 2 (n=900) | 1.50 / 2 / 2 / 2 (n=882) |

Stalls/freezes (gaps between successive events, counted per interval stage; on a still source a gap can be idle, not a stall):

| stage | T1 >100/250/500 ms | T2 >100/250/500 ms | T3 >100/250/500 ms |
| --- | --- | --- | --- |
| `sender.capture.complete_interval_ms` | 0/0/0 | 0/0/0 | 1/1/0 |
| `sender.submit_interval_ms` | 0/0/0 | 0/0/0 | 1/1/0 |
| `sender.window.compose_interval_ms` | 0/0/0 | 0/0/0 | 0/0/0 |

Bottleneck classifier verdicts per sender window: noBottleneckEvident (medium) × 9

Not measured by this bundle: capture-to-photon and input-to-photon (need external camera/photodiode measurement), presentation on glass on the default display-layer path, GPU/encoder/decoder utilisation, network bytes billed, receiver CPU/memory (in the receiver's own diagnostics export only), audio.

- Subjective observations (separate): operator to fill; keep apart from the numbers above
- Limitations / unexpected behavior / non-equivalences:
  - AVSampleBufferDisplayLayer enqueue is counted as enqueued for presentation, not as presented.
  - Only the experimental Metal path reports an observed presentation, and it changes timing itself.
  - No metric measures capture-to-photon; that needs external measurement.
  - Frame header cap is stamped at encoder submission, not at capture.
  - Cross-device spans use a ping/pong clock offset; error is up to about half the best round trip.
  - Byte counts are app payload, not bytes billed by a network.
  - Trials cover whole 5 s diagnostics windows after the warm-up; up to one window at each end is outside the measurement.
  - Receiver numbers are the receiver's own 5 s windows, each counted once, that began after the trial's first sender window began; they are not aligned with the sender's windows and the last one may end up to one window after the trial.
  - Frame-ID counts exist only on the receiver's experimental Metal path, which itself changes presentation timing.
  - Operator steps are done by hand; their timing varies between trials.
- How another tester reproduces:
  - (beforeRun) SYNTHETIC: nothing to set up.
  - (duringTrial at 11 s) SYNTHETIC: a scripted 300 ms stall happens in trial 3.
  - Start: Settings → System → Streaming Diagnostics → Performance Lab…, or `python3 tools/perf-lab/perf_lab.py start synthetic.self-test --trials 3`
  - Analyse: `python3 tools/perf-lab/perf_lab.py report synthetic-run`
- Code/feature follow-up issue(s): operator to fill
- Evidence: `synthetic-run/manifest.json` and `synthetic-run/trial-01.json`, `synthetic-run/trial-02.json`, `synthetic-run/trial-03.json` (aggregate numbers only; no names, addresses or screen content)
