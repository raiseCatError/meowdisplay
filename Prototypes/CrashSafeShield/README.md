# Crash-safe Privacy Shield prototype (isolated)

Not part of the app build. Nothing here installs, registers with launchd or needs root.

- `ShieldCore`: the keeper's rules (`KeeperPolicy`) and the line protocol (`WireMessage`). No
  message removes the cover; only this Mac's own click plus the login password does.
- `ShieldKeeper`: the cover controller (option B). Started by the app with a private socket
  pair on fd 3, in its own session so it outlives the app. Covers at the shielding level, left
  out of captures, clicks pass through. Watches the app (socket EOF and process exit) and its
  own main thread (watchdog).
- `FakeSender`: stands in for the main app; covers like the app; can start the keeper (B) or
  relaunch into a covered state from a marker (A).
- `CoverageTrace`: window-layer tracer; reports every interval in which a display was not fully
  covered by the prototype's windows.

Build and test: `swift build --scratch-path <scratch>` and `swift test --scratch-path <scratch>`.
Scenarios (cover the screens for about a minute in total, each releasing on its own):
`./run-scenarios.sh <scratch>/debug <evidence dir>`.

Test-only flags (`--test-mode`, `--test-autorelease`, `--no-lock`) exist only to run the
scenarios unattended without locking the Mac. A production keeper has none of them.
Results, the security model and the owner-facing assessment (threat model, feasibility on macOS
14–27, failure behaviour, maintenance cost, review plan): `ASSESSMENT.md` in this folder.
