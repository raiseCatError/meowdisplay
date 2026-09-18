import Foundation

/// Tracks consecutive "physical display usable" poll samples so a
/// transient blip during wake/lid/topology churn cannot prematurely cancel
/// a pending Mirror-unavailable offer and resume Mirror against a display
/// that isn't actually stably back. Pure counter, fed one sample per poll
/// tick — kept separate from `MacSender`'s networking/wait glue so the
/// debounce itself is unit-testable.
struct DisplayStabilityTracker: Equatable {
    private(set) var consecutiveUsableSamples = 0

    /// Consecutive usable samples required before treating the display as
    /// stably back. At the existing ~500ms poll cadence this covers
    /// "roughly 1 second" per the product requirement.
    static let requiredConsecutiveSamples = 2

    /// Feeds one sample; returns whether the display should now be treated
    /// as stably usable. Any unusable sample resets the streak immediately
    /// — there is no partial credit across a blip.
    mutating func recordSample(usable: Bool) -> Bool {
        consecutiveUsableSamples = usable ? consecutiveUsableSamples + 1 : 0
        return consecutiveUsableSamples >= Self.requiredConsecutiveSamples
    }
}
