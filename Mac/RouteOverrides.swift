#if DEBUG
import Foundation
import Combine

/// Session-only route-testing switches for Settings → Developer / Diagnostics
/// → Route Overrides. Exists only in DEBUG builds and never touches trust,
/// pairing, or persisted endpoint data — it only excludes a route from
/// candidate selection and reconnect/migration for the life of this process.
/// Resets to all-enabled on every launch, matching the "session-only" and
/// "no persistence" requirements: nothing here is written to UserDefaults.
@MainActor
final class RouteOverrides: ObservableObject {
    static let shared = RouteOverrides()

    @Published var usbEnabled = true { didSet { announceAndEnforce() } }
    @Published var lanEnabled = true { didSet { announceAndEnforce() } }
    @Published var awdlEnabled = true { didSet { announceAndEnforce() } }
    @Published var remoteEnabled = true { didSet { announceAndEnforce() } }

    /// Set by `SenderController` at startup. Called after every toggle so a
    /// route disabled mid-session is enforced immediately, not just against
    /// future candidates — see the "true hard gate" requirement.
    var onChange: (() -> Void)?

    private init() {}

    /// The single authoritative admission check. Every dial site — auto-
    /// connect, explicit user connect, pairing, cable upgrade, and WiFi
    /// failover — must call this immediately before starting a connection,
    /// not rely on a value cached when a candidate was first built.
    func isAllowed(_ route: ConnectionRoute) -> Bool {
        switch route {
        case .usb: return usbEnabled
        case .lan: return lanEnabled
        case .awdl: return awdlEnabled
        case .remote: return remoteEnabled
        }
    }

    func reset() {
        usbEnabled = true
        lanEnabled = true
        awdlEnabled = true
        remoteEnabled = true
    }

    func forceRemoteOnly() {
        usbEnabled = false
        lanEnabled = false
        awdlEnabled = false
        remoteEnabled = true
    }

    private func announceAndEnforce() {
        Log.info("routeDebug: overrides USB=\(usbEnabled) LAN=\(lanEnabled) AWDL=\(awdlEnabled) Remote=\(remoteEnabled)")
        onChange?()
    }
}
#endif
