import CoreGraphics
import XCTest

/// Stage Peek's rules: hold to open, scrub only browses, lift never selects,
/// a tap on any visible card selects exactly that window, everything Stage
/// Peek touches stays off the Mac. Also writes/checks
/// fixtures/stage-peek/vectors.json (WRITE_STAGE_PEEK_VECTORS=1), which the
/// Android port replays.
final class StagePeekTests: XCTestCase {
    private let ids: [UInt32] = [101, 102, 103, 104, 105, 106]
    private let phone = CGRect(x: 0, y: 47, width: 393, height: 771)   // iPhone portrait safe area

    private func machine(current: UInt32 = 103) -> StagePeekMachine {
        var m = StagePeekMachine()
        m.setItems(ids, current: current)
        return m
    }

    /// Holds on the left strip until Stage Peek opens.
    private func opened(_ m: inout StagePeekMachine, at p: CGPoint = CGPoint(x: 8, y: 430)) -> [StagePeekEffect] {
        XCTAssertTrue(m.touchBegan(id: 1, at: p, time: 0, onStrip: true))
        XCTAssertEqual(m.poll(now: StagePeekConfig.holdDelay - 0.01), [], "not before the hold delay")
        return m.poll(now: StagePeekConfig.holdDelay)
    }

    private func cards(_ m: StagePeekMachine) -> [StagePeekCard] {
        StagePeekLayout.cards(aspects: ids.map { _ in 1.5 }, position: m.position, expansion: m.expansion, edge: .left,
                              safe: phone, isPad: false, reduceMotion: false)
    }

    private func cardAt(_ m: StagePeekMachine) -> (CGPoint) -> Int? { let c = cards(m); return { StagePeekLayout.hit($0, cards: c) } }

    // MARK: Opening

    func testEdgeHoldOpensWithOneActivationHapticOnTheCurrentWindow() {
        var m = machine()
        XCTAssertEqual(opened(&m), [.opened, .haptic(.activate)])
        XCTAssertEqual(m.phase, .scrubbing)
        XCTAssertEqual(m.highlightedID, 103, "starts on the window shown now")
        XCTAssertEqual(m.poll(now: 1), [], "opens once")
    }

    func testTouchesOffTheStripAreNotStagePeeksWhileClosed() {
        var m = machine()
        XCTAssertFalse(m.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0, onStrip: false))
        XCTAssertEqual(m.phase, .closed)
    }

    func testASwipeFromTheEdgeNeitherOpensNorReachesTheMac() {
        var m = machine()
        XCTAssertTrue(m.touchBegan(id: 1, at: CGPoint(x: 8, y: 400), time: 0, onStrip: true), "owned: never forwarded")
        XCTAssertEqual(m.touchMoved(id: 1, to: CGPoint(x: 40, y: 400), time: 0.1, edge: .left), [])
        XCTAssertEqual(m.poll(now: 1), [])
        XCTAssertEqual(m.phase, .closed)
        XCTAssertEqual(m.touchEnded(id: 1, at: CGPoint(x: 60, y: 400), time: 0.2, cardAt: { _ in 0 }), [])
    }

    func testLiftingBeforeTheHoldOpensNothing() {
        var m = machine()
        _ = m.touchBegan(id: 1, at: CGPoint(x: 8, y: 400), time: 0, onStrip: true)
        XCTAssertEqual(m.touchEnded(id: 1, at: CGPoint(x: 8, y: 400), time: 0.1, cardAt: { _ in 0 }), [])
        XCTAssertEqual(m.poll(now: 1), [])
        XCTAssertEqual(m.phase, .closed)
    }

    func testAnEmptyCatalogNeverOpens() {
        var m = StagePeekMachine()
        XCTAssertFalse(m.touchBegan(id: 1, at: CGPoint(x: 8, y: 400), time: 0, onStrip: true))
    }

    // MARK: Scrubbing browses only

    func testScrubChangesOnlyTheHighlightWithOneTickPerChange() {
        var m = machine()
        _ = opened(&m)
        var effects: [StagePeekEffect] = []
        effects += m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 + 30), time: 0.4, edge: .left)
        XCTAssertEqual(m.highlightedID, 104)
        effects += m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 + 40), time: 0.45, edge: .left)
        XCTAssertEqual(m.highlightedID, 104, "same window: no tick")
        effects += m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 + 82), time: 0.5, edge: .left)
        XCTAssertEqual(m.highlightedID, 105)
        XCTAssertEqual(effects, [.haptic(.tick), .haptic(.tick)])
        XCTAssertFalse(effects.contains { if case .select = $0 { return true }; return false })
    }

    func testFastScrubTicksAreRateLimitedButTheHighlightKeepsUp() {
        var m = machine(current: 101)
        _ = opened(&m)
        var ticks = 0
        for step in 1...5 {   // five windows in 20 ms
            ticks += m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 + CGFloat(step) * 52), time: 0.4 + Double(step) * 0.004,
                                  edge: .left).filter { $0 == .haptic(.tick) }.count
        }
        XCTAssertEqual(m.highlightedID, 106)
        XCTAssertEqual(ticks, 1)
    }

    func testOverrunPlaysOneBoundaryHapticPerExcursion() {
        var m = machine(current: 101)
        _ = opened(&m)
        var effects = m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 - 30), time: 0.4, edge: .left)
        effects += m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 - 60), time: 0.5, edge: .left)
        XCTAssertEqual(effects, [.haptic(.boundary)])
        XCTAssertGreaterThan(m.position, -StagePeekConfig.maxOverrun - 1e-9, "rubber band")
        XCTAssertEqual(m.highlightedID, 101)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430), time: 0.6, edge: .left)
        XCTAssertEqual(m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 - 40), time: 0.7, edge: .left), [.haptic(.boundary)])
    }

    func testLiftNeverSelectsAndStagePeekStaysOpen() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8, y: 430 + 104), time: 0.5, edge: .left)
        XCTAssertEqual(m.touchEnded(id: 1, at: CGPoint(x: 8, y: 534), time: 0.6, cardAt: cardAt(m)), [])
        XCTAssertEqual(m.phase, .open)
        XCTAssertEqual(m.highlightedID, 105)
        XCTAssertEqual(m.position, 4, "settles on the highlighted window, no jump")
        XCTAssertEqual(m.poll(now: 5), [], "no selection when time passes either")
    }

    func testSecondFingerWhileScrubbingIsOwnedAndIgnored() {
        var m = machine()
        _ = opened(&m)
        XCTAssertTrue(m.touchBegan(id: 2, at: CGPoint(x: 200, y: 300), time: 0.4, onStrip: false))
        XCTAssertEqual(m.touchEnded(id: 2, at: CGPoint(x: 200, y: 300), time: 0.45, cardAt: { _ in 0 }), [])
        XCTAssertEqual(m.phase, .scrubbing)
    }

    // MARK: Tap to select

    func testTapOnTheHighlightedCardSelectsIt() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchEnded(id: 1, at: CGPoint(x: 8, y: 430), time: 0.5, cardAt: cardAt(m))
        let focus = cards(m).first { $0.highlighted }!
        XCTAssertTrue(m.touchBegan(id: 2, at: focus.center, time: 1, onStrip: false))
        XCTAssertEqual(m.touchEnded(id: 2, at: focus.center, time: 1.1, cardAt: cardAt(m)), [.haptic(.select), .select(103)])
        XCTAssertEqual(m.phase, .closed)
    }

    func testTapOnATiltedNeighbourSelectsExactlyThatWindow() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchEnded(id: 1, at: CGPoint(x: 8, y: 430), time: 0.5, cardAt: cardAt(m))
        let all = cards(m)
        let focus = all.first { $0.highlighted }!
        let below = all.first { $0.index == focus.index + 1 }!
        let above = all.first { $0.index == focus.index - 1 }!
        XCTAssertNotEqual(below.tilt, 0)
        // Points on the neighbours' visible parts, outside the front card.
        let belowPoint = CGPoint(x: below.center.x, y: below.center.y + below.size.height * 0.4)
        let abovePoint = CGPoint(x: above.center.x, y: above.center.y - above.size.height * 0.4)
        XCTAssertEqual(StagePeekLayout.hit(belowPoint, cards: all), focus.index + 1)
        XCTAssertEqual(StagePeekLayout.hit(abovePoint, cards: all), focus.index - 1)
        _ = m.touchBegan(id: 2, at: belowPoint, time: 1, onStrip: false)
        XCTAssertEqual(m.touchEnded(id: 2, at: belowPoint, time: 1.1, cardAt: cardAt(m)), [.haptic(.select), .select(104)])
    }

    func testWhereCardsOverlapTheFrontOneWins() {
        let all = StagePeekLayout.cards(aspects: [1.5, 1.5, 1.5], position: 1, expansion: 0, edge: .left,
                                        safe: phone, isPad: false, reduceMotion: false)
        let focus = all.first { $0.highlighted }!
        let below = all.first { $0.index == 2 }!
        // Inside both: just under the front card's bottom edge region shared with the next card.
        let shared = CGPoint(x: focus.center.x, y: (focus.center.y + focus.size.height / 2 + below.center.y - below.size.height / 2) / 2)
        XCTAssertTrue(focus.center.y + focus.size.height / 2 > below.center.y - below.size.height / 2, "the cards overlap")
        XCTAssertEqual(StagePeekLayout.hit(shared, cards: all), 1)
    }

    func testTapOutsideDismissesWithoutSwitching() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchEnded(id: 1, at: CGPoint(x: 8, y: 430), time: 0.5, cardAt: cardAt(m))
        let outside = CGPoint(x: 360, y: 200)
        XCTAssertNil(StagePeekLayout.hit(outside, cards: cards(m)))
        XCTAssertTrue(m.touchBegan(id: 2, at: outside, time: 1, onStrip: false), "owned: never a click on the Mac")
        XCTAssertEqual(m.touchEnded(id: 2, at: outside, time: 1.1, cardAt: cardAt(m)), [.dismissed])
        XCTAssertEqual(m.phase, .closed)
    }

    func testAHeldPressWhileOpenIsNotATap() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchEnded(id: 1, at: CGPoint(x: 8, y: 430), time: 0.5, cardAt: cardAt(m))
        let focus = cards(m).first { $0.highlighted }!
        _ = m.touchBegan(id: 2, at: focus.center, time: 1, onStrip: false)
        XCTAssertEqual(m.touchEnded(id: 2, at: focus.center, time: 2, cardAt: cardAt(m)), [])
        XCTAssertEqual(m.phase, .open)
    }

    func testDraggingTheOpenStackScrubsAgainWithoutSelecting() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchEnded(id: 1, at: CGPoint(x: 8, y: 430), time: 0.5, cardAt: cardAt(m))
        let focus = cards(m).first { $0.highlighted }!
        _ = m.touchBegan(id: 2, at: focus.center, time: 1, onStrip: false)
        _ = m.touchMoved(id: 2, to: CGPoint(x: focus.center.x, y: focus.center.y - 60), time: 1.1, edge: .left)
        XCTAssertEqual(m.highlightedID, 102)
        XCTAssertEqual(m.touchEnded(id: 2, at: CGPoint(x: focus.center.x, y: focus.center.y - 60), time: 1.2, cardAt: cardAt(m)), [])
        XCTAssertEqual(m.phase, .open)
    }

    // MARK: Expansion

    func testInwardDragExpandsOnlyPastTheDeliberateThreshold() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8 + StagePeekConfig.expandStart - 1, y: 430), time: 0.4, edge: .left)
        XCTAssertEqual(m.expansion, 0, "a small inward wobble does nothing")
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8 + (StagePeekConfig.expandStart + StagePeekConfig.expandFull) / 2, y: 430), time: 0.5, edge: .left)
        XCTAssertEqual(m.expansion, 0.5, accuracy: 1e-9, "progressive, following the finger")
        XCTAssertEqual(m.touchEnded(id: 1, at: .zero, time: 0.6, cardAt: { _ in 2 }), [], "lift after expanding never selects")
        XCTAssertFalse(m.expanded, "under the keep share: springs back to compact")
        XCTAssertEqual(m.expansion, 0)
    }

    func testDeepInwardDragStaysExpandedAndStillDoesNotSelect() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8 + StagePeekConfig.expandFull + 10, y: 470), time: 0.5, edge: .left)
        XCTAssertEqual(m.expansion, 1)
        XCTAssertEqual(m.touchEnded(id: 1, at: .zero, time: 0.6, cardAt: { _ in 2 }), [])
        XCTAssertTrue(m.expanded)
        XCTAssertEqual(m.phase, .open)
    }

    func testRightEdgeExpandsLeftward() {
        var m = machine()
        _ = m.touchBegan(id: 1, at: CGPoint(x: 385, y: 430), time: 0, onStrip: true)
        _ = m.poll(now: 1)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 385 - StagePeekConfig.expandFull, y: 430), time: 1.1, edge: .right)
        XCTAssertEqual(m.expansion, 1)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 385 + 100, y: 430), time: 1.2, edge: .right)
        XCTAssertEqual(m.expansion, 0, "moving toward the edge never expands")
    }

    func testExpandAndCompactButtons() {
        var m = machine()
        m.expand()
        XCTAssertFalse(m.expanded, "nothing to expand while closed")
        _ = opened(&m)
        m.expand()
        XCTAssertTrue(m.expanded)
        XCTAssertEqual(m.expansion, 1)
        m.compact()
        XCTAssertFalse(m.expanded)
        XCTAssertEqual(m.expansion, 0)
    }

    // MARK: Interruptions

    func testCancellationAndFoldNeverSelect() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8, y: 530), time: 0.5, edge: .left)
        m.touchCancelled(id: 1)
        XCTAssertEqual(m.phase, .open)
        m.cancelAll()
        XCTAssertEqual(m.phase, .closed)
        XCTAssertEqual(m.dismiss(), [])
    }

    func testACatalogReorderWhileScrubbingKeepsTheHighlightedWindow() {
        var m = machine()
        _ = opened(&m)
        _ = m.touchMoved(id: 1, to: CGPoint(x: 8, y: 482), time: 0.5, edge: .left)
        XCTAssertEqual(m.highlightedID, 104)
        m.setItems([106, 104, 101, 103], current: 103)
        XCTAssertEqual(m.highlightedID, 104, "same window, new index")
        m.setItems([106, 101], current: 103)
        XCTAssertNotNil(m.highlightedID, "a closed window: clamped onto a listed one, no crash")
        XCTAssertTrue([106, 101].contains(m.highlightedID!))
        m.setItems([], current: nil)
        XCTAssertEqual(m.phase, .closed, "nothing left: closes without selecting")
    }

    // MARK: Geometry

    func testHighlightedCardIsStraightLargestAndInFront() {
        for safe in [phone, CGRect(x: 59, y: 0, width: 734, height: 372), CGRect(x: 0, y: 24, width: 1032, height: 1342)] {
            let all = StagePeekLayout.cards(aspects: ids.map { _ in 1.6 }, position: 2, expansion: 0, edge: .left,
                                            safe: safe, isPad: safe.width > 1000, reduceMotion: false)
            let focus = all.first { $0.highlighted }!
            XCTAssertEqual(focus.tilt, 0)
            XCTAssertEqual(all.last, focus, "drawn last: in front")
            for c in all where c != focus {
                XCTAssertLessThan(c.size.width, focus.size.width)
                XCTAssertNotEqual(c.tilt, 0)
                XCTAssertEqual(c.index < focus.index, c.tilt > 0, "cards above tip their top away")
            }
            XCTAssertGreaterThanOrEqual(focus.center.x - focus.size.width / 2, safe.minX, "inside the safe area")
            XCTAssertLessThan(focus.center.x + focus.size.width / 2, safe.midX + 1, "compact: hugs the edge, the Mac stays visible")
        }
    }

    func testReduceMotionRemovesTheTilt() {
        let all = StagePeekLayout.cards(aspects: [1, 1, 1], position: 1, expansion: 0, edge: .right,
                                        safe: phone, isPad: false, reduceMotion: true)
        XCTAssertTrue(all.allSatisfy { $0.tilt == 0 })
        XCTAssertGreaterThan(all.first { $0.highlighted }!.center.x, phone.midX, "right edge")
    }

    func testExpandedBrowserIsCentredAndLarger() {
        let compact = StagePeekLayout.cards(aspects: [1.5, 1.5], position: 0, expansion: 0, edge: .left, safe: phone, isPad: false, reduceMotion: false)
        let wide = StagePeekLayout.cards(aspects: [1.5, 1.5], position: 0, expansion: 1, edge: .left, safe: phone, isPad: false, reduceMotion: false)
        let c = compact.first { $0.highlighted }!, w = wide.first { $0.highlighted }!
        XCTAssertEqual(w.center.x, phone.midX, accuracy: 1e-9)
        XCTAssertGreaterThan(w.size.width, c.size.width)
    }

    func testStripStaysInsideTheSafeAreaAndUnderTheGestureExclusionLimit() {
        for edge in StagePeekEdge.allCases {
            let s = StagePeekLayout.strip(edge: edge, safe: phone)!
            XCTAssertTrue(phone.contains(s))
            XCTAssertLessThanOrEqual(s.height, StagePeekConfig.edgeStripMaxHeight)
        }
    }

    func testStripAvoidsControlsOnItsEdge() {
        let landscape = CGRect(x: 59, y: 0, width: 734, height: 372)
        let functionTray = CGRect(x: 59, y: 100, width: 52, height: 170)   // controls on the left, mid-height
        let s = StagePeekLayout.strip(edge: .left, safe: landscape, avoiding: [functionTray])!
        XCTAssertFalse(s.intersects(functionTray))
        XCTAssertGreaterThanOrEqual(s.height, 60)
        XCTAssertNil(StagePeekLayout.strip(edge: .left, safe: landscape, avoiding: [CGRect(x: 59, y: 0, width: 40, height: 372)]),
                     "no room: no strip (and no stray hold area over controls)")
        XCTAssertEqual(StagePeekLayout.strip(edge: .right, safe: landscape, avoiding: [functionTray])?.height,
                       StagePeekConfig.edgeStripMaxHeight, "the other edge is unaffected")
    }

    func testAccessibilityOpenStepAndSelect() {
        var m = machine()
        XCTAssertEqual(m.openDirectly(), [.opened, .haptic(.activate)])
        XCTAssertEqual(m.phase, .open)
        XCTAssertEqual(m.step(1), [.haptic(.tick)])
        XCTAssertEqual(m.highlightedID, 104)
        XCTAssertEqual(m.step(10), [.haptic(.tick)])
        XCTAssertEqual(m.highlightedID, 106)
        XCTAssertEqual(m.step(1), [.haptic(.boundary)])
        XCTAssertEqual(m.selectHighlighted(), [.haptic(.select), .select(106)])
        XCTAssertEqual(m.phase, .closed)
        // A card's own VoiceOver action chooses that card, open or not highlighted.
        XCTAssertEqual(m.select(index: 1), [], "nothing while closed")
        _ = m.openDirectly()
        XCTAssertEqual(m.select(index: 0), [.haptic(.select), .select(101)])
        XCTAssertEqual(m.phase, .closed)
    }

    // MARK: Preferences

    func testStagePeekIsTheDefaultSwitcherAndOldBlobsKeepEverythingElse() throws {
        XCTAssertEqual(ReceiverControlPreferences().windowSwitcher, .stagePeek)
        XCTAssertEqual(ReceiverControlPreferences().stagePeekEdge, .left)
        var old = ReceiverControlPreferences()
        old.touchStyle = .classic
        old.inputMode = .trackpad
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "windowSwitcher"); json.removeValue(forKey: "stagePeekEdge"); json["version"] = 19
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StagePeekTests.\(UUID())"))
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        var loaded = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertEqual(loaded.windowSwitcher, .stagePeek)
        XCTAssertEqual(loaded.touchStyle, .classic, "switcher default never touches Touch Style")
        loaded.windowSwitcher = .rail
        loaded.stagePeekEdge = .right
        ReceiverControlPreferencesRepository(defaults: defaults).save(loaded)
        let again = ReceiverControlPreferencesRepository(defaults: defaults).load()
        XCTAssertEqual(again.windowSwitcher, .rail, "an explicit Rail choice persists")
        XCTAssertEqual(again.stagePeekEdge, .right)
        XCTAssertEqual(WindowSwitcherStyle.stagePeek.rawValue, "stagePeek")
        XCTAssertEqual(StagePeekEdge.left.rawValue, "left")
    }

    // MARK: Shared vectors

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/stage-peek/vectors.json")
    }

    private func vectors() -> [String: Any] {
        func render(_ e: [StagePeekEffect]) -> [String] {
            e.map {
                switch $0 {
                case .opened: return "opened"
                case .haptic(let h): return "haptic \(h.rawValue)"
                case .select(let id): return "select \(id)"
                case .dismissed: return "dismissed"
                }
            }
        }
        func card(_ c: StagePeekCard) -> [String: Any] {
            ["index": c.index, "cx": Double(c.center.x), "cy": Double(c.center.y), "w": Double(c.size.width),
             "h": Double(c.size.height), "tilt": c.tilt, "z": c.z, "opacity": c.opacity, "highlighted": c.highlighted]
        }
        var layouts: [[String: Any]] = []
        let safes: [(String, CGRect, Bool)] = [("phonePortrait", phone, false),
                                               ("phoneLandscape", CGRect(x: 59, y: 0, width: 734, height: 372), false),
                                               ("tablet", CGRect(x: 0, y: 24, width: 1032, height: 1342), true)]
        for (name, safe, pad) in safes {
            for (position, expansion, edge, reduce) in [(2.0, 0.0, StagePeekEdge.left, false), (2.4, 0.0, .right, false),
                                                        (0.0, 0.5, .left, false), (5.0, 1.0, .left, false), (1.0, 0.0, .left, true)] {
                let aspects = [1.6, 0.75, 1.33, 2.0, 1.0, 1.78]
                let cs = StagePeekLayout.cards(aspects: aspects, position: position, expansion: expansion, edge: edge,
                                               safe: safe, isPad: pad, reduceMotion: reduce)
                var hits: [[String: Any]] = []
                for c in cs {
                    for p in [c.center, CGPoint(x: c.center.x, y: c.center.y + c.size.height * 0.45),
                              CGPoint(x: c.center.x + c.size.width * 0.45, y: c.center.y - c.size.height * 0.45)] {
                        hits.append(["x": Double(p.x), "y": Double(p.y), "card": StagePeekLayout.hit(p, cards: cs) ?? -1])
                    }
                }
                hits.append(["x": Double(safe.maxX - 2), "y": Double(safe.minY + 2), "card": StagePeekLayout.hit(CGPoint(x: safe.maxX - 2, y: safe.minY + 2), cards: cs) ?? -1])
                layouts.append(["name": name, "safe": [Double(safe.minX), Double(safe.minY), Double(safe.width), Double(safe.height)],
                                "isPad": pad, "aspects": aspects, "position": position, "expansion": expansion,
                                "edge": edge.rawValue, "reduceMotion": reduce, "cards": cs.map(card), "hits": hits,
                                "strip": { let s = StagePeekLayout.strip(edge: edge, safe: safe)!; return [Double(s.minX), Double(s.minY), Double(s.width), Double(s.height)] }()])
            }
        }
        // One scripted session through the machine, with every step's effects and state.
        var m = machine()
        var steps: [[String: Any]] = []
        func record(_ op: [String: Any], _ e: [StagePeekEffect]) {
            var s = op
            s["effects"] = render(e)
            s["phase"] = m.phase.rawValue
            s["highlighted"] = m.highlightedID.map { Int($0) } ?? -1
            s["position"] = m.position
            s["expansion"] = m.expansion
            s["expanded"] = m.expanded
            steps.append(s)
        }
        func began(_ id: Int, _ x: Double, _ y: Double, _ t: Double, strip: Bool) {
            let owned = m.touchBegan(id: id, at: CGPoint(x: x, y: y), time: t, onStrip: strip)
            record(["op": "began", "id": id, "x": x, "y": y, "t": t, "onStrip": strip, "owned": owned], [])
        }
        func moved(_ id: Int, _ x: Double, _ y: Double, _ t: Double) {
            record(["op": "moved", "id": id, "x": x, "y": y, "t": t], m.touchMoved(id: id, to: CGPoint(x: x, y: y), time: t, edge: .left))
        }
        func ended(_ id: Int, _ x: Double, _ y: Double, _ t: Double) {
            // Hit testing uses the cards as drawn when the finger lifts.
            let drawn = cards(m)
            let e = m.touchEnded(id: id, at: CGPoint(x: x, y: y), time: t, cardAt: { StagePeekLayout.hit($0, cards: drawn) })
            record(["op": "ended", "id": id, "x": x, "y": y, "t": t], e)
        }
        func poll(_ t: Double) { record(["op": "poll", "t": t], m.poll(now: t)) }
        began(1, 8, 430, 0, strip: true); poll(0.2); poll(0.3)
        moved(1, 8, 460, 0.4); moved(1, 8, 470, 0.42); moved(1, 8, 512, 0.5); moved(1, 8, 513, 0.52)
        moved(1, 8, 330, 0.6); moved(1, 8, 300, 0.61); moved(1, 8, 250, 0.7)
        moved(1, 90, 300, 0.8); ended(1, 90, 300, 0.9)
        let neighbour = cards(m).first { $0.index == m.highlighted + 1 }!
        let np = CGPoint(x: neighbour.center.x, y: neighbour.center.y + neighbour.size.height * 0.4)
        began(2, Double(np.x), Double(np.y), 1.5, strip: false); ended(2, Double(np.x), Double(np.y), 1.6)
        began(3, 8, 400, 2, strip: true); moved(3, 30, 400, 2.1); poll(3); ended(3, 30, 400, 3.1)
        began(4, 8, 400, 4, strip: true); poll(4.31); moved(4, 8 + 170, 400, 4.4); ended(4, 178, 400, 4.5)
        began(5, 360, 120, 5, strip: false); ended(5, 360, 120, 5.05)
        return ["about": "Generated by MacTests/StagePeekTests.swift (WRITE_STAGE_PEEK_VECTORS=1); replayed by the Android port.",
                "config": ["holdDelay": StagePeekConfig.holdDelay, "holdSlop": Double(StagePeekConfig.holdSlop),
                           "scrubPitch": Double(StagePeekConfig.scrubPitch), "expandStart": Double(StagePeekConfig.expandStart),
                           "expandFull": Double(StagePeekConfig.expandFull), "expandKeep": StagePeekConfig.expandKeep,
                           "tickSpacing": StagePeekConfig.tickSpacing, "perspective": Double(StagePeekConfig.perspective)],
                "machine": ["ids": ids.map { Int($0) }, "current": 103, "safe": [0, 47, 393, 771], "aspect": 1.5, "steps": steps],
                "layouts": layouts]
    }

    func testSharedVectors() throws {
        let generated = vectors()
        let data = try JSONSerialization.data(withJSONObject: generated, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["WRITE_STAGE_PEEK_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL)
        }
        let saved = try Data(contentsOf: Self.fixtureURL)
        let a = try JSONSerialization.jsonObject(with: saved) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(a, b, "fixtures/stage-peek/vectors.json is stale: rerun with WRITE_STAGE_PEEK_VECTORS=1")
        // The scripted session's key facts, independent of the file.
        let steps = (generated["machine"] as! [String: Any])["steps"] as! [[String: Any]]
        let effects = steps.flatMap { $0["effects"] as! [String] }
        XCTAssertEqual(effects.filter { $0.hasPrefix("select") }.count, 1, "exactly one selection: the tap")
        XCTAssertEqual(effects.filter { $0 == "dismissed" }.count, 1, "the tap outside")
    }
}
