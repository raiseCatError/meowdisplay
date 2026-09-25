import Foundation

/// The coarse, user-facing connection health for one or more active
/// displays — distinct from `CaptureLifecyclePhase` (the lower-level
/// capture-pipeline state it's derived from) in that this is what every
/// status-bearing surface (toolbar, menu bar, Overview) actually renders.
enum CanonicalConnectionPhase: Equatable {
    case idle
    case connected
    /// Authenticated, but the session invitation is not yet admitted
    /// (either side's user may still be deciding). Never "connected".
    case awaitingApproval
    case paused
    case reconnecting
    case lost
}

/// Pure text projection of the canonical runtime state — the same values
/// `SenderController.activeDisplayEntries`/`canonicalStatusText` compute
/// from live sessions, factored out so the mapping (mode/route → headline,
/// authenticated-session count → status text) is unit-testable without the
/// full app (ScreenCaptureKit/Network/AppKit all live one layer up, in
/// `SenderController`/`MacSender`). Every status-bearing surface — Overview,
/// Devices → Active Display, the toolbar, the menu bar — must read from
/// values built through these functions, never re-derive its own.
enum CanonicalRuntimeStatus {
    /// "Mirroring · LAN" / "Extending · Remote" / "Extending" when the route
    /// isn't known yet (still dialing).
    static func headline(mode: CaptureMode, route: ConnectionRoute?) -> String {
        headline(verb: mode == .mirror
                 ? String(localized: "Mirroring", comment: "Status: showing a copy of a Mac display on the device.")
                 : String(localized: "Extending", comment: "Status: the device is acting as an extra Mac display."),
                 route: route)
    }

    /// The general "<verb> · <route>" shape `headline(mode:route:)` builds
    /// for the healthy case, generalized so a phase (e.g. "Paused") can
    /// reuse the exact same route formatting instead of a second literal.
    static func headline(verb: String, route: ConnectionRoute?) -> String {
        route.map { "\(verb) · \($0.rawValue)" } ?? verb
    }

    /// "Idle" while no session has completed the application handshake,
    /// otherwise "N device(s) connected" — gated on the count of
    /// *authenticated* sessions, never on "any session exists" (a dialing,
    /// pre-hello session is not yet a connected device — this is the
    /// canonical fix for the false-Idle / false-"N connected" class of bug).
    static func statusText(activeDisplayCount: Int) -> String {
        guard activeDisplayCount > 0 else { return String(localized: "Idle") }
        // Singular keeps its own key so English output never depends on the
        // plural variant being loaded (the hostless test bundle has no catalog);
        // translators can still vary the counted form by plural category.
        if activeDisplayCount == 1 { return String(localized: "1 device connected") }
        return String(localized: "\(activeDisplayCount) devices connected",
                      comment: "Toolbar status; the count is always 2 or more.")
    }

    /// Maps one session's *existing* capture-lifecycle/failed state (see
    /// `DeviceSession.capturePhase`/`.failed`) onto the coarse phase every
    /// status surface renders — no new session-lifecycle concept, just
    /// naming what's already tracked so the toolbar stops reading
    /// authenticated-count alone (which can't distinguish a healthy session
    /// from one that's mid-recovery or has failed outright).
    static func phase(capturePhase: CaptureLifecyclePhase, failed: Bool,
                      awaitingApproval: Bool = false) -> CanonicalConnectionPhase {
        if failed { return .lost }
        if awaitingApproval { return .awaitingApproval }
        switch capturePhase {
        case .recovering: return .reconnecting
        case .paused, .pausing: return .paused
        case .stopped: return .lost
        case .running, .resuming: return .connected
        }
    }

    /// The aggregate phase across every active display, prioritizing the
    /// least-healthy entry so one struggling session is never hidden behind
    /// others that are fine.
    static func aggregatePhase(entryPhases: [CanonicalConnectionPhase]) -> CanonicalConnectionPhase {
        guard !entryPhases.isEmpty else { return .idle }
        if entryPhases.contains(.lost) { return .lost }
        if entryPhases.contains(.reconnecting) { return .reconnecting }
        if entryPhases.contains(.awaitingApproval) { return .awaitingApproval }
        if entryPhases.allSatisfy({ $0 == .paused }) { return .paused }
        return .connected
    }

    /// One entry's toolbar-style text: healthy shows the usual mode/route
    /// headline, every other phase names itself explicitly rather than
    /// showing a stale "connected"-shaped string.
    static func entryStatusText(mode: CaptureMode, route: ConnectionRoute?,
                                 phase: CanonicalConnectionPhase) -> String {
        switch phase {
        case .connected: return headline(mode: mode, route: route)
        case .paused: return headline(verb: String(localized: "Paused"), route: route)
        case .reconnecting: return String(localized: "Reconnecting…")
        case .awaitingApproval: return String(localized: "Waiting for approval…")
        case .lost: return String(localized: "Connection Lost")
        case .idle: return String(localized: "Idle")
        }
    }

    /// The single toolbar/menu-bar pill string across every active display:
    /// one entry shows its own headline/phase text; several collapse to the
    /// aggregate phase (an unhealthy one still wins over a healthy count).
    static func aggregateStatusText(
        entries: [(mode: CaptureMode, route: ConnectionRoute?, phase: CanonicalConnectionPhase)]
    ) -> String {
        guard !entries.isEmpty else { return String(localized: "Idle") }
        if entries.count == 1, let only = entries.first {
            return entryStatusText(mode: only.mode, route: only.route, phase: only.phase)
        }
        switch aggregatePhase(entryPhases: entries.map(\.phase)) {
        case .lost: return String(localized: "Connection Lost")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .awaitingApproval: return String(localized: "Waiting for approval…")
        case .paused: return String(localized: "\(entries.count) devices paused",
                                                  comment: "Toolbar status; the count is always 2 or more.")
        case .connected, .idle: return statusText(activeDisplayCount: entries.count)
        }
    }
}
