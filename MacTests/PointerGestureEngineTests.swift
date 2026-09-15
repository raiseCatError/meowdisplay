import CoreGraphics
import XCTest

/// Pure-logic coverage for the M7 pointer/click gesture engine
/// (`Shared/PointerGestureEngine.swift`). No UIKit/gesture-recognizer
/// plumbing is exercised here (that lives in `iOS/OpenSidecarPhoneApp.swift`
/// and can't run outside a real app); this covers the touch-intent/session
/// policy both the recognizer and the real device rely on.
final class PointerGestureEngineTests: XCTestCase {
    func testOnlyDirectTouchSeedsAnAbsoluteScrollTarget() {
        XCTAssertTrue(PointerInputMode.direct.seedsAbsoluteScrollTarget)
        XCTAssertFalse(PointerInputMode.trackpad.seedsAbsoluteScrollTarget)
    }


    private func sample(_ id: Int, _ phase: PointerTouchSample.Phase,
                        view: CGPoint, norm: CGPoint? = CGPoint(x: 0.5, y: 0.5),
                        t: TimeInterval) -> PointerTouchSample {
        PointerTouchSample(id: AnyHashable(id), phase: phase, viewPoint: view, normalized: norm, time: t)
    }

    private func isMoveAbsolute(_ command: PointerCommand) -> Bool {
        if case .moveAbsolute = command { return true }
        return false
    }

    private func isMouseDown(_ command: PointerCommand) -> Bool {
        if case .mouseDown = command { return true }
        return false
    }

    /// Settles a already-begun touch `id` into `.absolutePointer` via
    /// movement evidence, well past `dragSlop` — the fast commit path,
    /// used throughout so tests don't need to wait out the arbitration
    /// window unless that's specifically what's under test.
    @discardableResult
    private func settleAsAnchor(_ engine: PointerGestureEngine, id: Int,
                                to settled: CGPoint, norm: CGPoint, t: TimeInterval) -> [PointerCommand] {
        engine.handle(sample(id, .moved, view: settled, norm: norm, t: t))
    }

    // MARK: - First-touch arbitration

    func testFirstTouchEmitsNothingUntilCommitted() {
        let engine = PointerGestureEngine()
        let down = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        XCTAssertEqual(down, [])   // withheld — still arbitrating
        XCTAssertEqual(engine.mode, .firstTouchPending)
    }

    func testQuickSecondTouchFormsFreshChordWithNoAbsoluteMoveEver() {
        let engine = PointerGestureEngine()
        let down1 = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        XCTAssertEqual(down1, [])
        // Second finger lands promptly, well inside the arbitration window.
        let down2 = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), norm: CGPoint(x: 0.3, y: 0.2), t: 0.02))
        XCTAssertEqual(down2, [])   // CRITICAL: no moveAbsolute to finger 1's location, ever
        XCTAssertEqual(engine.mode, .twoFingerPending)

        // Confirm nothing was silently queued while the fingers are still
        // down (nothing resolved yet — both are still on-screen).
        XCTAssertEqual(engine.poll(now: 5), [])
    }

    func testGenuineSingleFingerCommitsToAbsolutePointerViaMovement() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        // Movement well beyond dragSlop, inside the arbitration window —
        // commits immediately without waiting the window out.
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), norm: CGPoint(x: 0.4, y: 0.2), t: 0.01))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testGenuineSingleFingerCommitsToAbsolutePointerViaWindowExpiry() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        // Held still — no second finger, no movement.
        let stillArbitrating = engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow - 0.01)
        XCTAssertEqual(stillArbitrating, [])
        XCTAssertEqual(engine.mode, .firstTouchPending)

        let committed = engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow + 0.005)
        XCTAssertEqual(committed, [.moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testPlainMovementNeverImpliesMouseDown() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 0, y: 0), t: 0))
        // Move well beyond drag slop, then release — no click, no drag.
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 200, y: 200), t: 0.05))
        XCTAssertFalse(moved.contains(where: isMouseDown))
        let up = engine.handle(sample(1, .ended, view: CGPoint(x: 200, y: 200), t: 0.1))
        XCTAssertEqual(up, [])
        XCTAssertEqual(engine.mode, .idle)
    }

    // MARK: - Left click / tap counting

    func testSingleTapClicksOnceAfterChainWindowExpires() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), norm: CGPoint(x: 0.3, y: 0.3), t: 0))
        let up = engine.handle(sample(1, .ended, view: CGPoint(x: 11, y: 10), norm: CGPoint(x: 0.31, y: 0.3), t: 0.02))
        // The tap's own resolution moves the cursor there exactly once
        // (safe — no second finger ever joined) so the buffered click
        // lands at the right place.
        XCTAssertEqual(up, [.moveAbsolute(x: 0.31, y: 0.3)])
        XCTAssertEqual(engine.mode, .tapBuffered)
        let flushed = engine.poll(now: 0.02 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 1), .mouseUp(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .idle)
    }

    func testDoubleTapProducesClickCountTwo() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 12, y: 11), t: 0.08))
        let up = engine.handle(sample(2, .ended, view: CGPoint(x: 12, y: 11), t: 0.1))
        XCTAssertFalse(up.contains(where: isMouseDown))
        let flushed = engine.poll(now: 0.1 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 2), .mouseUp(button: .left, clickCount: 2)])
    }

    func testTripleTapProducesClickCountThree() {
        let engine = PointerGestureEngine()
        var t: TimeInterval = 0
        for id in 1...3 {
            _ = engine.handle(sample(id, .began, view: CGPoint(x: 10, y: 10), t: t))
            _ = engine.handle(sample(id, .ended, view: CGPoint(x: 10, y: 10), t: t + 0.02))
            t += 0.08
        }
        let flushed = engine.poll(now: t + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 3), .mouseUp(button: .left, clickCount: 3)])
    }

    func testMovementBeyondTapThresholdEmitsNoClick() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 0, y: 0), t: 0))
        _ = engine.handle(sample(1, .moved, view: CGPoint(x: 40, y: 0), t: 0.02))
        let up = engine.handle(sample(1, .ended, view: CGPoint(x: 40, y: 0), t: 0.04))
        XCTAssertEqual(up, [])
        let flushed = engine.poll(now: 1.0)
        XCTAssertEqual(flushed, [])   // nothing buffered — moved too far to be a tap
    }

    // MARK: - Left drag (tap-then-hold)

    func testTapThenHeldTouchProducesOnlyDragNoStrayClick() {
        let engine = PointerGestureEngine()
        // Tap 1.
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        XCTAssertEqual(engine.mode, .tapBuffered)

        // A second touchdown arrives quickly and is held (not released).
        let down2 = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 9), norm: CGPoint(x: 0.3, y: 0.3), t: 0.1))
        XCTAssertEqual(down2, [])   // still arbitrating — nothing emitted yet
        XCTAssertFalse(down2.contains(where: isMouseDown))

        // Movement beyond drag slop commits the drag — exactly one
        // mouseDown, carrying the tap chain's count (1), no bare click.
        let moved = engine.handle(sample(2, .moved, view: CGPoint(x: 40, y: 9), norm: CGPoint(x: 0.5, y: 0.3), t: 0.15))
        XCTAssertTrue(moved.contains(.mouseDown(button: .left, clickCount: 1)))
        XCTAssertEqual(engine.mode, .leftDragHeld)
        XCTAssertTrue(moved.contains(where: isMoveAbsolute))

        let dragged = engine.handle(sample(2, .moved, view: CGPoint(x: 60, y: 9), norm: CGPoint(x: 0.6, y: 0.3), t: 0.2))
        XCTAssertFalse(dragged.contains(where: isMouseDown))

        let up = engine.handle(sample(2, .ended, view: CGPoint(x: 60, y: 9), t: 0.25))
        XCTAssertEqual(up, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertEqual(engine.mode, .idle)

        // Flushing the (now-consumed) chain later must not double-fire.
        XCTAssertEqual(engine.poll(now: 10), [])
    }

    func testTapThenStationaryHoldStillCommitsDragViaHoldDelay() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 9), t: 0.1))

        // Held with no movement at all — the hold-commit delay alone
        // should still start the drag (mirrors a real tap-and-hold with a
        // perfectly steady finger).
        let committed = engine.poll(now: 0.1 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.moveAbsolute(x: 0.5, y: 0.5), .mouseDown(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .leftDragHeld)
    }

    // MARK: - Precision / relative session

    func testAbsoluteToRelativeSessionTransition() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 300, y: 0), norm: CGPoint(x: 0.6, y: 0.2), t: 0.02)
        XCTAssertEqual(engine.mode, .absolutePointer)

        let down2 = engine.handle(sample(2, .began, view: CGPoint(x: 20, y: 20), t: 0.1))
        XCTAssertEqual(down2, [])   // no jump to finger 2's location
        XCTAssertEqual(engine.mode, .relativePointerSession)
    }

    func testOriginalAnchorCanNoLongerEmitAbsoluteMovementAfterRelativeTransition() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 300, y: 0), norm: CGPoint(x: 0.6, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 20, y: 20), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)

        // Finger 1 (the original anchor) moves — this is the regression:
        // it must NEVER snap the Mac cursor back underneath itself again.
        let anchorMoved = engine.handle(sample(1, .moved, view: CGPoint(x: 305, y: 3), norm: CGPoint(x: 0.61, y: 0.21), t: 0.12))
        XCTAssertFalse(anchorMoved.contains(where: isMoveAbsolute))
        XCTAssertEqual(anchorMoved, [.moveRelative(dx: 5, dy: 3)])
    }

    func testBothRelativeFingersProduceDeltasWithoutSnapBack() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 300, y: 0), norm: CGPoint(x: 0.6, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 20, y: 20), t: 0.1))

        let anchorMoved = engine.handle(sample(1, .moved, view: CGPoint(x: 310, y: 5), t: 0.12))
        XCTAssertEqual(anchorMoved, [.moveRelative(dx: 10, dy: 5)])

        let precisionMoved = engine.handle(sample(2, .moved, view: CGPoint(x: 25, y: 24), t: 0.13))
        XCTAssertEqual(precisionMoved, [.moveRelative(dx: 5, dy: 4)])

        // Alternating movement never re-jumps either finger's baseline.
        let anchorMovedAgain = engine.handle(sample(1, .moved, view: CGPoint(x: 312, y: 5), t: 0.14))
        XCTAssertEqual(anchorMovedAgain, [.moveRelative(dx: 2, dy: 0)])
    }

    func testRelativeFingerLiftAndRetouchResetsItsOwnBaseline() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 300, y: 0), norm: CGPoint(x: 0.6, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 20, y: 20), t: 0.1))
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 30, y: 20), t: 0.12))
        // Held too long / moved too far by release to read as a tap.
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 60, y: 20), t: 0.2))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 60, y: 20), t: 0.9))
        XCTAssertEqual(engine.mode, .relativePointerSession)   // session continues (anchor still down)

        // Re-touch at a new location: origin resets there, not a jump —
        // and the anchor is still untouched/unaffected throughout.
        let down3 = engine.handle(sample(3, .began, view: CGPoint(x: 200, y: 200), t: 0.95))
        XCTAssertEqual(down3, [])
        let moved3 = engine.handle(sample(3, .moved, view: CGPoint(x: 210, y: 205), t: 0.97))
        XCTAssertEqual(moved3, [.moveRelative(dx: 10, dy: 5)])
    }

    func testQuickLaterFingerTapClicksAtCurrentCursorPositionAfterChainWindow() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, norm: CGPoint(x: 0.1, y: 0.1), t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.1), t: 0.02)
        XCTAssertEqual(engine.mode, .absolutePointer)

        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)
        let up = engine.handle(sample(2, .ended, view: CGPoint(x: 301, y: 299), t: 0.12))
        // Withheld — might still become a chain/drag (same tap-chain
        // buffering the anchor's own solo click already uses).
        XCTAssertEqual(up, [])
        XCTAssertEqual(engine.mode, .relativePointerSession)   // anchor session continues
        XCTAssertEqual(engine.pollDelay(now: 0.12) ?? -1, PointerGestureConfig.tapChainWindow, accuracy: 0.000_001)

        // Left click — carries no coordinates, so the caller sends it at
        // whatever the Mac's current cursor position already is.
        let flushed = engine.poll(now: 0.12 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 1), .mouseUp(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .relativePointerSession)
        XCTAssertEqual(engine.pollDelay(now: 0.12 + PointerGestureConfig.tapChainWindow + 0.01), nil)

        // A long, slow drift (many small per-frame moves, large total
        // displacement) must NOT still read as a tap on release — the tap
        // check uses total displacement from touchdown, not the last
        // frame's delta.
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 0, y: 0), t: 0.2))
        for i in 1...20 {
            _ = engine.handle(sample(4, .moved, view: CGPoint(x: CGFloat(i), y: 0), t: 0.2 + Double(i) * 0.01))
        }
        let driftUp = engine.handle(sample(4, .ended, view: CGPoint(x: 20, y: 0), t: 0.45))
        XCTAssertFalse(driftUp.contains(where: isMouseDown))
        XCTAssertEqual(engine.poll(now: 10), [])   // the drift never buffered a tap either
    }

    // MARK: - Relative-session left tap-chain / drag (GOAL: generalize to any participant)

    func testRelativeSecondaryFingerDoubleTapEmitsClickCountTwo() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)

        let up1 = engine.handle(sample(2, .ended, view: CGPoint(x: 301, y: 299), t: 0.12))
        XCTAssertEqual(up1, [])   // withheld — awaiting a possible continuation

        // A second touchdown near the first tap, soon after.
        let down2 = engine.handle(sample(3, .began, view: CGPoint(x: 302, y: 300), t: 0.18))
        XCTAssertEqual(down2, [])
        let up2 = engine.handle(sample(3, .ended, view: CGPoint(x: 302, y: 300), t: 0.2))
        XCTAssertEqual(up2, [])
        XCTAssertEqual(engine.mode, .relativePointerSession)   // anchor session never left

        let flushed = engine.poll(now: 0.2 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 2), .mouseUp(button: .left, clickCount: 2)])
    }

    func testRelativeSecondaryFingerTripleTapReachesClickCountThree() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        var t: TimeInterval = 0.1
        for id in 2...4 {
            _ = engine.handle(sample(id, .began, view: CGPoint(x: 300, y: 300), t: t))
            _ = engine.handle(sample(id, .ended, view: CGPoint(x: 300, y: 300), t: t + 0.02))
            t += 0.08
        }
        let flushed = engine.poll(now: t + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 3), .mouseUp(button: .left, clickCount: 3)])
    }

    func testRelativeSecondaryFingerTapThenHeldEntersLeftDragWithNoStandaloneClick() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        let tapUp = engine.handle(sample(2, .ended, view: CGPoint(x: 300, y: 300), t: 0.12))
        XCTAssertEqual(tapUp, [])

        // A second touchdown near the tap, held (not released quickly).
        let down3 = engine.handle(sample(3, .began, view: CGPoint(x: 301, y: 300), t: 0.18))
        XCTAssertEqual(down3, [])
        XCTAssertFalse(down3.contains(where: isMoveAbsolute))   // never switches back to absolute

        let moved = engine.handle(sample(3, .moved, view: CGPoint(x: 330, y: 300), t: 0.22))
        XCTAssertEqual(moved, [.mouseDown(button: .left, clickCount: 1)])   // no bare click, no move command
        XCTAssertFalse(moved.contains(where: isMoveAbsolute))

        // Further movement is relative, never absolute — this is the
        // regression under test (GOAL: "do not switch back to absolute").
        let dragged = engine.handle(sample(3, .moved, view: CGPoint(x: 335, y: 302), t: 0.25))
        XCTAssertEqual(dragged, [.moveRelative(dx: 5, dy: 2)])

        let up = engine.handle(sample(3, .ended, view: CGPoint(x: 335, y: 302), t: 0.3))
        XCTAssertEqual(up, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertEqual(engine.mode, .relativePointerSession)   // anchor session survives

        // The anchor itself is untouched throughout and can keep moving.
        let anchorMoved = engine.handle(sample(1, .moved, view: CGPoint(x: 205, y: 3), t: 0.32))
        XCTAssertEqual(anchorMoved, [.moveRelative(dx: 5, dy: 3)])

        XCTAssertEqual(engine.poll(now: 10), [])   // no stray click left buffered
    }

    func testRelativeSecondaryFingerTapThenStationaryHoldStillCommitsDrag() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 300, y: 300), t: 0.12))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 301, y: 300), t: 0.18))

        let committed = engine.poll(now: 0.18 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.mouseDown(button: .left, clickCount: 1)])
    }

    func testEitherRelativePointerParticipantCanPerformClickChain() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 300, y: 300), t: 0.12))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 301, y: 300), t: 0.18))
        _ = engine.handle(sample(3, .ended, view: CGPoint(x: 301, y: 300), t: 0.2))
        let flushed = engine.poll(now: 0.2 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 2), .mouseUp(button: .left, clickCount: 2)])
    }

    func testRelativeClickAndDragNeverEmitMoveAbsolute() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        var allCommands: [PointerCommand] = []
        allCommands += engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        allCommands += engine.handle(sample(2, .ended, view: CGPoint(x: 300, y: 300), t: 0.12))
        allCommands += engine.handle(sample(3, .began, view: CGPoint(x: 301, y: 300), t: 0.18))
        allCommands += engine.handle(sample(3, .moved, view: CGPoint(x: 330, y: 300), t: 0.22))
        allCommands += engine.handle(sample(3, .moved, view: CGPoint(x: 335, y: 305), t: 0.25))
        allCommands += engine.handle(sample(3, .ended, view: CGPoint(x: 335, y: 305), t: 0.3))
        allCommands += engine.poll(now: 10)
        XCTAssertFalse(allCommands.contains(where: isMoveAbsolute))
    }

    // MARK: - Right click / right drag

    func testFreshTwoFingerTapIsRightClickWithNoPrecedingAbsoluteMove() {
        let engine = PointerGestureEngine()
        let down1 = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        XCTAssertEqual(down1, [])
        let down2 = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        XCTAssertEqual(down2, [])
        XCTAssertEqual(engine.mode, .twoFingerPending)
        let up1 = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        XCTAssertEqual(up1, [])
        let up2 = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        XCTAssertEqual(up2, [])   // withheld for the double-tap/hold window
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.pollDelay(now: 0.06) ?? -1, PointerGestureConfig.tapChainWindow, accuracy: 0.000_001)
        let flushed = engine.poll(now: 0.06 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)])
        XCTAssertNil(engine.heldMouseButton)
    }

    /// GOAL: "fresh two-finger right click is still broken/finicky — first
    /// attempt often does nothing." Root cause: a second ordinary
    /// two-finger tap landing within the first's continuation window was
    /// being silently swallowed (both dropped) instead of flushing the
    /// first and re-arming for a possible third. Two ordinary right-clicks
    /// in a row, close together in time, must both fire.
    func testRepeatedOrdinaryTwoFingerRightClicksBothFireNotOnlyEveryOther() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))

        // A second, ordinary (not held) two-finger tap arrives well within
        // the first's continuation window.
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.1))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.11))
        let up3 = engine.handle(sample(3, .ended, view: CGPoint(x: 52, y: 52), t: 0.14))
        XCTAssertEqual(up3, [])   // one of the pair still down
        let up4 = engine.handle(sample(4, .ended, view: CGPoint(x: 72, y: 52), t: 0.15))
        // The FIRST tap is now confirmed final (this one didn't hold into
        // a drag either) and flushes immediately; the second tap is
        // itself now buffered.
        XCTAssertEqual(up4, [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)])

        // With nothing to continue it, the second tap flushes too.
        let flushed = engine.poll(now: 0.15 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)])
    }

    func testEstablishedPointerPlusTwoLaterFingersUsesChordSemantics() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        XCTAssertEqual(engine.mode, .absolutePointer)

        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)   // solo precision — not yet a chord
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 320, y: 300), t: 0.12))
        // Promoted to a 2-finger chord — no Mission Control takeover.
        XCTAssertEqual(engine.mode, .chordPending)

        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 301, y: 300), t: 0.15))
        let upLast = engine.handle(sample(3, .ended, view: CGPoint(x: 321, y: 301), t: 0.16))
        XCTAssertEqual(upLast, [])
        XCTAssertEqual(engine.mode, .relativePointerSession)   // anchor session survives the chord
        let flushed = engine.poll(now: 0.16 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)])

        // The anchor's relative tracking resumed from its live position —
        // no jump on the next move.
        let resumed = engine.handle(sample(1, .moved, view: CGPoint(x: 205, y: 2), t: 0.2))
        XCTAssertEqual(resumed, [.moveRelative(dx: 5, dy: 2)])
    }

    func testRightTapThenSecondChordHoldProducesOnlyRightDownDragUp() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        XCTAssertEqual(engine.mode, .idle)

        // A second two-finger touchdown arrives quickly, close to the
        // first tap, and is held.
        let down3 = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.15))
        XCTAssertEqual(down3, [])
        let down4 = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.16))
        XCTAssertEqual(down4, [])
        XCTAssertEqual(engine.mode, .twoFingerPending)

        // Held past the commit delay with no release — commits to a right
        // drag with NO preceding right click.
        let committed = engine.poll(now: 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.mode, .rightDragHeld)
        XCTAssertEqual(engine.heldMouseButton, .right)

        let moved = engine.handle(sample(3, .moved, view: CGPoint(x: 62, y: 52), t: 0.35))
        XCTAssertEqual(moved, [.moveRelative(dx: 5, dy: 0)])   // centroid moved by (5,0)

        let up3 = engine.handle(sample(3, .ended, view: CGPoint(x: 62, y: 52), t: 0.4))
        XCTAssertEqual(up3, [])   // one of two still down
        let up4 = engine.handle(sample(4, .ended, view: CGPoint(x: 72, y: 52), t: 0.41))
        XCTAssertEqual(up4, [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertNil(engine.heldMouseButton)

        // No stray right click was ever buffered/flushed for this sequence.
        XCTAssertEqual(engine.poll(now: 10), [])
    }

    func testFreshRightChordCanContinueWhenPartnerFingerArrivesAfterTapDeadline() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))

        // The next chord's first finger lands just inside the continuation
        // window. Polling at the old tap deadline must keep waiting for its
        // partner instead of posting the standalone right click.
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.27))
        XCTAssertEqual(engine.poll(now: 0.28), [])
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.30))

        let committed = engine.poll(now: 0.30 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.heldMouseButton, .right)

        XCTAssertEqual(engine.handle(sample(3, .moved, view: CGPoint(x: 62, y: 52), t: 0.47)),
                       [.moveRelative(dx: 5, dy: 0)])
        _ = engine.handle(sample(3, .ended, view: CGPoint(x: 62, y: 52), t: 0.50))
        let released = engine.handle(sample(4, .ended, view: CGPoint(x: 72, y: 52), t: 0.51))
        XCTAssertEqual(released, [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.poll(now: 10), [])
    }

    func testFreshRightChordMovementCommitsDragBeforeHoldDelay() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.15))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.16))

        let committed = engine.handle(sample(3, .moved, view: CGPoint(x: 74, y: 52), t: 0.18))
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.heldMouseButton, .right)
        XCTAssertFalse(committed.contains(where: isMoveAbsolute))

        let moved = engine.handle(sample(3, .moved, view: CGPoint(x: 80, y: 52), t: 0.19))
        XCTAssertEqual(moved, [.moveRelative(dx: 3, dy: 0)])
        _ = engine.handle(sample(3, .ended, view: CGPoint(x: 80, y: 52), t: 0.20))
        XCTAssertEqual(engine.handle(sample(4, .ended, view: CGPoint(x: 72, y: 52), t: 0.21)),
                       [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
    }

    func testExistingPointerRightChordContinuesIntoStationaryHeldDrag() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)

        // First right chord buffers its tap while the pointer anchor remains.
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.10))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 320, y: 300), t: 0.12))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 301, y: 300), t: 0.15))
        XCTAssertEqual(engine.handle(sample(3, .ended, view: CGPoint(x: 321, y: 301), t: 0.16)), [])
        XCTAssertEqual(engine.mode, .relativePointerSession)

        // The first added finger lands just before the candidate deadline;
        // the partner follows just after it. The pending click stays
        // undecided until the shared chord classifier sees both fingers.
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 310, y: 300), t: 0.37))
        XCTAssertEqual(engine.poll(now: 0.38), [])
        _ = engine.handle(sample(5, .began, view: CGPoint(x: 320, y: 300), t: 0.40))
        XCTAssertEqual(engine.mode, .chordPending)

        let committed = engine.poll(now: 0.40 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.heldMouseButton, .right)
        XCTAssertEqual(engine.handle(sample(4, .moved, view: CGPoint(x: 320, y: 300), t: 0.57)),
                       [.moveRelative(dx: 5, dy: 0)])
        _ = engine.handle(sample(4, .ended, view: CGPoint(x: 320, y: 300), t: 0.60))
        XCTAssertEqual(engine.handle(sample(5, .ended, view: CGPoint(x: 320, y: 300), t: 0.61)),
                       [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .relativePointerSession)

        // The anchor resumes from the position at which it was paused.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 205, y: 2), t: 0.62)),
                       [.moveRelative(dx: 5, dy: 2)])
    }

    /// GOAL: "the two fingers are acting as a BUTTON CHORD, not as
    /// pointing inputs" — no command from any point in a full
    /// tap/hold/drag/resume chord lifecycle may ever reposition the
    /// cursor, for either the fresh-chord path or the existing-pointer-
    /// session path.
    func testRightChordCoordinatesNeverRepositionCursor() {
        let engine = PointerGestureEngine()
        var all: [PointerCommand] = []
        // Fresh two-finger tap.
        all += engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        all += engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        all += engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        all += engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        all += engine.poll(now: 0.06 + PointerGestureConfig.tapChainWindow + 0.01)

        // Existing pointer session + two later fingers, tap and hold-drag.
        all += engine.handle(sample(3, .began, view: .zero, t: 1))
        all += settleAsAnchor(engine, id: 3, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 1.02)
        all += engine.handle(sample(4, .began, view: CGPoint(x: 300, y: 300), t: 1.1))
        all += engine.handle(sample(5, .began, view: CGPoint(x: 320, y: 300), t: 1.12))
        all += engine.handle(sample(4, .ended, view: CGPoint(x: 301, y: 300), t: 1.15))
        all += engine.handle(sample(5, .ended, view: CGPoint(x: 321, y: 301), t: 1.16))
        all += engine.poll(now: 1.16 + PointerGestureConfig.tapChainWindow + 0.01)
        all += engine.handle(sample(6, .began, view: CGPoint(x: 300, y: 300), t: 1.3))
        all += engine.handle(sample(7, .began, view: CGPoint(x: 320, y: 300), t: 1.31))
        all += engine.poll(now: 1.31 + PointerGestureConfig.holdCommitDelay + 0.01)
        all += engine.handle(sample(6, .moved, view: CGPoint(x: 340, y: 300), t: 1.5))
        all += engine.handle(sample(6, .ended, view: CGPoint(x: 340, y: 300), t: 1.6))
        all += engine.handle(sample(7, .ended, view: CGPoint(x: 320, y: 300), t: 1.61))

        // Exactly one `moveAbsolute` in this whole sequence: touch 3
        // legitimately establishing itself as the solo pointer anchor.
        // Nothing from either chord (fresh, or on the established
        // session) may ever reposition the cursor.
        let absoluteMoves = all.filter(isMoveAbsolute)
        XCTAssertEqual(absoluteMoves, [.moveAbsolute(x: 0.5, y: 0.2)])
    }

    // MARK: - Ownership / system gestures

    func testFreshThreeFingerGestureDefersEntirely() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        let third = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(third, [])
        XCTAssertEqual(engine.mode, .deferredSystemGesture)

        // Movement/release of any of these touches produces nothing —
        // the existing system-gesture recognizers own the sequence.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 10, y: 100), t: 0.1)), [])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 100), t: 0.2)), [])
        XCTAssertEqual(engine.handle(sample(2, .ended, view: CGPoint(x: 30, y: 100), t: 0.2)), [])
        XCTAssertEqual(engine.handle(sample(3, .ended, view: CGPoint(x: 50, y: 100), t: 0.2)), [])
    }

    /// The exact real-device failure: a fresh 3-finger system gesture defers
    /// entirely (as `testFreshThreeFingerGestureDefersEntirely` verifies),
    /// `VideoView.cancelTouchForGestureOwnership` then calls `reset()` (as
    /// soon as the gesture is recognized — typically well before all three
    /// fingers have physically lifted, since `cancelsTouchesInView = false`
    /// keeps delivering their trailing `moved`/`ended` samples to the
    /// engine), and only once every one of those three touches has actually
    /// ended does a genuinely fresh single-finger tap begin. That tap must
    /// resolve as a LEFT click, never a right click.
    func testFreshTapAfterThreeFingerGestureDeferAndResetIsALeftClickNotARightClick() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(engine.mode, .deferredSystemGesture)

        // Ownership taken mid-swipe, well before any finger has lifted.
        XCTAssertEqual(engine.reset(), [])
        XCTAssertEqual(engine.mode, .idle)

        // The three fingers keep moving and then lift one at a time —
        // still delivered to the engine (no UIKit-level cancellation) —
        // interleaved with the fresh tap that starts once they're gone.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 10, y: 120), t: 0.1)), [])
        XCTAssertEqual(engine.handle(sample(2, .moved, view: CGPoint(x: 30, y: 120), t: 0.1)), [])
        XCTAssertEqual(engine.handle(sample(3, .moved, view: CGPoint(x: 50, y: 120), t: 0.1)), [])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 120), t: 0.2)), [])
        XCTAssertEqual(engine.handle(sample(2, .ended, view: CGPoint(x: 30, y: 120), t: 0.21)), [])
        XCTAssertEqual(engine.handle(sample(3, .ended, view: CGPoint(x: 50, y: 120), t: 0.22)), [])
        XCTAssertEqual(engine.mode, .idle)

        // A genuinely fresh single-finger tap.
        let began = engine.handle(sample(4, .began, view: CGPoint(x: 200, y: 200),
                                         norm: CGPoint(x: 0.7, y: 0.7), t: 0.4))
        XCTAssertEqual(began, [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        let ended = engine.handle(sample(4, .ended, view: CGPoint(x: 200, y: 200),
                                         norm: CGPoint(x: 0.7, y: 0.7), t: 0.42))
        XCTAssertEqual(ended, [.moveAbsolute(x: 0.7, y: 0.7)])
        XCTAssertEqual(engine.mode, .tapBuffered)

        let flushed = engine.poll(now: 0.42 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 1),
                                 .mouseUp(button: .left, clickCount: 1)])
    }

    /// Same as above for a 4-finger pinch/spread system gesture (the
    /// already-working comparison case) — confirms the engine treats both
    /// group sizes identically once deferred and reset.
    func testFreshTapAfterFourFingerGestureDeferAndResetIsALeftClick() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 70, y: 10), t: 0.03))
        XCTAssertEqual(engine.mode, .deferredSystemGesture)

        XCTAssertEqual(engine.reset(), [])
        XCTAssertEqual(engine.mode, .idle)

        for (id, x) in [(1, 10.0), (2, 30.0), (3, 50.0), (4, 70.0)] {
            XCTAssertEqual(engine.handle(sample(id, .moved, view: CGPoint(x: x, y: 120), t: 0.1)), [])
        }
        for (id, x, t) in [(1, 10.0, 0.2), (2, 30.0, 0.21), (3, 50.0, 0.22), (4, 70.0, 0.23)] {
            XCTAssertEqual(engine.handle(sample(id, .ended, view: CGPoint(x: x, y: 120), t: t)), [])
        }
        XCTAssertEqual(engine.mode, .idle)

        let began = engine.handle(sample(5, .began, view: CGPoint(x: 200, y: 200),
                                         norm: CGPoint(x: 0.7, y: 0.7), t: 0.4))
        XCTAssertEqual(began, [])
        let ended = engine.handle(sample(5, .ended, view: CGPoint(x: 200, y: 200),
                                         norm: CGPoint(x: 0.7, y: 0.7), t: 0.42))
        XCTAssertEqual(ended, [.moveAbsolute(x: 0.7, y: 0.7)])
        let flushed = engine.poll(now: 0.42 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 1),
                                 .mouseUp(button: .left, clickCount: 1)])
    }

    /// After a deferred-and-reset 3-finger gesture, a fresh DOUBLE tap must
    /// still count correctly (clickCount 2) — the reset must not leave any
    /// residual tap-chain state, but must also not block ordinary chaining
    /// for the genuinely new sequence.
    func testFreshDoubleTapAfterThreeFingerGestureCountsCorrectly() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(engine.reset(), [])
        for id in [1, 2, 3] {
            _ = engine.handle(sample(id, .ended, view: CGPoint(x: Double(id) * 20, y: 120), t: 0.2))
        }

        _ = engine.handle(sample(10, .began, view: CGPoint(x: 200, y: 200), t: 0.4))
        _ = engine.handle(sample(10, .ended, view: CGPoint(x: 200, y: 200), t: 0.41))
        _ = engine.handle(sample(11, .began, view: CGPoint(x: 201, y: 200), t: 0.45))
        // Each tap in the chain also repositions the cursor to its own tap
        // location (see `.firstTouchPending`'s `ended()` case) — only the
        // click itself stays buffered, waiting out the chain window.
        let secondTapUp = engine.handle(sample(11, .ended, view: CGPoint(x: 201, y: 200), t: 0.46))
        XCTAssertEqual(secondTapUp, [.moveAbsolute(x: 0.5, y: 0.5)])
        let flushed = engine.poll(now: 0.46 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 2),
                                 .mouseUp(button: .left, clickCount: 2)])
    }

    /// A fresh pointer *drag* (not a tap) after a deferred-and-reset
    /// 3-finger gesture must also start clean: exactly one `moveAbsolute`
    /// from the new anchor, no leftover chord/right-click output.
    func testFreshPointerMovementAfterThreeFingerGestureStartsClean() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(engine.reset(), [])
        for id in [1, 2, 3] {
            _ = engine.handle(sample(id, .ended, view: CGPoint(x: Double(id) * 20, y: 120), t: 0.2))
        }

        _ = engine.handle(sample(20, .began, view: CGPoint(x: 200, y: 200), t: 0.4))
        let moved = engine.handle(sample(20, .moved, view: CGPoint(x: 260, y: 200),
                                         norm: CGPoint(x: 0.8, y: 0.5), t: 0.42))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.8, y: 0.5)])
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertTrue(moved.allSatisfy { !isMouseDown($0) })
    }

    /// A fresh, genuine two-finger right-click chord after a deferred-and-
    /// reset 3-finger gesture must still work — the fix must not suppress
    /// legitimate right-clicks going forward, only the stale leftovers of
    /// the claimed sequence.
    func testFreshTwoFingerRightClickAfterThreeFingerGestureStillWorks() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(engine.reset(), [])
        for id in [1, 2, 3] {
            _ = engine.handle(sample(id, .ended, view: CGPoint(x: Double(id) * 20, y: 120), t: 0.2))
        }

        _ = engine.handle(sample(30, .began, view: CGPoint(x: 200, y: 200), t: 0.4))
        _ = engine.handle(sample(31, .began, view: CGPoint(x: 220, y: 200), t: 0.41))
        XCTAssertEqual(engine.mode, .twoFingerPending)
        _ = engine.handle(sample(30, .ended, view: CGPoint(x: 200, y: 200), t: 0.44))
        _ = engine.handle(sample(31, .ended, view: CGPoint(x: 220, y: 200), t: 0.45))
        // A quick fresh chord tap buffers a right tap, only flushed if
        // nothing continues it — poll past the window to confirm it
        // actually resolves as a right click, not silently dropped.
        _ = engine.poll(now: 0.45 + PointerGestureConfig.tapChainWindow + 0.01)

        // Continue it into a drag with a second chord to force the
        // right-click through unambiguously (mirrors
        // `testCancellingRightDragReleasesTheButtonExactlyOnce`'s pattern).
        let engine2 = PointerGestureEngine()
        _ = engine2.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine2.handle(sample(2, .began, view: CGPoint(x: 30, y: 10), t: 0.01))
        _ = engine2.handle(sample(3, .began, view: CGPoint(x: 50, y: 10), t: 0.02))
        XCTAssertEqual(engine2.reset(), [])
        for id in [1, 2, 3] {
            _ = engine2.handle(sample(id, .ended, view: CGPoint(x: Double(id) * 20, y: 120), t: 0.2))
        }
        _ = engine2.handle(sample(30, .began, view: CGPoint(x: 200, y: 200), t: 0.4))
        _ = engine2.handle(sample(31, .began, view: CGPoint(x: 220, y: 200), t: 0.41))
        _ = engine2.handle(sample(30, .ended, view: CGPoint(x: 200, y: 200), t: 0.44))
        _ = engine2.handle(sample(31, .ended, view: CGPoint(x: 220, y: 200), t: 0.45))
        _ = engine2.handle(sample(32, .began, view: CGPoint(x: 202, y: 202), t: 0.5))
        _ = engine2.handle(sample(33, .began, view: CGPoint(x: 222, y: 202), t: 0.51))
        let rightDown = engine2.poll(now: 0.51 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(rightDown, [.mouseDown(button: .right, clickCount: 1)])
    }

    func testEstablishedPointerPlusTwoLaterFingersNeverDefersToSystemGesture() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 320, y: 300), t: 0.12))
        XCTAssertNotEqual(engine.mode, .deferredSystemGesture)
        XCTAssertEqual(engine.mode, .chordPending)
    }

    /// Simulates the legacy scroll/pinch recognizer winning a race for a
    /// fresh two-finger sequence the engine was also tracking as a
    /// right-click candidate — `VideoView.cancelTouchForGestureOwnership`
    /// calls `reset()` on exactly this kind of win, and after that no
    /// right-click output must ever reach the wire for these touches.
    func testScrollPinchOwnershipWinSuppressesPointerOutput() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        XCTAssertEqual(engine.mode, .twoFingerPending)

        let released = engine.reset()
        XCTAssertEqual(released, [])   // no button was held — nothing to release
        XCTAssertEqual(engine.mode, .idle)

        // The same physical touches continuing to move/lift produce
        // nothing further — the engine has fully let go of them.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 90), t: 0.05)), [])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 90), t: 0.1)), [])
        XCTAssertEqual(engine.handle(sample(2, .ended, view: CGPoint(x: 120, y: 90), t: 0.1)), [])
        XCTAssertEqual(engine.poll(now: 10), [])
    }

    // MARK: - Safety / cleanup

    func testReleaseHeldEndsAnOpenLeftDrag() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 9), t: 0.1))
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 40, y: 9), t: 0.15))
        XCTAssertEqual(engine.mode, .leftDragHeld)

        let released = engine.releaseHeld()
        XCTAssertEqual(released, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertEqual(engine.releaseHeld(), [])   // idempotent
    }

    func testReleaseHeldEndsAnOpenRightDrag() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.15))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.16))
        _ = engine.poll(now: 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(engine.mode, .rightDragHeld)

        XCTAssertEqual(engine.releaseHeld(), [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
    }

    func testCancelledFreshRightChordDoesNotLeaveAButtonHeld() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .cancelled, view: CGPoint(x: 50, y: 50), t: 0.05))
        XCTAssertEqual(engine.handle(sample(2, .cancelled, view: CGPoint(x: 70, y: 50), t: 0.06)), [])

        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.poll(now: 10), [])
    }

    func testCancellingRightDragReleasesTheButtonExactlyOnce() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.15))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.16))
        XCTAssertEqual(engine.poll(now: 0.32), [.mouseDown(button: .right, clickCount: 1)])

        let firstCancel = engine.handle(sample(3, .cancelled, view: CGPoint(x: 52, y: 52), t: 0.35))
        XCTAssertEqual(firstCancel, [])
        let lastCancel = engine.handle(sample(4, .cancelled, view: CGPoint(x: 72, y: 52), t: 0.36))
        XCTAssertEqual(lastCancel, [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.reset(), [])
    }

    func testResetReleasesHeldButtonAndForgetsAllTouches() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 9), t: 0.1))
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 40, y: 9), t: 0.15))
        XCTAssertEqual(engine.mode, .leftDragHeld)

        let out = engine.reset()
        XCTAssertEqual(out, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertEqual(engine.mode, .idle)
        // A stray sample for the now-forgotten touch is a no-op, not a crash.
        XCTAssertEqual(engine.handle(sample(2, .moved, view: CGPoint(x: 50, y: 9), t: 0.2)), [])
    }

    func testResetDuringRelativeSessionReleasesNothingHeldAndForgetsBothFingers() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 20, y: 20), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)

        XCTAssertEqual(engine.reset(), [])   // no button held during precision
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 205, y: 2), t: 0.2)), [])
        XCTAssertEqual(engine.handle(sample(2, .moved, view: CGPoint(x: 25, y: 24), t: 0.2)), [])
    }

    // MARK: - Trackpad input mode

    func testDefaultInputModeIsDirect() {
        XCTAssertEqual(PointerGestureEngine().inputMode, .direct)
    }

    func testTrackpadTouchDownNeverMovesCursor() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        let down = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        XCTAssertEqual(down, [])
        // Movement well beyond dragSlop commits the session — still no
        // absolute move, ever, in trackpad mode.
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), norm: CGPoint(x: 0.4, y: 0.2), t: 0.01))
        XCTAssertFalse(moved.contains(where: isMoveAbsolute))
        XCTAssertEqual(engine.mode, .relativePointerSession)
    }

    func testTrackpadOneFingerMovementProducesRelativeDeltas() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), t: 0))
        let committed = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), t: 0.01))
        XCTAssertEqual(committed, [])   // the crossing movement itself is absorbed, not replayed
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 160, y: 105), t: 0.02))
        XCTAssertEqual(moved, [.moveRelative(dx: 10, dy: 5)])
    }

    func testTrackpadWindowExpiryCommitsWithoutMovingCursorThenTracksRelatively() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), norm: CGPoint(x: 0.2, y: 0.2), t: 0))
        let committed = engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow + 0.005)
        XCTAssertEqual(committed, [])
        XCTAssertEqual(engine.mode, .relativePointerSession)
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 108, y: 100),
                                         t: PointerGestureConfig.firstTouchArbitrationWindow + 0.02))
        XCTAssertEqual(moved, [.moveRelative(dx: 8, dy: 0)])
    }

    func testTrackpadTapClicksAtCurrentCursorLocationNotTouchLocation() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), norm: CGPoint(x: 0.3, y: 0.3), t: 0))
        let up = engine.handle(sample(1, .ended, view: CGPoint(x: 11, y: 10), norm: CGPoint(x: 0.31, y: 0.3), t: 0.02))
        // Unlike direct mode, nothing moves the cursor — the click must
        // land wherever the Mac's cursor already is.
        XCTAssertEqual(up, [])
        XCTAssertEqual(engine.mode, .tapBuffered)
        let flushed = engine.poll(now: 0.02 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .left, clickCount: 1), .mouseUp(button: .left, clickCount: 1)])
    }

    func testTrackpadTapHoldThenMoveDragsRelativelyAndReleaseCleansUp() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        // A quick tap, buffered...
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        XCTAssertEqual(engine.mode, .tapBuffered)
        // ...then a fresh touch continues the chain and holds past the
        // hold-commit delay with real movement — commits to a drag with NO
        // absolute move (button posts at the cursor's current position).
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 11), t: 0.08))
        let dragStart = engine.handle(sample(2, .moved, view: CGPoint(x: 25, y: 11), t: 0.1))
        XCTAssertEqual(dragStart, [.mouseDown(button: .left, clickCount: 1)])
        XCTAssertFalse(dragStart.contains(where: isMoveAbsolute))
        XCTAssertEqual(engine.heldMouseButton, .left)

        let dragMove = engine.handle(sample(2, .moved, view: CGPoint(x: 40, y: 11), t: 0.12))
        XCTAssertEqual(dragMove, [.moveRelative(dx: 15, dy: 0)])

        let release = engine.handle(sample(2, .ended, view: CGPoint(x: 40, y: 11), t: 0.14))
        XCTAssertEqual(release, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .idle)
    }

    /// Regression: the STATIONARY-hold commit path (via `poll()`, when a
    /// continuing touch holds past `holdCommitDelay` without ever crossing
    /// `dragSlop`) must never jump the cursor either — only the
    /// movement-triggered commit path (`moved()`) was originally fixed;
    /// this covers the "tap → hold (stay still) → then move" sequence that
    /// only `poll()`'s timer branch resolves.
    func testTrackpadTapHoldStationaryThenMoveNeverEmitsAbsoluteMove() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), norm: CGPoint(x: 0.3, y: 0.3), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), norm: CGPoint(x: 0.3, y: 0.3), t: 0.02))
        XCTAssertEqual(engine.mode, .tapBuffered)

        // A fresh touch continues the chain and holds PERFECTLY STILL past
        // holdCommitDelay — never crosses dragSlop, so only `poll()`
        // resolves it, not `moved()`.
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 11), norm: CGPoint(x: 0.31, y: 0.31), t: 0.08))
        let commands = engine.poll(now: 0.08 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertFalse(commands.contains(where: isMoveAbsolute))
        XCTAssertEqual(commands, [.mouseDown(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .relativePointerSession)
        XCTAssertEqual(engine.heldMouseButton, .left)

        // Subsequent movement is relative, from wherever the cursor
        // actually is — never replayed as an absolute jump.
        let moved = engine.handle(sample(2, .moved, view: CGPoint(x: 21, y: 11),
                                         t: 0.08 + PointerGestureConfig.holdCommitDelay + 0.02))
        XCTAssertEqual(moved, [.moveRelative(dx: 10, dy: 0)])
    }

    // MARK: - Trackpad sensitivity

    func testDefaultTrackpadSensitivityPreservesUnscaledDelta() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        XCTAssertEqual(engine.trackpadSensitivity, PointerGestureConfig.defaultTrackpadSensitivity)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), t: 0))
        _ = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), t: 0.01))
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 160, y: 105), t: 0.02))
        XCTAssertEqual(moved, [.moveRelative(dx: 10, dy: 5)])
    }

    func testTrackpadSensitivityScalesOneFingerRelativeDelta() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        engine.trackpadSensitivity = 2.0
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), t: 0))
        _ = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), t: 0.01))
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 160, y: 105), t: 0.02))
        XCTAssertEqual(moved, [.moveRelative(dx: 20, dy: 10)])
    }

    func testTrackpadSensitivityIsClampedToConfiguredRange() {
        let engine = PointerGestureEngine()
        engine.trackpadSensitivity = 999
        XCTAssertEqual(engine.trackpadSensitivity, PointerGestureConfig.trackpadSensitivityRange.upperBound)
        engine.trackpadSensitivity = -5
        XCTAssertEqual(engine.trackpadSensitivity, PointerGestureConfig.trackpadSensitivityRange.lowerBound)
    }

    func testTrackpadSensitivityNeverAffectsDirectModeHybridPrecisionMove() {
        let engine = PointerGestureEngine()
        // Direct mode (default) — sensitivity set high, must be ignored.
        engine.trackpadSensitivity = 2.0
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        XCTAssertEqual(engine.mode, .absolutePointer)
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 300, y: 300), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)   // hybrid precision, still Direct mode
        let moved = engine.handle(sample(2, .moved, view: CGPoint(x: 310, y: 305), t: 0.12))
        XCTAssertEqual(moved, [.moveRelative(dx: 10, dy: 5)])   // unscaled
    }

    func testTrackpadSensitivityNeverAffectsTwoFingerRightDrag() {
        // Same sequence as testRightTapThenSecondChordHoldProducesOnlyRightDownDragUp,
        // but in Trackpad mode with sensitivity maxed — the right-drag delta
        // must come out identical regardless.
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        engine.trackpadSensitivity = 2.0
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))

        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.15))
        _ = engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.16))
        let committed = engine.poll(now: 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.mode, .rightDragHeld)

        let moved = engine.handle(sample(3, .moved, view: CGPoint(x: 62, y: 52), t: 0.35))
        XCTAssertEqual(moved, [.moveRelative(dx: 5, dy: 0)])   // unscaled centroid delta
    }

    /// Regression for the real-device "right click → hold → drag" report.
    /// The exact physical flow: cursor already somewhere, first finger
    /// down, second finger joins STAGGERED (past the 150ms arbitration
    /// window — the timing that used to get the first finger swallowed
    /// into its own solo Trackpad session instead of forming the
    /// continuation chord), the chord commits, is held, dragged, released.
    func testTrackpadRightClickChordHoldDragNeverJumpsAbsolutelyEvenWithStaggeredFingerArrival() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)

        // First right click: quick two-finger tap, buffers a pending right
        // tap for the second attempt to continue.
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))

        var allCommands: [PointerCommand] = []

        // Second attempt: finger 3 lands ALONE and sits past the 150ms
        // arbitration window before its partner joins.
        allCommands += engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.1))
        allCommands += engine.poll(now: 0.1 + PointerGestureConfig.firstTouchArbitrationWindow + 0.02)
        // Must still be withheld, arbitrating — NOT solo-committed to its
        // own relative session (which would swallow the pending chord).
        XCTAssertEqual(engine.mode, .firstTouchPending)

        // The partner now joins, well after the 150ms window but still
        // within the buffered tap's own continuation window.
        allCommands += engine.handle(sample(4, .began, view: CGPoint(x: 72, y: 52), t: 0.28))
        XCTAssertEqual(engine.mode, .twoFingerPending)
        XCTAssertTrue(engine.isChordContinuation)

        // Held past the commit delay with no movement — right mouseDown,
        // no move of any kind.
        let committed = engine.poll(now: 0.28 + PointerGestureConfig.holdCommitDelay + 0.01)
        allCommands += committed
        XCTAssertEqual(committed, [.mouseDown(button: .right, clickCount: 1)])
        XCTAssertEqual(engine.mode, .rightDragHeld)
        XCTAssertEqual(engine.heldMouseButton, .right)

        // Drag: relative centroid deltas only.
        let dragMove = engine.handle(sample(3, .moved, view: CGPoint(x: 67, y: 52),
                                            t: 0.28 + PointerGestureConfig.holdCommitDelay + 0.05))
        allCommands += dragMove
        XCTAssertEqual(dragMove, [.moveRelative(dx: 7.5, dy: 0)])

        // Release both fingers — clean right mouseUp.
        allCommands += engine.handle(sample(3, .ended, view: CGPoint(x: 67, y: 52), t: 1.0))
        let release = engine.handle(sample(4, .ended, view: CGPoint(x: 72, y: 52), t: 1.01))
        allCommands += release
        XCTAssertEqual(release, [.mouseUp(button: .right, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .idle)

        XCTAssertFalse(allCommands.contains(where: isMoveAbsolute))
    }

    func testTrackpadStaggeredLoneFingerEventuallyCommitsSoloIfNoPartnerEverArrives() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))

        _ = engine.handle(sample(3, .began, view: CGPoint(x: 52, y: 52), t: 0.1))
        // Nobody ever joins — well past both the arbitration window AND
        // the buffered tap's own continuation window.
        let committed = engine.poll(now: 0.1 + PointerGestureConfig.tapChainWindow + 0.05)
        XCTAssertFalse(committed.contains(where: isMoveAbsolute))
        XCTAssertEqual(engine.mode, .relativePointerSession)   // committed solo, as a normal Trackpad session
    }

    func testTrackpadHigherFingerGesturesShareDirectModeSemantics() {
        // Two-finger/right-click chord arbitration is unmodified by input
        // mode — a fresh two-finger tap still right-clicks in trackpad mode.
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 50, y: 50), t: 0))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 70, y: 50), t: 0.01))
        XCTAssertEqual(engine.mode, .twoFingerPending)
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 51, y: 50), t: 0.05))
        _ = engine.handle(sample(2, .ended, view: CGPoint(x: 71, y: 51), t: 0.06))
        let flushed = engine.poll(now: 0.06 + PointerGestureConfig.tapChainWindow + 0.01)
        XCTAssertEqual(flushed, [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)])
    }

    // MARK: - Input mode switching

    func testSetInputModeIsNoOpWhenUnchanged() {
        let engine = PointerGestureEngine()
        _ = engine.handle(sample(1, .began, view: .zero, t: 0))
        _ = settleAsAnchor(engine, id: 1, to: CGPoint(x: 200, y: 0), norm: CGPoint(x: 0.5, y: 0.2), t: 0.02)
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertEqual(engine.setInputMode(.direct), [])
        XCTAssertEqual(engine.mode, .absolutePointer)   // untouched — same mode requested
    }

    func testSwitchingModeMidLeftDragReleasesTheHeldButtonAndReturnsToIdle() {
        let engine = PointerGestureEngine()
        // Tap-then-hold-drag in direct mode.
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 11), norm: CGPoint(x: 0.3, y: 0.3), t: 0.08))
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 30, y: 11), norm: CGPoint(x: 0.5, y: 0.3), t: 0.1))
        XCTAssertEqual(engine.mode, .leftDragHeld)
        XCTAssertEqual(engine.heldMouseButton, .left)

        let cleanup = engine.setInputMode(.trackpad)
        XCTAssertEqual(cleanup, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.inputMode, .trackpad)

        // The next gesture starts completely clean under the new mode.
        _ = engine.handle(sample(3, .began, view: CGPoint(x: 0, y: 0), t: 0.5))
        let fresh = engine.handle(sample(3, .moved, view: CGPoint(x: 20, y: 0), t: 0.51))
        XCTAssertEqual(fresh, [])   // trackpad: crossing movement absorbed, no jump
        XCTAssertEqual(engine.mode, .relativePointerSession)
    }

    func testSwitchingModeMidRelativeSessionReleasesHeldButtonAndForgetsFingers() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(sample(1, .began, view: CGPoint(x: 10, y: 10), t: 0))
        _ = engine.handle(sample(1, .ended, view: CGPoint(x: 10, y: 10), t: 0.02))
        _ = engine.handle(sample(2, .began, view: CGPoint(x: 11, y: 11), t: 0.08))
        _ = engine.handle(sample(2, .moved, view: CGPoint(x: 30, y: 11), t: 0.1))
        XCTAssertEqual(engine.mode, .relativePointerSession)
        XCTAssertEqual(engine.heldMouseButton, .left)

        let cleanup = engine.setInputMode(.direct)
        XCTAssertEqual(cleanup, [.mouseUp(button: .left, clickCount: 0)])
        XCTAssertNil(engine.heldMouseButton)
        XCTAssertEqual(engine.mode, .idle)

        // No stuck touch: the same finger id starting a brand-new sequence
        // afterward is treated as fresh, not a continuation.
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 60, y: 60), t: 1)), [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
    }
}
