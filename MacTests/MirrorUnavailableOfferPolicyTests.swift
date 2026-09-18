import XCTest

/// Pure-logic tests for the headless-Mirror "Use Extend?" offer
/// (`WireMessage.mirrorUnavailable`, see PROTOCOL.md). `MacSender`'s actual
/// wait/networking glue (`offerExtendOrFailMirror`) isn't in this hostless
/// test target (it pulls in ScreenCaptureKit/AVFoundation) — the physical
/// retest exercises that; these tests cover the decisions `MacSender`
/// delegates to `MirrorUnavailableOfferPolicy`.
final class MirrorUnavailableOfferPolicyTests: XCTestCase {

    func testMirrorUnavailableWireVersionIsFixedAt17() {
        XCTAssertEqual(WireProtocol.mirrorUnavailableWireVersion, 17)
    }

    // See StreamingPriorityTests' matching comment — that canary now points
    // here.
    func testMirrorUnavailableWireVersionIsTheCurrentProtocolVersion() {
        XCTAssertEqual(WireProtocol.mirrorUnavailableWireVersion, WireProtocol.version)
    }

    // MARK: - shouldOffer (headless Mirror -> one offer; old receiver -> clean failure)

    /// Headless (no usable physical display) + a receiver that understands
    /// the offer -> offer instead of failing immediately.
    func testHeadlessWithSupportingReceiverOffers() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: false,
            receiverProtocolVersion: WireProtocol.mirrorUnavailableWireVersion))
    }

    /// A physical display exists — Mirror should just work; never offer
    /// regardless of receiver version.
    func testUsablePhysicalDisplayNeverOffers() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: true,
            receiverProtocolVersion: WireProtocol.mirrorUnavailableWireVersion))
    }

    /// Old receiver -> existing clean Mirror failure behavior: even
    /// headless, a receiver below the wire version this offer introduced
    /// must never be offered one it cannot understand.
    func testOldReceiverNeverOffersEvenWhenHeadless() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: false,
            receiverProtocolVersion: WireProtocol.mirrorUnavailableWireVersion - 1))
    }

    func testHeadlessWithNewerReceiverStillOffers() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: false,
            receiverProtocolVersion: WireProtocol.mirrorUnavailableWireVersion + 1))
    }

    // MARK: - isOfferStillPending (stale generation / timeout / teardown / Cancel/Disconnect)

    /// Exactly one pending offer per authenticated connection generation,
    /// and it is still valid while nothing has superseded it.
    func testFreshOfferOnLiveSessionIsStillPending() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: 5, sessionGeneration: 5, sessionIsLive: true))
    }

    /// Stale generation (session moved on — reconnect, migration, or a
    /// newer session) -> ignored, never resurrected.
    func testStaleGenerationIsNotPending() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: 5, sessionGeneration: 6, sessionIsLive: true))
    }

    /// Session no longer authenticated/live — Cancel (Disconnect), Forget,
    /// or any other session teardown — dismisses the offer.
    func testSessionNoLongerLiveIsNotPending() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: 5, sessionGeneration: 5, sessionIsLive: false))
    }

    /// The offer generation was already cleared (timeout fired, or the
    /// offer was otherwise retired) — a late check must not treat a nil
    /// offer as still pending even if the session itself is still live.
    func testClearedOfferIsNotPendingEvenOnALiveSession() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: nil, sessionGeneration: 5, sessionIsLive: true))
    }

    /// The actual "physical display reappears -> stale offer cannot force
    /// Extend" guard: `MacSender.offerExtendOrFailMirror`'s poll clears
    /// `mirrorUnavailableOfferGeneration` (sets it to `nil`) the moment it
    /// notices a physical display is usable again, BEFORE resuming Mirror
    /// on its own — the Mac decides, not a stale "Use Extend" tap that
    /// might still be in flight. Once cleared, this same generation is no
    /// longer pending for anything that checks afterward (a late poll tick,
    /// or conceptually a late acceptance), exactly like a timeout or
    /// teardown would leave it.
    func testGenerationClearedAfterPhysicalDisplayReturnsIsNoLongerPending() {
        let originalGeneration: UInt64 = 5
        // Mirror the exact sequence `offerExtendOrFailMirror` performs:
        var offerGeneration: UInt64? = originalGeneration
        XCTAssertTrue(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: offerGeneration, sessionGeneration: originalGeneration, sessionIsLive: true))

        // A physical display becomes usable -> the Mac clears the offer
        // itself, rather than waiting for (or trusting) any reply.
        offerGeneration = nil

        XCTAssertFalse(MirrorUnavailableOfferPolicy.isOfferStillPending(
            offerGeneration: offerGeneration, sessionGeneration: originalGeneration, sessionIsLive: true),
            "the original offer generation must not still be considered pending once cleared")
    }

    // MARK: - advertisedProtocolVersion (MacReceiver capability compatibility)

    /// A receiver advertising support for a `pv` MUST actually be able to
    /// handle everything that version implies. MacReceiver has no
    /// display-mode UI at all, so it cannot present the "Use Extend?"
    /// offer — it must cap itself below `mirrorUnavailableWireVersion`
    /// rather than silently receive an offer it can never answer.
    func testMacReceiverCapsBelowMirrorUnavailableVersion() {
        XCTAssertEqual(
            MirrorUnavailableOfferPolicy.advertisedProtocolVersion(
                deviceKind: "Mac", latestVersion: WireProtocol.version),
            WireProtocol.mirrorUnavailableWireVersion - 1)
    }

    /// iOS/iPadOS implement the offer UI — they advertise the full current
    /// version, unaffected by the MacReceiver cap.
    func testIOSReceiverAdvertisesTheFullCurrentVersion() {
        for kind in ["iPhone", "iPad"] {
            XCTAssertEqual(
                MirrorUnavailableOfferPolicy.advertisedProtocolVersion(
                    deviceKind: kind, latestVersion: WireProtocol.version),
                WireProtocol.version)
        }
    }

    /// The cap must never accidentally ADVERTISE a higher version than the
    /// build actually speaks (e.g. if a future refactor lowers
    /// `WireProtocol.version` below the mirrorUnavailable threshold for some
    /// other reason) — `min` keeps this defensively correct either way.
    func testAdvertisedVersionNeverExceedsTheBuildsOwnVersion() {
        let hypotheticalOlderBuildVersion = WireProtocol.mirrorUnavailableWireVersion - 5
        XCTAssertEqual(
            MirrorUnavailableOfferPolicy.advertisedProtocolVersion(
                deviceKind: "Mac", latestVersion: hypotheticalOlderBuildVersion),
            hypotheticalOlderBuildVersion)
    }

    // MARK: - canEnterMirror (Mirror requires a physical display; Extend does not)

    /// Headless Extend -> a request to switch into Mirror must be rejected
    /// — the exact gate `SenderController.requestMode` consults BEFORE ever
    /// assigning `mode` (so `restartAll()`/VD teardown never happens).
    func testHeadlessRejectsEnteringMirror() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: false))
    }

    /// A physical display present -> Mirror is allowed, exactly like today.
    func testPhysicalDisplayPresentAllowsMirror() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: true))
    }

    /// Not a permanent gate: the same stateless check allows Mirror again
    /// the instant a usable physical display returns — nothing "remembers"
    /// that Mirror was once rejected.
    func testAvailabilityReturningReEnablesMirror() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: false))
        XCTAssertTrue(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: true))
    }

    // MARK: - Video Off while headless Extend (SenderController.requestVideoEnabled)
    //
    // `requestVideoEnabled(false)` used to unconditionally set `mode = .mirror`
    // before stopping capture — a second, undiscovered bypass of the same
    // invariant `requestMode` enforces. It now consults this EXACT SAME
    // `canEnterMirror` gate before ever calling `transitionToMirrorAndDisableVideo`;
    // when it would be impossible, it calls `disableVideoKeepingExtend`
    // instead (stops capture, keeps `mode == .extend`, keeps the VD alive).
    // The stateful half of this — the VD actually surviving, and
    // `applyVideoEnabled(true)` -> `restartVideoCapture`'s `.extend` branch
    // actually resuming on it — needs a live `MacSender`/ScreenCaptureKit
    // session and is out of reach of this hostless test target; the
    // physical retest is authoritative for that half.

    /// Video Off while headless Extend must not attempt to become Mirror —
    /// `requestVideoEnabled` must route through `disableVideoKeepingExtend`,
    /// never `transitionToMirrorAndDisableVideo`, whenever this is false.
    func testHeadlessExtendVideoOffMustNotEnterMirror() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: false))
    }

    /// With a physical display present, the existing Extend -> Mirror ->
    /// Video Off behavior remains available (unchanged) —
    /// `requestVideoEnabled` only diverts to the headless-safe path when
    /// Mirror is genuinely impossible.
    func testPhysicalDisplayPresentAllowsTheExistingVideoOffMirrorTransition() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: true))
    }
}
