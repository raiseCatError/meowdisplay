import XCTest

/// `appLaunch` on the Mac (Mac/WindowBrowserService.swift): exactly the app asked for, only with
/// control, asked again right before it opens. The launcher is replaced: no real app is opened.
final class AppLaunchRequestTests: XCTestCase {
    func testTheGateNeedsABundleAndControl() {
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal"], inputGranted: true), .launch("com.apple.iCal"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": "com.apple.iCal"], inputGranted: false), .refuse("control"))
        XCTAssertEqual(AppLaunchGate.decide([:], inputGranted: true), .refuse("bundle"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": ""], inputGranted: true), .refuse("bundle"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": 7], inputGranted: true), .refuse("bundle"))
        XCTAssertEqual(AppLaunchGate.decide(["bundle": String(repeating: "a", count: 256)], inputGranted: true), .refuse("bundle"))
    }

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var launched: [String] = []
        var stillAllowedAnswers: [Bool] = []
        var messages: [[String: Any]] = []
        func add(_ b: String, _ allowed: Bool) { lock.withLock { launched.append(b); stillAllowedAnswers.append(allowed) } }
        func sent(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
    }

    private func service(_ calls: Calls, opens: Bool, sent: XCTestExpectation? = nil) -> WindowBrowserService {
        let s = WindowBrowserService(hostID: "mac-test")
        s.refreshesAfterLaunch = false
        s.launchApp = { bundle, stillAllowed, done in
            // The real launcher asks `stillAllowed` right before opening; record what it says.
            let allowed = stillAllowed()
            calls.add(bundle, allowed)
            done(opens && allowed)
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
