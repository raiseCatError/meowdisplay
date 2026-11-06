import CoreGraphics
import XCTest

/// Tucking floats into any edge (Shared/WorkspaceFloats.swift, WINDOW_MODE.md "Tuck it away"):
/// the throw that reaches an edge, the full-length strips that give way to the system's edge
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

    /// The title pill of a float at `r` (shares of a picture of `size`), across as far as its
    /// content (its widest is a few points wider: a float flush with an edge stays flush).
    private func pill(_ r: WorkspaceRect, _ size: WorkspaceSize) -> WorkspaceRect {
        let p = WorkspaceFloatLayering.pillBounds(WorkspaceRect(x: r.x * size.width, y: r.y * size.height,
                                                                width: r.width * size.width, height: r.height * size.height))
        let w = min(p.width, r.width * size.width)
        return WorkspaceRect(x: (p.midX - w / 2) / size.width, y: p.y / size.height, width: w / size.width, height: p.height / size.height)
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

    // MARK: Strips

    private let phoneScreen = WorkspaceRect(x: 0, y: 0, width: 390, height: 844)
    /// Portrait iPhone with a Dynamic Island: 59 pt at the top, the Home indicator's 34 below.
    private let phoneSafe = WorkspaceRect(x: 0, y: 59, width: 390, height: 751)
    private let landscapeScreen = WorkspaceRect(x: 0, y: 0, width: 844, height: 390)
    /// Landscape: no status bar (nothing kept at the top by the safe area), the Island's side kept.
    private let landscapeSafe = WorkspaceRect(x: 59, y: 0, width: 726, height: 369)

    private func floats(_ tucks: [(String, WorkspaceEdge, Double)]) -> [WorkspaceFloat] {
        tucks.map { WorkspaceFloat(tile: $0.0, frame: WorkspaceRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3), tuck: WorkspaceFloatTuck(edge: $0.1, offset: $0.2)) }
    }

    /// Where a strip takes touches (as the view lays it out): 44 pt in from its edge.
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

    /// A strip is a part of its own float: the float waits at its own size behind the edge, the
    /// strip `stripDepth` of its inner side, inside it.
    private func assertIsPartOfItsFloat(_ t: WorkspaceFloatGeometry.TuckTab, area: WorkspaceRect, file: StaticString = #filePath, line: UInt = #line) {
        let d = WorkspaceFloatGeometry.stripDepth
        let inside = t.float.x <= t.rect.x + 1e-9 && t.float.maxX >= t.rect.maxX - 1e-9 && t.float.y <= t.rect.y + 1e-9 && t.float.maxY >= t.rect.maxY - 1e-9
        XCTAssertTrue(inside, "the strip is inside its float: \(t)", file: file, line: line)
        switch t.edge {
        case .left:
            XCTAssertEqual(t.rect.x, area.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(t.float.maxX, area.x + d, accuracy: 1e-9, file: file, line: line)
        case .right:
            XCTAssertEqual(t.rect.maxX, area.maxX, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(t.float.x, area.maxX - d, accuracy: 1e-9, file: file, line: line)
        case .top:
            XCTAssertEqual(t.rect.y, area.y, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(t.float.maxY, area.y + d, accuracy: 1e-9, file: file, line: line)
        case .bottom:
            XCTAssertEqual(t.rect.maxY, area.maxY, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(t.float.y, area.maxY - d, accuracy: 1e-9, file: file, line: line)
        }
    }

    /// The owner's examples: a 260 pt tall float tucked left leaves a 260 pt strip; a 180 pt wide
    /// one tucked at the bottom a 180 pt strip. Thin (20 pt), as long as the window, a natural
    /// part of it, where it was along the edge.
    func testAStripIsAsLongAsItsFloat() throws {
        let area = phoneSafe
        let left = try XCTUnwrap(WorkspaceFloatGeometry.tuckTabs([("a", 0.5, WorkspaceSize(width: 220, height: 260))], edge: .left,
                                                                  area: area, picture: phoneScreen).first)
        XCTAssertFalse(left.isStack)
        XCTAssertEqual(left.rect.height, 260, accuracy: 1e-9, "as tall as the float")
        XCTAssertEqual(left.rect.width, WorkspaceFloatGeometry.stripDepth, accuracy: 1e-9, "and thin")
        XCTAssertEqual(left.float.width, 220, accuracy: 1e-9, "the float keeps its own size")
        XCTAssertEqual(left.float.height, 260, accuracy: 1e-9)
        XCTAssertEqual(left.rect.midY, 422, accuracy: 1e-9, "where it was along the edge")
        assertIsPartOfItsFloat(left, area: area)

        let bottom = try XCTUnwrap(WorkspaceFloatGeometry.tuckTabs([("b", 0.5, WorkspaceSize(width: 180, height: 120))], edge: .bottom,
                                                                    area: area, picture: phoneScreen).first)
        XCTAssertEqual(bottom.rect.width, 180, accuracy: 1e-9, "as wide as the float")
        XCTAssertEqual(bottom.rect.height, WorkspaceFloatGeometry.stripDepth, accuracy: 1e-9)
        XCTAssertEqual(bottom.rect.midX, 195, accuracy: 1e-9)
        assertIsPartOfItsFloat(bottom, area: area)

        // Every edge, through the floats' own frames.
        let all = WorkspaceFloatGeometry.tuckHandles([
            WorkspaceFloat(tile: "l", frame: WorkspaceRect(x: 0, y: 0.3, width: 0.5, height: 260 / 844), tuck: WorkspaceFloatTuck(edge: .left, offset: 0.45)),
            WorkspaceFloat(tile: "t", frame: WorkspaceRect(x: 0.3, y: 0.1, width: 160 / 390, height: 0.2), tuck: WorkspaceFloatTuck(edge: .top, offset: 0.5)),
            WorkspaceFloat(tile: "r", frame: WorkspaceRect(x: 0.5, y: 0.3, width: 0.5, height: 200 / 844), tuck: WorkspaceFloatTuck(edge: .right, offset: 0.6)),
            WorkspaceFloat(tile: "b", frame: WorkspaceRect(x: 0.2, y: 0.7, width: 180 / 390, height: 0.15), tuck: WorkspaceFloatTuck(edge: .bottom, offset: 0.5)),
        ], picture: phoneScreen, area: area)
        XCTAssertEqual(all.map(\.edge), [.left, .top, .right, .bottom], "reading order around the edges")
        for (t, length) in zip(all, [260.0, 160, 200, 180]) {
            XCTAssertEqual(t.edge.axis == .horizontal ? t.rect.height : t.rect.width, length, accuracy: 1e-9, "\(t.edge): as long as its float")
        }
        for t in all { assertIsPartOfItsFloat(t, area: area) }
        assertApart(all)
    }

    /// Strips sit inside the safe area and out of the system's own edge bands: the top band even
    /// where the safe area keeps nothing there (a landscape iPhone), the Home indicator's.
    func testStripsStayOutOfTheSystemBands() throws {
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
                                                                  ("b", .bottom, 0.98)]), picture: screen, area: area)
            XCTAssertEqual(tabs.map(\.edge), [.left, .top, .right, .bottom], "reading order around the edges")
            for t in tabs {
                XCTAssertGreaterThanOrEqual(t.rect.y, screen.y + WorkspaceFloatGeometry.systemEdgeClearance - 1e-9, "\(t)")
                XCTAssertLessThanOrEqual(t.rect.maxY, screen.maxY - WorkspaceFloatGeometry.systemEdgeClearance + 1e-9, "\(t)")
                XCTAssertGreaterThanOrEqual(t.rect.x, area.x - 1e-9)
                XCTAssertLessThanOrEqual(t.rect.maxX, area.maxX + 1e-9)
                XCTAssertGreaterThanOrEqual(t.rect.y, area.y - 1e-9)
                XCTAssertLessThanOrEqual(t.rect.maxY, area.maxY + 1e-9)
                assertIsPartOfItsFloat(t, area: area)
            }
            // Top and bottom strips lie along their edge, flush with it, clear of the corners.
            let top = try XCTUnwrap(tabs.first { $0.edge == .top }), bottom = try XCTUnwrap(tabs.first { $0.edge == .bottom })
            XCTAssertGreaterThan(top.rect.width, top.rect.height)
            XCTAssertGreaterThanOrEqual(top.rect.x, area.x + WorkspaceFloatGeometry.touchDepth, "out of the corner")
            XCTAssertLessThanOrEqual(bottom.rect.maxX, area.maxX - WorkspaceFloatGeometry.touchDepth)
            assertApart(tabs)
        }
        XCTAssertEqual(WorkspaceFloatGeometry.tuckEdges(area: portrait), WorkspaceFloatMotion.allEdges)
        XCTAssertEqual(WorkspaceFloatGeometry.tuckEdges(area: WorkspaceRect(x: 0, y: 0, width: 390, height: 50)), [.top, .bottom],
                       "too short for a side strip")
        XCTAssertTrue(WorkspaceFloatGeometry.tuckEdges(area: nil).isEmpty)
    }

    /// Stage Peek's handle on the left edge: a strip that wanted the same place slides along the
    /// edge to the nearest free room beside it, still full length; three share the room around
    /// it, in order, apart, shortened only where they must be.
    func testStripsGiveWayToStagePeeksHandle() throws {
        let area = phoneSafe
        let s = try XCTUnwrap(StagePeekLayout.strip(edge: .left, safe: CGRect(x: area.x, y: area.y, width: area.width, height: area.height)))
        let strip = WorkspaceRect(x: Double(s.minX), y: Double(s.minY), width: Double(s.width), height: Double(s.height))
        let size = WorkspaceSize(width: 240, height: 160)
        let one = try XCTUnwrap(WorkspaceFloatGeometry.tuckTabs([("a", 0.5, size)], edge: .left, area: area, picture: phoneScreen, avoiding: [strip]).first)
        XCTAssertNil(touch(one).intersection(strip), "never on or beside it")
        XCTAssertEqual(one.rect.height, 160, accuracy: 1e-9, "still as long as its float")
        XCTAssertEqual(one.rect.maxY, strip.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-9, "the nearest free room")
        assertIsPartOfItsFloat(one, area: area)
        // Stage Peek on the other edge: nothing moves.
        let free = WorkspaceFloatGeometry.tuckTabs([("a", 0.5, size)], edge: .right, area: area, picture: phoneScreen, avoiding: [strip])
        XCTAssertEqual(free.first?.rect.midY ?? 0, 422, accuracy: 1e-9)
        // Three: around it, in order, apart; the one with room to itself keeps its full length.
        let three = WorkspaceFloatGeometry.tuckTabs([("a", 0.45, size), ("b", 0.5, size), ("c", 0.55, size)], edge: .left, area: area,
                                                    picture: phoneScreen, avoiding: [strip])
        XCTAssertEqual(three.count, 3)
        XCTAssertFalse(three.contains(where: \.isStack))
        XCTAssertTrue(three.allSatisfy { touch($0).intersection(strip) == nil })
        assertApart(three)
        XCTAssertEqual(three.map { $0.ids[0] }, ["a", "b", "c"], "their order along the edge is kept")
        XCTAssertTrue(three.allSatisfy { $0.rect.height >= WorkspaceFloatGeometry.minimumStripLength - 1e-9 })
        XCTAssertEqual(three[2].rect.height, 160, accuracy: 1e-9, "alone below the handle: full length")
        for t in three { assertIsPartOfItsFloat(t, area: area) }
    }

    /// The function tray or the shortcut column along the right edge: strips take the free room,
    /// apart (shortened to share it when they must), and share one stack when there isn't room
    /// for each; with no free room at all they stay reachable on their edge.
    func testStripsGiveWayToTheTraysShortenAndStackWhenCrowded() throws {
        let area = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: landscapeScreen, safe: landscapeSafe, screen: landscapeScreen))
        let size = WorkspaceSize(width: 300, height: 117)
        func tabs(_ t: [(String, Double)], avoiding: [WorkspaceRect] = [], edge: WorkspaceEdge = .right) -> [WorkspaceFloatGeometry.TuckTab] {
            WorkspaceFloatGeometry.tuckTabs(t.map { ($0.0, $0.1, size) }, edge: edge, area: area, picture: landscapeScreen, avoiding: avoiding)
        }
        // A column of controls at the right edge, from near the top to below the middle.
        let column = WorkspaceRect(x: area.maxX - 52, y: 40, width: 48, height: 100)
        let two = tabs([("a", 0.3), ("b", 0.32)], avoiding: [column])
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(two.allSatisfy { touch($0).intersection(column) == nil })
        XCTAssertTrue(two.allSatisfy { $0.rect.y >= column.maxY })
        XCTAssertTrue(two.allSatisfy { $0.rect.height >= WorkspaceFloatGeometry.minimumStripLength - 1e-9 && $0.rect.height < 117 },
                      "shortened evenly to share the room: \(two.map(\.rect))")
        XCTAssertEqual(two[0].rect.height, two[1].rect.height, accuracy: 1e-6)
        for t in two { assertIsPartOfItsFloat(t, area: area) }
        assertApart(two)

        // Room for one only: the two share a stack there (the last resort, the small handle).
        let tall = WorkspaceRect(x: area.maxX - 52, y: 40, width: 48, height: 150)
        let crowded = tabs([("a", 0.3), ("b", 0.32)], avoiding: [tall])
        XCTAssertEqual(crowded.count, 1)
        XCTAssertEqual(crowded[0].ids, ["a", "b"])
        XCTAssertEqual(crowded[0].rect.height, WorkspaceFloatGeometry.tabSize.height, accuracy: 1e-9)
        XCTAssertNil(touch(crowded[0]).intersection(tall))

        // No room at all on that edge: still reachable on its edge (never lost), one alone as a strip.
        let wall = WorkspaceRect(x: area.maxX - 40, y: 0, width: 40, height: 390)
        let blocked = tabs([("a", 0.3), ("b", 0.6)], avoiding: [wall])
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked[0].ids.count, 2)
        XCTAssertEqual(blocked[0].rect.maxX, area.maxX, accuracy: 1e-9)
        let alone = try XCTUnwrap(tabs([("a", 0.3)], avoiding: [wall]).first)
        XCTAssertFalse(alone.isStack)
        XCTAssertEqual(alone.rect.maxX, area.maxX, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(alone.rect.height, WorkspaceFloatGeometry.minimumStripLength)
        assertIsPartOfItsFloat(alone, area: area)

        // Controls away from the edge don't push anything.
        let inside = WorkspaceRect(x: area.midX, y: 40, width: 100, height: 300)
        XCTAssertEqual(tabs([("a", 0.3)], avoiding: [inside]), tabs([("a", 0.3)]))
        // More than four on one edge: one stack.
        XCTAssertEqual(tabs((0..<5).map { ("f\($0)", Double($0) / 5) }, edge: .bottom).count, 1)
        // Hostile reserved rects change nothing.
        XCTAssertEqual(tabs([("a", 0.3)], avoiding: [WorkspaceRect(x: .nan, y: 0, width: 10, height: 10),
                                                     WorkspaceRect(x: 0, y: 0, width: -5, height: 10)]), tabs([("a", 0.3)]))
    }

    /// Two and three on one edge get their full lengths when the edge has room, in order and
    /// apart; more than fits are shortened evenly, never below the shortest strip; a float longer
    /// than all the room there is shows what fits, a part of itself near where it was.
    func testSeveralStripsOnOneEdge() throws {
        let area = phoneSafe
        let run = WorkspaceFloatGeometry.run(.left, in: area)   // 12% of the edge kept at each end
        XCTAssertEqual(run.hi - run.lo, 751 * 0.76, accuracy: 1e-9)
        func tabs(_ t: [(String, Double, Double)]) -> [WorkspaceFloatGeometry.TuckTab] {
            WorkspaceFloatGeometry.tuckTabs(t.map { ($0.0, $0.1, WorkspaceSize(width: 240, height: $0.2)) }, edge: .left, area: area, picture: phoneScreen)
        }
        let two = tabs([("a", 0.5, 200), ("b", 0.52, 180)])
        XCTAssertEqual(two.map(\.rect.height), [200, 180], "full length, both")
        XCTAssertEqual(two.map { $0.ids[0] }, ["a", "b"])
        assertApart(two)
        let three = tabs([("a", 0.3, 160), ("b", 0.5, 160), ("c", 0.7, 160)])
        XCTAssertEqual(three.map(\.rect.height), [160, 160, 160])
        assertApart(three)
        for t in two + three { assertIsPartOfItsFloat(t, area: area) }

        // Three of 260 on a 571 pt run: shortened evenly to share it.
        let long = tabs([("a", 0.4, 260), ("b", 0.5, 260), ("c", 0.6, 260)])
        XCTAssertEqual(long.count, 3)
        assertApart(long)
        XCTAssertTrue(long.allSatisfy { $0.rect.height < 260 && $0.rect.height >= WorkspaceFloatGeometry.minimumStripLength })
        XCTAssertEqual(long.map(\.rect.height).reduce(0, +) + 2 * WorkspaceFloatGeometry.tabSpacing, run.hi - run.lo, accuracy: 1e-6, "using the room there is")
        for t in long { assertIsPartOfItsFloat(t, area: area) }

        // One longer than the edge: it shows what fits, a part of itself.
        let tallest = try XCTUnwrap(tabs([("a", 0.5, 700)]).first)
        XCTAssertEqual(tallest.rect.height, run.hi - run.lo, accuracy: 1e-9, "the whole run")
        XCTAssertEqual(tallest.float.height, 700, "the float keeps its size behind the edge")
        assertIsPartOfItsFloat(tallest, area: area)
    }

    /// Rotation lays the strips out again on the new edges, still apart and inside, each as long
    /// as its float in the new picture where there's room.
    func testStripsReLayOutWhenThePhoneRotates() throws {
        let tucked = floats([("a", .right, 0.4), ("b", .right, 0.45), ("c", .top, 0.5), ("d", .left, 0.9)])
        for (picture, safe) in [(phoneScreen, phoneSafe), (landscapeScreen, landscapeSafe)] {
            let area = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: picture, safe: safe, screen: picture))
            let tabs = WorkspaceFloatGeometry.tuckHandles(tucked, picture: picture, area: area)
            XCTAssertEqual(Set(tabs.flatMap(\.ids)), ["a", "b", "c", "d"], "every tucked float keeps its strip")
            XCTAssertFalse(tabs.contains(where: \.isStack))
            assertApart(tabs)
            for t in tabs {
                assertIsPartOfItsFloat(t, area: area)
                XCTAssertEqual(t.edge.axis == .horizontal ? t.rect.height : t.rect.width,
                               t.edge.axis == .horizontal ? 0.3 * picture.height : 0.4 * picture.width, accuracy: 1e-6, "\(picture): full length")
            }
        }
    }

    // MARK: Never out of reach (round 3)

    /// The control tray along the bottom of a phone in portrait fills that edge's run: its strips
    /// wait just above the tray, at full length, their windows behind that line (under the tray),
    /// and a throw at the bottom still tucks. A keypad over half the screen leaves the bottom no
    /// room: a throw there doesn't tuck, and a float tucked there anyway (VoiceOver, an edge that
    /// filled up later) waits on the nearest side edge, at its end by the bottom, reachable.
    func testAnEdgeTheControlsFillTakesItsStripsJustInsideThem() throws {
        let area = phoneSafe
        let tray = WorkspaceRect(x: 8, y: 754, width: 374, height: 56)
        XCTAssertTrue(WorkspaceFloatGeometry.freeRuns(.bottom, in: area, avoiding: [tray]).isEmpty, "the tray fills the bottom's run")
        let inside = try XCTUnwrap(WorkspaceFloatGeometry.stripArea(.bottom, in: area, avoiding: [tray]))
        XCTAssertEqual(inside.maxY, tray.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-9, "just above the tray")
        XCTAssertEqual(inside.x, area.x)
        XCTAssertEqual(inside.width, area.width)
        XCTAssertEqual(WorkspaceFloatGeometry.stripArea(.left, in: area, avoiding: [tray]), area, "the other edges keep theirs")
        XCTAssertEqual(WorkspaceFloatGeometry.tuckEdges(area: area, reserved: [tray]), WorkspaceFloatMotion.allEdges)

        let bottom = [WorkspaceFloat(tile: "b", frame: WorkspaceRect(x: 0.25, y: 0.6, width: 180 / 390, height: 120 / 844),
                                     tuck: WorkspaceFloatTuck(edge: .bottom, offset: 0.5))]
        let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles(bottom, picture: phoneScreen, area: area, reserved: [tray]).first)
        XCTAssertEqual(tab.edge, .bottom)
        XCTAssertEqual(tab.rect.width, 180, accuracy: 1e-9, "full length")
        assertIsPartOfItsFloat(tab, area: inside)
        XCTAssertNil(WorkspaceFloatGeometry.touchArea(tab).intersection(tray), "a finger reaches it above the tray")
        XCTAssertEqual(WorkspaceFloatGeometry.unreachableTucked(bottom, handles: [tab], reserved: [tray]), [])
        // A palette open above the tray: the strips step inside that too.
        let palette = WorkspaceRect(x: 60, y: 690, width: 270, height: 56)
        let above = try XCTUnwrap(WorkspaceFloatGeometry.stripArea(.bottom, in: area, avoiding: [tray, palette]))
        XCTAssertEqual(above.maxY, palette.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-9)

        // A keypad over the lower half: no room at the bottom.
        let keypad = WorkspaceRect(x: 0, y: 450, width: 390, height: 394)
        XCTAssertNil(WorkspaceFloatGeometry.stripArea(.bottom, in: area, avoiding: [keypad]))
        XCTAssertFalse(WorkspaceFloatGeometry.tuckEdges(area: area, reserved: [keypad]).contains(.bottom), "a throw there glides back")
        if case .tuck = WorkspaceFloatMotion.decide(release: WorkspaceRect(x: 0.3, y: 0.5, width: 0.4, height: 0.2), velocity: (x: 0, y: 3000),
                                                    in: phone, edges: WorkspaceFloatGeometry.tuckEdges(area: area, reserved: [keypad])) {
            XCTFail("a throw at a full edge glides back")
        }
        let lowLeft = [WorkspaceFloat(tile: "b", frame: WorkspaceRect(x: 0.1, y: 0.6, width: 180 / 390, height: 120 / 844),
                                      tuck: WorkspaceFloatTuck(edge: .bottom, offset: 0.3))]
        let moved = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles(lowLeft, picture: phoneScreen, area: area, reserved: [keypad]).first)
        XCTAssertEqual(moved.edge, .left, "the nearer side")
        XCTAssertEqual(moved.rect.height, 120, accuracy: 1e-9, "a strip of itself, full length")
        XCTAssertEqual(moved.rect.maxY, keypad.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-9, "at the end by the bottom")
        assertIsPartOfItsFloat(moved, area: area)
        XCTAssertEqual(WorkspaceFloatGeometry.unreachableTucked(lowLeft, handles: [moved], reserved: [keypad]), [])
        let right = WorkspaceFloatGeometry.refuge(for: WorkspaceFloatTuck(edge: .bottom, offset: 0.8), open: [.left, .right, .top])
        XCTAssertEqual(right?.edge, .right)
        XCTAssertEqual(right?.offset, 1)
        XCTAssertEqual(WorkspaceFloatGeometry.refuge(for: WorkspaceFloatTuck(edge: .left, offset: 0.4), open: [.right])?.offset, 0.4,
                       "the opposite edge where it was along it")
        XCTAssertNil(WorkspaceFloatGeometry.refuge(for: WorkspaceFloatTuck(edge: .left, offset: 0.4), open: []))
    }

    /// Whatever the controls hold and however many floats are tucked where, every tucked float is
    /// on exactly one handle, and a finger reaches each handle, while any edge has room; strips
    /// never meet. Only with every edge full deeper than strips may go are some out of a finger's
    /// reach (VoiceOver's handles and Stage Peek still bring them back).
    func testEveryTuckedFloatStaysReachable() throws {
        let ipadScreen = WorkspaceRect(x: 0, y: 0, width: 1180, height: 820)
        let ipadSafe = WorkspaceRect(x: 0, y: 24, width: 1180, height: 776)
        for (screen, safe) in [(phoneScreen, phoneSafe), (landscapeScreen, landscapeSafe), (ipadScreen, ipadSafe)] {
            let area = try XCTUnwrap(WorkspaceFloatGeometry.handleArea(picture: screen, safe: safe, screen: screen))
            let w = screen.width, h = screen.height
            let peek = StagePeekLayout.strip(edge: .left, safe: CGRect(x: area.x, y: area.y, width: area.width, height: area.height))
                .map { WorkspaceRect(x: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height)) }
            let controls: [[WorkspaceRect]] = [
                [],
                [WorkspaceRect(x: 8, y: area.maxY - 56, width: w - 16, height: 56)],                       // a tray along the bottom
                [WorkspaceRect(x: area.maxX - 60, y: area.y, width: 56, height: area.height)],             // a column down the right
                [WorkspaceRect(x: 0, y: h * 0.45, width: w, height: h * 0.55)],                            // a keypad over the lower half
                [WorkspaceRect(x: 8, y: area.maxY - 56, width: w - 16, height: 56),
                 WorkspaceRect(x: area.maxX - 60, y: area.y, width: 56, height: area.height)],
                peek.map { [$0] } ?? [],
                [WorkspaceRect(x: 0, y: 0, width: w * 0.5, height: h), WorkspaceRect(x: w * 0.5, y: 0, width: w * 0.5, height: h)],   // everything
            ]
            let edges: [WorkspaceEdge] = [.left, .top, .right, .bottom]
            for reserved in controls {
                let open = WorkspaceFloatGeometry.tuckEdges(area: area, reserved: reserved)
                for count in [1, 2, 3, 5, 9] {
                    for k in 0..<4 {
                        let floats = (0..<count).map { i -> WorkspaceFloat in
                            let width = 120 + Double((i * 37 + k * 11) % 260), height = 90 + Double((i * 53 + k * 7) % 210)
                            return WorkspaceFloat(tile: "f\(i)", frame: WorkspaceRect(x: 0.1, y: 0.1, width: width / w, height: height / h),
                                                  tuck: WorkspaceFloatTuck(edge: edges[(k + i * (k + 1)) % 4], offset: Double((i * 29 + k * 13) % 100) / 100))
                        }
                        let tabs = WorkspaceFloatGeometry.tuckHandles(floats, picture: screen, area: area, reserved: reserved)
                        let ids = tabs.flatMap(\.ids)
                        XCTAssertEqual(ids.sorted(), floats.map(\.tile).sorted(), "each on exactly one handle: \(screen) \(reserved) \(count)")
                        let unreachable = WorkspaceFloatGeometry.unreachableTucked(floats, handles: tabs, reserved: reserved)
                        if open.isEmpty {
                            XCTAssertFalse(reserved.isEmpty)
                        } else {
                            XCTAssertEqual(unreachable, [], "\(screen) \(reserved) \(count) \(k): \(tabs.map { ($0.ids, $0.edge, $0.rect) })")
                            assertApart(tabs)
                            for t in tabs {
                                XCTAssertTrue(open.contains(t.edge), "only on edges with room: \(t)")
                                XCTAssertGreaterThanOrEqual(t.rect.x, area.x - 1e-9)
                                XCTAssertLessThanOrEqual(t.rect.maxX, area.maxX + 1e-9)
                                XCTAssertGreaterThanOrEqual(t.rect.y, area.y - 1e-9)
                                XCTAssertLessThanOrEqual(t.rect.maxY, area.maxY + 1e-9)
                            }
                        }
                    }
                }
            }
            // The last configuration fills every edge: none of them takes a throw.
            XCTAssertTrue(WorkspaceFloatGeometry.tuckEdges(area: area, reserved: controls.last!).isEmpty)
        }
        // Lost handles are caught.
        let one = [WorkspaceFloat(tile: "a", frame: WorkspaceRect(x: 0, y: 0, width: 0.3, height: 0.3), tuck: WorkspaceFloatTuck(edge: .left, offset: 0.5))]
        XCTAssertEqual(WorkspaceFloatGeometry.unreachableTucked(one, handles: [], reserved: []), ["a"])
        let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles(one, picture: phoneScreen, area: phoneSafe).first)
        XCTAssertEqual(WorkspaceFloatGeometry.unreachableTucked(one, handles: [tab, tab], reserved: []), ["a"], "two handles for one")
        XCTAssertEqual(WorkspaceFloatGeometry.unreachableTucked(one, handles: [tab], reserved: [WorkspaceFloatGeometry.touchArea(tab)]), ["a"],
                       "a handle under a control")
    }

    /// A picture with nothing clear of the system's edges still shows a handle for each tucked
    /// float (over the picture itself), so none is ever left without one.
    func testATuckedFloatAlwaysHasAHandle() throws {
        let thin = WorkspaceRect(x: 0, y: 0, width: 390, height: 20)
        XCTAssertNil(WorkspaceFloatGeometry.handleArea(picture: thin, safe: nil, screen: phoneScreen))
        let area = try XCTUnwrap(WorkspaceFloatGeometry.waitingArea(picture: thin, safe: nil, screen: phoneScreen))
        XCTAssertEqual(area, thin)
        let floats = floats([("a", .left, 0.5), ("b", .bottom, 0.3)])
        let tabs = WorkspaceFloatGeometry.tuckHandles(floats, picture: thin, area: area)
        XCTAssertEqual(Set(tabs.flatMap(\.ids)), ["a", "b"])
        XCTAssertEqual(WorkspaceFloatGeometry.waitingArea(picture: phoneScreen, safe: phoneSafe, screen: phoneScreen), phoneSafe)
        XCTAssertNil(WorkspaceFloatGeometry.waitingArea(picture: WorkspaceRect(x: .nan, y: 0, width: 10, height: 10), safe: nil, screen: nil))
    }

    /// A float pulled out of its handle comes straight out of the edge that handle is on, flush
    /// with it: as tucked; after the screen turned (it was flush with the picture's edge, the
    /// strips wait at the safe area's); waiting just above the tray; waiting on another edge.
    func testAFloatComesBackFlushWithTheEdgeItsHandleIsOn() throws {
        let size = WorkspaceSize(width: 390, height: 844)
        func shares(_ r: WorkspaceRect) -> WorkspaceRect { WorkspaceRect(x: r.x / 390, y: r.y / 844, width: r.width / 390, height: r.height / 844) }
        let safe = shares(phoneSafe)
        let frame = WorkspaceFloatGeometry.tuckedFrame(WorkspaceRect(x: 0.2, y: 0.4, width: 200 / 390, height: 140 / 844), edge: .left,
                                                       along: 0.45, in: size, area: safe, safe: safe)
        let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles([WorkspaceFloat(tile: "a", frame: frame, tuck: WorkspaceFloatTuck(edge: .left, offset: 0.45))],
                                                                  picture: phoneScreen, area: phoneSafe).first)
        let back = WorkspaceFloatGeometry.restoreFrame(frame, waiting: shares(tab.float), edge: .left, in: size, area: safe, safe: safe)
        XCTAssertEqual(back, WorkspaceFloatGeometry.comingBack(frame, waiting: shares(tab.float), edge: .left, in: size, safe: safe), "as tucked")

        // Landscape, the Island's side on the left: flush with the picture's edge after a turn,
        // it comes back flush with the safe area's.
        let land = WorkspaceSize(width: 844, height: 390)
        let landSafe = WorkspaceRect(x: 59.0 / 844, y: 0, width: 726.0 / 844, height: 369.0 / 390)
        let turned = WorkspaceRect(x: 0, y: 0.3, width: 200.0 / 844, height: 140.0 / 390)
        let out = WorkspaceFloatGeometry.restoreFrame(turned, waiting: WorkspaceRect(x: -0.1, y: 0.3, width: turned.width, height: turned.height),
                                                      edge: .left, in: land, area: landSafe, safe: landSafe)
        XCTAssertEqual(out.x, landSafe.x, accuracy: 1e-9, "out of the safe area's edge, not from under the Island")

        // Tucked at the bottom, waiting on the right (the bottom full): out of the right edge, where its strip is.
        let low = WorkspaceRect(x: 0.3, y: 1 - 140.0 / 844 - 34.0 / 844, width: 200.0 / 390, height: 140.0 / 844)
        let keypad = WorkspaceRect(x: 0, y: 450, width: 390, height: 394)
        let onRight = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles([WorkspaceFloat(tile: "a", frame: low, tuck: WorkspaceFloatTuck(edge: .bottom, offset: 0.8))],
                                                                       picture: phoneScreen, area: phoneSafe, reserved: [keypad]).first)
        XCTAssertEqual(onRight.edge, .right)
        let fromRight = WorkspaceFloatGeometry.restoreFrame(low, waiting: shares(onRight.float), edge: .right, in: size, area: safe, safe: safe)
        XCTAssertEqual(fromRight.maxX, safe.maxX, accuracy: 1e-9, "flush with the right edge")
        XCTAssertEqual(fromRight.midY * 844, onRight.float.midY, accuracy: 1e-6, "straight out of its strip")
        XCTAssertEqual(fromRight.width, low.width, accuracy: 1e-9, "its own size")
        let path = WorkspaceFloatGeometry.EdgePath(edge: .right, from: onRight.float,
                                                   to: WorkspaceRect(x: fromRight.x * 390, y: fromRight.y * 844, width: fromRight.width * 390, height: fromRight.height * 844),
                                                   clipFrom: onRight.rect, clipTo: phoneScreen)
        XCTAssertEqual(path.rect(0.5).y, onRight.float.y, accuracy: 1e-6, "a straight slide")
        XCTAssertEqual(path.travel, 200 - WorkspaceFloatGeometry.stripDepth, accuracy: 1e-6)

        // Just above the tray: comes back resting on that line, not under the tray.
        let tray = WorkspaceRect(x: 8, y: 754, width: 374, height: 56)
        let inside = shares(try XCTUnwrap(WorkspaceFloatGeometry.stripArea(.bottom, in: phoneSafe, avoiding: [tray])))
        let up = WorkspaceFloatGeometry.restoreFrame(low, waiting: low, edge: .bottom, in: size, area: inside, safe: safe)
        XCTAssertEqual(up.maxY * 844, tray.y - WorkspaceFloatGeometry.tabSpacing, accuracy: 1e-6)
    }

    // MARK: Pulling back out

    /// The way out of an edge is one picture: at its strip at 0 and at its frame at 1, its size
    /// unchanged, moving in a straight line; what shows grows continuously from the strip, and
    /// nothing of it shows beyond the edge until the very end (under the status bar or a notch).
    func testTheWayOutIsOnePictureGrowingContinuously() throws {
        let area = phoneSafe
        // Tucked at the top: the float waits above the safe area's top, its bottom 20 pt showing.
        let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckTabs([("a", 0.5, WorkspaceSize(width: 240, height: 150))], edge: .top,
                                                                 area: area, picture: phoneScreen).first)
        let back = WorkspaceRect(x: tab.float.x, y: area.y + 15, width: 240, height: 150)
        let path = WorkspaceFloatGeometry.EdgePath(edge: .top, from: tab.float, to: back, clipFrom: tab.rect, clipTo: phoneScreen)
        XCTAssertEqual(path.rect(0), tab.float)
        XCTAssertEqual(path.clip(0), tab.rect, "at rest only its strip shows")
        XCTAssertEqual(path.rect(1), back)
        XCTAssertEqual(path.clip(1), phoneScreen)
        XCTAssertEqual(path.travel, back.y - tab.float.y, accuracy: 1e-9)
        var lastShown = try XCTUnwrap(path.rect(0).intersection(path.clip(0))).height
        XCTAssertEqual(lastShown, WorkspaceFloatGeometry.stripDepth, accuracy: 1e-9, "at rest: its strip")
        for i in 0...100 {
            let p = Double(i) / 100
            let r = path.rect(p), c = path.clip(p)
            XCTAssertEqual(r.width, 240, accuracy: 1e-9, "its own size all the way")
            XCTAssertEqual(r.height, 150, accuracy: 1e-9)
            XCTAssertEqual(r.x, tab.float.x, accuracy: 1e-9, "a straight slide")
            XCTAssertLessThanOrEqual(r.maxY, c.maxY + 1e-9, "its inner side is never cut off")
            if p < WorkspaceFloatGeometry.EdgePath.outerHold { XCTAssertEqual(c.y, area.y, accuracy: 1e-9, "nothing past the edge while it's behind it") }
            let shown = (r.intersection(c)?.height ?? 0)
            XCTAssertGreaterThanOrEqual(shown, lastShown - 1e-9, "what shows only grows")
            XCTAssertLessThanOrEqual(shown - lastShown, path.travel / 100 + 1e-6 + (p > WorkspaceFloatGeometry.EdgePath.outerHold ? area.y / 25 : 0),
                                     "and continuously")
            lastShown = shown
        }
        // A finger: one point inward, one point out.
        XCTAssertEqual(path.progress(inward: 10), 10 / path.travel, accuracy: 1e-9)
        XCTAssertEqual(path.progress(inward: 10, from: 0.2), 0.2 + 10 / path.travel, accuracy: 1e-9)
        XCTAssertEqual(path.progress(inward: -50), 0, "pushed back: still in")
        XCTAssertEqual(path.progress(inward: 5000), 1, "never past where it comes back to")
        XCTAssertEqual(path.progress(inward: .nan, from: 0.3), 0.3)

        // A stack's float waits all the way behind the edge, nothing showing.
        let hidden = WorkspaceFloatGeometry.hidden(WorkspaceSize(width: 200, height: 120), edge: .right, area: area, along: 400)
        XCTAssertEqual(hidden.float.x, area.maxX)
        XCTAssertEqual(hidden.float.midY, 400)
        XCTAssertEqual(hidden.line.width, 0)

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

    /// Tucking keeps the float's size and puts it flush with that edge where its strip is, so the
    /// strip and where it comes back to line up: pulling it out is a straight slide. Its title
    /// pill stays reachable (below the Dynamic Island at the top).
    func testATuckedFloatWaitsFlushWithItsEdge() throws {
        let size = WorkspaceSize(width: 390, height: 844)
        let f = WorkspaceRect(x: 0.2, y: 0.4, width: 240 / 390, height: 150 / 844)
        let safe = WorkspaceRect(x: 0, y: 59 / 844, width: 1, height: 751 / 844)
        for edge in [WorkspaceEdge.left, .right, .top, .bottom] {
            let r = WorkspaceFloatGeometry.tuckedFrame(f, edge: edge, along: 0.45, in: size, area: safe, safe: safe)
            XCTAssertEqual(r.width, f.width, accuracy: 1e-9, "\(edge): its own size")
            XCTAssertEqual(r.height, f.height, accuracy: 1e-9)
            XCTAssertEqual(WorkspaceFloatMotion.along(r, edge), 0.45, accuracy: 1e-9, "\(edge): where it was along the edge")
            switch edge {
            case .left: XCTAssertEqual(r.x, 0, accuracy: 1e-9)
            case .right: XCTAssertEqual(r.maxX, 1, accuracy: 1e-9)
            case .top: XCTAssertEqual(r.y * size.height, 59 + WorkspaceFloatLayering.pillHeight / 2, accuracy: 1e-6, "its pill just below the Island")
            case .bottom: XCTAssertEqual(r.maxY, safe.maxY, accuracy: 1e-9)
            }
            // The strip it leaves and where it comes back to line up.
            let pictureRect = WorkspaceRect(x: 0, y: 0, width: size.width, height: size.height)
            let area = WorkspaceRect(x: 0, y: 59, width: 390, height: 751)
            let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles([WorkspaceFloat(tile: "a", frame: r, tuck: WorkspaceFloatTuck(edge: edge, offset: WorkspaceFloatMotion.along(r, edge)))],
                                                                      picture: pictureRect, area: area).first)
            let back = WorkspaceRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
            if edge.axis == .horizontal {
                XCTAssertEqual(tab.float.y, back.y, accuracy: 1e-6, "\(edge): a straight slide out")
            } else {
                XCTAssertEqual(tab.float.x, back.x, accuracy: 1e-6, "\(edge): a straight slide out")
            }
        }
        // Near an end of the edge: kept inside, the strip still where the float is.
        let low = WorkspaceFloatGeometry.tuckedFrame(f, edge: .right, along: 0.99, in: size)
        XCTAssertLessThanOrEqual(low.maxY, 1 + 1e-9)
    }

    /// A strip that slid along its edge to make room (here, kept out of the edge's end band) is
    /// where its window comes back out: straight out of it, flush with the edge, at its own size,
    /// its title pill reachable.
    func testAFloatComesStraightOutOfWhereItsStripIs() throws {
        let size = WorkspaceSize(width: 390, height: 844)
        let safe = WorkspaceRect(x: 0, y: 59 / 844, width: 1, height: 751 / 844)
        // Tucked left high up, in the end band at the top of the left edge.
        let r = WorkspaceFloatGeometry.tuckedFrame(WorkspaceRect(x: 0.3, y: 0.1, width: 220 / 390, height: 160 / 844), edge: .left,
                                                   along: 0.15, in: size, area: safe, safe: safe)
        let tab = try XCTUnwrap(WorkspaceFloatGeometry.tuckHandles([WorkspaceFloat(tile: "a", frame: r, tuck: WorkspaceFloatTuck(edge: .left, offset: WorkspaceFloatMotion.along(r, .left)))],
                                                                  picture: phoneScreen, area: phoneSafe).first)
        XCTAssertEqual(tab.rect.y, WorkspaceFloatGeometry.run(.left, in: phoneSafe).lo, accuracy: 1e-9, "its strip slid down out of the end band")
        XCTAssertGreaterThan(tab.float.y, r.y * size.height + 1, "so the window waits lower than it was")
        let waiting = WorkspaceRect(x: tab.float.x / 390, y: tab.float.y / 844, width: tab.float.width / 390, height: tab.float.height / 844)
        let back = WorkspaceFloatGeometry.comingBack(r, waiting: waiting, edge: .left, in: size, safe: safe)
        XCTAssertEqual(back.y * 844, tab.float.y, accuracy: 1e-6, "out where its strip is")
        XCTAssertEqual(back.x, 0, accuracy: 1e-9, "flush with the edge")
        XCTAssertEqual(back.width, r.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, r.height, accuracy: 1e-9)
        let to = WorkspaceRect(x: back.x * 390, y: back.y * 844, width: back.width * 390, height: back.height * 844)
        let path = WorkspaceFloatGeometry.EdgePath(edge: .left, from: tab.float, to: to, clipFrom: tab.rect, clipTo: phoneScreen)
        XCTAssertEqual(path.rect(0.5).y, tab.float.y, accuracy: 1e-6, "a straight slide")
        XCTAssertEqual(path.travel, 220 - WorkspaceFloatGeometry.stripDepth, accuracy: 1e-6)

        // At the top: its title pill stays below the Island, wherever its strip is.
        let top = WorkspaceFloatGeometry.comingBack(WorkspaceRect(x: 0.1, y: 0, width: 0.5, height: 0.2),
                                                    waiting: WorkspaceRect(x: 0.3, y: -0.15, width: 0.5, height: 0.2), edge: .top, in: size, safe: safe)
        XCTAssertEqual(top.x, 0.3, accuracy: 1e-9, "out where its strip is")
        XCTAssertEqual(top.y * 844, 59 + WorkspaceFloatLayering.pillHeight / 2, accuracy: 1e-6)
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

    /// Tucked into the top edge (a still asked for first, for its strip), it waits flush with that
    /// edge and isn't sent; restored, it's sent again at once but lifted (the Mac leaves it out
    /// while this device slides it out), and lands when the slide ends. Nothing of it acts on
    /// the Mac window.
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
        XCTAssertEqual(m.layout.float(fid)?.tuck?.edge, .top)
        XCTAssertEqual(m.layout.float(fid)?.tuck?.offset ?? 0, 0.3, accuracy: 1e-9)
        let waiting = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(waiting.width, frame.width, accuracy: 1e-9, "it waits at its own size")
        XCTAssertEqual(waiting.height, frame.height, accuracy: 1e-9)
        XCTAssertEqual(waiting.y * ipad.height, WorkspaceFloatGeometry.barHeight, accuracy: 1e-6, "flush with the top")
        XCTAssertEqual(waiting.midX, 0.3, accuracy: 1e-9, "where its strip is")
        XCTAssertTrue(sent.contains { $0["type"] as? String == WireMessage.workspaceBackdropRequest && $0["tile"] as? String == fid },
                      "a still for its strip, asked for while it's still sent")
        settle()
        XCTAssertNil(lastTile(sent, fid), "tucked: not sent")

        m.beginRestoringFloat(fid)
        XCTAssertNil(m.layout.float(fid)?.tuck)
        XCTAssertEqual(m.layout.float(fid)?.frame, waiting, "back where it waited: a straight slide out of its edge")
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

    /// The model side of a tuck: it waits flush with its edge at its own size (or where the view
    /// says, kept inside), comes back there or where it's told to land, follows its strip when
    /// that's slid along the edge, and stays flush through a rotation. None of it is ever sent.
    @MainActor
    func testATuckedFloatWaitsFlushAndComesBackThere() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature,
                                          WindowWorkspaceWire.floatLiftFeature]) { sent.append($0) }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        let frame = try XCTUnwrap(m.layout.float(fid)?.frame)

        m.tuckFloat(fid, edge: .right, offset: 0.4)
        let waiting = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(waiting.maxX, 1, accuracy: 1e-9, "flush with the right edge")
        XCTAssertEqual(waiting.midY, 0.4, accuracy: 1e-9)
        XCTAssertEqual(waiting.width, frame.width, accuracy: 1e-9)
        // The view's own place (in its safe area) wins.
        m.untuckFloat(fid)
        let told = WorkspaceRect(x: 0.5, y: 0.3, width: frame.width, height: frame.height)
        m.tuckFloat(fid, edge: .right, offset: 0.4, frame: told)
        XCTAssertEqual(m.layout.float(fid)?.frame, told)
        XCTAssertEqual(m.layout.float(fid)?.tuck?.offset ?? 0, told.midY, accuracy: 1e-9, "its strip waits where it is along the edge")

        // Slid along its edge: it waits there, still flush.
        m.moveTuckTab(fid, offset: 0.7)
        let slid = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(slid.midY, 0.7, accuracy: 1e-9)
        XCTAssertEqual(slid.x, told.x, accuracy: 1e-9, "only along the edge")
        XCTAssertEqual(m.layout.float(fid)?.tuck?.offset ?? 0, 0.7, accuracy: 1e-9)

        // Rotated: still flush with its edge, at its size in points, where it was along it.
        m.updateSpace(WorkspaceSize(width: ipad.height, height: ipad.width), hinge: nil)
        let turned = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(turned.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(turned.width * ipad.height, frame.width * ipad.width, accuracy: 1)
        XCTAssertEqual(m.layout.float(fid)?.tuck?.edge, .right)
        m.updateSpace(ipad, hinge: nil)

        // Back where the view lands it, lifted on the way, never acting on the Mac window.
        let landing = WorkspaceRect(x: 1 - frame.width, y: 0.2, width: frame.width, height: frame.height)
        m.beginRestoringFloat(fid, frame: landing)
        XCTAssertEqual(m.layout.float(fid)?.frame, landing)
        XCTAssertTrue(m.drawsFloatHere(fid))
        m.endFloatGesture(fid)
        settle()
        XCTAssertTrue(sent.allSatisfy { Self.safeTypes.contains($0["type"] as? String ?? "") }, "\(sent.map { $0["type"] ?? "" })")
        XCTAssertTrue(sent.filter { $0["type"] as? String == WireMessage.workspaceFocus }.allSatisfy { $0["raise"] as? Bool == false })
    }
}
