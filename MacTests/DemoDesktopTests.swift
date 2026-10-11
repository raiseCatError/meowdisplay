import XCTest

/// Demo Mode's interactive desktop, driven with real finger sequences the
/// way the demo screen feeds them.
@MainActor
final class DemoDesktopTests: XCTestCase {
    /// 800×500 points showing a 960×600 desktop: 1.2 desktop points per view point.
    private let area = CGRect(x: 0, y: 0, width: 800, height: 500)
    private var clock: TimeInterval = 100

    private func makeInteraction(mode: ReceiverDisplayMode = .mirror) -> DemoInteraction {
        DemoInteraction(desktop: DemoDesktop(mode: mode, size: DemoDesktop.size(forAspect: 1.6)))
    }

    private func base(_ interaction: DemoInteraction) -> RemoteViewportTransform {
        DemoDisplayGeometry.baseTransform(area: area, desktopSize: interaction.desktop.size)
    }

    /// View point for a desktop point at the base (unzoomed) presentation.
    private func view(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / 1.2, y: p.y / 1.2) }

    @discardableResult
    private func run(_ interaction: inout DemoInteraction, _ frames: [[CGPoint]],
                     _ settings: DemoInputSettings = DemoInputSettings()) -> [DemoFeedback] {
        var feedback: [DemoFeedback] = []
        for points in frames + [[]] {
            clock += 0.02
            feedback += interaction.touches(points, at: clock, base: base(interaction), settings: settings)
        }
        clock += 1
        return feedback
    }

    private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    // MARK: Direct Touch

    func testDirectTapFocusesWindowAndSelectsFile() throws {
        var interaction = makeInteraction()
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        let row = CGPoint(x: files.frame.midX, y: files.frame.minY + DemoDesktop.titleBarHeight + 45)
        run(&interaction, [[view(row)]])
        XCTAssertEqual(interaction.desktop.focused, .files)
        XCTAssertEqual(interaction.desktop.windows.last?.kind, .files)
        XCTAssertEqual(interaction.desktop.selectedFile, DemoFile.samples[1].id)
    }

    func testDirectDoubleTapOpensFileInPreview() throws {
        var interaction = makeInteraction()
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        let row = view(CGPoint(x: files.frame.midX, y: files.frame.minY + DemoDesktop.titleBarHeight + 75))
        run(&interaction, [[row]])
        clock -= 0.9
        let feedback = run(&interaction, [[row]])
        XCTAssertEqual(interaction.desktop.previewFile, DemoFile.samples[2].id)
        XCTAssertEqual(interaction.desktop.focused, .preview)
        XCTAssertTrue(feedback.contains { if case .local = $0 { return true } else { return false } })
    }

    func testDirectDragMovesWindowByTitleBar() throws {
        var interaction = makeInteraction()
        let notes = try XCTUnwrap(interaction.desktop.window(.notes))
        let start = view(CGPoint(x: notes.frame.midX, y: notes.frame.minY + 10))
        run(&interaction, [[start], [CGPoint(x: start.x + 25, y: start.y + 10)],
                           [CGPoint(x: start.x + 50, y: start.y + 20)]])
        let moved = try XCTUnwrap(interaction.desktop.window(.notes))
        XCTAssertEqual(moved.frame.minX, notes.frame.minX + 60, accuracy: 0.5)
        XCTAssertEqual(moved.frame.minY, notes.frame.minY + 24, accuracy: 0.5)
        XCTAssertEqual(interaction.desktop.focused, .notes)
    }

    func testOneFingerDragScrollsContentInDirectTouch() throws {
        var interaction = makeInteraction()
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        let start = view(CGPoint(x: files.frame.midX, y: files.frame.maxY - 20))
        run(&interaction, [[start], [CGPoint(x: start.x, y: start.y - 30)], [CGPoint(x: start.x, y: start.y - 60)]])
        XCTAssertGreaterThan(try XCTUnwrap(interaction.desktop.window(.files)).scrollOffset, 0)
    }

    // MARK: Trackpad

    func testTrackpadMovesPointerRelativelyWithSensitivity() {
        var interaction = makeInteraction()
        let startCursor = interaction.cursor
        var settings = DemoInputSettings(inputMode: .trackpad)
        // Touching down far from the pointer must not jump it there.
        run(&interaction, [[CGPoint(x: 10, y: 10)], [CGPoint(x: 30, y: 10)], [CGPoint(x: 60, y: 20)]], settings)
        XCTAssertEqual(interaction.cursor.x, startCursor.x + 60, accuracy: 0.5)
        XCTAssertEqual(interaction.cursor.y, startCursor.y + 12, accuracy: 0.5)
        settings.trackpadSensitivity = 2
        let before = interaction.cursor
        run(&interaction, [[CGPoint(x: 400, y: 300)], [CGPoint(x: 410, y: 300)]], settings)
        XCTAssertEqual(interaction.cursor.x, before.x + 24, accuracy: 0.5)
    }

    func testTrackpadPointerIsClampedToDesktop() {
        var interaction = makeInteraction()
        let settings = DemoInputSettings(inputMode: .trackpad)
        run(&interaction, [[CGPoint(x: 0, y: 0)], [CGPoint(x: 2000, y: 2000)]], settings)
        XCTAssertLessThanOrEqual(interaction.cursor.x, interaction.desktop.size.width)
        XCTAssertLessThanOrEqual(interaction.cursor.y, interaction.desktop.size.height)
    }

    func testTrackpadTapClicksAtPointerNotFinger() throws {
        var interaction = makeInteraction()
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        interaction.cursor = CGPoint(x: files.frame.midX, y: files.frame.minY + DemoDesktop.titleBarHeight + 15)
        // Tap far away from the Files window.
        run(&interaction, [[CGPoint(x: 20, y: 480)]], DemoInputSettings(inputMode: .trackpad))
        XCTAssertEqual(interaction.desktop.selectedFile, DemoFile.samples[0].id)
        XCTAssertEqual(interaction.desktop.focused, .files)
    }

    func testTwoFingerScrollAtTrackpadPointer() throws {
        var interaction = makeInteraction()
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        interaction.cursor = CGPoint(x: files.frame.midX, y: files.frame.midY)
        let a = CGPoint(x: 300, y: 300), b = CGPoint(x: 340, y: 300)
        run(&interaction, [[a, b]] + (1...6).map { step in
            let dy = CGFloat(step) * -12
            return [CGPoint(x: a.x, y: a.y + dy), CGPoint(x: b.x, y: b.y + dy)]
        }, DemoInputSettings(inputMode: .trackpad))
        XCTAssertGreaterThan(try XCTUnwrap(interaction.desktop.window(.files)).scrollOffset, 0)
        XCTAssertEqual(interaction.viewport, .identity)
    }

    // MARK: Local view

    private func pinch(_ interaction: inout DemoInteraction, spread: CGFloat, turn: CGFloat = 0,
                       _ settings: DemoInputSettings = DemoInputSettings()) -> [DemoFeedback] {
        let c = CGPoint(x: 400, y: 250)
        let frames: [[CGPoint]] = (0...8).map { step in
            let t = CGFloat(step) / 8
            let r = 60 + spread * t
            let angle = turn * t
            return [CGPoint(x: c.x - r * cos(angle), y: c.y - r * sin(angle)),
                    CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))]
        }
        return run(&interaction, frames, settings)
    }

    func testPinchZoomsLocalViewAndTwoFingerDoubleTapResets() {
        var interaction = makeInteraction()
        pinch(&interaction, spread: 60)
        XCTAssertGreaterThan(interaction.viewport.scale, 1.3)
        XCTAssertEqual(interaction.viewport.rotationRadians, 0, "Rotation defaults to Disabled")
        // Zoomed in: the same view point now lands on a different desktop point.
        let zoomedScale = interaction.desktopScale(base: base(interaction), videoEnabled: true)
        XCTAssertLessThan(zoomedScale, 1.2)
        let a = CGPoint(x: 380, y: 250), b = CGPoint(x: 420, y: 250)
        run(&interaction, [[a, b]])
        clock -= 0.9
        run(&interaction, [[a, b]])
        XCTAssertEqual(interaction.viewport, .identity)
    }

    func testRotationFollowsRotateTargetAndSnaps() {
        var interaction = makeInteraction()
        var settings = DemoInputSettings(rotateTarget: .viewport, snapRotation: false)
        pinch(&interaction, spread: 0, turn: 0.5, settings)
        XCTAssertEqual(interaction.viewport.rotationRadians, 0.5, accuracy: 0.05)
        interaction.resetViewport()
        settings.snapRotation = true
        pinch(&interaction, spread: 0, turn: .pi / 2 - 0.05, settings)
        XCTAssertEqual(interaction.viewport.rotationRadians, .pi / 2, accuracy: 0.001)
    }

    func testPinchSetToAppPreviewsCommandInsteadOfZooming() {
        var interaction = makeInteraction()
        let feedback = pinch(&interaction, spread: 60, DemoInputSettings(pinchTarget: .app))
        XCTAssertEqual(interaction.viewport.scale, 1)
        XCTAssertTrue(feedback.contains(.macAppCommand(.zoomIn)))
    }

    func testLocalViewNavigationOffLeavesViewAndExplains() {
        var interaction = makeInteraction()
        let feedback = pinch(&interaction, spread: 60, DemoInputSettings(allowLocalViewNavigation: false))
        XCTAssertEqual(interaction.viewport, .identity)
        XCTAssertTrue(feedback.contains { if case .gestureOff = $0 { return true } else { return false } })
    }

    func testMoveViewPansWithOneFinger() {
        var interaction = makeInteraction()
        run(&interaction, [[CGPoint(x: 300, y: 200)], [CGPoint(x: 340, y: 230)]],
            DemoInputSettings(moveViewActive: true))
        XCTAssertEqual(interaction.viewport.panX, 40, accuracy: 0.5)
        XCTAssertEqual(interaction.viewport.panY, 30, accuracy: 0.5)
    }

    // MARK: Input off, Video off

    func testInputOffBlocksDesktopInputButKeepsLocalZoom() throws {
        var interaction = makeInteraction()
        let before = interaction.desktop
        let settings = DemoInputSettings(inputAllowed: false)
        let files = try XCTUnwrap(interaction.desktop.window(.files))
        let feedback = run(&interaction, [[view(center(files.frame))]], settings)
        XCTAssertEqual(feedback, [.inputOff])
        XCTAssertEqual(interaction.desktop, before)
        pinch(&interaction, spread: 60, settings)
        XCTAssertGreaterThan(interaction.viewport.scale, 1)
    }

    func testVideoOffKeepsTrackpadButNoViewChanges() {
        var interaction = makeInteraction()
        let settings = DemoInputSettings(inputMode: .trackpad, videoEnabled: false)
        let cursor = interaction.cursor
        run(&interaction, [[CGPoint(x: 100, y: 100)], [CGPoint(x: 150, y: 100)]], settings)
        XCTAssertGreaterThan(interaction.cursor.x, cursor.x)
        pinch(&interaction, spread: 60, settings)
        XCTAssertEqual(interaction.viewport, .identity)
    }

    // MARK: Mirror, Extend, shape

    func testMirrorAndExtendShowDifferentDesktops() {
        let mirror = DemoDesktop(mode: .mirror, size: DemoDesktop.size(forAspect: 1.6))
        let extend = DemoDesktop(mode: .extend, size: DemoDesktop.size(forAspect: 1.6))
        XCTAssertTrue(mirror.hasDock)
        XCTAssertFalse(extend.hasDock)
        XCTAssertNotEqual(Set(mirror.windows.map(\.kind)), Set(extend.windows.map(\.kind)))
        XCTAssertNotNil(extend.window(.arrangement))
        XCTAssertNil(mirror.window(.arrangement))
    }

    func testWindowsStartBelowMenuBarInsideDesktop() {
        for mode in [ReceiverDisplayMode.mirror, .extend] {
            for aspect in [1512.0 / 982.0, 1.6, 16.0 / 9, 32.0 / 9, 1.0, 0.46, 4.0 / 3] {
                let size = DemoDesktop.size(forAspect: aspect)
                for window in DemoDesktop(mode: mode, size: size).windows {
                    XCTAssertGreaterThanOrEqual(window.frame.minY, DemoDesktop.menuBarHeight, "\(mode) \(aspect) \(window.kind)")
                    XCTAssertLessThanOrEqual(window.frame.maxY, size.height, "\(mode) \(aspect) \(window.kind)")
                    XCTAssertGreaterThan(window.frame.height, DemoDesktop.titleBarHeight * 2, "\(mode) \(aspect) \(window.kind)")
                }
            }
        }
    }

    func testSwitchingModeKeepsNotesAndSelection() {
        var interaction = makeInteraction()
        interaction.desktop.raise(.notes)
        XCTAssertTrue(interaction.desktop.type(" Extra"))
        interaction.reconfigure(mode: .extend, size: DemoDesktop.size(forAspect: 1.6))
        XCTAssertEqual(interaction.desktop.mode, .extend)
        XCTAssertTrue(interaction.desktop.notes.hasSuffix(" Extra"))
    }

    func testExtendShapesKeepTheirRatios() {
        let receiver = CGSize(width: 874, height: 402)
        for shape in ExtendDisplayShape.allCases where shape != .automatic {
            let aspect = DemoDisplayGeometry.desktopAspect(
                mode: .extend, shape: ExtendDisplayShapePreference(shape: shape, useFullDisplay: false), receiverSize: receiver)
            XCTAssertEqual(aspect, try XCTUnwrap(shape.explicitAspect), accuracy: 0.0001, shape.rawValue)
            let size = DemoDesktop.size(forAspect: aspect)
            XCTAssertEqual(Double(size.width / size.height), aspect, accuracy: 0.01, shape.rawValue)
            // Fitting never stretches: the shown rect keeps the ratio.
            let shown = DemoDisplayGeometry.baseTransform(area: area, desktopSize: size).displayedRect
            XCTAssertEqual(Double(shown.width / shown.height), aspect, accuracy: 0.01, shape.rawValue)
        }
    }

    func testAutomaticIs16x10AndFullDisplayFollowsOrientation() {
        let landscape = CGSize(width: 874, height: 402)
        let portrait = CGSize(width: 402, height: 874)
        XCTAssertEqual(DemoDisplayGeometry.desktopAspect(mode: .extend, shape: .standard, receiverSize: landscape),
                       16.0 / 10.0, accuracy: 0.0001)
        let full = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true)
        XCTAssertEqual(DemoDisplayGeometry.desktopAspect(mode: .extend, shape: full, receiverSize: landscape),
                       874.0 / 402.0, accuracy: 0.0001)
        let tall = DemoDisplayGeometry.desktopAspect(mode: .extend, shape: full, receiverSize: portrait)
        XCTAssertEqual(tall, 402.0 / 874.0, accuracy: 0.0001)
        let size = DemoDesktop.size(forAspect: tall)
        XCTAssertGreaterThan(size.height, size.width)
        // A tall desktop stacks its windows, all inside the desktop.
        let desktop = DemoDesktop(mode: .extend, size: size)
        for window in desktop.windows {
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(window.frame), "\(window.kind)")
        }
    }

    func testMirrorUsesSampleMacShapeRegardlessOfExtendShape() {
        let shape = ExtendDisplayShapePreference(shape: .r1x1, useFullDisplay: false)
        XCTAssertEqual(DemoDisplayGeometry.desktopAspect(mode: .mirror, shape: shape, receiverSize: CGSize(width: 400, height: 900)),
                       1512.0 / 982.0, accuracy: 0.0001)
    }

    func testExtendPointSizeComesFromRealSizing() {
        let full = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true)
        let size = DemoDisplayGeometry.extendPointSize(shape: full, receiverPixels: CGSize(width: 2752, height: 2064))
        XCTAssertEqual(size.wide, 1376)
        XCTAssertEqual(size.high, 1032)
    }

    // MARK: Keys

    func testControlKeysActLocallyWhereTheyCan() {
        var desktop = DemoDesktop(mode: .mirror, size: DemoDesktop.size(forAspect: 1.6))
        desktop.raise(.notes)
        XCTAssertEqual(desktop.key(usage: 4, modifiers: []), .local("Typed in Notes"))
        XCTAssertTrue(desktop.notes.hasSuffix("a"))
        XCTAssertEqual(desktop.key(usage: 29, modifiers: ["command"]), .local("Undo"))
        XCTAssertEqual(desktop.key(usage: 29, modifiers: ["command", "shift"]), .local("Redo"))
        XCTAssertNil(desktop.key(usage: 6, modifiers: ["command"]), "Copy needs a Mac")
        XCTAssertEqual(desktop.key(usage: 43, modifiers: []), .local("Focused Files"))
        XCTAssertEqual(desktop.focused, .files)
        _ = desktop.key(usage: 81, modifiers: [])
        XCTAssertEqual(desktop.selectedFile, DemoFile.samples[0].id)
    }

    func testDockAndCloseButtonWork() throws {
        var desktop = DemoDesktop(mode: .mirror, size: DemoDesktop.size(forAspect: 1.6))
        let notes = try XCTUnwrap(desktop.window(.notes))
        _ = desktop.click(at: CGPoint(x: notes.frame.minX + 15, y: notes.frame.minY + 14))
        XCTAssertNil(desktop.window(.notes))
        let dockNotes = try XCTUnwrap(desktop.dockFrames().first { $0.0 == .notes }).1
        _ = desktop.click(at: CGPoint(x: dockNotes.midX, y: dockNotes.midY))
        XCTAssertNotNil(desktop.window(.notes))
        XCTAssertEqual(desktop.focused, .notes)
    }

    // MARK: Tray defaults

    func testNewControlPreferencesPutFunctionTrayOpposite() {
        let preferences = ReceiverControlPreferences()
        XCTAssertEqual(preferences.functionTrayPosition, .oppositeSide)
        XCTAssertEqual(preferences.padMainEdge, .trailing)
        XCTAssertEqual(preferences.padFunctionEdge, .leading)
    }

    func testSavedControlPreferencesKeepTheirTrayPlacement() throws {
        let suite = "DemoDesktopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)

        // Explicit saved choices win.
        var saved = ReceiverControlPreferences()
        saved.functionTrayPosition = .sameSide
        saved.padFunctionEdge = .trailing
        repository.save(saved)
        XCTAssertEqual(repository.load().functionTrayPosition, .sameSide)
        XCTAssertEqual(repository.load().padFunctionEdge, .trailing)

        // Saves from before these keys existed keep the earlier placement.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReceiverControlPreferences())) as? [String: Any])
        json.removeValue(forKey: "functionTrayPosition")
        json.removeValue(forKey: "padFunctionEdge")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        XCTAssertEqual(repository.load().functionTrayPosition, .sameSide)
        XCTAssertEqual(repository.load().padFunctionEdge, .trailing)
    }

    // MARK: Lifecycle

    func testReenteringDemoStartsFresh() {
        let first = DemoSession()
        first.workspace.interaction.desktop.raise(.notes)
        _ = first.workspace.interaction.desktop.type("changed")
        first.workspace.interaction.viewport.scale = 2
        first.extendShape = ExtendDisplayShapePreference(shape: .r4x3, useFullDisplay: false)
        let second = DemoSession()
        XCTAssertEqual(second.workspace.interaction.desktop.notes, DemoDesktop.initialNotes)
        XCTAssertEqual(second.workspace.interaction.viewport, .identity)
        XCTAssertEqual(second.extendShape, .standard)
    }
}
