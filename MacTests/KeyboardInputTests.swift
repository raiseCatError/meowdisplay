import CoreGraphics
import XCTest

/// Pure-logic coverage for M4 keyboard input. `InputInjector`'s actual
/// `CGEvent` posting is intentionally NOT exercised here — that would post
/// real keyboard events on whatever Mac runs the test suite. Everything
/// tested below is the deterministic, side-effect-free logic those methods
/// call into: HID usage parsing/mapping, modifier decoding, text planning,
/// held-key tracking, and the version gate.
final class KeyboardInputTests: XCTestCase {

    // MARK: - HID usage mapping

    func testKnownHIDUsagesMapToExpectedKeys() {
        XCTAssertEqual(HIDKeyUsage.parse(40), .returnOrEnter)
        XCTAssertEqual(HIDKeyUsage.parse(42), .deleteOrBackspace)
        XCTAssertEqual(HIDKeyUsage.parse(43), .tab)
        XCTAssertEqual(HIDKeyUsage.parse(41), .escape)
        XCTAssertEqual(HIDKeyUsage.parse(44), .spacebar)
        XCTAssertEqual(HIDKeyUsage.parse(80), .leftArrow)
        XCTAssertEqual(HIDKeyUsage.parse(79), .rightArrow)
        XCTAssertEqual(HIDKeyUsage.parse(82), .upArrow)
        XCTAssertEqual(HIDKeyUsage.parse(81), .downArrow)
    }

    func testHIDUsagesMapToDistinctMacOSKeyCodes() {
        let keyCodes = Set(HIDKeyUsage.allCases.map(\.keyCode))
        XCTAssertEqual(keyCodes.count, HIDKeyUsage.allCases.count, "every usage must inject as a distinct key")
    }

    func testUnknownHIDUsageIsRejected() {
        XCTAssertNil(HIDKeyUsage.parse(9999))   // well-formed but not a usage we support
        XCTAssertNil(HIDKeyUsage.parse(0))
    }

    func testNegativeMalformedOrOversizedUsageIsRejected() {
        XCTAssertNil(HIDKeyUsage.parse(-1))
        XCTAssertNil(HIDKeyUsage.parse(70000))               // beyond the 16-bit HID usage range
        XCTAssertNil(HIDKeyUsage.parse(40.5))                // non-integral
        XCTAssertNil(HIDKeyUsage.parse(Double.nan))
        XCTAssertNil(HIDKeyUsage.parse(Double.infinity))
        XCTAssertNil(HIDKeyUsage.parse("40"))                // wrong JSON type
        XCTAssertNil(HIDKeyUsage.parse(nil))
    }

    // MARK: - Committed text must never carry a modifier (regression)

    /// Guards the fix for a real-device incident where plain typed text
    /// ("t") acted as a Command shortcut after a modified hardware key
    /// combo — `postUnicodeText` now sets this constant explicitly instead
    /// of leaving a CGEvent's flags at their (ambient-influenced) default.
    /// This can't exercise the CGEvent itself without posting a real event,
    /// but it keeps the invariant named, visible, and covered.
    func testCommittedTextFlagsAreAlwaysEmpty() {
        XCTAssertEqual(KeyboardTextFlags.committed, [])
        XCTAssertFalse(KeyboardTextFlags.committed.contains(.maskCommand))
        XCTAssertFalse(KeyboardTextFlags.committed.contains(.maskShift))
        XCTAssertFalse(KeyboardTextFlags.committed.contains(.maskControl))
        XCTAssertFalse(KeyboardTextFlags.committed.contains(.maskAlternate))
    }

    // MARK: - Modifier decoding

    func testKnownModifiersDecodeToExpectedFlags() {
        XCTAssertEqual(KeyModifier.flags(named: ["shift"]), .maskShift)
        XCTAssertEqual(KeyModifier.flags(named: ["control"]), .maskControl)
        XCTAssertEqual(KeyModifier.flags(named: ["option"]), .maskAlternate)
        XCTAssertEqual(KeyModifier.flags(named: ["command"]), .maskCommand)
        XCTAssertEqual(KeyModifier.flags(named: ["capsLock"]), .maskAlphaShift)
        XCTAssertEqual(KeyModifier.flags(named: ["shift", "command"]), [.maskShift, .maskCommand])
    }

    func testUnknownModifierNamesAreTolerated() {
        XCTAssertEqual(KeyModifier.flags(named: ["shift", "hyperspace"]), .maskShift)
        XCTAssertEqual(KeyModifier.flags(named: ["hyperspace"]), [])
        XCTAssertEqual(KeyModifier.flags(named: []), [])
    }

    // MARK: - Unicode text planning

    func testPlansASCIIText() {
        XCTAssertEqual(KeyboardTextPlanner.plan("hello"), Array("hello".utf16))
    }

    func testPlansAccentedText() {
        XCTAssertEqual(KeyboardTextPlanner.plan("café"), Array("café".utf16))
    }

    func testPlansEmoji() {
        // A multi-scalar emoji cluster (flag) round-trips as one planned unit.
        let text = "👍🏽🇺🇸"
        XCTAssertEqual(KeyboardTextPlanner.plan(text), Array(text.utf16))
    }

    func testPlansMultiCharacterCommit() {
        let text = "The quick café ☕️"
        XCTAssertEqual(KeyboardTextPlanner.plan(text), Array(text.utf16))
    }

    func testEmptyTextIsNotPlanned() {
        XCTAssertNil(KeyboardTextPlanner.plan(""))
    }

    func testOversizedTextIsRejected() {
        let huge = String(repeating: "a", count: KeyboardTextPlanner.maxUTF16Length + 1)
        XCTAssertNil(KeyboardTextPlanner.plan(huge))
        let atLimit = String(repeating: "a", count: KeyboardTextPlanner.maxUTF16Length)
        XCTAssertNotNil(KeyboardTextPlanner.plan(atLimit))
    }

    // MARK: - Held-key tracking

    func testDownReportsPostableOnFirstPressOnly() {
        var tracker = HeldKeyTracker()
        XCTAssertTrue(tracker.down(.leftArrow))     // first down — post it
        XCTAssertFalse(tracker.down(.leftArrow))    // duplicate down — ignore
        XCTAssertEqual(tracker.held, [.leftArrow])
    }

    func testUpReportsPostableOnlyWhenHeld() {
        var tracker = HeldKeyTracker()
        XCTAssertFalse(tracker.up(.upArrow))        // spurious up — never went down
        tracker.down(.upArrow)
        XCTAssertTrue(tracker.up(.upArrow))         // matching up — post it
        XCTAssertFalse(tracker.up(.upArrow))        // second up — spurious, ignore
    }

    func testReleaseAllReturnsAndClearsHeldKeys() {
        var tracker = HeldKeyTracker()
        tracker.down(.leftArrow)
        tracker.down(.rightArrow)
        let released = tracker.releaseAll()
        XCTAssertEqual(released, [.leftArrow, .rightArrow])
        XCTAssertTrue(tracker.held.isEmpty)
        // A key that was released can be pressed again afterward.
        XCTAssertTrue(tracker.down(.leftArrow))
    }

    func testCancellationClearsIndependentlyTrackedKeys() {
        var tracker = HeldKeyTracker()
        tracker.down(.tab)
        tracker.down(.escape)
        _ = tracker.releaseAll()
        XCTAssertTrue(tracker.held.isEmpty)
        XCTAssertFalse(tracker.up(.tab))    // an up arriving after cancellation is spurious, not re-posted
    }

    /// Cancellation (from an unexpected capture stop, a reconnect, transport
    /// migration, or Allow Input turning off) can arrive more than once in a
    /// row — e.g. a dropped connection followed immediately by a failed
    /// redial. Repeated release must never resurrect a key or double-post.
    func testReleaseAllIsIdempotentAcrossRepeatedCancellation() {
        var tracker = HeldKeyTracker()
        tracker.down(.leftArrow)
        XCTAssertEqual(tracker.releaseAll(), [.leftArrow])
        XCTAssertEqual(tracker.releaseAll(), [])   // nothing left the second time
        XCTAssertEqual(tracker.releaseAll(), [])   // and the third
        XCTAssertTrue(tracker.held.isEmpty)
    }

    // MARK: - Keyboard lifecycle gate (M4 fix: stricter than touch/Pencil)

    // `CaptureLifecycleState.allowsInput` (used by touch/scroll/Pencil/
    // proximity) is deliberately NOT touched by any of these — they only
    // exercise the new `allowsKeyboardInput`, which MacSender's
    // `receiverKeyboardInputIsAllowed()` combines with `InputPolicy`.

    func testKeyboardIsDeniedBeforeCaptureEverStarts() {
        let state = CaptureLifecycleState()   // starts `.recovering`
        XCTAssertFalse(state.allowsKeyboardInput)
        XCTAssertTrue(state.allowsInput, "existing touch/Pencil tolerance during recovering must be unchanged")
    }

    func testKeyboardIsAllowedOnlyOnceCaptureIsFullyRunning() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsKeyboardInput)
    }

    func testKeyboardIsDeniedWhileRecoveringAfterAnUnexpectedStop() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.unexpectedStop())   // running -> recovering
        XCTAssertFalse(state.allowsKeyboardInput)
        XCTAssertTrue(state.allowsInput, "touch/Pencil still tolerate recovering")
    }

    func testKeyboardIsDeniedWhilePaused() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.requestPause())
        XCTAssertTrue(state.pauseCompleted())
        XCTAssertFalse(state.allowsKeyboardInput)
        XCTAssertFalse(state.allowsInput)
    }

    func testKeyboardIsDeniedWhileStopped() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.captureStarted())
        state.stop()
        XCTAssertFalse(state.allowsKeyboardInput)
        XCTAssertFalse(state.allowsInput)
    }

    /// Mirrors `MacSender.receiverKeyboardInputIsAllowed()`'s combined
    /// expression: capture fully running is necessary but not sufficient —
    /// Allow Input off must still deny keyboard input.
    func testAllowInputOffDeniesKeyboardEvenWhileFullyRunning() {
        var state = CaptureLifecycleState()
        XCTAssertTrue(state.captureStarted())
        XCTAssertTrue(state.allowsKeyboardInput)

        let suite = "KeyboardInputTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: InputPolicy.defaultsKey)

        let keyboardAllowed = InputPolicy.allowsInput(defaults: defaults) && state.allowsKeyboardInput
        XCTAssertFalse(keyboardAllowed)
    }

    // MARK: - Version gating (pv3 suppression / pv4 enablement)

    func testKeyboardWireVersionGatesOnPeerProtocol() {
        // Mirrors StreamReceiver.macSupportsKeyboardWire's exact expression
        // (`macProtocolVersion >= WireProtocol.keyboardWireVersion`).
        XCTAssertEqual(WireProtocol.keyboardWireVersion, 4)
        XCTAssertFalse(3 >= WireProtocol.keyboardWireVersion)   // pv3 peer: no keyboard UI/messages
        XCTAssertTrue(4 >= WireProtocol.keyboardWireVersion)    // pv4 peer: keyboard enabled
    }

    // MARK: - Shared input gate (Allow Input / capture lifecycle)

    // Keyboard messages are gated by exactly the same `receiverInputIsAllowed()`
    // as touch/scroll/pencil/proximity (see MacSender.handleControl's
    // "keyboard" case) — no keyboard-specific gating logic exists to test.
    // `InputPolicy` itself and `CaptureLifecycleState.allowsInput` (paused/
    // recovering/stopped) are already covered by InputRoutingTests and
    // CaptureLifecycleTests; this just documents the shared contract.
    func testAllowInputOffAlsoGatesKeyboardsSharedPolicyCheck() {
        let suite = "KeyboardInputTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        XCTAssertFalse(InputPolicy.allowsInput(defaults: defaults))
    }
}
