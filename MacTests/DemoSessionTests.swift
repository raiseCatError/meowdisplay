import XCTest

/// iOS Demo Mode's boundary: the sample session stays in memory and never
/// reaches trust, remote endpoints, real preferences or the wire.
@MainActor
final class DemoSessionTests: XCTestCase {
    private func standardDefaultsSnapshot() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation().mapValues { String(describing: $0) }
    }

    func testEnteringDemoWritesNoTrustEndpointsOrStandardDefaults() {
        let before = standardDefaultsSnapshot()
        let demo = DemoSession()
        demo.setInputAllowed(false)
        demo.setInputAllowed(true)
        demo.displayMode = .mirror
        demo.setVideoEnabled(false)
        demo.audioEnabled = false
        demo.remoteAccessEnabled = false
        demo.requestInputAutomatically = true
        demo.deviceName = "Renamed"
        demo.sendKeyboardPress(usage: 6, modifiers: ["command"])

        XCTAssertFalse(TrustStore.shared.hasPin(peerID: DemoSession.peerID))
        XCTAssertFalse(TrustStore.shared.pinnedPeers().contains { $0.peerID == DemoSession.peerID })
        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: DemoSession.peerID))
        XCTAssertFalse(InputAutoRequestStore.isEnabled(peerID: DemoSession.peerID))
        XCTAssertEqual(standardDefaultsSnapshot(), before)
    }

    func testDemoStartsPopulatedWithInputAllowed() {
        let demo = DemoSession()
        XCTAssertTrue(demo.inputAllowed)
        XCTAssertEqual(demo.inputState, .allowed)
        XCTAssertEqual(demo.displayMode, .extend)
        XCTAssertTrue(demo.videoEnabled)
        XCTAssertTrue(demo.audioEnabled)
        XCTAssertEqual(demo.codec, .hevc)
        XCTAssertEqual(demo.fps, 60)
        XCTAssertEqual(demo.controlSessionPhase, .connected)
        XCTAssertGreaterThanOrEqual(demo.macProtocolVersion, WireProtocol.receiverControlsWireVersion)
    }

    func testAllowInputTogglesOnlyDemoState() {
        let demo = DemoSession()
        demo.setInputAllowed(false)
        XCTAssertFalse(demo.inputAllowed)
        XCTAssertEqual(demo.inputState, .off)
        demo.setInputAllowed(true)
        XCTAssertTrue(demo.inputAllowed)
        XCTAssertEqual(demo.events.suffix(2).map(\.message), ["Demo input turned off", "Demo input allowed"])
    }

    /// Demo controls produce local feedback only. The type holds no
    /// `StreamReceiver`, so there is no wire to reach.
    func testDemoSendsBecomeLocalFeedbackOnly() {
        let demo = DemoSession()
        let generation = demo.actionGeneration
        demo.sendKeyboardPress(usage: 6, modifiers: ["command"])
        XCTAssertEqual(demo.lastAction, "⌘C")
        demo.sendModifier(.option, down: true)
        XCTAssertEqual(demo.lastAction, "Option")
        demo.sendKeyboardPress(usage: 41)
        XCTAssertEqual(demo.lastAction, "Esc")
        XCTAssertEqual(demo.actionGeneration, generation + 3)
        XCTAssertFalse(Mirror(reflecting: demo).children.contains { $0.value is StreamReceiver })
    }

    func testDiagnosticsAreSampleAndPerInstance() {
        let first = DemoSession()
        XCTAssertEqual(first.events.first?.message, "Demo session started (sample data, no network)")
        XCTAssertTrue(first.events.allSatisfy { $0.message.contains("Demo") || $0.message.contains("Sample") })
        first.log("Demo audio resynced")
        let second = DemoSession()
        XCTAssertFalse(second.events.contains { $0.message == "Demo audio resynced" })
    }

    func testSampleRemoteHostIsReservedDomain() {
        XCTAssertTrue(DemoSession.remoteHost.hasSuffix(".example.ts.net"))
    }

    func testRealSessionAlwaysWinsAndExitRestoresIdle() {
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: true, realSurfaceShown: false), .demo)
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: true, realSurfaceShown: true), .receiver)
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: false, realSurfaceShown: false), .idle)
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: false, realSurfaceShown: true), .receiver)
    }

    func testEveryReleaseSettingsCategoryHasDemoPresentation() {
        let release = MobileSettingsCategory.visible(debug: false)
        XCTAssertFalse(release.contains(.developer))
        for category in release {
            XCTAssertNotNil(DemoSettingsPresentation.presentation(for: category), "\(category)")
        }
        XCTAssertNil(DemoSettingsPresentation.presentation(for: .developer))
        // Pages that need a real Mac get demo content, never an empty page.
        for category: MobileSettingsCategory in [.general, .display, .audio, .connections,
                                                  .pairedMacs, .remoteAccess, .permissions, .diagnostics] {
            XCTAssertEqual(DemoSettingsPresentation.presentation(for: category), .demo, "\(category)")
        }
    }

    /// The demo control store saves to its own domain, never the real key.
    func testDemoControlPreferencesUseSeparateDomain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: DemoSession.controlDefaultsSuite))
        defaults.removePersistentDomain(forName: DemoSession.controlDefaultsSuite)
        let realBefore = UserDefaults.standard.data(forKey: ReceiverControlPreferencesRepository.defaultsKey)
        var preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled.toggle()
        ReceiverControlPreferencesRepository(defaults: defaults).save(preferences)
        XCTAssertEqual(UserDefaults.standard.data(forKey: ReceiverControlPreferencesRepository.defaultsKey), realBefore)
        defaults.removePersistentDomain(forName: DemoSession.controlDefaultsSuite)
    }
}
