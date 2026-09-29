import CoreGraphics
import XCTest

/// Second physical-QA pass: system actions, rail anchoring, software-keyboard
/// chords, the editable Function Tray and its sequences, scroll direction,
/// Wheel and fan geometry, editor/import flows, and Request Input.
final class SecondQARefinementTests: XCTestCase {
    private let container = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let safe = ControlSafeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    private let metrics = PadControlMetrics()

    // MARK: - System actions

    func testSystemActionsMapToDocumentedMacShortcuts() {
        let menuBar = SystemGestureShortcutMapping.shortcut(for: .menuBar)
        XCTAssertEqual(menuBar.keyCode, 120, "Control-F2 focuses the menu bar")
        XCTAssertEqual(menuBar.flags, [.maskControl, .maskSecondaryFn])
        XCTAssertEqual(SystemGestureShortcutMapping.shortcut(for: .controlCenter).keyCode, 8)
        XCTAssertEqual(SystemGestureShortcutMapping.shortcut(for: .showDesktop).keyCode, 103)
        XCTAssertTrue(ReceiverGesture.shouldRoute(name: "menuBar", inputAllowed: true))
        XCTAssertFalse(ReceiverGesture.shouldRoute(name: "menuBar", inputAllowed: false))
    }

    func testStandardSystemGroupIsMenuBarDockDesktopControlCenter() throws {
        let items = FunctionTrayProfile.canonical().items
        let menuBar = try XCTUnwrap(items.first { $0.id == "menu-bar" })
        XCTAssertEqual(menuBar.item.action, .receiverGesture(ReceiverGesture.menuBar.rawValue))
        XCTAssertFalse(menuBar.isVisible, "opt-in in the Function Tray itself")
        let groups = PadRailComposition.mainGroups(
            visibility: PadStandardControlVisibility(),
            availability: .init(modifiers: ControlModifier.allCases, keyboardAvailable: true, moveViewAvailable: true))
        XCTAssertEqual(groups.first, [.function("menu-bar"), .tray(.dock), .function("show-desktop"),
                                      .function("control-center")])
        XCTAssertEqual(PadRailComposition.alignments(for: groups), [.start, .center, .end])
        // Dock stays the existing ⌥⌘D tray action.
        XCTAssertEqual(PadStandardControl.dock.kind, .tray(.dock))
    }

    // MARK: - Rail anchoring

    private func railLayout(main: ControlEdge = .trailing, function: ControlEdge = .trailing,
                            functionGroups: [Int] = [2, 2], strip: Bool = false,
                            metrics: PadControlMetrics? = nil, keyboardTop: CGFloat? = nil,
                            size: CGRect? = nil) -> PadEdgeLayout {
        PadEdgeGeometry.layout(container: size ?? container, safeInsets: safe, reservesStrips: strip,
                               mainEdge: main, functionEdge: function, mainGroupCounts: [4, 7, 2],
                               mainGroupAlignments: [.start, .center, .end], functionGroupCounts: functionGroups,
                               metrics: metrics ?? self.metrics, keyboardTop: keyboardTop)
    }

    func testSystemGroupStartsAtTheTopAndSettingsSitsAtTheBottom() throws {
        let layout = railLayout(functionGroups: [])
        let railTop = 24 + PadControlMetrics.edgeMargin
        let railBottom = 834 - 20 - PadControlMetrics.edgeMargin
        XCTAssertEqual(layout.mainSegments.first?.frame.minY ?? 0, railTop, accuracy: 0.01)
        XCTAssertEqual(layout.mainSegments.last?.frame.maxY ?? 0, railBottom, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(layout.mainSegments.first).frame.midX, container.midX, "top-right")
    }

    func testSharedEdgeFunctionGroupsSitBetweenTheAnchoredGroups() {
        let layout = railLayout(size: CGRect(x: 0, y: 0, width: 834, height: 1194))
        XCTAssertEqual(layout.laneCounts[.trailing], 1)
        let system = layout.mainSegments[0].frame
        let settings = layout.mainSegments[2].frame
        for segment in layout.functionSegments {
            XCTAssertGreaterThan(segment.frame.minY, system.maxY)
            XCTAssertLessThan(segment.frame.maxY, settings.minY)
        }
    }

    func testAnchoredRailsNeverOverlapAnywhere() {
        for size in [container, CGRect(x: 0, y: 0, width: 834, height: 1194)] {
            for strip in [true, false] {
                for scale in [0.85, 1.4] {
                    for main in ControlEdge.allCases {
                        for function in ControlEdge.allCases {
                            let metrics = PadControlMetrics(scale: scale)
                            let layout = railLayout(main: main, function: function, functionGroups: [2, 2, 3],
                                                    strip: strip, metrics: metrics, size: size)
                            let cells = layout.mainCells + layout.functionCells
                            XCTAssertEqual(cells.count, 20)
                            for i in cells.indices {
                                for j in cells.indices where j > i {
                                    XCTAssertFalse(cells[i].insetBy(dx: -metrics.gap / 2 + 0.01, dy: -metrics.gap / 2 + 0.01)
                                        .intersects(cells[j].insetBy(dx: -metrics.gap / 2 + 0.01, dy: -metrics.gap / 2 + 0.01)),
                                                   "\(size.size) strip=\(strip) \(scale) \(main)/\(function)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testSettingsStaysReachableAboveTheKeyboard() throws {
        let layout = railLayout(functionGroups: [], keyboardTop: 480)
        let settings = try XCTUnwrap(layout.mainSegments.last).frame
        let system = try XCTUnwrap(layout.mainSegments.first).frame
        XCTAssertEqual(settings.maxY, 480 - PadControlMetrics.edgeMargin, accuracy: 0.01)
        XCTAssertEqual(system.minY, 24 + PadControlMetrics.edgeMargin, accuracy: 0.01)
        XCTAssertEqual(settings.midX, system.midX, accuracy: 0.01, "both stay on the outer lane")
        let cells = layout.mainCells
        for i in cells.indices {
            for j in cells.indices where j > i { XCTAssertFalse(cells[i].intersects(cells[j])) }
            XCTAssertLessThanOrEqual(cells[i].maxY, 480)
        }
    }

    // MARK: - Modifier buttons + software keyboard

    func testTypedKeysCombineWithTheActiveChord() throws {
        let copy = try XCTUnwrap(SoftwareKeyboardChordPolicy.press(for: "c", modifiers: [.command]))
        XCTAssertEqual(copy.usage, 6)
        XCTAssertEqual(copy.modifiers, ["command"])
        let selectAll = try XCTUnwrap(SoftwareKeyboardChordPolicy.press(for: "a", modifiers: [.command]))
        XCTAssertEqual(selectAll.usage, 4)
        let palette = try XCTUnwrap(SoftwareKeyboardChordPolicy.press(for: "P", modifiers: [.command]))
        XCTAssertEqual(palette.usage, 19)
        XCTAssertEqual(palette.modifiers, ["command", "shift"], "an uppercase letter adds Shift")
        XCTAssertEqual(SoftwareKeyboardChordPolicy.press(for: "3", modifiers: [.command, .shift])?.usage, 32)
        XCTAssertNil(SoftwareKeyboardChordPolicy.press(for: "c", modifiers: []), "no chord: ordinary text")
        XCTAssertNil(SoftwareKeyboardChordPolicy.press(for: "cc", modifiers: [.command]))
        XCTAssertEqual(SoftwareKeyboardChordPolicy.modifiers(["shift"], chord: [.command]), ["command", "shift"])
    }

    // MARK: - Function Tray editing

    private func customItem(_ id: String = "u") -> ShortcutItem {
        ShortcutItem(id: id, title: "Underline", displayKey: "U", usage: 24, modifiers: ModifierChord([.control]))
    }

    func testFunctionTrayAddRemoveReorder() {
        var profile = FunctionTrayProfile.canonical()
        let count = profile.items.count
        XCTAssertTrue(profile.addCustomItem(customItem()))
        XCTAssertEqual(profile.items.count, count + 1)
        XCTAssertTrue(profile.visibleItems.contains { $0.id == "u" })
        XCTAssertFalse(profile.addCustomItem(customItem()), "ids stay unique")
        profile.moveItems(from: IndexSet(integer: profile.items.count - 1), to: 0)
        XCTAssertEqual(profile.items.first?.id, "u")
        profile.removeItem(id: "u")
        XCTAssertFalse(profile.items.contains { $0.id == "u" }, "custom actions are deleted")
        profile.removeItem(id: "undo")
        XCTAssertEqual(profile.items.first { $0.id == "undo" }?.isVisible, false, "built-ins are hidden")
        XCTAssertEqual(profile.resolvingCanonicalMetadata().items.first { $0.id == "undo" }?.isVisible, false)
        var invalid = customItem("bad")
        invalid.action = .keyboardShortcut(KeyboardShortcut(usage: 999, modifiers: ModifierChord()))
        XCTAssertFalse(profile.addCustomItem(invalid))
    }

    func testRenamesAndFacesPersistAndSurviveCanonicalRefresh() throws {
        var profile = FunctionTrayProfile.canonical()
        profile.rename(id: "undo", to: "Back")
        profile.setDisplay(id: "undo", .emoji("⏪"))
        profile.addCustomItem(customItem())
        profile.setDisplay(id: "u", .text("U̲"))
        profile.rename(id: "u", to: "Underline It")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(FunctionTrayProfile.self, from: data).resolvingCanonicalMetadata()
        let undo = try XCTUnwrap(decoded.allItems.first { $0.id == "undo" })
        XCTAssertEqual(undo.title, "Back")
        XCTAssertEqual(undo.face, .text("⏪"))
        XCTAssertEqual(undo.action, FunctionTrayProfile.canonical().items.first { $0.id == "undo" }?.item.action,
                       "the action is untouched by its label")
        let custom = try XCTUnwrap(decoded.allItems.first { $0.id == "u" })
        XCTAssertEqual(custom.title, "Underline It")
        XCTAssertEqual(custom.face, .text("U̲"))
        var keys = customItem()
        keys.display = .keys
        XCTAssertEqual(keys.face, .text("⌃U"))
        var symbol = customItem()
        symbol.display = .symbol("underline")
        XCTAssertEqual(symbol.face, .symbol("underline"))
        XCTAssertEqual(customItem().face, .text("U"), "default: the key cap")
    }

    // MARK: - Sequences

    private func sequenceAction() -> ControlAction {
        .sequence([
            ControlActionStep(action: .keyboardShortcut(KeyboardShortcut(usage: 14, modifiers: ModifierChord([.command]))),
                              delayMs: 200),
            ControlActionStep(action: .keyboardShortcut(KeyboardShortcut(usage: 14, modifiers: ModifierChord(),
                                                                         additionalUsages: [32])), delayMs: 100),
            ControlActionStep(action: .receiverGesture(ReceiverGesture.showDesktop.rawValue)),
        ])
    }

    func testSequencesRunInOrderWithBalancedKeys() {
        let operations = ControlActionPlan.operations(for: sequenceAction())
        XCTAssertEqual(operations, [
            .press(usage: 14, modifiers: ["command"]),
            .pause(milliseconds: 200),
            .key(KeyboardChordEvent(phase: .down, usage: 14, modifiers: [])),
            .key(KeyboardChordEvent(phase: .down, usage: 32, modifiers: [])),
            .key(KeyboardChordEvent(phase: .up, usage: 32, modifiers: [])),
            .key(KeyboardChordEvent(phase: .up, usage: 14, modifiers: [])),
            .pause(milliseconds: 100),
            .gesture("showDesktop"),
        ])
        var held = Set<Int>()
        for case .key(let event) in operations {
            if event.phase == .down { held.insert(event.usage) } else { held.remove(event.usage) }
        }
        XCTAssertTrue(held.isEmpty)
    }

    func testSequencesAreBounded() {
        let step = ControlActionStep(action: .receiverGesture("spotlight"))
        XCTAssertTrue(ControlAction.sequence([step]).isValid)
        XCTAssertFalse(ControlAction.sequence([]).isValid)
        XCTAssertFalse(ControlAction.sequence(Array(repeating: step, count: 9)).isValid)
        XCTAssertFalse(ControlAction.sequence([ControlActionStep(action: .sequence([step]))]).isValid, "no nesting")
        XCTAssertFalse(ControlAction.sequence([ControlActionStep(action: .receiverGesture("rm -rf"))]).isValid)
        XCTAssertFalse(ControlAction.sequence([ControlActionStep(action: .receiverGesture("spotlight"), delayMs: 9_000)]).isValid)
        XCTAssertEqual(ControlActionPlan.operations(for: .sequence([])), [], "invalid actions do nothing")
    }

    func testSequenceItemsRoundTrip() throws {
        var item = customItem("macro")
        item.action = sequenceAction()
        item.display = .emoji("🚀")
        XCTAssertEqual(try JSONDecoder().decode(ShortcutItem.self, from: JSONEncoder().encode(item)), item)
        XCTAssertEqual(item.keysDescription, "⌘K → K+3 → Underline")
    }

    // MARK: - Scroll direction

    func testScrollInversionIsPerAxis() {
        let natural = ScrollDirectionPolicy.apply(dx: 3, dy: -5, invertVertical: true, invertHorizontal: true)
        XCTAssertEqual(natural.dx, 3)
        XCTAssertEqual(natural.dy, -5)
        let vertical = ScrollDirectionPolicy.apply(dx: 0, dy: -5, invertVertical: false, invertHorizontal: true)
        XCTAssertEqual(vertical.dy, 5)
        let horizontal = ScrollDirectionPolicy.apply(dx: 3, dy: 0, invertVertical: true, invertHorizontal: false)
        XCTAssertEqual(horizontal.dx, -3)
        let diagonal = ScrollDirectionPolicy.apply(dx: 3, dy: -5, invertVertical: false, invertHorizontal: true)
        XCTAssertEqual(diagonal.dx, 3, "each axis follows only its own setting")
        XCTAssertEqual(diagonal.dy, 5)
        let both = ScrollDirectionPolicy.apply(dx: 3, dy: -5, invertVertical: false, invertHorizontal: false)
        XCTAssertEqual(both.dx, -3)
        XCTAssertEqual(both.dy, 5)
    }

    func testSchema18DefaultsAndMigration() throws {
        let preferences = ReceiverControlPreferences()
        XCTAssertTrue(preferences.invertVerticalScroll)
        XCTAssertTrue(preferences.invertHorizontalScroll)
        XCTAssertEqual(preferences.padOverlayPaletteStyle, .keys)
        let suite = "SecondQA.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReceiverControlPreferences()
        old.version = 17
        old.padShowControlHints = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["invertVerticalScroll", "invertHorizontalScroll", "padOverlayPaletteStyle"] { json.removeValue(forKey: key) }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var loaded = repository.load()
        XCTAssertEqual(loaded.version, 18)
        XCTAssertTrue(loaded.padShowControlHints, "a schema-17 choice survives")
        XCTAssertTrue(loaded.invertVerticalScroll)
        loaded.invertHorizontalScroll = false
        repository.save(loaded)
        XCTAssertFalse(repository.load().invertHorizontalScroll)
    }

    // MARK: - Custom system controls and editor

    func testTemplatePlacesTheSystemGroupOnTheOppositeSide() {
        for corner in ControlCorner.allCases {
            let arrangement = CustomControlArrangement.radialTemplate(corner: corner, portrait: false)
            let system = arrangement.placements.filter { CustomControlArrangement.templateSystem.contains($0.kind) }
            XCTAssertEqual(system.map(\.kind), CustomControlArrangement.templateSystem)
            for placement in system {
                XCTAssertEqual(placement.x < 0.5, !corner.isLeading, "\(corner): opposite side")
                XCTAssertEqual(placement.y < 0.5, corner.isTop)
            }
        }
    }

    func testTwoHandAssistStaysDormantWhileEditing() {
        var interaction = ControlInteractionState()
        interaction.press(.command)
        _ = interaction.toggleAssistModifier(.option)
        XCTAssertEqual(EditorTwoHandPresentation.state(previewing: false, showingAssistPreview: false, enabled: true,
                                                       interaction: interaction), .hidden)
        XCTAssertEqual(EditorTwoHandPresentation.state(previewing: false, showingAssistPreview: true, enabled: true,
                                                       interaction: ControlInteractionState()), .helper(active: [.command]))
        XCTAssertEqual(EditorTwoHandPresentation.state(previewing: true, showingAssistPreview: false, enabled: true,
                                                       interaction: interaction), .helper(active: [.command, .option]))
        XCTAssertEqual(EditorTwoHandPresentation.state(previewing: true, showingAssistPreview: true, enabled: false,
                                                       interaction: interaction), .hidden)
    }

    func testSnapToEdgesAndSnapToGuidesAreSeparate() {
        let area = CGRect(x: 12, y: 36, width: 1170, height: 766)
        let nearLeft = CGPoint(x: area.minX + 22 + 8, y: area.minY + 300)
        let edge = CustomLayoutGeometry.droppedPosition(for: nearLeft, in: area, diameter: 44,
                                                        snapToEdges: true, snapToGuides: false)
        XCTAssertEqual(edge.x, Double(22 / area.width), accuracy: 0.0001, "flush against the edge")
        let free = CustomLayoutGeometry.droppedPosition(for: nearLeft, in: area, diameter: 44,
                                                        snapToEdges: false, snapToGuides: false)
        XCTAssertEqual(free.x, Double(30 / area.width), accuracy: 0.0001)
        let nearCenter = CGPoint(x: area.midX + 7, y: area.minY + area.height * 0.2503)
        let centered = CustomLayoutGeometry.droppedPosition(for: nearCenter, in: area, diameter: 44,
                                                            snapToEdges: true, snapToGuides: true)
        XCTAssertEqual(centered.x, 0.5, accuracy: 0.0001, "center line")
        XCTAssertEqual(centered.y, 0.25, accuracy: 0.0001, "guide line")
    }

    // MARK: - Wheel

    func testWheelDividesARingIntoEqualWedgesAroundTheModifier() throws {
        let anchor = CGRect(x: 580, y: 380, width: 44, height: 44)
        let wheel = try XCTUnwrap(WheelPaletteGeometry.layout(count: 6, anchor: anchor, keyDiameter: 40, spacing: 8,
                                                              bounds: container))
        XCTAssertEqual(wheel.center, CGPoint(x: anchor.midX, y: anchor.midY))
        XCTAssertGreaterThanOrEqual(wheel.innerRadius, 22 + 8)
        XCTAssertEqual(wheel.segments.count, 6)
        let total = wheel.segments.map { $0.endAngle - $0.startAngle }.reduce(0, +)
        XCTAssertEqual(total, 2 * .pi, accuracy: 0.0001)
        for (index, segment) in wheel.segments.enumerated() {
            XCTAssertEqual(segment.endAngle - segment.startAngle, .pi / 3, accuracy: 0.0001)
            XCTAssertEqual(hypot(segment.labelPoint.x - wheel.center.x, segment.labelPoint.y - wheel.center.y),
                           (wheel.innerRadius + wheel.outerRadius) / 2, accuracy: 0.001)
            XCTAssertEqual(wheel.segmentIndex(at: segment.labelPoint), index)
        }
        XCTAssertEqual(wheel.segments[0].labelPoint.x, wheel.center.x, accuracy: 0.001, "first segment on top")
        XCTAssertNil(wheel.segmentIndex(at: wheel.center), "the center is the anchor, not an action")
    }

    func testWheelMovesInwardToStayOnScreenAndWidensForManyActions() throws {
        let corner = CGRect(x: 1150, y: 790, width: 44, height: 44)
        let wheel = try XCTUnwrap(WheelPaletteGeometry.layout(count: 8, anchor: corner, keyDiameter: 40, spacing: 8,
                                                              bounds: container))
        XCTAssertTrue(container.contains(wheel.frame))
        let crowded = try XCTUnwrap(WheelPaletteGeometry.layout(count: 16, anchor: CGRect(x: 580, y: 380, width: 44, height: 44),
                                                                keyDiameter: 40, spacing: 8, bounds: container))
        let middle = (crowded.innerRadius + crowded.outerRadius) / 2
        XCTAssertGreaterThanOrEqual(2 * .pi * middle / 16, 40 * 1.15 - 0.01, "more than a key's width per wedge")
        XCTAssertGreaterThanOrEqual(crowded.outerRadius - crowded.innerRadius, 40 * 1.5 - 0.01, "deep enough to hit")
    }

    // MARK: - Arc fan in every corner

    func testArcFansIntoFreeSpaceFromEveryCornerAndMovedAnchor() {
        let bounds = CGRect(x: 12, y: 36, width: 1170, height: 766)
        let anchors: [CGPoint] = [CGPoint(x: 60, y: 80), CGPoint(x: 1140, y: 80), CGPoint(x: 60, y: 760),
                                  CGPoint(x: 1140, y: 760), CGPoint(x: 597, y: 760), CGPoint(x: 60, y: 420),
                                  CGPoint(x: 597, y: 419)]
        for anchor in anchors {
            let toward = RadialPaletteLayout.direction(from: anchor, toward: CGPoint(x: bounds.midX, y: bounds.midY))
            let points = RadialPaletteLayout.points(count: 6, center: anchor, shape: .arc, itemDiameter: 40, spacing: 8,
                                                    minimumRadius: 110, direction: toward, bounds: bounds)
            XCTAssertEqual(points.count, 6, "\(anchor)")
            let radii = points.map { hypot($0.x - anchor.x, $0.y - anchor.y) }
            for radius in radii { XCTAssertEqual(radius, radii[0], accuracy: 0.01, "\(anchor): one arc") }
            let angles = points.map { atan2($0.y - anchor.y, $0.x - anchor.x) }
            let steps = zip(angles, angles.dropFirst()).map { ManualViewportState.normalizedAngle($1 - $0) }
            for step in steps { XCTAssertEqual(step, steps[0], accuracy: 0.001, "\(anchor): even spacing") }
            let inner = bounds.insetBy(dx: 20, dy: 20)
            for point in points { XCTAssertTrue(inner.contains(point), "\(anchor): on screen \(point)") }
            // It opens toward the room available, not into a corner.
            let mean = CGPoint(x: points.map(\.x).reduce(0, +) / 6 - anchor.x,
                               y: points.map(\.y).reduce(0, +) / 6 - anchor.y)
            XCTAssertGreaterThan(mean.x * cos(toward) + mean.y * sin(toward), 0, "\(anchor)")
        }
    }

    func testCornerClusterFollowsWhereTheAnchorActuallyIs() {
        // Stored as bottom-right, but arranged top-left.
        var arrangement = CustomControlArrangement.radialTemplate(corner: .topLeading, portrait: false)
        arrangement.corner = .bottomTrailing
        let area = CGRect(origin: .zero, size: CustomControlArrangement.referenceLandscape)
        let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: 44)
        XCTAssertEqual(CornerCluster.resolve(arrangement: arrangement, frames: frames, area: area)?.corner, .topLeading)
    }

    // MARK: - Import

    func testImportFlowOnlyFinishesAfterASuccessfulImport() throws {
        var preferences = ReceiverControlPreferences()
        preferences.createCustomLayout(id: "a")
        let code = try CustomLayoutShareCode.encode(preferences.customLayouts[0])
        var flow = CustomLayoutImportFlow()
        flow.validate()
        XCTAssertEqual(flow.stage, .entering)
        flow.paste("garbage")
        XCTAssertEqual(flow.stage, .failed(.notAShareCode))
        XCTAssertFalse(flow.isFinished)
        flow.paste(code)
        guard case .reviewing = flow.stage else { return XCTFail("expected a summary") }
        XCTAssertFalse(flow.isFinished, "reviewing never closes the screen")
        flow.importLayout(into: &preferences)
        XCTAssertTrue(flow.isFinished)
        XCTAssertEqual(preferences.customLayouts.count, 2)
        var full = preferences
        while full.canCreateCustomLayout { full.createCustomLayout() }
        var second = CustomLayoutImportFlow()
        second.paste(code)
        second.importLayout(into: &full)
        guard case .limitReached = second.stage else { return XCTFail("expected the limit") }
        XCTAssertFalse(second.isFinished)
        second.edit("")
        XCTAssertEqual(second.stage, .entering)
    }

    func testSharedLayoutsCarryTheirCustomActions() throws {
        var layout = CustomControlLayout.radialTemplate(name: "Macro", corner: .bottomTrailing)
        layout.landscape.placements.append(CustomControlPlacement(id: "m", kind: .function("my-macro"), x: 0.5, y: 0.5))
        layout.landscape.placements.append(CustomControlPlacement(id: "z", kind: .function("zoom-in"), x: 0.4, y: 0.5))
        layout.assistActionIDs = ["undo", "my-macro"]
        var macro = customItem("my-macro")
        macro.action = sequenceAction()
        macro.display = .emoji("🚀")
        let unrelated = customItem("unused")
        let code = try CustomLayoutShareCode.encode(layout, functionItems: [macro, unrelated])
        let summary = try CustomLayoutShareCode.decode(code).get()
        let placements = summary.layout.landscape.placements
        let adopted = try XCTUnwrap(placements.first { $0.id == "m" })
        guard case .shortcut(let item) = adopted.kind else { return XCTFail("the macro travels as a one-tap button") }
        XCTAssertEqual(item.action, macro.action)
        XCTAssertEqual(item.display, .emoji("🚀"))
        XCTAssertNotEqual(item.id, "my-macro", "a new local definition")
        XCTAssertEqual(placements.first { $0.id == "z" }?.kind, .function("zoom-in"), "built-ins travel by id")
        XCTAssertEqual(summary.layout.assistActionIDs, ["undo"])
        XCTAssertFalse(code.isEmpty)
        // Only what the layout uses.
        let body = code.dropFirst(5).split(separator: ".")[0]
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let json = try (XCTUnwrap(Data(base64Encoded: base64)) as NSData).decompressed(using: .zlib) as Data
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("unused"))
    }

    // MARK: - Request Input

    func testBlockedTouchOffersRequestInputThenFades() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertEqual(prompt.blockedAttempt(now: 0, userTurnedOff: false, autoRequest: false), [])
        XCTAssertEqual(prompt.kind, .requestInput)
        XCTAssertTrue(prompt.isVisible(at: 1))
        _ = prompt.blockedAttempt(now: 3, userTurnedOff: false, autoRequest: false)
        XCTAssertTrue(prompt.isVisible(at: 6), "another attempt refreshes the timer")
        prompt.tick(now: 7)
        XCTAssertNil(prompt.kind, "it fades once attempts stop")
        _ = prompt.blockedAttempt(now: 10, userTurnedOff: true, autoRequest: false)
        XCTAssertEqual(prompt.kind, .enableInput)
    }

    func testRequestIsSentOnceAndTheGrantShowsBriefly() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        _ = prompt.blockedAttempt(now: 0, userTurnedOff: false, autoRequest: false)
        XCTAssertEqual(prompt.requestTapped(now: 0.5), [.sendRequest])
        XCTAssertEqual(prompt.kind, .requesting)
        XCTAssertEqual(prompt.requestTapped(now: 0.7), [], "no duplicate requests")
        prompt.inputStateChanged(.requesting, now: 0.8)
        XCTAssertEqual(prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: true), [], "already pending")
        XCTAssertEqual(prompt.kind, .requesting)
        prompt.inputStateChanged(.allowed, now: 2)
        XCTAssertEqual(prompt.kind, .enabled)
        prompt.tick(now: 2 + ReceiverInputPrompt.enabledDuration + 0.01)
        XCTAssertNil(prompt.kind)
        XCTAssertEqual(prompt.blockedAttempt(now: 5, userTurnedOff: false, autoRequest: true), [], "input works now")
    }

    func testAlwaysAllowPeersRequestAutomaticallyButRateLimited() {
        var prompt = ReceiverInputPrompt()
        prompt.setSessionLive(true)
        XCTAssertEqual(prompt.blockedAttempt(now: 0, userTurnedOff: false, autoRequest: true), [.sendRequest])
        prompt.inputStateChanged(.off, now: 0.2)
        XCTAssertEqual(prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: true), [], "rate-limited")
        XCTAssertEqual(prompt.blockedAttempt(now: 10, userTurnedOff: false, autoRequest: true), [.sendRequest])
        prompt.inputStateChanged(.notAllowed, now: 11)
        XCTAssertEqual(prompt.blockedAttempt(now: 30, userTurnedOff: false, autoRequest: true), [],
                       "a declined request is never re-sent automatically")
        XCTAssertEqual(prompt.blockedAttempt(now: 40, userTurnedOff: true, autoRequest: true), [],
                       "input the user turned off stays off until they ask")
    }

    func testNoPromptWithoutALiveSessionOrWhenTheMacDisablesRequests() {
        var prompt = ReceiverInputPrompt()
        XCTAssertEqual(prompt.blockedAttempt(now: 0, userTurnedOff: false, autoRequest: true), [])
        XCTAssertNil(prompt.kind)
        prompt.setSessionLive(true)
        prompt.inputStateChanged(.requestsDisabled, now: 0)
        _ = prompt.blockedAttempt(now: 1, userTurnedOff: false, autoRequest: true)
        XCTAssertEqual(prompt.kind, .unavailable)
        XCTAssertEqual(prompt.requestTapped(now: 2), [])
    }

    func testLocalViewGesturesNeverAskForInput() {
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 2, moveViewActive: false),
                       "two fingers are local pan/zoom/rotate")
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: true))
        XCTAssertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 1, moveViewActive: false))
        XCTAssertTrue(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 3, moveViewActive: false))
        XCTAssertFalse(BlockedInputAttemptPolicy.isRemoteIntent(maximumTouchCount: 0, moveViewActive: false))
    }
}
