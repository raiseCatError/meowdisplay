import CoreGraphics
import ImageIO
import XCTest

/// Lock screen privacy (SECURITY.md "When the Mac is locked"): what counts as locked, how
/// notifications and reads combine, which messages stop, how control requests are answered,
/// and what a receiver drops. The sender's own gates are in `MacSenderInputRevocationTests`.
final class MacLockPrivacyTests: XCTestCase {
    private let console = kCGSessionOnConsoleKey as String

    func testReadingFailsClosed() {
        XCTAssertEqual(MacLockReading.state(nil), .unknown, "no dictionary is never 'unlocked'")
        XCTAssertEqual(MacLockReading.state([:]), .unknown, "no console key: unknown")
        XCTAssertEqual(MacLockReading.state([console: true]), .unlocked)
        XCTAssertEqual(MacLockReading.state([console: true, "CGSSessionScreenIsLocked": NSNumber(value: true)]), .locked)
        XCTAssertEqual(MacLockReading.state([console: true, "CGSSessionScreenIsLocked": NSNumber(value: false)]), .unlocked)
        XCTAssertEqual(MacLockReading.state([console: false, "CGSSessionScreenIsLocked": NSNumber(value: true)]), .switchedOut)
        for s in [MacScreenPrivacy.locked, .switchedOut, .unknown] { XCTAssertFalse(s.allowsContent, "\(s)") }
        XCTAssertTrue(MacScreenPrivacy.unlocked.allowsContent)
    }

    func testTrackerLocksOnTheNoticeAndUnlocksOnlyOnARead() {
        var t = MacLockTracker(reading: .unlocked)
        XCTAssertTrue(t.lockNotice(now: 10))
        XCTAssertEqual(t.state, .locked)
        // The session dictionary can lag the notice: a stale 'unlocked' read doesn't unlock.
        XCTAssertFalse(t.read(.unlocked, now: 10.5))
        XCTAssertEqual(t.state, .locked)
        XCTAssertFalse(t.read(.locked, now: 11))
        // Unlock notice, then a read that agrees: unlocked.
        t.unlockNotice()
        XCTAssertTrue(t.read(.unlocked, now: 11.2))
        XCTAssertEqual(t.state, .unlocked)
        // A missed unlock notice: reads win once the lag has passed.
        XCTAssertTrue(t.lockNotice(now: 20))
        XCTAssertFalse(t.read(.unlocked, now: 20 + MacLockTracker.unlockLag - 0.1))
        XCTAssertTrue(t.read(.unlocked, now: 20 + MacLockTracker.unlockLag + 0.1))
        // Reads alone: locked, unknown and switched out all block.
        XCTAssertTrue(t.read(.locked, now: 30)); XCTAssertEqual(t.state, .locked)
        XCTAssertTrue(t.read(.unknown, now: 31)); XCTAssertEqual(t.state, .unknown)
        XCTAssertTrue(t.read(.switchedOut, now: 32))
        XCTAssertFalse(t.lockNotice(now: 33), "switched out stays switched out")
        XCTAssertEqual(t.state, .switchedOut)
    }

    func testGateIsShared() {
        let g = MacPrivacyGate(.unlocked)
        XCTAssertTrue(g.allowsContent && g.allowsInput)
        XCTAssertTrue(g.set(.locked))
        XCTAssertFalse(g.set(.locked))
        XCTAssertFalse(g.allowsContent || g.allowsInput)
    }

    /// Window lists, titles, stills, icons, Files, Clipboard and menus stop; what keeps the
    /// session and explains it still goes.
    func testLockedContentPolicy() {
        let content = [WireMessage.windowCatalog, WireMessage.windowThumbnail, WireMessage.appIcon, WireMessage.workspaceState,
                       WireMessage.workspaceView, WireMessage.workspaceBackdrop, WireMessage.appCatalog, WireMessage.displayThumbnail,
                       WireMessage.files, WireMessage.menu, ClipboardWire.type, WireMessage.textCaret]
        let session = [WireMessage.welcome, WireMessage.videoState, WireMessage.allowInputState, WireMessage.inputReset,
                       MacLockWire.type, LockMacWire.result, WireMessage.displayModeState, "pong", nil]
        for type in content {
            XCTAssertFalse(LockedContentPolicy.allows(type: type, privacy: .locked), type)
            XCTAssertFalse(LockedContentPolicy.allows(type: type, privacy: .unknown), type)
            XCTAssertTrue(LockedContentPolicy.allows(type: type, privacy: .unlocked), type)
        }
        for type in session { XCTAssertTrue(LockedContentPolicy.allows(type: type, privacy: .locked), type ?? "nil") }
    }

    /// Ask: refused at once while locked (no prompt nobody can answer, never an implicit grant).
    /// Always Allow: granted as chosen (input still waits for the unlock). Never Allow: refused.
    func testControlRequestsWhileLocked() {
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true, policy: .ask), .deny(.notAllowed))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true, policy: .alwaysAllow), .grant)
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true, policy: .neverAllow), .deny(.requestsDisabled))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: false, onConsole: true, screenLocked: true, policy: .alwaysAllow), .deny(.notAllowed))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: false, screenLocked: true, policy: .alwaysAllow), .deny(.notAllowed))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: false, policy: .ask), .ask)
    }

    func testWireNotice() {
        let m = MacLockWire.message(.locked)
        XCTAssertEqual(m["remoteUnlock"] as? Bool, false, "never offered from a device")
        XCTAssertEqual(MacLockNotice(message: m), MacLockNotice(state: .locked))
        XCTAssertEqual(MacLockNotice(message: ["type": MacLockWire.type, "state": "somethingNew"])?.state, .unknown, "unknown counts as locked")
        XCTAssertNil(MacLockNotice(message: ["type": MacLockWire.type]))
        XCTAssertNil(MacLockNotice(message: ["type": "other", "state": "locked"]))
        XCTAssertFalse(MacLockNotice(state: .unlocked).isLocked)
        guard case .macLock(let n)? = WorkspaceEvent.parse(type: MacLockWire.type, m) else { return XCTFail("parsed") }
        XCTAssertTrue(n.isLocked)
    }

    /// The receiver drops the window list with its titles and every still, stops a drag and closes
    /// Stage Peek and the picker; the layout is kept; unlocking asks for the window list again.
    @MainActor
    func testReceiverForgetsContentButKeepsTheLayout() throws {
        var sent: [[String: Any]] = []
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "MacLockPrivacyTests-\(UUID().uuidString)")!)
        m.send = { sent.append($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        let catalog = try XCTUnwrap(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [["id": 10, "gen": 1, "bundle": "com.apple.Notes", "app": "Notes", "title": "Private note", "w": 800, "h": 600, "state": "visible"]],
            "apps": [],
        ]))
        m.apply(catalog)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        let layout = m.layout
        let png = try XCTUnwrap(Self.png())
        m.apply(.thumbnail(windowID: 10, generation: 1, data: png, stale: false))
        XCTAssertNotNil(m.thumbnails[10])
        m.stagePeekOpen = true
        m.openOverview(replacing: nil)
        m.beginDrag(.window(m.catalog!.windows[0]), at: CGPoint(x: 10, y: 10))

        m.apply(.macLock(MacLockNotice(state: .locked)))
        XCTAssertTrue(m.macLocked)
        XCTAssertNil(m.catalog, "no titles kept")
        XCTAssertTrue(m.thumbnails.isEmpty, "no stills kept")
        XCTAssertNil(m.drag)
        XCTAssertFalse(m.stagePeekOpen)
        XCTAssertFalse(m.overviewOpen)
        XCTAssertEqual(m.layout, layout, "the arrangement is kept")

        sent.removeAll()
        m.apply(.macLock(MacLockNotice(state: .unlocked)))
        XCTAssertFalse(m.macLocked)
        XCTAssertTrue(sent.contains { $0["type"] as? String == WireMessage.windowCatalogRequest }, "asked again after the unlock")
        m.apply(.disconnected)
        XCTAssertFalse(m.macLocked)
    }

    private static func png() -> Data? {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = ctx?.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// #255: a session that outlives the Mac's displays going to sleep. The Mac says so; the receiver
/// offers one explicit, bounded wake request and never wakes the Mac by itself.
final class MacDisplaySleepTests: XCTestCase {
    func testWireRoundTrip() {
        XCTAssertEqual(MacDisplaySleepWire.asleep(from: MacDisplaySleepWire.message(asleep: true)), true)
        XCTAssertEqual(MacDisplaySleepWire.asleep(from: MacDisplaySleepWire.message(asleep: false)), false)
    }

    func testMalformedMessagesAreIgnored() {
        XCTAssertNil(MacDisplaySleepWire.asleep(from: ["type": "macDisplaySleep"]))
        XCTAssertNil(MacDisplaySleepWire.asleep(from: ["type": "macDisplaySleep", "asleep": "yes"]))
        XCTAssertNil(MacDisplaySleepWire.asleep(from: ["type": "macLockState", "asleep": true]))
    }

    func testOneWakeRequestAtATime() {
        var request = MacWakeRequest()
        let first = request.begin()
        XCTAssertNotNil(first)
        XCTAssertEqual(request.phase, .waiting)
        XCTAssertNil(request.begin(), "a second tap while waiting sends nothing")
    }

    func testTheMacWakingEndsTheRequest() {
        var request = MacWakeRequest()
        let id = request.begin()!
        request.displayReported(asleep: true)
        XCTAssertEqual(request.phase, .waiting, "still asleep: keep waiting")
        request.displayReported(asleep: false)
        XCTAssertEqual(request.phase, .idle)
        XCTAssertFalse(request.timedOut(id), "a timeout after the Mac woke fails nothing")
        XCTAssertEqual(request.phase, .idle)
    }

    func testAMacThatStaysAsleepFailsTheRequestAndNothingRetries() {
        var request = MacWakeRequest()
        let id = request.begin()!
        XCTAssertTrue(request.timedOut(id))
        XCTAssertEqual(request.phase, .failed)
        XCTAssertFalse(request.timedOut(id))
        XCTAssertEqual(request.phase, .failed, "failed stays failed until another tap")
        XCTAssertNotNil(request.begin(), "Try Again starts a new request")
    }

    func testAStaleTimeoutCannotFailANewerRequest() {
        var request = MacWakeRequest()
        let old = request.begin()!
        _ = request.timedOut(old)
        let new = request.begin()!
        XCTAssertFalse(request.timedOut(old))
        XCTAssertEqual(request.phase, .waiting)
        XCTAssertTrue(request.timedOut(new))
    }
}
