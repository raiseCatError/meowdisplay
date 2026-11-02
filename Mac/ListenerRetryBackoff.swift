import Foundation

/// How long to wait before rebuilding a listener that failed (the Remote connect-request listener
/// on 9003). A port another process holds stays held, so retrying every second forever only burns
/// wakeups and fills the log: the delay doubles up to a minute and resets once the listener is up.
struct ListenerRetryBackoff: Equatable {
    static let initial: TimeInterval = 1
    static let maximum: TimeInterval = 60

    private(set) var failures = 0

    /// The delay before the next attempt; counts a failure.
    mutating func nextDelay() -> TimeInterval {
        let delay = min(Self.initial * pow(2, Double(min(failures, 16))), Self.maximum)
        failures += 1
        return delay
    }

    /// Log the failure only on the first few and then once per ten, not every retry.
    var shouldLog: Bool { failures <= 3 || failures % 10 == 0 }

    mutating func ready() { failures = 0 }
}
