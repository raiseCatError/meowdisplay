import XCTest

/// Pure-logic tests for the wake/lid/topology-churn debounce used by
/// `MacSender.offerExtendOrFailMirror` before cancelling a pending
/// Mirror-unavailable offer and resuming Mirror.
final class DisplayStabilityTrackerTests: XCTestCase {

    /// A single transient "usable" sample (exactly the wake-transition
    /// false-positive blip reported on real hardware) must NOT be enough to
    /// declare the display stably back.
    func testTransientSingleUsableSampleDoesNotDeclareStable() {
        var tracker = DisplayStabilityTracker()
        XCTAssertFalse(tracker.recordSample(usable: true),
            "one usable sample must not cancel a pending offer by itself")
    }

    /// Consecutive usable samples reaching the required threshold (~1s at
    /// the existing poll cadence) DO declare the display stable.
    func testConsecutiveUsableSamplesDeclareStable() {
        var tracker = DisplayStabilityTracker()
        for i in 0..<(DisplayStabilityTracker.requiredConsecutiveSamples - 1) {
            XCTAssertFalse(tracker.recordSample(usable: true), "sample \(i) alone must not be enough")
        }
        XCTAssertTrue(tracker.recordSample(usable: true),
            "reaching \(DisplayStabilityTracker.requiredConsecutiveSamples) consecutive usable samples must declare stable")
    }

    /// Any unusable sample resets the streak immediately — no partial
    /// credit survives a blip going the other way either.
    func testUnusableSampleResetsTheStreakImmediately() {
        var tracker = DisplayStabilityTracker()
        _ = tracker.recordSample(usable: true)
        XCTAssertFalse(tracker.recordSample(usable: false))
        XCTAssertEqual(tracker.consecutiveUsableSamples, 0)
        // Must start counting fully over — one more usable sample alone is
        // still not enough.
        XCTAssertFalse(tracker.recordSample(usable: true))
    }

    /// A blip-then-recovery sequence — exactly wake/lid churn — must not
    /// short-circuit into "stable" by accumulating samples across the gap.
    func testBlipThenRecoveryRequiresAFreshFullStreak() {
        var tracker = DisplayStabilityTracker()
        XCTAssertFalse(tracker.recordSample(usable: true))   // transient positive
        XCTAssertFalse(tracker.recordSample(usable: false))  // settles back to unusable
        for i in 0..<(DisplayStabilityTracker.requiredConsecutiveSamples - 1) {
            XCTAssertFalse(tracker.recordSample(usable: true), "post-blip sample \(i) alone must not be enough")
        }
        XCTAssertTrue(tracker.recordSample(usable: true))
    }
}
