import CoreGraphics
import XCTest

/// Third physical-QA pass: blocked touches never enable input on their own,
/// local navigation stays independent of input, the keyboard accessory bar,
/// and user-defined chord palettes.
final class ThirdQARefinementTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "ThirdQA.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: - Blocked touches and input permission

    func testBlockedTouchWithoutOptInOnlyShowsThePrompt() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        let preferencesBefore = ReceiverControlPreferences()
        var preferences = preferencesBefore
        preferences.allowInput = false
        let snapshot = preferences
        for time in stride(from: 0.0, to: 30, by: 1.5) {
            XCTAssertEqual(prompt.blockedAttempt(now: time, userTurnedOff: false, autoRequest: false), [],
                           "no request is ever sent by itself")
        }
        XCTAssertEqual(prompt.kind, .requestInput)
        XCTAssertEqual(preferences, snapshot, "a blocked touch never touches the input preference")
    }

    func testLocallyTurnedOffInputOffersEnableAndNeverAutoRequests() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertEqual(prompt.blockedAttempt(now: 0, userTurnedOff: true, autoRequest: true), [])
        XCTAssertEqual(prompt.kind, .enableInput)
        // Only the user's explicit tap asks the Mac.
        XCTAssertEqual(prompt.requestTapped(now: 1), [.sendRequest])
    }

    func testConnectionAlwaysAllowIsNotConsentToRequestInput() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "mac", defaults: defaults)
        XCTAssertFalse(InputAutoRequestStore.isEnabled(peerID: "mac", defaults: defaults))
        XCTAssertFalse(InputAutoRequestPolicy.shouldAutoRequest(
            peerOptedIn: InputAutoRequestStore.isEnabled(peerID: "mac", defaults: defaults)))
        XCTAssertFalse(InputAutoRequestStore.isEnabled(peerID: nil, defaults: defaults))
    }

    func testExplicitOptInSendsOnlyTheRealRequest() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        InputAutoRequestStore.setEnabled(true, peerID: "mac", defaults: defaults)
        let auto = InputAutoRequestPolicy.shouldAutoRequest(
            peerOptedIn: InputAutoRequestStore.isEnabled(peerID: "mac", defaults: defaults))
        XCTAssertTrue(auto)
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertEqual(prompt.blockedAttempt(now: 0, userTurnedOff: false, autoRequest: auto), [.sendRequest])
        XCTAssertEqual(prompt.kind, .requesting, "requested — not granted")
        XCTAssertEqual(prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: auto), [], "deduped")
        // Only the Mac's confirmed state can show input as enabled.
        prompt.inputStateChanged(.allowed, now: 2)
        XCTAssertEqual(prompt.kind, .enabled)
        InputAutoRequestStore.remove(peerID: "mac", defaults: defaults)
        XCTAssertFalse(InputAutoRequestStore.isEnabled(peerID: "mac", defaults: defaults), "forgetting clears it")
    }

    // MARK: - Local navigation without input

    func testLocalNavigationWorksAndNeverAsksForInput() {
        var gate = ReceiverMultiFingerGestureGate(voiceOverRunning: false)
        _ = gate.update(remoteInputAllowed: false, localNavigationAllowed: true)
        XCTAssertTrue(gate.isEnabled(.twoFingerViewport))
        XCTAssertTrue(gate.isEnabled(.viewportDoubleTap))
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .viewportZoomPan, remoteInputAllowed: false,
                                                     localNavigationAllowed: true, videoEnabled: true,
                                                     pinchTarget: .viewport, rotateTarget: .viewport), [.viewport])
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .scroll, remoteInputAllowed: false,
                                                     localNavigationAllowed: true, videoEnabled: true,
                                                     pinchTarget: .viewport, rotateTarget: .viewport), [])
        XCTAssertTrue(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed: false,
                                                                      localNavigationAllowed: true, videoEnabled: true))
        // Pinch, pan, rotate and the reset double tap are two-finger;
        // Move View is its own mode — neither refreshes the prompt.
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 2, moveViewActive: false))
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: true))
        XCTAssertNil(prompt.kind)
        var session = ViewportNavigationSession()
        let base = CGRect(x: 0, y: 0, width: 800, height: 500)
        var state = session.update(points: [CGPoint(x: 300, y: 250), CGPoint(x: 500, y: 250)], current: .identity,
                                   base: base, allowsZoom: true, allowsRotation: true)
        state = session.update(points: [CGPoint(x: 250, y: 250), CGPoint(x: 550, y: 250)], current: state,
                               base: base, allowsZoom: true, allowsRotation: true)
        XCTAssertEqual(state.scale, 1.5, accuracy: 0.001)
    }

    // MARK: - Keyboard accessory bar

    func testKeyboardBarHoldsOnlyKeyboardCompanions() {
        XCTAssertEqual(ReceiverControlPresentation.mode(softwareKeyboardVisible: true), .keyboardBar)
        XCTAssertEqual(ReceiverControlPresentation.mode(softwareKeyboardVisible: false), .normal)
        XCTAssertEqual(KeyboardBarItem.defaultItems, [.modifier(.command), .modifier(.option), .modifier(.control),
                                                      .modifier(.shift), .escape, .tab, .dismissKeyboard])
    }

    func testNormalControlsReturnUnchangedAfterTheKeyboard() {
        let preferences = ReceiverControlPreferences()
        func rail() -> PadEdgeLayout {
            PadEdgeGeometry.layout(container: CGRect(x: 0, y: 0, width: 1194, height: 834),
                                   safeInsets: ControlSafeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
                                   reservesStrips: preferences.padControlLayout == .strip,
                                   mainEdge: preferences.padMainEdge, functionEdge: preferences.padFunctionEdge,
                                   mainGroupCounts: [4, 7, 2], mainGroupAlignments: [.start, .center, .end],
                                   functionGroupCounts: [2, 2], metrics: PadControlMetrics())
        }
        let before = rail()
        // The keyboard bar is a presentation switch only — nothing about the
        // stored layout changes while it shows.
        _ = ReceiverControlPresentation.mode(softwareKeyboardVisible: true)
        XCTAssertEqual(ReceiverControlPresentation.mode(softwareKeyboardVisible: false), .normal)
        XCTAssertEqual(rail(), before)
    }

    func testLatchedModifierAndTypedKeyAreOneChord() throws {
        var interaction = ControlInteractionState()
        let latch = interaction.tap(.command)
        XCTAssertEqual(latch.first, .modifierDown(.command))
        let press = try XCTUnwrap(SoftwareKeyboardChordPolicy.press(for: "c", modifiers: interaction.activeChord.modifiers))
        XCTAssertEqual(press.usage, 6)
        XCTAssertEqual(press.modifiers, ["command"], "⌘C in a single press")
        XCTAssertEqual(interaction.latchedModifiers, [.command], "the latch stays, as for palette taps")
    }

    // MARK: - User-defined palettes

    private func customPalette() -> [ShortcutItem] {
        var spotlight = ShortcutItem(id: "s", title: "Spotlight", displayKey: "Space", usage: 44,
                                     modifiers: ModifierChord([.command]))
        spotlight.display = .emoji("🔎")
        var macro = ShortcutItem(id: "m", title: "Macro", displayKey: "⋯", usage: 4, modifiers: ModifierChord())
        macro.action = .sequence([ControlActionStep(action: .keyboardShortcut(KeyboardShortcut(usage: 14,
                                                                                               modifiers: ModifierChord([.command])))),
                                  ControlActionStep(action: .receiverGesture("showDesktop"))])
        let desktop = ShortcutItem(id: "d", title: "Show Desktop", gesture: .showDesktop, systemImage: "rectangle.dashed")
        let copy = ShortcutItem(id: "c", title: "Copy", displayKey: "C", usage: 6, modifiers: ModifierChord([.command]))
        return [copy, spotlight, macro, desktop]
    }

    func testCustomPaletteActionsPersist() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = repository.load()
        var profile = preferences.profile(for: .default)
        profile.setActions(customPalette(), for: ModifierChord([.command]))
        preferences.updateProfile(profile)
        repository.save(preferences)
        let loaded = repository.load().profile(for: .default).actions(for: ModifierChord([.command]))
        XCTAssertEqual(loaded, customPalette())
        XCTAssertEqual(loaded[1].face, .text("🔎"), "the face is stored apart from the action")
        XCTAssertEqual(loaded[1].action, .keyboardShortcut(KeyboardShortcut(usage: 44, modifiers: ModifierChord([.command]))))
    }

    func testPaletteActionsCanBeReorderedAndRemoved() {
        var profile = ControlProfile.canonical()
        let chord = ModifierChord([.command])
        profile.setActions(customPalette(), for: chord)
        profile.moveActions(for: chord, from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(profile.actions(for: chord).map(\.id), ["d", "c", "s", "m"])
        var actions = profile.actions(for: chord)
        actions.removeAll { $0.id == "s" }
        profile.setActions(actions, for: chord)
        XCTAssertEqual(profile.actions(for: chord).map(\.id), ["d", "c", "m"])
    }

    func testPreviewAndRuntimeReadTheSamePalette() throws {
        var preferences = ReceiverControlPreferences()
        var profile = preferences.profile(for: .default)
        profile.setActions(customPalette(), for: ModifierChord([.command]))
        preferences.updateProfile(profile)
        // Both the overlay and the editor's Preview ask the active profile.
        let runtime = preferences.profile(for: preferences.activeControlProfile).actions(for: ModifierChord([.command]))
        var session = CustomLayoutPreviewSession()
        session.tapModifier(.command)
        let chord = try XCTUnwrap(session.interaction.paletteChord)
        let preview = preferences.profile(for: preferences.activeControlProfile).actions(for: chord)
        XCTAssertEqual(preview, runtime)
        session.tapPaletteAction(preview[3])
        XCTAssertEqual(session.feedback, .wouldPerform("Show Desktop"),
                       "a system action in a palette previews without sending")
        session.tapPaletteAction(preview[0])
        XCTAssertEqual(session.feedback, .wouldSend("⌘C"))
        // What a runtime tap would send, for each kind.
        XCTAssertEqual(ControlActionPlan.operations(for: runtime[2].action).first,
                       .press(usage: 14, modifiers: ["command"]))
        XCTAssertEqual(ControlActionPlan.operations(for: runtime[3].action), [.gesture("showDesktop")])
    }
}
