import CoreGraphics
import XCTest

/// Smart Touch (Experimental): the pure engine policy in
/// `Shared/PointerGestureEngine.swift` plus the Mac-side Accessibility
/// role classification in `Mac/SmartTouchTargetClassifier.swift`.
final class SmartTouchTests: XCTestCase {
    private func sample(_ id: Int, _ phase: PointerTouchSample.Phase,
                        view: CGPoint, norm: CGPoint? = CGPoint(x: 0.5, y: 0.5),
                        t: TimeInterval) -> PointerTouchSample {
        PointerTouchSample(id: AnyHashable(id), phase: phase, viewPoint: view, normalized: norm, time: t)
    }

    private func smartEngine() -> PointerGestureEngine {
        let engine = PointerGestureEngine()
        engine.smartTouchEnabled = true
        return engine
    }

    /// Touch down at (100,100) and return the probe id it asked for.
    private func beginProbedTouch(_ engine: PointerGestureEngine, id: Int = 1, t: TimeInterval = 0) -> Int? {
        let out = engine.handle(sample(id, .began, view: CGPoint(x: 100, y: 100),
                                       norm: CGPoint(x: 0.2, y: 0.2), t: t))
        guard out.count == 1, case .probeScrollTarget(let probeID, let x, let y) = out[0] else { return nil }
        XCTAssertEqual(x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(y, 0.2, accuracy: 1e-9)
        return probeID
    }

    // MARK: - Off / Trackpad: exact existing path

    func testDisabledSmartTouchNeverProbesAndKeepsDirectTouch() {
        let engine = PointerGestureEngine()
        XCTAssertEqual(engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0)), [])
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100),
                                         norm: CGPoint(x: 0.4, y: 0.2), t: 0.01))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testTrackpadIgnoresSmartTouch() {
        let engine = smartEngine()
        engine.setInputMode(.trackpad)
        XCTAssertEqual(engine.handle(sample(1, .began, view: CGPoint(x: 100, y: 100), t: 0)), [])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), t: 0.01)), [])
        XCTAssertEqual(engine.mode, .relativePointerSession)
        // A stray reply can't change anything either.
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: 1, scrollable: true), [])
        XCTAssertEqual(engine.mode, .relativePointerSession)
    }

    // MARK: - Classification outcomes

    func testScrollableTargetTurnsOneFingerSwipeIntoScroll() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, scrollable: true), [])   // no movement yet
        let first = engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(first, [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.mode, .smartScroll)
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 150), t: 0.04)),
                       [.scroll(dx: 0, dy: 20)])
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 150), t: 0.05)),
                       [.scrollEnded(momentum: true)])
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.heldMouseButton, nil)
    }

    func testCancelledSmartScrollEndsWithoutMomentum() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: true)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(engine.handle(sample(1, .cancelled, view: CGPoint(x: 100, y: 130), t: 0.04)),
                       [.scrollEnded(momentum: false)])
    }

    func testNonScrollableTargetFallsBackToDirectTouch() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: false)
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100),
                                         norm: CGPoint(x: 0.4, y: 0.2), t: 0.03))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testLateReplyCommitsTheWithheldMovement() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        // Crossed drag slop before the Mac answered — withheld, not committed.
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.02)), [])
        XCTAssertEqual(engine.mode, .firstTouchPending)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, scrollable: true),
                       [.moveAbsolute(x: 0.2, y: 0.2), .scroll(dx: 0, dy: 30)])
        XCTAssertEqual(engine.mode, .smartScroll)
    }

    func testLateNegativeReplyCommitsDirectTouch() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(1, .moved, view: CGPoint(x: 150, y: 100), norm: CGPoint(x: 0.4, y: 0.2), t: 0.02))
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, scrollable: false),
                       [.moveAbsolute(x: 0.4, y: 0.2)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    /// No reply at all (lookup failed, Mac never answered) — the existing
    /// arbitration window commits ordinary Direct Touch.
    func testMissingReplyFallsBackAfterArbitrationWindow() throws {
        let engine = smartEngine()
        _ = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), norm: CGPoint(x: 0.2, y: 0.3), t: 0.02))
        let out = engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow)
        XCTAssertEqual(out, [.moveAbsolute(x: 0.2, y: 0.3)])
        XCTAssertEqual(engine.mode, .absolutePointer)
    }

    func testStaleReplyIsIgnored() throws {
        let engine = smartEngine()
        let firstProbe = try XCTUnwrap(beginProbedTouch(engine, id: 1))
        engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100), t: 0.05))   // a tap
        engine.poll(now: 1)                                                          // flushed
        let secondProbe = try XCTUnwrap(beginProbedTouch(engine, id: 2, t: 2))
        XCTAssertNotEqual(firstProbe, secondProbe)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: firstProbe, scrollable: true), [])
        let moved = engine.handle(sample(2, .moved, view: CGPoint(x: 100, y: 130), t: 2.01))
        XCTAssertEqual(moved, [], "still waiting on its own probe")
    }

    // MARK: - Intent lock

    func testScrollIntentStaysLockedUntilLift() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: true)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        // A second finger, a pause, and more movement never turn it into
        // a pointer move or drag.
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 200, y: 100), t: 0.1)), [])
        XCTAssertEqual(engine.poll(now: 2), [])
        XCTAssertEqual(engine.handle(sample(1, .moved, view: CGPoint(x: 110, y: 130), t: 2.1)),
                       [.scroll(dx: 10, dy: 0)])
        XCTAssertEqual(engine.handle(sample(2, .moved, view: CGPoint(x: 250, y: 100), t: 2.2)), [])
        XCTAssertEqual(engine.mode, .smartScroll)
    }

    func testDirectIntentStaysLockedEvenIfAReplyArrivesLater() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.poll(now: PointerGestureConfig.firstTouchArbitrationWindow)   // held still: Direct Touch
        XCTAssertEqual(engine.mode, .absolutePointer)
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, scrollable: true), [])
        let moved = engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 150),
                                         norm: CGPoint(x: 0.2, y: 0.4), t: 0.3))
        XCTAssertEqual(moved, [.moveAbsolute(x: 0.2, y: 0.4)])
    }

    // MARK: - Taps and tap-hold-drag

    func testTapOnScrollableTargetIsStillAClick() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: true)
        XCTAssertEqual(engine.handle(sample(1, .ended, view: CGPoint(x: 102, y: 101),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.08)),
                       [.moveAbsolute(x: 0.2, y: 0.2)])
        XCTAssertEqual(engine.poll(now: 1), [.mouseDown(button: .left, clickCount: 1),
                                             .mouseUp(button: .left, clickCount: 1)])
    }

    func testDoubleAndTripleTapsKeepClickCounts() throws {
        let engine = smartEngine()
        for i in 0..<3 {
            let t = Double(i) * 0.15
            let out = engine.handle(sample(i + 1, .began, view: CGPoint(x: 100, y: 100), t: t))
            if let probe = out.compactMap({ c -> Int? in
                if case .probeScrollTarget(let id, _, _) = c { return id }; return nil }).first {
                engine.resolveSmartTouchProbe(id: probe, scrollable: true)
            }
            engine.handle(sample(i + 1, .ended, view: CGPoint(x: 100, y: 100), t: t + 0.05))
        }
        XCTAssertEqual(engine.poll(now: 5), [.mouseDown(button: .left, clickCount: 3),
                                             .mouseUp(button: .left, clickCount: 3)])
    }

    func testTapThenHoldDragOverScrollableAreaIsStillALeftDrag() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: true)
        engine.handle(sample(1, .ended, view: CGPoint(x: 100, y: 100), t: 0.05))
        // The continuing touch does not probe — tap-then-hold is a drag.
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 100, y: 100),
                                            norm: CGPoint(x: 0.2, y: 0.2), t: 0.15)), [])
        let drag = engine.handle(sample(2, .moved, view: CGPoint(x: 100, y: 130),
                                        norm: CGPoint(x: 0.2, y: 0.3), t: 0.2))
        XCTAssertEqual(drag, [.moveAbsolute(x: 0.2, y: 0.3), .mouseDown(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.mode, .leftDragHeld)
    }

    // MARK: - Multi-finger paths untouched

    func testTwoFingerStartStillFormsAFreshChord() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        XCTAssertEqual(engine.handle(sample(2, .began, view: CGPoint(x: 130, y: 100), t: 0.02)), [])
        XCTAssertEqual(engine.mode, .twoFingerPending)
        // Late reply for the first finger changes nothing — scroll, pinch
        // and rotation stay with the two-finger recognizer.
        XCTAssertEqual(engine.resolveSmartTouchProbe(id: probe, scrollable: true), [])
        XCTAssertEqual(engine.mode, .twoFingerPending)
    }

    func testThreeFingerStartStillDefersToSystemGestures() throws {
        let engine = smartEngine()
        _ = try XCTUnwrap(beginProbedTouch(engine))
        engine.handle(sample(2, .began, view: CGPoint(x: 130, y: 100), t: 0.01))
        engine.handle(sample(3, .began, view: CGPoint(x: 160, y: 100), t: 0.02))
        XCTAssertEqual(engine.mode, .deferredSystemGesture)
    }

    func testResetClearsSmartScroll() throws {
        let engine = smartEngine()
        let probe = try XCTUnwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id: probe, scrollable: true)
        engine.handle(sample(1, .moved, view: CGPoint(x: 100, y: 130), t: 0.03))
        XCTAssertEqual(engine.reset(), [])
        XCTAssertEqual(engine.mode, .idle)
    }

    // MARK: - Accessibility role classification

    func testScrollAreaAncestorIsScrollable() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXStaticText", "AXCell", "AXRow", "AXTable", "AXScrollArea", "AXWindow"]),
                       .scrollable(container: "AXScrollArea"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXGroup", "AXWebArea"]),
                       .scrollable(container: "AXWebArea"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXTextArea", "AXScrollArea"]),
                       .scrollable(container: "AXScrollArea"))
    }

    func testControlsAndPlainWindowsAreNotScrollable() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXSlider", "AXScrollArea"]),
                       .notScrollable(reason: "control:AXSlider"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXScrollBar", "AXScrollArea"]),
                       .notScrollable(reason: "control:AXScrollBar"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXButton", "AXGroup", "AXWindow", "AXScrollArea"]),
                       .notScrollable(reason: "noScrollContainer"))
    }

    func testUnknownOrMissingTargetsFallBack() {
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: []), .notScrollable(reason: "noElement"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: Array(repeating: "AXGroup", count: 40)),
                       .notScrollable(reason: "depthLimit"))
        XCTAssertEqual(SmartTouchTargetClassifier.classify(roles: ["AXUnknown"]),
                       .notScrollable(reason: "depthLimit"))
    }

    // MARK: - Preference persistence

    func testSmartTouchDefaultsOffAndMigratesFromOlderSchema() throws {
        XCTAssertFalse(ReceiverControlPreferences().smartTouchEnabled)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SmartTouchTests.\(UUID().uuidString)"))
        var old = ReceiverControlPreferences()
        old.version = 13
        old.inputMode = .trackpad
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "smartTouchEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        let loaded = repository.load()
        XCTAssertEqual(loaded.version, ReceiverControlPreferences.schemaVersion)
        XCTAssertFalse(loaded.smartTouchEnabled)
        XCTAssertEqual(loaded.inputMode, .trackpad, "other preferences survive")

        var enabled = loaded
        enabled.smartTouchEnabled = true
        repository.save(enabled)
        XCTAssertTrue(repository.load().smartTouchEnabled)
    }
}
