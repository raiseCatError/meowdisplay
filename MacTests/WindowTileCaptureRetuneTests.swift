import CoreMedia
import XCTest
@preconcurrency import ScreenCaptureKit

/// A Window view pane's live capture retune (#256): what the stream really has, one change at a
/// time, the engine's latest decision last, and failures never counted as applied. No capture
/// runs: a never-started stream stands in, and `FakeReconfigure` plays ScreenCaptureKit's
/// `updateConfiguration` and `stopCapture`. The real `stopCapture` on a stream that never
/// started can wait on the system capture service indefinitely.
final class WindowTileCaptureRetuneTests: XCTestCase {
    private let small = CGSize(width: 800, height: 600)
    private let large = CGSize(width: 1600, height: 1200)
    private let medium = CGSize(width: 1200, height: 900)
    private let huge = CGSize(width: 2400, height: 1800)

    private func capture(_ fake: FakeReconfigure, size: CGSize = CGSize(width: 800, height: 600), fps: Int = 30) -> WindowTileCapture {
        let c = WindowTileCapture(tileID: "w1", windowID: 7, assignmentGeneration: 1,
                                  reconfigure: { _, config in try await fake.apply(config) },
                                  stopCapture: { _ in fake.stopStream() })
        c.installStreamForTesting(SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil),
                                  size: size, fps: fps)
        return c
    }

    private func settings(_ size: CGSize, _ fps: Int = 30) -> TileCaptureSettings { TileCaptureSettings(size: size, fps: fps) }
    private func call(_ size: CGSize, _ fps: Int = 30) -> FakeReconfigure.Call {
        FakeReconfigure.Call(width: Int(size.width), height: Int(size.height), fps: fps)
    }

    func testARefusedChangeIsNotAppliedAndTheSameRequestTriesAgain() async {
        let fake = FakeReconfigure(script: [.fail(-3802), .succeed])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = await c.applyRequested()
        XCTAssertEqual(first, TileRetuneResult(outcome: .failed(-3802), accepted: 0), "ScreenCaptureKit refused the change: not a reconfiguration")
        XCTAssertEqual(c.appliedSettings, settings(small), "the stream keeps what it had")
        XCTAssertTrue(c.request(size: large, fps: 30), "the stream still has the old size, so the same request is tried again")
        let second = await c.applyRequested()
        XCTAssertEqual(second, TileRetuneResult(outcome: .applied, accepted: 1))
        XCTAssertEqual(c.appliedSettings, settings(large))
        XCTAssertEqual(fake.calls, [call(large), call(large)])
    }

    func testAFailureNeverRetriesByItself() async {
        let fake = FakeReconfigure(script: [.fail(-3802)])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let outcome = await c.applyRequested()
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .failed(-3802), accepted: 0))
        XCTAssertEqual(fake.calls.count, 1, "no loop: only a new request tries again")
    }

    func testOverlappingRequestsRunOneChangeAtATimeAndEndOnTheLatest() async {
        let fake = FakeReconfigure(script: [.hold, .succeed])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = Task { [c] in await c.applyRequested() }
        await fake.waitForHeldCall()
        XCTAssertTrue(c.request(size: medium, fps: 30))
        let second = await c.applyRequested()
        XCTAssertEqual(second, TileRetuneResult(outcome: .coalesced, accepted: 0), "the change already running takes it up")
        XCTAssertTrue(c.request(size: huge, fps: 15))
        fake.release()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, TileRetuneResult(outcome: .applied, accepted: 2), "both accepted changes count, the one taken up from the coalesced request too")
        XCTAssertEqual(fake.maxInFlight, 1, "one stream, one configuration change at a time")
        XCTAssertEqual(fake.calls, [call(large), call(huge, 15)], "the superseded size is skipped; the latest is applied last")
        XCTAssertEqual(c.appliedSettings, settings(huge, 15))
    }

    func testTheEnginesOrderWinsWhateverOrderTheTasksRun() async {
        let fake = FakeReconfigure(script: [])
        let c = capture(fake)
        // The engine decides large, then medium, on its queue; the tasks that apply them may run
        // in any order. Either way the stream ends on medium.
        XCTAssertTrue(c.request(size: large, fps: 30))
        XCTAssertTrue(c.request(size: medium, fps: 30))
        let a = await c.applyRequested()
        let b = await c.applyRequested()
        XCTAssertEqual(a, TileRetuneResult(outcome: .applied, accepted: 1))
        XCTAssertEqual(b, TileRetuneResult(outcome: .unchanged, accepted: 0))
        XCTAssertEqual(fake.calls, [call(medium)])
        XCTAssertEqual(c.appliedSettings, settings(medium))
    }

    func testARequestBackToTheAppliedSettingsDuringAChangeIsStillApplied() async {
        let fake = FakeReconfigure(script: [.hold, .succeed])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = Task { [c] in await c.applyRequested() }
        await fake.waitForHeldCall()
        // Back to what the stream had: nothing new to start, but the running change must not
        // leave the stream on the size it is applying.
        XCTAssertFalse(c.request(size: small, fps: 30))
        fake.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .applied, accepted: 2))
        XCTAssertEqual(fake.calls, [call(large), call(small)])
        XCTAssertEqual(c.appliedSettings, settings(small))
    }

    func testANewerRequestAfterAFailedChangeIsTried() async {
        let fake = FakeReconfigure(script: [.holdThenFail(-3802), .succeed])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = Task { [c] in await c.applyRequested() }
        await fake.waitForHeldCall()
        XCTAssertTrue(c.request(size: medium, fps: 30))
        fake.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .applied, accepted: 1), "only the newer change was accepted")
        XCTAssertEqual(fake.calls, [call(large), call(medium)])
        XCTAssertEqual(c.appliedSettings, settings(medium))
    }

    func testAChangeAcceptedBeforeALaterFailureIsCounted() async {
        let fake = FakeReconfigure(script: [.hold, .fail(-3802)])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = Task { [c] in await c.applyRequested() }
        await fake.waitForHeldCall()
        XCTAssertTrue(c.request(size: medium, fps: 30))
        fake.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .failed(-3802), accepted: 1),
                       "the latest change failed, but the one before it was accepted and counts")
        XCTAssertEqual(c.appliedSettings, settings(large), "the stream has what was accepted")
        XCTAssertEqual(fake.calls, [call(large), call(medium)])
    }

    func testAStopDuringAChangeNeitherRecordsItNorStartsAnother() async {
        let fake = FakeReconfigure(script: [.hold])
        let c = capture(fake)
        XCTAssertTrue(c.request(size: large, fps: 30))
        let first = Task { [c] in await c.applyRequested() }
        await fake.waitForHeldCall()
        XCTAssertTrue(c.request(size: medium, fps: 30))
        await c.stop()
        fake.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .stopped, accepted: 0), "accepted by the fake, but the stream had stopped: not recorded, not counted")
        XCTAssertNil(c.appliedSettings, "a stopped stream is never reported current")
        XCTAssertFalse(c.request(size: huge, fps: 30), "nothing to retune after a stop")
        let after = await c.applyRequested()
        XCTAssertEqual(after, TileRetuneResult(outcome: .stopped, accepted: 0))
        XCTAssertEqual(fake.calls, [call(large)], "the request made before the stop is not applied to the stopped stream")
        XCTAssertEqual(fake.stops, 1, "the stream is asked to stop once")
    }

    func testAnUnchangedRequestDoesNothing() async {
        let fake = FakeReconfigure(script: [])
        let c = capture(fake)
        XCTAssertFalse(c.request(size: small, fps: 30))
        let outcome = await c.applyRequested()
        XCTAssertEqual(outcome, TileRetuneResult(outcome: .unchanged, accepted: 0))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testARequestBeforeTheStreamExistsIsIgnored() async {
        let fake = FakeReconfigure(script: [])
        let c = WindowTileCapture(tileID: "w1", windowID: 7, assignmentGeneration: 1,
                                  reconfigure: { _, config in try await fake.apply(config) })
        XCTAssertFalse(c.request(size: large, fps: 30), "the start uses the size the engine has when it runs")
        XCTAssertNil(c.appliedSettings)
    }

    /// Every change sends the whole configuration, so a live change never resets the cursor,
    /// pixel format, queue depth or audio (#172).
    func testEveryChangeCarriesTheWholeConfiguration() {
        let config = WindowTileCapture.configuration(TileCaptureSettings(size: CGSize(width: 1201.6, height: 900), fps: 0))
        XCTAssertEqual(config.width, 1201)
        XCTAssertEqual(config.height, 900)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 1), "at least 1 fps")
        XCTAssertFalse(config.showsCursor)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertFalse(config.capturesAudio)
        if #available(macOS 14.2, *) { XCTAssertTrue(config.ignoreShadowsSingleWindow) }
    }
}

/// Plays `SCStream.updateConfiguration`: records what each call asked for, and succeeds, fails,
/// or holds until released, in script order (then succeeds).
final class FakeReconfigure: @unchecked Sendable {
    enum Step { case succeed, fail(Int), hold, holdThenFail(Int) }
    struct Call: Equatable { var width: Int; var height: Int; var fps: Int }

    private let lock = NSLock()
    private var script: [Step]
    private var _calls: [Call] = []
    private var inFlight = 0
    private var _maxInFlight = 0
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var heldArrived = false

    init(script: [Step]) { self.script = script }

    var calls: [Call] { lock.withLock { _calls } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    private var _stops = 0
    /// How many times the capture asked the stream to stop.
    var stops: Int { lock.withLock { _stops } }
    func stopStream() { lock.withLock { _stops += 1 } }

    func apply(_ config: SCStreamConfiguration) async throws {
        let interval = config.minimumFrameInterval
        let fps = interval.value > 0 ? Int(interval.timescale) / Int(interval.value) : 0
        let step = lock.withLock { () -> Step in
            _calls.append(Call(width: config.width, height: config.height, fps: fps))
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
            return script.isEmpty ? .succeed : script.removeFirst()
        }
        defer { lock.withLock { inFlight -= 1 } }
        switch step {
        case .succeed: return
        case .fail(let code): throw NSError(domain: SCStreamErrorDomain, code: code)
        case .hold: await waitForRelease()
        case .holdThenFail(let code):
            await waitForRelease()
            throw NSError(domain: SCStreamErrorDomain, code: code)
        }
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                held = c
                heldArrived = true
                defer { heldWaiter = nil }
                return heldWaiter
            }
            waiter?.resume()
        }
    }

    /// Returns once a held call is waiting.
    func waitForHeldCall() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if heldArrived { return true }
                heldWaiter = c
                return false
            }
            if ready { c.resume() }
        }
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { held = nil }; return held }
        c?.resume()
    }
}
