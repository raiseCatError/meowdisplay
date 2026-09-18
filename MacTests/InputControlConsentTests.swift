import XCTest

final class InputControlConsentTests: XCTestCase {
    // MARK: - EffectiveInputAuthorization

    func testEffectiveInputRequiresBothMasterAndSessionGrant() {
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: false, sessionGranted: false))
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: false, sessionGranted: true))
        XCTAssertFalse(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: false))
        XCTAssertTrue(EffectiveInputAuthorization.allowed(masterEnabled: true, sessionGranted: true))
    }

    // MARK: - SessionInputGrantBox

    func testSessionInputGrantBoxDefaultsToFalse() {
        XCTAssertFalse(SessionInputGrantBox().get())
    }

    func testSessionInputGrantBoxTracksLastWrite() {
        let box = SessionInputGrantBox()
        box.set(true)
        XCTAssertTrue(box.get())
        box.set(false)
        XCTAssertFalse(box.get())
    }

    func testTwoSessionInputGrantBoxesAreIndependent() {
        // Simulates "iPhone A granted, iPhone B must not gain input" at the
        // exact primitive both sessions' gates read from.
        let sessionA = SessionInputGrantBox()
        let sessionB = SessionInputGrantBox()
        sessionA.set(true)
        XCTAssertTrue(sessionA.get())
        XCTAssertFalse(sessionB.get())
    }

    // MARK: - InputControlRequestLifecycle

    func testFirstRequestBeginsPendingAtGenerationOne() {
        var lifecycle = InputControlRequestLifecycle()
        XCTAssertEqual(lifecycle.beginRequest(now: Date()), 1)
        XCTAssertTrue(lifecycle.isPending)
    }

    func testDuplicateRequestWhilePendingCoalescesIntoOnePrompt() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        XCTAssertNotNil(lifecycle.beginRequest(now: now))
        XCTAssertNil(lifecycle.beginRequest(now: now), "a second packet while one prompt is pending must not raise a second prompt")
    }

    func testResolvingTheCurrentGenerationSucceeds() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let generation = lifecycle.beginRequest(now: now)!
        XCTAssertTrue(lifecycle.resolve(generation: generation, decision: .allowSession, now: now))
        XCTAssertFalse(lifecycle.isPending)
    }

    func testResolvingAStaleGenerationIsIgnored() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let firstGeneration = lifecycle.beginRequest(now: now)!
        // The first request times out (surfaced as .notNow by the
        // presenting model), a new one begins (new generation)...
        XCTAssertTrue(lifecycle.resolve(generation: firstGeneration, decision: .notNow, now: now))
        let secondGeneration = lifecycle.beginRequest(now: now.addingTimeInterval(InputControlRequestLifecycle.cooldown + 1))!
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        // ...and a late decision for the FIRST (superseded) generation must
        // never be able to resolve/grant the newer, still-pending request.
        XCTAssertFalse(lifecycle.resolve(generation: firstGeneration, decision: .allowSession, now: now))
        XCTAssertTrue(lifecycle.isPending, "the newer request must remain pending, untouched by the stale decision")
    }

    func testNotNowStartsACooldownThatSuppressesTheNextRequest() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let generation = lifecycle.beginRequest(now: now)!
        lifecycle.resolve(generation: generation, decision: .notNow, now: now)

        XCTAssertNil(lifecycle.beginRequest(now: now.addingTimeInterval(1)), "an immediate re-request during cooldown must be suppressed")
    }

    func testRequestAfterCooldownExpiresIsAllowed() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let generation = lifecycle.beginRequest(now: now)!
        lifecycle.resolve(generation: generation, decision: .notNow, now: now)

        XCTAssertNotNil(lifecycle.beginRequest(now: now.addingTimeInterval(InputControlRequestLifecycle.cooldown + 1)))
    }

    func testTimeoutSurfacedAsNotNowLeavesTheRequestUnresolvedAndStartsCooldown() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let generation = lifecycle.beginRequest(now: now)!
        XCTAssertTrue(lifecycle.resolve(generation: generation, decision: .notNow, now: now))
        XCTAssertFalse(lifecycle.isPending)
        XCTAssertNil(lifecycle.beginRequest(now: now.addingTimeInterval(1)), "a timed-out request must still cool down like Not Now")
    }

    func testResetClearsPendingAndCooldownForATrueSessionEnd() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let generation = lifecycle.beginRequest(now: now)!
        lifecycle.resolve(generation: generation, decision: .notNow, now: now)
        lifecycle.reset()

        XCTAssertNotNil(lifecycle.beginRequest(now: now), "reset must clear the cooldown too, since a fresh session starts clean")
    }

    func testStaleDecisionAfterResetCannotResolveTheFreshLifecycle() {
        var lifecycle = InputControlRequestLifecycle()
        let now = Date()
        let staleGeneration = lifecycle.beginRequest(now: now)!
        lifecycle.reset()
        let freshGeneration = lifecycle.beginRequest(now: now)!

        XCTAssertFalse(lifecycle.resolve(generation: staleGeneration, decision: .allowSession, now: now))
        XCTAssertNotEqual(staleGeneration, freshGeneration)
        XCTAssertTrue(lifecycle.isPending)
    }

    // MARK: - InputControlRequestPlan (persist-before-grant ordering)

    // Regression coverage for a real bug: applying `.alwaysAllowDevice` by
    // granting the session first, then persisting `.alwaysAllow`, let the
    // just-created session grant itself satisfy the store's own
    // self-authorization guard (`anySessionHasEffectiveInput`), silently
    // downgrading "Always Allow This Device" into "Allow for This Session"
    // every single time. These tests pin the plan's *contents* — the call
    // site (`SenderController.resolveInputControlRequest`) must apply
    // `persistPolicy` before `grantSession`, which is exercised by
    // `ReceiverInputAuthorizationStoreTests`'s guard tests below.

    func testAllowSessionPlanGrantsWithoutPersistingAnything() {
        let plan = InputControlRequestPlan.plan(for: .allowSession)
        XCTAssertNil(plan.persistPolicy, "Allow for This Session must never touch persistent policy")
        XCTAssertTrue(plan.grantSession)
        XCTAssertNil(plan.denyState)
    }

    func testNeverAllowRequestsPlanPersistsNarrowingAndDenies() {
        let plan = InputControlRequestPlan.plan(for: .neverAllowRequests)
        XCTAssertEqual(plan.persistPolicy, .neverAllow)
        XCTAssertFalse(plan.grantSession)
        XCTAssertEqual(plan.denyState, .requestsDisabled)
    }

    func testNotNowPlanDeniesWithoutPersistingAnything() {
        let plan = InputControlRequestPlan.plan(for: .notNow)
        XCTAssertNil(plan.persistPolicy)
        XCTAssertFalse(plan.grantSession)
        XCTAssertEqual(plan.denyState, .notAllowed)
    }

    func testAlwaysAllowDevicePlanBothPersistsAndGrants() {
        let plan = InputControlRequestPlan.plan(for: .alwaysAllowDevice)
        XCTAssertEqual(plan.persistPolicy, .alwaysAllow, "the caller must persist this BEFORE granting the session")
        XCTAssertTrue(plan.grantSession)
        XCTAssertNil(plan.denyState)
    }
}
