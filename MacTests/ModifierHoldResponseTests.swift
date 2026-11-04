import CoreGraphics
import XCTest

/// Modifier tray responsiveness (#131): the hold that opens a modifier's
/// shortcuts, sliding toward them, and touches the system takes away.
final class ModifierHoldResponseTests: XCTestCase {
    func testStandardIsTheDefaultAndFasterThanBefore() {
        XCTAssertEqual(ReceiverControlPreferences().modifierHoldResponse, .standard)
        XCTAssertLessThan(ModifierHoldResponse.standard.delay, 0.35)
        XCTAssertLessThan(ModifierHoldResponse.fast.delay, ModifierHoldResponse.standard.delay)
        XCTAssertGreaterThan(ModifierHoldResponse.deliberate.delay, ModifierHoldResponse.standard.delay)
    }

    func testEveryChoiceLeavesRoomForATap() {
        // A deliberate tap lasts about a tenth of a second; none of the
        // choices may turn one into a hold.
        for response in ModifierHoldResponse.allCases {
            XCTAssertGreaterThanOrEqual(response.delay, 0.15, response.rawValue)
            XCTAssertLessThanOrEqual(response.delay, 0.5, response.rawValue)
        }
    }

    func testAnOlderSaveGetsStandardAndKeepsEverythingElse() throws {
        var stored = ReceiverControlPreferences()
        stored.hapticsEnabled = false
        stored.preferredLandscapeSide = .leading
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        json["modifierHoldResponse"] = nil
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.modifierHoldResponse, .standard)
        XCTAssertFalse(decoded.hapticsEnabled)
        XCTAssertEqual(decoded.preferredLandscapeSide, .leading)
    }

    func testAChoiceIsKeptAndAnUnknownOneFallsBack() throws {
        var stored = ReceiverControlPreferences()
        stored.modifierHoldResponse = .deliberate
        let data = try JSONEncoder().encode(stored)
        XCTAssertEqual(try JSONDecoder().decode(ReceiverControlPreferences.self, from: data).modifierHoldResponse,
                       .deliberate)
        // A value from a later build never resets the rest.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["modifierHoldResponse"] = "instant"
        json["hapticsEnabled"] = false
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.modifierHoldResponse, .standard)
        XCTAssertFalse(decoded.hapticsEnabled)
    }

    // MARK: - Sliding toward the palette

    func testASmallWobbleKeepsWaitingAndASlideOpensThePalette() {
        XCTAssertFalse(ModifierPressPolicy.slideOpensPalette(translation: .zero))
        XCTAssertFalse(ModifierPressPolicy.slideOpensPalette(translation: CGSize(width: 6, height: 7)))
        XCTAssertTrue(ModifierPressPolicy.slideOpensPalette(translation: CGSize(width: 0, height: -14)))
    }

    func testASlideThenLiftOnNothingLatchesNothing() {
        var state = ControlInteractionState()
        state.press(.command)
        // The slide opens the palette at once; the lift lands on no shortcut.
        XCTAssertEqual(state.beginPalette(with: .command), [.modifierDown(.command), .haptic(.selection)])
        XCTAssertEqual(state.finish(with: nil), [.modifierUp(.command)])
        XCTAssertTrue(state.latchedModifiers.isEmpty)
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Touches the system takes

    func testACancelledPressLatchesNothingAndSendsNothing() {
        var state = ControlInteractionState()
        state.press(.option)
        XCTAssertEqual(state.cancelPress(), [])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.latchedModifiers.isEmpty)
    }

    func testACancelledPressKeepsAnEarlierLatch() {
        var state = ControlInteractionState()
        _ = state.tap(.shift)
        state.press(.command)
        XCTAssertEqual(state.cancelPress(), [])
        XCTAssertEqual(state.latchedModifiers, [.shift])
        XCTAssertEqual(state.phase, .latched(ModifierChord([.shift])))
    }

    func testACancelledHoldLetsGoAndFiresNothing() {
        var state = ControlInteractionState()
        state.press(.command)
        _ = state.beginPalette(with: .command)
        _ = state.addTemporaryModifier(.shift)
        _ = state.selectAction("copy")
        let effects = state.cancelPress()
        XCTAssertFalse(effects.contains { if case .execute = $0 { return true } else { return false } })
        let released: Set<ControlModifier> = Set(effects.compactMap { effect -> ControlModifier? in
            if case .modifierUp(let modifier) = effect { return modifier } else { return nil }
        })
        XCTAssertEqual(released, [.command, .shift])
        XCTAssertTrue(state.temporaryModifiers.isEmpty)
        XCTAssertNil(state.selectedActionID)
        XCTAssertEqual(state.phase, .idle)
    }
}
