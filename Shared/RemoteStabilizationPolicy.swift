import Foundation

/// Decides whether an authenticated connection's route classification
/// should (re-)arm the shared `WakeStabilizationAssertion`. Pure logic, same
/// style as `RemoteConnectRequestPolicy` — no networking, no IOKit.
///
/// This never grants trust: it only runs against a `ConnectionRoute` label
/// computed after the connection is already `connectionReady` (past pinned
/// mutual-TLS verification in `MacSender`), so arming here is always
/// downstream of an authenticated peer, never a substitute for one.
enum RemoteStabilizationPolicy {
    /// `previouslyArmedGeneration` is the connection generation the
    /// assertion was last armed for (nil if never armed this launch).
    /// Arms once per connection generation, and only for the Remote route —
    /// LAN/USB/AWDL sessions have no dark-wake gap to bridge.
    static func shouldArm(
        route: ConnectionRoute,
        previouslyArmedGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        route == .remote && previouslyArmedGeneration != currentGeneration
    }
}
