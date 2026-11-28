import CoreGraphics
import XCTest

/// Rearrange Controls (Shared/ControlRearrangement.swift): the pure reorder
/// and persistence rules behind the iPhone/iPad Rearrange Controls sheet.
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

    // MARK: Moving rows

    func testListMovesAndSteps() {
        XCTAssertEqual(ControlRearrangement.listMove(from: [0], to: 3, count: 3).map { [$0.from, $0.to] }, [0, 2],
                       "dropped after the last row: it ends last")
        XCTAssertEqual(ControlRearrangement.listMove(from: [2], to: 0, count: 3).map { [$0.from, $0.to] }, [2, 0])
        XCTAssertEqual(ControlRearrangement.listMove(from: [1], to: 3, count: 4).map { [$0.from, $0.to] }, [1, 2])
        XCTAssertNil(ControlRearrangement.listMove(from: [1], to: 1, count: 3), "dropped where it was")
        XCTAssertNil(ControlRearrangement.listMove(from: [1], to: 2, count: 3), "dropped just after itself")
        XCTAssertNil(ControlRearrangement.listMove(from: [0, 1], to: 3, count: 3), "one row at a time")
        XCTAssertNil(ControlRearrangement.listMove(from: [5], to: 0, count: 3))
        XCTAssertEqual(ControlRearrangement.step(from: 0, by: 1, count: 3), 1)
        XCTAssertNil(ControlRearrangement.step(from: 0, by: -1, count: 3), "already first")
        XCTAssertNil(ControlRearrangement.step(from: 2, by: 1, count: 3), "already last")
    }

    func testAListMoveReordersTheTrayAsDrawn() {
        var profile = ControlProfile.canonical()
        let shown = profile.visibleTrayItems(landscape: false)
        guard shown.count >= 3, let move = ControlRearrangement.listMove(from: [0], to: shown.count, count: shown.count)
        else { return XCTFail("the canonical tray has buttons") }
        profile.moveShownTrayItem(shown: shown, from: move.from, to: move.to, landscape: false)
        XCTAssertEqual(profile.visibleTrayItems(landscape: false), Array(shown.dropFirst()) + [shown[0]])
        XCTAssertEqual(profile.visibleTrayItems(landscape: true), shown, "landscape keeps its own order")
    }

    func testRearrangingPortraitFunctionTrayLeavesLandscapeAlone() {
        var profile = FunctionTrayProfile.canonical()
        let before = profile.items(landscape: true).map(\.id)
        let shown = profile.visibleGroups(landscape: false).flatMap { $0 }.map(\.id)
        guard shown.count >= 2 else { return XCTFail("the default Function Tray has buttons") }
        profile.moveShownItem(shown: shown, from: 0, to: 1, landscape: false)
        XCTAssertNotEqual(profile.items(landscape: false).map(\.id), before)
        XCTAssertEqual(profile.items(landscape: true).map(\.id), before, "landscape keeps what it showed")
    }
}
