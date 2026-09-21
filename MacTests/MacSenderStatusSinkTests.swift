import XCTest

@MainActor
final class MacSenderStatusSinkTests: XCTestCase {

    func testPublishStatusInvokesCurrentCallback() {
        let sink = MacSenderStatusSink()
        var received: [String] = []
        sink.onStatus = { received.append($0) }
        sink.publishStatus("Connected")
        XCTAssertEqual(received, ["Connected"])
    }

    func testPublishStatusIsNoOpWithNoCallbackAssigned() {
        let sink = MacSenderStatusSink()
        // Must not crash/trap when nobody has subscribed yet.
        sink.publishStatus("ignored")
    }

    func testPublishStatsForwardsExactValues() {
        let sink = MacSenderStatusSink()
        var got: (Int, Double)?
        sink.onStats = { got = ($0, $1) }
        sink.publishStats(frames: 42, mbps: 12.5)
        XCTAssertEqual(got?.0, 42)
        XCTAssertEqual(got?.1, 12.5)
    }

    func testPublishMediaStateForwardsExactValues() {
        let sink = MacSenderStatusSink()
        var got: (Bool, Bool, Int, Int, Int)?
        sink.onMediaState = { got = ($0, $1, $2, $3, $4) }
        sink.publishMediaState(videoActive: true, audioActive: false, width: 1920, height: 1080, fps: 60)
        XCTAssertEqual(got?.0, true)
        XCTAssertEqual(got?.1, false)
        XCTAssertEqual(got?.2, 1920)
        XCTAssertEqual(got?.3, 1080)
        XCTAssertEqual(got?.4, 60)
    }

    func testPublishCaptureLifecycleChangedForwardsPhase() {
        let sink = MacSenderStatusSink()
        var got: CaptureLifecyclePhase?
        sink.onCaptureLifecycleChanged = { got = $0 }
        sink.publishCaptureLifecycleChanged(.running)
        XCTAssertEqual(got, .running)
    }

    func testPublishDisconnectedFiresExactlyOnce() {
        let sink = MacSenderStatusSink()
        var count = 0
        sink.onDisconnected = { count += 1 }
        sink.publishDisconnected()
        XCTAssertEqual(count, 1)
    }

    func testPublishPeerSleepingAndPeerClosedAreIndependent() {
        let sink = MacSenderStatusSink()
        var sleepingCount = 0
        var closedCount = 0
        sink.onPeerSleeping = { sleepingCount += 1 }
        sink.onPeerClosed = { closedCount += 1 }
        sink.publishPeerSleeping()
        XCTAssertEqual(sleepingCount, 1)
        XCTAssertEqual(closedCount, 0)
        sink.publishPeerClosed()
        XCTAssertEqual(sleepingCount, 1)
        XCTAssertEqual(closedCount, 1)
    }

    func testPublishTransportPathForwardsRouteAndNil() {
        let sink = MacSenderStatusSink()
        var got: [ConnectionRoute?] = []
        sink.onTransportPath = { got.append($0) }
        sink.publishTransportPath(.usb)
        sink.publishTransportPath(nil)
        XCTAssertEqual(got, [.usb, nil])
    }

    func testPublishCaptureStoppedByUserFiresExactlyOnce() {
        let sink = MacSenderStatusSink()
        var count = 0
        sink.onCaptureStoppedByUser = { count += 1 }
        sink.publishCaptureStoppedByUser()
        sink.publishCaptureStoppedByUser()
        XCTAssertEqual(count, 2)
    }

    func testReassigningCallbackReplacesRatherThanAccumulates() {
        // Guards against accidental Combine/append-style storage: assigning a
        // new closure to the property must fully replace the old one, not
        // chain both, matching MacSender's plain `sender.onStatus = { ... }`
        // delegate-style usage.
        let sink = MacSenderStatusSink()
        var firstCalls = 0
        var secondCalls = 0
        sink.onStatus = { _ in firstCalls += 1 }
        sink.onStatus = { _ in secondCalls += 1 }
        sink.publishStatus("x")
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(secondCalls, 1)
    }
}
