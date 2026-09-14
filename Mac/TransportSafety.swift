import Foundation

/// Pure helpers backing the M2 transport-safety audit fixes. Kept free of
/// Network.framework types so they can be unit tested without a mock
/// NWPath/NWConnection layer.
enum TransportSafety {
    /// Clamped decrement for the in-flight send counter (`pendingSends`).
    ///
    /// A route change (`switchTransport`/`scheduleReconnect`) resets the
    /// counter to zero before redialing, but an `NWConnection.send`
    /// completion for a frame issued on the superseded connection can still
    /// be dispatched onto the same serial queue afterward — and it still
    /// decrements. Clamp at zero instead of letting a late completion drive
    /// the counter negative.
    static func decrementedPendingCount(_ count: Int) -> Int {
        Swift.max(0, count - 1)
    }

    /// Whether a connection's current path should be classified as a
    /// wired/cable direct link.
    ///
    /// The historical check was "not WiFi, not loopback, not cellular" —
    /// wired by exclusion. AWDL interfaces (`awdl0`) do not report as
    /// `NWInterface.InterfaceType.wifi` on macOS, so that exclusion alone
    /// would fold a future AWDL-carried path into "cable" classification and
    /// its unplug-ends-session semantics (see `MacSender.linkDied`), which is
    /// wrong for a radio hop. There is no public `NWInterface.InterfaceType`
    /// case for AWDL, so it is excluded by interface name instead — the same
    /// `awdl*` prefix test already used in
    /// `MacSender.candidateInterfaceNames` and
    /// `StreamReceiver.reachableAddresses`.
    static func isWiredDirectLinkPath(
        usesWiFi: Bool,
        usesLoopback: Bool,
        usesCellular: Bool,
        interfaceNames: [String]
    ) -> Bool {
        guard !usesWiFi, !usesLoopback, !usesCellular else { return false }
        return !interfaceNames.contains { $0.hasPrefix("awdl") }
    }
}
