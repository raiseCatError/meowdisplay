import CoreGraphics
import XCTest

/// Rearrange Controls (Shared/ControlRearrangement.swift): the pure reorder,
/// persistence and jiggle rules behind the iPhone/iPad edit mode.
final class ControlRearrangementTests: XCTestCase {

    // MARK: Offering it

    func testOfferedOnlyWithATrayToRearrange() {
        XCTAssertTrue(ControlRearrangePolicy.available(trayShown: true, functionTrayShown: false, customLayout: false))
        XCTAssertTrue(ControlRearrangePolicy.available(trayShown: false, functionTrayShown: true, customLayout: false))
        XCTAssertFalse(ControlRearrangePolicy.available(trayShown: false, functionTrayShown: false, customLayout: false),
                       "only the gear is left")
        XCTAssertFalse(ControlRearrangePolicy.available(trayShown: true, functionTrayShown: true, customLayout: true),
                       "a Custom layout is arranged in its own editor")
    }

    func testSessionActionsListRearrangeOnlyOverTheLiveSession() {
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: true, presentation: .session,
                                                            canLockMac: true, canRearrangeControls: true),
                       [.backToHome, .rearrangeControls, .lockMac, .disconnect])
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: true, presentation: .session,
                                                            canRearrangeControls: false),
                       [.backToHome, .disconnect])
        XCTAssertEqual(ReceiverSessionActionsPolicy.actions(surfaceRetained: true,
                                                            presentation: .homeKeepingSession(macPeerID: "mac"),
                                                            canRearrangeControls: true),
                       [.disconnect], "no controls on Home")
    }

    func testChoosingRearrangeClosesTheOverlayAndRemembersTheKeyboard() {
        var state = ReceiverSessionActionsState()
        XCTAssertTrue(state.open(keyboardActive: true))
        XCTAssertEqual(state.choose(.rearrangeControls), .rearrangeControls(reopenKeyboardAfter: true))
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.surfaceInteractive(.session), "the screen decides input while editing, not the overlay")
    }

    func testEveryModifierOpensAPalette() {
        let profile = ControlProfile.canonical()
        XCTAssertEqual(ControlRearrangePolicy.paletteChord(for: .command, in: profile), ModifierChord([.command]))
        XCTAssertEqual(ControlRearrangePolicy.paletteChord(for: .option, in: profile), ModifierChord([.option]),
                       "an empty palette still opens, with its hint")
        XCTAssertNil(ControlRearrangePolicy.paletteChord(for: .escape, in: profile))
        XCTAssertNil(ControlRearrangePolicy.paletteChord(for: .settings, in: profile))
    }

    func testTapsBuildAChordLikeTheLiveTray() {
        let command = ControlRearrangePolicy.palette(after: nil, tapping: .command)
        XCTAssertEqual(command, ModifierChord([.command]))
        let commandOption = ControlRearrangePolicy.palette(after: command, tapping: .option)
        XCTAssertEqual(commandOption, ModifierChord([.command, .option]))
        XCTAssertEqual(ControlRearrangePolicy.palette(after: commandOption, tapping: .command), ModifierChord([.option]))
        XCTAssertNil(ControlRearrangePolicy.palette(after: command, tapping: .command))
    }

    func testBoundsOutlineEachClusterOfSlots() {
        let row = ControlRearrangement.stackSlots(center: CGPoint(x: 100, y: 50), horizontal: true,
                                                  count: 3, item: 40, spacing: 8)
        let apart = ControlRearrangement.stackSlots(center: CGPoint(x: 400, y: 50), horizontal: true,
                                                    count: 2, item: 40, spacing: 8)
        let clusters = ControlRearrangement.clusters(row + apart)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first, row.dropFirst().reduce(row[0]) { $0.union($1) })
    }

    // MARK: Portrait and landscape

    func testLandscapeKeepsItsOwnMainTrayOrder() {
        var profile = ControlProfile.canonical()
        let portrait = profile.visibleTrayItems
        profile.moveShownTrayItem(shown: portrait, from: 0, to: 2, landscape: true)
        XCTAssertEqual(profile.visibleTrayItems, portrait, "portrait is untouched")
        XCTAssertEqual(profile.visibleTrayItems(landscape: false), portrait)
        XCTAssertEqual(profile.visibleTrayItems(landscape: true), ControlRearrangement.moving(portrait, from: 0, to: 2))
        profile.moveShownTrayItem(shown: portrait, from: 1, to: 0)
        XCTAssertEqual(profile.visibleTrayItems, ControlRearrangement.moving(portrait, from: 1, to: 0))
        XCTAssertEqual(profile.visibleTrayItems(landscape: true), ControlRearrangement.moving(portrait, from: 0, to: 2),
                       "landscape is untouched by a portrait move")
        let decoded = try? JSONDecoder().decode(ControlProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testLandscapeKeepsItsOwnFunctionTrayOrder() {
        var tray = FunctionTrayProfile.canonical()
        let shown = tray.visibleItems.map(\.id)
        let groups = tray.visibleGroups.map { $0.map(\.id) }
        tray.moveShownItem(shown: shown, from: 0, to: shown.count - 1, landscape: true)
        XCTAssertEqual(tray.visibleGroups.map { $0.map(\.id) }, groups, "portrait is untouched")
        XCTAssertEqual(tray.visibleGroups(landscape: true).flatMap { $0 }.map(\.id),
                       ControlRearrangement.moving(shown, from: 0, to: shown.count - 1))
        XCTAssertEqual(tray.visibleGroups(landscape: true).map(\.count), groups.map(\.count), "clusters keep their sizes")
        let refreshed = tray.resolvingCanonicalMetadata()
        XCTAssertEqual(refreshed.landscapeOrder, tray.landscapeOrder, "a metadata refresh keeps the landscape order")
    }

    func testAProfileSavedBeforeLandscapeOrdersDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ControlProfile.canonical())) as! [String: Any]
        json.removeValue(forKey: "landscapeTrayOrder")
        let decoded = try JSONDecoder().decode(ControlProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.landscapeTrayOrder)
        XCTAssertEqual(decoded.visibleTrayItems(landscape: true), decoded.visibleTrayItems)
    }

    // MARK: Reordering

    func testMovingPutsTheElementAtItsFinalIndex() {
        XCTAssertEqual(ControlRearrangement.moving([0, 1, 2, 3], from: 0, to: 2), [1, 2, 0, 3])
        XCTAssertEqual(ControlRearrangement.moving([0, 1, 2, 3], from: 3, to: 0), [3, 0, 1, 2])
        XCTAssertEqual(ControlRearrangement.moving([0, 1, 2, 3], from: 1, to: 1), [0, 1, 2, 3])
        XCTAssertEqual(ControlRearrangement.moving([0, 1, 2, 3], from: 4, to: 0), [0, 1, 2, 3], "out of range")
    }

    func testReorderingShownLeavesEverythingElseInPlace() {
        let all = ["a", "H", "b", "c", "I", "d"]
        let shown = ["a", "b", "c", "d"]
        XCTAssertEqual(ControlRearrangement.reorderingShown(all, id: { $0 }, shown: shown, from: 0, to: 3),
                       ["b", "H", "c", "d", "I", "a"])
        XCTAssertEqual(ControlRearrangement.reorderingShown(all, id: { $0 }, shown: ["a", "x"], from: 0, to: 1), all,
                       "an id that isn't there changes nothing")
    }

    func testMainTrayOrderSkipsHiddenAndUnavailableItems() {
        var profile = ControlProfile.canonical()
        profile.trayItems[profile.trayItems.firstIndex { $0.item == .tab }!].isVisible = false
        // The tray as drawn: Tab hidden, Keyboard unavailable on this Mac.
        let shown = profile.visibleTrayItems.filter { $0 != .keyboard }
        let settings = shown.firstIndex(of: .settings)!
        profile.moveShownTrayItem(shown: shown, from: settings, to: 0)
        XCTAssertEqual(profile.trayItems.map(\.item),
                       [.settings, .command, .option, .control, .shift, .tab, .escape, .keyboard, .dock],
                       "the shown items pass along their own places; Tab and Keyboard keep theirs")
        XCTAssertFalse(profile.trayItems.first { $0.item == .tab }!.isVisible, "visibility is untouched")
    }

    func testPaletteKeysReorderAndPersist() throws {
        var preferences = ReceiverControlPreferences()
        var profile = preferences.profile(for: .default)
        let command = ModifierChord([.command])
        profile.moveAction(for: command, from: 0, to: 2)
        preferences.updateProfile(profile)
        XCTAssertEqual(Array(profile.actions(for: command).prefix(3)).map(\.id), ["paste", "cut", "copy"])

        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                               from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.profile(for: .default).actions(for: command).map(\.id),
                       profile.actions(for: command).map(\.id))
        XCTAssertEqual(decoded.profile(for: .profile1), ControlProfile.canonical(slot: .profile1),
                       "other profiles are untouched")
    }

    func testFunctionTrayClustersKeepTheirShape() {
        var profile = FunctionTrayProfile.canonical()
        let shown = profile.visibleItems.map(\.id)
        XCTAssertEqual(shown, ["zoom-in", "zoom-out", "undo", "redo", "return"])
        let before = profile.visibleGroups.map(\.count)
        // Return into the zoom cluster's first slot.
        profile.moveShownItem(shown: shown, from: 4, to: 0)
        XCTAssertEqual(profile.visibleItems.map(\.id), ["return", "zoom-in", "zoom-out", "undo", "redo"])
        XCTAssertEqual(profile.visibleGroups.map(\.count), before, "same clusters, buttons passed along")
        XCTAssertEqual(profile.visibleGroups.map { $0.map(\.id) },
                       [["return", "zoom-in"], ["zoom-out", "undo"], ["redo"]])
        XCTAssertEqual(profile.items.filter { !$0.isVisible }.map(\.id),
                       ["menu-bar", "launchpad", "show-desktop", "control-center"], "hidden actions stay put")
    }

    func testFunctionTrayOrderPersistsThroughTheSavedPreferences() throws {
        var preferences = ReceiverControlPreferences()
        var profile = preferences.functionTrayProfile(for: .default)
        profile.moveShownItem(shown: profile.visibleItems.map(\.id), from: 0, to: 1)
        preferences.updateFunctionTrayProfile(profile)
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                               from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.functionTrayProfile(for: .default).visibleItems.map(\.id),
                       ["zoom-out", "zoom-in", "undo", "redo", "return"])
    }

    // MARK: Slots

    func testNearestSlotAndSteps() {
        let slots = ControlRearrangement.stackSlots(center: CGPoint(x: 100, y: 50), horizontal: true,
                                                    count: 3, item: 40, spacing: 4)
        XCTAssertEqual(slots.map(\.midX), [56, 100, 144])
        XCTAssertEqual(slots.map(\.midY), [50, 50, 50])
        XCTAssertEqual(ControlRearrangement.nearestSlot(to: CGPoint(x: 130, y: 60), in: slots), 2)
        XCTAssertEqual(ControlRearrangement.nearestSlot(to: CGPoint(x: -500, y: 0), in: slots), 0)
        XCTAssertNil(ControlRearrangement.nearestSlot(to: .zero, in: []))
        XCTAssertTrue(ControlRearrangement.runsHorizontally(slots))
        XCTAssertFalse(ControlRearrangement.runsHorizontally(ControlRearrangement.stackSlots(
            center: .zero, horizontal: false, count: 3, item: 40, spacing: 4)))
        XCTAssertEqual(ControlRearrangement.step(from: 0, by: 1, count: 3), 1)
        XCTAssertNil(ControlRearrangement.step(from: 0, by: -1, count: 3), "already first")
        XCTAssertNil(ControlRearrangement.step(from: 2, by: 1, count: 3), "already last")
    }

    func testPaletteGridFitsAndCentres() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
        let slots = ControlRearrangement.gridSlots(count: 9, key: 38, gap: 8, maximumColumns: 5,
                                                   center: CGPoint(x: 100, y: 200), bounds: bounds)
        XCTAssertEqual(slots.count, 9)
        XCTAssertEqual(Set(slots.map(\.minY)).count, 3, "4 columns fit 200pt, so three rows")
        XCTAssertTrue(slots.allSatisfy { bounds.contains($0) })
        XCTAssertEqual(slots[0].minX + slots[3].maxX, 200, accuracy: 0.001, "centred")
    }

    // MARK: Jiggle

    func testJiggleMatchesTheHomeScreenRangeAndVariesPerIcon() {
        let ids = ["tray:command", "tray:option", "tray:escape", "shortcut:undo", "shortcut:redo"]
        let motions = ids.map(ControlJiggleMotion.init(id:))
        for motion in motions {
            XCTAssertTrue(ControlJiggleMotion.amplitudeRange.contains(motion.amplitude))
            XCTAssertTrue(ControlJiggleMotion.periodRange.contains(motion.period))
            XCTAssertTrue(ControlJiggleMotion.bobRange.contains(motion.bob))
            for step in 0..<50 {
                let t = Double(step) * 0.017
                XCTAssertLessThanOrEqual(abs(motion.angle(at: t)), 2.0 + 1e-9)
                XCTAssertLessThanOrEqual(abs(motion.offset(at: t)), 1.0 + 1e-9)
            }
        }
        XCTAssertEqual(Set(motions.map(\.phase)).count, ids.count, "no two icons in lockstep")
        XCTAssertEqual(ControlJiggleMotion(id: "tray:command"), motions[0], "an icon keeps its rhythm")
    }
}
