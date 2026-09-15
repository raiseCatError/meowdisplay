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
        preferences.allowInput = false
        preferences.inputMode = .trackpad
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

    func testSchemaThreePreferencesDefaultAllowInputAndDirectTouch() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 3
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        // A save written before either preference existed must migrate to
        // exactly the pre-feature behavior: input always allowed, touch
        // always direct/absolute — never silently disable input or switch
        // an existing user into an unfamiliar pointer model.
        XCTAssertTrue(migrated.allowInput)
        XCTAssertEqual(migrated.inputMode, .direct)
    }

    func testSchemaFourPreferencesDefaultTrackpadSensitivityToPreSettingSpeed() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 4
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertEqual(migrated.trackpadSensitivity, PointerGestureConfig.defaultTrackpadSensitivity)
    }

    func testTrayCanBeShownRequiresBothAllowInputAndTrayEnabled() {
        var preferences = ReceiverControlPreferences()
        XCTAssertTrue(preferences.trayCanBeShown)

        preferences.allowInput = false
        XCTAssertFalse(preferences.trayCanBeShown)
        // Turning input back on restores the tray automatically because the
        // stored `trayEnabled` preference was never touched.
        preferences.allowInput = true
        XCTAssertTrue(preferences.trayCanBeShown)

        preferences.trayEnabled = false
        XCTAssertFalse(preferences.trayCanBeShown)
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
                paletteSize: CGSize(width: 42, height: 260), avoidNotch: true)
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
            traySize: CGSize(width: 360, height: 58), paletteSize: CGSize(width: 330, height: 92),
            avoidNotch: true)
        XCTAssertLessThanOrEqual(layout.trayFrame.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(layout.paletteFrame.maxY, layout.trayFrame.minY)
        XCTAssertTrue(visible.contains(layout.paletteFrame))
    }

    func testLandscapeCornerFallsBackInsideKeyboardVisibleBounds() {
        let visible = CGRect(x: 0, y: 0, width: 700, height: 190)
        let layout = ControlTrayGeometry.layout(
            container: CGRect(x: 0, y: 0, width: 700, height: 390), safeInsets: .zero,
            keyboardVisibleRect: visible, portrait: false, side: .trailing,
            traySize: CGSize(width: 58, height: 300), paletteSize: CGSize(width: 320, height: 92),
            avoidNotch: true)
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

    func testHIDKeyUsageMinusAndEqualParseAndMapToCorrectKeyCodes() {
        XCTAssertEqual(HIDKeyUsage.parse(45 as NSNumber), .minus)
        XCTAssertEqual(HIDKeyUsage.parse(46 as NSNumber), .equal)
        XCTAssertEqual(HIDKeyUsage.minus.keyCode, 27)
        XCTAssertEqual(HIDKeyUsage.equal.keyCode, 24)
    }

    // MARK: - Avoid Notch

    func testAvoidingUnsafeRegionShiftsOnlyWhenIntersectingAndOnlyOnTheAffectedEdge() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)

        // Frame sitting inside the notch's strip — shifted to clear it.
        let overlapping = CGRect(x: 10, y: 100, width: 44, height: 120)
        let shifted = ControlTrayGeometry.avoidingUnsafeRegion(overlapping, in: container, safeInsets: leftNotch, enabled: true, notchSide: .leading)
        XCTAssertEqual(shifted.minX, 40)
        XCTAssertEqual(shifted.minY, overlapping.minY)   // only the affected axis moves

        // A frame nowhere near the unsafe strip is returned unchanged.
        let clear = CGRect(x: 200, y: 100, width: 44, height: 120)
        XCTAssertEqual(ControlTrayGeometry.avoidingUnsafeRegion(clear, in: container, safeInsets: leftNotch, enabled: true, notchSide: .leading), clear)

        // Disabled: never shifts, even when intersecting.
        XCTAssertEqual(ControlTrayGeometry.avoidingUnsafeRegion(overlapping, in: container, safeInsets: leftNotch, enabled: false, notchSide: .leading), overlapping)
    }

    func testAvoidingUnsafeRegionHandlesAllFourEdgesIndependently() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 30, leading: 40, bottom: 20, trailing: 50)
        // Trailing-edge overlap — the physical notch side is given
        // explicitly (see `PhysicalNotchSide`), not inferred from comparing
        // `leading`/`trailing` depths.
        let trailing = CGRect(x: 770, y: 100, width: 44, height: 44)
        let shiftedTrailing = ControlTrayGeometry.avoidingUnsafeRegion(trailing, in: container, safeInsets: insets, enabled: true, notchSide: .trailing)
        XCTAssertEqual(shiftedTrailing.maxX, 750)
        // Top overlap — independent of notchSide entirely.
        let top = CGRect(x: 378, y: 5, width: 44, height: 44)
        XCTAssertEqual(ControlTrayGeometry.avoidingUnsafeRegion(top, in: container, safeInsets: insets, enabled: true).minY, 30)
        // Bottom overlap — independent of notchSide entirely.
        let bottom = CGRect(x: 378, y: 370, width: 44, height: 44)
        XCTAssertEqual(ControlTrayGeometry.avoidingUnsafeRegion(bottom, in: container, safeInsets: insets, enabled: true).maxY, 380)
    }

    func testLeftSideNotchShiftsLeadingTrayInward() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)
        let on = ControlTrayGeometry.layout(
            container: container, safeInsets: leftNotch, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        XCTAssertGreaterThanOrEqual(on.trayFrame.minX, 40)
    }

    func testRightSideNotchShiftsTrailingTrayInward() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let rightNotch = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 40)
        let on = ControlTrayGeometry.layout(
            container: container, safeInsets: rightNotch, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .trailing)
        XCTAssertLessThanOrEqual(on.trayFrame.maxX, container.maxX - 40)
    }

    func testLeftTrayIsUnchangedByRightUnsafeInset() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        let raw = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil,
            portrait: false, side: .leading,
            traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 46, height: 330),
            avoidNotch: true)
        let rightUnsafe = ControlSafeInsets(top: 0, leading: 0, bottom: 21, trailing: 59)
        let resolved = ControlTrayGeometry.layout(
            container: container, safeInsets: rightUnsafe, keyboardVisibleRect: nil,
            portrait: false, side: .leading,
            traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 46, height: 330),
            avoidNotch: true, notchSide: .trailing)
        XCTAssertEqual(resolved.trayFrame.minX, raw.trayFrame.minX)
    }

    func testRightTrayIsUnchangedByLeftUnsafeInset() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        let raw = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil,
            portrait: false, side: .trailing,
            traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 46, height: 330),
            avoidNotch: true)
        let leftUnsafe = ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 0)
        let resolved = ControlTrayGeometry.layout(
            container: container, safeInsets: leftUnsafe, keyboardVisibleRect: nil,
            portrait: false, side: .trailing,
            traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 46, height: 330),
            avoidNotch: true, notchSide: .leading)
        XCTAssertEqual(resolved.trayFrame.maxX, raw.trayFrame.maxX)
    }

    func testCollapsedGearUsesTheSameNotchSafeMainTrayFrame() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        let leftUnsafe = ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 0)
        let gearSize = CGSize(width: 50, height: 50)
        let layout = ControlTrayGeometry.layout(
            container: container, safeInsets: leftUnsafe, keyboardVisibleRect: nil,
            portrait: false, side: .leading, traySize: gearSize,
            paletteSize: .zero, avoidNotch: true, notchSide: .leading)

        XCTAssertEqual(layout.trayFrame.minX, leftUnsafe.leading)
        XCTAssertEqual(layout.trayFrame.size, gearSize)

        let off = ControlTrayGeometry.layout(
            container: container, safeInsets: leftUnsafe, keyboardVisibleRect: nil,
            portrait: false, side: .leading, traySize: gearSize,
            paletteSize: .zero, avoidNotch: false, notchSide: .leading)
        XCTAssertEqual(off.trayFrame.minX, 12)
    }

    func testRuntimeSafeAreaReportRepairsZeroedSwiftUIInsetsAfterRotation() {
        let zeroedProxy = ControlSafeInsets.zero
        let landscapeWindow = ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 0)
        XCTAssertEqual(ControlSafeInsets.resolved(proxy: zeroedProxy, runtime: landscapeWindow),
                       landscapeWindow)

        // Rotating the other way swaps the physical sensor side. The live
        // snapshot replaces, rather than merges with, the stale proxy.
        let rotatedWindow = ControlSafeInsets(top: 0, leading: 0, bottom: 21, trailing: 59)
        XCTAssertEqual(ControlSafeInsets.resolved(proxy: landscapeWindow, runtime: rotatedWindow),
                       rotatedWindow)
        XCTAssertEqual(ControlSafeInsets.resolved(proxy: landscapeWindow, runtime: nil),
                       landscapeWindow)
    }

    func testTrayOnNonNotchSideIsUnaffected() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)
        let unaffected = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true)
        let withLeftNotch = ControlTrayGeometry.layout(
            container: container, safeInsets: leftNotch, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        // A trailing-side tray is unaffected by a leading-edge notch.
        XCTAssertEqual(unaffected.trayFrame, withLeftNotch.trayFrame)
    }

    func testAvoidNotchOffPreservesFullEdgePlacementEvenOverTheUnsafeStrip() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)
        let off = ControlTrayGeometry.layout(
            container: container, safeInsets: leftNotch, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: false, notchSide: .leading)
        // With Avoid Notch off, the tray sits at the literal screen edge,
        // ignoring the notch's inset entirely.
        XCTAssertEqual(off.trayFrame.minX, 12, accuracy: 0.5)
    }

    func testAvoidNotchOnWithNoActualMainTrayOverlapMatchesOffExactly() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        // A top sensor region is centered horizontally; this left-side
        // landscape tray never intersects it.
        let topUnsafe = ControlSafeInsets(top: 59, leading: 0, bottom: 0, trailing: 0)
        func layout(avoid: Bool) -> ControlTrayLayout {
            ControlTrayGeometry.layout(
                container: container, safeInsets: topUnsafe, keyboardVisibleRect: nil,
                portrait: false, side: .leading,
                traySize: CGSize(width: 44, height: 300),
                paletteSize: CGSize(width: 46, height: 330), avoidNotch: avoid)
        }
        XCTAssertEqual(layout(avoid: true), layout(avoid: false))
    }

    func testTemporaryPaletteUsesConditionalObstacleAvoidance() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        let leftNotch = ControlSafeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
        let clearPalette = CGRect(x: 12, y: 12, width: 46, height: 60)
        XCTAssertEqual(ControlTrayGeometry.avoidingUnsafeRegion(
            clearPalette, in: container, safeInsets: leftNotch, enabled: true, notchSide: .leading), clearPalette)

        let collidingPalette = CGRect(x: 12, y: 150, width: 46, height: 100)
        let shifted = ControlTrayGeometry.avoidingUnsafeRegion(
            collidingPalette, in: container, safeInsets: leftNotch, enabled: true, notchSide: .leading)
        XCTAssertEqual(shifted.minX, leftNotch.leading)
        XCTAssertEqual(shifted.minY, collidingPalette.minY)
    }

    func testResultingFrameStaysWithinVisibleBoundsWithAvoidNotch() {
        // Asymmetric so the trailing edge is the notch side under test; the
        // symmetric case (a real device CAN report equal depths on both
        // edges while still having a real, single-sided notch) is covered
        // separately below.
        let container = CGRect(x: 0, y: 0, width: 200, height: 150)
        let heavyInsets = ControlSafeInsets(top: 10, leading: 0, bottom: 10, trailing: 40)
        let layout = ControlTrayGeometry.layout(
            container: container, safeInsets: heavyInsets, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 120), paletteSize: CGSize(width: 42, height: 100),
            avoidNotch: true, notchSide: .trailing)
        let visible = CGRect(x: container.minX, y: heavyInsets.top,
                             width: container.width - heavyInsets.trailing,
                             height: container.height - heavyInsets.top - heavyInsets.bottom)
        XCTAssertTrue(visible.contains(layout.trayFrame))
    }

    /// The real-device failure this replaces: `leading=59, trailing=59`
    /// used to make the old leading/trailing-depth-comparison heuristic
    /// (`horizontalNotchSide`, now removed) conclude "no notch," even
    /// though the device had a real, single-sided physical notch. Depth
    /// comparison can never distinguish that case from actual symmetric
    /// rounded corners — only `UIInterfaceOrientation` can (see
    /// `PhysicalNotchSide`) — so equal insets must still produce an
    /// exclusion once the physical side is given explicitly.
    func testSymmetricSafeInsetsStillExcludeGivenAnExplicitNotchSide() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let symmetric = ControlSafeInsets(top: 0, leading: 59, bottom: 20, trailing: 59)
        let on = ControlTrayGeometry.layout(
            container: container, safeInsets: symmetric, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        XCTAssertGreaterThanOrEqual(on.trayFrame.minX, symmetric.leading)

        // The opposite (non-notch) side is unaffected by the same symmetric
        // insets, exactly as with an asymmetric notch.
        let unaffected = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true)
        let withSymmetricNotch = ControlTrayGeometry.layout(
            container: container, safeInsets: symmetric, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        XCTAssertEqual(unaffected.trayFrame, withSymmetricNotch.trayFrame)
    }

    /// `nil` (no known physical notch side) is the safe default — e.g. a
    /// non-notched device, or an orientation that isn't clearly landscape —
    /// and must not invent an obstacle on either edge even with sizable
    /// insets present.
    func testNoNotchSideProducesNoHorizontalObstacleEvenWithSizableInsets() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 40)
        let on = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: nil)
        let raw = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true)
        XCTAssertEqual(on.trayFrame, raw.trayFrame)
    }

    // MARK: - Notch side vs. tray side matrix

    func testPhysicalNotchLeftAndControlLeftIsDisplaced() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
        let layout = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        XCTAssertGreaterThanOrEqual(layout.trayFrame.minX, insets.leading)
    }

    func testPhysicalNotchLeftAndControlRightIsUnchanged() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
        let raw = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true)
        let withNotch = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .leading)
        XCTAssertEqual(raw.trayFrame, withNotch.trayFrame)
    }

    func testPhysicalNotchRightAndControlRightIsDisplaced() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 59)
        let layout = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .trailing)
        XCTAssertLessThanOrEqual(layout.trayFrame.maxX, container.maxX - insets.trailing)
    }

    func testPhysicalNotchRightAndControlLeftIsUnchanged() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 59)
        let raw = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true)
        let withNotch = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .trailing)
        XCTAssertEqual(raw.trayFrame, withNotch.trayFrame)
    }

    func testPortraitNeverTreatsSideInsetsAsANotch() {
        let container = CGRect(x: 0, y: 0, width: 400, height: 844)
        let sideInsets = ControlSafeInsets(top: 0, leading: 30, bottom: 0, trailing: 0)
        // `notchSide` given explicitly (as if a landscape reading were
        // stale) — portrait's own guard must still win.
        let on = ControlTrayGeometry.layout(
            container: container, safeInsets: sideInsets, keyboardVisibleRect: nil, portrait: true,
            side: .leading, traySize: CGSize(width: 260, height: 60), paletteSize: CGSize(width: 200, height: 60),
            avoidNotch: true, notchSide: .leading)
        let off = ControlTrayGeometry.layout(
            container: container, safeInsets: sideInsets, keyboardVisibleRect: nil, portrait: true,
            side: .leading, traySize: CGSize(width: 260, height: 60), paletteSize: CGSize(width: 200, height: 60),
            avoidNotch: false)
        XCTAssertEqual(on.trayFrame, off.trayFrame)
    }

    func testSchemaSixPreferencesDefaultAvoidNotchToTrue() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 6
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertTrue(migrated.avoidNotch)
    }

    func testAvoidNotchPersistsAcrossSaveAndLoad() throws {
        let suite = "ReceiverControlsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = ReceiverControlPreferences()
        preferences.avoidNotch = false
        repository.save(preferences)
        XCTAssertFalse(repository.load().avoidNotch)
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
    // MARK: - Physical notch side (orientation-derived)

    /// `UIInterfaceOrientation` describes how CONTENT rotates to compensate
    /// for the device — the opposite of the device's own physical rotation
    /// — confirmed against a real notched iPhone: `.landscapeLeft` (device
    /// rotated left) puts the physical notch on the screen's TRAILING edge.
    func testLandscapeLeftMapsToTrailingNotchSide() {
        XCTAssertEqual(PhysicalNotchSide.forLandscape(.landscapeLeft), .trailing)
    }

    /// `.landscapeRight` (device rotated right) puts the physical notch on
    /// the screen's LEADING edge.
    func testLandscapeRightMapsToLeadingNotchSide() {
        XCTAssertEqual(PhysicalNotchSide.forLandscape(.landscapeRight), .leading)
    }

    /// No landscape orientation (portrait, flat, or simply unknown) means no
    /// landscape notch side — never invented.
    func testNoLandscapeOrientationMapsToNoNotchSide() {
        XCTAssertNil(PhysicalNotchSide.forLandscape(nil))
    }
}
