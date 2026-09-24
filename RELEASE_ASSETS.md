# Release screenshots and assets checklist

What's already in place, and what still needs physical capture. Two
separate tracks: public repository/website presentation (mockups are
acceptable, and now exist) and App Store submission screenshots (real
captures only, explicitly deferred).

## Public repository / website assets — now available

Reconstructed SVG product visuals live in `assets/mockups/`. These are
**not literal screenshots** — they're clean, source-accurate
reconstructions of the real UI (verified against `Mac/OverviewSettingsView.swift`,
`Mac/DisplaysSettingsView.swift`, and `Shared/ConnectionRoute.swift` for
exact labels/states before drawing them), used because no physical device
capture exists yet. Each file's `<desc>` says so explicitly, and the README
captions them the same way.

| Asset | Purpose | Source | Used in |
|---|---|---|---|
| `hero.svg` | README/GitHub hero image — Mac + iPad connecting, Extend mode | SVG | README top |
| `mirror-mode.svg` | Explains Mirror mode | SVG | README § Features |
| `extend-mode.svg` | Explains Extend mode | SVG | README § Features |
| `connection-state.svg` | Overview panel in a connected, authenticated state, exact field labels from source | SVG | README § How it works |

These are reusable as-is for `meowdisplay.app` once that site exists (see
[Website/marketing content](#websitemarketing-content-not-yet-deployed)
below) — same SVGs, same accuracy constraints.

Also already exist: app icons for Mac, Mac Receiver, and iOS
(`Mac/Assets.xcassets`, `MacReceiver/Assets.xcassets`,
`iOS/Assets.xcassets`) — complete size sets including the Debug variant;
marketing site assets in `assets/`/`public/` (`Github Readme Icon.png`,
`MeowDisplay-mark.png`, `logo.png`, `icon.png`/`icon-256.png`, `og.png`).

## Still worth capturing later (real device photos/screen recordings)

Once real hardware capture happens, these can replace or sit alongside the
mockups above — real captures are always preferable once available:

| Capture | Show | Avoid |
|---|---|---|
| Mac menu bar / overview | The Mac app's main overview panel with a connected device | Sensitive window content in the background |
| iPhone/iPad connected view | The receiving device showing the Mac's extended or mirrored display | Personal photos/notifications visible on the Mac's real screen |
| Remote Access | The Remote Access settings pane with a Tailscale endpoint configured | The actual Tailscale address/hostname — redact or use a placeholder |
| Pairing / SAS | The SAS confirmation screen on both devices | — |
| Settings overview | Devices, Displays, and Security settings panes | Any real paired-device names if they reveal personal info |

This is not blocking — the mockups above are sufficient for current public
presentation.

## App Store submission screenshots — DEFERRED

**Not started, and intentionally out of scope until iOS submission is
actually being prepared (Issue #3's remaining account-side work).**
App Store Connect requires real device screenshots, not reconstructed
visuals — mockups from this checklist must not be submitted as App Store
assets.

### TestFlight / App Store (only needed once iOS submission proceeds)

- Required iPhone screenshot sizes and iPad screenshot sizes (if the app is
  submitted as universal) must be checked against **current** App Store
  Connect requirements at submission time — sizes change between Apple's
  device generations and aren't hardcoded here to avoid going stale.
- `fastlane/APP_STORE_LISTING.md` already has the text fields drafted;
  screenshots are the remaining gap for that submission.

## Capture guidance

- Use a clean desktop/wallpaper and a throwaway or clearly-fake device name
  where the UI shows one.
- Prefer a realistic but unremarkable window/content on the "extended"
  display (a code editor, a document) rather than truly personal content.
- Device mockups/frames around screenshots are optional — plain captures
  are acceptable for README use; App Store screenshots may benefit from
  Apple's official device frame templates.
- Save originals at full resolution; downscale copies for README/web use to
  keep the repo lean.

## Website/marketing content (not yet deployed)

`meowdisplay.app` (the `homepage` set on the GitHub repo) has no live
GitHub Pages deployment yet (see Issue #1/#3 findings — `gh api
repos/.../pages` returns 404). The following is ready to reuse once that
site exists; nothing here is deployed by this checklist:

- The four `assets/mockups/*.svg` files above — same accuracy/labeling
  constraints apply on a public site as in the README.
- Short product description: reuse the README's opening paragraph and
  "Why MeowDisplay?" section verbatim — it's already accurate and
  intentionally free of unsupported claims.
- Security/privacy summary for a future `meowdisplay.app/privacy` page:
  reuse `SECURITY.md` as the source of truth rather than writing separate
  privacy copy that could drift from it.
- No content was fabricated or deployed here — this section only says
  what's *ready* to reuse when the site is built, which is a decision (and
  a separate effort) for the maintainer, not something this pass performs.

## Not blocking

None of the above blocks any other release-preparation work — every doc in
this repository can and does describe MeowDisplay accurately without inline
screenshots. This checklist exists so the maintainer knows exactly what to
capture when ready, not to gate other progress on it.
