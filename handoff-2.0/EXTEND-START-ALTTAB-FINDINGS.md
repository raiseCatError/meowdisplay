<!-- Sanitized copy of the integration folder's evidence/extend-p0-2026-10-30/README.md (2026-10-31). Local paths and personal names removed; the integration folder holds the original and evidence. -->

# Extend start latency (P0), 2026-10-30 night

## Cause
macOS's capture service (replayd) answers ScreenCaptureKit requests from every app in turn.
AltTab 10.8.0 (installed; macOS 27.0) sends bursts of window-screenshot requests after display
changes and other events, the problem in alt-tab-macos#5861, fixed in AltTab 11.4.4 (lazy
previews). Our content requests waited behind those bursts: 21:58, request sent 21:58:05.059,
served 21:58:14.12 (9 s); next one sent 21:58:14.177, served 21:58:41.5 (27 s); SCStream start
itself 31 ms. Source: tccd "requestor replayd ... accessor com.lwouis.alt-tab-macos" lines
(about 2 a second during bursts) plus ScreenCaptureKit lines in the Dev app's unified log.
Not the Privacy Shield: covering with no new display (21:30, 21:40), AltTab sent nothing.
Earlier fast Extend starts (17:06, 18:24, 18:42: about 2 s) had no burst in the way.

## Our side (commits e268f46, ed34d39, 0ea6ebf)
- One shared broker for ScreenCaptureKit content (`Mac/CoalescingFetch.swift`,
  `Mac/ShareableContentBroker.swift`): callers share requests (at most two out), reuse recent
  answers until a display or the shield's windows change, waits are bounded (45 s budget for
  listing a display, then a clear error) and cancellable (checked every second).
- Extend lists its display and the shield windows from one answer (was two requests in a row).
- A display just created is found in the first answer from any request started after it existed.
- `startTrace id=xxxx mode=... stage=... t=ms dt=ms` lines from admission to first encoded frame,
  one id per session.

## Measurements (Mac side, admission to first captured frame; Moto unless noted)
| Run | Build | AltTab | Result |
|---|---|---|---|
| before (21:54, 21:58, 22:03) | 7f8a0f1 | running | 31.9 s, 36.9 s, 61.5 s (iPhone, with a Moto Mirror start queued behind it) |
| A1b cold 22:38 | e268f46 | running | 19.2 s (listing 14.1 s, stream start 4.7 s, both queued in replayd) |
| A2 warm 22:39 | e268f46 | running | 20.3 s |
| B1 cold 22:45 (auto-reconnect after relaunch) | ed34d39 | quitting | 0.85 s |
| B2 warm 22:47 | ed34d39 | quit | 0.68 s (first encoded 0.74 s) |
| B3 22:48, iPhone Extend while the Moto mirrored | ed34d39 | quit | 1.17 s; the Moto's Mirror start, made at the same moment as an iPhone start, 0.12 s |
| C1 warm 22:50 | ed34d39 | reopened | 21.2 s (an answer at 5.4 s was discarded: fixed in 0ea6ebf, not yet measured) |

| cold 23:07 (auto-reconnect right after relaunch) | 0ea6ebf | removed | 2.43 s (first video encoder in the process 1.5 s; listing 0.35 s) |

AltTab was removed at the owner's request at 23:0x (app, preferences, caches, launch agent, its
permissions), so 0ea6ebf can't be measured against it any more. Mac app while streaming Extend to
the Moto: 17% CPU, 113 MB resident. Mirror first frame 0.12–0.18 s; Window first frame 1–4 s
(earlier runs). Not measured: iPad; frame continuity of a running session during another start.
