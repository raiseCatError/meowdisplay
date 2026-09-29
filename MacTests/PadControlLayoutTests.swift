import CoreGraphics
import XCTest

/// Receiver defaults (schema 16), iPad Strip/Overlay geometry, control
/// scale, display-aware backdrop, Custom layouts, radial palettes and
/// Two-Hand Assist — all pure policy, no UIKit.
final class PadControlLayoutTests: XCTestCase {
    private let container = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let metrics = PadControlMetrics()

    // MARK: - Defaults and migration

    func testNewInstallDefaults() {
        let preferences = ReceiverControlPreferences()
        XCTAssertTrue(preferences.smartTouchEnabled)
        XCTAssertTrue(preferences.autoHideEnabled)
        XCTAssertEqual(preferences.pinchTarget, .viewport)
        XCTAssertEqual(preferences.rotateTarget, .disabled)
        XCTAssertTrue(preferences.preferMeowDisplayGestures)
        XCTAssertEqual(preferences.padControlLayout, .strip)
        XCTAssertTrue(preferences.padShowControlHints)
        XCTAssertEqual(preferences.padControlScale, 1)
        XCTAssertTrue(preferences.customLayouts.isEmpty, "no empty Custom layouts are pre-created")
        XCTAssertFalse(preferences.audioPreferred, "audio stays opt-in")
        XCTAssertTrue(preferences.allowInput)
    }

    func testSchema15InstallMigratesOnceToTheNewDefaults() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReceiverControlPreferences()
        old.version = 15
        old.smartTouchEnabled = false
        old.autoHideEnabled = false
        old.pinchTarget = .app
        old.rotateTarget = .viewport
        old.inputMode = .trackpad
        old.hapticsEnabled = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["preferMeowDisplayGestures", "padControlLayout", "padMainEdge", "padFunctionEdge",
                    "padShowControlHints", "padControlScale", "customLayouts"] {
            json.removeValue(forKey: key)
        }
        defaults.set(try JSONSerialization.data(withJSONObject: json),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let loaded = repository.load()
        XCTAssertEqual(loaded.version, 16)
        XCTAssertTrue(loaded.smartTouchEnabled)
        XCTAssertTrue(loaded.autoHideEnabled)
        XCTAssertEqual(loaded.pinchTarget, .viewport)
        XCTAssertEqual(loaded.rotateTarget, .disabled)
        XCTAssertTrue(loaded.preferMeowDisplayGestures)
        XCTAssertEqual(loaded.padControlLayout, .strip)
        XCTAssertEqual(loaded.inputMode, .trackpad, "unrelated choices survive")
        XCTAssertFalse(loaded.hapticsEnabled, "unrelated choices survive")
    }

    func testChoicesSavedUnderSchema16AreNeverRemigrated() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        var chosen = repository.load()
        chosen.smartTouchEnabled = false
        chosen.autoHideEnabled = false
        chosen.pinchTarget = .app
        chosen.rotateTarget = .viewport
        chosen.preferMeowDisplayGestures = false
        chosen.padControlLayout = .overlay
        repository.save(chosen)
        let reloaded = repository.load()
        XCTAssertFalse(reloaded.smartTouchEnabled)
        XCTAssertFalse(reloaded.autoHideEnabled)
        XCTAssertEqual(reloaded.pinchTarget, .app)
        XCTAssertEqual(reloaded.rotateTarget, .viewport)
        XCTAssertFalse(reloaded.preferMeowDisplayGestures)
        XCTAssertEqual(reloaded.padControlLayout, .overlay)
    }

    func testPersistedControlScaleIsClampedOnLoad() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ReceiverControlPreferences())) as? [String: Any])
        json["padControlScale"] = 9.0
        defaults.set(try JSONSerialization.data(withJSONObject: json),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)
        XCTAssertEqual(repository.load().padControlScale, PadControlScale.range.upperBound)
    }

    func testAnUnreadableCustomLayoutIsDroppedWithoutResettingPreferences() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = false
        preferences.createCustomLayout(id: "keep")
        preferences.createCustomLayout(id: "future")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preferences)) as? [String: Any])
        var layouts = try XCTUnwrap(json["customLayouts"] as? [[String: Any]])
        layouts[1]["landscape"] = "not an arrangement"
        json["customLayouts"] = layouts
        defaults.set(try JSONSerialization.data(withJSONObject: json),
                     forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let loaded = repository.load()
        XCTAssertEqual(loaded.customLayouts.map(\.id), ["keep"])
        XCTAssertFalse(loaded.hapticsEnabled)
    }

    func testAnUnknownControlKindDropsOnlyThatPlacement() throws {
        let json = """
        {"corner":"bottomLeading","placements":[
          {"id":"a","kind":{"kind":"tray","value":"command"},"x":0.1,"y":0.9,"size":1},
          {"id":"b","kind":{"kind":"hologram"},"x":0.2,"y":0.9,"size":1}
        ]}
        """
        let arrangement = try JSONDecoder().decode(CustomControlArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(arrangement.corner, .bottomLeading)
        XCTAssertEqual(arrangement.placements.map(\.id), ["a"])
    }

    // MARK: - Control scale

    func testControlScaleIsBoundedWithAClearDefault() {
        XCTAssertEqual(PadControlScale.defaultValue, 1)
        XCTAssertTrue(PadControlScale.range.contains(1))
        XCTAssertEqual(PadControlScale.clamped(0.1), PadControlScale.range.lowerBound)
        XCTAssertEqual(PadControlScale.clamped(5), PadControlScale.range.upperBound)
        XCTAssertEqual(PadControlScale.clamped(.nan), 1)
        XCTAssertEqual(PadControlScale.clamped(1.2), 1.2)
        // Never an impractically small hit target.
        XCTAssertGreaterThanOrEqual(PadControlMetrics(scale: 0).item, 37)
        XCTAssertLessThanOrEqual(PadControlMetrics(scale: 99).item, 62)
    }

    // MARK: - Strip / Overlay geometry

    func testStripReservesARailAndCentersTheMainControls() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: true,
                                            mainEdge: .trailing, functionEdge: .trailing,
                                            mainCount: 9, functionGroupCounts: [2, 2], metrics: metrics)
        XCTAssertEqual(layout.strips.map(\.edge), [.trailing])
        let strip = try XCTUnwrap(layout.strips.first).frame
        XCTAssertEqual(strip, CGRect(x: 1130, y: 0, width: 64, height: 834))
        XCTAssertEqual(layout.canvas, CGRect(x: 0, y: 0, width: 1130, height: 834))
        let main = try XCTUnwrap(layout.mainFrame)
        XCTAssertEqual(main.midY, container.midY, accuracy: 0.5)
        XCTAssertEqual(main.midX, strip.midX, accuracy: 0.5)
        XCTAssertTrue(strip.contains(main))
    }

    func testStripOnEachEdgeKeepsTheCanvasBesideIt() {
        for edge in ControlEdge.allCases {
            let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: true,
                                                mainEdge: edge, functionEdge: edge,
                                                mainCount: 6, functionGroupCounts: [2], metrics: metrics)
            XCTAssertEqual(layout.strips.count, 1, "\(edge)")
            let strip = layout.strips[0].frame
            XCTAssertFalse(strip.intersects(layout.canvas), "\(edge)")
            XCTAssertEqual(strip.union(layout.canvas), container, "\(edge)")
            if let main = layout.mainFrame {
                XCTAssertTrue(strip.contains(main), "\(edge)")
                if edge.stacksVertically {
                    XCTAssertEqual(main.midY, container.midY, accuracy: 0.5)
                } else {
                    XCTAssertEqual(main.midX, container.midX, accuracy: 0.5)
                }
            } else {
                XCTFail("missing main frame on \(edge)")
            }
        }
    }

    func testStripIncludesTheSafeInsetButKeepsControlsClearOfIt() throws {
        let safe = ControlSafeInsets(top: 0, leading: 0, bottom: 20, trailing: 0)
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: safe, reservesStrips: true,
                                            mainEdge: .bottom, functionEdge: .bottom,
                                            mainCount: 6, functionGroupCounts: [], metrics: metrics)
        let strip = try XCTUnwrap(layout.strips.first).frame
        XCTAssertEqual(strip.maxY, container.maxY)
        XCTAssertEqual(strip.height, metrics.stripThickness(on: .bottom) + 20)
        XCTAssertLessThanOrEqual(try XCTUnwrap(layout.mainFrame).maxY, container.maxY - 20)
    }

    func testOverlayUsesTheWholeCanvas() {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: false,
                                            mainEdge: .leading, functionEdge: .trailing,
                                            mainCount: 9, functionGroupCounts: [2, 2], metrics: metrics)
        XCTAssertTrue(layout.strips.isEmpty)
        XCTAssertEqual(layout.canvas, container)
    }

    func testFunctionGroupsSplitTowardTopAndBottomOnAVerticalEdge() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: false,
                                            mainEdge: .trailing, functionEdge: .trailing,
                                            mainCount: 9, functionGroupCounts: [2, 2], metrics: metrics)
        let main = try XCTUnwrap(layout.mainFrame)
        XCTAssertEqual(layout.functionFrames.count, 2)
        XCTAssertLessThanOrEqual(layout.functionFrames[0].maxY, main.minY - metrics.groupGap + 0.5)
        XCTAssertGreaterThanOrEqual(layout.functionFrames[1].minY, main.maxY + metrics.groupGap - 0.5)
        for frame in layout.functionFrames {
            XCTAssertEqual(frame.midX, main.midX, accuracy: 0.5)
            XCTAssertFalse(frame.intersects(main))
        }
    }

    func testFunctionGroupsSplitTowardLeftAndRightOnAHorizontalEdge() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: true,
                                            mainEdge: .bottom, functionEdge: .bottom,
                                            mainCount: 9, functionGroupCounts: [2, 2, 2], metrics: metrics)
        let main = try XCTUnwrap(layout.mainFrame)
        XCTAssertEqual(layout.functionFrames.count, 3)
        XCTAssertLessThan(layout.functionFrames[0].maxX, layout.functionFrames[1].minX)
        XCTAssertLessThan(layout.functionFrames[1].maxX, main.minX)
        XCTAssertGreaterThan(layout.functionFrames[2].minX, main.maxX)
        for frame in layout.functionFrames {
            XCTAssertEqual(frame.midY, main.midY, accuracy: 0.5)
        }
    }

    func testMainAndFunctionEdgesAreIndependent() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: true,
                                            mainEdge: .trailing, functionEdge: .leading,
                                            mainCount: 9, functionGroupCounts: [2, 2], metrics: metrics)
        XCTAssertEqual(Set(layout.strips.map(\.edge)), [.leading, .trailing])
        XCTAssertEqual(layout.canvas.minX, 64)
        XCTAssertEqual(layout.canvas.maxX, 1130)
        let leadingStrip = try XCTUnwrap(layout.strips.first { $0.edge == .leading }).frame
        // Split to the two ends of the other edge, away from the center.
        XCTAssertTrue(leadingStrip.contains(layout.functionFrames[0]))
        XCTAssertTrue(leadingStrip.contains(layout.functionFrames[1]))
        XCTAssertLessThan(layout.functionFrames[0].maxY, container.midY)
        XCTAssertGreaterThan(layout.functionFrames[1].minY, container.midY)
    }

    func testPerpendicularEdgesDoNotCollideAtTheirSharedCorner() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: false,
                                            mainEdge: .bottom, functionEdge: .trailing,
                                            mainCount: 14, functionGroupCounts: [3, 3], metrics: metrics)
        let main = try XCTUnwrap(layout.mainFrame)
        for frame in layout.functionFrames { XCTAssertFalse(frame.intersects(main)) }
    }

    func testBottomControlsRiseAboveTheKeyboard() throws {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: false,
                                            mainEdge: .bottom, functionEdge: .trailing,
                                            mainCount: 6, functionGroupCounts: [2, 2], metrics: metrics,
                                            keyboardTop: 500)
        XCTAssertLessThanOrEqual(try XCTUnwrap(layout.mainFrame).maxY, 500)
        for frame in layout.functionFrames { XCTAssertLessThanOrEqual(frame.maxY, 500) }
    }

    func testHiddenControlsReserveNoStrip() {
        let layout = PadEdgeGeometry.layout(container: container, safeInsets: .zero, reservesStrips: true,
                                            mainEdge: .trailing, functionEdge: .leading,
                                            mainCount: 0, functionGroupCounts: [], metrics: metrics)
        XCTAssertTrue(layout.strips.isEmpty)
        XCTAssertEqual(layout.canvas, container)
        XCTAssertNil(layout.mainFrame)
    }

    func testHintsWidenTheStrip() {
        let hinted = PadControlMetrics(showsHints: true)
        XCTAssertGreaterThan(hinted.stripThickness(on: .trailing), metrics.stripThickness(on: .trailing))
        XCTAssertGreaterThan(hinted.stripThickness(on: .bottom), metrics.stripThickness(on: .bottom))
    }

    func testPaletteOpensTowardTheCanvasAndStaysInside() {
        let anchor = CGRect(x: 1140, y: 187, width: 44, height: 460)
        let bounds = CGRect(x: 12, y: 12, width: 1130, height: 810)
        let frame = PadEdgeGeometry.paletteFrame(size: CGSize(width: 44, height: 300), anchor: anchor,
                                                 edge: .trailing, bounds: bounds, gap: 8)
        XCTAssertEqual(frame.maxX, 1132)
        XCTAssertEqual(frame.midY, anchor.midY, accuracy: 0.5)
        XCTAssertTrue(bounds.contains(frame))
    }

    func testPaletteGridWrapsIntoMoreColumnsWhenAColumnWouldOverflow() {
        let grid = PadEdgeGeometry.paletteGrid(count: 12, key: CGSize(width: 40, height: 40), gap: 5,
                                               edge: .trailing, available: CGSize(width: 900, height: 300))
        XCTAssertEqual(grid.rows, 6)
        XCTAssertEqual(grid.columns, 2)
        XCTAssertLessThanOrEqual(grid.size.height, 300)
    }

    func testAutoHideNeverAppliesToTheIPadStrip() {
        XCTAssertFalse(ControlAutoHidePolicy.applies(isPad: true, layout: .strip))
        XCTAssertTrue(ControlAutoHidePolicy.applies(isPad: true, layout: .overlay))
        XCTAssertTrue(ControlAutoHidePolicy.applies(isPad: true, layout: .custom))
        XCTAssertTrue(ControlAutoHidePolicy.applies(isPad: false, layout: .strip))
    }

    // MARK: - Display-aware backdrop

    private func footprint(rotation: CGFloat = 0, origin: CGPoint = .zero) -> DisplayFootprint {
        let base = RemoteViewportCalculator.normal(viewBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                                   remoteAspectSize: CGSize(width: 16, height: 9))
        let transform = RemoteViewportTransform(remoteCrop: base.remoteCrop, displayedRect: base.displayedRect,
                                                rotationRadians: rotation)
        return DisplayFootprint(transform: transform, surfaceOrigin: origin,
                                surfaceSize: CGSize(width: 1000, height: 1000))
    }

    func testControlOverTheRenderedDisplayGetsAFullHalo() {
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 100, y: 400, width: 44, height: 44),
                                                          footprint: footprint()), 1)
    }

    func testControlOverLetterboxingGetsNoHalo() {
        // The 16:9 picture spans y 218.75...781.25; y 50 is the black bar.
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 100, y: 50, width: 44, height: 44),
                                                          footprint: footprint()), 0)
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 100, y: 400, width: 44, height: 44),
                                                          footprint: .none), 0)
    }

    func testPartialOverlapScalesTheHalo() {
        let coverage = ControlBackdropPolicy.coverage(of: CGRect(x: 100, y: 196.75, width: 44, height: 44),
                                                      footprint: footprint())
        XCTAssertEqual(coverage, 0.6, accuracy: 0.001)
        let strength = ControlBackdropPolicy.haloStrength(coverage: coverage)
        XCTAssertEqual(strength, 1)
        let sliver = ControlBackdropPolicy.haloStrength(coverage: 0.2)
        XCTAssertGreaterThan(sliver, 0)
        XCTAssertLessThan(sliver, 1)
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(coverage: 0.02), 0)
    }

    func testBackdropFollowsRotationAndTheSurfaceOrigin() {
        let rotated = footprint(rotation: .pi / 2)
        // Rotated a quarter turn, the picture covers the top of the view
        // and no longer covers the left edge.
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 480, y: 60, width: 40, height: 40),
                                                          footprint: rotated), 1)
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 40, y: 480, width: 40, height: 40),
                                                          footprint: rotated), 0)
        // A Strip on the left shifts the surface; overlay coordinates follow.
        let shifted = footprint(origin: CGPoint(x: 64, y: 0))
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 20, y: 400, width: 40, height: 40),
                                                          footprint: shifted), 0)
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 90, y: 400, width: 40, height: 40),
                                                          footprint: shifted), 1)
    }

    func testBackdropFollowsZoomAndPan() {
        let base = RemoteViewportCalculator.normal(viewBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                                   remoteAspectSize: CGSize(width: 16, height: 9))
        let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: ManualViewportState(scale: 2))
        let print = DisplayFootprint(transform: zoomed, surfaceOrigin: .zero,
                                     surfaceSize: CGSize(width: 1000, height: 1000))
        // Zoomed 2x, the picture now fills what was the letterbox bar.
        XCTAssertEqual(ControlBackdropPolicy.haloStrength(for: CGRect(x: 100, y: 50, width: 44, height: 44),
                                                          footprint: print), 1)
    }

    // MARK: - Custom layouts

    func testAtMostFiveCustomLayouts() {
        var preferences = ReceiverControlPreferences()
        for index in 0..<5 {
            XCTAssertTrue(preferences.canCreateCustomLayout)
            XCTAssertNotNil(preferences.createCustomLayout(id: "layout-\(index)"))
        }
        XCTAssertFalse(preferences.canCreateCustomLayout)
        XCTAssertNil(preferences.createCustomLayout())
        XCTAssertEqual(preferences.customLayouts.count, 5)
        XCTAssertEqual(Set(preferences.customLayouts.map(\.name)).count, 5, "names are unique")
    }

    func testCreateRenameAndDeleteCustomLayouts() throws {
        var preferences = ReceiverControlPreferences()
        preferences.padControlLayout = .custom
        let first = try XCTUnwrap(preferences.createCustomLayout(id: "a"))
        let second = try XCTUnwrap(preferences.createCustomLayout(id: "b"))
        XCTAssertEqual(preferences.activeCustomLayout?.id, second, "a new layout becomes active")
        preferences.renameCustomLayout(first, to: "  Drawing  ")
        XCTAssertEqual(preferences.customLayouts.first?.name, "Drawing")
        preferences.renameCustomLayout(first, to: "   ")
        XCTAssertEqual(preferences.customLayouts.first?.name, "Drawing", "blank names are ignored")
        preferences.deleteCustomLayout(second)
        XCTAssertEqual(preferences.activeCustomLayout?.id, first)
        XCTAssertEqual(preferences.padControlLayout, .custom)
        preferences.deleteCustomLayout(first)
        XCTAssertNil(preferences.activeCustomLayout)
        XCTAssertEqual(preferences.padControlLayout, .overlay, "Custom with nothing to show falls back")
    }

    func testPortraitAndLandscapeLayoutsAreIndependent() throws {
        var layout = CustomControlLayout.radialTemplate(name: "Test")
        var portrait = layout.arrangement(portrait: true)
        portrait.placements[0].x = 0.5
        portrait.placements.removeLast()
        let landscapeBefore = layout.arrangement(portrait: false)
        layout.setArrangement(portrait, portrait: true)
        XCTAssertEqual(layout.arrangement(portrait: false), landscapeBefore)
        XCTAssertEqual(layout.arrangement(portrait: true), portrait)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(CustomControlLayout.self, from: data), layout)
    }

    func testPlacementsStayNormalizedAndBounded() {
        let placement = CustomControlPlacement(kind: .tray(.escape), x: 1.7, y: -3, size: 9)
        XCTAssertEqual(placement.x, 1)
        XCTAssertEqual(placement.y, 0)
        XCTAssertEqual(placement.size, CustomControlPlacement.sizeRange.upperBound)
        let area = CustomLayoutGeometry.layoutArea(container: container,
                                                   safeInsets: ControlSafeInsets(top: 24, leading: 0,
                                                                                 bottom: 20, trailing: 0))
        let frame = CustomLayoutGeometry.frame(for: placement, in: area, baseDiameter: 44)
        XCTAssertTrue(area.contains(frame), "clamped clear of the Home indicator and edges")
        XCTAssertLessThanOrEqual(frame.maxY, container.maxY - 20)
        let normalized = CustomLayoutGeometry.normalizedPoint(for: CGPoint(x: -50, y: area.midY), in: area)
        XCTAssertEqual(normalized.x, 0)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    func testAlignmentSnapOnlyNearAGridLine() {
        XCTAssertEqual(CustomLayoutGeometry.snapped(0.505), 0.5)
        XCTAssertEqual(CustomLayoutGeometry.snapped(0.52), 0.52)
    }

    func testRadialTemplateClustersAroundEachCornerWithoutOverlap() {
        for corner in ControlCorner.allCases {
            for portrait in [false, true] {
                let arrangement = CustomControlArrangement.radialTemplate(corner: corner, portrait: portrait)
                let reference = portrait ? CustomControlArrangement.referencePortrait
                    : CustomControlArrangement.referenceLandscape
                XCTAssertEqual(arrangement.corner, corner)
                let points = arrangement.placements.map {
                    (CGPoint(x: $0.x * reference.width, y: $0.y * reference.height), 44 * $0.size)
                }
                for i in points.indices {
                    for j in points.indices where j > i {
                        let d = hypot(points[i].0.x - points[j].0.x, points[i].0.y - points[j].0.y)
                        XCTAssertGreaterThanOrEqual(d, (points[i].1 + points[j].1) / 2,
                                                    "\(corner) portrait=\(portrait) \(i)/\(j)")
                    }
                }
                // Settings sits closest to the corner.
                let cornerPoint = CGPoint(x: corner.unitPoint.x * reference.width,
                                          y: corner.unitPoint.y * reference.height)
                let nearest = arrangement.placements.min {
                    hypot($0.x * reference.width - cornerPoint.x, $0.y * reference.height - cornerPoint.y)
                        < hypot($1.x * reference.width - cornerPoint.x, $1.y * reference.height - cornerPoint.y)
                }
                XCTAssertEqual(nearest?.kind, .tray(.settings))
                XCTAssertEqual(Set(ControlModifier.allCases), Set(arrangement.placements.compactMap(\.kind.modifier)))
                // The whole constellation stays in the corner's quadrant.
                for placement in arrangement.placements {
                    XCTAssertEqual(placement.x < 0.5, corner.isLeading)
                    XCTAssertEqual(placement.y < 0.5, corner.isTop)
                }
            }
        }
    }

    // MARK: - Radial palettes

    func testArcKeysAreEvenlySpacedAndFanTowardTheDirection() {
        let center = CGPoint(x: 1000, y: 700)
        let direction = RadialPaletteLayout.direction(from: center, toward: CGPoint(x: 597, y: 417))
        let points = RadialPaletteLayout.points(count: 5, center: center, shape: .arc, itemDiameter: 44,
                                                spacing: 6, minimumRadius: 110, direction: direction,
                                                bounds: container)
        XCTAssertEqual(points.count, 5)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 50 - 0.01)
        }
        for point in points {
            XCTAssertEqual(hypot(point.x - center.x, point.y - center.y), 110, accuracy: 0.01)
            XCTAssertLessThan(point.x, center.x + 1, "fans toward the screen, away from the corner")
        }
        let middle = points[2]
        XCTAssertEqual(atan2(middle.y - center.y, middle.x - center.x), direction, accuracy: 0.001)
    }

    func testLongArcsContinueOnALargerArc() {
        let points = RadialPaletteLayout.points(count: 12, center: CGPoint(x: 600, y: 400), shape: .arc,
                                                itemDiameter: 44, spacing: 6, minimumRadius: 80,
                                                direction: -.pi / 2, bounds: container)
        let radii = Set(points.map { Int(hypot($0.x - 600, $0.y - 400).rounded()) })
        XCTAssertGreaterThan(radii.count, 1)
        for i in points.indices {
            for j in points.indices where j > i {
                XCTAssertGreaterThanOrEqual(hypot(points[i].x - points[j].x, points[i].y - points[j].y), 44)
            }
        }
    }

    func testRingRowAndColumnShapes() {
        let center = CGPoint(x: 600, y: 400)
        let ring = RadialPaletteLayout.points(count: 8, center: center, shape: .ring, itemDiameter: 44,
                                              spacing: 6, minimumRadius: 44, direction: 0, bounds: container)
        for (a, b) in zip(ring, ring.dropFirst() + [ring[0]]) {
            XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 50 - 0.01)
        }
        let row = RadialPaletteLayout.points(count: 3, center: center, shape: .row, itemDiameter: 44,
                                             spacing: 6, minimumRadius: 60, direction: -.pi / 2, bounds: container)
        XCTAssertEqual(Set(row.map { $0.y }), [340])
        XCTAssertEqual(row.map { $0.x }, [550, 600, 650])
        let column = RadialPaletteLayout.points(count: 3, center: center, shape: .column, itemDiameter: 44,
                                                spacing: 6, minimumRadius: 60, direction: .pi, bounds: container)
        XCTAssertEqual(Set(column.map { $0.x }), [540])
    }

    func testPaletteGrowsOutwardPastOtherControls() {
        let center = CGPoint(x: 600, y: 400)
        let blocker = CGRect(x: 578, y: 278, width: 44, height: 44)   // straight up at radius 100
        let points = RadialPaletteLayout.points(count: 3, center: center, shape: .arc, itemDiameter: 44,
                                                spacing: 6, minimumRadius: 100, direction: -.pi / 2,
                                                bounds: container, obstacles: [blocker])
        for point in points {
            XCTAssertFalse(blocker.insetBy(dx: -22, dy: -22).contains(point))
        }
    }

    func testPaletteKeysStayOnScreen() {
        let points = RadialPaletteLayout.points(count: 6, center: CGPoint(x: 20, y: 20), shape: .ring,
                                                itemDiameter: 44, spacing: 6, minimumRadius: 60,
                                                direction: 0, bounds: container)
        for point in points {
            XCTAssertTrue(container.insetBy(dx: 21.9, dy: 21.9).contains(point))
        }
    }

    // MARK: - Two-Hand Assist

    func testAssistProjectsTheSharedChordState() {
        var interaction = ControlInteractionState()
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction), .idle)
        XCTAssertEqual(TwoHandAssist.state(enabled: false, interaction: interaction), .hidden)
        interaction.press(.command)
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction), .helper(active: [.command]))
    }

    func testHelperModifierJoinsTheHeldChord() {
        var interaction = ControlInteractionState()
        interaction.press(.command)
        let effects = interaction.toggleAssistModifier(.option)
        XCTAssertTrue(effects.contains(.modifierDown(.command)))
        XCTAssertTrue(effects.contains(.modifierDown(.option)))
        XCTAssertEqual(interaction.activeChord, ModifierChord([.command, .option]))
        XCTAssertEqual(interaction.paletteChord, ModifierChord([.command, .option]),
                       "the primary palette updates to the combined chord")
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction),
                       .helper(active: [.command, .option]))
        // Tapping it again on the helper removes it again.
        _ = interaction.toggleAssistModifier(.option)
        XCTAssertEqual(interaction.activeChord, ModifierChord([.command]))
        _ = interaction.toggleAssistModifier(.shift)
        // Releasing the hold (executing a shortcut) releases everything, and
        // the idle Function actions come back.
        let action = ShortcutItem(title: "Redo", displayKey: "Z", usage: 29,
                                  modifiers: ModifierChord([.command, .shift]))
        let release = interaction.finish(with: action)
        XCTAssertTrue(release.contains(.execute(action)))
        XCTAssertTrue(release.contains(.modifierUp(.command)))
        XCTAssertTrue(release.contains(.modifierUp(.shift)))
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction), .idle)
    }

    func testHelperModifierLatchesAlongsideALatchedChord() {
        var interaction = ControlInteractionState()
        _ = interaction.tap(.command)
        _ = interaction.toggleAssistModifier(.option)
        XCTAssertEqual(interaction.latchedModifiers, [.command, .option])
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction),
                       .helper(active: [.command, .option]))
        _ = interaction.resetAll()
        XCTAssertEqual(TwoHandAssist.state(enabled: true, interaction: interaction), .idle)
    }

    func testHelperAppearsOnTheOppositeSide() {
        XCTAssertEqual(TwoHandAssist.helperAnchor(clusterCentroid: CGPoint(x: 0.875, y: 0.75)),
                       CGPoint(x: 0.125, y: 0.75))
        XCTAssertEqual(TwoHandAssist.helperAnchor(clusterCentroid: CGPoint(x: 0.1, y: 0.2)),
                       CGPoint(x: 0.9, y: 0.2))
        XCTAssertEqual(TwoHandAssist.helperAnchor(clusterCentroid: CGPoint(x: 0.5, y: 0.875)),
                       CGPoint(x: 0.5, y: 0.125), "a bottom-centered cluster mirrors to the top")
        let area = CGRect(x: 12, y: 12, width: 1170, height: 810)
        let points = TwoHandAssist.helperPoints(count: 4, clusterCentroid: CGPoint(x: 0.9, y: 0.9), area: area,
                                                itemDiameter: 44, spacing: 6)
        XCTAssertEqual(points.count, 4)
        for point in points {
            XCTAssertLessThan(point.x, area.midX)
            XCTAssertGreaterThan(point.y, area.midY)
            XCTAssertTrue(area.contains(point))
        }
    }

    func testTemplateEnablesTwoHandAssistWithIdleFunctionActions() {
        let layout = CustomControlLayout.radialTemplate(name: "Test", corner: .bottomLeading)
        XCTAssertTrue(layout.twoHandAssist)
        XCTAssertEqual(layout.assistActionIDs, ["undo", "redo", "zoom-in", "zoom-out"])
        let canonicalIDs = Set(FunctionTrayProfile.canonical().items.map(\.id))
        XCTAssertTrue(Set(layout.assistActionIDs).isSubset(of: canonicalIDs),
                      "idle actions reuse existing Function Tray items")
        XCTAssertLessThan(layout.landscape.clusterCentroid.x, 0.5)
    }

    // MARK: - Gesture preference

    func testPreferMeowDisplayGesturesControlsEdgeDeferral() {
        XCTAssertTrue(ReceiverScreenEdgePolicy.defersScreenEdges(surfaceShown: true, inputAllowed: true,
                                                                 preferMeowDisplayGestures: true))
        XCTAssertFalse(ReceiverScreenEdgePolicy.defersScreenEdges(surfaceShown: true, inputAllowed: true,
                                                                  preferMeowDisplayGestures: false))
        XCTAssertTrue(ReceiverEditingInteractionPolicy.suppressesEditingInteractions(preferMeowDisplayGestures: true))
        XCTAssertFalse(ReceiverEditingInteractionPolicy.suppressesEditingInteractions(preferMeowDisplayGestures: false))
    }

    func testVoiceOverAlwaysWins() {
        XCTAssertFalse(ReceiverScreenEdgePolicy.defersScreenEdges(surfaceShown: true, inputAllowed: true,
                                                                  preferMeowDisplayGestures: true,
                                                                  voiceOverRunning: true))
        var gate = ReceiverMultiFingerGestureGate(voiceOverRunning: true)
        XCTAssertFalse(gate.recognizersEnabled)
        _ = gate.update(viewportNavigationActive: false)
        XCTAssertFalse(gate.recognizersEnabled, "no preference or mode re-enables them under VoiceOver")
    }

    func testMoveViewParksTheMultiFingerRecognizers() {
        var gate = ReceiverMultiFingerGestureGate(voiceOverRunning: false)
        XCTAssertTrue(gate.update(viewportNavigationActive: true))
        for kind in ReceiverMultiFingerRecognizer.allCases { XCTAssertFalse(gate.isEnabled(kind)) }
        XCTAssertFalse(gate.update(viewportNavigationActive: true))
        XCTAssertTrue(gate.update(viewportNavigationActive: false))
        XCTAssertTrue(gate.recognizersEnabled)
    }

    // MARK: - Settings

    func testSettingsCategoriesAreSharedByBothSizeClasses() {
        XCTAssertFalse(MobileSettingsCategory.visible(debug: false).contains(.developer))
        XCTAssertTrue(MobileSettingsCategory.visible(debug: true).contains(.developer))
        XCTAssertEqual(MobileSettingsCategory.initialSelection(regularWidth: true), .general)
        XCTAssertNil(MobileSettingsCategory.initialSelection(regularWidth: false))
        let ids = MobileSettingsCategory.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for category in MobileSettingsCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }

    func testIPadOnlyControlSettingsNeverShowOnIPhone() {
        for layout in PadControlLayoutMode.allCases {
            let phone = PadControlSettingsVisibility(isPad: false, layout: layout)
            XCTAssertFalse(phone.showsLayoutPicker)
            XCTAssertFalse(phone.showsControlSize)
            XCTAssertFalse(phone.showsEdgePickers)
            XCTAssertFalse(phone.showsControlHints)
            XCTAssertFalse(phone.showsCustomLayouts)
            XCTAssertTrue(phone.showsPhoneTrayPlacement)
        }
        XCTAssertTrue(PadControlSettingsVisibility(isPad: true, layout: .strip).showsControlHints)
        XCTAssertFalse(PadControlSettingsVisibility(isPad: true, layout: .overlay).showsControlHints)
        XCTAssertFalse(PadControlSettingsVisibility(isPad: true, layout: .custom).showsEdgePickers)
        XCTAssertTrue(PadControlSettingsVisibility(isPad: true, layout: .custom).showsCustomLayouts)
    }

    // MARK: - Helpers

    private func makeRepository() throws -> (ReceiverControlPreferencesRepository, UserDefaults, String) {
        let suite = "PadControlLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ReceiverControlPreferencesRepository(defaults: defaults), defaults, suite)
    }
}
