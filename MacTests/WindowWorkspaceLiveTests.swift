import AppKit
import XCTest

/// Live check against windows that already exist on this Mac (never opens, moves, focuses or
/// saves anything). Skipped unless WORKSPACE_LIVE_WINDOWS lists window ids, e.g. a window on
/// the current stage and one in Stage Manager's side strip:
///   WORKSPACE_LIVE_WINDOWS=12549,10203 xcrun xctest -XCTest OpenSidecarMacTests.WindowWorkspaceLiveTests <bundle>
/// Run from a process with Screen Recording (xcodebuild's runner has none). Prints a report.
final class WindowWorkspaceLiveTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        private var frames = 0
        func add(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
        func frame() { lock.withLock { frames += 1 } }
        var frameCount: Int { lock.withLock { frames } }
        func last(_ type: String) -> [String: Any]? { lock.withLock { messages.last { $0["type"] as? String == type } } }
        func all(_ type: String) -> [[String: Any]] { lock.withLock { messages.filter { $0["type"] as? String == type } } }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testExistingWindowsStreamOrReportTheirTruthfulState() throws {
        guard let list = ProcessInfo.processInfo.environment["WORKSPACE_LIVE_WINDOWS"] else { throw XCTSkip("set WORKSPACE_LIVE_WINDOWS") }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("no Screen Recording permission in this process") }
        _ = NSApplication.shared
        let ids = list.split(separator: ",").compactMap { Int($0) }
        let box = Box()
        let browser = WindowBrowserService(hostID: "live-mac")
        browser.sendMessage = { box.add($0) }
        let engine = WindowWorkspaceEngine(hostID: "live-mac", canvas: CGSize(width: 1170, height: 2532), fps: 30, browser: browser)
        engine.deliverFrame = { _ in box.frame() }
        engine.sendMessage = { box.add($0) }
        engine.start()
        defer { engine.stop(); browser.stop() }

        browser.handle(type: WireMessage.windowCatalogRequest, message: [:], inputGranted: false)
        XCTAssertTrue(waitUntil(5) { box.last(WireMessage.windowCatalog) != nil })
        let windows = try XCTUnwrap(box.last(WireMessage.windowCatalog)?["windows"] as? [[String: Any]])
        var tiles: [[String: Any]] = []
        for (i, id) in ids.enumerated() {
            guard let w = windows.first(where: { $0["id"] as? Int == id }) else { print("LIVE: window \(id) not listed"); continue }
            print("LIVE: window \(id) app=\(w["bundle"] ?? "?") listed \(w["w"] ?? 0)x\(w["h"] ?? 0) strip=\(w["strip"] ?? false)")
            let h = 1.0 / Double(ids.count)
            tiles.append(["id": "t\(i)", "x": 0.0, "y": Double(i) * h, "w": 1.0, "h": h, "window": id, "gen": w["gen"] as? Int ?? 0, "view": 1])
        }
        let started = Date()
        engine.handle(type: WireMessage.workspaceRequest, message: ["tiles": tiles], inputGranted: false)
        // Every pane reaches a truthful state (live or paused) quickly; never stuck on waiting.
        let settled = waitUntil(8) {
            let states = (box.last(WireMessage.workspaceState)?["tiles"] as? [[String: Any]] ?? []).compactMap { $0["state"] as? String }
            return states.count == tiles.count && states.allSatisfy { $0 == "live" || $0 == "paused" }
        }
        let states = box.last(WireMessage.workspaceState)?["tiles"] as? [[String: Any]] ?? []
        print("LIVE: settled=\(settled) after \(String(format: "%.2f", Date().timeIntervalSince(started))) s states=\(states.map { "\($0["id"] ?? "")=\($0["state"] ?? "")\(($0["strip"] as? Bool) == true ? "(strip)" : "")" })")
        XCTAssertTrue(settled, "no pane may stay waiting: \(states)")
        XCTAssertTrue(waitUntil(3) { !box.all(WireMessage.workspaceView).isEmpty }, "the view is echoed once composed")

        // Zoom a live pane from 0.7x to 8x and back: frames keep coming, few reconfigurations.
        if let live = states.first(where: { $0["state"] as? String == "live" })?["id"] as? String,
           var tile = tiles.first(where: { $0["id"] as? String == live }) {
            let before = box.frameCount
            var epoch = 1
            for s in [0.7, 1, 2, 4, 8, 3, 1] {
                epoch += 1
                tile["zoom"] = [s, 0.4, 0.6]
                tile["view"] = epoch
                engine.handle(type: WireMessage.workspaceRequest, message: ["tiles": tiles.map { $0["id"] as? String == live ? tile : $0 }], inputGranted: false)
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            }
            let echoed = box.all(WireMessage.workspaceView).compactMap { ($0["tiles"] as? [String: Int])?[live] }.max() ?? 0
            print("LIVE: zoom sweep frames=\(box.frameCount - before) last echoed view=\(echoed) (sent \(epoch))")
            XCTAssertEqual(echoed, epoch, "the last view reached the picture")
            XCTAssertGreaterThan(box.frameCount - before, 5)
            // The whole-source still for the receiver's instant zoom.
            engine.handle(type: WireMessage.workspaceBackdropRequest, message: ["tile": live, "max": 1280, "req": 1], inputGranted: false)
            XCTAssertTrue(waitUntil(3) { box.last(WireMessage.workspaceBackdrop) != nil }, "a backdrop still comes back")
            if let b = box.last(WireMessage.workspaceBackdrop), let jpeg = b["jpeg"] as? String {
                print("LIVE: backdrop \(jpeg.count) base64 chars after request")
            }
        }
    }
}
