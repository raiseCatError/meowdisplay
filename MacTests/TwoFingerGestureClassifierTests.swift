import CoreGraphics
import XCTest

/// Pure-logic coverage for the two-finger gesture arbitration policy: the
/// three-way choice between remote-Mac scroll, local viewport pinch-zoom,
/// and (once a viewport session is already under way) local viewport pan.
/// No UIKit/gesture-recognizer plumbing is exercised here — that lives in
/// `iOS/OpenSidecarPhoneApp.swift`'s `TwoFingerViewportGestureRecognizer`,
/// which is a thin wrapper around exactly the logic under test here
/// (`TwoFingerGestureClassifier` + `TwoFingerGestureSession`).
///
/// Product rule under test: an ordinary two-finger drag — parallel finger
/// movement with little separation change — must classify as `.scroll`,
/// regardless of current manual zoom (zoom level never enters this
/// decision at all, which is the fix for the real-device regression where
/// any two-finger movement while zoomed was misread as viewport pan). A
/// clear, deliberate change in finger separation classifies as
/// `.viewportZoomPan`. Once a session commits to either, it must hold that
/// answer for the rest of the touch sequence.
final class TwoFingerGestureClassifierTests: XCTestCase {

    private let origin = CGPoint(x: 200, y: 400)

    // MARK: - Fresh gesture: scroll

    func testFreshParallelDragClassifiesAsScroll() {
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 120, currentDistance: 122,   // negligible separation change
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 40, y: origin.y + 5))
        XCTAssertEqual(result, .scroll)
    }

    func testFreshParallelDragClassifiesAsScrollRegardlessOfCurrentZoomLevel() {
        // The classifier takes no zoom parameter at all — this is the fix:
        // scroll eligibility must not depend on manual zoom state.
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 300, currentDistance: 305,
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x - 30, y: origin.y + 20))
        XCTAssertEqual(result, .scroll, "scroll must remain reachable regardless of manual zoom")
    }

    func testSmallSeparationJitterDuringADragRemainsScroll() {
        // A big centroid move with only a tiny (sub-threshold) spacing
        // change — natural finger sloppiness during an intentional scroll.
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 100, currentDistance: 103,   // 3% — under the 6% pinch threshold
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 50, y: origin.y))
        XCTAssertEqual(result, .scroll)
    }

    // MARK: - Fresh gesture: pinch

    func testClearSeparationIncreaseClassifiesAsViewportZoom() {
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 100, currentDistance: 130,   // 30% spread
            initialMidpoint: origin, currentMidpoint: origin)   // centroid barely moves
        XCTAssertEqual(result, .viewportZoomPan)
    }

    func testClearSeparationDecreaseClassifiesAsViewportZoom() {
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 200, currentDistance: 150,   // pinching inward
            initialMidpoint: origin, currentMidpoint: origin)
        XCTAssertEqual(result, .viewportZoomPan)
    }

    // MARK: - Ambiguous samples: dominance

    func testUndecidedBelowBothThresholds() {
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 100, currentDistance: 102,   // 2%, under threshold
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 3, y: origin.y))   // under threshold
        XCTAssertEqual(result, .undecided)
    }

    func testScaleSignalDominatesWhenBothThresholdsAreCrossedTogether() {
        // Distance changed 20% (well past its 6% threshold) while the
        // centroid moved only barely past its own threshold — the pinch
        // signal is proportionally far stronger, so it wins.
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 100, currentDistance: 120,
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 11, y: origin.y))
        XCTAssertEqual(result, .viewportZoomPan)
    }

    func testScrollSignalDominatesWhenScaleChangeIsOnlyMarginallyOverThreshold() {
        // Distance changed only just past its threshold while the centroid
        // moved far past its own — a diagonal scroll drag that happens to
        // also spread the fingers slightly must still read as scroll.
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 100, currentDistance: 106.5,   // just over 6%
            initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 60, y: origin.y))   // 6x its threshold
        XCTAssertEqual(result, .scroll)
    }

    // MARK: - Degenerate inputs never crash or hang

    func testZeroInitialDistanceIsUndecidedNotNaN() {
        let result = TwoFingerGestureClassifier.classify(
            initialDistance: 0, currentDistance: 50,
            initialMidpoint: origin, currentMidpoint: origin)
        XCTAssertEqual(result, .undecided)
    }

    // MARK: - Session: commit-once / no oscillation

    func testSessionCommitsToScrollAndHoldsItDespiteALaterClearPinchSample() {
        var session = TwoFingerGestureSession()
        XCTAssertEqual(session.update(initialDistance: 100, currentDistance: 101,
                                      initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 20, y: origin.y)),
                      .scroll)
        // A later sample in the *same* session that looks like a strong
        // pinch must NOT flip the already-committed intent.
        let after = session.update(initialDistance: 100, currentDistance: 160,
                                   initialMidpoint: origin, currentMidpoint: origin)
        XCTAssertEqual(after, .scroll, "a committed session must never oscillate back to a different intent")
        XCTAssertEqual(session.intent, .scroll)
    }

    func testSessionCommitsToViewportZoomAndHoldsItAcrossPureCentroidMovement() {
        var session = TwoFingerGestureSession()
        XCTAssertEqual(session.update(initialDistance: 100, currentDistance: 140,
                                      initialMidpoint: origin, currentMidpoint: origin),
                      .viewportZoomPan)
        // After the pinch commits, moving the midpoint (panning the
        // zoomed viewport, fingers still down) must stay the same intent
        // — this is "viewport pan after pinch", not a new decision.
        let after = session.update(initialDistance: 100, currentDistance: 140,
                                   initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 80, y: origin.y - 40))
        XCTAssertEqual(after, .viewportZoomPan)
        XCTAssertEqual(session.intent, .viewportZoomPan)
    }

    func testSessionStaysUndecidedUntilAThresholdIsCrossed() {
        var session = TwoFingerGestureSession()
        XCTAssertEqual(session.update(initialDistance: 100, currentDistance: 101,
                                      initialMidpoint: origin, currentMidpoint: CGPoint(x: origin.x + 1, y: origin.y)),
                      .undecided)
        XCTAssertEqual(session.intent, .undecided)
    }

    func testAFreshSessionAfterOneCommitsStartsUndecidedAgain() {
        // Models "lifting fingers resets ownership": a brand-new session
        // value (as `reset()` creates) carries none of a prior gesture's
        // commitment.
        var first = TwoFingerGestureSession()
        _ = first.update(initialDistance: 100, currentDistance: 140, initialMidpoint: origin, currentMidpoint: origin)
        XCTAssertEqual(first.intent, .viewportZoomPan)

        let second = TwoFingerGestureSession()
        XCTAssertEqual(second.intent, .undecided, "a fresh two-finger touch-down must not inherit the previous gesture's intent")
    }
}
