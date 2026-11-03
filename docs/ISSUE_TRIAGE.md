# Issue triage and evidence-based product decisions

This is a **maintainer guide**, not extra homework for people reporting a bug. Public issue forms stay short. Issues are a backlog of observations and proposals, **not** promises of delivery or authorization to implement. `dev` is the development baseline; release decisions follow [BRANCHING.md](../BRANCHING.md) and [RELEASE.md](../RELEASE.md).

## Intake: keep the question small

1. **Search first** (including closed issues and PRs). Prefer one problem per issue. Link related trackers, but don't merge unrelated symptoms merely because they involve the same screen. Record a report as **observed**, not **reproduced** or **verified** (see [Evidence terms](#evidence-terms)).
2. **Classify by intent:** bug/regression; actionable supported-platform improvement; speculative idea/research; documentation correction; device/compatibility evidence; private security vulnerability (never a public issue). Redirect support requests to the existing support page. Avoid duplicate research trackers that will never be maintained.
3. **Record user-observable behavior and evidence:** user task, expected/actual result, affected mode/platform/build, route where applicable, repeatable steps, frequency and workaround if known. Do not require a video, logs, exact timings, personally identifying environment information or owning a second test device.
4. **Establish the baseline:** current shipped release versus `dev`; code inspection versus simulator versus physical device are **different claims**. A regression needs a verified previous working version, not just a feeling that something used to work. Keep unknown values explicitly unknown.
5. **Route the decision:** can we reproduce it? is there a safe, smaller solution already in the app? What happens if we do nothing? Who can reasonably test it? Avoid turning every idea into an implementation request.

### Evidence terms

| Term | Meaning |
| --- | --- |
| Observed | Someone reports seeing it; cause, scope and frequency not established |
| Reproduced | A maintainer or tester made it happen again, with the build, device, mode and steps recorded |
| Inferred | A likely cause from code reading or logs, not yet confirmed by a test |
| Proposed | A suggested change or design; not approved and not shown to work |
| Verified | A stated check (named test, build, device and OS) confirmed the behavior or the fix; say what was not covered |

### Internal state vocabulary (written in an issue or comment, not a required GitHub label)

| State | Meaning |
| --- | --- |
| Reported / needs reproduction | Credible user report, cause and scope not established |
| Investigating / researching | Checking baseline, alternatives, platform guidance and failure boundaries |
| Ready for implementation | Maintainer-approved scope, constraints and measurable acceptance criteria |
| Blocked / needs evidence | A specific missing prerequisite, device, entitlement, dependency or decision |
| Implemented / awaiting verification | Code exists, but required physical or release checks have not passed |
| Completed / not planned / duplicate | Record the rationale and linked PR or issue; research-only trackers can remain open intentionally |

**No automatic state transition, milestone, assigned maintainer, release ETA, contributor assignment or label should be inferred from an issue's detail.** Prefer a short state line near the top of large owner-authored research issues.

## Prioritization: use judgment, not an invented score

The maintainer owns priority. Evaluate:

- **Severity and trust:** security/privacy issues use private reporting; crashes, inaccessible core actions, accidental remote input, lost session state and broken pairing precede speculative features.
- **User impact:** frequency, affected supported platforms/devices, number of users or workflows, recovery cost and availability of an accessible workaround.
- **Evidence:** physical reproduction, regression confirmation, reliable test case and confidence in diagnosis (weak evidence means investigate, **not** automatically low importance).
- **Opportunity:** time-to-fix and regression risk, testability with available devices, maintenance/resource/thermal cost, and whether the result improves MeowDisplay's personal-first Mac display/control focus.
- **Dependencies:** release constraints, App Store/Play safety, compatibility, permissions, encryption and remote-input consent.

Practical provisional ordering—not a public SLA:

| Band | Typical handling |
| --- | --- |
| P0 / urgent | Confirmed critical security/safety risk (privately handled), widespread broken core functionality or severe data/control consequences; immediate owner triage |
| P1 / high | Reproducible core workflow failure, major visual/input regression, accessibility blocker or unrecoverable reconnect/discovery failures |
| P2 / normal | Significant usability, quality or performance issue with a workaround; focused supported-platform enhancement |
| P3 / explore | Speculative mode, new platform, optional polish, unproven value or maintenance-heavy idea |

**Do not assign P0/P1 from an unmeasured adjective.** An issue can be high priority to **investigate** without its proposed fix being approved. Do not invent percent affected, FPS, latency, quality, tester counts or hardware coverage. Label sparingly: existing kind/platform labels are useful. The existing `priority:high` and `priority:medium` labels correspond roughly to P1 and P2; only the maintainer applies them, as a recorded decision, never inferred from an issue's detail. Otherwise an issue body can convey provisional priority. No new project board or automation is needed merely to record priority.

## Focused research when a design decision matters

Research depth should be **proportional to risk and reversibility**. A small text or reproducible UI bug does not need a competitor survey. For a new gesture, layout/multitasking mode, image-quality pipeline or permission-affecting feature:

1. **State the user job and current solution.** Trace the actual app path and current gesture/permission defaults. Distinguish shipped behavior from prototypes and user suggestions.
2. **Check relevant first-party guidance**, not a generic HIG compliance badge: [Apple Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking); [Android accessibility](https://developer.android.com/guide/topics/ui/accessibility) and [Material adaptive design](https://m3.material.io/foundations/adaptive-design/overview) where applicable. Check up-to-date API/platform restrictions separately. Standards are design inputs, not evidence a candidate works.
3. **Compare realistic options:** (A) do nothing/document workaround, (B) improve/reuse an existing control, (C) add a small affordance, (D) add new interaction/mode. State benefit, complexity, discoverability, power/performance cost, accessibility and failure modes. Refer to a credible product or OSS implementation **only when the interaction is actually comparable**; record what was observed, its version/date, and where it differs. No competitor-feature copying as a roadmap policy.
4. **Prototype and validate the smallest option**, ideally on real hardware. Test natural repeated gestures, consecutive fast attempts, cancellation/recognizer conflicts, tap/hold/drag, portrait/landscape, multiple panes, large text, VoiceOver/TalkBack/Touch Accommodations, keyboard/pointer, reduced motion, View Only/Allow Input, and permissions when relevant. Do not equate shorter delay with improved feel.
5. **Make an explicit decision:** chosen option or no-change, measured outcome and limitations, acceptance tests, affected platforms, rollback/regression plan. Separate what is observed, reproduced, inferred, proposed and verified. Don't fabricate experiments.

For gesture shortcuts, preserve an accessible button/menu alternative and avoid hijacking OS-reserved gestures. For Window view quality, compare Mirror/Extend on matched hardware/scene/size/route, trace capture pixels -> compositing canvas -> encoded stream -> decoded presentation, and separate expected multi-pane shrinkage from avoidable blur. See [performance methodology issue #123](https://github.com/raiseCatError/meowdisplay/issues/123).

## Validation and closing the loop

- State the actual outcome and evidence (test name, build/commit, device and OS, route and mode); explicitly mention **not tested** paths. Simulator, unit tests and physical testing are not substitutes for one another.
- Add regression criteria covering adjacent interactions and privacy/input-grant behavior. Include text/visual accessibility checks for UI changes, and resource/latency/quality checks when changing capture or encoding.
- Close as fixed only with linked implementation and appropriate verification; if implemented but physical validation is outstanding, say so. Close duplicates and out-of-scope proposals with a short rationale, not an implied feature promise.
- Avoid public private content: pairing codes, IP/hostnames, Tailscale identities, logs with secrets, personal desktop windows or identifiable screen recordings. Use the repository's private security flow for vulnerabilities.

## Examples of scoped tracking

- [#137](https://github.com/raiseCatError/meowdisplay/issues/137): rapid two-finger double-tap reliability is a bug to reproduce **before changing recognizer timing**; relate to [#131](https://github.com/raiseCatError/meowdisplay/issues/131) only for the broader hold-gesture audit.
- [#138](https://github.com/raiseCatError/meowdisplay/issues/138): Window view image clarity is a separate observable quality concern, not a presupposed codec bug; coordinate with #123.
- [#139](https://github.com/raiseCatError/meowdisplay/issues/139): optional temporary floating pane is exploratory; compare with Stage Peek, Window view and local fullscreen before building another mode.
