import AVFoundation
import CoreGraphics
import XCTest

/// Zoom While Typing keeps the typing location visible above the keyboard
/// (2.1.0 QA): a caret resent for a new keyboard session is not dropped, a
/// missing caret keeps the best known location, a caret on the Mac's bottom
/// line keeps room above the keyboard, a hand-zoomed picture is moved to show
/// the caret without changing the user's zoom, and every presentation maps
/// touches back to the same Mac point it draws.
@MainActor
final class ZoomWhileTypingReliabilityTests: XCTestCase {
    private let phone = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let phoneVisible = CGRect(x: 0, y: 0, width: 390, height: 444)
    private let phoneLandscape = CGRect(x: 0, y: 0, width: 844, height: 390)
    private let phoneLandscapeVisible = CGRect(x: 0, y: 0, width: 844, height: 160)
    private let iPad = CGRect(x: 0, y: 0, width: 1180, height: 820)
    private let iPadVisible = CGRect(x: 0, y: 0, width: 1180, height: 445)
    private let wide = CGSize(width: 1920, height: 1080)
    private let tall = CGSize(width: 1000, height: 1600)

    private func caret(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 0.002, height: 0.02)
    }

    private func open(view: CGRect, visible: CGRect, remote: CGSize, zoom: Bool = true,
                      anchor: CGPoint? = nil, caret: CGRect?, previous: CGRect? = nil) -> RemoteViewportTransform {
        RemoteViewportCalculator.keyboardOpen(viewBounds: view, remoteAspectSize: remote, visibleRect: visible,
                                              anchor: anchor, zoomEnabled: zoom, caret: caret, previous: previous)
    }

    /// The caret's top and bottom edges in the view.
    private func caretSpan(_ t: RemoteViewportTransform, _ c: CGRect) -> (top: CGFloat, bottom: CGFloat, x: CGFloat) {
        let top = t.viewPoint(forRemote: CGPoint(x: c.midX, y: c.minY))
        let bottom = t.viewPoint(forRemote: CGPoint(x: c.midX, y: c.maxY))
        return (min(top.y, bottom.y), max(top.y, bottom.y), top.x)
    }

    private func assertMapsBack(_ t: RemoteViewportTransform, file: StaticString = #filePath, line: UInt = #line) {
        for p in [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.93, y: 0.97), CGPoint(x: 0.31, y: 0.77)] {
            guard let back = t.remotePoint(forView: t.viewPoint(forRemote: p)) else {
                return XCTFail("no mapping for \(p)", file: file, line: line)
            }
            XCTAssertEqual(back.x, p.x, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-6, file: file, line: line)
        }
    }

    // MARK: - A new keyboard session gets the Mac's caret again

    func testTheSameCaretSentForANewKeyboardSessionReachesTheView() {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "Test",
                                      fallbackServiceName: "Test")
        var delivered: [CGRect?] = []
        receiver.onTextCaret = { delivered.append($0) }
        let c = caret(0.4, 0.9)

        receiver.sendKeyboardState(open: true)
        receiver.applyTextCaretUpdate(c)
        receiver.applyTextCaretUpdate(c)
        XCTAssertEqual(delivered, [c], "within one keyboard session an unchanged caret is not repeated")

        // The view forgets its caret when the keyboard closes; the receiver must too.
        receiver.sendKeyboardState(open: false)
        receiver.sendKeyboardState(open: true)
        receiver.applyTextCaretUpdate(c)
        XCTAssertEqual(delivered, [c, c], "the Mac's first reading of the next session is delivered")
        XCTAssertEqual(receiver.textCaret, c)
    }

    // MARK: - Missing or stale caret

    func testACaretReportSteersAndNoCaretKeepsTheLastOneUntilATouch() {
        var focus = TypingFocus()
        XCTAssertNil(focus.steeringCaret, "nothing known: the touch anchor steers")

        let first = caret(0.3, 0.8)
        focus.caretReported(first)
        XCTAssertEqual(focus.steeringCaret, first)

        // The Mac can't read a caret for a moment (or the app has none): the
        // last one is still the best known typing location.
        focus.caretReported(nil)
        XCTAssertEqual(focus.steeringCaret, first)
        XCTAssertFalse(focus.caretIsLive)

        // A touch after that is newer than the caret: it steers.
        focus.touched()
        XCTAssertNil(focus.steeringCaret)

        // The next caret report wins again.
        let second = caret(0.6, 0.2)
        focus.caretReported(second)
        XCTAssertEqual(focus.steeringCaret, second)
    }

    func testATouchWhileTheCaretIsLiveDoesNotTakeOver() {
        var focus = TypingFocus()
        let c = caret(0.5, 0.5)
        focus.caretReported(c)
        focus.touched()
        XCTAssertEqual(focus.steeringCaret, c, "the Mac's live caret is better than the touch that moved it")
    }

    func testAnUnusableCaretCountsAsNoCaret() {
        var focus = TypingFocus()
        let c = caret(0.5, 0.5)
        focus.caretReported(c)
        focus.caretReported(CGRect(x: 1.4, y: 0.5, width: 0.002, height: 0.02))
        XCTAssertEqual(focus.steeringCaret, c)
        XCTAssertFalse(focus.caretIsLive)
        focus.caretReported(CGRect(x: CGFloat.nan, y: 0.5, width: 0, height: 0))
        XCTAssertEqual(focus.steeringCaret, c)
    }

    func testClosingTheKeyboardForgetsTheCaret() {
        var focus = TypingFocus()
        focus.caretReported(caret(0.5, 0.5))
        focus.keyboardClosed()
        XCTAssertEqual(focus, TypingFocus())
        XCTAssertNil(focus.steeringCaret)
    }

    // MARK: - Room above the keyboard

    func testACaretOnTheMacsBottomLineKeepsRoomAboveTheKeyboard() {
        let layouts: [(CGRect, CGRect, CGSize)] = [
            (phone, phoneVisible, wide), (phone, phoneVisible, tall),
            (phoneLandscape, phoneLandscapeVisible, wide),
            (iPad, iPadVisible, wide), (iPad, iPadVisible, tall),
        ]
        for (view, visible, remote) in layouts {
            let gap = RemoteViewportCalculator.keyboardGap(visibleHeight: visible.height)
            for zoom in [true, false] {
                for y in [0.9, 0.95, 0.975, 0.99] as [CGFloat] {
                    for x in [0.02, 0.5, 0.98] as [CGFloat] {
                        let c = caret(x, y)
                        let t = open(view: view, visible: visible, remote: remote, zoom: zoom, caret: c)
                        let span = caretSpan(t, c)
                        let label = "\(view.size) \(remote) zoom=\(zoom) caret=(\(x),\(y))"
                        XCTAssertLessThanOrEqual((span.top + span.bottom) / 2, visible.maxY - gap + 0.01, label)
                        XCTAssertLessThan(span.bottom, visible.maxY, label)
                        XCTAssertGreaterThanOrEqual(span.top, visible.minY - 0.01, label)
                        XCTAssertGreaterThanOrEqual(span.x, visible.minX - 0.01, label)
                        XCTAssertLessThanOrEqual(span.x, visible.maxX + 0.01, label)
                        assertMapsBack(t)
                    }
                }
            }
        }
    }

    func testATouchOnTheMacsBottomLineKeepsRoomAboveTheKeyboardToo() {
        let gap = RemoteViewportCalculator.keyboardGap(visibleHeight: phoneLandscapeVisible.height)
        for zoom in [true, false] {
            let anchor = CGPoint(x: 0.5, y: 0.99)
            let t = open(view: phoneLandscape, visible: phoneLandscapeVisible, remote: wide, zoom: zoom,
                         anchor: anchor, caret: nil)
            XCTAssertLessThanOrEqual(t.viewPoint(forRemote: anchor).y, phoneLandscapeVisible.maxY - gap + 0.01)
        }
    }

    func testTheKeyboardGapIsModestAndBounded() {
        XCTAssertEqual(RemoteViewportCalculator.keyboardGap(visibleHeight: 445), 35.6, accuracy: 0.01)
        XCTAssertEqual(RemoteViewportCalculator.keyboardGap(visibleHeight: 160), 16)
        XCTAssertEqual(RemoteViewportCalculator.keyboardGap(visibleHeight: 60), 15, "never more than a quarter")
        XCTAssertEqual(RemoteViewportCalculator.keyboardGap(visibleHeight: 0), 0)
    }

    // MARK: - Following the caret

    func testTypingALineMovesThePictureRarelyAndChangingLinesFollows() {
        var previous: CGRect?
        var moves = 0
        var y: CGFloat = 0.3
        var x: CGFloat = 0.05
        // Three lines of ~90 characters, then a jump to another field.
        for _ in 0..<3 {
            x = 0.05
            for _ in 0..<90 {
                let c = caret(x, y)
                let t = open(view: phone, visible: phoneVisible, remote: wide, caret: c, previous: previous)
                if let previous, previous != t.displayedRect { moves += 1 }
                previous = t.displayedRect
                let p = t.viewPoint(forRemote: CGPoint(x: c.midX, y: c.midY))
                XCTAssertTrue(phoneVisible.contains(p), "caret (\(x),\(y)) stays in view")
                x += 0.01
            }
            y += 0.03
        }
        XCTAssertLessThanOrEqual(moves, 12, "the picture moves a few times a line, never per character")

        let other = caret(0.8, 0.92)
        let t = open(view: phone, visible: phoneVisible, remote: wide, caret: other, previous: previous)
        XCTAssertTrue(phoneVisible.contains(t.viewPoint(forRemote: CGPoint(x: other.midX, y: other.midY))),
                      "moving to another field brings it into view")
    }

    // MARK: - Keyboard resizing and rotation

    func testResizingTheKeyboardKeepsTheCaretInView() {
        let c = caret(0.7, 0.85)
        var previous: CGRect?
        for height in [444, 400, 470, 300, 444] as [CGFloat] {
            let visible = CGRect(x: 0, y: 0, width: 390, height: height)
            let t = open(view: phone, visible: visible, remote: wide, caret: c, previous: previous)
            let span = caretSpan(t, c)
            XCTAssertLessThanOrEqual((span.top + span.bottom) / 2,
                                     visible.maxY - RemoteViewportCalculator.keyboardGap(visibleHeight: height) + 0.01)
            XCTAssertLessThan(span.bottom, visible.maxY)
            XCTAssertGreaterThanOrEqual(span.top, visible.minY - 0.01)
            previous = t.displayedRect
        }
    }

    func testRotatingWithTheKeyboardOpenKeepsTheCaretInView() {
        let c = caret(0.85, 0.9)
        let portrait = open(view: phone, visible: phoneVisible, remote: wide, caret: c)
        // The landscape pass gets portrait's placement as `previous`: another size, so it starts over.
        let landscape = open(view: phoneLandscape, visible: phoneLandscapeVisible, remote: wide, caret: c,
                             previous: portrait.displayedRect)
        let back = open(view: phone, visible: phoneVisible, remote: wide, caret: c, previous: landscape.displayedRect)
        for (t, visible) in [(portrait, phoneVisible), (landscape, phoneLandscapeVisible), (back, phoneVisible)] {
            let p = t.viewPoint(forRemote: CGPoint(x: c.midX, y: c.midY))
            XCTAssertTrue(visible.contains(p), "\(visible.size)")
            assertMapsBack(t)
        }
        XCTAssertEqual(back, portrait, "rotating back returns the same placement")
    }

    // MARK: - Repeated open and close

    func testRepeatedOpenAndCloseNeitherDriftsNorAccumulates() {
        let closed = RemoteViewportCalculator.normal(viewBounds: iPad, remoteAspectSize: wide)
        let manual = ManualViewportState(scale: 2.2, panX: -140, panY: 90)
        let zoomedBefore = RemoteViewportCalculator.applyManualZoom(to: closed, state: manual)
        var focus = TypingFocus()
        var firstOpen: RemoteViewportTransform?
        for cycle in 0..<25 {
            // Open: the caret arrives (the same one every time).
            focus.caretReported(caret(0.62, 0.88))
            let base = open(view: iPad, visible: iPadVisible, remote: wide, caret: focus.steeringCaret)
            let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
            let reveal = RemoteViewportCalculator.typingRevealOffset(
                of: zoomed, focus: focus.steeringCaret!, visibleRect: iPadVisible, current: .zero)
            let shown = RemoteViewportCalculator.applyManualZoom(to: base.offsetBy(reveal), state: manual)
            if let firstOpen { XCTAssertEqual(shown, firstOpen, "cycle \(cycle)") } else { firstOpen = shown }
            // Close: the caret and the reveal are forgotten, the manual state never changed.
            focus.keyboardClosed()
            let after = RemoteViewportCalculator.applyManualZoom(to: closed, state: manual)
            XCTAssertEqual(after, zoomedBefore, "cycle \(cycle): back to exactly the user's view")
        }
    }

    // MARK: - Manual zoom and pan

    func testAHandZoomedPictureIsMovedToShowTheCaretAndRestoredOnClose() {
        // Zoomed into the top left; the caret is in a chat box at the bottom right.
        let manual = ManualViewportState(scale: 2.5, panX: 700, panY: 400)
        let c = caret(0.85, 0.93)
        let base = open(view: iPad, visible: iPadVisible, remote: wide, caret: c)
        let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
        let hidden = zoomed.viewPoint(forRemote: CGPoint(x: c.midX, y: c.midY))
        XCTAssertFalse(iPadVisible.contains(hidden), "without the reveal the caret is out of view")

        let reveal = RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: c, visibleRect: iPadVisible,
                                                                 current: .zero)
        let shown = RemoteViewportCalculator.applyManualZoom(to: base.offsetBy(reveal), state: manual)
        let expected = zoomed.offsetBy(reveal).displayedRect
        XCTAssertEqual(shown.displayedRect.minX, expected.minX, accuracy: 1e-6, "moving the base moves the zoomed picture the same")
        XCTAssertEqual(shown.displayedRect.minY, expected.minY, accuracy: 1e-6)
        XCTAssertEqual(shown.displayedRect.size, zoomed.displayedRect.size, "the user's zoom is kept")
        let span = caretSpan(shown, c)
        XCTAssertTrue(iPadVisible.insetBy(dx: 0, dy: 1).contains(CGPoint(x: span.x, y: (span.top + span.bottom) / 2)))
        assertMapsBack(shown)
    }

    func testTheRevealStaysPutWhileTypingAndIsZeroWhenTheUsersViewShowsTheCaret() {
        let base = open(view: iPad, visible: iPadVisible, remote: wide, caret: caret(0.5, 0.5))
        let manual = ManualViewportState(scale: 2, panX: 0, panY: 0)
        let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
        XCTAssertEqual(RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(0.5, 0.5),
                                                                   visibleRect: iPadVisible, current: .zero),
                       .zero, "a caret the user's view already shows moves nothing")

        var current = RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(0.9, 0.9),
                                                                  visibleRect: iPadVisible, current: .zero)
        XCTAssertNotEqual(current, .zero)
        var moves = 0
        var x: CGFloat = 0.9
        for _ in 0..<6 {
            x += 0.005
            let next = RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(x, 0.9),
                                                                   visibleRect: iPadVisible, current: current)
            if next != current { moves += 1 }
            current = next
        }
        XCTAssertEqual(moves, 0, "typing a few characters doesn't move the picture")
    }

    func testTheRevealWorksOnARotatedPicture() {
        let base = open(view: iPad, visible: iPadVisible, remote: wide, caret: caret(0.2, 0.9))
        let manual = ManualViewportState(scale: 1.8, panX: 200, panY: -150, rotationRadians: .pi / 2)
        let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
        let c = caret(0.2, 0.9)
        let reveal = RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: c, visibleRect: iPadVisible,
                                                                 current: .zero)
        let shown = RemoteViewportCalculator.applyManualZoom(to: base.offsetBy(reveal), state: manual)
        XCTAssertTrue(iPadVisible.contains(shown.viewPoint(forRemote: CGPoint(x: c.midX, y: c.midY))))
        assertMapsBack(shown)
    }

    func testAPinchOnARevealedPictureStaysUnderTheFingers() {
        let base = open(view: iPad, visible: iPadVisible, remote: wide, caret: caret(0.85, 0.93))
        let manual = ManualViewportState(scale: 2.5, panX: 700, panY: 400)
        let zoomed = RemoteViewportCalculator.applyManualZoom(to: base, state: manual)
        let reveal = RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(0.85, 0.93),
                                                                 visibleRect: iPadVisible, current: .zero)
        // The gesture is given the revealed base, as VideoView does.
        let gestureBase = base.offsetBy(reveal)
        let shown = RemoteViewportCalculator.applyManualZoom(to: gestureBase, state: manual)
        let fingers = CGPoint(x: 500, y: 250)
        let under = shown.remotePoint(forView: fingers)!
        let next = ManualViewportState.pinching(from: manual, initialBase: gestureBase.displayedRect,
                                                initialMidpoint: fingers, currentMidpoint: fingers, scaleRatio: 1.3)
        let after = RemoteViewportCalculator.applyManualZoom(to: gestureBase, state: next)
        let stillUnder = after.remotePoint(forView: fingers)!
        XCTAssertEqual(stillUnder.x, under.x, accuracy: 1e-6)
        XCTAssertEqual(stillUnder.y, under.y, accuracy: 1e-6)
    }

    func testTheRevealIgnoresUnusableInput() {
        let zoomed = RemoteViewportCalculator.normal(viewBounds: iPad, remoteAspectSize: wide)
        XCTAssertEqual(RemoteViewportCalculator.typingRevealOffset(of: .invalid, focus: caret(0.5, 0.5),
                                                                   visibleRect: iPadVisible, current: .zero), .zero)
        XCTAssertEqual(RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(1.5, 0.5),
                                                                   visibleRect: iPadVisible, current: .zero), .zero)
        XCTAssertEqual(RemoteViewportCalculator.typingRevealOffset(of: zoomed, focus: caret(0.5, 0.5),
                                                                   visibleRect: .zero, current: .zero), .zero)
    }
}
