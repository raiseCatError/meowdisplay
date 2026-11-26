import XCTest

final class RouteArbitrationTests: XCTestCase {
    func testRoutePriorityOrdering() {
        XCTAssertEqual(RoutePriority.tier(.usb), 0)
        XCTAssertEqual(RoutePriority.tier(.lan), 1)
        XCTAssertEqual(RoutePriority.tier(.awdl), 1)
        XCTAssertEqual(RoutePriority.tier(.remote), 2)
    }

    func testNoExistingOwnerProceeds() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: nil, targetTier: RoutePriority.tier(.lan)),
            .proceed)
    }

    /// Remote active + LAN request -> controlled one-way local upgrade, no
    /// second owner: LAN is strictly better than Remote, so this migrates
    /// the existing session in place rather than creating a competitor.
    func testRemoteOwnerWithLANRequestMigrates() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.remote),
                                    targetTier: RoutePriority.tier(.lan)),
            .migrate)
    }

    /// LAN active + Remote request -> Remote ignored: Remote is strictly
    /// worse than the existing LAN owner.
    func testLANOwnerWithRemoteRequestIsIgnored() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.lan),
                                    targetTier: RoutePriority.tier(.remote)),
            .ignore)
    }

    /// USB active + LAN/Remote request -> ignored: USB is the top tier, so
    /// nothing beats it automatically.
    func testUSBOwnerIgnoresLANAndRemoteRequests() {
        for worseTier in [RoutePriority.tier(.lan), RoutePriority.tier(.remote)] {
            XCTAssertEqual(
                RouteArbitration.decide(ownerTier: RoutePriority.tier(.usb), targetTier: worseTier),
                .ignore)
        }
    }

    /// LAN and AWDL share a tier — neither may bounce to the other, even
    /// though they're nominally "different" routes.
    func testLANAndAWDLDoNotBounceBetweenEachOther() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.lan),
                                    targetTier: RoutePriority.tier(.awdl)),
            .ignore)
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.awdl),
                                    targetTier: RoutePriority.tier(.lan)),
            .ignore)
    }

    /// A stale/retired route's own redial firing after another (equal or
    /// better) route already won must be rejected, not resurrect a second
    /// owner — same shape as the automatic same-tier case above.
    func testRetiredRouteRetryIsRejected() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.lan),
                                    targetTier: RoutePriority.tier(.lan)),
            .ignore)
    }

    /// A single iOS Connect/Wake & Connect action fans out into BOTH a local
    /// Bonjour connect request and a Remote connect request when Remote is
    /// configured — so an equal/worse-route request is never a "user
    /// override" here, even when it happens to be user-initiated. There is
    /// no `.replace` case: RouteArbitration has no notion of "user
    /// insisted on this transport," only "the peer should be connected."
    func testEqualOrWorseRouteIsAlwaysIgnoredRegardlessOfWhoAskedForIt() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.usb),
                                    targetTier: RoutePriority.tier(.lan)),
            .ignore)
    }

    /// A better route is a migration even for the most aggressive case: a
    /// user-initiated request that also happens to be the top tier.
    func testBetterRouteMigrates() {
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: RoutePriority.tier(.remote),
                                    targetTier: RoutePriority.tier(.usb)),
            .migrate)
    }

    /// The exact race described in the field report: a single Connect
    /// action fires both a local and a Remote request.
    ///   1. Remote owns the peer.
    ///   2. LAN arrives first -> migrates (LAN is strictly better).
    ///   3. The delayed Remote request for the SAME peer arrives after —
    ///      by then the owner is LAN, and Remote is a worse tier -> ignored.
    ///   4. LAN remains the sole owner.
    /// Modeled as two sequential `decide` calls against the owner tier that
    /// results from step 2, since `RouteArbitration` itself is a pure,
    /// stateless per-attempt decision — `SenderController.owningSession`
    /// is what supplies the "current owner" tier fed into the second call.
    func testDelayedRemoteRequestAfterLANMigrationIsIgnored() {
        let remoteOwnerTier = RoutePriority.tier(.remote)
        let lanRequestTier = RoutePriority.tier(.lan)
        XCTAssertEqual(RouteArbitration.decide(ownerTier: remoteOwnerTier, targetTier: lanRequestTier),
                       .migrate, "LAN must migrate in over the existing Remote owner")

        // The owner is now LAN (post-migration) when the delayed Remote
        // request from the same original Connect action finally arrives.
        let lanOwnerTierAfterMigration = lanRequestTier
        let delayedRemoteRequestTier = RoutePriority.tier(.remote)
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: lanOwnerTierAfterMigration, targetTier: delayedRemoteRequestTier),
            .ignore, "the delayed Remote request must not replace or bounce the new LAN owner")
    }

    /// Inverse arrival order of the same race: LAN wins first (no owner yet
    /// when it arrives), and the delayed Remote request that follows is
    /// ignored rather than replacing the already-connected LAN session.
    func testDelayedRemoteRequestAfterLANWinsFirstIsIgnored() {
        XCTAssertEqual(RouteArbitration.decide(ownerTier: nil, targetTier: RoutePriority.tier(.lan)),
                       .proceed, "LAN arriving with no existing owner proceeds normally")

        let lanOwnerTier = RoutePriority.tier(.lan)
        let delayedRemoteRequestTier = RoutePriority.tier(.remote)
        XCTAssertEqual(
            RouteArbitration.decide(ownerTier: lanOwnerTier, targetTier: delayedRemoteRequestTier),
            .ignore, "the delayed Remote request must not replace the LAN session that already won")
    }
}
