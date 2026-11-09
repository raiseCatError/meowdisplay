import XCTest
import CoreGraphics

/// Lock episodes (PROTOCOL.md 6.19): the tag on the wire, the receiver's tagging of every input
/// family, and `InputInjector`'s own episode check, the second enforcement point, which holds even
/// when the Mac unlocks between `MacSender`'s check and the post.
final class LockScreenInputEpisodeTests: XCTestCase {

    // MARK: - The tag on the wire

    func testATagNamesAViewOnlyWithAPositiveIntegerNeverABoolean() {
        XCTAssertNil(LockScreenInputTag(message: ["type": "keyboard", "action": "press"]), "untagged")
        XCTAssertEqual(LockScreenInputTag(message: ["type": "keyboard", "lockScreen": true]), LockScreenInputTag(view: nil),
                       "an older build's bare tag names no view")
        XCTAssertEqual(LockScreenInputTag(message: ["type": "keyboard", "lockScreen": false]), LockScreenInputTag(view: nil),
                       "any tag field tags it (fail closed)")
        XCTAssertEqual(LockScreenInputTag(message: ["lockScreen": true, "lockScreenView": 4242]), LockScreenInputTag(view: 4242))
        XCTAssertEqual(LockScreenInputTag(message: ["lockScreenView": 4242]), LockScreenInputTag(view: 4242))
        for bad in [true, false, 0, -5, "4242", 1.5, [4242]] as [Any] {
            XCTAssertEqual(LockScreenInputTag(message: ["lockScreen": true, "lockScreenView": bad]), LockScreenInputTag(view: nil), "\(bad)")
        }
        // Through JSON, as it arrives.
        let data = try? JSONSerialization.data(withJSONObject: ["lockScreen": true, "lockScreenView": true])
        let parsed = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertEqual(LockScreenInputTag(message: parsed), LockScreenInputTag(view: nil), "JSON true is not view 1")
        XCTAssertEqual(InputEpisode(tag: nil), .desktop)
        XCTAssertEqual(InputEpisode(tag: LockScreenInputTag(view: 7)), .lockScreen(view: 7))
        XCTAssertEqual(InputEpisode(tag: LockScreenInputTag(view: nil)), .lockScreen(view: 0), "a view that never exists")
    }

    func testViewNumbersAreNeverReusedAndNeverLookLikeABoolean() {
        var seen = Set<Int>()
        for _ in 0..<1_000 {
            let n = LockScreenViewNumbers.next()
            XCTAssertGreaterThan(n, 1)
            XCTAssertTrue(seen.insert(n).inserted)
        }
    }

    func testMacLockStateCarriesTheViewOnlyWhileActive() {
        let active = MacLockWire.message(.locked, lockScreen: .active, view: 4242)
        XCTAssertEqual(active[LockScreenWire.viewKey] as? Int, 4242)
        XCTAssertEqual(MacLockNotice(message: active)?.lockScreenView, 4242)
        XCTAssertNil(MacLockWire.message(.locked, lockScreen: .available, view: 4242)[LockScreenWire.viewKey])
        XCTAssertNil(MacLockWire.message(.unlocked, lockScreen: .active, view: 4242)[LockScreenWire.viewKey])
        var forged = MacLockWire.message(.locked, lockScreen: .available)
        forged[LockScreenWire.viewKey] = 4242
        XCTAssertNil(MacLockNotice(message: forged)?.lockScreenView, "a view number only with active")
        XCTAssertNil(MacLockNotice(message: MacLockWire.message(.locked, lockScreen: .active))?.lockScreenView,
                     "an older Mac numbers no views")
    }

    /// The receiver tags every input family while it sees the Mac locked (one place, whatever
    /// sends it, a future arrow keypad included), with the view only while it shows one, and
    /// nothing else (requests, mode switches, the lock screen request itself).
    func testTheReceiverTagsEveryInputFamilyAndNothingElse() {
        let inputs: [[String: Any]] = LockScreenInputTag.messageTypes.map { ["type": $0] }
        XCTAssertTrue(LockScreenInputTag.messageTypes.isSuperset(of: [
            "touch", "pointer", "keyboard", "scroll", "pencil", "proximity", "gesture",
            WireMessage.nativeAppGesture, WireMessage.smartTouchProbe, WireMessage.windowAction,
            WireMessage.workspaceFocus, WireMessage.menuPress, WireMessage.appLaunch, WireMessage.windowClose,
        ]))
        let unlocked = LockScreenInputTagState()
        for m in inputs { XCTAssertNil(LockScreenInputTag(message: unlocked.tagged(m)), "unlocked: untagged \(m)") }

        let locked = LockScreenInputTagState(locked: true, view: nil)
        for m in inputs { XCTAssertEqual(LockScreenInputTag(message: locked.tagged(m)), LockScreenInputTag(view: nil), "\(m)") }

        let showing = LockScreenInputTagState(locked: true, view: 4242)
        for m in inputs { XCTAssertEqual(LockScreenInputTag(message: showing.tagged(m)), LockScreenInputTag(view: 4242), "\(m)") }
        for type in [LockScreenWire.request, WireMessage.allowInputRequest, WireMessage.displayModeRequest, "ping", "hello"] {
            XCTAssertNil(LockScreenInputTag(message: showing.tagged(["type": type])), "\(type) is not input")
        }
        XCTAssertNil(LockScreenInputTagState(locked: false, view: 4242).tag, "no view without the lock")
    }

    func testOtherFamiliesNeverGoTaggedOrWhileAViewIsLive() {
        typealias T = LockScreenTaggedInput
        XCTAssertTrue(T.otherInputAdmits(tag: nil, liveView: nil), "ordinary input")
        XCTAssertFalse(T.otherInputAdmits(tag: nil, liveView: 7), "never on the lock screen")
        XCTAssertFalse(T.otherInputAdmits(tag: LockScreenInputTag(view: 7), liveView: 7), "not even tagged for it")
        XCTAssertFalse(T.otherInputAdmits(tag: LockScreenInputTag(view: 7), liveView: nil), "made on the lock screen, after the unlock")
        XCTAssertFalse(T.otherInputAdmits(tag: LockScreenInputTag(view: nil), liveView: nil), "made while locked")
        XCTAssertTrue(LockScreenInputTag.otherTypes.isDisjoint(with: LockScreenInputTag.lockScreenTypes))
    }

    // MARK: - InputInjector: the second enforcement point

    private let events = RecordingEventSink()
    private let gate = MacPrivacyGate(.locked)
    private let lockScreen = LockScreenInputGate()
    private let grant = SessionInputGrantBox()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        LoginSessionConsole.shared.set(onConsole: true)
        grant.set(true)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        super.tearDown()
    }

    private func makeInjector() -> InputInjector {
        let injector = InputInjector(displayID: CGMainDisplayID(), sessionInputGrant: grant, eventSink: events)
        injector.privacyGate = gate
        injector.lockScreenGate = lockScreen
        return injector
    }

    private func keyDowns(_ posted: [RecordingEventSink.Posted]) -> [Int64] {
        posted.filter { $0.type == .keyDown }.compactMap(\.keyCode)
    }

    /// The Mac unlocks after `MacSender` let a lock screen keystroke through but before it is
    /// posted: it is never typed into the desktop. Desktop input meanwhile never reaches the lock
    /// screen, and a view's input never reaches another view.
    func testAnEpisodeChangeBetweenTheSendersCheckAndThePostActsOnNothing() {
        let injector = makeInjector()
        lockScreen.set(view: 11)
        injector.perform(for: .lockScreen(view: 11)) { injector.handleKeyboardPress(.keyA) }
        XCTAssertEqual(keyDowns(events.take()), [Int64(HIDKeyUsage.keyA.keyCode)], "the live view's own key")
        injector.handleKeyboardPress(.keyB)
        injector.handleKeyboardText("x")
        injector.perform(for: .lockScreen(view: 10)) { injector.handleKeyboardPress(.keyB) }
        XCTAssertEqual(events.take(), [], "desktop input, or another view's, on the lock screen")

        gate.set(.unlocked)   // the unlock lands here; MacSender hasn't ended the view yet
        injector.perform(for: .lockScreen(view: 11)) {
            injector.handleKeyboardPress(.returnOrEnter)
            injector.handleKeyboardText("fake-pass-123")
            injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
            injector.handlePointerDown(button: .left, clickCount: 1)
        }
        XCTAssertEqual(events.take(), [], "typed for the lock screen: never into the desktop")
        injector.handleKeyboardPress(.keyC)
        XCTAssertEqual(keyDowns(events.take()), [Int64(HIDKeyUsage.keyC.keyCode)], "the desktop's own")
    }

    /// Held input belongs to the episode that pressed it: at the first event of another one it is
    /// released, and a release from another episode never releases what the current one holds.
    func testHeldInputNeverCrossesAnEpisodeAndStaleReleasesReleaseNothing() {
        let injector = makeInjector()
        lockScreen.set(view: 21)
        injector.perform(for: .lockScreen(view: 21)) {
            injector.handleModifier(name: ControlModifier.shift.rawValue, down: true)
            injector.handleKeyboardDown(usage: .keyA, modifiers: [])
            injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        }
        XCTAssertTrue(events.take().contains { $0.type == .leftMouseDown })

        gate.set(.unlocked)   // no MacSender cleanup yet: the injector's own boundary
        injector.handleKeyboardPress(.keyB)
        let crossed = events.take()
        let shift = Int64(ControlModifier.shift.keyCode)
        XCTAssertEqual(crossed.filter { $0.type == .leftMouseUp }.count, 1, "\(crossed)")
        XCTAssertTrue(crossed.contains { $0.type == .keyUp && $0.keyCode == Int64(HIDKeyUsage.keyA.keyCode) }, "\(crossed)")
        XCTAssertTrue(crossed.contains { $0.keyCode == shift && $0.type != .keyDown }, "\(crossed)")
        let typed = crossed.filter { $0.type == .keyDown }
        XCTAssertEqual(typed.compactMap(\.keyCode), [Int64(HIDKeyUsage.keyB.keyCode)])
        XCTAssertFalse(typed.first?.flags.contains(.maskShift) ?? true, "no Shift from the lock screen")

        // The desktop now holds its own key; the lock screen's late releases touch none of it.
        injector.handleKeyboardDown(usage: .keyD, modifiers: [])
        injector.handleTouch(phase: "began", x: 0.4, y: 0.4)
        _ = events.take()
        injector.perform(for: .lockScreen(view: 21)) {
            injector.handleKeyboardUp(usage: .keyD, modifiers: [])
            injector.handleKeyboardUp(usage: .keyA, modifiers: [])
            injector.handleModifier(name: ControlModifier.shift.rawValue, down: false)
            injector.handleTouch(phase: "ended", x: 0.4, y: 0.4)
            injector.handlePointerUp(button: .left, clickCount: 1)
        }
        XCTAssertEqual(events.take(), [], "stale releases release nothing")
        injector.handleKeyboardUp(usage: .keyD, modifiers: [])
        injector.handleTouch(phase: "ended", x: 0.4, y: 0.4)
        let own = events.take()
        XCTAssertTrue(own.contains { $0.type == .keyUp } && own.contains { $0.type == .leftMouseUp }, "\(own)")

        // And back: desktop input held when the Mac locks and a view goes live is released first.
        injector.handleModifier(name: ControlModifier.command.rawValue, down: true)
        _ = events.take()
        gate.set(.locked)
        lockScreen.set(view: 22)
        injector.perform(for: .lockScreen(view: 22)) { injector.handleKeyboardPress(.keyE) }
        let into = events.take()
        XCTAssertTrue(into.contains { $0.keyCode == Int64(ControlModifier.command.keyCode) }, "Command released: \(into)")
        XCTAssertFalse(into.first { $0.type == .keyDown }?.flags.contains(.maskCommand) ?? true, "never a desktop Command on the lock screen")
    }

    /// Scroll, Pencil and proximity never act on the lock screen, even as a live view's own input.
    func testOtherFamiliesNeverActOnTheLockScreenInTheInjector() {
        let injector = makeInjector()
        lockScreen.set(view: 31)
        injector.perform(for: .lockScreen(view: 31)) {
            injector.handleScroll(dx: 0, dy: 400)
            injector.handlePencil(phase: "down", x: 0.5, y: 0.5, pressure: 0.5, azimuth: 0, altitude: 1, rotation: 0)
            injector.handleProximity(entering: true, x: 0.5, y: 0.5)
        }
        injector.handleScroll(dx: 0, dy: 400)
        XCTAssertEqual(events.take(), [])
    }
}
