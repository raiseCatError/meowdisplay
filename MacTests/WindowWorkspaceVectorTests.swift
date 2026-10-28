import XCTest

/// Cross-platform vectors for the workspace engine: the Swift engine writes
/// fixtures/workspace/vectors.json (WRITE_WORKSPACE_VECTORS=1) and checks it
/// on every run; the Android port checks the same file
/// (AndroidReceiver/core/.../WorkspaceVectorsTest.kt).
final class WindowWorkspaceVectorTests: XCTestCase {
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/workspace/vectors.json")
    }

    private func tiles(_ n: Int) -> [WorkspaceTile] {
        (0..<n).map { WorkspaceTile(id: "t\($0)", source: WorkspaceSource(host: "mac-a", windowID: UInt32(100 + $0))) }
    }

    private func rect(_ r: WorkspaceRect) -> [Double] { [r.x, r.y, r.width, r.height] }

    private func record(_ layout: WorkspaceLayout) -> Any {
        try! JSONSerialization.jsonObject(with: WorkspaceLayoutRecord(layout).encoded()!)
    }

    private func frames(_ layout: WorkspaceLayout, _ size: WorkspaceSize, _ hinge: WorkspaceHinge?) -> [String: Any] {
        let f = WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge)
        return [
            "tiles": f.tiles.mapValues { rect($0) },
            "slots": f.slots.map { rect($0) },
            "dividers": f.dividers.map { ["path": $0.path, "index": $0.index, "axis": $0.axis.rawValue, "hit": rect($0.hitRect)] as [String: Any] },
        ]
    }

    private func hingeJSON(_ h: WorkspaceHinge?) -> Any {
        guard let h else { return NSNull() }
        return ["rect": rect(h.rect), "orientation": h.orientation.rawValue]
    }

    private func buildVectors() -> [String: Any] {
        let sizes: [WorkspaceSize] = [.init(width: 390, height: 844), .init(width: 844, height: 390), .init(width: 1024, height: 1366),
                                      .init(width: 790, height: 820)]
        let hinges: [WorkspaceHinge?] = [nil, .init(rect: .init(x: 0.49, y: 0, width: 0.02, height: 1), orientation: .vertical),
                                         .init(rect: .init(x: 0, y: 0.45, width: 1, height: 0.03), orientation: .horizontal)]
        var layoutCases: [[String: Any]] = []
        for preset in WorkspacePreset.allCases {
            let layout = WorkspaceLayout(preset: preset, tiles: tiles(preset.slotCount))
            for size in sizes {
                for hinge in hinges {
                    layoutCases.append(["name": "\(preset.rawValue)", "layout": record(layout), "size": [size.width, size.height],
                                        "hinge": hingeJSON(hinge), "frames": frames(layout, size, hinge)])
                }
            }
        }
        // Operation results: the same sequence must give the same tree on both platforms.
        let size = WorkspaceSize(width: 1366, height: 1024)
        var opCases: [[String: Any]] = []
        var layout = WorkspaceLayout(preset: .grid3x3, tiles: tiles(9))
        func snap(_ name: String, _ l: WorkspaceLayout) {
            opCases.append(["name": name, "layout": record(l), "frames": frames(l, size, nil)])
        }
        snap("start", layout)
        layout = layout.swapping("t0", "t8"); snap("swap t0 t8", layout)
        layout = layout.moving("t4", to: .split(index: 0, edge: .left, preview: .unit)); snap("move t4 split slot0 left", layout)
        layout = layout.removing("t2"); snap("remove t2", layout)
        let div = WorkspaceGeometry.frames(for: layout, in: size).dividers[0]
        layout = WorkspaceGeometry.resizing(layout, divider: div, delta: 0.07, in: size); snap("resize divider0 +0.07", layout)
        layout = layout.rotating("t1").settingFit(.fill, for: "t3"); snap("rotate t1 fill t3", layout)
        layout = layout.adding(WorkspaceTile(id: "n1"), landscape: true); snap("add n1", layout)
        layout = layout.applying(.grid2x2).layout; snap("apply grid2x2", layout)
        let adapted = WorkspaceAdaptation.adapt(WorkspaceLayout(preset: .grid3x3, tiles: tiles(9)), to: .init(width: 360, height: 780), active: "t7")
        opCases.append(["name": "adapt 9 -> compact active t7", "layout": record(adapted.visible), "stacked": adapted.stacked,
                        "frames": frames(adapted.visible, .init(width: 360, height: 780), nil)])
        // Capacity by usable size.
        var capacities: [[String: Any]] = []
        for s in sizes + [.init(width: 100, height: 80), .init(width: 360, height: 640), .init(width: 320, height: 1024), .init(width: 1366, height: 1024)] {
            for hinge in hinges {
                capacities.append(["size": [s.width, s.height], "hinge": hingeJSON(hinge), "capacity": WorkspaceGeometry.capacity(for: s, hinge: hinge)])
            }
        }
        // Transforms: forward points per rotation and fit.
        var transforms: [[String: Any]] = []
        for rotation in WorkspaceRotation.allCases {
            for fit in [WorkspaceFit.fit, .fill] {
                let t = TileContentTransform(tile: .init(x: 40, y: 20, width: 600, height: 400), source: .init(width: 1600, height: 900),
                                             rotation: rotation, fit: fit)
                let pts: [[Double]] = [[0, 0], [1600, 0], [0, 900], [800, 450], [123, 777]]
                transforms.append(["rotation": rotation.rawValue, "fit": fit.rawValue, "tile": [40, 20, 600, 400], "source": [1600, 900],
                                   "points": pts, "canvas": pts.map { let c = t.canvasPoint(fromSource: .init(x: $0[0], y: $0[1])); return [c.x, c.y] }])
            }
        }
        return ["schema": 1, "layouts": layoutCases, "operations": opCases, "capacities": capacities, "transforms": transforms]
    }

    func testWorkspaceVectorsMatchTheSharedFixture() throws {
        let vectors = buildVectors()
        let data = try JSONSerialization.data(withJSONObject: vectors, options: [.sortedKeys])
        if ProcessInfo.processInfo.environment["WRITE_WORKSPACE_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL)
        }
        let stored = try Data(contentsOf: Self.fixtureURL)
        let a = try JSONSerialization.jsonObject(with: stored) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(a, b, "the engine changed: regenerate with WRITE_WORKSPACE_VECTORS=1 and update the Android port to match")
    }
}
