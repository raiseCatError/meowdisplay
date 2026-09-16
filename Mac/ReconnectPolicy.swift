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
}
