# CI speed and release-gate campaign (November 2026)

The record of the November 2026 campaign: what changed in Tests, what was measured, what was tried and rejected, and what is still open. How the gates work today is described in [BRANCHING.md](../../BRANCHING.md). Raw measurements are in [the evidence file](ci-speed-campaign-2026-11-evidence.md).

"Measured" means real GitHub Actions runs. "Estimate" is marked wherever it applies. Nothing here was tested on a physical device or a local simulator.

## Outcome

| PR | What it did | Merged into `dev` |
|---|---|---|
| #269 | Batched `dev` pushes with per-job anchors: a gate run always finishes, and a failed job reruns on every later push until it passes. The "dev integration gate failing" issue opens on a failure and closes on the first clean run | `e38e9b0f` |
| #272 | Fast PR gate: the iPhone Duo UI suite runs on a PR only for changed UI test classes and fold geometry. The `mac` job's iOS step became `build-for-testing`, so UI tests always compile. Tests can be run by hand (`workflow_dispatch`) | `5691b320` |
| #273 | `promotion-gate` job, plus the publish guard's check of Tests on the exact candidate commit (`scripts/ci/promotion_gate.py`) | `65f86293` |
| #275 | Outside a promotion, the job is named `promotion-gate (not a promotion)` (see "Gate enforcement") | `82a816b1` |
| #276 | `BRANCHING.md` warning about legacy release branches | `b1c8a456` |

On 2026-11-14 the `main` (26242155) and `release/*` (26251854) rulesets gained the required check `promotion-gate` (integration 15368). Nothing else in them changed. They were applied with targeted `gh api -X PUT` calls, because `scripts/release/apply-rulesets.sh --apply` would also rewrite "Release state" and "Tags". For those two, the live `update` rule reports `{"update_allows_fetch_and_merge": false}` while the files say `null`: the same rule, a permanent diff.

## Before and after

| PR type | Before | After | Source |
|---|---|---|---|
| iOS app code (most iOS PRs) | 31.1 min median, 38.0 p90 (the Duo job; `mac` ~10.9 in parallel) | ~11.6 min (estimate: `mac` median 10.9 plus 0.6–0.8 for `build-for-testing`); 13.8 measured on #270 with runners contended | 200-run history; live #270 |
| UI test class or fold geometry | 31–38 min | 20.9 min (#271: AdaptiveLayoutTests only; build 15.8, the test 62 s) | live |
| Mac only | 8.5 min | 8.5 min | history, 18 runs |
| Android only | ~5.8 min | ~5.8 min | history |
| Docs, tooling, press kit | < 1 min | < 1 min | history |
| CI files or unknown paths | 31–38 min | full CI: 27.5 (#272), 37.8 (#273, three Duo runs at once) | live |
| PR into `main` or `release/*` | full CI, not enforced | full CI, then `promotion-gate`: Duo 27.5 min (#274) | live |

- **Queue:** macOS jobs queued ~0 min at the median but ~21 min at p90 (the account runs at most 5 macOS jobs at once). This was not re-measured after the change.
- **Runner minutes:** the Duo job used 66% of all macOS runner minutes (3,026 of 4,596 over 200 Tests runs).
- **Replay:** the last 60 merged `dev` PRs, run through #272's rules, drop from 47 Duo jobs to 10, and Duo test time from ~625 min to ~84. That is about 1,100 macOS runner-minutes freed per 60 PRs (estimate: 37 × the 31-min median). Details are in #272's description.
- **`dev` integration runs after the merges**, full CI each time with Duo ~27–44 min:
  - 43582202148 (`e38e9b0f`);
  - 43584499405 (`5691b320`);
  - 43586998472 (`65f86293`);
  - 43592468708 (`82a816b1`);
  - after #276 (docs only): 43611491218 (`b1c8a456`) correctly skipped every heavy job.

## Where the full Duo suite runs

| When | Duo suite | What blocks |
|---|---|---|
| PR into `dev` or a feature branch | Only changed UI test classes, or AdaptiveLayoutTests for `Shared/ControlFoldGeometry.swift` and `Shared/ControlTrayGeometry.swift`. Otherwise skipped | Required: `mac`, `conventional`, `release-tooling`, `android`. A Duo-only regression shows up on the `dev` run after the merge, not on the PR |
| Push to `dev` | Full suite whenever its inputs changed since it last passed | Nothing blocks; the issue tracks failures, and the failed job reruns on every push until it passes |
| PR into `main` or `release/*`, push to either | Full suite, always | `promotion-gate` (required): every job `success`, Duo ran exactly `DemoModeSmokeTests AdaptiveLayoutTests LocalCalculatorTourTests` |
| Publishing | — | The guard requires the newest Tests push run for the exact SHA on `release/<version>` to have passed, with every required job's latest attempt, `promotion-gate` and `ios-duo` included. Manual approvals are unchanged |
| On request | Full suite (`workflow_dispatch`) | — |

## Gate enforcement: what was proven

- **Unit tests** (`scripts/ci/test_promotion_gate.py`):
  - every job × {failure, cancelled, skipped, missing} fails the gate, and so does a narrowed Duo run;
  - the publish check rejects runs for another SHA, branch, event, workflow or fork; a newer failed, cancelled, in-progress or timed-out run beats an older pass; a failed rerun counts; a job from another commit is rejected; an API error fails the check;
  - the job-name expression is checked in 14 contexts.
  - Mutations (skipped counted as success, oldest run, job SHA ignored, class check dropped, always reporting the required name) are each caught.
- **Live, on disposable PR #274 into `main`:**
  - cancelling its run made `promotion-gate` fail (it is `always()`);
  - the full rerun passed every job and the gate;
  - after the rulesets were applied, the PR was `BLOCKED` by its failed `promotion-gate`.
- **The #275 bug found live:** the `dev` push and the `dev` → `main` PR run on the same commit, and GitHub matches required checks by name on the commit. Before #275, the `dev` run's "not a promotion" pass carried the name `promotion-gate` and could have answered for `main`. The same commit also shows `mac`, `android` and `release-tooling` as passed from the `dev` run while the PR's were cancelled, which is why the gate reads its own run's results.
- **Publish check, read-only against real past runs:** a failed run gives "is failure", a cancelled one "is cancelled", the wrong branch "no Tests run". A run from before #273 is rejected because it has no `promotion-gate` job.

## Rejected experiments

### Xcode compilation caching (`ci-exp/compile-cache`)
- **Identical commit:** build 7.8 → 2.4 min (run 43571680931, jobs 8.3 vs 3.0 min).
- **Realistic PR change** (2 files): 6.4 min cold vs 7.1 warm, no gain (run 43573472305).
- **Why:** each app is one large Swift module, so one changed file invalidates its cache.

### Parallel macOS unit tests (`ci-exp/mac-parallel`, `ci-exp/mac-parallel-fixed`, `ci-exp/hang-probe`)
- **Same coverage:** serial and parallel (3 workers) ran the identical test set: 3,462 tests, 3,459 passed and 3 skipped, same identity fingerprint.
- **Saving:** about 1.5–2 min (test step 1.4–2.2 vs 3.2–3.5 min; jobs 5.2–5.7 vs 8.4–9.2, run 43539190367).
- **Failures:** 2 of 9 parallel runs, in different tests:
  1. `WindowTileCaptureRetuneTests` (a stop during a change) hung for 120 s on the original code (run 43541959521).
     - The suspected cause, ScreenCaptureKit `stopCapture()` hanging on a never-started stream, was **not** confirmed. On the runner, 120 calls returned in under 1 ms (worst 70 ms), alone and three at a time (probe run 43571562562). The original test passed 440 of 440 runs in parallel isolation.
     - The root cause is unknown. The candidate test-side fix (32453793) was never merged; it is kept on `ci-exp/hang-probe`.
  2. `RemoteFinderLoopTests.testSaveAndShareCopyFilesAndFoldersIntact` failed with that fix applied (run 43570823657).
     - Likely cause: every `RemoteFilesModel` init calls `RemoteTransferQueue.removeStaleCache()`, which deletes the shared `$TMPDIR/RemoteFinder` folder that other test processes write into (`Shared/RemoteFiles.swift`, `Shared/RemoteTransferQueue.swift`).
     - The same deletion could hit two app processes run by one user. This is product code and was not fixed.
- **Decision:** not enabled. Two shared-state hazards in 9 runs, for about 2 min.

### Coverage-based UI test selection (`ci/tiered-ui-selection`, `ci-exp/duo-coverage`, `ci-exp/gate-sim`, `ci-exp/tier-base`)
- **Idea:** a per-line coverage map from a Duo run, so a PR runs only the classes that execute its changed lines.
- **Backtest over 60 merged PRs:**
  - 47 still needed all three classes;
  - 1 a subset;
  - 1 build-only;
  - 3 full CI;
  - 8 had no UI job before or after.
- **Why it fails:** all three classes share one entry path (launch → onboarding → Demo Mode → controls overlay → Settings), so nearly every app line maps to all three.
- **Cost:** the map needs a coverage-enabled Duo run to stay current, and it goes stale as `dev` moves (the backtest flags "changed on dev since the coverage").
- **Decision:** not adopted. Path-based selection (#272) gets the saving without a coverage map. The implementation stays parked on `ci/tiered-ui-selection`.

### Duo build and boot order (`ci-exp/duo-build-first`)
- **Question:** the Duo job is slow (boot 2.4, build 13.2, tests 14.8 min at the median) because the 3-core, 7 GB runner is starved for memory. Would building the UI tests before booting the simulator, or the reverse, avoid it?
- **Round 1** (run 43530967553, the job's own simulator):
  - boot-first 34.0 and 32.1 min (that second repetition failed);
  - build-first 36.8 and 39.9 min.
- **Round 2** (run 43535685285, the runner image's pre-created iPhone Duo):
  - boot-first 32.3 and 26.3 min;
  - build-first 32.2 and 28.3 min.
- **Load sampling** (per phase, in the evidence file):
  - built with no simulator running, the build sat at load 29–34 with no swapping;
  - whenever the booted Duo simulator was up, during a build or while it settled, load averaged 230–490 with ~60 MB free;
  - 0.7–1.6 GB was swapped out (43,672–103,734 pages of 16 KB) in whichever phase followed the boot.
- **Why it doesn't help:** the starvation comes from the booted simulator itself on a 7 GB runner, not from the build and the boot competing. Changing the order only moves the cost to a different phase, and the totals didn't improve.
- **Decision:** no change. Taking the routine Duo run off PRs (#272) was the effective fix. A larger runner is the remaining lever.

## Not done (considered)

- **A separate required iOS build job** to bring iOS PRs under 10 min. Estimate, not measured: about 8.5–9 min, for ~4 more runner-minutes per iOS PR. Not done because it would need a new required check.
- **Shorter Duo tours:** the Calculator tour has about 50 s of fixed sleeps, and the 9 s controls auto-hide forces wake taps in all three classes. A launch argument that turns auto-hide off in UI tests would cut both.
- **Unit tests in place of Duo assertions:** pull the Stage Peek Edge and Smart Touch row conditions into pure functions, and make `LocalCalculatorModel` compile in MacTests.

## Limitations and known failures

- **Legacy release branches:** publishing runs `release-publish.yml` from the release branch itself. Branches cut before #273 and #275 (all six existing `release/*`) publish without the Tests check, and a PR into one that lacks the new workflow waits for `promotion-gate` forever. Cut every new release branch from `dev` at or after `82a816b1` (`BRANCHING.md`).
- **Untested in a real release:** no release has gone through the new publish check yet. No real PR into `release/*` has run since the rulesets changed.
- **Who controls the gate code:** `promotion-gate` and the publish check run code from the PR or candidate commit, as every workflow-defined check does. There is no CODEOWNERS file.
- **Duo regressions show late:** a regression only the Duo tours catch shows up on the `dev` run after the merge (~30 min), not on the PR.
- **Known failures, unfixed:**
  - the parallel-only `WindowTileCaptureRetuneTests` hang, root cause unknown;
  - the shared `$TMPDIR/RemoteFinder` deletion race in Remote Files.
- **Not run:** shellcheck and actionlint, local simulators (policy), physical devices.

## Branches and evidence

- **Kept:**
  - `ci/tiered-ui-selection`: the coverage-selection implementation;
  - `ci-exp/hang-probe`: the probe, the original-retune repro, and the unmerged test-side fix 32453793 (it contains every commit of `ci-exp/mac-parallel-fixed`).
- **Disposable once this file is on `dev`:** `ci-exp/compile-cache`, `ci-exp/duo-build-first`, `ci-exp/duo-coverage`, `ci-exp/mac-parallel`, `ci-exp/mac-parallel-fixed`, `ci-exp/gate-sim`, `ci-exp/tier-base`, `ci-exp/demo-ios-logic` (#270) and `ci-exp/demo-ui-test-2` (#271). These hold experiment workflows and one-line demo changes; their results are recorded here.
- **Raw data:**
  - The run histories and logs (~1.1 GB) and per-second load samples were kept only on a scratch volume.
  - The load-phase summaries and the coverage backtest are copied into [the evidence file](ci-speed-campaign-2026-11-evidence.md).
  - The GitHub runs cited above keep their logs only for the repository's log retention period.
