import CoreGraphics
import XCTest

/// The overview's display actions: Move Cursor Here only to a listed display with control,
/// Identify labels, and the rate limits that keep a tapping receiver from flooding the Mac.
final class DisplayActionPolicyTests: XCTestCase {
    private let listed: [UInt32: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 1512, height: 982),
        2: CGRect(x: -2560, y: -300, width: 2560, height: 1440),
    ]

    func testMoveGoesToTheCentreOfAListedDisplay() {
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": 2], inputGranted: true, listed: listed),
                       .move(2, CGPoint(x: -1280, y: 420)))
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": 1], inputGranted: true, listed: listed),
                       .move(1, CGPoint(x: 756, y: 491)))
    }

    func testMoveNeedsControl() {
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": 1], inputGranted: false, listed: listed), .refuse("control"))
    }

    func testMoveRefusesDisplaysThatWereNotListed() {
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": 9], inputGranted: true, listed: listed), .refuse("display"))
        XCTAssertEqual(DisplayActionPolicy.moveCursor([:], inputGranted: true, listed: listed), .refuse("display"))
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": -1], inputGranted: true, listed: listed), .refuse("display"))
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": "1"], inputGranted: true, listed: listed), .refuse("display"))
        XCTAssertEqual(DisplayActionPolicy.moveCursor(["id": 3], inputGranted: true, listed: [3: .zero]), .refuse("display"))
    }

    func testIdentifyLabelsNumberFromOne() {
        XCTAssertEqual(DisplayActionPolicy.identifyLabel(index: 0, name: "Built-in Retina Display"), "1  Built-in Retina Display")
        XCTAssertEqual(DisplayActionPolicy.identifyLabel(index: 2, name: "  "), "3")
        XCTAssertEqual(DisplayActionPolicy.identifyLabel(index: 1, name: String(repeating: "x", count: 200)).count, 63)
    }

    func testRateLimit() {
        var limit = DisplayActionRateLimit()
        XCTAssertTrue(limit.admit(now: 10, interval: 2))
        XCTAssertFalse(limit.admit(now: 11, interval: 2))
        XCTAssertTrue(limit.admit(now: 12, interval: 2))
        XCTAssertTrue(limit.admit(now: 5, interval: 2), "a clock that went backwards does not block forever")
    }

    func testTheMacAdvertisesDisplayActionsOnlyWithWindowMode() {
        XCTAssertTrue(MacSender.welcomeFeatures(windowStreamingAllowed: true).contains(DisplayArrangeWire.welcomeFeature))
        XCTAssertFalse(MacSender.welcomeFeatures(windowStreamingAllowed: false).contains(DisplayArrangeWire.welcomeFeature))
        let features = MacSender.welcomeFeatures(windowStreamingAllowed: true)
        XCTAssertLessThanOrEqual(features.count, WindowWorkspaceWire.welcomeFeatureLimit)
        XCTAssertEqual(features.prefix(17).last, WindowWorkspaceWire.restoreOffscreenFeature,
                       "older receivers retain their first 16 features")
        XCTAssertFalse(MacSender.welcomeFeatures(windowStreamingAllowed: false).contains(WindowWorkspaceWire.restoreOffscreenFeature))
    }

    func testVideoOffLayoutUsesOptionalDesktopMetadataInEveryMode() {
        for windowMode in [true, false] {
            XCTAssertTrue(MacSender.welcomeFeatures(windowStreamingAllowed: windowMode)
                .contains(TrackpadLayoutWire.welcomeFeature))
        }
        let displays = listed.keys.sorted().map { TrackpadDisplayGeometry(id: $0, bounds: listed[$0]!) }
        for cursor in [CGPoint(x: 756, y: 491), CGPoint(x: -1280, y: 420)] {
            let sample = TrackpadLayoutWire.Sample(displays: displays, cursor: cursor)
            XCTAssertEqual(TrackpadLayoutWire.Sample.parse(sample.message), sample)
        }
        let gap = TrackpadLayoutWire.Sample(displays: displays, cursor: CGPoint(x: 400, y: -200))
        XCTAssertNil(TrackpadLayoutWire.Sample.parse(gap.message)?.cursor)
        let duplicate = TrackpadLayoutWire.Sample(displays: displays + displays, cursor: nil)
        XCTAssertNil(TrackpadLayoutWire.Sample.parse(duplicate.message))
        XCTAssertFalse(LockedContentPolicy.allows(type: TrackpadLayoutWire.state, privacy: .locked))
    }

    func testRequests() {
        XCTAssertEqual(WorkspaceRequests.identifyDisplays()["type"] as? String, "displayIdentify")
        let move = WorkspaceRequests.moveCursor(toDisplay: 7)
        XCTAssertEqual(move["type"] as? String, "cursorToDisplay")
        XCTAssertEqual(move["id"] as? Int, 7)
    }
}
