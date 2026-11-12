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
                       keypadOpen: Bool = false, paletteKeys: Int = 0, withModifiers: Bool = false) -> Scene {
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
        let arrows = withModifiers
            ? ControlTrayGeometry.arrowKeysLayoutWithModifiers(
                container: container, safeInsets: safe, portrait: portrait, side: arrowSide,
                toggleSize: Self.toggle, keypadOpen: keypadOpen, key: 42, gap: 4,
                mainTrayFrame: main, obstacles: others, avoidNotch: true, notchSide: portrait ? nil : .leading)
            : ControlTrayGeometry.arrowKeysLayout(
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
        if let modifiers = scene.arrows.modifiers {
            XCTAssertFalse(modifiers.intersects(scene.arrows.toggle), file: file, line: line)
            XCTAssertFalse(modifiers.intersects(scene.arrows.keypad ?? .null), file: file, line: line)
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

    // MARK: - Keyboard bar item

    private static let barKeypad = ArrowKeypadGeometry.size(key: 42, gap: 4)

    func testWithTheKeyboardUpTheKeypadOpensAboveTheBarItem() {
        // A 6.1" iPhone in portrait with the keyboard and typing strip up.
        let safe = CGRect(x: 0, y: 59, width: 393, height: 759)
        let bar = CGRect(x: 23, y: 400, width: 347, height: 44)
        let item = CGRect(x: 290, y: 406, width: 32, height: 32)
        let keypad = ControlTrayGeometry.keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                                                 keypadSize: Self.barKeypad, palette: nil)
        XCTAssertEqual(keypad.maxY, bar.minY - 10, accuracy: 0.5)
        XCTAssertTrue(safe.insetBy(dx: 12, dy: 12).contains(keypad))
        XCTAssertLessThanOrEqual(keypad.minX, item.midX)
        XCTAssertGreaterThanOrEqual(keypad.maxX, item.midX)
    }

    func testAnOpenPaletteAboveTheBarPushesTheKeypadHigher() {
        let safe = CGRect(x: 0, y: 59, width: 393, height: 759)
        let bar = CGRect(x: 23, y: 400, width: 347, height: 44)
        let item = CGRect(x: 290, y: 406, width: 32, height: 32)
        let palette = CGRect(x: 20, y: 300, width: 353, height: 90)
        let keypad = ControlTrayGeometry.keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                                                 keypadSize: Self.barKeypad, palette: palette)
        XCTAssertFalse(keypad.intersects(palette))
        XCTAssertEqual(keypad.maxY, palette.minY - 10, accuracy: 0.5)
    }

    func testInLandscapeWithTheKeyboardUpTheKeypadSitsBesideTheBar() {
        // iPhone landscape: the keyboard leaves about 90 pt above the bar.
        let safe = CGRect(x: 59, y: 0, width: 734, height: 372)
        let bar = CGRect(x: 225, y: 89, width: 402, height: 44)
        let item = CGRect(x: 540, y: 95, width: 38, height: 38)
        let keypad = ControlTrayGeometry.keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                                                 keypadSize: Self.barKeypad, palette: nil)
        XCTAssertFalse(keypad.intersects(bar))
        XCTAssertEqual(keypad.maxY, bar.maxY, accuracy: 0.5, "bottoms aligned, never over the keyboard")
        XCTAssertEqual(keypad.minX, bar.maxX + 10, accuracy: 0.5)
        XCTAssertTrue(safe.contains(keypad))
    }

    func testTheKeyboardBarKeypadNeverGoesBelowTheBar() {
        // No room above or beside: it may overlap the picture, never the keyboard.
        let safe = CGRect(x: 0, y: 0, width: 400, height: 140)
        let bar = CGRect(x: 0, y: 40, width: 400, height: 44)
        let item = CGRect(x: 300, y: 46, width: 32, height: 32)
        let keypad = ControlTrayGeometry.keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                                                 keypadSize: Self.barKeypad, palette: nil)
        XCTAssertLessThanOrEqual(keypad.maxY, bar.maxY)
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

    // MARK: - Keypad modifiers: tap, latch, hold

    func testATapLatchesAModifierAndASecondTapUnlatchesIt() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.touchDown(.shift)
        XCTAssertEqual(modifiers.active, [.shift], "on while the finger is down")
        XCTAssertTrue(modifiers.lift(.shift))
        XCTAssertEqual(modifiers.latched, [.shift])
        XCTAssertEqual(modifiers.active, [.shift], "a latch stays on after the lift")
        XCTAssertEqual(modifiers.keyDown(available: true), [.shift])
        XCTAssertEqual(modifiers.keyDown(available: true), [.shift], "and applies to every arrow")

        modifiers.touchDown(.shift)
        XCTAssertTrue(modifiers.lift(.shift))
        XCTAssertTrue(modifiers.latched.isEmpty)
        XCTAssertEqual(modifiers.keyDown(available: true), [])
    }

    func testModifiersCombine() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.command)
        modifiers.toggle(.shift)
        modifiers.toggle(.option)
        XCTAssertEqual(modifiers.keyDown(available: true), [.shift, .option, .command])
        XCTAssertEqual(ArrowKeypadModifiers.wireNames([.shift, .option, .command]), ["command", "option", "shift"])
        XCTAssertEqual(ArrowKeypadModifiers.wireNames([.shift]), ["shift"])
        XCTAssertEqual(ArrowKeypadModifiers.wireNames([]), [])
    }

    func testHoldingAModifierAppliesItOnlyWhileHeld() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.touchDown(.option)
        XCTAssertEqual(modifiers.keyDown(available: true), [.option], "an arrow pressed while ⌥ is held")
        XCTAssertFalse(modifiers.lift(.option), "a hold that carried an arrow doesn't latch")
        XCTAssertTrue(modifiers.isEmpty)
        XCTAssertEqual(modifiers.keyDown(available: true), [])
    }

    func testAHoldOnALatchedModifierKeepsTheLatch() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.command)
        modifiers.touchDown(.command)
        XCTAssertEqual(modifiers.keyDown(available: true), [.command])
        XCTAssertFalse(modifiers.lift(.command))
        XCTAssertEqual(modifiers.latched, [.command])
    }

    func testHoldingOneWhileAnotherIsLatched() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.shift)
        modifiers.touchDown(.command)
        XCTAssertEqual(modifiers.keyDown(available: true), [.shift, .command])
        modifiers.lift(.command)
        XCTAssertEqual(modifiers.keyDown(available: true), [.shift])
    }

    func testSlidingOffOrACancelledTouchChangesNothing() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.touchDown(.shift)
        modifiers.cancelTouch(.shift)
        XCTAssertTrue(modifiers.isEmpty)
        // A late lift after the cancel finds nothing to toggle.
        XCTAssertFalse(modifiers.lift(.shift))
        XCTAssertTrue(modifiers.latched.isEmpty)

        modifiers.toggle(.option)
        modifiers.touchDown(.option)
        modifiers.cancelTouch(.option)
        XCTAssertEqual(modifiers.latched, [.option], "a cancelled touch never unlatches")
    }

    func testALiftWithoutATouchDoesNothing() {
        var modifiers = ArrowKeypadModifiers()
        XCTAssertFalse(modifiers.lift(.shift))
        XCTAssertTrue(modifiers.isEmpty)
    }

    func testOnlyShiftOptionAndCommandBelongToTheKeypad() {
        XCTAssertEqual(ArrowKeypadModifiers.keys, [.shift, .option, .command])
        var modifiers = ArrowKeypadModifiers()
        modifiers.touchDown(.control)
        XCTAssertFalse(modifiers.toggle(.control))
        XCTAssertTrue(modifiers.isEmpty)
    }

    func testClosingTheKeypadOrAResetClearsEverything() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.shift)
        modifiers.touchDown(.command)
        modifiers.clear()
        XCTAssertTrue(modifiers.isEmpty)
        XCTAssertEqual(modifiers.keyDown(available: true), [])
        // A finger still on a key when the keypad closed lifts into nothing.
        XCTAssertFalse(modifiers.lift(.command))
        XCTAssertTrue(modifiers.isEmpty)
    }

    // MARK: - Keypad modifiers: an older Mac

    func testANewMacKeepsTheKeypadAndTheTrayApart() {
        XCTAssertTrue(ArrowKeypadModifiers.isAvailable(macSupportsExactModifiers: true, trayChord: []))
        XCTAssertTrue(ArrowKeypadModifiers.isAvailable(macSupportsExactModifiers: true, trayChord: [.command]))
    }

    func testAnOlderMacAllowsKeypadModifiersOnlyWhileTheTrayHoldsNone() {
        XCTAssertTrue(ArrowKeypadModifiers.isAvailable(macSupportsExactModifiers: false, trayChord: []))
        XCTAssertFalse(ArrowKeypadModifiers.isAvailable(macSupportsExactModifiers: false, trayChord: [.command]))
        XCTAssertFalse(ArrowKeypadModifiers.isAvailable(macSupportsExactModifiers: false, trayChord: [.control]))
    }

    func testUnavailableModifiersAreDroppedNotHidden() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.shift)
        modifiers.touchDown(.option)
        XCTAssertFalse(modifiers.reconcile(available: true), "nothing changes while available")
        XCTAssertEqual(modifiers.active, [.shift, .option])
        // A tray modifier on an older Mac: the arrow carries none of the
        // keypad's, and they don't come back when the tray's goes.
        XCTAssertEqual(modifiers.keyDown(available: false), [])
        XCTAssertTrue(modifiers.reconcile(available: false))
        XCTAssertTrue(modifiers.isEmpty)
        XCTAssertFalse(modifiers.reconcile(available: false))
        XCTAssertEqual(modifiers.keyDown(available: true), [])
    }

    // MARK: - Keypad modifiers: the key down decides

    func testAHeldArrowKeepsTheModifiersItWentDownWith() {
        var modifiers = ArrowKeypadModifiers()
        modifiers.toggle(.shift)
        var hold = ArrowKeyHold()
        XCTAssertEqual(hold.move(to: .right, now: 0, modifiers: modifiers.keyDown(available: true)),
                       [.down(.right, modifiers: [.shift])])
        // ⇧ off and ⌘ on while the key is held: its repeats and up don't change.
        modifiers.toggle(.shift)
        modifiers.toggle(.command)
        XCTAssertEqual(hold.move(to: .right, now: 0.1, modifiers: modifiers.keyDown(available: true)), [])
        XCTAssertEqual(hold.tick(now: ArrowKeyHold.initialDelay), .repeat(.right, modifiers: [.shift]))
        XCTAssertEqual(hold.release(), .up(.right, modifiers: [.shift]))
        XCTAssertTrue(hold.heldModifiers.isEmpty)
    }

    func testSlidingToAnotherKeyReleasesWithTheOldModifiersAndPressesWithTheNew() {
        var hold = ArrowKeyHold()
        _ = hold.move(to: .left, now: 0, modifiers: [.option])
        XCTAssertEqual(hold.move(to: .down, now: 0.2, modifiers: [.command]),
                       [.up(.left, modifiers: [.option]), .down(.down, modifiers: [.command])])
        XCTAssertEqual(hold.tick(now: 0.2 + ArrowKeyHold.initialDelay), .repeat(.down, modifiers: [.command]))
        XCTAssertEqual(hold.move(to: nil, now: 1), [.up(.down, modifiers: [.command])])
    }

    func testWithoutKeypadModifiersTheEventsAreUnchanged() {
        var hold = ArrowKeyHold()
        XCTAssertEqual(hold.move(to: .up, now: 0), [.down(.up)])
        XCTAssertEqual(hold.move(to: .up, now: 0, modifiers: [.shift]), [], "same key: nothing new")
        XCTAssertEqual(hold.release(), .up(.up, modifiers: []))
    }

    // MARK: - Keypad modifiers: geometry

    func testTheModifierStripMatchesTheT() {
        XCTAssertEqual(ArrowKeypadGeometry.modifierKeySize(key: 42), CGSize(width: 42, height: 28))
        XCTAssertEqual(ArrowKeypadGeometry.modifierStripSize(.leading, key: 42, gap: 4), CGSize(width: 42, height: 88))
        XCTAssertEqual(ArrowKeypadGeometry.modifierStripSize(.trailing, key: 42, gap: 4), CGSize(width: 42, height: 88))
        XCTAssertEqual(ArrowKeypadGeometry.modifierStripSize(.below, key: 42, gap: 4), CGSize(width: 134, height: 28))
        XCTAssertEqual(ArrowKeypadGeometry.blockSize(.leading, key: 42, gap: 4), CGSize(width: 180, height: 88))
        XCTAssertEqual(ArrowKeypadGeometry.blockSize(.below, key: 42, gap: 4), CGSize(width: 134, height: 120))
    }

    func testTheBlockSplitsIntoTheTAndAStripOnTheChosenSide() {
        let key: CGFloat = 42, gap: CGFloat = 4
        let t = ArrowKeypadGeometry.size(key: key, gap: gap)
        for placement in ArrowKeypadModifierPlacement.allCases {
            let size = ArrowKeypadGeometry.blockSize(placement, key: key, gap: gap)
            let block = CGRect(origin: CGPoint(x: 100, y: 200), size: size)
            let parts = ArrowKeypadGeometry.split(block, placement: placement, key: key, gap: gap)
            XCTAssertEqual(parts.keypad.size, t, "\(placement)")
            XCTAssertTrue(block.contains(parts.keypad), "\(placement)")
            XCTAssertTrue(block.contains(parts.modifiers), "\(placement)")
            XCTAssertFalse(parts.keypad.intersects(parts.modifiers), "\(placement)")
            switch placement {
            case .leading:
                XCTAssertEqual(parts.keypad.minX - parts.modifiers.maxX, gap)
                XCTAssertEqual(parts.modifiers.minY, parts.keypad.minY)
                XCTAssertEqual(parts.modifiers.height, parts.keypad.height)
            case .trailing:
                XCTAssertEqual(parts.modifiers.minX - parts.keypad.maxX, gap)
                XCTAssertEqual(parts.modifiers.minY, parts.keypad.minY)
            case .below:
                XCTAssertEqual(parts.modifiers.minY - parts.keypad.maxY, gap)
                XCTAssertEqual(parts.modifiers.minX, parts.keypad.minX)
                XCTAssertEqual(parts.modifiers.width, parts.keypad.width)
            }
        }
    }

    func testModifierKeysStackInOrderAndFillTheirStrip() {
        let key: CGFloat = 42, gap: CGFloat = 4
        for placement in ArrowKeypadModifierPlacement.allCases {
            let strip = CGRect(origin: CGPoint(x: 10, y: 20),
                               size: ArrowKeypadGeometry.modifierStripSize(placement, key: key, gap: gap))
            let frames = ArrowKeypadGeometry.modifierKeyFrames(in: strip, placement: placement, key: key, gap: gap)
            let ordered = ArrowKeypadModifiers.keys.map { frames[$0]! }
            XCTAssertEqual(ordered.count, 3)
            for (index, frame) in ordered.enumerated() {
                XCTAssertTrue(strip.contains(frame), "\(placement)")
                XCTAssertEqual(frame.size, CGSize(width: 42, height: 28))
                if index > 0 {
                    let previous = ordered[index - 1]
                    XCTAssertFalse(previous.intersects(frame))
                    if placement.isColumn {
                        XCTAssertLessThan(previous.maxY, frame.minY, "⇧ above ⌥ above ⌘")
                    } else {
                        XCTAssertLessThan(previous.maxX, frame.minX, "⇧ ⌥ ⌘ left to right")
                    }
                }
            }
            // The three keys span the strip exactly.
            if placement.isColumn {
                XCTAssertEqual(ordered[0].minY, strip.minY)
                XCTAssertEqual(ordered[2].maxY, strip.maxY, accuracy: 0.001)
            } else {
                XCTAssertEqual(ordered[0].minX, strip.minX)
                XCTAssertEqual(ordered[2].maxX, strip.maxX, accuracy: 0.001)
            }
        }
    }

    // MARK: - Keypad modifiers: placement among the other controls

    func testInPortraitTheModifiersAreAColumnBesideTheTOnTheSideWithRoom() {
        for side in LandscapeTraySide.allCases {
            let scene = phone(portrait: true, arrowSide: side, keypadOpen: true, withModifiers: true)
            assertClear(scene)
            let toggle = scene.arrows.toggle
            let keypad = try! XCTUnwrap(scene.arrows.keypad)
            let modifiers = try! XCTUnwrap(scene.arrows.modifiers)
            // Toward the middle of the screen, where there is room.
            XCTAssertEqual(scene.arrows.modifierPlacement, side == .trailing ? .leading : .trailing, "\(side)")
            if side == .trailing {
                XCTAssertEqual(keypad.minX - modifiers.maxX, 4, accuracy: 0.5)
            } else {
                XCTAssertEqual(modifiers.minX - keypad.maxX, 4, accuracy: 0.5)
            }
            XCTAssertEqual(modifiers.minY, keypad.minY, accuracy: 0.5, "a compact column, the T's height")
            XCTAssertEqual(modifiers.height, keypad.height, accuracy: 0.5)
            // The T still opens above the button and over it.
            XCTAssertLessThanOrEqual(keypad.maxY, toggle.minY)
            XCTAssertLessThanOrEqual(keypad.minX, toggle.midX)
            XCTAssertGreaterThanOrEqual(keypad.maxX, toggle.midX)
        }
    }

    func testInLandscapeTheModifiersStayClearOfEverything() {
        for side in LandscapeTraySide.allCases {
            for mainSide in LandscapeTraySide.allCases {
                let scene = phone(arrowSide: side, mainSide: mainSide, keypadOpen: true, withModifiers: true)
                assertClear(scene)
                XCTAssertNotNil(scene.arrows.modifiers, "\(side) main=\(mainSide)")
                XCTAssertLessThanOrEqual(scene.arrows.keypad!.maxY, scene.arrows.toggle.minY)
            }
        }
    }

    func testTheModifiersNeverMoveTheButton() {
        for side in LandscapeTraySide.allCases {
            for portrait in [false, true] {
                let plain = phone(portrait: portrait, arrowSide: side)
                let closed = phone(portrait: portrait, arrowSide: side, withModifiers: true)
                let open = phone(portrait: portrait, arrowSide: side, keypadOpen: true, withModifiers: true)
                XCTAssertEqual(closed.arrows, plain.arrows, "closed, the layout is the same as before")
                XCTAssertNil(closed.arrows.modifiers)
                XCTAssertEqual(open.arrows.toggle, plain.arrows.toggle, "\(side) portrait=\(portrait)")
            }
        }
    }

    func testAnOpenPaletteNeverCoversTheModifiers() {
        for side in LandscapeTraySide.allCases {
            assertClear(phone(arrowSide: side, keypadOpen: true, paletteKeys: 7, withModifiers: true))
            assertClear(phone(portrait: true, arrowSide: side, keypadOpen: true, paletteKeys: 6, withModifiers: true))
        }
    }

    func testTheCalculatorAndOtherObstaclesAreAvoided() {
        // A calculator panel right where the column would go.
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        let main = CGRect(x: 20, y: 760, width: 353, height: 44)
        let plain = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: true, side: .trailing, toggleSize: Self.toggle,
            keypadOpen: true, key: 42, gap: 4, mainTrayFrame: main, obstacles: [main], avoidNotch: false)
        let panel = try! XCTUnwrap(plain.modifiers).insetBy(dx: -20, dy: -20)
        let layout = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: true, side: .trailing, toggleSize: Self.toggle,
            keypadOpen: true, key: 42, gap: 4, mainTrayFrame: main, obstacles: [main, panel], avoidNotch: false)
        for frame in [layout.keypad!, layout.modifiers!] {
            XCTAssertFalse(frame.intersects(panel), "\(frame) overlaps the calculator")
            XCTAssertFalse(frame.intersects(main))
            XCTAssertTrue(container.insetBy(dx: 12, dy: 12).contains(frame))
        }
        XCTAssertEqual(layout.toggle, plain.toggle)
    }

    func testWhenNoColumnFitsTheModifiersGoInARowUnderTheT() {
        // A narrow window: 180 pt of keypad and column don't fit across, 134 do.
        let container = CGRect(x: 0, y: 0, width: 190, height: 600)
        let layout = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: true, side: .trailing, toggleSize: Self.toggle,
            keypadOpen: true, key: 42, gap: 4, mainTrayFrame: .zero, obstacles: [], avoidNotch: false)
        XCTAssertEqual(layout.modifierPlacement, .below)
        let keypad = try! XCTUnwrap(layout.keypad), modifiers = try! XCTUnwrap(layout.modifiers)
        XCTAssertEqual(modifiers.minY - keypad.maxY, 4, accuracy: 0.5)
        XCTAssertLessThanOrEqual(modifiers.maxY, layout.toggle.minY, "under the T, above the button")
        XCTAssertTrue(container.insetBy(dx: 12, dy: 12).contains(keypad.union(modifiers)))
    }

    func testReservedRegionsAreAvoidedWithModifiers() {
        let container = CGRect(x: 0, y: 0, width: 852, height: 393)
        let plain = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: false, side: .trailing, toggleSize: Self.toggle,
            keypadOpen: true, key: 42, gap: 4, mainTrayFrame: .zero, obstacles: [], avoidNotch: true)
        // A system-reserved occlusion right where the column would go.
        let occlusion = ControlReservedRegion(kind: .occlusion, frame: try! XCTUnwrap(plain.modifiers).insetBy(dx: -4, dy: -4))
        let layout = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: false, side: .trailing, toggleSize: Self.toggle,
            keypadOpen: true, key: 42, gap: 4, mainTrayFrame: .zero, obstacles: [], avoidNotch: true,
            reservedRegions: [occlusion])
        XCTAssertFalse(layout.keypad!.intersects(occlusion.frame))
        XCTAssertFalse(layout.modifiers!.intersects(occlusion.frame))
    }

    // MARK: - Keypad modifiers: the keyboard bar

    func testWithTheKeyboardUpTheModifierColumnOpensWithTheKeypadAboveTheBar() {
        let safe = CGRect(x: 0, y: 59, width: 393, height: 759)
        let bar = CGRect(x: 23, y: 400, width: 347, height: 44)
        let item = CGRect(x: 290, y: 406, width: 32, height: 32)
        let layout = ControlTrayGeometry.keyboardBarArrowKeysLayout(safe: safe, bar: bar, item: item,
                                                                    key: 42, gap: 4, palette: nil)
        let keypad = try! XCTUnwrap(layout.keypad), modifiers = try! XCTUnwrap(layout.modifiers)
        XCTAssertEqual(layout.toggle, item)
        XCTAssertEqual(layout.modifierPlacement, .leading, "toward the middle, where there is room")
        XCTAssertEqual(keypad.minX - modifiers.maxX, 4, accuracy: 0.5)
        XCTAssertEqual(keypad.maxY, bar.minY - 10, accuracy: 0.5)
        XCTAssertEqual(modifiers.maxY, keypad.maxY, accuracy: 0.5)
        for frame in [keypad, modifiers] {
            XCTAssertTrue(safe.insetBy(dx: 12, dy: 12).contains(frame))
            XCTAssertFalse(frame.intersects(bar))
        }
    }

    func testInLandscapeWithTheKeyboardUpTheModifiersAreARowBesideTheBar() {
        // iPhone landscape: no room above the bar, and 180 pt don't fit beside it.
        let safe = CGRect(x: 59, y: 0, width: 734, height: 372)
        let bar = CGRect(x: 225, y: 89, width: 402, height: 44)
        let item = CGRect(x: 540, y: 95, width: 38, height: 38)
        let layout = ControlTrayGeometry.keyboardBarArrowKeysLayout(safe: safe, bar: bar, item: item,
                                                                    key: 42, gap: 4, palette: nil)
        let keypad = try! XCTUnwrap(layout.keypad), modifiers = try! XCTUnwrap(layout.modifiers)
        XCTAssertEqual(layout.modifierPlacement, .below)
        XCTAssertEqual(keypad.minX, bar.maxX + 10, accuracy: 0.5)
        XCTAssertEqual(modifiers.maxY, bar.maxY, accuracy: 0.5, "bottoms aligned, never over the keyboard")
        XCTAssertEqual(modifiers.minY - keypad.maxY, 4, accuracy: 0.5)
        for frame in [keypad, modifiers] {
            XCTAssertTrue(safe.insetBy(dx: 12, dy: 12).contains(frame))
            XCTAssertFalse(frame.intersects(bar))
        }
    }

    func testAnOpenPaletteAboveTheBarPushesTheModifiersHigherToo() {
        let safe = CGRect(x: 0, y: 59, width: 393, height: 759)
        let bar = CGRect(x: 23, y: 400, width: 347, height: 44)
        let item = CGRect(x: 290, y: 406, width: 32, height: 32)
        let palette = CGRect(x: 20, y: 300, width: 353, height: 90)
        let layout = ControlTrayGeometry.keyboardBarArrowKeysLayout(safe: safe, bar: bar, item: item,
                                                                    key: 42, gap: 4, palette: palette)
        for frame in [layout.keypad!, layout.modifiers!] {
            XCTAssertFalse(frame.intersects(palette))
            XCTAssertLessThanOrEqual(frame.maxY, palette.minY - 10 + 0.5)
        }
    }

    func testTheKeyboardBarModifiersNeverGoBelowTheBar() {
        // No room anywhere: they may overlap the picture, never the keyboard.
        let safe = CGRect(x: 0, y: 0, width: 400, height: 140)
        let bar = CGRect(x: 0, y: 40, width: 400, height: 44)
        let item = CGRect(x: 300, y: 46, width: 32, height: 32)
        let layout = ControlTrayGeometry.keyboardBarArrowKeysLayout(safe: safe, bar: bar, item: item,
                                                                    key: 42, gap: 4, palette: nil)
        XCTAssertLessThanOrEqual(layout.keypad!.maxY, bar.maxY)
        XCTAssertLessThanOrEqual(layout.modifiers!.maxY, bar.maxY)
    }

    func testTheModifiersAreReportedAsOccupied() {
        let layout = ArrowKeysLayout(toggle: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     keypad: CGRect(x: 0, y: 20, width: 10, height: 10),
                                     modifiers: CGRect(x: 20, y: 20, width: 10, height: 10), modifierPlacement: .trailing)
        XCTAssertEqual(layout.occupied.count, 3)
        XCTAssertEqual(ArrowKeysLayout(toggle: .zero, keypad: nil).occupied, [.zero])
    }
}
