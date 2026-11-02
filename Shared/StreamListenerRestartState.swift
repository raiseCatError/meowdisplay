import Foundation

/// Small, pure state machine for `StreamReceiver` listener restarts.
///
/// Adapted from the listener lifecycle fix in nmt3325/openairdisplay
/// (GPL-3.0). Keeping the timing and generation bookkeeping outside
/// Network.framework makes the race handling deterministic and unit-testable
/// without introducing a listener manager.
struct StreamListenerRestartState {
    struct ScheduledRestart: Equatable {
        let generation: Int
        let delay: TimeInterval
    }

    private(set) var listenerStarting = false
    private(set) var restartPending = false
    private(set) var listenerGeneration = 0
    private(set) var restartBackoff: TimeInterval = 0.5

    var shouldDeferEnsureListening: Bool {
        listenerStarting || restartPending
    }

    mutating func beginStarting() -> Bool {
        guard !listenerStarting, !restartPending else { return false }
        listenerStarting = true
        return true
    }

    mutating func listenerReady() {
        listenerStarting = false
        restartBackoff = 0.5
    }

    mutating func listenerStopped() {
        listenerStarting = false
    }

    mutating func scheduleRestart(after requestedDelay: TimeInterval = 0) -> ScheduledRestart? {
        guard !restartPending else { return nil }
        restartPending = true
        listenerStarting = false
        listenerGeneration &+= 1
        return ScheduledRestart(
            generation: listenerGeneration,
            delay: max(requestedDelay, 0.35))
    }

    mutating func scheduleRetry() -> ScheduledRestart? {
        guard !restartPending else { return nil }
        let delay = restartBackoff
        restartBackoff = min(restartBackoff * 2, 8.0)
        return scheduleRestart(after: delay)
    }

    mutating func consume(_ restart: ScheduledRestart) -> Bool {
        guard restartPending, restart.generation == listenerGeneration else { return false }
        restartPending = false
        return true
    }

    mutating func invalidate() {
        listenerGeneration &+= 1
        listenerStarting = false
        restartPending = false
        restartBackoff = 0.5
    }
}
