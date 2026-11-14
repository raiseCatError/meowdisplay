# CI speed campaign (November 2026): evidence

Raw measurements behind [the campaign record](ci-speed-campaign-2026-11.md), copied here because the originals lived only on a scratch volume and in GitHub run logs, which expire.

## Duo build and boot order: load per phase

The experiment job sampled load, free memory and swap-outs once a second (`top`) and marked each phase (`ci-exp/duo-build-first`, run 43530967553). Swap-outs are 16 KB pages, counted within the phase. "Minimum free" is the lowest free memory seen.

| Repetition | Phase | Seconds | Mean load | Minimum free | Swap-outs |
|---|---|---|---|---|---|
| A boot-first 1 | boot | 10–218 | 229 | 66 MB | 0 |
| A boot-first 1 | build (simulator up) | 218–2005 | 478 | 63 MB | 103,734 (~1.6 GB) |
| A boot-first 2 | boot | 18–1034 | 488 | 62 MB | 59,584 (~0.9 GB) |
| A boot-first 2 | test | 1034–1893 | 224 | 60 MB | 0 |
| B build-first 1 | build (no simulator) | 14–248 | 34 | 66 MB | 0 |
| B build-first 1 | boot to end | 248–2177 | 333 | 61 MB | 67,204 (~1.0 GB) |
| B build-first 2 | build (no simulator) | 18–310 | 29 | 63 MB | 0 |
| B build-first 2 | boot | 310–750 | 279 | 66 MB | 0 |
| B build-first 2 | settle | 750–1353 | 476 | 66 MB | 43,672 (~0.7 GB) |
| B build-first 2 | test | 1353–2358 | 167 | 63 MB | 0 |

Job durations:

| Run | Variant | Repetition 1 | Repetition 2 |
|---|---|---|---|
| 43530967553 | A boot-first | 34.0 min | 32.1 min (failed) |
| 43530967553 | B build-first | 36.8 min | 39.9 min |
| 43535685285 (image's pre-created Duo) | D boot-first | 32.3 min | 26.3 min |
| 43535685285 (image's pre-created Duo) | C build-first | 32.2 min | 28.3 min |

## Compilation cache and parallel macOS tests: job durations

| Run | Branch | Jobs |
|---|---|---|
| 43571680931 | `ci-exp/compile-cache` (identical commit) | cold 8.3 min, warm 3.0 min |
| 43573472305 | `ci-exp/compile-cache` (2-file change; warm also runs the macOS tests) | cold 6.9 min, warm 11.1 min |
| 43539190367 | `ci-exp/mac-parallel` | serial 9.2 and 8.4 min; parallel-3 5.2 and 5.7 min |
| 43541959521 | `ci-exp/mac-parallel` | parallel-3 ×4: 7.6, 8.2 (failed: `WindowTileCaptureRetuneTests` hang), 7.5, 7.7 min |
| 43570823657 | `ci-exp/mac-parallel-fixed` | serial 6.9; parallel-3 ×3: 5.3, 7.1 (failed: `RemoteFinderLoopTests`), 8.5 min; original-retune repro job failed as intended |
| 43571562562 | `ci-exp/hang-probe` | `stopCapture()` probe: passed, all calls returned quickly |

## Coverage-based selection: backtest over the last 60 merged PRs

Each row is one PR: number | what coverage-based selection would run | estimated Duo time | classes | title (cut short) | the reason. The 8 PRs with no UI job before or after are counted in the last line but not listed.

```text
268 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(ios): the asleep cover's Back to Home hides a  | iOS/OpenSidecarPhoneApp.swift:177 changed on dev since the coverage: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests; iOS/OpenSidecarPhoneApp.sw
267 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(concurrency): mark main-thread-only AppKit and | Shared/WorkspaceViews.swift:2101 changed on dev since the coverage: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests; Shared/WorkspaceViews.swift
266 | build-only |  | build-only | test(ios): Lock Mac live test cancels the confirma | iOSUITests/LiveSessionActionsTests.swift: no CI class
261 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(receiver): offer Request Control and video sta | Shared/ReceiverInputPrompt.swift:33: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests; Shared/ReceiverInputPrompt.swift:39: AdaptiveLayoutTests D
260 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(mirror): wait for a waking display before offe | PROTOCOL.md can change any UI
259 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(lock-screen): deliver a fresh lock screen pict | Shared/LockScreenFlow.swift:180 changed on dev since the coverage: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests; Shared/LockScreenFlow.swift:
233 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | chore(release): integrate the tested 2.1.0 release | PROTOCOL.md can change any UI
229 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): Enable Floating Windows switch  | PROTOCOL.md can change any UI
228 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(mac): menu-bar icon drawn from the MeowDispla | PROTOCOL.md can change any UI
227 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(mac): new installs start as Dock & Menu Bar | PROTOCOL.md can change any UI
226 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(mac): resolve a Bonjour QUIC service before bu | PROTOCOL.md can change any UI
225 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(ios): keep the typing location above the keybo | PROTOCOL.md can change any UI
224 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(lock-screen): trusted devices operate the Mac | PROTOCOL.md can change any UI
223 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(android): show and accept nothing while the Ma | PROTOCOL.md can change any UI
222 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(controls): Lock Mac asks for control first, a | PROTOCOL.md can change any UI
221 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): apps with no window say so fast; | PROTOCOL.md can change any UI
220 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): Open and Save choosers in a pane | PROTOCOL.md can change any UI
218 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | docs(window-mode): research and limits for dialogs | PROTOCOL.md can change any UI
217 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(security): show and accept nothing while the M | PROTOCOL.md can change any UI
216 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): windows closed on the Mac leave | PROTOCOL.md can change any UI
215 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(stage-peek): drags put the search keyboard awa | PROTOCOL.md can change any UI
214 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): window picker opens apps that ar | PROTOCOL.md can change any UI
213 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): keep the drag HUD and float chro | PROTOCOL.md can change any UI
212 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): one hold opens a folded pane tit | PROTOCOL.md can change any UI
211 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): Fill Window on Mac and Restore  | PROTOCOL.md can change any UI
210 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): throws tuck on any edge; tucked | PROTOCOL.md can change any UI
209 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): circle while dragging to switch | PROTOCOL.md can change any UI
208 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): freeform float viewport drawn o | PROTOCOL.md can change any UI
207 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(controls): arrow keypad gets its own Shift, O | PROTOCOL.md can change any UI
206 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(stage-manager): count switches and leave the D | PROTOCOL.md can change any UI
205 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): Mission Control notice only on t | PROTOCOL.md can change any UI
204 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): float chrome no longer shows thr | PROTOCOL.md can change any UI
203 | subset | 7.4m | DemoModeSmokeTests | test(ios): check Touch Style from the device's own | iOSUITests/DemoModeSmokeTests.swift: DemoModeSmokeTests
202 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(window-mode): give each pane title its own acc | Shared/WorkspaceViews.swift:265: DemoModeSmokeTests; Shared/WorkspaceViews.swift:583: DemoModeSmokeTests; iOSUITests/DemoModeSmokeTests.swift: DemoModeSmokeTest
200 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | test(ios): keep the Demo tours clear of Show Windo | iOSUITests/DemoDesktopWakePoint.swift is added or deleted
198 | ALL(full CI) |  | ci(ios): boot the Duo simulator before building ag
196 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): floating windows on iPhone and  | Shared/WorkspaceFloatViews.swift is new, deleted or not in the UI coverage
195 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(window-mode): floating panes model, Mac valid | PROTOCOL.md can change any UI
194 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(ios): keep prompts, the keyboard bar and Demo  | RECEIVER_CONTROLS.md can change any UI
193 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | perf(cursor): draw the Mac cursor on the receiver' | PROTOCOL.md can change any UI
192 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(mac): open request panels on the owner's Space | project.yml can change any UI
189 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(ios): quicker modifier shortcuts with a Hold  | RECEIVER_CONTROLS.md can change any UI
188 | ALL(full CI) |  | feat(ios): add a built-in local calculator to the 
187 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(ios): on-screen arrow keys with tap-to-open k | RECEIVER_CONTROLS.md can change any UI
186 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(ios): prerequisites-first Remote Access setup | PARITY.md can change any UI
185 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(mac): restart streaming once when a receiver c | project.yml can change any UI
184 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(receiver): don't offer Remove from Layout on t | Shared/WorkspaceClient.swift:1439 changed on dev since the coverage: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests
183 | ALL(full CI) |  | ci(ios): build the Duo UI tests before the simulat
181 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | fix(ios): stop retrying audio playback during an a | Shared/ReceiverPictureInPicture.swift:216: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests; Shared/ReceiverPictureInPicture.swift:220: AdaptiveL
178 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat: Streaming Priority reads Latency, Balanced,  | Shared/Protocol.swift:118 changed on dev since the coverage: AdaptiveLayoutTests DemoModeSmokeTests LocalCalculatorTourTests
177 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | docs(ios): say Unified Clipboard keeps working on  | RECEIVER_CONTROLS.md can change any UI
176 | all | 13.3m | DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests | feat(ios): show the build number and a Rate MeowDi | Shared/AppStore.swift:28: DemoModeSmokeTests; Shared/AppStore.swift:58: DemoModeSmokeTests; Shared/AppVersion.swift is new, deleted or not in the UI coverage
{'all': 47, 'build-only': 1, 'no ios_ui before or after': 8, 'subset': 1, 'full CI (all classes)': 3}
```
