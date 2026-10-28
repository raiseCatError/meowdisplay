import AppKit
import CoreImage
import CoreVideo
import XCTest

/// Window mode end to end on this Mac: real windows, real ScreenCaptureKit
/// per-window streams, the GPU compositor. Skipped (not passed) when this
/// process has no Screen Recording permission.
final class WindowWorkspaceEngineIntegrationTests: XCTestCase {
    /// Keeps only the newest frames (the compositor's pool is bounded, like the
    /// encoder's hold) and checks each frame as it arrives.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var frames: [(at: Int, buffer: CVPixelBuffer)] = []
        var messages: [[String: Any]] = []
        var check: ((Int, CVPixelBuffer) -> Void)?
        func add(_ m: [String: Any]) { lock.withLock { messages.append(m) } }
        func add(_ b: CVPixelBuffer) {
            let (at, check) = lock.withLock { () -> (Int, ((Int, CVPixelBuffer) -> Void)?) in
                frames.append((messages.count, b)); if frames.count > 4 { frames.removeFirst() }
                return (messages.count, self.check)
            }
            check?(at, b)
        }
        func last(_ type: String) -> [String: Any]? { lock.withLock { messages.last { $0["type"] as? String == type } } }
        var messageCount: Int { lock.withLock { messages.count } }
        var lastFrame: CVPixelBuffer? { lock.withLock { frames.last?.buffer } }
    }

    private func window(_ color: NSColor, x: CGFloat) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: x, y: 300, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "MeowDisplay workspace test"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentView!.bounds)
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        w.contentView = v
        w.orderFrontRegardless()
        return w
    }

    /// Fraction of sampled pixels in `rect` (normalized) close to `rgb`.
    private func share(of rgb: (Int, Int, Int), in buffer: CVPixelBuffer, rect: WorkspaceRect) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var hits = 0, total = 0
        for j in 0..<20 {
            for i in 0..<20 {
                let x = Int((rect.x + rect.width * (Double(i) + 0.5) / 20) * Double(w))
                let y = Int((rect.y + rect.height * (Double(j) + 0.5) / 20) * Double(h))
                let p = base + y * row + x * 4   // BGRA
                let (b, g, r) = (Int(p[0]), Int(p[1]), Int(p[2]))
                if abs(r - rgb.0) < 60 && abs(g - rgb.1) < 60 && abs(b - rgb.2) < 60 { hits += 1 }
                total += 1
            }
        }
        return Double(hits) / Double(total)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testTwoWindowsCompositeIntoTheirTilesAndAReplacedTileNeverShowsTheOldWindow() throws {
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("no Screen Recording permission in this test process") }
        _ = NSApplication.shared
        let magenta = window(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.7, alpha: 1), x: 120)
        let green = window(NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1), x: 700)
        defer { magenta.close(); green.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let box = Box()
        let engine = WindowWorkspaceEngine(hostID: "test-mac", canvas: CGSize(width: 960, height: 480), fps: 30)
        engine.includeOwnProcessForTesting = true
        engine.deliverFrame = { box.add($0) }
        engine.sendMessage = { box.add($0) }
        engine.start()
        defer { engine.stop() }

        engine.handle(type: WireMessage.windowCatalogRequest, message: [:], inputGranted: false)
        XCTAssertTrue(waitUntil(5) { box.last(WireMessage.windowCatalog) != nil })
        let windows = try XCTUnwrap(box.last(WireMessage.windowCatalog)?["windows"] as? [[String: Any]])
        func gen(_ w: NSWindow) -> Int? { windows.first { $0["id"] as? Int == w.windowNumber }?["gen"] as? Int }
        let mGen = try XCTUnwrap(gen(magenta), "the test window is listed")
        let gGen = try XCTUnwrap(gen(green))

        // Tile a: magenta, upright. Tile b: green, rotated a quarter turn.
        engine.handle(type: WireMessage.workspaceRequest, message: ["tiles": [
            ["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "window": magenta.windowNumber, "gen": mGen],
            ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "window": green.windowNumber, "gen": gGen, "rotation": 90],
        ] as [[String: Any]]], inputGranted: false)
        XCTAssertTrue(waitUntil(6) {
            let tiles = box.last(WireMessage.workspaceState)?["tiles"] as? [[String: Any]] ?? []
            return tiles.count == 2 && tiles.allSatisfy { $0["state"] as? String == "live" }
        }, "both tiles go live: \(String(describing: box.last(WireMessage.workspaceState)))")
        XCTAssertTrue(waitUntil(3) { box.lastFrame.map { self.share(of: (230, 26, 178), in: $0, rect: .init(x: 0.15, y: 0.3, width: 0.2, height: 0.4)) > 0.9 } ?? false },
                      "tile a shows the magenta window")
        let frame = try XCTUnwrap(box.lastFrame)
        if let dir = ProcessInfo.processInfo.environment["WORKSPACE_TEST_DUMP"] {
            let ci = CIImage(cvPixelBuffer: frame)
            let rep = NSBitmapImageRep(ciImage: ci)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/composite-two-tiles.png"))
        }
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(frame), 480)
        XCTAssertGreaterThan(share(of: (26, 204, 51), in: frame, rect: .init(x: 0.7, y: 0.3, width: 0.1, height: 0.4)), 0.9, "tile b shows green")
        XCTAssertLessThan(share(of: (230, 26, 178), in: frame, rect: .init(x: 0.5, y: 0, width: 0.5, height: 1)), 0.01, "no magenta outside its tile")
        // Rotated 90°: a 480x320 window in a 480x480 tile is letterboxed left/right (taller than wide after rotation).
        XCTAssertLessThan(share(of: (26, 204, 51), in: frame, rect: .init(x: 0.51, y: 0.4, width: 0.04, height: 0.2)), 0.5,
                          "quarter-turned window: side bars, not stretched")

        // Replace tile a's window with the green one: from the state that
        // confirms it, no frame may show magenta in tile a again.
        let mark = box.messageCount
        let stats = NSLock()
        var afterMark = 0, staleMagenta = 0, greenSeen = false
        box.check = { at, buffer in
            guard at > mark else { return }
            let magenta = self.share(of: (230, 26, 178), in: buffer, rect: .init(x: 0, y: 0, width: 0.5, height: 1))
            let green = self.share(of: (26, 204, 51), in: buffer, rect: .init(x: 0.15, y: 0.3, width: 0.2, height: 0.4))
            stats.withLock { afterMark += 1; if magenta >= 0.01 { staleMagenta += 1 }; if green > 0.9 { greenSeen = true } }
        }
        engine.handle(type: WireMessage.workspaceRequest, message: ["tiles": [
            ["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "window": green.windowNumber, "gen": gGen],
            ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "window": green.windowNumber, "gen": gGen, "rotation": 90],
        ] as [[String: Any]]], inputGranted: false)
        XCTAssertTrue(waitUntil(5) { stats.withLock { greenSeen } }, "tile a switches to green")
        stats.withLock {
            XCTAssertGreaterThan(afterMark, 0)
            XCTAssertEqual(staleMagenta, 0, "a stale magenta frame leaked into the replaced tile")
        }

        // A stale generation is refused, not retargeted.
        engine.handle(type: WireMessage.workspaceRequest, message: ["tiles": [
            ["id": "c", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "window": magenta.windowNumber, "gen": mGen + 1000],
        ] as [[String: Any]]], inputGranted: false)
        XCTAssertTrue(waitUntil(3) { (box.last(WireMessage.workspaceState)?["rejected"] as? [String: String])?["c"] == "unavailable" })
    }
}
