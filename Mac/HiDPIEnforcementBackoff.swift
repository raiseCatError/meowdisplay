import Foundation

/// Bounds how hard the HiDPI enforcement loop pushes WindowServer. macOS can
/// publish an @2x mode yet persistently refuse to switch to it; without a
/// limit the loop issues a failed permanent reconfiguration every tick.
struct HiDPIEnforcementBackoff {
    static let failureThreshold = 5
    static let probeInterval: TimeInterval = 30

    private(set) var consecutiveFailures = 0
    private var retryAfter: Date?

    var isBackingOff: Bool { retryAfter != nil }

    /// False while inside the backoff window.
    func shouldAttempt(at now: Date) -> Bool {
        guard let retryAfter else { return true }
        return now >= retryAfter
    }

    /// Returns true exactly when this failure starts (or renews) a backoff,
    /// so the caller can log one summary instead of one line per failure.
    mutating func recordFailure(at now: Date) -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failureThreshold else { return false }
        let firstBackoff = retryAfter == nil
        retryAfter = now.addingTimeInterval(Self.probeInterval)
        return firstBackoff
    }

    /// Success, resize, or any mode change: the next mode gets a fresh chance.
    mutating func reset() {
        consecutiveFailures = 0
        retryAfter = nil
    }
}
