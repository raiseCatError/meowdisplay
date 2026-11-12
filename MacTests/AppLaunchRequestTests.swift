import CoreGraphics
import XCTest

/// `appLaunch` on the Mac (Mac/WindowBrowserService.swift): exactly the app asked for, only with
/// control, asked again right before it opens. The launcher is replaced: no real app is opened.
final class AppLaunchRequestTests: XCTestCase {
    func testTheGateNeedsABundleAndControl() {
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal"], inputGranted: true), .launch("com.apple.iCal", reveal: false))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal"], inputGranted: false), .refuse("control"))
        XCTAssertEqual(AppLaunchGate.decide([:], inputGranted: true), .refuse("bundle"))
        // Show a Window on Mac: brought forward, and still only with control.
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal", "reveal": true], inputGranted: true),
                       .launch("com.apple.iCal", reveal: true))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal", "reveal": true], inputGranted: false), .refuse("control"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal", "reveal": "yes"], inputGranted: true),
                       .launch("com.apple.iCal", reveal: false), "only a true Boolean brings it forward")
        XCTAssertEqual(AppLaunchGate.decide(["bundle": ""], inputGranted: true), .refuse("bundle"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": 7], inputGranted: true), .refuse("bundle"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": String(repeating: "a", count: 256)], inputGranted: true), .refuse("bundle"))
    }

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var launched: [String] = []
        var reveals: [Bool] = []
        var stillAllowedAnswers: [Bool] = []
        var messages: [[String: Any]] = []
        func add(_ b: String, _ allowed: Bool) { lock.withLock { launched.append(b); stillAllowedAnswers.append(allowed) } }
        func sent(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
    }

    private func service(_ calls: Calls, opens: Bool, window: Bool? = nil, sent: XCTestExpectation? = nil) -> WindowBrowserService {
        let s = WindowBrowserService(hostID: "mac-test")
        s.refreshesAfterLaunch = false
        s.launchApp = { bundle, reveal, stillAllowed, done in
            // The real launcher asks `stillAllowed` right before opening; record what it says.
            let allowed = stillAllowed()
            calls.add(bundle, allowed)
            calls.lock.withLock { calls.reveals.append(reveal) }
            done(AppLaunchOutcome(ok: opens && allowed, window: opens && allowed ? window : nil))
        }
        s.sendMessage = { m in calls.sent(m); sent?.fulfill() }
        return s
    }

    /// With control: exactly that bundle id is launched, control is re-checked right before, and
    /// the Mac answers `appLaunchResult` for it.
    func testALaunchWithControlOpensExactlyThatAppAndAnswers() {
        let calls = Calls()
        let answered = expectation(description: "appLaunchResult")
        let s = service(calls, opens: true, sent: answered)
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.apple.iCal"],
                 inputGranted: true, controlStillAllowed: { true })
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(calls.launched, ["com.apple.iCal"])
        XCTAssertEqual(calls.stillAllowedAnswers, [true])
        let reply = calls.messages.first
        XCTAssertEqual(reply?["type"] as? String, WireMessage.appLaunchResult)
        XCTAssertEqual(reply?["bundle"] as? String, "com.apple.iCal")
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        s.stop()
    }

    /// Control gone by the time the app would open: nothing opens and the answer says so.
    func testControlLostBeforeOpeningOpensNothing() {
        let calls = Calls()
        let answered = expectation(description: "appLaunchResult")
        let s = service(calls, opens: true, sent: answered)
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.apple.iCal"],
                 inputGranted: true, controlStillAllowed: { false })
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(calls.stillAllowedAnswers, [false], "the launcher was told control ended")
        XCTAssertEqual(calls.messages.first?["ok"] as? Bool, false)
        s.stop()
    }

    /// Without control when it arrives: never launched (the receiver stops waiting on its own).
    func testWithoutControlNothingIsLaunched() {
        let calls = Calls()
        let s = service(calls, opens: true)
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.apple.iCal"],
                 inputGranted: false, controlStillAllowed: { true })
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch], inputGranted: true, controlStillAllowed: { true })
        _ = s.scDisplay(0)   // the service's queue has run both
        XCTAssertEqual(calls.launched, [])
        XCTAssertTrue(calls.messages.isEmpty)
        s.stop()
    }

    /// An app running without a window that a background open didn't give one: the answer says so,
    /// and Show a Window on Mac asks the launcher to bring it forward. Without the outcome, no key.
    func testTheAnswerSaysWhenNoWindowCameAndRevealReachesTheLauncher() {
        let calls = Calls()
        let answered = expectation(description: "appLaunchResult")
        answered.expectedFulfillmentCount = 2
        let s = service(calls, opens: true, window: false, sent: answered)
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.mitchellh.ghostty"],
                 inputGranted: true, controlStillAllowed: { true })
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.mitchellh.ghostty", "reveal": true],
                 inputGranted: true, controlStillAllowed: { true })
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(calls.reveals, [false, true])
        XCTAssertEqual(calls.messages.first?["window"] as? Bool, false)
        s.stop()

        let plain = Calls()
        let once = expectation(description: "appLaunchResult")
        let t = service(plain, opens: true, sent: once)
        t.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.apple.iCal"],
                 inputGranted: true, controlStillAllowed: { true })
        wait(for: [once], timeout: 2)
        XCTAssertNil(plain.messages.first?["window"], "unknown is left out (older receivers ignore it anyway)")
        t.stop()
    }

    func testOnlyOnScreenNormalWindowsOfThatAppCount() {
        func w(_ pid: Int32, layer: Int = 0, alpha: Double = 1, _ size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation]
        }
        let list = [w(7), w(7, layer: 25), w(7, alpha: 0), w(7, CGSize(width: 20, height: 20)), w(8), [:]]
        XCTAssertEqual(AppWindowPresence.normalWindowCount(list, pid: 7), 1)
        XCTAssertEqual(AppWindowPresence.normalWindowCount(list, pid: 9), 0)
    }

    /// The default re-check refuses: a caller that doesn't say how to re-check control opens nothing.
    func testTheDefaultReCheckRefuses() {
        let calls = Calls()
        let answered = expectation(description: "appLaunchResult")
        let s = service(calls, opens: true, sent: answered)
        s.handle(type: WireMessage.appLaunch, message: ["type": WireMessage.appLaunch, "bundle": "com.apple.iCal"], inputGranted: true)
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(calls.stillAllowedAnswers, [false])
        XCTAssertEqual(calls.messages.first?["ok"] as? Bool, false)
        s.stop()
    }
}
