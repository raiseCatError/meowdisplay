import CoreMedia
import XCTest
@preconcurrency import ScreenCaptureKit

/// A Window view pane's live capture retune (#256): what the stream really has, one update at a
/// time, and failures never counted as applied. No capture runs: a never-started stream stands in,
/// and `FakeReconfigure` plays ScreenCaptureKit's `updateConfiguration`.
final class WindowTileCaptureRetuneTests: XCTestCase {
    private let small = CGSize(width: 800, height: 600)
    private let large = CGSize(width: 1600, height: 1200)

    private func capture(_ fake: FakeReconfigure, size: CGSize = CGSize(width: 800, height: 600), fps: Int = 30) -> WindowTileCapture {
        let c = WindowTileCapture(tileID: "w1", windowID: 7, assignmentGeneration: 1,
                                  reconfigure: { _, config in try await fake.apply(config) })
        c.installStreamForTesting(SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil),
                                  size: size, fps: fps)
        return c
    }

    func testAFailedUpdateIsNotReportedAsAppliedAndIsTriedAgain() async {
        let fake = FakeReconfigure(script: [.fail(-3802), .succeed])
        let c = capture(fake)
        let first = await c.update(size: large, fps: 30)
        XCTAssertFalse(first, "ScreenCaptureKit refused the change: not a reconfiguration")
        let second = await c.update(size: large, fps: 30)
        XCTAssertTrue(second, "the stream still has the old size, so the same request is tried again")
        XCTAssertEqual(fake.calls.map(\.width), [1600, 1600])
    }

    func testOverlappingUpdatesNeverRunTogether() async {
        let fake = FakeReconfigure(script: [.hold, .succeed])
        let c = capture(fake)
        let target = large
        let first = Task { [c] in await c.update(size: target, fps: 30) }
        await fake.waitForHeldCall()
        _ = await c.update(size: CGSize(width: 1200, height: 900), fps: 30)
        fake.release()
        _ = await first.value
        XCTAssertEqual(fake.maxInFlight, 1, "one stream, one configuration change at a time")
    }
}

/// Plays `SCStream.updateConfiguration`: records what each call asked for, and succeeds, fails,
/// or holds until released, in script order (then succeeds).
final class FakeReconfigure: @unchecked Sendable {
    enum Step { case succeed, fail(Int), hold }
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

    func apply(_ config: SCStreamConfiguration) async throws {
        let fps = config.minimumFrameInterval.value > 0 ? Int(config.minimumFrameInterval.timescale) / Int(config.minimumFrameInterval.value) : 0
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
        case .hold:
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
    }

    /// Returns once a `.hold` call is waiting.
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
