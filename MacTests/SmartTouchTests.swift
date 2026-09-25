import CoreGraphics
import XCTest

/// Smart Touch (Experimental): the pure engine policy in
/// `Shared/PointerGestureEngine.swift` plus the Mac-side Accessibility
/// role classification in `Mac/SmartTouchTargetClassifier.swift`.
final class SmartTouchTests: XCTestCase {
    private func sample(_ id: Int, _ phase: PointerTouchSample.Phase,
                        view: CGPoint, norm: CGPoint? = CGPoint(x: 0.5, y: 0.5),
                        t: TimeInterval) -> PointerTouchSample {
        PointerTouchSample(id: AnyHashable(id), phase: phase, viewPoint: view, normalized: norm, time: t)
    }

    private func smartEngine() -> PointerGestureEngine {
        let engine = PointerGestureEngine()
        engine.smartTouchEnabled = true
        return engine
    }

    /// Touch down at (100,100) and return the probe id it asked for.
    private func beginProbedTouch(_ engine: PointerGestureEngine, id: Int = 1, t: TimeInterval = 0) -> Int? {
        let out = engine.handle(sample(id, .began, view: CGPoint(x: 100, y: 100),
                                       norm: CGPoint(x: 0.2, y: 0.2), t: t))
        guard out.count == 1, case .probeScrollTarget(let probeID, let x, let y) = out[0] else { return nil }
        XCTAssertEqual(x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(y, 0.2, accuracy: 1e-9)
        return probeID
    }

    // MARK: - Off / Trackpad: exact existing path

    func testDisabledSmartTouchNeverProbesAndKeepsDirectTouch() {
        let engine = PointerGestureEngine()
        XCTAssertEqual(engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0)), [])
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100),
                                         norm: CGPoint(x: 0.4, y: 0.2), t: 0.01))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testTrackpadIgnoresSmartTouch() {
        let engine = smartEngine()
        engine.setInputMode(.trackpad)
        XCTAssertEqual(engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), t: 0)), [])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), t: 0.01)), [])
        XCTAssertEqual(engine.mode, .relativePointerSession)
        // A stray reply can't change anything either.
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: 1, target: .scroll), [])
        XCTAssertEqual(engine.mode, .relativePointerSession)
    }

    // MARK: - Classification outcomes

    func testScrollableTargetTurnsOneFingerSwipeIntoScroll() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .scroll), [])   // no movement yet
        let first = engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(first, [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.mode, .smartScroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 150), t: 0.04)),
                       [.scroll(dx: 0, dy: 20)])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 150), t: 0.05)),
                       [.scrollEnded(momentum: true)])
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.heldMouseButton, nil)
    }

    func testCancelledSmartScrollEndsWithoutMomentum() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(engine.handle(sample(1, .cancelled, view: CGPoint(x: 100, y: 130), t: 0.04)),
                       [.scrollEnded(momentum: false)])
    }

    func testNonScrollableTargetFallsBackToDirectTouch() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: nil)
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100),
                                         norm: CGPoint(x: 0.4, y: 0.2), t: 0.03))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testLateReplyCommitsTheWithheldMovement() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        // Crossed drag slop before the Mac answered — withheld, not committed.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.02)), [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .scroll),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.mode, .smartScroll)
    }

    func testLateNegativeReplyCommitsDirectTouch() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), norm: CGPoint(x: 0.4, y: 0.2), t: 0.02))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: nil),
                       [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    /// No reply at all (lookup failed, Mac never answered) — the existing
    /// arbitration window commits ordinary Direct Touch.
    func testMissingReplyFallsBackAfterArbitrationWindow() throws {
        let engine = smartEngine()
        _ = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), norm: CGPoint(x: 0.2, y: 0.3), t: 0.02))
        let out = engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow)
        XCTAssertEqual(out, [.moveAbsolute(x: 0.2, y: 0.3)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testStaleReplyIsIgnored() throws {
        let engine = smartEngine()
        let firstProbe = try XCTUnwrap(beginProbedTouch(engine, id: 1))
        engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100), t: 0.05))   // a tap
        engine.poll(now: 1)                                                          // flushed
        let secondProbe = try XCTUnwrap(beginProbedTouch(engine, id: 2, t: 2))
        XCTAssertNotEqual(firstProbe, secondProbe)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: firstProbe, target: .scroll), [])
        let moved = engine.handle(sample(2, .moved, view: CGPoint(x: 100, y: 130), t: 2.01))
        XCTAssertEqual(moved, [], "still waiting on its own probe")
    }

    // MARK: - Intent lock

    func testScrollIntentStaysLockedUntilLift() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        // A second finger, a pause, and more movement never turn it into
        // a pointer move or drag.
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 200, y: 100), t: 0.1)), [])
        XCTAssertEqual(engine.poll(now: 2), [])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 140), t: 2.1)),
                       [.scroll(dx: 0, dy: 10)])
        XCTAssertEqual(engine.handle(sample(2, .moved, view: CGPoint(x: 250, y: 100), t: 2.2)), [])
        XCTAssertEqual(engine.mode, .smartScroll)
    }

    func testDirectIntentStaysLockedEvenIfAReplyArrivesLater() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow)   // held still: Direct Touch
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .scroll), [])
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 150),
                                         norm: CGPoint(x: 0.2, y: 0.4), t: 0.3))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.2, y: 0.4)])
    }

    // MARK: - Scroll axes

    func testHorizontalSwipeScrollsHorizontallyOnly() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 70, y: 103), t: 0.03)),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: -30, dy: 0)])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 50, y: 108), t: 0.04)),
                       [.scroll(dx: -20, dy: 0)])
        // Pure vertical drift on a horizontal lock sends nothing.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 50, y: 112), t: 0.05)), [])
    }

    func testVerticalSwipeIgnoresSidewaysDrift() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 104, y: 130), t: 0.03)),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 110, y: 140), t: 0.04)),
                       [.scroll(dx: 0, dy: 10)])
    }

    func testDiagonalSwipeKeepsCarryingBothAxes() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 85, y: 80), t: 0.03)),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: -15, dy: -20)])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 60, y: 50), t: 0.04)),
                       [.scroll(dx: -25, dy: -30)])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 60, y: 50), t: 0.05)),
                       [.scrollEnded(momentum: true)])
    }

    func testDiagonalSwipePansFreely() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 120, y: 120), t: 0.03)),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 20, dy: 20)])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 130, y: 120), t: 0.04)),
                       [.scroll(dx: 10, dy: 0)])
    }

    // MARK: - Long-press override

    func testLongPressOnScrollableTargetSwitchesToDirectTouchWithFeedback() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        // The arbitration window no longer commits a confidently
        // classified touch — the long press does.
        XCTAssertEqual(engine.pollDelay(now: 0.05) ?? 0,
                       PointerGestureConfig.smartTouchLongPressDelay - 0.05, accuracy: 1e-9)
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow), [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.smartTouchLongPressDelay),
                       [.moveAbsolute(x: 0.2, y: 0.2), .smartTouchFeedback(.directTouchOverride)])
        XCTAssertEqual(engine.mode, .absolutePointer)
        // From here it is plain Direct Touch: movement moves the pointer.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 150),
                                            norm: CGPoint(x: 0.2, y: 0.4), t: 0.5)),
                       [.moveAbsolute(x: 0.2, y: 0.4)])
    }

    func testPauseShorterThanLongPressStillScrolls() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        engine.poll(now: 0.3)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.32)),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.mode, .smartScroll)
    }

    func testReleaseAfterArbitrationWindowIsStillNotAClick() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.3)),
                       [.moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.poll(now: 1), [])
    }

    func testNoFeedbackWithoutAConfidentTarget() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: nil)
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow),
                       [.moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    // MARK: - Title bar hold, then drag

    private let holdDeadline = PointerGestureConfig.smartTouchTitleBarHoldDelay

    /// Touch down on a title bar the Mac recognized; returns what the
    /// probe reply emitted.
    private func beginTitleBarHold(_ engine: PointerGestureEngine, id: Int = 1,
                                   t: TimeInterval = 0) throws -> [PointerCommand] {
        let probe = try XCTUnwrap(beginProbedTouch(engine, id: id, t: t))
        return engine.resolveSmartTouchProbe(id: probe, target: .windowDrag)
    }

    func testRecognizedTitleBarStartsTheHoldInsteadOfDragging() throws {
        let engine = smartEngine()
        XCTAssertEqual(try beginTitleBarHold(engine),
                       [.smartTouchFeedback(.titleBarHoldBegan(deadline: holdDeadline))])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        XCTAssertNil(engine.heldMouseButton)
        // Neither the arbitration window nor the generic long press
        // commits it — the title bar hold does.
        XCTAssertEqual(engine.pollDelay(now: 0.05) ?? 0, holdDeadline - 0.05, accuracy: 1e-9)
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow), [])
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.smartTouchLongPressDelay), [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        XCTAssertNil(engine.heldMouseButton)
    }

    func testTitleBarHoldArmsTheDragThenTheWindowFollowsUntilLift() throws {
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        // Small wobble inside the slop keeps the hold alive.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 106, y: 104),
                                            norm: CGPoint(x: 0.21, y: 0.21), t: 0.2)), [])
        let armed = engine.poll(now: holdDeadline)
        XCTAssertEqual(armed, [.moveAbsolute(x: 0.2, y: 0.2), .mouseDown(button: .left, clickCount: 1),
                               .smartTouchFeedback(.windowDragArmed)])
        XCTAssertEqual(engine.mode, .leftDragHeld)
        XCTAssertEqual(engine.heldMouseButton, .left)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 160, y: 110),
                                            norm: CGPoint(x: 0.4, y: 0.25), t: 0.6)),
                       [.moveAbsolute(x: 0.4, y: 0.25)])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 200, y: 150),
                                            norm: CGPoint(x: 0.5, y: 0.35), t: 0.7)),
                       [.moveAbsolute(x: 0.5, y: 0.35)])
        XCTAssertEqual(engine.poll(now: 0.8), [], "nothing re-arms or presses again")
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 200, y: 150), t: 0.9)),
                       [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .idle)
    }

    func testMouseDownHappensExactlyOncePerTitleBarDrag() throws {
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        var all = engine.poll(now: holdDeadline)
        for step in 1...5 {
            all += engine.handle(sample(1, .moved, view: CGPoint(x: 100 + CGFloat(step) * 20, y: 100),
                                        norm: CGPoint(x: 0.2 + Double(step) * 0.05, y: 0.2),
                                        t: holdDeadline + Double(step) * 0.01))
            all += engine.poll(now: holdDeadline + Double(step) * 0.01)
        }
        all += engine.handle(sample(1, .ended, view: CGPoint(x: 200, y: 100), t: 1))
        XCTAssertEqual(all.filter { $0 == .mouseDown(button: .left, clickCount: 1) }.count, 1)
        XCTAssertEqual(all.filter { if case .mouseUp = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(all.filter { $0 == .smartTouchFeedback(.windowDragArmed) }.count, 1)
    }

    func testMovingBeforeTheHoldArmsFallsBackToDirectTouch() throws {
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 130, y: 100),
                                         norm: CGPoint(x: 0.3, y: 0.2), t: 0.2))
        XCTAssertEqual(moved, [.smartTouchFeedback(.titleBarHoldCancelled), .moveAbsolute(x: 0.3, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertNil(engine.heldMouseButton)
        // The deadline passing later changes nothing.
        XCTAssertEqual(engine.poll(now: 1), [])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 130, y: 100), t: 1.1)), [])
    }

    func testTitleBarReplyAfterMovementNeverDrags() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(1, .moved, view: CGPoint(x: 130, y: 100), norm: CGPoint(x: 0.3, y: 0.2), t: 0.02))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .windowDrag),
                       [.moveAbsolute(x: 0.3, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertNil(engine.heldMouseButton)
    }

    func testTapOnTitleBarIsStillAClick() throws {
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 101, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.08)),
                       [.smartTouchFeedback(.titleBarHoldCancelled), .moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.poll(now: 1), [.mouseDown(button: .left, clickCount: 1),
                                             .mouseUp(button: .left, clickCount: 1)])
        XCTAssertNil(engine.heldMouseButton)
    }

    func testReleasingMidHoldStopsTheBuildUpWithoutAClick() throws {
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.3)),
                       [.smartTouchFeedback(.titleBarHoldCancelled), .moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.poll(now: 1), [])
        XCTAssertNil(engine.heldMouseButton)
    }

    func testSecondFingerOrResetCancelsTheHold() throws {
        var engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 140, y: 100), t: 0.1)),
                       [.smartTouchFeedback(.titleBarHoldCancelled)])
        XCTAssertEqual(engine.mode, .twoFingerPending)

        engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        XCTAssertEqual(engine.reset(), [.smartTouchFeedback(.titleBarHoldCancelled)])
        XCTAssertEqual(engine.poll(now: 1), [])
        XCTAssertNil(engine.heldMouseButton)
    }

    func testGenericLongPressStillSwitchesToDirectTouch() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .scroll), [],
                       "no title bar build-up for an ordinary target")
        XCTAssertEqual(engine.poll(now: PointerGestureConfig.smartTouchLongPressDelay),
                       [.moveAbsolute(x: 0.2, y: 0.2), .smartTouchFeedback(.directTouchOverride)])
        XCTAssertNil(engine.heldMouseButton)
    }

    /// Haptics settings live only on the receiver: the engine emits the same
    /// commands either way, and the policy only silences feedback.
    func testHapticsSettingsChangeFeedbackOnly() throws {
        XCTAssertTrue(SmartTouchHapticPolicy.isEnabled(haptics: true, smartTouchHaptics: true))
        XCTAssertFalse(SmartTouchHapticPolicy.isEnabled(haptics: true, smartTouchHaptics: false))
        XCTAssertFalse(SmartTouchHapticPolicy.isEnabled(haptics: false, smartTouchHaptics: true))
        XCTAssertFalse(SmartTouchHapticPolicy.isEnabled(haptics: false, smartTouchHaptics: false))
        let engine = smartEngine()
        _ = try beginTitleBarHold(engine)
        let armed = engine.poll(now: holdDeadline).filter {
            if case .smartTouchFeedback = $0 { return false }; return true
        }
        XCTAssertEqual(armed, [.moveAbsolute(x: 0.2, y: 0.2), .mouseDown(button: .left, clickCount: 1)])
    }

    // MARK: - Taps and tap-hold-drag

    func testTapOnScrollableTargetIsStillAClick() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 102, y: 101),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.08)),
                       [.moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.poll(now: 1), [.mouseDown(button: .left, clickCount: 1),
                                             .mouseUp(button: .left, clickCount: 1)])
    }

    func testDoubleAndTripleTapsKeepClickCounts() throws {
        let engine = smartEngine()
        for i in 0..<3 {
            let t = Double(i) * 0.15
            let out = engine.handle(sample(i + 1, .began, view: CGPoint(x: 100, y: 100), t: t))
            if let probe = out.compactMap({ c -> Int? in
                if case .probeScrollTarget(let id, _, _) = c { return id }; return nil }).first {
                engine.resolveSmartTouchProbe(id: probe, target: .scroll)
            }
            engine.handle(sample(i + 1, .ended, view: CGPoint(x: 100, y: 100), t: t + 0.05))
        }
        XCTAssertEqual(engine.poll(now: 5), [.mouseDown(button: .left, clickCount: 3),
                                             .mouseUp(button: .left, clickCount: 3)])
    }

    func testTapThenHoldDragOverScrollableAreaIsStillALeftDrag() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100), t: 0.05))
        // The continuing touch does not probe — tap-then-hold is a drag.
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.15)), [])
        let drag = engine.handle(sample(2, .moved, view: CGPoint(x: 100, y: 130),
                                        norm: CGPoint(x: 0.2, y: 0.3), t: 0.2))
        XCTAssertEqual(drag, [.moveAbsolute(x: 0.2, y: 0.3), .mouseDown(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .leftDragHeld)
    }

    // MARK: - Multi-finger paths untouched

    func testTwoFingerStartStillFormsAFreshChord() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 130, y: 100), t: 0.02)), [])
        XCTAssertEqual(engine.mode, .twoFingerPending)
        // Late reply for the first finger changes nothing — scroll, pinch
        // and rotation stay with the two-finger recognizer.
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, target: .scroll), [])
        XCTAssertEqual(engine.mode, .twoFingerPending)
    }

    func testThreeFingerStartStillDefersToSystemGestures() throws {
        let engine = smartEngine()
        _ = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(2, .began, view: CGPoint(x: 130, y: 100), t: 0.01))
        engine.handle(sample(3, .began, view: CGPoint(x: 160, y: 100), t: 0.02))
        XCTAssertEqual(engine.mode, .deferredSystemGesture)
    }

    func testResetClearsSmartScroll() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, target: .scroll)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(engine.reset(), [])
        XCTAssertEqual(engine.mode, .idle)
    }

    // MARK: - Accessibility role classification

    func testScrollAreaAncestorIsScrollable() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXStaticText", "AXCell", "AXRow", "AXTable", "AXScrollArea", "AXWindow"]),
                       .scrollable(container: "AXScrollArea"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXGroup", "AXWebArea"]),
                       .scrollable(container: "AXWebArea"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXTextArea", "AXScrollArea"]),
                       .scrollable(container: "AXScrollArea"))
    }

    func testControlsAndPlainWindowsAreNotScrollable() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXSlider", "AXScrollArea"]),
                       .notScrollable(reason: "control:AXSlider"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXScrollBar", "AXScrollArea"]),
                       .notScrollable(reason: "control:AXScrollBar"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXButton", "AXGroup", "AXWindow", "AXScrollArea"]),
                       .notScrollable(reason: "noScrollContainer"))
    }

    func testStandardTitleBarHitsAreCandidates() {
        typealias C = SmartTouchTargetClassifier
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXWindow"]), .titleBand)
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXStaticText", "AXWindow"]), .titleBand)
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXToolbar", "AXWindow"]), .toolbar)
    }

    func testNestedToolbarGroupsAreCandidates() {
        typealias C = SmartTouchTargetClassifier
        // Unified toolbars nest item groups inside the toolbar.
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXToolbar", "AXWindow"]), .toolbar)
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXGroup", "AXToolbar", "AXWindow"]), .toolbar)
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXStaticText", "AXGroup", "AXToolbar", "AXWindow"]), .toolbar)
        // Plain groups or a bare scroll area under a transparent title bar
        // still need the title bar band.
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXWindow"]), .titleBand)
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXScrollArea", "AXSplitGroup", "AXWindow"]), .titleBand)
    }

    func testWindowAndToolbarControlsAreNeverCandidates() {
        typealias C = SmartTouchTargetClassifier
        // Close, minimize and full screen are AXButtons on the window.
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXButton", "AXWindow"]), .rejected(reason: "role:AXButton"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXButton", "AXGroup", "AXToolbar", "AXWindow"]),
                       .rejected(reason: "role:AXButton"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXImage", "AXButton", "AXToolbar", "AXWindow"]),
                       .rejected(reason: "role:AXImage"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXStaticText", "AXButton", "AXToolbar", "AXWindow"]),
                       .rejected(reason: "role:AXButton"))
        for control in ["AXTextField", "AXComboBox", "AXRadioGroup", "AXRadioButton", "AXPopUpButton",
                        "AXMenuButton", "AXCheckBox", "AXSlider", "AXScrollBar", "AXSplitter", "AXLink",
                        "AXDisclosureTriangle", "AXImage", "AXIncrementor", "AXColorWell"] {
            XCTAssertEqual(C.titleBarCandidate(roles: [control, "AXGroup", "AXToolbar", "AXWindow"]),
                           .rejected(reason: "role:\(control)"), control)
            XCTAssertEqual(C.titleBarCandidate(roles: [control, "AXWindow"]),
                           .rejected(reason: "role:\(control)"), control)
        }
        // A search field's text inside it is still the field.
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXStaticText", "AXTextField", "AXToolbar", "AXWindow"]),
                       .rejected(reason: "role:AXTextField"))
    }

    func testOrdinaryContentIsNeverACandidate() {
        typealias C = SmartTouchTargetClassifier
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXStaticText", "AXCell", "AXRow", "AXTable", "AXScrollArea", "AXWindow"]),
                       .rejected(reason: "role:AXCell"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXTextArea", "AXScrollArea", "AXWindow"]),
                       .rejected(reason: "role:AXTextArea"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXWebArea", "AXScrollArea", "AXWindow"]),
                       .rejected(reason: "role:AXWebArea"))
        // A scroll area is only a leaf; with content under it, it's content.
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXScrollArea", "AXWindow"]),
                       .rejected(reason: "role:AXScrollArea"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXSheet"]), .rejected(reason: "notInWindow:AXSheet"))
        XCTAssertEqual(C.titleBarCandidate(roles: ["AXGroup", "AXGroup"]), .rejected(reason: "notInWindow:AXGroup"))
        XCTAssertEqual(C.titleBarCandidate(roles: []), .rejected(reason: "noElement"))
    }

    func testAncestorWalkOnlyContinuesWhileATitleBarIsPossible() {
        typealias C = SmartTouchTargetClassifier
        XCTAssertTrue(C.canBeTitleBar(role: "AXScrollArea", isLeaf: true))
        XCTAssertFalse(C.canBeTitleBar(role: "AXScrollArea", isLeaf: false))
        XCTAssertTrue(C.canBeTitleBar(role: "AXGroup", isLeaf: false))
        XCTAssertFalse(C.canBeTitleBar(role: "AXButton", isLeaf: true))
        XCTAssertFalse(C.canBeTitleBar(role: "AXWebArea", isLeaf: true))
    }

    func testTitleBarBandFollowsTheCloseButton() {
        // Plain 28pt title bar: close button centered 14pt down.
        XCTAssertTrue(SmartTouchTargetClassifier.isInTitleBar(pointY: 120, windowTop: 100, closeButtonMidY: 114))
        XCTAssertFalse(SmartTouchTargetClassifier.isInTitleBar(pointY: 140, windowTop: 100, closeButtonMidY: 114))
        // Unified 52pt toolbar.
        XCTAssertTrue(SmartTouchTargetClassifier.isInTitleBar(pointY: 145, windowTop: 100, closeButtonMidY: 126))
        // Nonsense geometry never matches.
        XCTAssertFalse(SmartTouchTargetClassifier.isInTitleBar(pointY: 100, windowTop: 100, closeButtonMidY: 90))
        XCTAssertFalse(SmartTouchTargetClassifier.isInTitleBar(pointY: 150, windowTop: 100, closeButtonMidY: 300))
    }

    func testUnknownOrMissingTargetsFallBack() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: []), .notScrollable(reason: "noElement"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: Array(repeating: "AXGroup", count: 40)),
                       .notScrollable(reason: "depthLimit"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXUnknown"]),
                       .notScrollable(reason: "depthLimit"))
    }

    // MARK: - Preference persistence

    func testSmartTouchDefaultsOffAndMigratesFromOlderSchema() throws {
        XCTAssertFalse(ReceiverControlPreferences().smartTouchEnabled)
        XCTAssertTrue(ReceiverControlPreferences().smartTouchLongPressHapticEnabled)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SmartTouchTests.\(UUID().uuidString)"))
        var old = ReceiverControlPreferences()
        old.version = 13
        old.inputMode = .trackpad
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "smartTouchEnabled")
        json.removeValue(forKey: "smartTouchLongPressHapticEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        let loaded = repository.load()
        XCTAssertEqual(loaded.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertFalse(loaded.smartTouchEnabled)
        XCTAssertTrue(loaded.smartTouchLongPressHapticEnabled)
        XCTAssertEqual(loaded.inputMode, .trackpad, "other preferences survive")

        var enabled = loaded
        enabled.smartTouchEnabled = true
        repository.save(enabled)
        XCTAssertTrue(repository.load().smartTouchEnabled)
    }
}
