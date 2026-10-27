# MeowDisplay for Android (receiver)

A native Android receiver for MeowDisplay: it speaks MeowDisplay's own secure
protocol (PROTOCOL.md, pv 22) to the Mac sender, exactly as the iPhone, iPad
and Mac receivers do. It is not a port of another project's Android app and
never uses a plaintext transport.

| Module | What it holds | Tests |
| --- | --- | --- |
| `core` | The protocol in plain Kotlin/JVM: pairing v13 (P-256 ECDH, transcript-bound HKDF, six-digit code, HMAC confirmations, commit/reveal, authenticated commit/ack/abort, the responder throttle), pinned mutual TLS 1.3 over JSSE, pin fingerprints, media framing and the channel demux, audio media frames | Host JVM: replays the Swift implementation's vectors (`../fixtures/receiver-protocol/swift-vectors.json`), runs both pairing roles in-process and over loopback sockets, and real loopback TLS handshakes |
| `app` | The Android app: Keystore identity, pin store, DNS-SD advertisement and browsing, the pairing listener (TCP 9002) and "nearby Mac → Pair", Compose UI | JVM unit tests; device checks in the QA checklist |

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

## Status

Secure core and pairing are implemented. Media (the TLS 9001 listener,
session admission, H.264/HEVC decoding, audio), the receiver controls and the
adaptive phone/tablet/foldable UI follow.
