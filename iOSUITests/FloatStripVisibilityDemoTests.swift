import UIKit
import XCTest

/// Tucked floats' strips are really on screen (owner's iPhone QA of build 9000023: a float thrown
/// at an edge vanished, leaving nothing to pull back, while the model said it was tucked). In
/// Demo Mode's Window view (a sample Mac on this device, nothing sent), for each edge: throw the
/// float there, then check that its strip's picture and its touch target are both mounted, on
/// screen at that edge, as long as the window, reachable by a tap, and that the tap brings the
/// same window back, the same size, out of that edge.
///
/// How the picture is observed: from the screen itself. A strip's picture is deliberately not an
/// accessibility element: VoiceOver has one stop per strip, its Restore button, which is the
/// touch target checked here by identifier. Giving the picture an identifier would need it to be
/// an element too, a second stop beside that button. So the test compares screenshots of the
/// strip's slice before and after the throw. In Demo Mode a window has no still of its own, so
/// its strip is its dark card (0.07, 0.07, 0.08) with a light grip, a colour nothing else in
/// the sample picture has; the run of it along the edge is the picture's length.
///
/// XCUITest presses and drags in a straight line to one point: it can throw a float and tap a
/// strip, not peek, pull halfway or feel the motion; those are for the hands-on pass. Runs on
/// iPhone and iPad (portrait, where the sample picture leaves every edge's run free).
final class FloatStripVisibilityDemoTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testAFloatTuckedLeftLeavesAVisibleReachableStrip() throws { try tuckAndBringBack(.left) }
    @MainActor func testAFloatTuckedRightLeavesAVisibleReachableStrip() throws { try tuckAndBringBack(.right) }
    @MainActor func testAFloatTuckedAtTheTopLeavesAVisibleReachableStrip() throws { try tuckAndBringBack(.top) }
    @MainActor func testAFloatTuckedAtTheBottomLeavesAVisibleReachableStrip() throws { try tuckAndBringBack(.bottom) }

    /// Two floats tucked on opposite edges: two strips, each its own picture and target, each
    /// bringing back its own window.
    @MainActor
    func testTwoTuckedFloatsEachKeepTheirOwnStrip() throws {
        let app = openDemoWindowView()
        openFloat(app)
        openFloat(app)
        let floats = floatElements(app)
        XCTAssertTrue(waitFor { floats.count == 2 }, "two floats open")
        let picture = app.descendants(matching: .any)["demoWindowPicture"]

        // The front one (its title pill is the one not hidden by the other) to the left, then the other to the right.
        var tucked: [(edge: StripEdge, title: String, size: CGSize, before: ScreenPixels)] = []
        for edge in [StripEdge.left, .right] {
            let float = try XCTUnwrap(frontFloat(app), "a float to throw")
            let title = try XCTUnwrap(floatTitle(float))
            centre(float, in: app, picture: picture)
            let shown = floatNamed(title, app)
            let size = shown.frame.size
            let before = try XCTUnwrap(ScreenPixels(app), "a screenshot")
            throwFloat(shown, toward: edge, in: app, picture: picture)
            XCTAssertTrue(waitUntil(shown, "exists == false"), "\(edge): tucked, so not shown as a float")
            tucked.append((edge, title, size, before))
        }
        let handles = app.descendants(matching: .any).matching(identifier: "floatTuckHandle")
        XCTAssertTrue(waitFor { handles.count == 2 }, "a strip each: \(handles.count)")
        pause(1)   // the slides into the edges end
        attach(app, "two-tucked")
        let after = try XCTUnwrap(ScreenPixels(app))
        for t in tucked {
            let handle = handleNamed(t.title, app)
            XCTAssertTrue(handle.exists, "\(t.title)'s strip")
            assertStrip(handle, edge: t.edge, length: t.edge.length(of: t.size), picture: picture.frame, before: t.before, after: after)
        }
        // Each strip brings back its own window.
        for (i, t) in tucked.enumerated() {
            handleNamed(t.title, app).tap()
            let back = floatNamed(t.title, app)
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(t.title) back")
            XCTAssertTrue(waitFor { handles.count == tucked.count - i - 1 }, "its strip gone, the other's kept")
            XCTAssertEqual(back.frame.width, t.size.width, accuracy: 3, "the same window, its own size")
            XCTAssertEqual(back.frame.height, t.size.height, accuracy: 3)
        }
        attach(app, "two-back")
    }

    // MARK: One edge

    @MainActor
    private func tuckAndBringBack(_ edge: StripEdge) throws {
        let app = openDemoWindowView()
        openFloat(app)
        let picture = app.descendants(matching: .any)["demoWindowPicture"]
        let float = try XCTUnwrap(frontFloat(app), "a float")
        let title = try XCTUnwrap(floatTitle(float))
        centre(float, in: app, picture: picture)
        let shown = floatNamed(title, app)
        let size = shown.frame.size
        let handles = app.descendants(matching: .any).matching(identifier: "floatTuckHandle")
        XCTAssertEqual(handles.count, 0, "nothing tucked yet")
        attach(app, "\(edge)-1-before")
        let before = try XCTUnwrap(ScreenPixels(app), "a screenshot")

        throwFloat(shown, toward: edge, in: app, picture: picture)
        let handle = handles.firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "\(edge): a tucked float leaves a strip")
        XCTAssertTrue(waitUntil(shown, "exists == false"), "\(edge): tucked, so not shown as a float")
        XCTAssertEqual(handles.count, 1)
        pause(1)   // the slide into the edge ends
        attach(app, "\(edge)-2-tucked")
        let after = try XCTUnwrap(ScreenPixels(app), "a screenshot")
        assertStrip(handle, edge: edge, length: edge.length(of: size), picture: picture.frame, before: before, after: after)
        let strip = handle.frame

        // A tap brings back the same window, out of that edge, at its own size; its strip goes.
        handle.tap()
        let back = floatNamed(title, app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "\(edge): back")
        XCTAssertTrue(waitUntil(handle, "exists == false"), "\(edge): its strip is gone")
        XCTAssertEqual(floatElements(app).count, 1, "one window, never a second copy")
        pause(1)
        attach(app, "\(edge)-3-back")
        let f = back.frame
        XCTAssertEqual(f.width, size.width, accuracy: 3, "\(edge): its own size")
        XCTAssertEqual(f.height, size.height, accuracy: 3)
        switch edge {
        case .left: XCTAssertEqual(f.minX, strip.minX, accuracy: 3, "out of the left edge")
        case .right: XCTAssertEqual(f.maxX, strip.maxX, accuracy: 3, "out of the right edge")
        case .top:
            // Its title bar's room (30 pt, `WorkspaceFloatGeometry.barHeight`) stays below the top,
            // so its title pill is inside: on the iPhone it lands 30 pt below its strip.
            XCTAssertGreaterThanOrEqual(f.minY, strip.minY - 1, "out of the top edge, not past it")
            XCTAssertLessThanOrEqual(f.minY, strip.minY + 33, "out of the top edge, no lower than its title bar's room")
            if let pill = pill(of: back, in: app) {
                XCTAssertGreaterThanOrEqual(pill.screenPoint.y, picture.frame.minY, "its title pill inside")
            }
        case .bottom: XCTAssertEqual(f.maxY, strip.maxY, accuracy: 3, "out of the bottom edge")
        }
        // A straight slide out of its strip: across it, where the strip was.
        if edge == .top || edge == .bottom {
            XCTAssertEqual(f.minX, strip.minX, accuracy: 4, "\(edge): straight out of its strip")
        } else {
            XCTAssertEqual(f.minY, strip.minY, accuracy: 4, "\(edge): straight out of its strip")
        }
        // Its strip's picture went with it: that slice shows the window now, not the card. (At the
        // top its dark title pill sits there now.)
        if edge != .top {
            let restored = try XCTUnwrap(ScreenPixels(app))
            let slice = edge.slice(of: strip)
            XCTAssertLessThan(restored.cardShare(in: slice, edge: edge), 0.3, "\(edge): no strip left behind at \(slice)")
        }
    }

    /// The strip of a float tucked at `edge`: its touch target (`handle`) and its picture (the
    /// slice of the screen inside it, against the edge).
    @MainActor
    private func assertStrip(_ handle: XCUIElement, edge: StripEdge, length: CGFloat, picture: CGRect, before: ScreenPixels,
                             after: ScreenPixels, file: StaticString = #filePath, line: UInt = #line) {
        let h = handle.frame
        // The touch target: at that edge of the picture (inside the safe area), along it, reachable.
        switch edge {
        case .left:
            XCTAssertEqual(h.minX, picture.minX, accuracy: 60, "at the left edge: \(h) in \(picture)", file: file, line: line)
            XCTAssertLessThan(h.maxX, picture.midX, file: file, line: line)
        case .right:
            XCTAssertEqual(h.maxX, picture.maxX, accuracy: 60, "at the right edge: \(h) in \(picture)", file: file, line: line)
            XCTAssertGreaterThan(h.minX, picture.midX, file: file, line: line)
        case .top:
            XCTAssertEqual(h.minY, picture.minY, accuracy: 60, "at the top edge: \(h) in \(picture)", file: file, line: line)
            XCTAssertLessThan(h.maxY, picture.midY, file: file, line: line)
        case .bottom:
            XCTAssertLessThanOrEqual(h.maxY, picture.maxY + 1, "at the bottom edge: \(h) in \(picture)", file: file, line: line)
            XCTAssertGreaterThan(h.minY, picture.midY, file: file, line: line)
        }
        XCTAssertEqual(edge.depth(of: h), 44, accuracy: 1, "a 44 pt target in from the edge", file: file, line: line)
        XCTAssertEqual(edge.length(of: h.size), length, accuracy: 4,
                       "as long as the window (\(length) pt), not a fixed tab: \(h)", file: file, line: line)
        XCTAssertTrue(handle.isHittable, "\(edge): a finger reaches it (nothing drawn over it)", file: file, line: line)

        // The picture: the window's own slice, 20 pt deep against the edge, over the whole target's
        // length; it wasn't there before the throw; a grip on it; as long as the window.
        let slice = edge.slice(of: h)
        let now = after.cardShare(in: slice, edge: edge), then = before.cardShare(in: slice, edge: edge)
        XCTAssertGreaterThan(now, 0.6, "\(edge): the strip's picture shows at \(slice) (card share \(now))", file: file, line: line)
        XCTAssertLessThan(then, 0.35, "\(edge): and wasn't there before the throw (card share \(then))", file: file, line: line)
        XCTAssertTrue(after.hasGrip(in: slice, edge: edge), "\(edge): a grip on it", file: file, line: line)
        let shown = after.cardRun(along: slice, edge: edge)
        XCTAssertEqual(shown, length, accuracy: 6, "\(edge): its picture is as long as the window (\(length) pt): \(shown) pt",
                       file: file, line: line)
    }

    // MARK: Steps

    @MainActor
    private func openDemoWindowView() -> XCUIApplication {
        // Portrait: the screenshots are read the way the window's points are laid out.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 8), "the home screen's Try the Demo")
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(waitUntil(explore, "isHittable == true"))
        pause(1)
        explore.tap()
        let toggle = app.buttons["demoWindowViewToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()
        let panes = app.descendants(matching: .any).matching(identifier: "workspacePane")
        XCTAssertTrue(waitUntil(panes.firstMatch, "exists == true"))
        return app
    }

    @MainActor
    private func openFloat(_ app: XCUIApplication) {
        let count = floatElements(app).count
        let open = app.buttons["demoOpenFloating"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(open, "isHittable == true"))
        open.tap()
        XCTAssertTrue(waitFor { floatElements(app).count == count + 1 }, "a float opened")
        if app.buttons["Dismiss Tip"].exists { app.buttons["Dismiss Tip"].tap() }
    }

    /// A slow move by its title to the middle of the picture: it stays where it's let go.
    @MainActor
    private func centre(_ float: XCUIElement, in app: XCUIApplication, picture: XCUIElement) {
        guard let pill = pill(of: float, in: app) else { return XCTFail("its title pill") }
        let f = float.frame, p = picture.frame
        let to = pill.withOffset(CGVector(dx: p.midX - f.midX, dy: p.midY - f.midY))
        pill.press(forDuration: 0.05, thenDragTo: to, withVelocity: 300, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitFor { abs(float.frame.midX - p.midX) < 40 && abs(float.frame.midY - p.midY) < 40 },
                      "moved to the middle: \(float.frame) in \(p)")
    }

    /// A fast throw by its title toward `edge`.
    @MainActor
    private func throwFloat(_ float: XCUIElement, toward edge: StripEdge, in app: XCUIApplication, picture: XCUIElement) {
        guard let pill = pill(of: float, in: app) else { return XCTFail("its title pill") }
        let p = picture.frame
        let d: CGVector
        switch edge {
        case .left: d = CGVector(dx: -p.width * 0.4, dy: 0)
        case .right: d = CGVector(dx: p.width * 0.4, dy: 0)
        case .top: d = CGVector(dx: 0, dy: -p.height * 0.25)
        case .bottom: d = CGVector(dx: 0, dy: p.height * 0.25)
        }
        pill.press(forDuration: 0.05, thenDragTo: pill.withOffset(d), withVelocity: 3000, thenHoldForDuration: 0)
    }

    /// Where to take a float by its title: beside its ⋯ button, the one on that float's top edge
    /// (the title pill is centred on it). nil while another float hides its pill.
    @MainActor
    private func pill(of float: XCUIElement, in app: XCUIApplication) -> XCUICoordinate? {
        let f = float.frame
        let options = app.buttons.matching(identifier: "floatOptions").allElementsBoundByIndex
            .filter { abs($0.frame.midY - f.minY) <= 6 && $0.frame.midX >= f.minX && $0.frame.midX <= f.maxX + 40 }
            .min { abs($0.frame.midX - f.midX) < abs($1.frame.midX - f.midX) }
        return options?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -40, dy: 0))
    }

    @MainActor
    private func floatElements(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "workspaceFloat")
    }

    /// The float whose title pill is shown (the front one where they overlap).
    @MainActor
    private func frontFloat(_ app: XCUIApplication) -> XCUIElement? {
        floatElements(app).allElementsBoundByIndex.first { pill(of: $0, in: app) != nil }
    }

    /// "<title>, floating window".
    @MainActor
    private func floatTitle(_ float: XCUIElement) -> String? {
        let label = float.label
        guard let r = label.range(of: ", floating window", options: .backwards) else { return nil }
        return String(label[..<r.lowerBound])
    }

    @MainActor
    private func floatNamed(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        floatElements(app).matching(NSPredicate(format: "label == %@", "\(title), floating window")).firstMatch
    }

    @MainActor
    private func handleNamed(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "floatTuckHandle")
            .matching(NSPredicate(format: "label == %@", "Restore \(title)")).firstMatch
    }

    // MARK: Waiting

    @MainActor
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        let done = expectation(for: NSPredicate(format: format), evaluatedWith: element)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}

/// An edge, with the geometry the checks need (points, the app's window).
private enum StripEdge: CustomStringConvertible {
    case left, right, top, bottom

    var description: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }

    /// Strips lie along y on the left and right edges, along x on the top and bottom.
    var alongY: Bool { self == .left || self == .right }

    func length(of size: CGSize) -> CGFloat { alongY ? size.height : size.width }

    /// How far a rect against this edge reaches in from it.
    func depth(of r: CGRect) -> CGFloat { alongY ? r.width : r.height }

    /// The strip's picture inside its touch target: the 20 pt against the edge, as long as the target.
    func slice(of target: CGRect) -> CGRect {
        let d: CGFloat = 20
        switch self {
        case .left: return CGRect(x: target.minX, y: target.minY, width: d, height: target.height)
        case .right: return CGRect(x: target.maxX - d, y: target.minY, width: d, height: target.height)
        case .top: return CGRect(x: target.minX, y: target.minY, width: target.width, height: d)
        case .bottom: return CGRect(x: target.minX, y: target.maxY - d, width: target.width, height: d)
        }
    }

    /// The point `depth` in from the edge side of `slice`, `along` from its start.
    func point(in slice: CGRect, depth: CGFloat, along: CGFloat) -> CGPoint {
        switch self {
        case .left: return CGPoint(x: slice.minX + depth, y: slice.minY + along)
        case .right: return CGPoint(x: slice.maxX - depth, y: slice.minY + along)
        case .top: return CGPoint(x: slice.minX + along, y: slice.minY + depth)
        case .bottom: return CGPoint(x: slice.minX + along, y: slice.maxY - depth)
        }
    }
}

/// A screenshot of the app as sRGB bytes, read in the app window's points.
private struct ScreenPixels {
    let width: Int
    let height: Int
    /// Pixels per point.
    let scale: CGFloat
    private let bytes: [UInt8]

    @MainActor
    init?(_ app: XCUIApplication) {
        let image = app.screenshot().image
        let points = app.windows.firstMatch.frame.size
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        // Portrait only: the screenshot and the window must agree on which way is up.
        guard w > 0, h > 0, points.width > 0, (w > h) == (points.width > points.height) else { return nil }
        // Upright (the screenshot's orientation applied), 8 bits per channel, one pixel per pixel.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = upright.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        scale = CGFloat(w) / points.width
        bytes = data
    }

    func color(at p: CGPoint) -> (r: Int, g: Int, b: Int)? {
        let x = Int((p.x * scale).rounded(.down)), y = Int((p.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// A tucked window's dark card without a still: (0.07, 0.07, 0.08), a little lighter under its
    /// thin outline.
    func isCard(_ p: CGPoint) -> Bool {
        guard let c = color(at: p) else { return false }
        return abs(c.r - 18) <= 16 && abs(c.g - 18) <= 16 && abs(c.b - 20) <= 16 && max(c.r, c.g, c.b) - min(c.r, c.g, c.b) <= 10
    }

    private func luminance(_ p: CGPoint) -> Int {
        guard let c = color(at: p) else { return 0 }
        return (c.r * 3 + c.g * 6 + c.b) / 10
    }

    /// The share of the slice (away from its grip's line and its inner outline) that is the card.
    func cardShare(in slice: CGRect, edge: StripEdge) -> Double {
        let length = edge.length(of: slice.size)
        guard length > 8 else { return 0 }
        var card = 0, all = 0
        for depth: CGFloat in [3, 5.5, 14.5, 17] {
            var along: CGFloat = 3
            while along < length - 3 {
                if isCard(edge.point(in: slice, depth: depth, along: along)) { card += 1 }
                all += 1
                along += 2
            }
        }
        return all > 0 ? Double(card) / Double(all) : 0
    }

    /// A light grip on the slice: its line, 10 pt in from the edge, around the middle.
    func hasGrip(in slice: CGRect, edge: StripEdge) -> Bool {
        let length = edge.length(of: slice.size)
        var along = max(length / 2 - 40, 0)
        while along <= min(length / 2 + 40, length) {
            for depth: CGFloat in [9, 10, 11] where luminance(edge.point(in: slice, depth: depth, along: along)) >= 80 { return true }
            along += 1
        }
        return false
    }

    /// How long the card runs along the edge (2 pt in from it, clear of the grip and of an icon
    /// beside it), out from the middle of the slice and on past its ends while it lasts.
    func cardRun(along slice: CGRect, edge: StripEdge) -> CGFloat {
        let length = edge.length(of: slice.size)
        func card(_ a: CGFloat) -> Bool { isCard(edge.point(in: slice, depth: 2, along: a)) }
        func reach(_ step: CGFloat) -> CGFloat {
            var a = length / 2, last = a, misses: CGFloat = 0
            while abs(a - length / 2) < length + 200 {
                if card(a) { last = a; misses = 0 } else { misses += abs(step); if misses > 4 { break } }
                a += step
            }
            return last
        }
        return reach(1) - reach(-1) + 1
    }
}
