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
                       [.command, .option, .control, .shift, .escape, .tab, .dock, .keyboard, .settings])
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
        preferences.showSurfaceGrid = false
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

    func testSchemaEightPreferencesDefaultSurfaceGridOn() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 8
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "showSurfaceGrid")
        defaults.set(try JSONSerialization.data(withJSONObject: object),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertTrue(migrated.showSurfaceGrid)
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

    // MARK: - Function Tray

    func testDefaultFunctionTrayContainsZoomAndEditActionsInOrder() {
        let profile = FunctionTrayProfile.canonical()
        XCTAssertEqual(profile.visibleItems.map(\.id), ["zoom-in", "zoom-out", "undo", "redo"])
        XCTAssertEqual(profile.visibleItems.map(\.title), ["Zoom In", "Zoom Out", "Undo", "Redo"])
    }

    func testDefaultFunctionTrayRendersAsTwoDistinctGroups() {
        let profile = FunctionTrayProfile.canonical()
        let groups = profile.visibleGroups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.id), ["zoom-in", "zoom-out"])
        XCTAssertEqual(groups[1].map(\.id), ["undo", "redo"])
    }

    func testZoomInResolvesToCommandPlus() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "zoom-in" })
        guard case .keyboardShortcut(let shortcut) = item.action else { return XCTFail("expected a keyboard shortcut") }
        XCTAssertEqual(shortcut.usage, HIDKeyUsage.equal.rawValue)
        XCTAssertEqual(shortcut.modifiers, ModifierChord([.command]))
    }

    func testZoomOutResolvesToCommandMinus() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "zoom-out" })
        guard case .keyboardShortcut(let shortcut) = item.action else { return XCTFail("expected a keyboard shortcut") }
        XCTAssertEqual(shortcut.usage, HIDKeyUsage.minus.rawValue)
        XCTAssertEqual(shortcut.modifiers, ModifierChord([.command]))
    }

    func testUndoResolvesToCommandZ() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "undo" })
        guard case .keyboardShortcut(let shortcut) = item.action else { return XCTFail("expected a keyboard shortcut") }
        XCTAssertEqual(shortcut.usage, HIDKeyUsage.keyZ.rawValue)
        XCTAssertEqual(shortcut.modifiers, ModifierChord([.command]))
    }

    func testRedoResolvesToShiftCommandZ() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "redo" })
        guard case .keyboardShortcut(let shortcut) = item.action else { return XCTFail("expected a keyboard shortcut") }
        XCTAssertEqual(shortcut.usage, HIDKeyUsage.keyZ.rawValue)
        XCTAssertEqual(shortcut.modifiers, ModifierChord([.command, .shift]))
    }

    func testHIDKeyUsageMinusAndEqualParseAndMapToCorrectKeyCodes() {
        XCTAssertEqual(HIDKeyUsage.parse(45 as NSNumber), .minus)
        XCTAssertEqual(HIDKeyUsage.parse(46 as NSNumber), .equal)
        XCTAssertEqual(HIDKeyUsage.minus.keyCode, 27)
        XCTAssertEqual(HIDKeyUsage.equal.keyCode, 24)
    }

    func testMainTrayOwnsToggleDockNotFunctionTray() {
        let mainItems = ControlProfile.canonical().visibleTrayItems
        let dockIndex = try? XCTUnwrap(mainItems.firstIndex(of: .dock))
        let keyboardIndex = try? XCTUnwrap(mainItems.firstIndex(of: .keyboard))
        XCTAssertEqual(dockIndex.map { $0 + 1 }, keyboardIndex)
        XCTAssertEqual(ControlTrayItem.dock.title, "Toggle Dock")
        XCTAssertEqual(ControlTrayItem.dock.displayLabel, "dock.rectangle")
        let functionIDs = FunctionTrayProfile.canonical().visibleItems.map(\.id)
        XCTAssertFalse(functionIDs.contains("dock"))
        XCTAssertFalse(functionIDs.contains { $0.lowercased().contains("dock") })
    }

    func testOldFunctionTrayItemsResolveCanonicalSymbolsWithoutLosingCustomization() {
        var saved = FunctionTrayProfile.canonical(slot: .profile1)
        saved.items.reverse()
        saved.items[0].isVisible = false
        saved.items[0].group = 42
        for index in saved.items.indices {
            saved.items[index].item.systemImage = nil
            saved.items[index].item.title = "Old \(saved.items[index].item.id)"
        }

        let resolved = saved.resolvingCanonicalMetadata()
        XCTAssertEqual(resolved.items.map(\.id), saved.items.map(\.id))
        XCTAssertFalse(resolved.items[0].isVisible)
        XCTAssertEqual(resolved.items[0].group, 42)
        XCTAssertEqual(resolved.items.first { $0.id == "zoom-in" }?.item.systemImage,
                       "plus.magnifyingglass")
        XCTAssertEqual(resolved.items.first { $0.id == "zoom-out" }?.item.systemImage,
                       "minus.magnifyingglass")
        XCTAssertEqual(resolved.items.first { $0.id == "undo" }?.item.systemImage,
                       "arrow.uturn.backward")
        XCTAssertEqual(resolved.items.first { $0.id == "redo" }?.item.systemImage,
                       "arrow.uturn.forward")
        XCTAssertEqual(resolved.items.first { $0.id == "undo" }?.item.title, "Undo")
    }

    func testSchemaSevenProfilesGainDockImmediatelyBeforeKeyboard() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 7
        for index in old.profiles.indices {
            old.profiles[index].trayItems.removeAll { $0.item == .dock }
        }
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        for profile in migrated.profiles {
            let dock = try XCTUnwrap(profile.trayItems.firstIndex { $0.item == .dock })
            let keyboard = try XCTUnwrap(profile.trayItems.firstIndex { $0.item == .keyboard })
            XCTAssertEqual(dock + 1, keyboard)
            XCTAssertEqual(profile.trayItems[dock].isVisible, profile.slot == .default)
        }
    }

    func testSameSideFunctionGroupsAvoidRenderedMainTrayWhenMiddleCannotFit() {
        let container = CGRect(x: 0, y: 0, width: 844, height: 390)
        let renderedMain = CGRect(x: 12, y: -3, width: 44, height: 396)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil,
            portrait: false, mainSide: .leading, position: .sameSide,
            mainTrayFrame: renderedMain,
            groupSizes: [CGSize(width: 44, height: 88), CGSize(width: 44, height: 88)],
            avoiding: nil, avoidNotch: true)

        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { !$0.intersects(renderedMain) })
        XCTAssertTrue(frames.allSatisfy { container.contains($0) })
    }

    func testFunctionTrayProfilesPersistIndependentlyFromMainTrayProfiles() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)

        var preferences = ReceiverControlPreferences()
        preferences.activeControlProfile = .profile2
        preferences.activeFunctionTrayProfile = .profile1
        var mainProfile1 = preferences.profile(for: .profile1)
        mainProfile1.trayItems[0].isVisible = false
        preferences.updateProfile(mainProfile1)
        var functionProfile1 = preferences.functionTrayProfile(for: .profile1)
        functionProfile1.items[0].isVisible = false
        preferences.updateFunctionTrayProfile(functionProfile1)
        repository.save(preferences)

        let loaded = repository.load()
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(loaded.activeControlProfile, .profile2)
        XCTAssertEqual(loaded.activeFunctionTrayProfile, .profile1)
        XCTAssertFalse(loaded.profile(for: .profile1).trayItems[0].isVisible)
        XCTAssertFalse(loaded.functionTrayProfile(for: .profile1).items[0].isVisible)
        // Changing one tray's profile 1 never touched the other's.
        XCTAssertEqual(loaded.functionTrayProfile(for: .profile2), .canonical(slot: .profile2))
        XCTAssertEqual(loaded.profile(for: .profile2), .canonical(slot: .profile2))
    }

    func testVisibilityAndOrderChangesDoNotMergeMainAndFunctionProfileState() {
        var preferences = ReceiverControlPreferences()
        var mainProfile = preferences.profile(for: .default)
        mainProfile.moveTrayItems(from: [0], to: mainProfile.trayItems.count)
        preferences.updateProfile(mainProfile)
        // The Function Tray's default profile — untouched by the Main Tray
        // edit above — still reads exactly as canonical.
        XCTAssertEqual(preferences.functionTrayProfile(for: .default), .canonical(slot: .default))

        var functionProfile = preferences.functionTrayProfile(for: .default)
        functionProfile.items[0].isVisible = false
        preferences.updateFunctionTrayProfile(functionProfile)
        // And the Main Tray edit from above is still intact after that.
        XCTAssertEqual(preferences.profile(for: .default), mainProfile)
    }

    func testSchemaFivePreferencesDefaultFunctionTrayToEnabledWithCanonicalProfiles() throws {
        let suite = "ReceiverControlsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var old = ReceiverControlPreferences()
        old.version = 5
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let migrated = repository.load()
        XCTAssertEqual(migrated.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertTrue(migrated.functionTrayEnabled)
        XCTAssertEqual(migrated.functionTrayPosition, .sameSide)
        XCTAssertEqual(migrated.functionTrayProfile(for: .default), .canonical(slot: .default))
    }

    func testFunctionTrayHiddenWhenAllowInputOff() {
        var preferences = ReceiverControlPreferences()
        XCTAssertTrue(preferences.functionTrayCanBeShown)
        preferences.allowInput = false
        XCTAssertFalse(preferences.functionTrayCanBeShown)
        // Independent of the Main Tray's own visibility, which reacts the
        // same way to the same single `allowInput` gate.
        XCTAssertFalse(preferences.trayCanBeShown)
        preferences.allowInput = true
        preferences.functionTrayEnabled = false
        XCTAssertFalse(preferences.functionTrayCanBeShown)
        XCTAssertTrue(preferences.trayCanBeShown)   // Main Tray unaffected by Function Tray's own toggle
    }

    // MARK: - Function Tray layout / collision avoidance

    private let functionContainer = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let functionGroupSizes = [CGSize(width: 44, height: 90), CGSize(width: 44, height: 90)]

    func testFunctionTraySameSideAnchorsZoomAboveAndEditBelowMainTrayWithoutOverlap() {
        let mainFrame = CGRect(x: 300, y: 120, width: 44, height: 60)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: functionContainer, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .sameSide,
            mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: nil, avoidNotch: false)
        XCTAssertEqual(frames.count, 2)
        let zoom = frames[0], edit = frames[1]
        // Both hug the Main Tray's own (trailing) side.
        XCTAssertGreaterThan(zoom.midX, 200)
        XCTAssertGreaterThan(edit.midX, 200)
        // Zoom above, Edit below, neither overlapping the Main Tray or each other.
        XCTAssertLessThan(zoom.maxY, mainFrame.minY)
        XCTAssertGreaterThan(edit.minY, mainFrame.maxY)
        XCTAssertFalse(zoom.intersects(mainFrame))
        XCTAssertFalse(edit.intersects(mainFrame))
        XCTAssertFalse(zoom.intersects(edit))
        // Zoom anchors toward the top of the available space, Edit toward the bottom.
        XCTAssertLessThan(zoom.minY, functionContainer.midY)
        XCTAssertGreaterThan(edit.maxY, functionContainer.midY)
    }

    func testFunctionTrayOppositeSideUsesTheOtherEdgeIndependentlyOfMainTray() {
        let mainFrame = CGRect(x: 300, y: 120, width: 44, height: 60)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: functionContainer, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .oppositeSide,
            mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: nil, avoidNotch: false)
        // Opposite of the Main Tray's trailing side — hugs leading instead,
        // nowhere near the Main Tray's own frame — and top/bottom anchoring
        // is independent of where the Main Tray happens to sit.
        for frame in frames {
            XCTAssertLessThan(frame.midX, 200)
            XCTAssertFalse(frame.intersects(mainFrame))
        }
        XCTAssertLessThan(frames[0].minY, frames[1].minY)
    }

    func testFunctionTrayDisplacesAroundACollidingPaletteThenReturns() {
        let mainFrame = CGRect(x: 300, y: 120, width: 44, height: 60)
        func layout(avoiding: CGRect?) -> [CGRect] {
            ControlTrayGeometry.functionTrayLayout(
                container: functionContainer, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
                mainSide: .trailing, position: .sameSide,
                mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: avoiding, avoidNotch: false)
        }
        let undisplaced = layout(avoiding: nil)
        // A palette that exactly covers where the Zoom group would sit.
        let collidingPalette = undisplaced[0].insetBy(dx: -2, dy: -2)
        let displaced = layout(avoiding: collidingPalette)

        XCTAssertFalse(displaced[0].intersects(collidingPalette))
        XCTAssertNotEqual(displaced[0], undisplaced[0])
        // The uninvolved (Edit) group is untouched.
        XCTAssertEqual(displaced[1], undisplaced[1])

        // The palette closing (avoiding: nil) returns it to the exact
        // original position — no permanent reservation of the moved-to spot.
        XCTAssertEqual(layout(avoiding: nil), undisplaced)
    }

    func testLeftSameSideLivePaletteMovesOnlyTopGroupAndReturnsExactly() {
        assertSameSidePaletteMovement(side: .leading, collidingGroup: 0)
    }

    func testRightSameSideLivePaletteMovesOnlyTopGroupAndReturnsExactly() {
        assertSameSidePaletteMovement(side: .trailing, collidingGroup: 0)
    }

    func testSameSideBottomPaletteCollisionMovesOnlyBottomGroup() {
        assertSameSidePaletteMovement(side: .leading, collidingGroup: 1)
    }

    private func assertSameSidePaletteMovement(side: LandscapeTraySide,
                                               collidingGroup: Int,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        // A tall rendered Main Tray forces the working Same Side base
        // fallback inward. This is the real-device geometry that exposed
        // the old palette->main displacement loop.
        let mainX: CGFloat = side == .leading ? 12 : 344
        let main = CGRect(x: mainX, y: 20, width: 44, height: 260)
        func layout(palette: CGRect?) -> [CGRect] {
            ControlTrayGeometry.functionTrayLayout(
                container: functionContainer, safeInsets: .zero,
                keyboardVisibleRect: nil, portrait: false,
                mainSide: side, position: .sameSide,
                mainTrayFrame: main, groupSizes: functionGroupSizes,
                avoiding: palette, avoidNotch: false)
        }

        let closed = layout(palette: nil)
        let palette = closed[collidingGroup].insetBy(dx: -2, dy: -2)
        let open = layout(palette: palette)
        let other = collidingGroup == 0 ? 1 : 0

        XCTAssertNotEqual(open[collidingGroup], closed[collidingGroup], file: file, line: line)
        XCTAssertFalse(open[collidingGroup].intersects(palette), file: file, line: line)
        XCTAssertFalse(open[collidingGroup].intersects(main), file: file, line: line)
        XCTAssertEqual(open[other], closed[other], file: file, line: line)
        // `nil` models `paletteChord` closing: geometry is stateless and
        // recomputes the exact base frame used by SwiftUI's frame animation.
        XCTAssertEqual(layout(palette: nil), closed, file: file, line: line)
    }

    func testOppositeSideMovesOnlyForActualPaletteIntersection() {
        let main = CGRect(x: 344, y: 100, width: 44, height: 100)
        func layout(palette: CGRect?) -> [CGRect] {
            ControlTrayGeometry.functionTrayLayout(
                container: functionContainer, safeInsets: .zero,
                keyboardVisibleRect: nil, portrait: false,
                mainSide: .trailing, position: .oppositeSide,
                mainTrayFrame: main, groupSizes: functionGroupSizes,
                avoiding: palette, avoidNotch: false)
        }
        let base = layout(palette: nil)
        XCTAssertEqual(layout(palette: CGRect(x: 300, y: 120, width: 44, height: 60)), base)

        let palette = base[0].insetBy(dx: -2, dy: -2)
        let moved = layout(palette: palette)
        XCTAssertNotEqual(moved[0], base[0])
        XCTAssertFalse(moved[0].intersects(palette))
        XCTAssertEqual(moved[1], base[1])
    }

    func testPaletteDisplacementRemainsClearOfUnsafeRegion() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let safe = ControlSafeInsets(top: 0, leading: 50, bottom: 0, trailing: 0)
        let main = CGRect(x: 50, y: 100, width: 44, height: 200)
        let base = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: safe, keyboardVisibleRect: nil,
            portrait: false, mainSide: .leading, position: .sameSide,
            mainTrayFrame: main, groupSizes: functionGroupSizes,
            avoiding: nil, avoidNotch: true)
        let palette = base[0].insetBy(dx: -2, dy: -2)
        let moved = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: safe, keyboardVisibleRect: nil,
            portrait: false, mainSide: .leading, position: .sameSide,
            mainTrayFrame: main, groupSizes: functionGroupSizes,
            avoiding: palette, avoidNotch: true)

        XCTAssertFalse(moved[0].intersects(palette))
        XCTAssertFalse(moved[0].intersects(main))
        XCTAssertGreaterThanOrEqual(moved[0].minX, safe.leading)
        XCTAssertTrue(container.contains(moved[0]))
    }

    func testFunctionTrayLayoutIsANoOpWhenNotActuallyColliding() {
        let mainFrame = CGRect(x: 300, y: 120, width: 44, height: 60)
        let farAwayPalette = CGRect(x: 0, y: 0, width: 20, height: 20)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: functionContainer, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .sameSide,
            mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: farAwayPalette, avoidNotch: false)
        for frame in frames { XCTAssertFalse(frame.intersects(farAwayPalette)) }
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

    func testNonIntersectingFunctionTrayGroupsStayAtExactRawFrames() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)
        let mainFrame = CGRect(x: 700, y: 120, width: 44, height: 60)
        func layout(avoid: Bool) -> [CGRect] {
            ControlTrayGeometry.functionTrayLayout(
                container: container, safeInsets: leftNotch, keyboardVisibleRect: nil, portrait: false,
                mainSide: .trailing, position: .oppositeSide,
                mainTrayFrame: mainFrame, groupSizes: functionGroupSizes,
                avoiding: nil, avoidNotch: avoid, notchSide: .leading)
        }
        XCTAssertEqual(layout(avoid: true), layout(avoid: false))
    }

    func testIntersectingFunctionTrayGroupMovesOnlyMinimumDistance() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let leftNotch = ControlSafeInsets(top: 0, leading: 40, bottom: 0, trailing: 0)
        let mainFrame = CGRect(x: 700, y: 120, width: 44, height: 60)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: leftNotch, keyboardVisibleRect: nil,
            portrait: false, mainSide: .trailing, position: .oppositeSide,
            mainTrayFrame: mainFrame, groupSizes: [CGSize(width: 44, height: 200)],
            avoiding: nil, avoidNotch: true, notchSide: .leading)
        XCTAssertEqual(frames[0].minX, leftNotch.leading)
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

    // MARK: - Main Tray / Function Tray independence

    /// Both trays share one geometry/avoidance path
    /// (`ControlTrayGeometry.avoidingUnsafeRegion`, fed the same `notchSide`)
    /// but are evaluated against their OWN actual rendered frame — a Main
    /// Tray and Function Tray on opposite sides must not move together.
    func testMainTrayAndFunctionTrayOnOppositeSidesOnlyTheIntersectingOneMoves() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        // Notch on the right; Main Tray on the right (intersects), Function
        // Tray on the left (opposite side — never intersects).
        let insets = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 59)
        let mainLayout = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .trailing, traySize: CGSize(width: 44, height: 300), paletteSize: CGSize(width: 42, height: 260),
            avoidNotch: true, notchSide: .trailing)
        XCTAssertLessThanOrEqual(mainLayout.trayFrame.maxX, container.maxX - insets.trailing)

        let mainFrame = CGRect(x: mainLayout.trayFrame.midX - 22, y: mainLayout.trayFrame.midY - 150,
                               width: 44, height: 300)
        let functionRaw = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .oppositeSide,
            mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: nil, avoidNotch: true)
        let functionWithNotch = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .oppositeSide,
            mainTrayFrame: mainFrame, groupSizes: functionGroupSizes, avoiding: nil,
            avoidNotch: true, notchSide: .trailing)
        // The Function Tray (opposite/left side) is untouched by the
        // right-side notch even though the Main Tray (right side) moved.
        XCTAssertEqual(functionRaw, functionWithNotch)
    }

    /// Main Tray and Function Tray on the SAME side both avoid the notch
    /// when it intersects them, independently, each shifted only its own
    /// minimum distance.
    func testMainTrayAndFunctionTrayOnTheSameSideBothAvoidTheNotch() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 400)
        let insets = ControlSafeInsets(top: 0, leading: 59, bottom: 0, trailing: 0)
        // Main Tray near the bottom, out of the group's way.
        let mainLayout = ControlTrayGeometry.layout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            side: .leading, traySize: CGSize(width: 44, height: 60), paletteSize: CGSize(width: 42, height: 60),
            avoidNotch: true, notchSide: .leading)
        XCTAssertGreaterThanOrEqual(mainLayout.trayFrame.minX, insets.leading)
        let lowMainFrame = CGRect(x: mainLayout.trayFrame.minX, y: 340, width: 44, height: 60)

        // A single tall group anchored from the top corner — at height 200
        // starting at y=12, it spans into the notch's vertical band
        // (centered on the container, per `unsafeRegions`) and must be
        // pushed clear exactly like the Main Tray was, independently.
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: insets, keyboardVisibleRect: nil, portrait: false,
            mainSide: .leading, position: .sameSide,
            mainTrayFrame: lowMainFrame, groupSizes: [CGSize(width: 44, height: 200)], avoiding: nil,
            avoidNotch: true, notchSide: .leading)
        XCTAssertEqual(frames[0].minX, insets.leading)
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

    // MARK: - Function Tray icons

    func testUndoUsesUndoArrowSymbol() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "undo" })
        XCTAssertEqual(item.systemImage, "arrow.uturn.backward")
    }

    func testRedoUsesRedoArrowSymbol() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "redo" })
        XCTAssertEqual(item.systemImage, "arrow.uturn.forward")
    }

    func testZoomInUsesMagnifierPlusSymbol() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "zoom-in" })
        XCTAssertEqual(item.systemImage, "plus.magnifyingglass")
    }

    func testZoomOutUsesMagnifierMinusSymbol() throws {
        let item = try XCTUnwrap(FunctionTrayProfile.canonical().visibleItems.first { $0.id == "zoom-out" })
        XCTAssertEqual(item.systemImage, "minus.magnifyingglass")
    }

    func testMainTrayPaletteShortcutsHaveNoSystemImageByDefault() {
        // Main Tray palette shortcuts keep their plain keycap presentation —
        // adding `systemImage` never touched their existing definitions.
        let copy = ControlProfile.canonical().actions(for: ModifierChord([.command])).first { $0.id == "copy" }
        XCTAssertNil(copy?.systemImage)
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

    func testPortraitTrackpadSurfaceUsesMostAvailableHeightAndClearsControls() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)
        let tray = CGRect(x: 40, y: 770, width: 310, height: 50)
        let surface = VideoOffSurfaceGeometry.interactionRect(
            container: container,
            safeInsets: ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            occupiedControlFrames: [tray], portrait: true, inputMode: .trackpad,
            remoteAspectSize: CGSize(width: 1920, height: 1080))
        XCTAssertGreaterThan(surface.height, surface.width)
        XCTAssertGreaterThan(surface.height, 650)
        XCTAssertGreaterThanOrEqual(surface.minY, 69)
        XCTAssertLessThanOrEqual(surface.maxY, tray.minY - VideoOffSurfaceGeometry.controlGap)
    }

    func testDirectVideoOffSurfacePreservesRemoteAspectInsideSameAvailableRegion() {
        let surface = VideoOffSurfaceGeometry.interactionRect(
            container: CGRect(x: 0, y: 0, width: 390, height: 844),
            safeInsets: ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            occupiedControlFrames: [CGRect(x: 50, y: 770, width: 290, height: 50)],
            portrait: true, inputMode: .direct,
            remoteAspectSize: CGSize(width: 16, height: 9))
        XCTAssertEqual(surface.width / surface.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(surface.minY, 69)
        XCTAssertLessThanOrEqual(surface.maxY, 760)
    }

    func testGesturePreferencesDefaultAndMigrateWithoutOverwritingOldChoices() throws {
        let suite = "ReceiverGestureMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReceiverControlPreferences()
        old.version = 9
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let loaded = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertEqual(loaded.pinchTarget, .viewport)
        XCTAssertEqual(loaded.rotateTarget, .viewport)
        XCTAssertTrue(loaded.snapRotation)
        XCTAssertEqual(loaded.version, ReceiverControlPreferences.schemaVersion)
    }

    func testAudioPreferencesMigrateInDisabledAndCentered() throws {
        let suite = "AudioPreferenceMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReceiverControlPreferences()
        old.version = 11
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let loaded = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertFalse(loaded.audioPreferred)
        XCTAssertEqual(loaded.avSyncOffsetMs, 0)
        XCTAssertEqual(loaded.version, ReceiverControlPreferences.schemaVersion)
    }

    func testAudioPreferencesPersistAcrossSaveAndLoad() throws {
        let suite = "AudioPreferencePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ReceiverControlPreferences()
        preferences.audioPreferred = true
        preferences.avSyncOffsetMs = -250
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        repository.save(preferences)
        let loaded = repository.load()
        XCTAssertTrue(loaded.audioPreferred)
        XCTAssertEqual(loaded.avSyncOffsetMs, -250)
    }

    func testAudioSyncOffsetClampsOnDecodeOfOutOfRangeValue() throws {
        let suite = "AudioOffsetClampTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ReceiverControlPreferences()
        preferences.avSyncOffsetMs = 5_000   // out of range if ever written by a future build
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        repository.save(preferences)
        let loaded = repository.load()
        XCTAssertEqual(loaded.avSyncOffsetMs, AVSyncOffset.range.upperBound)
    }

    // MARK: - App Gesture Commands

    func testAppGestureCommandDefaultsMatchSpec() {
        let defaults = AppGestureCommands.defaults
        XCTAssertEqual(defaults.zoomIn, KeyboardShortcut(usage: 46, modifiers: ModifierChord([.command])))
        XCTAssertEqual(defaults.zoomOut, KeyboardShortcut(usage: 45, modifiers: ModifierChord([.command])))
        XCTAssertEqual(defaults.rotateLeft, KeyboardShortcut(usage: 47, modifiers: ModifierChord([.command])))
        XCTAssertEqual(defaults.rotateRight, KeyboardShortcut(usage: 48, modifiers: ModifierChord([.command])))
    }

    func testAppGestureCommandsMigrateInWithCanonicalDefaults() throws {
        let suite = "AppGestureCommandMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReceiverControlPreferences()
        old.version = 10
        defaults.set(try JSONEncoder().encode(old),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let loaded = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertEqual(loaded.appGestureCommands, AppGestureCommands.defaults)
        XCTAssertEqual(loaded.version, ReceiverControlPreferences.schemaVersion)
    }

    func testAppGestureCommandsPersistAcrossSaveAndLoad() throws {
        let suite = "AppGestureCommandPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = ReceiverControlPreferences()
        preferences.appGestureCommands.setShortcut(
            KeyboardShortcut(usage: 6, modifiers: ModifierChord([.option, .shift])), for: .zoomIn)
        repository.save(preferences)
        XCTAssertEqual(repository.load().appGestureCommands.zoomIn,
                       KeyboardShortcut(usage: 6, modifiers: ModifierChord([.option, .shift])))
    }

    func testResetAppGestureCommandsRestoresOnlyTheFourDefaultsNotUnrelatedSettings() {
        var preferences = ReceiverControlPreferences()
        preferences.appGestureCommands.setShortcut(
            KeyboardShortcut(usage: 6, modifiers: ModifierChord([.control])), for: .rotateRight)
        preferences.pinchTarget = .app
        preferences.rotateTarget = .app
        preferences.snapRotation = false
        preferences.avoidNotch = false

        preferences.resetAppGestureCommands()

        XCTAssertEqual(preferences.appGestureCommands, AppGestureCommands.defaults)
        // Unrelated settings — including the gesture targets themselves —
        // are untouched by this reset (spec section G).
        XCTAssertEqual(preferences.pinchTarget, .app)
        XCTAssertEqual(preferences.rotateTarget, .app)
        XCTAssertFalse(preferences.snapRotation)
        XCTAssertFalse(preferences.avoidNotch)
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
