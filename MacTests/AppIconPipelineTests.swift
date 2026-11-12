import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// App icons from the Mac to pane and float titles, Stage Peek and its dock. Owner's iPhone QA
/// (build 9000022, screenshot 7): no app had its icon after this device reconnected to a Mac
/// session that stayed (QUIC reconnect, "admitted generation=3 first=false"): the Mac sent each
/// icon once per session, and this device, restarted meanwhile, had none of them any more.
final class AppIconPipelineTests: XCTestCase {
    private typealias Planner = AppIconRequestPlanner

    // MARK: Receiver: what to ask for

    func testEachMissingIconIsAskedForOnceThenRetriedWithBackoffAFewTimesAtMost() {
        var p = Planner()
        var have: Set<String> = ["com.apple.Safari"]
        XCTAssertEqual(p.plan(["a", "a", "com.apple.Safari", "", "b"], has: { have.contains($0) }, now: 0), ["a", "b"],
                       "missing, deduplicated, in order")
        XCTAssertEqual(p.plan(["a", "b"], has: { have.contains($0) }, now: 1), [], "not asked again at once")
        XCTAssertEqual(p.nextRetry(has: { have.contains($0) }), 4)
        have.insert("b")
        XCTAssertEqual(p.outstanding(has: { have.contains($0) }), ["a"])
        XCTAssertEqual(p.plan(p.outstanding(has: { have.contains($0) }), has: { have.contains($0) }, now: 4), ["a"])
        XCTAssertEqual(p.nextRetry(has: { have.contains($0) }), 4 + 8, "4, 8, 16 s")
        XCTAssertEqual(p.plan(["a"], has: { have.contains($0) }, now: 12), ["a"])
        XCTAssertEqual(p.plan(["a"], has: { have.contains($0) }, now: 28), ["a"])
        XCTAssertNil(p.nextRetry(has: { have.contains($0) }), "four asks, then it waits for the next connection")
        XCTAssertEqual(p.plan(["a"], has: { have.contains($0) }, now: 1000), [])
        p.reset()
        XCTAssertEqual(p.plan(["a"], has: { have.contains($0) }, now: 1001), ["a"], "a new connection asks again")
    }

    func testAMessageAsksForAtMost48AndAnUnsentAskIsRepeatedNextTime() {
        var p = Planner()
        let many = (0..<60).map { "app.\($0)" }
        let first = p.plan(many, has: { _ in false }, now: 0)
        XCTAssertEqual(first.count, Planner.batch)
        XCTAssertEqual(p.plan(many, has: { _ in false }, now: 0), Array(many.suffix(12)), "the rest in the next message")
        p.unsent(["app.0"])
        XCTAssertEqual(p.plan(["app.0"], has: { _ in false }, now: 0.1), ["app.0"], "never sent (no connection): asked again")
    }

    func testAnArrivedIconIsNoLongerOutstanding() {
        var p = Planner()
        _ = p.plan(["a"], has: { _ in false }, now: 0)
        p.received("a")
        XCTAssertNil(p.nextRetry(has: { _ in false }))
        XCTAssertEqual(p.plan(["a"], has: { _ in false }, now: 0.5), ["a"], "dropped later to make room: asked again when wanted")
    }

    func testRoomIsMadeByDroppingTheOldestIconNotShownInAPaneOrFloat() {
        XCTAssertEqual(Planner.evict(arrival: ["pane.app", "old", "newer"], shown: ["pane.app"]), "old")
        XCTAssertNil(Planner.evict(arrival: ["pane.app"], shown: ["pane.app"]))
    }

    func testThePlaceholderShowsTheAppsInitial() {
        XCTAssertEqual(Planner.initial(of: "Google Chrome"), "G")
        XCTAssertEqual(Planner.initial(of: "7-Zip"), "7")
        XCTAssertEqual(Planner.initial(of: "  ärger"), "Ä")
        XCTAssertNil(Planner.initial(of: ""), "no name: a window glyph")
        XCTAssertNil(Planner.initial(of: "—"))
    }

    // MARK: Receiver model: panes and floats get icons without Stage Peek

    private static let png: Data = {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }()

    private static func catalog(_ windows: [(UInt32, String)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": Int($0.0), "gen": 1, "bundle": $0.1, "app": $0.1, "title": "t\($0.0)", "w": 800, "h": 600, "state": "visible"] },
            "apps": [],
        ])!
    }

    private static func iconAsks(_ sent: [[String: Any]]) -> [[String]] {
        sent.filter { $0["type"] as? String == WireMessage.windowThumbnailRequest }.compactMap { $0["icons"] as? [String] }
    }

    @MainActor
    private func connectedModel(defaults: UserDefaults, sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let m = WorkspaceModel(defaults: defaults)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.mode(window: true))
        m.apply(Self.catalog([(10, "dev.zed.Zed"), (11, "com.google.Chrome")]))
        m.updateSpace(WorkspaceSize(width: 800, height: 600), hinge: nil)
        return m
    }

    @MainActor
    func testAPanesIconIsAskedForWithoutBrowsingAndOncePerConnection() {
        var sent: [[String: Any]] = []
        let defaults = UserDefaults(suiteName: "AppIconPipelineTests-\(UUID().uuidString)")!
        let m = connectedModel(defaults: defaults) { sent.append($0) }
        XCTAssertFalse(m.stagePeekOpen || m.overviewOpen || m.launchpadOpen, "nothing is being browsed")
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertEqual(Self.iconAsks(sent), [["dev.zed.Zed"]], "the new pane's app")
        m.choose(m.catalog!.windows[1], asNewTile: true)
        m.updateSpace(WorkspaceSize(width: 700, height: 600), hinge: nil)
        XCTAssertEqual(Self.iconAsks(sent), [["dev.zed.Zed"], ["com.google.Chrome"]], "each once, however often the layout changes")
        m.apply(.icon(bundleID: "dev.zed.Zed", data: Self.png))
        XCTAssertNotNil(m.icons["dev.zed.Zed"])

        // The same Mac again: only what's still missing is asked for.
        sent = []
        m.apply(.disconnected)
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.connected(peerID: "mac-a"))
        XCTAssertEqual(Self.iconAsks(sent), [["com.google.Chrome"]])

        // This device restarted (a new model, the layout saved): every pane's icon is asked for.
        var fresh: [[String: Any]] = []
        let restarted = WorkspaceModel(defaults: defaults)
        restarted.send = { fresh.append($0); return true }
        restarted.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        restarted.apply(.connected(peerID: "mac-a"))
        XCTAssertEqual(Set(Self.iconAsks(fresh).flatMap { $0 }), ["dev.zed.Zed", "com.google.Chrome"])
    }

    @MainActor
    func testNoIconIsAskedForBeforeTheSessionIsAdmitted() {
        var sent: [[String: Any]] = []
        let m = connectedModel(defaults: UserDefaults(suiteName: "AppIconPipelineTests-\(UUID().uuidString)")!) { sent.append($0) }
        // Reconnecting: the Mac's welcome has come, its admission not yet.
        m.apply(.disconnected)
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertEqual(Self.iconAsks(sent), [], "the Mac drops asks from a session it hasn't admitted")
        m.apply(.connected(peerID: "mac-a"))
        XCTAssertEqual(Self.iconAsks(sent), [["dev.zed.Zed"]])
    }

    @MainActor
    func testAShownPanesIconIsKeptWhenTheIconsAreFull() {
        let m = connectedModel(defaults: UserDefaults(suiteName: "AppIconPipelineTests-\(UUID().uuidString)")!) { _ in }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.apply(.icon(bundleID: "dev.zed.Zed", data: Self.png))
        for i in 0..<Planner.keep { m.apply(.icon(bundleID: "app.\(i)", data: Self.png)) }
        XCTAssertEqual(m.icons.count, Planner.keep)
        XCTAssertNotNil(m.icons["dev.zed.Zed"], "the pane's icon stays")
        XCTAssertNil(m.icons["app.0"], "the oldest other one made room")
        XCTAssertNotNil(m.icons["app.\(Planner.keep - 1)"], "the newest is kept, not dropped")
    }

    // MARK: Mac: what to send

    func testTheMacSendsAnAskedIconOncePerConnectionAndAgainWhenAskedLater() {
        typealias Ledger = AppIconSendLedger
        var l = Ledger()
        XCTAssertEqual(l.admit(["a", "b", "a", ""], now: 0), ["a", "b"])
        XCTAssertEqual(l.admit(["a", "b"], now: 1), [], "asked again at once (two views on screen): once")
        XCTAssertEqual(l.admit(["a"], now: Ledger.resendAfter), ["a"], "asked again later: the receiver still lacks it")
        l.noIcon("b")
        XCTAssertEqual(l.admit(["b"], now: Ledger.resendAfter + 1), [], "no icon on this Mac: not looked up again soon")
        XCTAssertEqual(l.admit(["b"], now: Ledger.unavailableRetry + 1), ["b"])
        _ = l.admit(["c"], now: 100)
        l.reset()
        XCTAssertEqual(l.admit(["c"], now: 100.5), ["c"], "a new connection: answered afresh")
        XCTAssertEqual(l.admit((0..<60).map { "x\($0)" }, now: 200).count, Ledger.batch)
    }

    /// The service itself: a session that went inactive and active again (a reconnect) sends
    /// an icon asked for again, which it used to refuse for the rest of the session.
    func testTheBrowserSendsIconsAgainAfterAReconnect() throws {
        let finder = "com.apple.finder"
        try XCTSkipIf(NSRunningApplication.runningApplications(withBundleIdentifier: finder).isEmpty
                      || NSWorkspace.shared.urlForApplication(withBundleIdentifier: finder) == nil, "needs Finder")
        let sink = IconSink()
        let service = WindowBrowserService(hostID: "test")
        defer { service.stop() }
        service.sendMessage = { m in if m["type"] as? String == WireMessage.appIcon { sink.fire() } }
        let ask: [String: Any] = ["type": WireMessage.windowThumbnailRequest, "ids": [Int](), "icons": [finder]]

        let first = expectation(description: "sent")
        sink.set { first.fulfill() }
        service.handle(type: WireMessage.windowThumbnailRequest, message: ask, inputGranted: false)
        wait(for: [first], timeout: 10)

        let again = expectation(description: "not sent twice at once")
        again.isInverted = true
        sink.set { again.fulfill() }
        service.handle(type: WireMessage.windowThumbnailRequest, message: ask, inputGranted: false)
        wait(for: [again], timeout: 1.5)

        let reconnected = expectation(description: "sent again after a reconnect")
        sink.set { reconnected.fulfill() }
        service.setActive(false)
        service.setActive(true)
        service.handle(type: WireMessage.windowThumbnailRequest, message: ask, inputGranted: false)
        wait(for: [reconnected], timeout: 10)
    }
}

private final class IconSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    func set(_ h: @escaping () -> Void) { lock.withLock { handler = h } }
    func fire() {
        let h = lock.withLock { handler }
        h?()
    }
}
