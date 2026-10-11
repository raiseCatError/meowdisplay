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

    /// Demo controls act on the sample desktop or preview what a Mac would
    /// get. The type holds no `StreamReceiver`, so there is no wire to reach.
    func testDemoSendsBecomeLocalActionsOrMacPreviews() {
        let demo = DemoSession()
        demo.sendKeyboardPress(usage: 6, modifiers: ["command"])
        XCTAssertEqual(demo.workspace.feedback, .macShortcut(usage: 6, modifiers: ["command"]))
        XCTAssertEqual(DemoFeedback.shortcutName(usage: 6, modifiers: ["command"]), "Copy")
        demo.sendModifier(.option, down: true)
        XCTAssertEqual(demo.workspace.feedback, .modifierHeld(.option))
        demo.sendGesture(name: ReceiverGesture.missionControl.rawValue)
        XCTAssertEqual(demo.workspace.feedback, .macGesture("missionControl"))
        // Show Desktop and Undo are carried out locally.
        demo.sendGesture(name: ReceiverGesture.showDesktop.rawValue)
        XCTAssertTrue(demo.workspace.interaction.desktop.showingDesktop)
        demo.workspace.interaction.desktop.reconfigure(mode: .mirror, size: DemoDesktop.size(forAspect: 1.6))
        demo.workspace.focusNotesForTyping()
        demo.typeText("Hi")
        XCTAssertTrue(demo.workspace.interaction.desktop.notes.hasSuffix("Hi"))
        demo.sendKeyboardPress(usage: 29, modifiers: ["command"])
        XCTAssertEqual(demo.workspace.feedback, .local("Undo"))
        XCTAssertFalse(demo.workspace.interaction.desktop.notes.hasSuffix("Hi"))
        XCTAssertFalse(Mirror(reflecting: demo).children.contains { $0.value is StreamReceiver })
    }

    func testInputOffBlocksSimulatedMacInput() {
        let demo = DemoSession()
        demo.setInputAllowed(false)
        let before = demo.workspace.interaction.desktop
        demo.sendKeyboardPress(usage: 6, modifiers: ["command"])
        XCTAssertEqual(demo.workspace.feedback, .inputOff)
        demo.typeText("x")
        demo.sendGesture(name: ReceiverGesture.showDesktop.rawValue)
        XCTAssertEqual(demo.workspace.interaction.desktop, before)
    }

    func testExtendShapeIsDemoLocalAndStartsAutomatic() {
        let demo = DemoSession()
        XCTAssertEqual(demo.extendShape, .standard)
        demo.extendShape = ExtendDisplayShapePreference(shape: .r21x9, useFullDisplay: false)
        XCTAssertEqual(DemoSession().extendShape, .standard)
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
        XCTAssertEqual(DemoSession.remoteHost, "review-mac.example")
        XCTAssertTrue(DemoSession.remoteHost.hasSuffix(".example"))
    }

    func testRealModeKeepsStandardPreferences() {
        XCTAssertTrue(DemoSession.preferenceDefaults(demoActive: false) === UserDefaults.standard)
        XCTAssertFalse(DemoSession.preferenceDefaults(demoActive: true) === UserDefaults.standard)
    }

    /// Zoom While Typing in Demo Mode lives in the demo domain only, and
    /// exiting discards it.
    func testDemoZoomWhileTypingIsIsolatedAndDiscarded() {
        let key = "zoomWhileTyping"
        let realBefore = UserDefaults.standard.object(forKey: key) as? Bool
        DemoSession.discardPreferences()
        let demo = DemoSession.preferenceDefaults(demoActive: true)
        demo.set(!(realBefore ?? true), forKey: key)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, realBefore)
        XCTAssertNotNil(DemoSession.preferenceDefaults(demoActive: true).object(forKey: key))
        DemoSession.discardPreferences()
        XCTAssertNil(DemoSession.preferenceDefaults(demoActive: true).object(forKey: key))
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, realBefore)
    }

    /// Nine demo taps unlock Cat Mode in the demo domain only.
    func testDemoCatModeTapsDoNotTouchRealCatMode() {
        let keys = [CatMode.unlockedDefaultsKey, CatMode.enabledDefaultsKey, CatMode.tapCountDefaultsKey]
        let realBefore = keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }
        DemoSession.discardPreferences()
        let demo = DemoSession.preferenceDefaults(demoActive: true)
        var count = 0
        var unlocked = false
        for _ in 0..<9 {
            let result = CatMode.registerTap(tapCount: count, alreadyUnlocked: unlocked)
            count = result.tapCount
            demo.set(count, forKey: CatMode.tapCountDefaultsKey)
            if result.justUnlocked {
                unlocked = true
                demo.set(true, forKey: CatMode.unlockedDefaultsKey)
                demo.set(true, forKey: CatMode.enabledDefaultsKey)
            }
        }
        XCTAssertTrue(unlocked)
        XCTAssertTrue(demo.bool(forKey: CatMode.unlockedDefaultsKey))
        XCTAssertEqual(keys.map { UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } }, realBefore)
        DemoSession.discardPreferences()
        XCTAssertFalse(DemoSession.preferenceDefaults(demoActive: true).bool(forKey: CatMode.unlockedDefaultsKey))
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
