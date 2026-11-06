import AppKit
import ApplicationServices
import XCTest

/// Fill Window on Mac / Restore Previous Size on Mac (Mac/WindowFrameSetter.swift): the target
/// frame, the grading, which Accessibility window is the listed one, Restore's staleness rules,
/// the bounded memory, the wire format and the engine's answers. Nothing here moves a window,
/// except the live test, which only ever touches a window this test process creates.
final class WindowFrameTests: XCTestCase {
    // A 1512x982 built-in display: 33 pt menu bar; the Dock at the bottom (70 pt).
    private let builtIn = WindowFrameScreen(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            cocoaVisibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))

    // MARK: Target

    func testInsetsComeFromTheMenuBarAndTheDockOnAnyEdge() {
        XCTAssertEqual(WindowFrameGeometry.insets(frame: builtIn.cocoaFrame, visibleFrame: builtIn.cocoaVisibleFrame),
                       WindowFrameInsets(top: 33, left: 0, bottom: 70, right: 0))
        // Dock on the left / right: Cocoa's visibleFrame starts or ends inside the frame.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(WindowFrameGeometry.insets(frame: frame, visibleFrame: CGRect(x: 64, y: 0, width: 1448, height: 949)),
                       WindowFrameInsets(top: 33, left: 64, bottom: 0, right: 0))
        XCTAssertEqual(WindowFrameGeometry.insets(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1450, height: 949)),
                       WindowFrameInsets(top: 33, left: 0, bottom: 0, right: 62))
        // A visibleFrame that pokes outside (never expected) is never a negative inset.
        XCTAssertEqual(WindowFrameGeometry.insets(frame: frame, visibleFrame: frame.insetBy(dx: -5, dy: -5)), WindowFrameInsets())
    }

    func testFillTargetIsBelowTheMenuBarAndClearOfTheDock() {
        XCTAssertEqual(WindowFrameGeometry.target(on: builtIn), CGRect(x: 0, y: 33, width: 1512, height: 879))
        // Fractional insets never reach under the menu bar or the Dock.
        var odd = builtIn
        odd.cocoaVisibleFrame = CGRect(x: 0, y: 69.5, width: 1512, height: 879)   // top inset 33.5
        let t = WindowFrameGeometry.target(on: odd)!
        XCTAssertEqual(t.minY, 34)
        XCTAssertEqual(t.maxY, 912)
    }

    /// A second display left of the main one and higher: its bounds are global (top-left), its
    /// Cocoa frame bottom-left. Only their difference matters, so nothing is flipped.
    func testASecondDisplayUsesItsOwnBoundsAndItsOwnInsets() {
        // Global: x -1920...0, y -300...780. Cocoa (main height 982): y = 982 - 780 = 202.
        let left = WindowFrameScreen(displayID: 2, bounds: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                                     cocoaFrame: CGRect(x: -1920, y: 202, width: 1920, height: 1080),
                                     cocoaVisibleFrame: CGRect(x: -1920, y: 202, width: 1920, height: 1055))   // its own menu bar, no Dock
        XCTAssertEqual(WindowFrameGeometry.target(on: left), CGRect(x: -1920, y: -275, width: 1920, height: 1055))
        // The window's screen is the one it overlaps most, never the main one by default.
        let window = CGRect(x: -500, y: 100, width: 700, height: 400)   // 500 pt on the left display, 200 on the main one
        XCTAssertEqual(WindowFrameGeometry.screen(for: window, among: [builtIn, left])?.displayID, 2)
        XCTAssertEqual(WindowFrameGeometry.screen(for: CGRect(x: -100, y: 100, width: 700, height: 400), among: [builtIn, left])?.displayID, 1)
        XCTAssertNil(WindowFrameGeometry.screen(for: CGRect(x: 5000, y: 5000, width: 100, height: 100), among: [builtIn, left]))
    }

    func testStageManagersStripIsClearedOnTheEdgeItHugs() {
        let display = builtIn.bounds
        // Thumbnails down the left edge, up to x = 196.
        let strip = [CGRect(x: 12, y: 200, width: 176, height: 140), CGRect(x: 20, y: 380, width: 176, height: 160)]
        let left = WindowFrameGeometry.stripInsets(display: display, stripItems: strip)
        XCTAssertEqual(left.left, 196 + WindowFrameGeometry.stripClearance)
        XCTAssertEqual(left.right, 0)
        let t = WindowFrameGeometry.target(on: builtIn, stripItems: strip)!
        XCTAssertEqual(t.minX, 204)
        XCTAssertEqual(t.maxX, 1512)
        XCTAssertEqual(t.minY, 33)
        // On the right (the Dock on the left moves the strip there).
        let right = WindowFrameGeometry.stripInsets(display: display, stripItems: [CGRect(x: 1320, y: 200, width: 176, height: 140)])
        XCTAssertEqual(right.right, 1512 - 1320 + WindowFrameGeometry.stripClearance)
        XCTAssertEqual(right.left, 0)
        // Big windows, items in the middle or on another display aren't the strip.
        let none = WindowFrameGeometry.stripInsets(display: display, stripItems: [
            CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 700, y: 400, width: 100, height: 100),
            CGRect(x: -400, y: 100, width: 176, height: 140),
        ])
        XCTAssertEqual(none.left, 0)
        XCTAssertEqual(none.right, 0)
        // The Dock on the left and the strip: the larger inset wins, not their sum.
        var dockLeft = builtIn
        dockLeft.cocoaVisibleFrame = CGRect(x: 80, y: 0, width: 1432, height: 949)
        XCTAssertEqual(WindowFrameGeometry.target(on: dockLeft, stripItems: strip)?.minX, 204)
    }

    func testATargetTooSmallToBeMeantIsRefused() {
        let tiny = WindowFrameScreen(displayID: 3, bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                     cocoaFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                     cocoaVisibleFrame: CGRect(x: 0, y: 60, width: 300, height: 100))
        XCTAssertNil(WindowFrameGeometry.target(on: tiny))
    }

    // MARK: Grading

    func testFillIsGradedFromTheFrameTheWindowServerReportsAfterwards() {
        let before = CGRect(x: 300, y: 200, width: 400, height: 300)
        let target = CGRect(x: 0, y: 33, width: 1512, height: 879)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 1, y: 34, width: 1511, height: 877)), .filled)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: before), .notResizable, "nothing changed")
        // Its maximum size, at the target's corner; a terminal's size steps; a minimum bigger than the area.
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 0, y: 33, width: 1200, height: 800)), .limited)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 0, y: 33, width: 1505, height: 870)), .limited)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 0, y: 33, width: 1600, height: 900)), .limited)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 40, y: 60, width: 1300, height: 800)), .limited,
                       "nudged but mostly in the area")
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: CGRect(x: 3000, y: 60, width: 500, height: 300)), .failed)
        XCTAssertEqual(WindowFrameGeometry.gradeFill(before: before, target: target, after: nil), .failed)
    }

    // MARK: Which window

    private func candidate(_ frame: CGRect?, _ title: String?, standard: Bool = true) -> WindowFrameCandidates.Candidate {
        .init(frame: frame, title: title, subrole: standard ? kAXStandardWindowSubrole as String : kAXDialogSubrole as String)
    }

    func testExactlyOneAccessibilityWindowWithTheFrameAndTitleIsPicked() {
        let b = CGRect(x: 100, y: 100, width: 800, height: 600)
        let other = CGRect(x: 140, y: 140, width: 800, height: 600)
        XCTAssertEqual(WindowFrameCandidates.pick([], bounds: b, title: "Doc"), .none)
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(other, "Doc")], bounds: b, title: "Doc"), .none, "frame must match")
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(other, "Doc"), candidate(b.offsetBy(dx: 1, dy: -2), "Doc")], bounds: b, title: "Doc"), .one(1))
        // The title is exact: a longer Accessibility title is not guessed at.
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "Doc — Edited")], bounds: b, title: "Doc"), .none)
        // Same frame: the title tells them apart; same frame and title: refused.
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "A"), candidate(b, "Doc")], bounds: b, title: "Doc"), .one(1))
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "Doc"), candidate(b, "Doc")], bounds: b, title: "Doc"), .many)
        // No listed title: the frame alone, and it must be unique.
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "A"), candidate(other, "B")], bounds: b, title: ""), .one(0))
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "A"), candidate(b, "B")], bounds: b, title: ""), .many)
        // A dialog or panel is never resized; an element without a frame never matches.
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(b, "Doc", standard: false)], bounds: b, title: "Doc"), .notStandard)
        XCTAssertEqual(WindowFrameCandidates.pick([candidate(nil, "Doc")], bounds: b, title: "Doc"), .none)
    }

    func testAnotherOnScreenWindowOfTheAppWithTheSameBoundsIsAmbiguous() {
        let b = CGRect(x: 100, y: 100, width: 800, height: 600)
        func w(_ id: UInt32, pid: Int32 = 42, layer: Int = 0, _ r: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600), on: Bool = true) -> WindowFrameCandidates.ServerWindow {
            .init(id: id, pid: pid, layer: layer, bounds: r, onScreen: on)
        }
        XCTAssertFalse(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7)]), "itself")
        XCTAssertTrue(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7), w(8)]))
        XCTAssertFalse(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7), w(8, pid: 43)]), "another app")
        XCTAssertFalse(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7), w(8, layer: 3)]), "a menu or panel layer")
        XCTAssertFalse(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7), w(8, on: false)]), "another Space")
        XCTAssertFalse(WindowFrameCandidates.hasTwin(windowID: 7, pid: 42, bounds: b, in: [w(7), w(8, CGRect(x: 120, y: 100, width: 800, height: 600))]))
    }

    // MARK: Restore

    private func entry(before: CGRect, after: CGRect, at: TimeInterval = 10) -> WindowFrameMemoryEntry {
        WindowFrameMemoryEntry(before: before, after: after, displayID: 1, title: "Doc", at: at)
    }

    func testRestoreOnlyPutsBackAWindowStillWhereFillLeftIt() {
        let before = CGRect(x: 300, y: 200, width: 400, height: 300)
        let after = CGRect(x: 0, y: 33, width: 1512, height: 879)
        let displays = [builtIn.bounds]
        let e = entry(before: before, after: after)
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: nil, current: after, displays: displays), .nothingToRestore)
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: e, current: after.offsetBy(dx: 1, dy: 1), displays: displays), .restore(before))
        // Resized or moved by hand on the Mac since: never the stale size.
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: e, current: CGRect(x: 0, y: 33, width: 1000, height: 879), displays: displays), .changed)
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: e, current: after.offsetBy(dx: 30, dy: 0), displays: displays), .changed)
        // The old frame was on a display that's gone (less than half of it is on one now).
        let elsewhere = entry(before: CGRect(x: 1700, y: 100, width: 600, height: 400), after: after)
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: elsewhere, current: after, displays: displays), .displayChanged)
        let half = entry(before: CGRect(x: 1212, y: 100, width: 600, height: 400), after: after)   // exactly 300 of 600 pt on it
        XCTAssertEqual(WindowFrameGeometry.restoreDecision(entry: half, current: after, displays: displays), .restore(half.before))
    }

    func testTheMemoryIsBoundedAndForgetsClosedReusedAndHandMovedWindows() {
        var m = WindowFrameMemoryStore()
        let a = CGRect(x: 0, y: 33, width: 1512, height: 879), b = CGRect(x: 10, y: 50, width: 400, height: 300)
        for i in 0..<(WindowFrameMemoryStore.capacity + 5) {
            m.remember(WindowFrameMemoryKey(windowID: UInt32(i), pid: 9), entry(before: b, after: a, at: TimeInterval(i)))
        }
        XCTAssertEqual(m.entries.count, WindowFrameMemoryStore.capacity)
        XCTAssertNil(m.entry(WindowFrameMemoryKey(windowID: 0, pid: 9)), "the oldest go first")
        XCTAssertNotNil(m.entry(WindowFrameMemoryKey(windowID: UInt32(WindowFrameMemoryStore.capacity + 4), pid: 9)))
        // Filling again replaces the window's entry instead of adding one.
        let k = WindowFrameMemoryKey(windowID: 30, pid: 9)
        m.remember(k, entry(before: a, after: b, at: 500))
        XCTAssertEqual(m.entries.count, WindowFrameMemoryStore.capacity)
        XCTAssertEqual(m.entry(k)?.before, a)

        var r = WindowFrameMemoryStore()
        let kept = WindowFrameMemoryKey(windowID: 1, pid: 9), closed = WindowFrameMemoryKey(windowID: 2, pid: 9)
        let reused = WindowFrameMemoryKey(windowID: 3, pid: 9), moved = WindowFrameMemoryKey(windowID: 4, pid: 9)
        let justFilled = WindowFrameMemoryKey(windowID: 5, pid: 9)
        for (key, at) in [(kept, 10.0), (closed, 10.0), (reused, 10.0), (moved, 10.0), (justFilled, 19.5)] { r.remember(key, entry(before: b, after: a, at: at)) }
        r.reconcile(existing: [kept, moved, justFilled, WindowFrameMemoryKey(windowID: 3, pid: 77)],
                    listed: [kept: a, moved: a.offsetBy(dx: 0, dy: 40), justFilled: b], listedAt: 20)
        XCTAssertNotNil(r.entry(kept))
        XCTAssertNil(r.entry(closed), "the window closed")
        XCTAssertNil(r.entry(reused), "the id now belongs to another app")
        XCTAssertNil(r.entry(moved), "moved by hand after Fill")
        XCTAssertNotNil(r.entry(justFilled), "a listing from before the Fill settled says nothing")
        r.forget(kept)
        XCTAssertNil(r.entry(kept))
    }

    // MARK: Wire

    func testRequestAndResultRoundTripAndBadInputIsRefused() throws {
        let m = WindowFrameWire.requestMessage(.fill, window: 4321, generation: 9, req: 3)
        XCTAssertEqual(m["type"] as? String, "windowFrame")
        let data = try JSONSerialization.data(withJSONObject: m)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(WindowFrameRequest.parse(back), WindowFrameRequest(op: .fill, windowID: 4321, generation: 9, req: 3))
        XCTAssertEqual(WindowFrameRequest.parse(["op": "restore", "window": 1, "gen": 2])?.req, nil)
        for bad: [String: Any] in [["op": "maximize", "window": 1, "gen": 1], ["op": "fill", "window": -1, "gen": 1],
                                   ["op": "fill", "window": 1 << 40, "gen": 1], ["op": "fill", "window": 1], ["op": "fill", "gen": 1],
                                   ["op": "fill", "window": "1", "gen": 1], ["op": "fill", "window": 1, "gen": -3]] {
            XCTAssertNil(WindowFrameRequest.parse(bad), "\(bad)")
        }
        for result in WindowFrameResult.allCases {
            let r = WindowFrameWire.resultMessage(.restore, window: 77, req: 5, result: result, restorable: result == .limited)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: r)) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, "windowFrameResult")
            XCTAssertEqual(WindowFrameReply.parse(json), WindowFrameReply(op: .restore, windowID: 77, req: 5, result: result, restorable: result == .limited))
            guard case .frameResult(let reply)? = WorkspaceEvent.parse(type: WindowFrameWire.result, json) else { return XCTFail("not parsed") }
            XCTAssertEqual(reply.result, result)
        }
        XCTAssertNil(WindowFrameReply.parse(["op": "fill", "window": 1, "result": "exploded"]))
        XCTAssertNil(WindowFrameWire.resultMessage(.fill, window: 1, req: nil, result: .stale, restorable: false)["req"])
        XCTAssertEqual(Set(WindowFrameResult.allCases.filter(\.succeeded)), [.filled, .limited, .alreadyFilled, .restored])
    }

    func testTheMacOffersItOnlyWhileWindowModeIsAllowed() {
        XCTAssertTrue(MacSender.welcomeFeatures(windowModeAllowed: true).contains(WindowFrameWire.welcomeFeature))
        XCTAssertFalse(MacSender.welcomeFeatures(windowModeAllowed: false).contains(WindowFrameWire.welcomeFeature))
        XCTAssertFalse(MacSender.welcomeFeatures(windowModeAllowed: false).contains(WindowWorkspaceWire.welcomeFeature))
        XCTAssertTrue(MacSender.welcomeFeatures(windowModeAllowed: false).contains(LockMacWire.welcomeFeature), "the rest is unchanged")
    }

    // MARK: Engine

    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String: Any]] = []
        func add(_ m: [String: Any]) { lock.withLock { all.append(m) } }
        func results() -> [[String: Any]] { lock.withLock { all.filter { $0["type"] as? String == WindowFrameWire.result } } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: WindowFrameResult?
        func set(_ r: WindowFrameResult) { lock.withLock { value = r } }
        var result: WindowFrameResult? { lock.withLock { value } }
    }

    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Without control the engine answers `control` and never asks Accessibility; a paused engine
    /// answers `failed`; a malformed request gets no answer and changes nothing.
    func testTheEngineAnswersWithoutTouchingAWindowWhenItMayNot() {
        let messages = Messages()
        let engine = WindowWorkspaceEngine(hostID: "test-mac", canvas: CGSize(width: 800, height: 600), fps: 30,
                                           browser: WindowBrowserService(hostID: "test-mac"))
        engine.sendMessage = { messages.add($0) }
        let asked = Counter()
        let request = WindowFrameWire.requestMessage(.fill, window: 123, generation: 4, req: 8)
        engine.handleWindowFrame(request, inputGranted: false) { asked.bump(); return true }
        wait { messages.results().count == 1 }
        XCTAssertEqual(messages.results().first?["result"] as? String, "control")
        XCTAssertEqual(messages.results().first?["req"] as? Int, 8)
        XCTAssertEqual(messages.results().first?["restorable"] as? Bool, false)

        // Granted, but the engine isn't running (paused, Video Off): answered, nothing attempted.
        engine.handleWindowFrame(WindowFrameWire.requestMessage(.restore, window: 123, generation: 4, req: 9), inputGranted: true) {
            asked.bump(); return true
        }
        wait { messages.results().count == 2 }
        XCTAssertEqual(messages.results().last?["result"] as? String, "failed")
        XCTAssertEqual(messages.results().last?["op"] as? String, "restore")

        engine.handleWindowFrame(["op": "fill", "window": "nope"], inputGranted: true) { asked.bump(); return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(messages.results().count, 2, "a malformed request is dropped")
        XCTAssertEqual(asked.count, 0, "the re-check is only asked right before a write, and nothing got that far")
        engine.stop()
    }

    // MARK: Live (a window this test creates, only with Accessibility)

    /// Fill and Restore a disposable window of this test process. Skipped unless the test runner
    /// is Accessibility-trusted (xcodebuild's normally isn't). Never touches any other window.
    @MainActor
    func testLiveFillAndRestoreOfThisTestsOwnWindow() throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("the test runner isn't Accessibility-trusted") }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 420, height: 300),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "MeowDisplay fill test \(UUID().uuidString.prefix(8))"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let id = UInt32(window.windowNumber)
        let pid = ProcessInfo.processInfo.processIdentifier
        let memory = WindowFrameMemory()
        let before = WindowWorkspaceEngine.currentFrame(id)
        guard let before else { throw XCTSkip("the test window isn't on screen") }

        let title = window.title
        func run(_ op: WindowFrameOp, allowed: Bool = true) -> WindowFrameResult? {
            let box = ResultBox()
            WindowFrameSetter.perform(.init(op: op, windowID: id, pid: pid, title: title, stillAllowed: { allowed }),
                                      memory: memory) { box.set($0) }
            wait(6) { box.result != nil }
            return box.result
        }

        XCTAssertEqual(run(.fill, allowed: false), .control, "control is asked again right before the write")
        XCTAssertEqual(WindowWorkspaceEngine.currentFrame(id), before, "nothing moved")
        XCTAssertEqual(run(.restore), .nothingToRestore)
        let filled = run(.fill)
        XCTAssertTrue(filled == .filled || filled == .limited, "\(String(describing: filled))")
        XCTAssertNotNil(memory.entry(WindowFrameMemoryKey(windowID: id, pid: pid)))
        XCTAssertEqual(run(.fill), .alreadyFilled)
        XCTAssertEqual(run(.restore), .restored)
        let back = try XCTUnwrap(WindowWorkspaceEngine.currentFrame(id))
        XCTAssertTrue(WindowFrameGeometry.matches(back, before), "\(back) vs \(before)")
        XCTAssertNil(memory.entry(WindowFrameMemoryKey(windowID: id, pid: pid)))

        // Resized by hand after Fill: Restore refuses and forgets.
        let again = run(.fill)
        XCTAssertTrue(again == .filled || again == .limited, "\(String(describing: again))")
        window.setFrame(window.frame.insetBy(dx: 60, dy: 60), display: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(run(.restore), .changed)
        XCTAssertNil(memory.entry(WindowFrameMemoryKey(windowID: id, pid: pid)))
    }
}
