import CoreGraphics
import XCTest

/// #123 review of ddcef384: the adaptive raster re-check at its real call
/// sites in a real `MacSender` (no network, no ScreenCaptureKit). F1: with
/// the Beta switch off and no data saving, a capture whose start note reads
/// a different size than it was sized at (a display-mode change, or no mode,
/// between sizing and preparation) is never restarted, logged, deferred or
/// reported. F7: a re-check during the lock screen view is held, and held
/// changes are dropped, not applied, when the connection ends or the
/// sender stops.
final class AdaptiveSenderCallSiteTests: XCTestCase {
    private final class SentLog: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        var record: @Sendable (String) -> Void {
            { [weak self] json in
                guard let self else { return }
                self.lock.withLock { self.messages.append(json) }
            }
        }

        var count: Int { lock.withLock { messages.count } }
    }

    /// A display ID no Mac has: `CGDisplayCopyDisplayMode` returns nil for
    /// it, so the note falls back to the size given here, as it does for a
    /// display that went away or asleep between sizing and preparation.
    private let missingDisplay: CGDirectDisplayID = 0x7EAD_BEEF

    private func admittedSender(adaptiveAutomatic: Bool = false)
        async throws -> (MacSender, SentLog, () -> Void) {
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        LoginSessionConsole.shared.set(onConsole: true)
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-adaptive-call-site-tests")
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: "adaptive-call-site-test-ipad")
        // Never dialed: the endpoint only satisfies the initializer.
        let sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                               name: "Adaptive Call Site Test iPad", mode: .mirror,
                               streamingMode: .automatic, adaptiveAutomatic: adaptiveAutomatic)
        let sent = SentLog()
        let hello: [String: Any] = ["type": "hello", "pixelsWide": 2732, "pixelsHigh": 2048, "scale": 2.0,
                                    "device": "iPad", "id": "adaptive-call-site-test-ipad", "pv": WireProtocol.version]
        _ = try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: RecordingEventSink(), sent: sent.record)
        try await sender.settleForTesting()
        return (sender, sent, { keychain.delete() })
    }

    func testSwitchOffRecheckNeverRestartsLogsOrSendsForAMismatchedStartSize() async throws {
        let (sender, sent, cleanup) = try await admittedSender()
        defer { cleanup() }
        XCTAssertFalse(sender.adaptive.announcesAdaptive, "the Beta switch is off")
        let sentBefore = sent.count
        let writesBefore = sender.adaptive.monitor.writeCount
        // Sized from one mode (2732×2048), noted against another (3024×1964).
        for (displayWidth, displayHeight) in [(3024, 1964), (1366, 1024), (2732, 2048)] {
            for lockScreenShown in [false, true] {
                let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
                    displayID: missingDisplay, displayWidth: displayWidth, displayHeight: displayHeight,
                    pixelsWide: 2732, pixelsHigh: 2048, lockScreenShown: lockScreenShown)
                XCTAssertFalse(probe.restartRequested, "\(displayWidth)x\(displayHeight): no capture restart")
                XCTAssertEqual(probe.deferred, .none, "nothing held for the lock screen view")
                XCTAssertFalse(probe.hasManagedRaster)
                XCTAssertEqual(probe.work, AdaptiveStreamingCoordinator.WorkCounters(), "no adaptive work")
            }
        }
        try await sender.settleForTesting()
        XCTAssertEqual(sent.count, sentBefore, "nothing new on the wire")
        XCTAssertEqual(sender.adaptive.monitor.writeCount, writesBefore)
        XCTAssertNil(sender.adaptive.plan)
    }

    func testRecheckDuringTheLockScreenViewIsHeldAndDroppedWhenTheConnectionEnds() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        // "Use less data" on (works with the switch off): the plan asks for
        // the Balanced raster, but this capture started at the old one.
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048,
            saveData: .on, lockScreenShown: true)
        XCTAssertTrue(probe.hasManagedRaster)
        XCTAssertFalse(probe.restartRequested, "not while the lock screen view is shown")
        XCTAssertEqual(probe.deferred, .captureRestart, "held, not lost")
        try await sender.loseConnectionForTesting()
        let afterConnectionEnd = try await sender.adaptiveLockScreenDeferralForTesting
        XCTAssertEqual(afterConnectionEnd, .none, "dropped with the connection, never applied on the way out")
    }

    func testChangesHeldForTheLockScreenViewAreDroppedOnStop() async throws {
        let (sender, _, cleanup) = try await admittedSender()
        defer { cleanup() }
        let probe = try await sender.adaptiveCaptureStartRecheckForTesting(
            displayID: missingDisplay, displayWidth: 2732, displayHeight: 2048, pixelsWide: 2732, pixelsHigh: 2048,
            saveData: .on, lockScreenShown: true)
        XCTAssertEqual(probe.deferred, .captureRestart)
        sender.stop()
        let afterStop = try await sender.adaptiveLockScreenDeferralForTesting
        XCTAssertEqual(afterStop, .none)
    }
}
