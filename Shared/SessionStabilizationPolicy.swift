import Foundation

/// Decides whether an authenticated MEOW application session should
/// (re-)arm the shared `WakeStabilizationAssertion`. Pure logic, same style
/// as `RemoteConnectRequestPolicy` — no networking, no IOKit.
///
/// This never grants trust: `shouldArm` is only ever consulted after a
/// connection has already completed pinned mutual-TLS AND the MEOW
/// application handshake (`AuthenticatedSessionState.markApplicationReady`)
/// in `MacSender`, so arming here is always downstream of an authenticated
/// peer, never a substitute for one. Applies uniformly to every route
/// (USB/LAN/AWDL/Remote) — the video/graphics pipeline needs the same
/// runway to come alive regardless of which transport carried the
/// handshake.
enum SessionStabilizationPolicy {
    /// `previouslyArmedGeneration` is the connection generation the
    /// assertion was last armed for (nil if never armed this launch). Arms
    /// once per connection generation; a same-peer transport migration gets
    /// a new generation (see `MacSender.switchTransport`) so this naturally
    /// extends/resets the window rather than requiring a separate signal.
    static func shouldArm(
        previouslyArmedGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        previouslyArmedGeneration != currentGeneration
    }
}
