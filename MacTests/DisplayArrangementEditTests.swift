import CoreGraphics
import Foundation
import XCTest

/// Pure-logic coverage for display arrangement editing (Shared/DisplayArrangementEdit.swift):
/// snapping, validation, normalization to the main display, the Mac-side request check and the
/// wire messages.
final class DisplayArrangementEditTests: XCTestCase {
    private typealias Edit = DisplayArrangementEdit

    private func display(_ id: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1000, _ h: CGFloat = 600,
                         main: Bool = false, own: Bool = false, meow: Bool = false,
                         mirrorOf: UInt32? = nil) -> OverviewDisplay {
        OverviewDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h), isMain: main,
                        isMeow: meow, isOwn: own, mirrorOf: mirrorOf)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Main display 1 at 0,0 and display 2 to its right, both 1000x600.
    private var pair: Edit { Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0)]) }

    // MARK: Unchanged and simple moves

    func testAnUnchangedEditIsValidAndSendsNothing() {
        let edit = pair
        XCTAssertNil(edit.validate())
        XCTAssertTrue(edit.changedOrigins.isEmpty)
        XCTAssertFalse(edit.isChanged)
    }

    func testMovingADisplayBesideAnotherIsValidAndReportsOnlyThatDisplay() {
        var edit = pair
        XCTAssertTrue(edit.move(2, to: point(-1000, 0), snapDistance: 0))
        XCTAssertNil(edit.validate())
        XCTAssertEqual(edit.changedOrigins, [2: point(-1000, 0)])
        XCTAssertTrue(edit.isChanged)
    }

    func testResetPutsEveryDisplayBack() {
        var edit = pair
        edit.move(2, to: point(-1000, 0), snapDistance: 0)
        edit.reset()
        XCTAssertEqual(edit.displays, edit.original)
        XCTAssertFalse(edit.isChanged)
    }

    func testMovingAnUnknownDisplayDoesNothing() {
        var edit = pair
        XCTAssertFalse(edit.move(9, to: point(0, 600)))
        XCTAssertEqual(edit.displays, edit.original)
    }

    // MARK: Snapping

    func testADisplayDroppedNearAnEdgeSnapsToTouchIt() {
        let edit = pair
        XCTAssertEqual(edit.snapped(2, to: point(1030, 10), snapDistance: 96), point(1000, 0))
    }

    func testSnappingAlignsBottomEdgesWhenClose() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, 800, 400)])
        // Bottom-aligned would be y = 600 - 400 = 200; 190 is 10 points away.
        XCTAssertEqual(edit.snapped(2, to: point(1010, 190), snapDistance: 96), point(1000, 200))
    }

    func testSnappingAlignsCentresWhenClose() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, 800, 400)])
        // Centred would be y = 300 - 200 = 100.
        XCTAssertEqual(edit.snapped(2, to: point(1010, 95), snapDistance: 96), point(1000, 100))
    }

    func testSnappingKeepsAnUnalignedOffsetAlongTheEdge() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, 800, 400)])
        XCTAssertEqual(edit.snapped(2, to: point(1010, 140), snapDistance: 96, alignDistance: 0), point(1000, 140))
    }

    func testSnappingKeepsAtLeastOnePointOfSharedEdge() {
        let edit = pair
        // Dropped almost entirely below the main display's right edge: kept sharing one point.
        let snapped = edit.snapped(2, to: point(1020, 605), snapDistance: 96, alignDistance: 0)
        XCTAssertEqual(snapped, point(1000, 599))
        var moved = edit
        moved.move(2, to: point(1020, 605), snapDistance: 96, alignDistance: 0)
        XCTAssertNil(moved.validate())
    }

    func testADisplayDroppedFarFromEverythingStaysWhereDroppedRounded() {
        var edit = pair
        XCTAssertEqual(edit.snapped(2, to: point(3000.4, 2000.6), snapDistance: 96), point(3000, 2001))
        edit.move(2, to: point(3000.4, 2000.6), snapDistance: 96)
        XCTAssertEqual(edit.validate(), .disconnected(2))
    }

    func testSnappingNeverPicksAPositionThatOverlapsAnotherDisplay() {
        // 2 is below the main display; 3 already sits right of it.
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 0, 600), display(3, 1000, 0)])
        let snapped = edit.snapped(2, to: point(1010, 0), snapDistance: 96)
        XCTAssertNotEqual(snapped, point(1000, 0), "right of the main display is taken by 3")
        XCTAssertEqual(snapped, point(1010, 0), "nothing free within reach: left where dropped")
    }

    func testANonFiniteDropIsIgnored() {
        var edit = pair
        XCTAssertFalse(edit.move(2, to: point(.nan, 0)))
        XCTAssertFalse(edit.move(2, to: point(0, .infinity)))
        XCTAssertEqual(edit.displays, edit.original)
    }

    // MARK: Validation

    func testOverlappingDisplaysAreRejected() {
        var edit = pair
        edit.move(2, to: point(500, 0), snapDistance: 0)
        XCTAssertEqual(edit.validate(), .overlap(1, 2))
    }

    func testTouchingOnlyAtACornerIsDisconnected() {
        var edit = pair
        edit.move(2, to: point(1000, 600), snapDistance: 0)
        XCTAssertEqual(edit.validate(), .disconnected(2))
    }

    func testADisplayConnectedThroughAnotherIsValid() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0), display(3, 2000, 0)])
        XCTAssertNil(edit.validate())
    }

    func testSharedEdgeNeedsAtLeastOnePoint() {
        XCTAssertTrue(Edit.sharesEdge(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 9, width: 10, height: 10)))
        XCTAssertFalse(Edit.sharesEdge(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 10, width: 10, height: 10)))
        XCTAssertFalse(Edit.overlaps(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)))
    }

    func testOriginsMustBeWholeFiniteAndInRange() {
        XCTAssertTrue(Edit.isValidOrigin(point(-32768, 32768)))
        XCTAssertFalse(Edit.isValidOrigin(point(0.5, 0)))
        XCTAssertFalse(Edit.isValidOrigin(point(.nan, 0)))
        XCTAssertFalse(Edit.isValidOrigin(point(0, -.infinity)))
        XCTAssertFalse(Edit.isValidOrigin(point(40_000, 0)))
    }

    // MARK: Normalization

    func testMovingTheMainDisplayKeepsItAtTheOriginAndMovesTheRest() {
        var edit = pair
        // Main moved to the right of 2: the same as 2 moving to the main display's left.
        edit.move(1, to: point(2000, 0), snapDistance: 0)
        XCTAssertNil(edit.validate())
        XCTAssertEqual(edit.normalizedOrigins[1], point(0, 0))
        XCTAssertEqual(edit.changedOrigins, [2: point(-1000, 0)])
    }

    // MARK: Mirror groups and placeholders

    func testAMirrorGroupIsOneDisplayThatMovesTogether() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0), display(3, 1000, 0, mirrorOf: 2)])
        XCTAssertEqual(edit.displays.map(\.id), [1, 2])
        XCTAssertEqual(edit.display(withID: 2)?.mirrorMemberIDs, [3])
        XCTAssertEqual(edit.primaryID(ofMirrorMember: 3), 2)
    }

    func testAMirrorMemberMovedAloneIsRejected() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0), display(3, 1000, 0, mirrorOf: 2)])
        XCTAssertEqual(edit.proposal(applying: [3: point(-1000, 0)]), .failure(.mirrorMember(3)))
        XCTAssertEqual(edit.proposal(applying: [2: point(-1000, 0), 3: point(1000, 0)]), .failure(.mirrorMember(3)))
    }

    func testAMirrorMemberListedWithItsPrimaryIsFoldedIntoIt() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0), display(3, 1000, 0, mirrorOf: 2)])
        XCTAssertEqual(edit.proposal(applying: [2: point(-1000, 0), 3: point(-1000, 0)]), .success([2: point(-1000, 0)]))
        XCTAssertEqual(edit.proposal(applying: [2: point(-1000, 0)]), .success([2: point(-1000, 0)]))
    }

    func testAnotherSessionsMeowDisplayCannotMove() {
        var edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, meow: true)])
        XCTAssertEqual(edit.display(withID: 2)?.isMovable, false)
        XCTAssertFalse(edit.move(2, to: point(-1000, 0)))
        XCTAssertEqual(edit.proposal(applying: [2: point(-1000, 0)]), .failure(.notMovable(2)))
    }

    func testThisSessionsOwnVirtualDisplayMayMove() {
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, own: true)])
        XCTAssertEqual(edit.display(withID: 2)?.isMovable, true)
        XCTAssertEqual(edit.proposal(applying: [2: point(-1000, 0)]), .success([2: point(-1000, 0)]))
    }

    func testMovingTheMainDisplayAwayFromAnotherSessionsScreenIsRejected() {
        // Normalization would shift 2 relative to the main display: that moves it.
        let edit = Edit(displays: [display(1, 0, 0, main: true), display(2, 1000, 0, meow: true), display(3, -1000, 0)])
        XCTAssertEqual(edit.proposal(applying: [1: point(1000, 600)]), .failure(.notMovable(2)))
        // Other displays still move freely around it.
        XCTAssertEqual(edit.proposal(applying: [3: point(0, 600)]), .success([3: point(0, 600)]))
    }

    // MARK: The Mac's request check

    func testAProposalIsValidatedAsAWhole() {
        let edit = pair
        XCTAssertEqual(edit.proposal(applying: [2: point(500, 0)]), .failure(.overlap(1, 2)))
        XCTAssertEqual(edit.proposal(applying: [2: point(3000, 0)]), .failure(.disconnected(2)))
    }

    func testAProposalRejectsBadOriginsAndUnknownIDs() {
        let edit = pair
        XCTAssertEqual(edit.proposal(applying: [2: point(1000.5, 0)]), .failure(.invalidOrigin(2)))
        XCTAssertEqual(edit.proposal(applying: [2: point(.nan, 0)]), .failure(.invalidOrigin(2)))
        XCTAssertEqual(edit.proposal(applying: [2: point(.infinity, 0)]), .failure(.invalidOrigin(2)))
        XCTAssertEqual(edit.proposal(applying: [2: point(1e12, 0)]), .failure(.invalidOrigin(2)))
        XCTAssertEqual(edit.proposal(applying: [99: point(0, 600)]), .failure(.unknownDisplay(99)))
    }

    func testAnEmptyOrUnchangedProposalIsRejected() {
        let edit = pair
        XCTAssertEqual(edit.proposal(applying: [:]), .failure(.empty))
        XCTAssertEqual(edit.proposal(applying: [2: point(1000, 0)]), .failure(.empty))
    }

    func testAProposalThatMovesTheMainDisplayIsNormalized() {
        let edit = pair
        XCTAssertEqual(edit.proposal(applying: [1: point(2000, 0)]), .success([2: point(-1000, 0)]))
    }

    func testWithoutAMainDisplayNothingIsValid() {
        let edit = Edit(displays: [display(1, 0, 0), display(2, 1000, 0)])
        XCTAssertEqual(edit.validate(), .noMainDisplay)
    }

    func testProblemsHaveWireReasons() {
        XCTAssertEqual(DisplayArrangementProblem.overlap(1, 2).wireReason, "overlap")
        XCTAssertEqual(DisplayArrangementProblem.disconnected(1).wireReason, "disconnected")
        XCTAssertEqual(DisplayArrangementProblem.notMovable(1).wireReason, "notMovable")
        XCTAssertEqual(DisplayArrangementProblem.noMainDisplay.wireReason, "noMain")
        let reasons = [DisplayArrangementProblem.empty, .unknownDisplay(1), .invalidOrigin(1), .mirrorMember(1),
                       .notMovable(1), .overlap(1, 2), .disconnected(1), .noMainDisplay].map(\.wireReason)
        XCTAssertTrue(reasons.allSatisfy { $0.count <= 32 })
    }

    // MARK: Wire

    private func roundTrip(_ message: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: message)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testARequestRoundTripsThroughJSON() throws {
        var edit = pair
        edit.move(2, to: point(-1000, 0), snapDistance: 0)
        let wire = try roundTrip(DisplayArrangeRequestMessage(req: 7, edit: edit).wire)
        XCTAssertEqual(wire["type"] as? String, WireMessage.displayArrangeRequest)
        let parsed = try XCTUnwrap(DisplayArrangeRequestMessage.parse(wire))
        XCTAssertEqual(parsed.req, 7)
        XCTAssertEqual(parsed.origins, [2: point(-1000, 0)])
        XCTAssertEqual(parsed.base.map(\.id), [1, 2])
        XCTAssertEqual(parsed.base.map(\.frame), [CGRect(x: 0, y: 0, width: 1000, height: 600),
                                                  CGRect(x: 1000, y: 0, width: 1000, height: 600)])
    }

    /// A request with these `origins` entries and one valid `base` entry.
    private func request(_ origins: [[String: Any]], base: [[String: Any]]? = nil) -> [String: Any] {
        let fallback: [[String: Any]] = [["id": 1, "x": 0, "y": 0, "w": 10, "h": 10]]
        return ["req": 1, "origins": origins, "base": base ?? fallback]
    }

    func testARequestKeepsFractionalNumbersForValidationToReject() throws {
        let origin: [String: Any] = ["id": 2, "x": 10.5, "y": 0]
        let wire = try roundTrip(request([origin]))
        XCTAssertEqual(DisplayArrangeRequestMessage.parse(wire)?.origins[2], point(10.5, 0))
    }

    func testMalformedRequestsAreRefused() throws {
        var noReq = request([])
        noReq["req"] = nil
        XCTAssertNil(DisplayArrangeRequestMessage.parse(noReq), "no req")
        var notAList = request([])
        notAList["origins"] = "x"
        XCTAssertNil(DisplayArrangeRequestMessage.parse(notAList))
        let booleanID: [String: Any] = ["id": true, "x": 0, "y": 0]
        XCTAssertNil(DisplayArrangeRequestMessage.parse(try roundTrip(request([booleanID]))), "a boolean is not an id")
        let textX: [String: Any] = ["id": 2, "x": "0", "y": 0]
        XCTAssertNil(DisplayArrangeRequestMessage.parse(request([textX])))
        let first: [String: Any] = ["id": 2, "x": 0, "y": 0]
        let again: [String: Any] = ["id": 2, "x": 1, "y": 0]
        XCTAssertNil(DisplayArrangeRequestMessage.parse(request([first, again])), "repeated id")
        let negative: [String: Any] = ["id": -1, "x": 0, "y": 0]
        XCTAssertNil(DisplayArrangeRequestMessage.parse(request([negative])))
        let flat: [String: Any] = ["id": 1, "x": 0, "y": 0, "w": 0, "h": 10]
        XCTAssertNil(DisplayArrangeRequestMessage.parse(request([], base: [flat])), "a base display needs a size")
        let many: [[String: Any]] = (0..<17).map { id -> [String: Any] in ["id": id, "x": 0, "y": 0] }
        XCTAssertNil(DisplayArrangeRequestMessage.parse(request(many)), "too many entries")
        let zero: [String: Any] = ["id": 0, "x": 1, "y": 0]
        XCTAssertNotNil(DisplayArrangeRequestMessage.parse(try roundTrip(request([zero]))),
                        "ids 0 and 1 are numbers, not booleans")
    }

    func testStateMessagesRoundTripAndAreBounded() throws {
        let applied = try roundTrip(DisplayArrangeStateMessage(req: 3, state: .applied, revertIn: 15).wire)
        XCTAssertEqual(DisplayArrangeStateMessage.parse(applied), DisplayArrangeStateMessage(req: 3, state: .applied, revertIn: 15))
        let denied = try roundTrip(DisplayArrangeStateMessage(req: 4, state: .denied, reason: "busy").wire)
        XCTAssertEqual(DisplayArrangeStateMessage.parse(denied)?.reason, "busy")
        XCTAssertNil(DisplayArrangeStateMessage.parse(["req": 1, "state": "exploded"]))
        XCTAssertNil(DisplayArrangeStateMessage.parse(["state": "kept"]))
        XCTAssertNil(DisplayArrangeStateMessage.parse(["req": 1, "state": "applied", "revertIn": 600])?.revertIn)
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(DisplayArrangeStateMessage.parse(["req": 1, "state": "failed", "reason": long])?.reason?.count, 32)
    }

    func testOnlyOutcomeStatesEndARequest() {
        XCTAssertFalse(DisplayArrangeState.awaitingMacConfirm.isFinal)
        XCTAssertFalse(DisplayArrangeState.applied.isFinal)
        for state in [DisplayArrangeState.kept, .reverted, .denied, .failed] { XCTAssertTrue(state.isFinal, state.rawValue) }
    }
}
