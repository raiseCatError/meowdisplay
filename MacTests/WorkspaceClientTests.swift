import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The Apple receivers' window-workspace client (Shared/WorkspaceClient.swift).
@MainActor
final class WorkspaceClientTests: XCTestCase {
    private func catalog(_ windows: [(UInt32, UInt64, String)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": Int($0.0), "gen": Int($0.1), "bundle": $0.2, "app": $0.2, "title": "t\($0.0)", "w": 800, "h": 600, "state": "visible"] },
            "apps": [["bundle": "dev.zed.Zed", "name": "Zed", "windows": true]],
        ])!
    }

    private func model(sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let defaults = UserDefaults(suiteName: "WorkspaceClientTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        return m
    }

    func testParsingIsBoundedAndDefensive() {
        let state = WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "tiles": [["id": "a", "window": 10, "gen": 2, "state": "live", "app": "Zed"], ["id": "b", "state": "bogus"], ["window": 3]],
            "active": "a", "hostFocus": "otherWindowFocused", "rejected": ["c": "unavailable", "d": 7],
        ])
        guard case .state(let s)? = state else { return XCTFail("expected state") }
        XCTAssertEqual(s.tiles.map(\.id), ["a", "b"])
        XCTAssertEqual(s.tiles[1].status, .waiting)
        XCTAssertTrue(s.hostFocus.isMismatch)
        XCTAssertEqual(s.rejected, ["c": "unavailable"])
        let huge = String(repeating: "A", count: WorkspaceEvent.maxBase64 + 4)
        guard case .thumbnail(_, _, let data)? = WorkspaceEvent.parse(type: WireMessage.windowThumbnail, ["id": 1, "jpeg": huge]) else {
            return XCTFail("expected thumbnail")
        }
        XCTAssertNil(data, "oversized stills are dropped before decoding")
        XCTAssertNil(WorkspaceEvent.parse(type: WireMessage.appIcon, ["bundle": "x", "png": huge]))
        XCTAssertNil(WorkspaceEvent.parse(type: "somethingElse", [:]))
    }

    func testChoosingAWindowSendsOnlyListedWindowsWithTheirGeneration() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        XCTAssertTrue(m.available)
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
        var requested = false
        m.requestWindowMode = { requested = true }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertFalse(requested, "already in Window mode")
        XCTAssertEqual(m.layout.tiles.count, 1)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        XCTAssertEqual(m.layout.tiles.count, 2)
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        let tiles = request?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(tiles.compactMap { $0["window"] as? Int }.sorted(), [10, 11])
        XCTAssertEqual(tiles.first { $0["window"] as? Int == 10 }?["gen"] as? Int, 5)
        XCTAssertTrue(tiles.allSatisfy { $0["host"] as? String == "mac-a" })

        // Removing a tile never closes a Mac window; closing is its own message.
        sent.removeAll()
        let ids = m.layout.orderedTileIDs
        m.removeTile(ids[1])
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.windowAction })
        m.closeRemoteWindow(ids[0])
        let close = sent.last { $0["type"] as? String == WireMessage.windowAction }
        XCTAssertEqual(close?["action"] as? String, "close")
        XCTAssertEqual(close?["gen"] as? Int, 5)
    }

    /// Stage Peek browsing (hold, scrub, expand, lift) only refreshes the
    /// catalog and thumbnails; the layout and the Mac's windows are untouched.
    /// A tap on a card replaces only the active tile's window.
    func testStagePeekBrowsingChangesNothingAndATapReplacesOnlyTheActiveTile() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.a"), (11, 1, "dev.qa.b"), (12, 1, "dev.qa.c")]))
        m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let ids = m.layout.orderedTileIDs
        XCTAssertEqual(ids.count, 2)
        let state = WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "tiles": [["id": ids[0], "window": 10, "gen": 1, "state": "live"], ["id": ids[1], "window": 11, "gen": 1, "state": "live"]],
            "active": ids[1]])!
        m.apply(state)
        XCTAssertEqual(m.currentWindowID, 11, "Stage Peek starts on the active tile's window")
        let settle = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        let before = m.layout
        sent.removeAll()
        m.stagePeekOpen = true
        m.stagePeekOpen = false
        let browse = expectation(description: "nothing else is sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { browse.fulfill() }
        wait(for: [browse], timeout: 2)
        XCTAssertEqual(m.layout, before)
        XCTAssertFalse(sent.isEmpty, "opening refreshes the catalog")
        XCTAssertTrue(sent.allSatisfy {
            [WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest].contains($0["type"] as? String)
        }, "browsing sends only catalog and thumbnail requests: \(sent.map { $0["type"] ?? "?" })")

        m.switchTo(m.catalog!.windows[2])
        XCTAssertEqual(m.layout.orderedTileIDs, ids, "no tile added or removed")
        XCTAssertEqual(m.layout.tiles[ids[0]]?.source?.windowID, 10, "the other tile keeps its window")
        XCTAssertEqual(m.layout.tiles[ids[1]]?.source?.windowID, 12)
    }

    /// Found on the Moto: with two tiles waiting for windows and none active,
    /// a Stage Peek tap added a third tile. It fills the first waiting one.
    func testStagePeekFillsAWaitingTileInsteadOfAddingOne() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.a"), (11, 1, "dev.qa.b"), (12, 1, "dev.qa.c")]))
        m.updateSpace(WorkspaceSize(width: 390, height: 844), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let ids = m.layout.orderedTileIDs
        // Both windows close on the Mac; nothing is active.
        m.apply(catalog([(12, 1, "dev.qa.c")]))
        XCTAssertEqual(m.missing, Set(ids))
        XCTAssertNil(m.active)
        XCTAssertEqual(m.switchTarget, ids[0])
        m.switchTo(m.catalog!.windows[0])
        XCTAssertEqual(m.layout.orderedTileIDs, ids, "no tile added")
        XCTAssertEqual(m.layout.tiles[ids[0]]?.source?.windowID, 12)
        XCTAssertEqual(m.layout.tiles[ids[1]]?.source?.windowID, 11)
    }

    func testTheSameWindowNumberOnAnotherMacNeverReachesThisMacsTiles() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertEqual(m.layout.tiles.values.compactMap { $0.source?.windowID }, [30])
        // Another Mac, same window number and even the same app: its own (empty) arrangement.
        m.apply(.connected(peerID: "mac-other"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        XCTAssertTrue(m.layout.tiles.values.allSatisfy { $0.source == nil }, "nothing carried over from mac-a")
        // Back on the first Mac, its tile is still there.
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        XCTAssertEqual(m.layout.tiles.values.compactMap { $0.source?.windowID }, [30])
    }

    func testAReconnectKeepsOnlyTheSameWindowOfTheSameApp() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-b"))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.zed.Zed"), (11, 1, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        // New Mac session: window 10 now belongs to another app, 11 is the same Safari window.
        m.apply(catalog([(10, 1, "com.apple.Terminal"), (11, 1, "com.apple.Safari")]))
        let zedTile = m.layout.tiles.first { $0.value.source?.windowID == 10 }?.key
        XCTAssertNotNil(zedTile)
        XCTAssertTrue(m.missing.contains(zedTile!), "a reused id for another app is never retargeted")
        XCTAssertEqual(m.missing.count, 1)
    }

    func testChoosingAWindowForAClosedTileShowsAndSendsIt() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-d"))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.probe")]))
        m.updateSpace(WorkspaceSize(width: 390, height: 844), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        let tile = m.layout.orderedTileIDs[0]
        // The window closes and the app opens a new one.
        m.apply(catalog([(12, 1, "dev.qa.probe")]))
        XCTAssertEqual(m.missing, [tile])
        m.openOverview(replacing: tile)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertTrue(m.missing.isEmpty, "the tile shows its new window, not \"Choose a window\"")
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        XCTAssertEqual((request?["tiles"] as? [[String: Any]])?.compactMap { $0["window"] as? Int }, [12])
    }

    func testOneDividerDragIsOneUndoStepAndTracksTheFinger() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-d"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "a"), (31, 1, "b")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        for w in m.catalog!.windows { m.choose(w, asNewTile: true) }
        let before = m.layout
        let divider = WorkspaceGeometry.frames(for: m.layout, in: WorkspaceSize(width: 1366, height: 1024)).dividers[0]
        for _ in 0..<20 { m.resize(divider, delta: 0.01) }   // one drag, many small steps
        m.endResize()
        let ratio = { (l: WorkspaceLayout) -> Double in
            if case .split(_, _, let ratios) = l.root { return ratios[0] }
            return .nan
        }
        XCTAssertEqual(ratio(m.layout), ratio(before) + 0.2, accuracy: 0.001, "every step of the drag applies")
        m.resize(divider, delta: -0.05)   // a second drag
        m.endResize()
        m.undo()
        XCTAssertEqual(ratio(m.layout), ratio(before) + 0.2, accuracy: 0.001, "undo reverts only the second drag")
        m.undo()
        XCTAssertEqual(m.layout, before, "a second undo reverts the whole first drag")
    }

    func testCompactSpaceStacksTilesAndKeepsThem() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-c"))
        m.apply(.mode(window: true))
        m.apply(catalog((0..<9).map { (UInt32(20 + $0), 1, "app\($0)") }))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        for w in m.catalog!.windows { m.choose(w, asNewTile: true) }
        XCTAssertEqual(m.layout.tiles.count, 9)
        m.updateSpace(WorkspaceSize(width: 360, height: 780), hinge: nil)   // fold to a cover screen
        XCTAssertEqual(m.layout.tiles.count, 3)
        XCTAssertEqual(m.stacked.count, 6)
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        XCTAssertEqual(m.layout.tiles.count, 9, "unfolding brings every tile back")
    }

    func testImagesAreDecodedBoundedOnly() throws {
        // A real 600x400 PNG decodes to at most the requested side.
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let image = try XCTUnwrap(WorkspaceImageDecoder.image(data as Data, maxSide: 128))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128)
        XCTAssertNil(WorkspaceImageDecoder.image(Data("not an image".utf8), maxSide: 128))
    }
}
