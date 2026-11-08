import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Circling while moving a float docks it into the panes (Shared/WorkspaceFloats.swift,
/// `WorkspaceFloatMove`, and `WorkspaceModel.moveFloatFinger` / `endDockingFloat` /
/// `cancelDockingFloat`), the path the float layer drives from its title's move gesture.
///
/// XCUITest can't draw a circle (only press-and-drag to one point), so the touch path itself
/// (gesture → card → drop) needs a person on a device; these drive the same model calls the
/// view makes, sample by sample.
final class WorkspaceFloatDockingTests: XCTestCase {
    private let ipad = WorkspaceSize(width: 1180, height: 820)

    // MARK: The pure move

    private func floats() -> WorkspaceLayout {
        var l = WorkspaceLayout(root: .slot("a"), tiles: ["a": WorkspaceTile(id: "a", source: WorkspaceSource(host: "mac-a", windowID: 10, bundleID: "app.10"))])
        l = l.addingFloat(WorkspaceTile(id: "f1", source: WorkspaceSource(host: "mac-a", windowID: 11, bundleID: "app.11")),
                          frame: WorkspaceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        l = l.addingFloat(WorkspaceTile(id: "f2", source: WorkspaceSource(host: "mac-a", windowID: 12, bundleID: "app.12")),
                          frame: WorkspaceRect(x: 0.5, y: 0.3, width: 0.3, height: 0.3))
        return l
    }

    /// Feeds a path at 60 Hz from `t0` for `seconds`; returns the switches with their times.
    private func feed(_ m: inout WorkspaceFloatMove, from t0: Double = 0, seconds: Double,
                      _ path: (Double) -> (x: Double, y: Double)) -> [(Double, WorkspaceFloatMove.Switch)] {
        var out: [(Double, WorkspaceFloatMove.Switch)] = []
        var t = t0
        while t <= t0 + seconds {
            let p = path(t - t0)
            if let s = m.add(x: p.x, y: p.y, at: t) { out.append((t, s)) }
            t += 1.0 / 60
        }
        return out
    }

    private func loop(_ cx: Double = 300, _ cy: Double = 400, radius: Double = 50) -> (Double) -> (x: Double, y: Double) {
        { t in (cx + radius * cos(2 * .pi * t), cy + radius * sin(2 * .pi * t)) }
    }

    func testAMoveDocksOnlyOnACircleAndCirclingAgainFloatsIt() throws {
        let l = floats()
        XCTAssertNil(WorkspaceFloatMove("a", in: l), "a pane isn't a float")
        var m = try XCTUnwrap(WorkspaceFloatMove("f1", in: l))
        XCTAssertEqual(m.frame, WorkspaceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        XCTAssertEqual(m.index, 0)

        // A shake, a zig-zag, a straight move: never docks.
        XCTAssertTrue(feed(&m, seconds: 3) { t in (300 + 40 * sin(2 * .pi * 4 * t), 400) }.isEmpty)
        XCTAssertTrue(feed(&m, from: 4, seconds: 3) { t in
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (100 + 200 * t, 400 + (phase < 0.5 ? phase : 1 - phase) * 120)
        }.isEmpty)
        XCTAssertTrue(feed(&m, from: 8, seconds: 2) { t in (100 + 250 * t, 300 + 80 * t) }.isEmpty)
        XCTAssertFalse(m.docking)

        // A circle: docks once; circling on doesn't switch back.
        let first = feed(&m, from: 11, seconds: 4, loop())
        XCTAssertEqual(first.map { $0.1 }, [.dock])
        XCTAssertEqual(first.first?.0 ?? 0, 12.4, accuracy: 0.3, "a circle and a bit after it began")
        XCTAssertTrue(m.docking)
        // A pause, then another circle: back to a float.
        XCTAssertEqual(feed(&m, from: 15.6, seconds: 2, loop()).map { $0.1 }, [.float])
        XCTAssertFalse(m.docking)
    }

    func testRestoringPutsTheFloatBackWhereItWasAndInItsPlace() throws {
        var l = floats()
        let m = try XCTUnwrap(WorkspaceFloatMove("f1", in: l))
        // The finger raised it and moved it.
        l = l.raisingFloat("f1").settingFloatFrame("f1", WorkspaceRect(x: 0.6, y: 0.5, width: 0.3, height: 0.3))
        XCTAssertEqual(l.floatIDs, ["f2", "f1"])
        let back = m.restoring(l)
        XCTAssertEqual(back, floats(), "frame and place back to front exactly as before")
        XCTAssertEqual(m.restoring(back.removing("f1")), back.removing("f1"), "gone: nothing to put back")
    }

    /// Ordinary moves of a float, however they curve, never dock it: round another float (all the
    /// way round it), a long sweeping loop, nudging it back and forth past its spot.
    func testAnOrdinaryCurvedMoveNeverDocks() throws {
        var m = try XCTUnwrap(WorkspaceFloatMove("f1", in: floats()))
        // Round a 300 x 260 float, 40 pt clear of it, the whole way round and a bit, at 350 pt/s.
        var t = 0.0
        let corners: [(x: Double, y: Double, from: Double)] = [(450, 400, 0.5), (150, 400, 1), (150, 140, 1.5), (450, 140, 0)]
        var points: [(x: Double, y: Double)] = []
        for (x, y, from) in corners + [corners[0]] {
            for i in 0...10 { let a = (from + Double(i) / 20) * .pi; points.append((x + 40 * cos(a), y + 40 * sin(a))) }
        }
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / (350.0 / 60)), 1)
            for s in 1...steps {
                t += 1.0 / 60
                XCTAssertNil(m.add(x: a.x + (b.x - a.x) * Double(s) / Double(steps), y: a.y + (b.y - a.y) * Double(s) / Double(steps), at: t))
            }
        }
        // A big loop and a half across the screen.
        XCTAssertTrue(feed(&m, from: t + 1, seconds: 4.5) { t in (590 + 200 * cos(2 * .pi * 0.33 * t), 410 + 200 * sin(2 * .pi * 0.33 * t)) }.isEmpty)
        // Back and forth past a spot, both ends turning the same way (a stretched loop).
        XCTAssertTrue(feed(&m, from: t + 6, seconds: 4) { t in
            let a = 2 * .pi * 0.8 * t
            return (300 + 120 * cos(a) + 40 * cos(3 * a), 400 + 15 * sin(a))
        }.isEmpty)
        XCTAssertFalse(m.docking)
    }

    /// In one hold, with no pause: a circle docks; circling on doesn't undock; a circle the
    /// other way round undocks at once; the first way round again docks again.
    func testCirclingTheOtherWayUndocksAndDocksAgainInOneHold() throws {
        var m = try XCTUnwrap(WorkspaceFloatMove("f1", in: floats()))
        var t = 0.0, a = 0.0
        var centre = (x: 300.0, y: 400.0)
        var switches: [WorkspaceFloatMove.Switch] = []
        // One loop a second, 50 pt round, clockwise on screen unless `ccw`. Each new circle starts
        // where the finger is, heading on the way it was (an S, as a hand does it).
        func circle(seconds: Double, ccw: Bool) {
            for _ in 0..<Int(seconds * 60) {
                t += 1.0 / 60
                a += (ccw ? -1 : 1) * 2 * .pi / 60
                if let s = m.add(x: centre.x + 50 * cos(a), y: centre.y + 50 * sin(a), at: t) { switches.append(s) }
            }
        }
        func reverse() {
            centre = (centre.x + 100 * cos(a), centre.y + 100 * sin(a))
            a += .pi
        }
        circle(seconds: 3, ccw: false)
        XCTAssertEqual(switches, [.dock], "one switch for three seconds of circling")
        reverse()
        circle(seconds: 1.4, ccw: true)
        XCTAssertEqual(switches, [.dock, .float])
        XCTAssertFalse(m.docking)
        reverse()
        circle(seconds: 1.4, ccw: false)
        XCTAssertEqual(switches, [.dock, .float, .dock])
        XCTAssertTrue(m.docking)
    }

    // MARK: The model, as the float layer drives it

    @MainActor
    private func connectedModel(lift: Bool = true, sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let defaults = UserDefaults(suiteName: "WorkspaceFloatDockingTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        m.floatsDrawnHere = true   // the iPhone/iPad receiver (this test runs on the Mac)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        var features: Set<String> = [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]
        if lift { features.insert(WindowWorkspaceWire.floatLiftFeature) }
        m.apply(.features(features))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [10, 11, 12, 13].map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [], "displays": [],
        ])!)
        m.updateSpace(ipad, hinge: nil)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        m.cancelZoneGlobal = CGRect(x: 400, y: 740, width: 120, height: 44)    // ends at x 520
        m.removeZoneGlobal = CGRect(x: 532, y: 740, width: 220, height: 44)    // 12 pt later
        return m
    }

    /// Two panes side by side and two floats over them (back, front).
    @MainActor
    private func arranged(_ m: WorkspaceModel) throws -> (panes: [String], back: String, front: String) {
        let w = try XCTUnwrap(m.catalog?.windows)
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        m.openFloating(w[2], at: WorkspacePoint(x: 0.3, y: 0.4))
        m.openFloating(w[3], at: WorkspacePoint(x: 0.6, y: 0.5))
        let f = m.layout.floatIDs
        XCTAssertEqual(f.count, 2)
        return (m.layout.orderedTileIDs, f[0], f[1])
    }

    private func png() -> Data {
        let ctx = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func lastTile(_ sent: [[String: Any]], _ id: String) -> [String: Any]? {
        let tiles = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        return tiles.first { $0["id"] as? String == id }
    }

    /// Nothing a float does is a window action or pointer input.
    private let allowed: Set<String> = [WireMessage.workspaceRequest, WireMessage.workspaceFocus, WireMessage.workspaceBackdropRequest,
                                        WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest]

    /// The view's move: the finger takes the float, drags it by `by` (global points) in a straight
    /// line, then circles until it docks. Returns the time after the switch.
    @MainActor
    @discardableResult
    private func moveThenCircle(_ m: WorkspaceModel, _ id: String, by: CGVector = CGVector(dx: 120, dy: 60),
                                around c: CGPoint, from t0: Double = 0) -> (switched: WorkspaceFloatMove.Switch?, t: Double) {
        let start = m.layout.float(id)!.frame
        // What the view does while it moves the float: it follows the finger.
        func follow(_ p: CGPoint) {
            var f = start
            f.x += (p.x - c.x) / ipad.width; f.y += (p.y - c.y) / ipad.height
            m.updateFloatFrame(id, f)
        }
        var t = t0
        for i in 1...20 {
            t += 1.0 / 60
            let p = CGPoint(x: c.x + by.dx * Double(i) / 20, y: c.y + by.dy * Double(i) / 20)
            XCTAssertNil(m.moveFloatFinger(id, to: p, at: t), "a straight move never switches")
            follow(p)
        }
        let centre = CGPoint(x: c.x + by.dx, y: c.y + by.dy)
        for i in 1...150 {
            t += 1.0 / 60
            let a = Double(i) / 60 * 2 * .pi
            let p = CGPoint(x: centre.x - 50 + 50 * cos(a), y: centre.y + 50 * sin(a))
            if let s = m.moveFloatFinger(id, to: p, at: t) { return (s, t) }
            follow(p)
        }
        return (nil, t)
    }

    /// Picked up, circled into a card, dropped on a pane: it docks there exactly as a pane drag
    /// would (a tab in the middle), the card is the only thing drawn for it meanwhile (the Mac
    /// leaves it out even before a still arrived), and one Undo puts it back as it was.
    @MainActor
    func testACircledFloatDocksWhereItsDroppedAndIsNeverShownBehindTheCard() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel { sent.append($0) }
        let (panes, back, front) = try arranged(m)
        let before = m.layout
        sent.removeAll()

        // No still yet (the request is in flight): docking still lifts it.
        m.beginFloatGesture(front)
        let (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        XCTAssertEqual(m.dockingFloat, front)
        XCTAssertEqual(m.drag?.item, .float(front))
        XCTAssertEqual(m.drag?.placement, .pane, "the pane drop targets")
        XCTAssertTrue(m.liftedFloats.contains(front), "the Mac leaves it out (no still needed: only the card shows)")
        XCTAssertEqual(lastTile(sent, front)?["lift"] as? Bool, true, "sent at once")
        XCTAssertEqual(m.layout.float(front)?.frame, before.float(front)?.frame, "back where the move began, under the card")
        XCTAssertNotNil(m.layout.float(back), "the other float is untouched")

        // Where the docking float was, the pane under it is the target now (it isn't drawn there).
        let ff = before.float(front)!.frame
        let underIt = CGPoint(x: ff.midX * ipad.width, y: ff.midY * ipad.height)
        XCTAssertFalse(before.float(back)!.frame.contains(WorkspacePoint(x: ff.midX, y: ff.midY)))
        XCTAssertNotNil(m.dropTarget(forGlobal: underIt))
        // Over the other float: no target (a float never docks onto a float).
        let bf = before.float(back)!.frame
        let onBack = CGPoint(x: (bf.x + 0.02) * ipad.width, y: (bf.y + 0.02) * ipad.height)
        XCTAssertFalse(ff.contains(WorkspacePoint(x: bf.x + 0.02, y: bf.y + 0.02)))
        XCTAssertNil(m.dropTarget(forGlobal: onBack))

        // Following the finger to the middle of the second pane (below the floats): a tab there.
        let pane = try XCTUnwrap(m.frames.tiles[panes[1]])
        let target = CGPoint(x: pane.midX * ipad.width, y: (pane.y + pane.height * 0.72) * ipad.height)
        XCTAssertNil(m.moveFloatFinger(front, to: target, at: t + 0.5))
        XCTAssertEqual(m.drag?.location, target)
        guard case .tab(let tile, _)? = m.dropTarget(forGlobal: target), tile == panes[1] else {
            return XCTFail("the middle of a pane takes a docked float as a tab, never replacing: \(String(describing: m.dropTarget(forGlobal: target)))")
        }
        XCTAssertTrue(m.endDockingFloat(front))
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag)
        XCTAssertEqual(m.layout.floatIDs, [back])
        XCTAssertEqual(Set(m.layout.tiles.values.flatMap(\.windows).map(\.windowID)), [10, 11, 12, 13], "every window still here")
        XCTAssertTrue(m.liftedFloats.isEmpty)
        XCTAssertFalse(m.drawsFloatHere(front), "a pane now: nothing to land")
        XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") }, "\(sent.map { $0["type"] ?? "" })")
        XCTAssertTrue(sent.filter { $0["type"] as? String == WireMessage.workspaceFocus }.allSatisfy { $0["raise"] as? Bool == false },
                      "arranging never brings the Mac window forward")

        // One undo step: the float, where it was, in its place; the step before is opening it.
        m.undo()
        XCTAssertEqual(m.layout, before)
        m.undo()
        XCTAssertNil(m.layout.float(front))
        XCTAssertNotNil(m.layout.float(back))
    }

    /// The Mac locking while a float docks: it is put back as on a cancel, and the Mac draws it
    /// again after the unlock (#217 with #215's abandonDrag).
    @MainActor
    func testTheMacLockingMidDockPutsTheFloatBack() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel { sent.append($0) }
        let (_, back, _) = try arranged(m)
        let before = m.layout
        m.beginFloatGesture(back)
        let (switched, _) = moveThenCircle(m, back, around: CGPoint(x: 360, y: 330))
        XCTAssertEqual(switched, .dock)
        XCTAssertEqual(m.dockingFloat, back)
        m.apply(.macLock(MacLockNotice(state: .locked)))
        XCTAssertEqual(m.layout, before, "put back exactly")
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag)
        XCTAssertNil(m.floatGesture)
        XCTAssertFalse(m.liftedFloats.contains(back), "the Mac draws it again")
    }

    /// Cancel, a release on no target, or the system cancelling the touch: the float comes back
    /// exactly as it was (frame, size, view, behind the same float), drawn by the Mac again,
    /// with no undo step.
    @MainActor
    func testCancelNowhereOrASystemCancelPutsTheFloatBackExactly() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel { sent.append($0) }
        let (_, back, _) = try arranged(m)
        let unrotated = m.layout
        m.rotate(back)   // a view of its own, kept
        let before = m.layout

        for end in ["cancel", "outside", "system", "abandoned"] {
            sent.removeAll()
            m.beginFloatGesture(back)
            m.apply(.backdrop(tile: back, windowID: 12, data: png(), stale: false))
            m.liftFloat(back)
            XCTAssertEqual(m.layout.floatIDs.last, back, "touched: in front while it moves")
            let (switched, t) = moveThenCircle(m, back, around: CGPoint(x: 360, y: 330))
            XCTAssertEqual(switched, .dock, end)
            switch end {
            case "cancel":
                let onCancel = CGPoint(x: 460, y: 760)
                m.moveFloatFinger(back, to: onCancel, at: t + 0.3)
                XCTAssertTrue(m.overCancelZone(onCancel))
                XCTAssertNil(m.dropTarget(forGlobal: onCancel))
                XCTAssertFalse(m.endDockingFloat(back), end)
            case "outside":
                m.moveFloatFinger(back, to: CGPoint(x: 1300, y: 400), at: t + 0.3)
                XCTAssertFalse(m.endDockingFloat(back), end)
            case "abandoned":
                m.abandonDrag(reason: "no finger down")   // the gesture's end never came (WorkspaceDragGuard)
            default:
                m.cancelDockingFloat(back)   // the touch went to a call or Control Center
            }
            XCTAssertEqual(m.layout, before, "\(end): frame, size, view and place among the floats as before")
            XCTAssertNil(m.dockingFloat)
            XCTAssertNil(m.drag)
            XCTAssertFalse(m.liftedFloats.contains(back), "\(end): the Mac draws it again")
            XCTAssertTrue(m.drawsFloatHere(back), "\(end): drawn here from its still until the Mac's frame with it is out")
            let landed = try XCTUnwrap(lastTile(sent, back))
            XCTAssertNil(landed["lift"])
            XCTAssertEqual(landed["x"] as? Double ?? -1, before.float(back)!.frame.x, accuracy: 1e-9)
            XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") }, end)
        }
        m.undo()
        XCTAssertEqual(m.layout, unrotated, "the cancelled moves left no undo step: one Undo takes back the rotation")
    }

    /// A second circle while it docks opens the card back into the float under the finger, which
    /// moves on (still lifted, drawn here from its still); without a recent still the Mac draws it
    /// again instead of nothing being drawn. Letting go then lands it as a move: one undo step.
    @MainActor
    func testCirclingAgainTurnsTheCardBackIntoTheFloat() throws {
        let m = connectedModel { _ in }
        let (_, _, front) = try arranged(m)
        let before = m.layout

        m.beginFloatGesture(front)
        m.apply(.backdrop(tile: front, windowID: 13, data: png(), stale: false))
        m.liftFloat(front)
        var (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        // Circling on: nothing more. A pause, then a second circle: a float again.
        for i in 1...60 {
            let a = Double(i) / 60 * 2 * .pi
            XCTAssertNil(m.moveFloatFinger(front, to: CGPoint(x: 700 + 50 * cos(a), y: 460 + 50 * sin(a)), at: t + Double(i) / 60))
        }
        t += 1.6
        var back: WorkspaceFloatMove.Switch?
        for i in 1...150 where back == nil {
            let a = Double(i) / 60 * 2 * .pi
            back = m.moveFloatFinger(front, to: CGPoint(x: 700 + 50 * cos(a), y: 460 + 50 * sin(a)), at: t + Double(i) / 60)
        }
        XCTAssertEqual(back, .float)
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag, "the drop targets go")
        XCTAssertTrue(m.liftedFloats.contains(front), "drawn here under the finger, from its still")
        XCTAssertTrue(m.layout.isFloat(front))
        m.updateFloatFrame(front, WorkspaceRect(x: 0.4, y: 0.4, width: before.float(front)!.frame.width, height: before.float(front)!.frame.height))
        m.endFloatGesture(front)
        XCTAssertFalse(m.liftedFloats.contains(front))
        XCTAssertEqual(m.layout.float(front)?.frame.x ?? 0, 0.4, accuracy: 1e-9)
        m.undo()
        XCTAssertEqual(m.layout, before, "the whole move is one undo step")

        // Without a recent still: circled back, the Mac draws it again (never an empty frame).
        let bare = connectedModel { _ in }
        let (_, _, f2) = try arranged(bare)
        bare.beginFloatGesture(f2)
        (switched, t) = moveThenCircle(bare, f2, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        XCTAssertTrue(bare.liftedFloats.contains(f2), "hidden while it's a card, still or not")
        back = nil
        for i in 1...150 where back == nil {
            let a = Double(i) / 60 * 2 * .pi
            back = bare.moveFloatFinger(f2, to: CGPoint(x: 700 + 50 * cos(a), y: 400 + 50 * sin(a)), at: t + 1 + Double(i) / 60)
        }
        XCTAssertEqual(back, .float)
        XCTAssertFalse(bare.liftedFloats.contains(f2), "no still to draw it from: the Mac draws it while it moves")
        bare.endFloatGesture(f2)
    }

    /// In the same hold, with no pause: circled into a card, a circle the other way round opens
    /// it back into the float as soon as that circle is complete, the first way round again folds
    /// it once more, and Cancel then puts it back exactly as the finger found it.
    @MainActor
    func testCirclingTheOtherWayTurnsTheCardBackAtOnce() throws {
        let m = connectedModel { _ in }
        let (_, _, front) = try arranged(m)
        let before = m.layout
        m.beginFloatGesture(front)
        var (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        // `moveThenCircle` circles 50 pt round (770, 460), one loop a second from 20/60 s.
        var centre = CGPoint(x: 770, y: 460)
        var a = (t - 20.0 / 60) * 2 * .pi
        var steps: [WorkspaceFloatMove.Switch] = []
        func circle(seconds: Double, ccw: Bool) {
            for _ in 0..<Int(seconds * 60) {
                t += 1.0 / 60
                a += (ccw ? -1 : 1) * 2 * .pi / 60
                if let s = m.moveFloatFinger(front, to: CGPoint(x: centre.x + 50 * cos(a), y: centre.y + 50 * sin(a)), at: t) { steps.append(s) }
            }
        }
        func reverse() {   // straight on into a circle the other way round (an S)
            centre = CGPoint(x: centre.x + 100 * cos(a), y: centre.y + 100 * sin(a))
            a += .pi
        }
        circle(seconds: 1, ccw: false)
        XCTAssertEqual(steps, [], "circling on: still a card")
        XCTAssertEqual(m.dockingFloat, front)
        reverse()
        let reversed = t
        circle(seconds: 1.4, ccw: true)
        XCTAssertEqual(steps, [.float], "the other way round: the float again")
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag, "the drop targets go")
        reverse()
        circle(seconds: 1.4, ccw: false)
        XCTAssertEqual(steps, [.float, .dock], "and back into a card, still the same hold")
        XCTAssertEqual(m.dockingFloat, front)
        XCTAssertGreaterThan(t - reversed, 2.4, "each switch took its own circle")
        let onCancel = CGPoint(x: 460, y: 760)
        m.moveFloatFinger(front, to: onCancel, at: t + 0.3)
        XCTAssertFalse(m.endDockingFloat(front))
        XCTAssertEqual(m.layout, before, "Cancel: back exactly as it was")
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag)
    }

    /// Shakes, zig-zags and plain moves of a float never dock it; a tap or a resize never does either.
    @MainActor
    func testAnIncorrectGestureNeverDocks() throws {
        let m = connectedModel { _ in }
        let (_, _, front) = try arranged(m)
        m.beginFloatGesture(front)
        var t = 0.0
        for _ in 0..<240 {   // four seconds of shaking
            t += 1.0 / 60
            XCTAssertNil(m.moveFloatFinger(front, to: CGPoint(x: 600 + 40 * sin(2 * .pi * 4 * t), y: 400), at: t))
        }
        for i in 0..<240 {   // a zig-zag
            t += 1.0 / 60
            let phase = (Double(i) / 20).truncatingRemainder(dividingBy: 1)
            XCTAssertNil(m.moveFloatFinger(front, to: CGPoint(x: 200 + 3 * Double(i), y: 400 + (phase < 0.5 ? phase : 1 - phase) * 120), at: t))
        }
        for i in 0..<120 {   // a figure eight
            t += 1.0 / 60
            let a = 2 * .pi * 0.8 * Double(i) / 60
            XCTAssertNil(m.moveFloatFinger(front, to: CGPoint(x: 600 + 80 * sin(a), y: 400 + 50 * sin(2 * a)), at: t))
        }
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.drag)
        m.endFloatGesture(front)
        XCTAssertNil(m.moveFloatFinger(front, to: CGPoint(x: 600, y: 400), at: t + 1), "no move after the gesture ended")
        XCTAssertTrue(m.layout.isFloat(front))
    }

    /// Remove from This Device for a float being docked: released on it the float is removed
    /// here only (the Mac window stays open; nothing but the layout is sent; Undo brings it back);
    /// Cancel changes nothing; where the two zones' margins meet, Cancel wins, so the highlight,
    /// the haptic and the drop agree and nothing is removed by a near miss.
    @MainActor
    func testAFloatReleasedOnRemoveIsRemovedFromThisDeviceOnly() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel { sent.append($0) }
        let (_, back, front) = try arranged(m)
        let before = m.layout

        m.beginFloatGesture(front)
        var (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        XCTAssertTrue(m.canDropToRemove, "offered for a float being docked")
        XCTAssertTrue(m.drag?.isFloat == true, "labelled Remove from This Device")
        XCTAssertFalse(m.canDropToFloat, "no Float zone: circling back is the way")

        // Between the zones (inside both 8 pt margins): Cancel.
        let between = CGPoint(x: 526, y: 760)
        m.moveFloatFinger(front, to: between, at: t + 0.3)
        XCTAssertTrue(m.overCancelZone(between))
        XCTAssertFalse(m.overRemoveZone(between), "only one zone lights at a time")
        XCTAssertFalse(m.endDockingFloat(front))
        XCTAssertEqual(m.layout, before, "a near miss removes nothing")

        // On Remove: gone from this device only.
        sent.removeAll()
        m.beginFloatGesture(front)
        (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400), from: 100)
        XCTAssertEqual(switched, .dock)
        let onRemove = CGPoint(x: 650, y: 760)
        m.moveFloatFinger(front, to: onRemove, at: t + 0.3)
        XCTAssertTrue(m.overRemoveZone(onRemove))
        XCTAssertNil(m.dropTarget(forGlobal: onRemove), "Remove is not also a pane drop")
        XCTAssertTrue(m.endDockingFloat(front))
        XCTAssertNil(m.layout.tiles[front])
        XCTAssertEqual(m.layout.floatIDs, [back])
        XCTAssertTrue(m.liftedFloats.isEmpty)
        let types = sent.compactMap { $0["type"] as? String }
        XCTAssertFalse(types.contains(WireMessage.windowClose), "never closes the Mac window")
        XCTAssertFalse(types.contains(WireMessage.windowAction), "never minimizes or moves it")
        XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") }, "\(types)")
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertFalse(request.contains { $0["id"] as? String == front }, "no longer asked for")
        m.undo()
        XCTAssertEqual(m.layout, before, "Undo brings it back where it was")

        // A pane's label still gets Remove from Layout; a tab or a Stage Peek window doesn't.
        let pane = m.layout.orderedTileIDs[0]
        m.beginDrag(.pane(pane, tab: nil), at: CGPoint(x: 200, y: 20))
        XCTAssertTrue(m.canDropToRemove)
        XCTAssertFalse(m.drag?.isFloat == true)
        m.cancelDrag()
        m.beginDrag(.window(m.catalog!.windows[0]), at: CGPoint(x: 200, y: 400))
        XCTAssertFalse(m.canDropToRemove)
        m.cancelDrag()
    }

    /// A Mac without `floatLift` can't leave the float out: it keeps drawing it where the move
    /// began while the card is shown, and nothing is ever sent with `lift`.
    @MainActor
    func testAMacWithoutLiftKeepsDrawingItAndDockingStillWorks() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(lift: false) { sent.append($0) }
        let (panes, _, front) = try arranged(m)
        m.beginFloatGesture(front)
        let (switched, t) = moveThenCircle(m, front, around: CGPoint(x: 700, y: 400))
        XCTAssertEqual(switched, .dock)
        XCTAssertTrue(m.liftedFloats.isEmpty)
        let pane = try XCTUnwrap(m.frames.tiles[panes[0]])
        let target = CGPoint(x: pane.midX * ipad.width, y: (pane.y + pane.height * 0.72) * ipad.height)
        m.moveFloatFinger(front, to: target, at: t + 0.3)
        XCTAssertTrue(m.endDockingFloat(front))
        XCTAssertFalse(m.layout.isFloat(front))
        XCTAssertFalse(sent.contains { ($0["tiles"] as? [[String: Any]])?.contains { $0["lift"] != nil } == true })
    }

    /// Disconnecting mid-dock forgets it.
    @MainActor
    func testDisconnectingWhileDockingForgetsIt() throws {
        let m = connectedModel { _ in }
        let (_, _, front) = try arranged(m)
        m.beginFloatGesture(front)
        XCTAssertEqual(moveThenCircle(m, front, around: CGPoint(x: 700, y: 400)).switched, .dock)
        m.apply(.disconnected)
        XCTAssertNil(m.dockingFloat)
        XCTAssertNil(m.floatMove)
        XCTAssertNil(m.drag)
        XCTAssertFalse(m.endDockingFloat(front))
    }
}
