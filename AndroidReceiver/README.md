# MeowDisplay for Android (receiver)

A native Android receiver for MeowDisplay: it speaks MeowDisplay's own secure
protocol (PROTOCOL.md, pv 22) to the Mac sender, exactly as the iPhone, iPad
and Mac receivers do. It is not a port of another project's Android app and
never uses a plaintext transport.

| Module | What it holds | Tests |
| --- | --- | --- |
| `core` | The protocol in plain Kotlin/JVM: pairing v13 (P-256 ECDH, transcript-bound HKDF, six-digit code, HMAC confirmations, commit/reveal, authenticated commit/ack/abort, the responder throttle), pinned mutual TLS 1.3 over JSSE, pin fingerprints, media framing and the channel demux, audio media frames | Host JVM: replays the Swift implementation's vectors (`../fixtures/receiver-protocol/swift-vectors.json`), runs both pairing roles in-process and over loopback sockets, and real loopback TLS handshakes |
| `core/controls` | The receiver controls ported from the iOS receiver's `Shared/*.swift`: profiles, trays, chords, pointer engine, viewport, tray/iPad/radial geometry, keyboard rules, touch arbitration (see RECEIVER_CONTROLS.md) | Host JVM: the matching Mac tests, ported |
| `app` | The Android app: Keystore identity, pin store, DNS-SD advertisement and browsing, the pairing listener (TCP 9002) and "nearby Mac → Pair", the media listener and decoders, the live receiver screen with the control overlay, input, adaptive layout and Settings | JVM unit tests; `EmulatorSmokeTest` on phone, tablet and foldable AVDs; physical checklist in RECEIVER_CONTROLS.md |

## Build and test

Requires JDK 17 and the Android SDK (platform 36).

```sh
./gradlew :core:test                 # protocol, against the Swift vectors
./gradlew :app:testDebugUnitTest     # app unit tests
./gradlew :app:assembleDebug         # debug APK (app id …android.debug)
./gradlew :app:lintRelease :app:bundleRelease
```

Release builds take `-Pmeow.versionCode=…` and `-Pmeow.versionName=…`, and are
signed only when CI provides the upload key through `MEOW_UPLOAD_STORE_FILE`,
`MEOW_UPLOAD_STORE_PASSWORD`, `MEOW_UPLOAD_KEY_ALIAS` and
`MEOW_UPLOAD_KEY_PASSWORD` (RELEASE.md). Without them the bundle is unsigned.

## Cross-language vectors

`MacTests/CrossPlatformFixtureTests.swift` writes the vectors from the Swift
implementation; `core`'s `SwiftVectorsTest` replays them. After a deliberate
protocol change, regenerate them on the Mac
(`TEST_RUNNER_MEOW_WRITE_FIXTURES=1`, see that file) and make both suites pass.

## Emulator test

With one AVD booted and the debug APK installed (never alongside a Gradle
build on an 8 GB machine; `-gpu host` recommended):

```sh
MEOW_EMULATOR_SERIAL=emulator-5554 MEOW_EMULATOR_PROFILE=phone \
  MEOW_SMOKE_SHOTS=/path/to/shots ./gradlew :core:test --tests '*EmulatorSmokeTest' --rerun
```

`MEOW_EMULATOR_PROFILE` is `phone`, `tablet` or `foldable` (folds and
unfolds mid-session).

## Status

Secure pairing, the authenticated media session, H.264/HEVC decoding, audio,
the receiver controls and the adaptive phone/tablet/foldable UI are
implemented. This is **a receiver for a Mac sender**, not an Android
screen-sharing/sender or an enterprise remote-desktop client.

See [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md) and
[../PARITY.md](../PARITY.md) for differences from iOS and the physical
QA checklist. Earlier real-device testing was reported; **additional
Android physical QA for the 2.0 release-candidate process was waived by
the maintainer**. This does not imply every device or advanced function
was verified. Android USB is not implemented.

Google Play internal/closed-testing submission and *public production*
availability are distinct milestones. Consult the actual Play Console
for the release status, not this source-build README.
