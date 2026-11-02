# MeowDisplay 2.0.0: Android physical QA waiver

**Status: WAIVED by the owner (2026-10-31). Not executed, not passed.**

## Decision

For the 2.0.0 release candidate, the owner decided that no additional
Android physical QA is required. Android takes part in the coordinated
2.0.0 release as a required platform (`crossPlatformReady: true`,
`requiredPlatforms: ["mac", "ios", "android"]` in
`.github/release-config.json`).

The decision rests on evidence that already exists:

- development and emulator testing;
- automated tests (the `android` job of `Tests` on `dev`);
- earlier physical device testing on the Moto, recorded in
  [COMPLETION-MATRIX.md](COMPLETION-MATRIX.md) with its own dates and
  limits (for example, physical keyboard/mouse and foldable checks are
  recorded there as PARTIAL or BLOCKED).

## What the waiver covers

Only additional hands-on Android device QA for this candidate. No new
physical Android check was run for 2.0.0, and none may be reported as run
or passed.

## What it does not cover

The waiver bypasses no other safeguard. Android still has to pass:

- release lint and the automated test suite;
- upload-key signing verification against the registered upload
  certificate (`6a9ac078…338e94`);
- a versionCode above every build Google Play already has;
- Google Play review on the configured review track (`alpha`);
- the publication gate, which waits for Mac, iOS and Android to be
  approved for the same release commit, and then for the owner's final
  approval (`publishMode: manual-final-approval`).
