import Foundation

/// Whether `MacSender`'s own in-place retry loop (`scheduleReconnect`) may
/// run another automatic attempt, or must give up and end the session
/// instead. Applies only to automatic calls — an explicit Connect/Reconnect
/// (`forceReconnect`, `scheduleReconnect(automatic: false)`) always bypasses
/// this and proceeds regardless of `autoReconnectEnabled`.
///
/// A session that has never connected yet keeps retrying regardless of the
/// preference: its first connection was already gated at creation (either an
/// explicit user action, or `SenderController.autoConnect()`'s own
/// `AutoConnectPolicy` check before the session was ever created), so a
/// struggling *initial* dial — including one behind Wake & Connect, which
/// depends on redialing while the Mac wakes — is part of that same attempt,
/// not background Auto-Reconnect. Only a loss *after* a session has proven
/// itself is "ordinary transport loss" in the Auto-Reconnect sense.
enum ReconnectPolicy {
    static func automaticRetryAllowed(autoReconnectEnabled: Bool, everConnected: Bool) -> Bool {
        !everConnected || autoReconnectEnabled
    }

    /// The longest wait between redials of a session that has never connected.
    static let maxRetryDelay: TimeInterval = 10

    /// How long to wait before redial number `attempt` (1 for the first since the
    /// transport was last up). A session that was connected redials every second: it
    /// is inside its short disconnect grace, where every second of picture counts. One
    /// that has never connected (a device asleep, out of range, or a Mac still waking)
    /// can retry for a long time, so it backs off, 1, 2, 4, 8 and then every 10
    /// seconds, instead of dialing every second forever.
    static func retryDelay(attempt: Int, everConnected: Bool) -> TimeInterval {
        guard !everConnected, attempt > 1 else { return 1 }
        let doubled = pow(2, Double(min(attempt - 1, 10)))
        return min(doubled, maxRetryDelay)
    }
}
