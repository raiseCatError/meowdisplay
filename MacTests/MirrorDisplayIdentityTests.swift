import XCTest

final class MirrorDisplayIdentityTests: XCTestCase {
    func testResolveFindsNoMatchWhenPersistentIDIsNotAmongOnScreenDisplays() {
        // We can't construct a real SCDisplay in a unit test (no live
        // ScreenCaptureKit content), so this exercises the empty-list edge
        // case that a genuinely disconnected display produces — the code
        // path Phase "selected display disappears" relies on.
        XCTAssertNil(MirrorDisplayIdentity.resolve(persistentID: "not-a-real-uuid", in: []))
    }

    func testMainDisplayUUIDIsStableAcrossRepeatedLookups() {
        // The main display always exists while tests run — this is a
        // sanity check that CGDisplayCreateUUIDFromDisplayID is stable
        // within a session, which the persistence/resolution model assumes.
        let id = CGMainDisplayID()
        let first = MirrorDisplayIdentity.uuidString(for: id)
        let second = MirrorDisplayIdentity.uuidString(for: id)
        XCTAssertEqual(first, second)
    }
}

final class MirrorDisplayCandidateTests: XCTestCase {
    func testDetailDistinguishesLogicalFromBackingPixelSize() {
        let candidate = MirrorDisplayCandidate(
            displayID: 1, persistentID: "uuid", name: "Test Display",
            logicalSize: CGSize(width: 2560, height: 1440),
            pixelSize: CGSize(width: 5120, height: 2880),
            isMain: false, likelyVirtual: true)
        XCTAssertTrue(candidate.isHiDPI)
        XCTAssertTrue(candidate.detail.contains("2560×1440 logical"))
        XCTAssertTrue(candidate.detail.contains("5120×2880 backing"))
        XCTAssertTrue(candidate.detail.contains("HiDPI"))
        XCTAssertTrue(candidate.detail.contains("possibly virtual"))
    }

    func testNonHiDPIDisplayIsNotFlaggedHiDPI() {
        let candidate = MirrorDisplayCandidate(
            displayID: 1, persistentID: "uuid", name: "Test Display",
            logicalSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            isMain: true, likelyVirtual: false)
        XCTAssertFalse(candidate.isHiDPI)
        XCTAssertEqual(candidate.label, "Test Display (Main)")
    }

    func testIDFallsBackToDisplayIDWhenNoPersistentIDAvailable() {
        let candidate = MirrorDisplayCandidate(
            displayID: 42, persistentID: nil, name: "No UUID Display",
            logicalSize: .zero, pixelSize: .zero, isMain: false, likelyVirtual: false)
        XCTAssertEqual(candidate.id, "id:42")
    }
}
