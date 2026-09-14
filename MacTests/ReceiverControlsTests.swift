import XCTest

final class ReceiverControlsTests: XCTestCase {
    func testModifierTapLatchesAndSecondTapUnlatches() {
        var state = ControlInteractionState()
        XCTAssertEqual(state.tap(.command), [.modifierDown(.command), .haptic(.latch)])
        XCTAssertEqual(state.latchedModifiers, [.command])
        XCTAssertEqual(state.tap(.command), [.modifierUp(.command), .haptic(.latch)])
        XCTAssertTrue(state.latchedModifiers.isEmpty)
    }

    func testMultipleModifiersLatch() {
        var state = ControlInteractionState()
        _ = state.tap(.command)
        _ = state.tap(.option)
        XCTAssertEqual(state.latchedModifiers, [.command, .option])
    }

    func testHoldOpensPaletteWithoutLatchingAndBuildsChord() {
        var state = ControlInteractionState()
        state.press(.command)
        let effects = state.beginPalette(with: .command)
        XCTAssertEqual(effects, [.modifierDown(.command), .haptic(.selection)])
        XCTAssertTrue(state.latchedModifiers.isEmpty)
        XCTAssertEqual(state.activeChord, ModifierChord([.command]))

        XCTAssertEqual(state.addTemporaryModifier(.option),
                       [.modifierDown(.option), .haptic(.selection)])
        XCTAssertEqual(state.activeChord, ModifierChord([.command, .option]))
        XCTAssertEqual(state.paletteChord, ModifierChord([.command, .option]))
        XCTAssertEqual(state.addTemporaryModifier(.option), [])
        XCTAssertEqual(state.activeChord, ModifierChord([.command, .option]))
    }

    func testContinuousChordSelectionHapticsAndExecutionAreSemantic() {
        var state = ControlInteractionState()
        state.press(.command)
        _ = state.beginPalette(with: .command)
        XCTAssertEqual(state.addTemporaryModifier(.option),
                       [.modifierDown(.option), .haptic(.selection)])
        XCTAssertEqual(state.addTemporaryModifier(.option), [])

        let action = ShortcutItem(id: "move-here", title: "Move Item Here",
                                  displayKey: "V", usage: 25,
                                  modifiers: ModifierChord([.command, .option]))
        XCTAssertEqual(state.selectAction(action.id), [.haptic(.selection)])
        XCTAssertEqual(state.selectAction(action.id), [])
        XCTAssertEqual(state.finish(with: action),
                       [.execute(action), .haptic(.confirmation),
                        .modifierUp(.command), .modifierUp(.option)])
        XCTAssertTrue(state.temporaryModifiers.isEmpty)
        XCTAssertNil(state.paletteChord)
    }

    func testTemporaryReleaseWithoutActionReturnsToLatchedPalette() {
        var state = ControlInteractionState()
        _ = state.tap(.shift)
        state.press(.command)
        _ = state.beginPalette(with: .command)
        _ = state.addTemporaryModifier(.option)
        XCTAssertEqual(state.finish(with: nil),
                       [.modifierUp(.command), .modifierUp(.option)])
        XCTAssertEqual(state.latchedModifiers, [.shift])
        XCTAssertEqual(state.paletteChord, ModifierChord([.shift]))
    }

    func testTapLatchedChordKeepsItsPaletteVisible() {
        var state = ControlInteractionState()
        _ = state.tap(.command)
        XCTAssertEqual(state.paletteChord, ModifierChord([.command]))
        _ = state.tap(.option)
        XCTAssertEqual(state.paletteChord, ModifierChord([.command, .option]))
    }

    func testExecutingShortcutClearsTemporaryAndPreservesPermanentModifiers() {
        var state = ControlInteractionState()
        _ = state.tap(.shift)
        _ = state.beginPalette(with: .command)
        _ = state.updateTemporaryChord([.command, .option])
        let action = ShortcutItem(title: "Paste", displayKey: "V", usage: 25,
                                  modifiers: ModifierChord([.command, .option, .shift]))
        let effects = state.finish(with: action)
        XCTAssertEqual(effects, [.execute(action), .haptic(.confirmation),
                                 .modifierUp(.command), .modifierUp(.option)])
        XCTAssertEqual(state.latchedModifiers, [.shift])
        XCTAssertTrue(state.temporaryModifiers.isEmpty)
    }

    func testCancelAndResetReleaseHeldModifiers() {
        var state = ControlInteractionState()
        _ = state.beginPalette(with: .command)
        XCTAssertEqual(state.cancelTemporary(), [.modifierUp(.command)])
        _ = state.tap(.command)
        _ = state.tap(.option)
        XCTAssertEqual(state.resetAll(), [.modifierUp(.command), .modifierUp(.option)])
        XCTAssertTrue(state.latchedModifiers.isEmpty)
    }

    func testCanonicalProfileContentsAndArbitraryChordLookup() {
        var profile = ControlProfile.canonical()
        XCTAssertEqual(profile.visibleTrayItems, ControlTrayItem.allCases)
        XCTAssertEqual(profile.actions(for: ModifierChord([.command])).map(\.displayKey),
                       ["C", "V", "X", "Z", "A", "W", "Space"])
        XCTAssertEqual(profile.actions(for: ModifierChord([.command, .option])).count, 5)
        XCTAssertEqual(profile.actions(for: ModifierChord([.command, .shift])).count, 6)

        let arbitrary = ModifierChord([.control, .option, .shift])
        let action = ShortcutItem(title: "Test", displayKey: "T", usage: 23,
                                  modifiers: arbitrary)
        profile.setActions([action], for: arbitrary)
        XCTAssertEqual(profile.actions(for: ModifierChord([.shift, .control, .option])), [action])
    }

    func testDefaultTrayIncludesCustomizableOneShotTab() {
        let profile = ControlProfile.canonical()
        XCTAssertEqual(profile.visibleTrayItems,
                       [.command, .option, .control, .shift, .escape, .tab, .keyboard, .settings])
        XCTAssertEqual(ControlTrayItem.tab.displayLabel, "tab")
        XCTAssertEqual(profile.trayItems.first(where: { $0.item == .tab })?.isVisible, true)
    }

    func testShortcutHUDReflectsActiveCombinationWithoutActionTitle() {
        XCTAssertEqual(ModifierChord([.command]).hudText(for: "C"), "⌘C")
        XCTAssertEqual(ModifierChord([.command, .option]).hudText(for: "V"), "⌘⌥V")
        XCTAssertEqual(ModifierChord([.command, .shift]).hudText(for: "4"), "⌘⇧4")
    }

    func testReceiverCanRequestMirrorToExtendAndExtendToMirror() {
        var mirror = DisplayModeRequestState()
        XCTAssertFalse(mirror.confirm(.mirror))
        XCTAssertTrue(mirror.request(.extend))
        XCTAssertEqual(mirror.pendingMode, .extend)

        var extend = DisplayModeRequestState()
        XCTAssertFalse(extend.confirm(.extend))
        XCTAssertTrue(extend.request(.mirror))
        XCTAssertEqual(extend.pendingMode, .mirror)
    }

    func testDuplicateModeRequestIsSuppressedWhilePending() {
        var state = DisplayModeRequestState()
        _ = state.confirm(.mirror)
        XCTAssertTrue(state.request(.extend))
        XCTAssertFalse(state.request(.extend))
        XCTAssertFalse(state.request(.mirror))
        XCTAssertEqual(state.pendingMode, .extend)
    }

    func testConfirmedModeUpdatesReceiverAndProducesOneReceiverConfirmation() {
        var state = DisplayModeRequestState()
        _ = state.confirm(.mirror)
        _ = state.request(.extend)
        XCTAssertTrue(state.confirm(.extend))
        XCTAssertEqual(state.confirmedMode, .extend)
        XCTAssertNil(state.pendingMode)
        XCTAssertFalse(state.confirm(.extend))
    }

    func testUnansweredModeRequestExpiresAndKeepsTheActualMode() {
        var state = DisplayModeRequestState()
        _ = state.confirm(.mirror)
        XCTAssertTrue(state.request(.extend))
        let generation = state.pendingGeneration
        XCTAssertTrue(state.expirePending(generation: generation))
        XCTAssertNil(state.pendingMode)
        XCTAssertEqual(state.confirmedMode, .mirror)
        // Idempotent, and a stale deadline can never retire a newer request.
        XCTAssertFalse(state.expirePending(generation: generation))
        XCTAssertTrue(state.request(.extend))
        XCTAssertFalse(state.expirePending(generation: generation))
        XCTAssertEqual(state.pendingMode, .extend)
    }

    func testSessionResetClearsStalePendingAndConfirmedMode() {
        var state = DisplayModeRequestState()
        _ = state.confirm(.mirror)
        _ = state.request(.extend)
        state.reset()
        XCTAssertNil(state.pendingMode)
        XCTAssertNil(state.confirmedMode)
        // Nothing is carried over: the first state after a reset is a plain
        // Mac-originated update, not a receiver confirmation.
        XCTAssertFalse(state.confirm(.extend))
        XCTAssertTrue(state.request(.mirror))
    }

    func testMacOriginatedModeStateUpdatesWithoutReceiverConfirmation() {
        var state = DisplayModeRequestState()
        XCTAssertFalse(state.confirm(.mirror))
        XCTAssertEqual(state.confirmedMode, .mirror)
        XCTAssertFalse(state.confirm(.extend))
        XCTAssertEqual(state.confirmedMode, .extend)
    }

    func testCaptureModeMapsToExplicitReceiverModeBothWays() {
        XCTAssertEqual(CaptureMode(ReceiverDisplayMode.mirror), .mirror)
        XCTAssertEqual(CaptureMode(ReceiverDisplayMode.extend), .extend)
        XCTAssertEqual(CaptureMode.mirror.receiverMode, .mirror)
        XCTAssertEqual(CaptureMode.extend.receiverMode, .extend)
    }

    func testProfileReorderHideAndPaletteEditing() {
        var profile = ControlProfile.canonical()
        profile.moveTrayItems(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(profile.trayItems.map(\.item).prefix(3), [.option, .control, .command])
        profile.trayItems[0].isVisible = false
        XCTAssertFalse(profile.visibleTrayItems.contains(.option))

        let chord = ModifierChord([.command])
        let originalCount = profile.actions(for: chord).count
        var actions = profile.actions(for: chord)
        actions.removeFirst()
        actions.append(ShortcutItem(title: "New", displayKey: "N", usage: 17,
                                    modifiers: chord))
        profile.setActions(actions, for: chord)
        profile.moveActions(for: chord, from: IndexSet(integer: originalCount - 1), to: 0)
        XCTAssertEqual(profile.actions(for: chord).first?.title, "New")
    }

    func testPreferencesSerializationSlotsPersistenceAndReset() throws {
        let suite = "ReceiverControlsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = ReceiverControlPreferences()
        preferences.activeControlProfile = .profile2
        preferences.trayEnabled = false
        preferences.keyboardButtonEnabled = false
        preferences.hapticsEnabled = false
        preferences.preferredLandscapeSide = .leading
        var profile1 = preferences.profile(for: .profile1)
        profile1.trayItems[0].isVisible = false
        preferences.updateProfile(profile1)
        repository.save(preferences)

        let loaded = repository.load()
        XCTAssertEqual(loaded, preferences)
        XCTAssertNotEqual(loaded.profile(for: .profile1), loaded.profile(for: .profile2))
        var reset = loaded
        reset.resetProfile(.profile1)
        XCTAssertEqual(reset.profile(for: .profile1), .canonical(slot: .profile1))
        XCTAssertFalse(reset.trayEnabled)
    }

    func testVersionOnePreferencesGainTabWithoutLosingCustomization() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 1
        for index in old.profiles.indices {
            old.profiles[index].trayItems.removeAll { $0.item == .tab }
        }
        old.profiles[0].trayItems[0].isVisible = false
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertFalse(migrated.profiles[0].trayItems[0].isVisible)
        XCTAssertEqual(migrated.profiles[0].trayItems.firstIndex { $0.item == .tab },
                       migrated.profiles[0].trayItems.firstIndex { $0.item == .keyboard }.map { $0 - 1 })
    }

    func testLandscapeTrayHugsChosenSideAndCentersVertically() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        func layout(_ side: LandscapeTraySide) -> ControlTrayLayout {
            ControlTrayGeometry.layout(
                container: container, safeInsets: .zero, keyboardVisibleRect: nil,
                portrait: false, side: side, traySize: CGSize(width: 44, height: 348),
                paletteSize: CGSize(width: 42, height: 260))
        }
        let right = layout(.trailing)
        let left = layout(.leading)
        XCTAssertEqual(right.trayFrame.maxX, container.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(left.trayFrame.minX, container.minX + 12, accuracy: 0.5)
        // Vertically centered, and the palette opens inward on both sides.
        XCTAssertEqual(right.trayFrame.midY, container.midY, accuracy: 0.5)
        XCTAssertEqual(left.trayFrame.midY, container.midY, accuracy: 0.5)
        XCTAssertLessThan(right.paletteFrame.maxX, right.trayFrame.minX)
        XCTAssertGreaterThan(left.paletteFrame.minX, left.trayFrame.maxX)
    }

    func testSchemaTwoLandscapeCornerMigratesToTraySide() throws {
        let suite = "ReceiverControlsSideMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let encoded = try JSONEncoder().encode(ReceiverControlPreferences())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 2
        object.removeValue(forKey: "preferredLandscapeSide")
        object["preferredLandscapeCorner"] = LandscapeTrayCorner.bottomLeading.rawValue
        defaults.set(try JSONSerialization.data(withJSONObject: object),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertEqual(migrated.preferredLandscapeSide, .leading)
    }

    func testGeometryKeepsPortraitTrayAndPaletteAboveKeyboard() {
        let visible = CGRect(x: 0, y: 0, width: 390, height: 500)
        let layout = ControlTrayGeometry.layout(
            container: CGRect(x: 0, y: 0, width: 390, height: 844), safeInsets: .zero,
            keyboardVisibleRect: visible, portrait: true, side: .trailing,
            traySize: CGSize(width: 360, height: 58), paletteSize: CGSize(width: 330, height: 92))
        XCTAssertLessThanOrEqual(layout.trayFrame.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(layout.paletteFrame.maxY, layout.trayFrame.minY)
        XCTAssertTrue(visible.contains(layout.paletteFrame))
    }

    func testLandscapeCornerFallsBackInsideKeyboardVisibleBounds() {
        let visible = CGRect(x: 0, y: 0, width: 700, height: 190)
        let layout = ControlTrayGeometry.layout(
            container: CGRect(x: 0, y: 0, width: 700, height: 390), safeInsets: .zero,
            keyboardVisibleRect: visible, portrait: false, side: .trailing,
            traySize: CGSize(width: 58, height: 300), paletteSize: CGSize(width: 320, height: 92))
        XCTAssertTrue(visible.contains(layout.trayFrame))
        XCTAssertTrue(visible.contains(layout.paletteFrame))
        XCTAssertFalse(layout.trayFrame.intersects(layout.paletteFrame))
        XCTAssertEqual(layout.axis, .vertical)
    }

    func testHeldModifierTrackerNeverKeepsReleasedState() {
        var tracker = HeldModifierTracker()
        XCTAssertTrue(tracker.down(.command))
        XCTAssertFalse(tracker.down(.command))
        XCTAssertTrue(tracker.flags.contains(.maskCommand))
        XCTAssertTrue(tracker.up(.command))
        XCTAssertFalse(tracker.flags.contains(.maskCommand))
        XCTAssertFalse(tracker.up(.command))
    }

    func testHapticPolicyHonorsPreference() {
        for event in [ControlHapticEvent.selection, .latch, .confirmation, .profileChange, .reset] {
            XCTAssertTrue(ControlHapticPolicy.shouldPlay(event, enabled: true))
            XCTAssertFalse(ControlHapticPolicy.shouldPlay(event, enabled: false))
        }
    }

    func testMacDeliveredPreferenceUpdateChangesOnlySuppliedFields() throws {
        var preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = false
        let update = try XCTUnwrap(ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "trayEnabled": false,
        ]))
        update.apply(to: &preferences)
        XCTAssertFalse(preferences.trayEnabled)
        XCTAssertTrue(preferences.keyboardButtonEnabled)
        XCTAssertFalse(preferences.hapticsEnabled)
        XCTAssertNil(ReceiverUIPreferenceUpdate(message: ["type": "unknown",
                                                          "trayEnabled": true]))
    }
}
