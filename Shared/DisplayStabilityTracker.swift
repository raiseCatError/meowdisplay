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

/// A capture start that finds no display right after a sleep or a network
/// wake (#255): the display is usually asleep or still coming up, not gone.
/// Asks once for it to be woken, then polls a bounded number of times.
/// Pure sequencing — the caller supplies the wake call, the probe and the
/// pause — so the order and the bounds are testable without ScreenCaptureKit.
enum DisplayReadinessWait {
    /// How many polls fit in `grace` at `interval` (at least one).
    static func polls(grace: TimeInterval, interval: TimeInterval) -> Int {
        guard interval > 0 else { return 1 }
        return max(1, Int((grace / interval).rounded(.down)))
    }

    /// The first value `probe` yields. A value already there is returned at
    /// once, with no wake and no pause. Otherwise `wake` runs exactly once
    /// and `probe` is retried after each `pause`, at most `polls` times; nil
    /// when it never yields one. Throws `CancellationError` as soon as
    /// `stillWanted` turns false (session ended, sender stopped), so a wait
    /// never outlives the session it was started for.
    static func firstAvailable<Value>(
        polls: Int,
        wake: () -> Void,
        probe: () async -> Value?,
        pause: () async throws -> Void,
        stillWanted: () -> Bool
    ) async throws -> Value? {
        guard stillWanted() else { throw CancellationError() }
        if let value = await probe() { return value }
        wake()
        for _ in 0..<max(polls, 0) {
            try await pause()
            guard stillWanted() else { throw CancellationError() }
            if let value = await probe() { return value }
        }
        return nil
    }
}
