import CoreGraphics
import XCTest

/// Tucking floats into any edge (Shared/WorkspaceFloats.swift, WINDOW_MODE.md "Tuck it away"):
/// the throw that reaches an edge, the handles (slivers) that give way to the system's edge
/// bands, the fixed controls and Stage Peek's handle, and pulling a tucked float back out.
/// All receiver-local: none of it moves, resizes or brings forward a Mac window.
final class WorkspaceFloatTuckTests: XCTestCase {
    private let ipad = WorkspaceSize(width: 1180, height: 820)
    private let phone = WorkspaceSize(width: 390, height: 844)
    /// A float in the middle of the iPad's picture.
    private let middle = WorkspaceRect(x: 0.29, y: 0.3, width: 0.42, height: 0.4)

    private func decide(_ frame: WorkspaceRect, _ v: (Double, Double), _ size: WorkspaceSize,
                        edges: Set<WorkspaceEdge> = WorkspaceFloatMotion.allEdges) -> WorkspaceFloatMotion.Outcome {
        WorkspaceFloatMotion.decide(release: frame, velocity: (x: v.0, y: v.1), in: size, edges: edges)
    }

    private func isTuck(_ o: WorkspaceFloatMotion.Outcome) -> Bool {
        if case .tuck = o { return true }
        return false
    }

    // MARK: Throws

    /// The projections: a settle glide carries a card's length, the reach a throw is judged by is
    /// UIKit's normal deceleration (WWDC18's picture in picture).
    func testProjectionNumbers() {
        XCTAssertEqual(WorkspaceFloatMotion.projection(1000), 199, accuracy: 0.5)
        XCTAssertEqual(WorkspaceFloatMotion.projection(1000, rate: WorkspaceFloatMotion.reachDecelerationRate), 499, accuracy: 0.5)
        XCTAssertEqual(WorkspaceFloatMotion.projection(-2000, rate: WorkspaceFloatMotion.reachDecelerationRate), -998, accuracy: 0.5)
        XCTAssertEqual(WorkspaceFloatMotion.projection(.nan), 0)
        XCTAssertEqual(WorkspaceFloatMotion.projection(1000, rate: 1), 0, "no rate that never stops")
    }

    /// iPad (1180 x 820): a strong throw from the middle tucks at the edge it reaches, from the
    /// far side too; one that falls short glides and stays inside; a move that isn't a throw
    /// never tucks, however far across the middle it goes.
    func testLongThrowsTuckOnTheIPad() {
        // Centre → right: about 1200 pt/s reaches the right edge.
        XCTAssertEqual(decide(middle, (1500, 0), ipad), .tuck(edge: .right, offset: middle.midY))
        guard case .settle(let short, true) = decide(middle, (1150, 0), ipad) else { return XCTFail("falls short: glides") }
        XCTAssertLessThanOrEqual(short.maxX, 1 + 1e-9, "stays inside")
        XCTAssertGreaterThan(short.x, middle.x)
        XCTAssertFalse(isTuck(decide(middle, (1000, 0), ipad)), "not a throw")

        // Right → left: across the whole picture, about 1800 pt/s.
        let right = WorkspaceRect(x: 0.55, y: 0.3, width: 0.42, height: 0.4)
        XCTAssertEqual(decide(right, (-2500, 0), ipad), .tuck(edge: .left, offset: right.midY))
        guard case .settle(let back, true) = decide(right, (-1500, 0), ipad) else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(back.x, 0, "a quick move that wouldn't reach the far edge stays inside")

        // A slow drag across the middle, let go anywhere inside: never tucks.
        for x in stride(from: 0.0, through: 0.58, by: 0.04) {
            let f = WorkspaceRect(x: x, y: 0.3, width: 0.42, height: 0.4)
            XCTAssertFalse(isTuck(decide(f, (900, 0), ipad)), "x \(x)")
            XCTAssertFalse(isTuck(decide(f, (-900, 0), ipad)), "x \(x)")
        }

        // Up and down: the top and bottom edges take a throw too.
        guard case .tuck(.bottom, let along) = decide(middle, (0, 2000), ipad) else { return XCTFail() }
        XCTAssertEqual(along, middle.midX, accuracy: 1e-9)
        guard case .tuck(.top, _) = decide(middle, (100, -2200), ipad) else { return XCTFail() }

        // Where along the edge: where the path crosses it.
        guard case .tuck(.right, let crossing) = decide(middle, (3000, 600), ipad) else { return XCTFail() }
        XCTAssertGreaterThan(crossing, middle.midY, "carried down a little on its way")
    }

    /// iPhone (390 x 844, a picture-in-picture float near the bottom): a flick sideways tucks
    /// it; up to the top takes a long throw; down into the bottom a short one.
    func testThrowsOnThePhone() {
        let pip = WorkspaceFloatGeometry.defaultFrame(aspect: 1.5, in: phone)
        XCTAssertEqual(pip.midX, 0.5, accuracy: 1e-6)
        guard case .tuck(.right, _) = decide(pip, (1300, 0), phone) else { return XCTFail() }
        guard case .tuck(.left, _) = decide(pip, (-1300, -100), phone) else { return XCTFail() }
        XCTAssertFalse(isTuck(decide(pip, (900, 0), phone)), "not a throw")
        guard case .tuck(.top, _) = decide(pip, (0, -2000), phone) else { return XCTFail("all the way up") }
        guard case .settle(let up, true) = decide(pip, (0, -1300), phone) else { return XCTFail("falls short of the top") }
        XCTAssertLessThan(up.y, pip.y)
        guard case .tuck(.bottom, _) = decide(pip, (0, 1200), phone) else { return XCTFail() }
    }

    /// A throw toward a corner tucks into the edge its path crosses first.
    func testACornerThrowTakesTheEdgeItCrossesFirst() {
        // From the middle, down and right alike: the bottom is nearer.
        guard case .tuck(.bottom, let along) = decide(middle, (2400, 2400), ipad) else { return XCTFail() }
        XCTAssertGreaterThan(along, middle.midX)
        // From near the right edge: the right one.
        let nearRight = WorkspaceRect(x: 0.5, y: 0.3, width: 0.42, height: 0.4)
        guard case .tuck(.right, _) = decide(nearRight, (2400, 2400), ipad) else { return XCTFail() }
        // Up and left from the middle of a phone: the left edge first (the top is far).
        let pip = WorkspaceFloatGeometry.defaultFrame(aspect: 1.5, in: phone)
        guard case .tuck(.left, _) = decide(pip, (-2500, -2500), phone) else { return XCTFail() }
        // An edge with no room for a handle is passed over for the next one on the path.
        guard case .tuck(.right, _) = decide(middle, (2400, 2400), ipad, edges: [.left, .right, .top]) else { return XCTFail() }
        XCTAssertFalse(isTuck(decide(middle, (2400, 2400), ipad, edges: [])))
    }

    /// Pulled more than halfway past the bottom (or any edge) and let go slowly: tucked there;
    /// thrown back in from there: it comes back inside.
    func testPulledPastAnyEdge() {
        let low = WorkspaceRect(x: 0.3, y: 0.9, width: 0.3, height: 0.25)
        XCTAssertEqual(WorkspaceFloatMotion.pulledEdge(low), .bottom)
        XCTAssertEqual(decide(low, (0, 0), ipad), .tuck(edge: .bottom, offset: low.midX))
        guard case .settle(let back, true) = decide(low, (0, -1500), ipad) else { return XCTFail() }
        XCTAssertLessThanOrEqual(back.maxY, 1 + 1e-9)
        XCTAssertNil(WorkspaceFloatMotion.pulledEdge(low, edges: [.left, .right]), "only where it may tuck")
        XCTAssertNil(WorkspaceFloatMotion.pulledEdge(middle))
    }

    // MARK: Let go off-screen

    /// iPhone 14 Pro Max (430 x 932 pt; the Dynamic Island's 59 pt at the top, the Home
    /// indicator's 34 below), its safe area as shares of the picture, portrait and landscape.
    private let proMax = WorkspaceSize(width: 430, height: 932)
    private let proMaxSafe = WorkspaceRect(x: 0, y: 59.0 / 932, width: 1, height: (932.0 - 59 - 34) / 932)
    private let proMaxLandscape = WorkspaceSize(width: 932, height: 430)
    private let proMaxLandscapeSafe = WorkspaceRect(x: 59.0 / 932, y: 24.0 / 430, width: (932.0 - 118) / 932, height: (430.0 - 24 - 21) / 430)

    /// The title pill of a float at `r` (shares of a picture of `size`).
    private func pill(_ r: WorkspaceRect, _ size: WorkspaceSize) -> WorkspaceRect {
        let p = WorkspaceFloatLayering.pillBounds(WorkspaceRect(x: r.x * size.width, y: r.y * size.height,
                                                                width: r.width * size.width, height: r.height * size.height))
        return WorkspaceRect(x: p.x / size.width, y: p.y / size.height, width: p.width / size.width, height: p.height / size.height)
    }

    private func assertComesBackReachable(_ o: WorkspaceFloatMotion.Outcome, _ size: WorkspaceSize, safe: WorkspaceRect, _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard case .settle(let r, let glide) = o else { return XCTFail("\(name): \(o)", file: file, line: line) }
        XCTAssertTrue(glide, "\(name): glides back from where it was let go", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.x, -1e-9, name, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, 1 + 1e-9, name, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, 1 + 1e-9, name, file: file, line: line)
        let p = pill(r, size)
        XCTAssertGreaterThanOrEqual(p.y, safe.y - 1e-9, "\(name): its title pill clear of the top", file: file, line: line)
        XCTAssertLessThanOrEqual(p.maxY, safe.maxY + 1e-9, "\(name): and of the bottom", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.x, safe.x - 1e-9, "\(name): and of the sides", file: file, line: line)
        XCTAssertLessThanOrEqual(p.maxX, safe.maxX + 1e-9, name, file: file, line: line)
    }

    /// A float held partly off-screen past any edge or a corner and let go: more than halfway
    /// past, it tucks into that edge (in a corner, the one more of it is past); less, it glides
    /// back to where its title pill can be reached, clear of the Dynamic Island, the Home indicator
    /// and a landscape notch. Only where it rests is kept reachable: the finger may hold it anywhere.
    func testLettingGoOffScreenTucksOrComesBackReachable() {
        for (size, safe) in [(proMax, proMaxSafe), (proMaxLandscape, proMaxLandscapeSafe)] {
            let w = 240 / size.width, h = 160 / size.height
            func at(_ x: Double, _ y: Double) -> WorkspaceRect { WorkspaceRect(x: x, y: y, width: w, height: h) }
            func let_(_ f: WorkspaceRect, _ v: (Double, Double) = (0, 0), edges: Set<WorkspaceEdge> = WorkspaceFloatMotion.allEdges) -> WorkspaceFloatMotion.Outcome {
                WorkspaceFloatMotion.decide(release: f, velocity: (x: v.0, y: v.1), in: size, edges: edges, safe: safe)
            }
            // Less than halfway past each edge and corner, let go slowly: back in, reachable.
            let short: [(String, WorkspaceRect)] = [
                ("left", at(-0.3 * w, 0.4)), ("right", at(1 - 0.7 * w, 0.4)), ("top", at(0.3, -0.3 * h)), ("bottom", at(0.3, 1 - 0.7 * h)),
                ("top-left", at(-0.3 * w, -0.3 * h)), ("top-right", at(1 - 0.7 * w, -0.4 * h)),
                ("bottom-left", at(-0.4 * w, 1 - 0.6 * h)), ("bottom-right", at(1 - 0.6 * w, 1 - 0.7 * h)),
            ]
            for (name, f) in short { assertComesBackReachable(let_(f), size, safe: safe, "\(size) \(name)") }
            // Inside the picture but its pill under the status bar or the Dynamic Island: down into the safe area.
            assertComesBackReachable(let_(at(0.3, 8 / size.height)), size, safe: safe, "\(size) under the top band")
            // Pushed back in from past an edge: it glides in and stays reachable.
            assertComesBackReachable(let_(at(1 - 0.7 * w, 0.4), (-700, 0)), size, safe: safe, "\(size) pushed back in")
            assertComesBackReachable(let_(at(0.3, -0.3 * h), (0, 600)), size, safe: safe, "\(size) pushed down from the top")

            // More than halfway past: tucked into that edge, where it is along it.
            XCTAssertEqual(let_(at(-0.6 * w, 0.4)), .tuck(edge: .left, offset: 0.4 + h / 2))
            XCTAssertEqual(let_(at(1 - 0.4 * w, 0.4)), .tuck(edge: .right, offset: 0.4 + h / 2))
            XCTAssertEqual(let_(at(0.3, -0.7 * h)), .tuck(edge: .top, offset: 0.3 + w / 2))
            XCTAssertEqual(let_(at(0.3, 1 - 0.3 * h)), .tuck(edge: .bottom, offset: 0.3 + w / 2))
            // Corners: the edge more of it is past.
            guard case .tuck(.right, _) = let_(at(1 - 0.3 * w, 1 - 0.6 * h)) else { return XCTFail("\(size): right 70%, bottom 40%") }
            guard case .tuck(.bottom, _) = let_(at(1 - 0.4 * w, 1 - 0.2 * h)) else { return XCTFail("\(size): right 60%, bottom 80%") }
            guard case .tuck(.top, _) = let_(at(-0.55 * w, -0.8 * h)) else { return XCTFail("\(size): left 55%, top 80%") }
            guard case .tuck(.left, _) = let_(at(-0.7 * w, 1 - 0.4 * h)) else { return XCTFail("\(size): left 70%, bottom 60%") }
            // An edge without room for a strip doesn't take it: back in, reachable.
            assertComesBackReachable(let_(at(0.3, -0.7 * h), edges: [.left, .right, .bottom]), size, safe: safe, "\(size) no room at the top")
        }
        // Flush against the notch side in landscape: the pill moves out from under the notch.
        let flush = WorkspaceRect(x: 1 - 240 / proMaxLandscape.width, y: 0.4, width: 240 / proMaxLandscape.width, height: 160 / proMaxLandscape.height)
        let rest = WorkspaceFloatGeometry.reachable(flush, in: proMaxLandscape, safe: proMaxLandscapeSafe)
        XCTAssertLessThanOrEqual(pill(rest, proMaxLandscape).maxX, proMaxLandscapeSafe.maxX + 1e-9)
        XCTAssertEqual(rest.y, flush.y, "only as far as it must")
        // Without a safe area: just inside the picture, as before.
        XCTAssertEqual(WorkspaceFloatGeometry.reachable(flush, in: proMaxLandscape, safe: nil), WorkspaceFloatGeometry.clamped(flush, in: proMaxLandscape))
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: middle, velocity: (x: 80, y: 40), in: ipad, safe: nil),
                       .settle(frame: middle, glide: false), "let go slowly in the middle: stays exactly there")
    }

    // MARK: Model

    /// Every edge is a tuck; a decoded tuck is kept on its edge with a usable offset.
    func testSanitizedKeepsEveryEdge() {
        let box = WorkspaceRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        for edge in [WorkspaceEdge.left, .right, .top, .bottom] {
            let f = WorkspaceFloat(tile: "f", frame: box, tuck: WorkspaceFloatTuck(edge: edge, offset: .nan)).sanitized
            XCTAssertEqual(f.tuck, WorkspaceFloatTuck(edge: edge, offset: 0.5))
            XCTAssertEqual(WorkspaceFloat(tile: "f", frame: box, tuck: WorkspaceFloatTuck(edge: edge, offset: 3)).sanitized.tuck?.offset, 1)
            XCTAssertEqual(WorkspaceFloat(tile: "f", frame: box, tuck: WorkspaceFloatTuck(edge: edge, offset: -1)).sanitized.tuck?.offset, 0)
        }
    }

    // MARK: Handles

    private let phoneScreen = WorkspaceRect(x: 0, y: 0, width: 390, height: 844)
    /// Portrait iPhone with a Dynamic Island: 59 pt at the top, the Home indicator's 34 below.
    private let phoneSafe = WorkspaceRect(x: 0, y: 59, width: 390, height: 751)
    private let landscapeScreen = WorkspaceRect(x: 0, y: 0, width: 844, height: 390)
    /// Landscape: no status bar (nothing kept at the top by the safe area), the Island's side kept.
    private let landscapeSafe = WorkspaceRect(x: 59, y: 0, width: 726, height: 369)

    private func floats(_ tucks: [(String, WorkspaceEdge, Double)]) -> [WorkspaceFloat] {
        tucks.map { WorkspaceFloat(tile: $0.0, frame: WorkspaceRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3), tuck: WorkspaceFloatTuck(edge: $0.1, offset: $0.2)) }
    }

    /// Where a handle takes touches (as the view lays it out): 44 pt in from its edge.
    private func touch(_ t: WorkspaceFloatGeometry.TuckTab) -> WorkspaceRect {
        let d = WorkspaceFloatGeometry.touchDepth, r = t.rect
        switch t.edge {
        case .left: return WorkspaceRect(x: r.x, y: r.y, width: d, height: r.height)
        case .right: return WorkspaceRect(x: r.maxX - d, y: r.y, width: d, height: r.height)
        case .top: return WorkspaceRect(x: r.x, y: r.y, width: r.width, height: d)
        case .bottom: return WorkspaceRect(x: r.x, y: r.maxY - d, width: r.width, height: d)
        }
    }

    private func assertApart(_ tabs: [WorkspaceFloatGeometry.TuckTab], file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in tabs.enumerated() {
            for b in tabs[(i + 1)...] {
                XCTAssertNil(touch(a).intersection(touch(b)), "\(a) meets \(b)", file: file, line: line)
            }
        }
    }

    /// Handles sit inside the safe area and out of the system's own edge bands: the top band
    /// even where the safe area keeps nothing there (a landscape iPhone), the Home indicator's.
    func testHandlesStayOutOfTheSystemBands() throws {
        let portrait = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: phoneScreen, safe: phoneSafe, screen: phoneScreen))
        XCTAssertEqual(portrait, phoneSafe, "the safe area already clears the Island and the Home indicator")
        let landscape = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: landscapeScreen, safe: landscapeSafe, screen: landscapeScreen))
        XCTAssertEqual(landscape.y, WorkspaceFloatGeometry.systemEdgeClearance, "Notification Center's swipe starts at the very top")
        XCTAssertEqual(landscape.maxY, 390 - WorkspaceFloatGeometry.systemEdgeClearance)
        XCTAssertEqual(landscape.x, 59)
        // iPad: the status bar's 24 pt and the Home indicator's 20.
        let pad = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: WorkspaceRect(x: 0, y: 0, width: 1180, height: 820),
                                                                  safe: WorkspaceRect(x: 0, y: 24, width: 1180, height: 776),
                                                                  screen: WorkspaceRect(x: 0, y: 0, width: 1180, height: 820)))
        XCTAssertEqual(pad.y, 24)
        XCTAssertEqual(pad.maxY, 796)
        // A letterboxed picture: its own edges, still clear of the screen's bands.
        let boxed = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: WorkspaceRect(x: 0, y: 10, width: 390, height: 300),
                                                                    safe: nil, screen: phoneScreen))
        XCTAssertEqual(boxed.y, 24)
        XCTAssertNil(WorkspaceFloatGeometry.handleArea(picture: WorkspaceRect(x: 0, y: 0, width: 390, height: 20), safe: nil, screen: phoneScreen))

        for (area, screen) in [(portrait, phoneScreen), (landscape, landscapeScreen)] {
            let tabs = WorkspaceFloatGeometry.tuckHandles(floats([("l", .left, 0.5), ("t", .top, 0.02), ("r", .right, 0.99),
                                                                  ("b", .bottom, 0.98)]), area: area)
            XCTAssertEqual(tabs.map(\.edge), [.left, .top, .right, .bottom], "reading order around the edges")
            for t in tabs {
                XCTAssertGreaterThanOrEqual(t.rect.y, screen.y + WorkspaceFloatGeometry.systemEdgeClearance - 1e-9, "\(t)")
                XCTAssertLessThanOrEqual(t.rect.maxY, screen.maxY - WorkspaceFloatGeometry.systemEdgeClearance + 1e-9, "\(t)")
                XCTAssertNotNil(area.intersection(t.rect))
                XCTAssertGreaterThanOrEqual(t.rect.x, area.x - 1e-9)
                XCTAssertLessThanOrEqual(t.rect.maxX, area.maxX + 1e-9)
                XCTAssertGreaterThanOrEqual(t.rect.y, area.y - 1e-9)
                XCTAssertLessThanOrEqual(t.rect.maxY, area.maxY + 1e-9)
            }
            // Top and bottom handles lie along their edge, flush with it, clear of the corners.
            let top = try XCTUnwrap(tabs.first { $0.edge == .top }), bottom = try XCTUnwrap(tabs.first { $0.edge == .bottom })
            XCTAssertGreaterThan(top.rect.width, top.rect.height)
            XCTAssertEqual(top.rect.y, area.y, accuracy: 1e-9)
            XCTAssertEqual(bottom.rect.maxY, area.maxY, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(top.rect.x, area.x + WorkspaceFloatGeometry.touchDepth, "out of the corner")
            XCTAssertLessThanOrEqual(bottom.rect.maxX, area.maxX - WorkspaceFloatGeometry.touchDepth)
            assertApart(tabs)
        }
        XCTAssertEqual(WorkspaceFloatGeometry.tuckEdges(area: portrait), WorkspaceFloatMotion.allEdges)
        XCTAssertEqual(WorkspaceFloatGeometry.tuckEdges(area: WorkspaceRect(x: 0, y: 0, width: 390, height: 50)), [.top, .bottom],
                       "too short for a side handle")
        XCTAssertTrue(WorkspaceFloatGeometry.tuckEdges(area: nil).isEmpty)
    }

    /// Stage Peek's handle on the left edge (screenshots IMG_1756, 2267, 2268): a tuck handle
    /// that wanted the same place slides along the edge to the nearest free room beside it.
    func testHandlesGiveWayToStagePeeksHandle() throws {
        let area = phoneSafe
        // Stage Peek's strip, placed the way StagePeekLayout places it in this safe area.
        let s = try XCTUnwrap(StagePeekLayout.strip(edge: .left, safe: CGRect(x: area.x, y: area.y, width: area.width, height: area.height)))
        let strip = WorkspaceRect(x: Double(s.minX), y: Double(s.minY), width: Double(s.width), height: Double(s.height))
        let tabs = WorkspaceFloatGeometry.tuckTabs([("a", 0.5)], edge: .left, area: area, avoiding: [strip])
        let t = try XCTUnwrap(tabs.first)
        XCTAssertNil(touch(t).intersection(strip), "never on or beside it")
        XCTAssertEqual(t.rect.maxY, strip.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-9, "the nearest free room")
        // Stage Peek on the other edge: nothing moves.
        let free = WorkspaceFloatGeometry.tuckTabs([("a", 0.5)], edge: .right, area: area, avoiding: [strip])
        XCTAssertEqual(free.first?.rect.midY ?? 0, area.y + area.height * 0.5, accuracy: 1e-9)
        // Several: around it, in order, apart.
        let three = WorkspaceFloatGeometry.tuckTabs([("a", 0.45), ("b", 0.5), ("c", 0.55)], edge: .left, area: area, avoiding: [strip])
        XCTAssertEqual(three.count, 3)
        XCTAssertTrue(three.allSatisfy { touch($0).intersection(strip) == nil })
        assertApart(three)
        XCTAssertEqual(three.map { $0.ids[0] }, ["a", "b", "c"], "their order along the edge is kept")
    }

    /// The function tray or the shortcut column along the right edge (IMG_2269-2271) and two
    /// right-edge handles (IMG_1762): the handles take the free room, apart, and collapse into
    /// one stack when there isn't room for each.
    func testHandlesGiveWayToTheTraysAndStackWhenCrowded() throws {
        let area = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: landscapeScreen, safe: landscapeSafe, screen: landscapeScreen))
        // A column of controls at the right edge, from near the top to below the middle.
        let column = WorkspaceRect(x: area.maxX - 52, y: 40, width: 48, height: 100)
        let two = WorkspaceFloatGeometry.tuckTabs([("a", 0.3), ("b", 0.32)], edge: .right, area: area, avoiding: [column])
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(two.allSatisfy { touch($0).intersection(column) == nil })
        XCTAssertTrue(two.allSatisfy { $0.rect.y >= column.maxY })
        assertApart(two)

        // Room for one only: the two share a stack there.
        let tall = WorkspaceRect(x: area.maxX - 52, y: 40, width: 48, height: 150)
        let crowded = WorkspaceFloatGeometry.tuckTabs([("a", 0.3), ("b", 0.32)], edge: .right, area: area, avoiding: [tall])
        XCTAssertEqual(crowded.count, 1)
        XCTAssertEqual(crowded[0].ids, ["a", "b"])
        XCTAssertNil(touch(crowded[0]).intersection(tall))

        // No room at all on that edge: still one stack, reachable on its edge (never lost).
        let wall = WorkspaceRect(x: area.maxX - 40, y: 0, width: 40, height: 390)
        let blocked = WorkspaceFloatGeometry.tuckTabs([("a", 0.3), ("b", 0.6)], edge: .right, area: area, avoiding: [wall])
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked[0].ids.count, 2)
        XCTAssertEqual(blocked[0].rect.maxX, area.maxX, accuracy: 1e-9)

        // Controls away from the edge don't push anything.
        let inside = WorkspaceRect(x: area.midX, y: 40, width: 100, height: 300)
        XCTAssertEqual(WorkspaceFloatGeometry.tuckTabs([("a", 0.3)], edge: .right, area: area, avoiding: [inside]),
                       WorkspaceFloatGeometry.tuckTabs([("a", 0.3)], edge: .right, area: area))

        // Five on one edge: one stack, as before.
        XCTAssertEqual(WorkspaceFloatGeometry.tuckTabs((0..<5).map { ("f\($0)", Double($0) / 5) }, edge: .bottom, area: area).count, 1)
        // Hostile reserved rects change nothing.
        XCTAssertEqual(WorkspaceFloatGeometry.tuckTabs([("a", 0.3)], edge: .right, area: area,
                                                       avoiding: [WorkspaceRect(x: .nan, y: 0, width: 10, height: 10),
                                                                  WorkspaceRect(x: 0, y: 0, width: -5, height: 10)]),
                       WorkspaceFloatGeometry.tuckTabs([("a", 0.3)], edge: .right, area: area))
    }

    /// Rotation lays the handles out again on the new edges, still apart and inside.
    func testHandlesReLayOutWhenThePhoneRotates() throws {
        let tucked = floats([("a", .right, 0.4), ("b", .right, 0.45), ("c", .top, 0.5), ("d", .left, 0.9)])
        for (picture, safe) in [(phoneScreen, phoneSafe), (landscapeScreen, landscapeSafe)] {
            let area = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: picture, safe: safe, screen: picture))
            let tabs = WorkspaceFloatGeometry.tuckHandles(tucked, area: area)
            XCTAssertEqual(Set(tabs.flatMap(\.ids)), ["a", "b", "c", "d"], "every tucked float keeps a handle")
            assertApart(tabs)
            XCTAssertTrue(tabs.filter { $0.edge == .right }.allSatisfy { abs($0.rect.maxX - area.maxX) < 1e-9 })
        }
    }

    // MARK: Pulling back out

    /// A pull brings the float out with its inner side under the finger; let go past the
    /// restore point (or flicked out), it comes back; short of it, or pushed back, it slides in.
    func testPullingATuckedFloatBackOut() {
        let f = WorkspaceRect(x: 0.6, y: 0.3, width: 0.3, height: 0.3)
        // Right edge: hidden at 1.02, back at 0.6.
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: 1.02, frame: f, edge: .right), 0, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: 0.81, frame: f, edge: .right), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: 0.6, frame: f, edge: .right), 1, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: 1.2, frame: f, edge: .right), 0, "pushed outward: still hidden")
        let half = WorkspaceFloatMotion.pulledFrame(f, edge: .right, handle: 0.7, progress: 0.5)
        XCTAssertEqual(half.x, 0.81, accuracy: 1e-9, "its inner side under the finger")
        XCTAssertEqual(half.midY, (0.7 + f.midY) / 2, accuracy: 1e-9, "from its handle toward where it was")
        XCTAssertEqual(WorkspaceFloatMotion.pulledFrame(f, edge: .right, handle: 0.7, progress: 0),
                       WorkspaceFloatMotion.hiddenFrame(f, edge: .right, along: 0.7))
        XCTAssertEqual(WorkspaceFloatMotion.pulledFrame(f, edge: .right, handle: 0.7, progress: 1.4), f, "never past where it was")
        XCTAssertEqual(WorkspaceFloatMotion.pullTravel(f, edge: .right, in: ipad), 0.42 * 1180, accuracy: 1e-6)

        // The other edges, the same way round.
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: f.maxX, frame: f, edge: .left), 1, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: -0.02, frame: f, edge: .left), 0, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: f.maxY, frame: f, edge: .top), 1, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pullProgress(finger: f.y, frame: f, edge: .bottom), 1, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceFloatMotion.pulledFrame(f, edge: .bottom, handle: 0.2, progress: 0).midX, 0.2, accuracy: 1e-9)
        for edge in [WorkspaceEdge.left, .right, .top, .bottom] {
            let hidden = WorkspaceFloatMotion.hiddenFrame(f, edge: edge)
            XCTAssertNil(hidden.intersection(.unit), "\(edge): none of it shows")
        }

        // Let go.
        let travel = 500.0
        XCTAssertTrue(WorkspaceFloatMotion.pullRestores(progress: 0.45, inwardVelocity: 0, travel: travel))
        XCTAssertFalse(WorkspaceFloatMotion.pullRestores(progress: 0.3, inwardVelocity: 0, travel: travel), "short: back in")
        XCTAssertTrue(WorkspaceFloatMotion.pullRestores(progress: 0.25, inwardVelocity: 700, travel: travel), "flicked out")
        XCTAssertFalse(WorkspaceFloatMotion.pullRestores(progress: 0.1, inwardVelocity: 300, travel: travel), "a nudge isn't a flick")
        XCTAssertFalse(WorkspaceFloatMotion.pullRestores(progress: 0.8, inwardVelocity: -400, travel: travel), "pushed back: back in")
        XCTAssertFalse(WorkspaceFloatMotion.pullRestores(progress: .nan, inwardVelocity: 0, travel: travel))
        XCTAssertFalse(WorkspaceFloatMotion.pullRestores(progress: 0.9, inwardVelocity: 0, travel: 0))
    }

    // MARK: The model

    @MainActor
    private func connectedModel(features: Set<String>, sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "WorkspaceFloatTuckTests-\(UUID().uuidString)")!)
        m.floatsDrawnHere = true   // the iPhone/iPad receiver (this test runs on the Mac)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features(features))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [10, 11, 12].map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [], "displays": [],
        ])!)
        m.updateSpace(ipad, hinge: nil)
        return m
    }

    @MainActor
    private func settle() {
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    private func lastTile(_ sent: [[String: Any]], _ id: String) -> [String: Any]? {
        let tiles = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        return tiles.first { $0["id"] as? String == id }
    }

    private static let safeTypes: Set<String> = [WireMessage.workspaceRequest, WireMessage.workspaceFocus, WireMessage.workspaceBackdropRequest,
                                                 WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest]

    /// Tucked into the top edge (a still asked for first, for its sliver), it isn't sent; restored,
    /// it's sent again at once but lifted (the Mac leaves it out while this device slides it
    /// out), and lands when the slide ends. Nothing of it acts on the Mac window.
    @MainActor
    func testARestoredFloatSlidesOutDrawnHereAndNeverActsOnTheMacWindow() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature,
                                          WindowWorkspaceWire.floatLiftFeature]) { sent.append($0) }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.openFloating(w[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        let frame = try XCTUnwrap(m.layout.float(fid)?.frame)
        settle()
        sent.removeAll()

        m.tuckFloat(fid, edge: .top, offset: 0.3)
        XCTAssertEqual(m.layout.float(fid)?.tuck, WorkspaceFloatTuck(edge: .top, offset: 0.3))
        XCTAssertTrue(sent.contains { $0["type"] as? String == WireMessage.workspaceBackdropRequest && $0["tile"] as? String == fid },
                      "a still for its sliver, asked for while it's still sent")
        settle()
        XCTAssertNil(lastTile(sent, fid), "tucked: not sent")

        m.beginRestoringFloat(fid)
        XCTAssertNil(m.layout.float(fid)?.tuck)
        XCTAssertEqual(m.layout.float(fid)?.frame, frame, "back where it was")
        XCTAssertEqual(m.layout.floatIDs.last, fid, "in front")
        XCTAssertTrue(m.drawsFloatHere(fid), "drawn here while it slides out")
        XCTAssertEqual(lastTile(sent, fid)?["lift"] as? Bool, true, "sent again (its capture starts) but left out by the Mac")
        m.endFloatGesture(fid)
        XCTAssertNil(lastTile(sent, fid)?["lift"], "landed: the Mac draws it")
        settle()

        let focuses = sent.filter { $0["type"] as? String == WireMessage.workspaceFocus }
        XCTAssertTrue(focuses.allSatisfy { $0["raise"] as? Bool == false }, "never brings the Mac window forward: \(focuses)")
        XCTAssertTrue(sent.allSatisfy { Self.safeTypes.contains($0["type"] as? String ?? "") },
                      "never acts on the Mac window: \(sent.map { $0["type"] ?? "" })")

        // Undo puts it back at its edge.
        m.undo()
        XCTAssertEqual(m.layout.float(fid)?.tuck?.edge, .top)
    }

    /// A Mac without `floatLift`: restoring shows it again, never with `lift`.
    @MainActor
    func testRestoringOnAMacWithoutLift() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { sent.append($0) }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        m.tuckFloat(fid, edge: .bottom, offset: 0.6)
        m.beginRestoringFloat(fid)
        m.endFloatGesture(fid)
        settle()
        XCTAssertNil(m.layout.float(fid)?.tuck)
        XCTAssertFalse(m.drawsFloatHere(fid))
        XCTAssertNotNil(lastTile(sent, fid), "shown again")
        XCTAssertFalse(sent.contains { ($0["tiles"] as? [[String: Any]])?.contains { $0["lift"] != nil } == true })
    }
}
