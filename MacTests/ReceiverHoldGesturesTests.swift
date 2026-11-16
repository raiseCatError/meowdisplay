import XCTest

/// The registry of the receiver's touch-and-hold gestures (#131): what each delay is, and that
/// only the modifier-shortcut hold can be changed.
final class ReceiverHoldGesturesTests: XCTestCase {
    private func entry(_ id: String) throws -> ReceiverHoldGestures.Entry {
        try XCTUnwrap(ReceiverHoldGestures.all.first { $0.id == id }, id)
    }

    func testEveryHoldHasOneEntryWithAUsableDelay() {
        let ids = ReceiverHoldGestures.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "one entry per gesture")
        for e in ReceiverHoldGestures.all {
            XCTAssertGreaterThanOrEqual(e.seconds, 0.15, e.id)
            XCTAssertLessThanOrEqual(e.seconds, 0.6, e.id)
        }
    }

    func testOnlyTheModifierShortcutHoldIsAdjustable() throws {
        XCTAssertEqual(ReceiverHoldGestures.all.filter(\.adjustable).map(\.id), ["modifierShortcuts"])
        // Its registry value is the Standard choice, the shipped default.
        XCTAssertEqual(try entry("modifierShortcuts").seconds, ModifierHoldResponse.standard.delay)
        XCTAssertEqual(ReceiverControlPreferences().modifierHoldResponse, .standard)
    }

    func testTheShippedDelaysAreRecorded() throws {
        // A change to any of these is a change to what a hold means: it belongs in this list
        // and in RECEIVER_CONTROLS.md → Hold gestures, not only in the view that uses it.
        XCTAssertEqual(try entry("stagePeekEdge").seconds, 0.3)
        XCTAssertEqual(try entry("stagePeekCardDrag").seconds, 0.35)
        XCTAssertEqual(try entry("sessionActions").seconds, 0.5)
        XCTAssertEqual(try entry("paneLabel").seconds, 0.4)
        XCTAssertEqual(try entry("paneDivider").seconds, 0.35)
        XCTAssertEqual(try entry("touchHoldCommit").seconds, 0.15)
        XCTAssertEqual(try entry("naturalPress").seconds, 0.25)
        XCTAssertEqual(try entry("naturalRightClick").seconds, 0.5)
        XCTAssertEqual(try entry("smartTouchLongPress").seconds, 0.4)
        XCTAssertEqual(try entry("smartTouchTitleBar").seconds, 0.5)
    }

    func testTheGesturesThatReachTheMacOrEndASessionNeverGetFasterThanAModifierHold() throws {
        // Right click, a window drag and Session Actions (Disconnect) keep delays at least as long
        // as the slowest modifier choice a user can pick, so the Hold Response setting can never
        // make a modifier hold the quicker, more accidental gesture.
        let slowestModifier = ModifierHoldResponse.allCases.map(\.delay).max()!
        for id in ["naturalRightClick", "smartTouchTitleBar", "sessionActions"] {
            XCTAssertGreaterThanOrEqual(try entry(id).seconds, slowestModifier, id)
        }
    }

    func testTheModifierChoicesAreInOrderAndKeepRoomForATap() {
        let delays = ModifierHoldResponse.allCases.map(\.delay)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(Set(delays).count, delays.count)
        XCTAssertEqual(ModifierHoldResponse.allCases.map(\.rawValue), ["fast", "standard", "deliberate"])
    }
}
