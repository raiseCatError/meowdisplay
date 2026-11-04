import CoreGraphics
import XCTest

/// On-screen arrow keys (#179): tap versus swipe on the compact button,
/// holding a key on the keypad, the keypad's hit areas and where the button
/// and keypad sit among the other controls.
final class ArrowKeyNavigationTests: XCTestCase {
    // MARK: - Directions

    func testDirectionsSendTheMacArrowKeyUsages() {
        XCTAssertEqual(ArrowKeyDirection.right.usage, 79)
        XCTAssertEqual(ArrowKeyDirection.left.usage, 80)
        XCTAssertEqual(ArrowKeyDirection.down.usage, 81)
        XCTAssertEqual(ArrowKeyDirection.up.usage, 82)
    }

    func testEveryDirectionHasASpokenName() {
        XCTAssertEqual(Set(ArrowKeyDirection.allCases.map(\.title)).count, 4)
        XCTAssertEqual(ArrowKeyDirection.up.title, "Up Arrow")
    }

    func testTheButtonFollowsTheKeyboardGates() {
        XCTAssertTrue(ArrowKeysAvailability.isShown(enabled: true, allowInput: true, keyboardAvailable: true))
        XCTAssertFalse(ArrowKeysAvailability.isShown(enabled: false, allowInput: true, keyboardAvailable: true))
        XCTAssertFalse(ArrowKeysAvailability.isShown(enabled: true, allowInput: false, keyboardAvailable: true))
        XCTAssertFalse(ArrowKeysAvailability.isShown(enabled: true, allowInput: true, keyboardAvailable: false))
    }

    // MARK: - Compact button: tap or swipe

    func testATapOrASmallWobbleTogglesTheKeypad() {
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: .zero, cancelled: false), .toggleKeypad)
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 6, height: -7), cancelled: false), .toggleKeypad)
    }

    func testADeliberateSwipeSendsOnePressInItsDirection() {
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 40, height: 5), cancelled: false), .press(.right))
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: -40, height: -8), cancelled: false), .press(.left))
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 3, height: 30), cancelled: false), .press(.down))
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: -9, height: -32), cancelled: false), .press(.up))
    }

    func testAnAmbiguousOrCancelledGestureSendsNothing() {
        // Past tap range but short of a swipe.
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 16, height: 0), cancelled: false), .nothing)
        // A diagonal.
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 40, height: 35), cancelled: false), .nothing)
        // A cancelled swipe or tap (the system took the touch).
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: CGSize(width: 60, height: 0), cancelled: true), .nothing)
        XCTAssertEqual(ArrowButtonGesture.outcome(translation: .zero, cancelled: true), .nothing)
    }

    func testThePreviewShowsOnlyWhatAReleaseWouldSend() {
        XCTAssertNil(ArrowButtonGesture.direction(of: CGSize(width: 12, height: 0)))
        XCTAssertEqual(ArrowButtonGesture.direction(of: CGSize(width: 0, height: -30)), .up)
        XCTAssertNil(ArrowButtonGesture.direction(of: CGSize(width: 30, height: -30)))
    }

    // MARK: - Preferences

    func testArrowKeysDefaultOnAtTheRight() {
        let preferences = ReceiverControlPreferences()
        XCTAssertTrue(preferences.arrowKeysEnabled)
        XCTAssertEqual(preferences.arrowKeysSide, .trailing)
    }

    func testAnOlderSaveGainsTheDefaultsAndKeepsEverythingElse() throws {
        var stored = ReceiverControlPreferences()
        stored.preferredLandscapeSide = .leading
        stored.functionTrayPosition = .sameSide
        stored.hapticsEnabled = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        json["arrowKeysEnabled"] = nil
        json["arrowKeysSide"] = nil
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.arrowKeysEnabled)
        XCTAssertEqual(decoded.arrowKeysSide, .trailing)
        XCTAssertEqual(decoded.preferredLandscapeSide, .leading)
        XCTAssertEqual(decoded.functionTrayPosition, .sameSide)
        XCTAssertFalse(decoded.hapticsEnabled)
    }

    func testAStoredChoiceIsKept() throws {
        var stored = ReceiverControlPreferences()
        stored.arrowKeysEnabled = false
        stored.arrowKeysSide = .leading
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self, from: JSONEncoder().encode(stored))
        XCTAssertFalse(decoded.arrowKeysEnabled)
        XCTAssertEqual(decoded.arrowKeysSide, .leading)
    }

    // MARK: - Modifiers

    func testAnArrowNeverChangesALatchedChord() {
        var state = ControlInteractionState()
        _ = state.tap(.shift)
        XCTAssertEqual(state.promotePressedModifier(), [])
        XCTAssertEqual(state.latchedModifiers, [.shift])
        XCTAssertEqual(state.activeChord, ModifierChord([.shift]))
    }

    func testAnArrowDuringAModifierPressHoldsItFirst() {
        // ⌘ is touched but hasn't become a latch or hold yet: nothing is down
        // on the Mac, so an arrow now must hold ⌘ first, as a long press would,
        // and the later lift must not latch it.
        var state = ControlInteractionState()
        state.press(.command)
        XCTAssertEqual(state.promotePressedModifier(), [.modifierDown(.command), .haptic(.selection)])
        XCTAssertEqual(state.activeChord, ModifierChord([.command]))
        XCTAssertEqual(state.finish(with: nil), [.modifierUp(.command)])
        XCTAssertTrue(state.latchedModifiers.isEmpty)
    }

    func testWithNoModifierAnArrowChangesNothing() {
        var state = ControlInteractionState()
        XCTAssertEqual(state.promotePressedModifier(), [])
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Keypad: key down, repeat, key up

    func testATapIsOneKeyDownAndOneKeyUp() {
        var hold = ArrowKeyHold()
        XCTAssertEqual(hold.move(to: .left, now: 0), [.down(.left)])
        XCTAssertNil(hold.tick(now: 0.1))
        XCTAssertEqual(hold.release(), .up(.left))
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.tick(now: 1))
    }

    func testReleaseIsSafeToRepeat() {
        var hold = ArrowKeyHold()
        XCTAssertNil(hold.release())
        _ = hold.move(to: .up, now: 0)
        XCTAssertEqual(hold.release(), .up(.up))
        XCTAssertNil(hold.release())
        XCTAssertEqual(hold.move(to: nil, now: 1), [])
    }

    func testStayingOnTheSameKeySendsNothingNew() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .down, now: 0)
        XCTAssertEqual(hold.move(to: .down, now: 0.05), [])
    }

    func testHoldingRepeatsAfterTheInitialDelayAtABoundedRate() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .down, now: 10)
        XCTAssertNil(hold.tick(now: 10 + ArrowKeyHold.initialDelay - 0.01))
        var repeats = 0
        var t = 10.0
        while t < 12 {   // 2 s of holding, ticked every 10 ms
            if let event = hold.tick(now: t) {
                XCTAssertEqual(event, .repeat(.down))
                repeats += 1
            }
            t += 0.01
        }
        let expected = (2 - ArrowKeyHold.initialDelay) / ArrowKeyHold.interval
        XCTAssertEqual(Double(repeats), expected.rounded(.up), accuracy: 2)
        XCTAssertLessThanOrEqual(Double(repeats) / 2, 1 / ArrowKeyHold.interval)
    }

    func testALateTickSendsOneRepeatNotABurst() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .right, now: 0)
        // The app stalled for a second: one repeat, then back to the normal pace.
        XCTAssertEqual(hold.tick(now: 1.5), .repeat(.right))
        XCTAssertNil(hold.tick(now: 1.5))
        XCTAssertNil(hold.tick(now: 1.5 + ArrowKeyHold.interval * 0.9))
        XCTAssertEqual(hold.tick(now: 1.5 + ArrowKeyHold.interval), .repeat(.right))
    }

    func testNoRepeatAfterTheKeyIsUp() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .up, now: 0)
        XCTAssertEqual(hold.tick(now: 0.5), .repeat(.up))
        XCTAssertEqual(hold.release(), .up(.up))
        XCTAssertNil(hold.tick(now: 0.6))
        XCTAssertNil(hold.tick(now: 5))
        XCTAssertNil(hold.nextRepeatAt)
    }

    func testSlidingToAnotherKeyReleasesTheFirstAndRestartsTheDelay() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .up, now: 0)
        XCTAssertEqual(hold.tick(now: 0.5), .repeat(.up))
        XCTAssertEqual(hold.move(to: .left, now: 0.52), [.up(.up), .down(.left)])
        XCTAssertNil(hold.tick(now: 0.6))
        XCTAssertEqual(hold.tick(now: 0.52 + ArrowKeyHold.initialDelay), .repeat(.left))
    }

    func testSlidingOffTheKeypadReleasesTheKey() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .right, now: 0)
        XCTAssertEqual(hold.move(to: nil, now: 0.2), [.up(.right)])
        XCTAssertNil(hold.tick(now: 1))
    }

    // MARK: - Keypad hit areas

    func testTheKeypadIsAnInvertedT() {
        let size = ArrowKeypadGeometry.size(key: 42, gap: 4)
        XCTAssertEqual(size, CGSize(width: 134, height: 88))
        let keys = ArrowKeypadGeometry.keyFrames(key: 42, gap: 4)
        XCTAssertEqual(keys[.up]?.midX, keys[.down]?.midX)
        XCTAssertLessThan(keys[.up]!.maxY, keys[.down]!.minY)
        XCTAssertEqual(keys[.left]?.midY, keys[.right]?.midY)
        XCTAssertLessThan(keys[.left]!.maxX, keys[.down]!.minX)
        XCTAssertLessThan(keys[.down]!.maxX, keys[.right]!.minX)
    }

    func testEachKeyAnswersAcrossItsWholeCellAndTheCornersAreEmpty() {
        let keys = ArrowKeypadGeometry.keyFrames(key: 42, gap: 4)
        for direction in ArrowKeyDirection.allCases {
            let frame = keys[direction]!
            XCTAssertEqual(ArrowKeypadGeometry.direction(at: CGPoint(x: frame.midX, y: frame.midY), key: 42, gap: 4), direction)
        }
        // The gap between ← and ↓ belongs to one of them: sliding never drops out.
        XCTAssertNotNil(ArrowKeypadGeometry.direction(at: CGPoint(x: 44, y: 67), key: 42, gap: 4))
        // Above ← and above → is no key; so is anywhere off the keypad.
        XCTAssertNil(ArrowKeypadGeometry.direction(at: CGPoint(x: 10, y: 10), key: 42, gap: 4))
        XCTAssertNil(ArrowKeypadGeometry.direction(at: CGPoint(x: 124, y: 10), key: 42, gap: 4))
        XCTAssertNil(ArrowKeypadGeometry.direction(at: CGPoint(x: 67, y: 120), key: 42, gap: 4))
    }

    // MARK: - Placement among the other controls

    private struct Scene {
        var main: CGRect
        var function: [CGRect]
        var palette: CGRect?
        var arrows: ArrowKeysLayout
        var container: CGRect
        var others: [CGRect] { [main] + function + (palette.map { [$0] } ?? []) }
    }

    private static let toggle = CGSize(width: 44, height: 44)
    private static let keypad = ArrowKeypadGeometry.size(key: 42, gap: 4)

    /// A 6.1" iPhone with the default Main Tray (all nine controls) and the
    /// default Function Tray (Zoom; Undo/Redo; Return), laid out by the real
    /// geometry the overlay uses.
    private func phone(portrait: Bool = false, arrowSide: LandscapeTraySide,
                       mainSide: LandscapeTraySide = .trailing,
                       position: FunctionTrayPosition = .oppositeSide,
                       keypadOpen: Bool = false, paletteKeys: Int = 0) -> Scene {
        let container = portrait ? CGRect(x: 0, y: 0, width: 393, height: 852)
                                 : CGRect(x: 0, y: 0, width: 852, height: 393)
        let safe = portrait ? ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
                            : ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let item = ControlTrayGeometry.fittedChipDiameter(count: 9, length: portrait ? 393 : 393)
        let length = 9 * item + 8 * 4 + 4
        let traySize = portrait ? CGSize(width: length, height: item + 4) : CGSize(width: item + 4, height: length)
        func span(_ n: Int) -> CGFloat { CGFloat(n) * 38 + CGFloat(max(0, n - 1)) * 5 + 4 }
        let paletteSize = paletteKeys == 0 ? .zero
            : (portrait ? CGSize(width: span(paletteKeys), height: span(1)) : CGSize(width: span(1), height: span(paletteKeys)))
        let layout = ControlTrayGeometry.layout(
            container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: portrait,
            side: mainSide, traySize: traySize, paletteSize: paletteSize, avoidNotch: true,
            notchSide: portrait ? nil : .leading)
        let main = CGRect(x: layout.trayFrame.midX - traySize.width / 2, y: layout.trayFrame.midY - traySize.height / 2,
                          width: traySize.width, height: traySize.height)
        let palette = paletteKeys == 0 ? nil : layout.paletteFrame
        let two = portrait ? CGSize(width: 88, height: 44) : CGSize(width: 44, height: 88)
        let function = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: portrait,
            mainSide: layout.side, position: position, mainTrayFrame: main,
            groupSizes: [two, two, CGSize(width: 44, height: 44)], avoiding: palette, avoidNotch: true,
            notchSide: portrait ? nil : .leading, bottomRow: true)
        let others = [main] + function + (palette.map { [$0] } ?? [])
        let arrows = ControlTrayGeometry.arrowKeysLayout(
            container: container, safeInsets: safe, portrait: portrait, side: arrowSide,
            toggleSize: Self.toggle, keypadSize: keypadOpen ? Self.keypad : nil,
            mainTrayFrame: main, obstacles: others, avoidNotch: true, notchSide: portrait ? nil : .leading)
        return Scene(main: main, function: function, palette: palette, arrows: arrows, container: container)
    }

    private func assertClear(_ scene: Scene, file: StaticString = #filePath, line: UInt = #line) {
        for frame in scene.arrows.occupied {
            XCTAssertTrue(scene.container.contains(frame), "\(frame) leaves the screen", file: file, line: line)
            for other in scene.others {
                XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)", file: file, line: line)
            }
        }
        if let keypad = scene.arrows.keypad {
            XCTAssertFalse(keypad.intersects(scene.arrows.toggle), file: file, line: line)
        }
    }

    func testLandscapeRightSitsInTheLowerRightBesideTheMainTray() {
        let scene = phone(arrowSide: .trailing)
        let toggle = scene.arrows.toggle
        assertClear(scene)
        XCTAssertGreaterThan(toggle.midX, scene.container.midX)
        XCTAssertGreaterThanOrEqual(toggle.maxY, scene.container.maxY - 12 - 21)   // the bottom row
        XCTAssertLessThanOrEqual(toggle.maxX, scene.main.minX)
        XCTAssertLessThan(scene.main.minX - toggle.maxX, 20)                      // right beside it
    }

    func testLandscapeLeftSitsBesideReturn() {
        let scene = phone(arrowSide: .leading)
        let returnKey = scene.function[2]
        assertClear(scene)
        XCTAssertLessThan(scene.arrows.toggle.midX, scene.container.midX)
        XCTAssertEqual(scene.arrows.toggle.midY, returnKey.midY, accuracy: 1)
        XCTAssertEqual(scene.arrows.toggle.minX - returnKey.maxX, 10, accuracy: 1)
    }

    func testSameSideFunctionTrayStillPutsTheButtonBesideReturn() {
        let scene = phone(arrowSide: .trailing, position: .sameSide)
        let returnKey = scene.function[2]
        assertClear(scene)
        XCTAssertEqual(scene.arrows.toggle.midY, returnKey.midY, accuracy: 1)
        XCTAssertEqual(returnKey.minX - scene.arrows.toggle.maxX, 10, accuracy: 1)
    }

    func testOpeningTheKeypadNeverMovesTheButton() {
        for side in LandscapeTraySide.allCases {
            for portrait in [false, true] {
                let closed = phone(portrait: portrait, arrowSide: side)
                let open = phone(portrait: portrait, arrowSide: side, keypadOpen: true)
                XCTAssertEqual(closed.arrows.toggle, open.arrows.toggle, "\(side) portrait=\(portrait)")
                XCTAssertNil(closed.arrows.keypad)
                let keypad = try! XCTUnwrap(open.arrows.keypad)
                XCTAssertLessThanOrEqual(keypad.maxY, open.arrows.toggle.minY, "opens above the button")
                assertClear(open)
            }
        }
    }

    func testTheKeypadMovesInwardRatherThanOverTheMainTray() {
        let scene = phone(arrowSide: .trailing, keypadOpen: true)
        let keypad = try! XCTUnwrap(scene.arrows.keypad)
        XCTAssertLessThanOrEqual(keypad.maxX, scene.main.minX)
        // Still over the button, not off somewhere else.
        XCTAssertLessThanOrEqual(keypad.minX, scene.arrows.toggle.minX)
    }

    func testPortraitSitsAtTheChosenEndAboveTheMainTray() {
        for side in LandscapeTraySide.allCases {
            let scene = phone(portrait: true, arrowSide: side)
            assertClear(scene)
            XCTAssertLessThanOrEqual(scene.arrows.toggle.maxY, scene.main.minY)
            if side == .trailing {
                XCTAssertGreaterThan(scene.arrows.toggle.midX, scene.container.midX)
            } else {
                XCTAssertLessThan(scene.arrows.toggle.midX, scene.container.midX)
            }
        }
    }

    func testAnOpenPaletteNeverCoversTheButtonOrKeypad() {
        for side in LandscapeTraySide.allCases {
            assertClear(phone(arrowSide: side, keypadOpen: true, paletteKeys: 7))
            assertClear(phone(portrait: true, arrowSide: side, keypadOpen: true, paletteKeys: 6))
        }
    }

    func testMainTrayOnTheLeftKeepsBothSidesClear() {
        for side in LandscapeTraySide.allCases {
            assertClear(phone(arrowSide: side, mainSide: .leading, keypadOpen: true))
        }
    }

    func testReservedRegionsAreAvoided() {
        let container = CGRect(x: 0, y: 0, width: 852, height: 393)
        // A system-reserved occlusion right where the button would go.
        let occlusion = ControlReservedRegion(kind: .occlusion, frame: CGRect(x: 760, y: 320, width: 80, height: 73))
        let layout = ControlTrayGeometry.arrowKeysLayout(
            container: container, safeInsets: .zero, portrait: false, side: .trailing,
            toggleSize: Self.toggle, keypadSize: Self.keypad, mainTrayFrame: .zero, obstacles: [],
            avoidNotch: true, reservedRegions: [occlusion])
        XCTAssertFalse(layout.toggle.intersects(occlusion.frame))
        XCTAssertFalse(layout.keypad!.intersects(occlusion.frame))
    }
}
