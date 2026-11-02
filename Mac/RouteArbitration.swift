import Foundation

/// USB > LAN/AWDL > Remote. LAN and AWDL share a tier — they must never
/// bounce between each other — and only a strictly lower tier counts as
/// "genuinely better" for `RouteArbitration`'s auto-migration path.
enum RoutePriority {
    static func tier(_ route: ConnectionRoute) -> Int {
        switch route {
        case .usb: return 0
        case .lan, .awdl: return 1
        case .remote: return 2
        }
    }
}

/// The single source of truth for what should happen when a connection
/// attempt targets a peer that may already have a live session on another
/// route. One logical peer must own exactly one long-lived session —
/// this is the pure decision `SenderController.startSession` acts on, kept
/// separate so a route-thrash regression can be caught without instantiating
/// networking/UI state.
///
/// There is deliberately no "user override replaces an equal/worse route"
/// case: a single iOS Connect/Wake & Connect action fans out into BOTH a
/// local Bonjour connect request and a Remote connect request when Remote is
/// configured, so both arrive at the Mac as user-initiated attempts for the
/// same peer. Letting `userInitiated` force a replace re-created the exact
/// thrash this type exists to prevent (Remote wins -> LAN migrates in ->
/// the delayed Remote request replaces LAN again). `userInitiated` means
/// "the user wants this DEVICE connected," not "the user insists on this
/// particular route" — a real "force this exact transport" action, if one is
/// ever needed, is a separate, explicit feature this type does not provide.
enum RouteArbitrationDecision: Equatable {
    /// No existing owner — proceed to create a new session normally.
    case proceed
    /// A strictly better route appeared for the peer an existing session
    /// already owns — migrate that session's transport in place rather than
    /// creating a second one.
    case migrate
    /// The existing owner is on an equal or better route — leave both
    /// alone. Covers a stale/retired route's own redial firing after
    /// another route already won, LAN<->AWDL bouncing (same tier), and a
    /// second user-initiated request (e.g. Remote, fired alongside a local
    /// Connect request that already won) arriving after migration.
    case ignore
}

enum RouteArbitration {
    static func decide(ownerTier: Int?, targetTier: Int) -> RouteArbitrationDecision {
        guard let ownerTier else { return .proceed }
        return targetTier < ownerTier ? .migrate : .ignore
    }
}
