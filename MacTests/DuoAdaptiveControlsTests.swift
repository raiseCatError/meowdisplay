import CoreGraphics
import XCTest

/// iPhone Duo and other foldable windows: the one roomy rule, first-run
/// defaults on a roomy window, the Settings presentation latch, the
/// compact/roomy reachability table, and roomy layouts that keep clear of a
/// fold. All pure policy, no UIKit.
final class DuoAdaptiveControlsTests: XCTestCase {
    // MARK: - One roomy rule

    func testRoomyOnlyWhenRegularInBothDirections() {
        XCTAssertTrue(ReceiverLayoutClass.isRoomy(horizontalRegular: true, verticalRegular: true))
        XCTAssertFalse(ReceiverLayoutClass.isRoomy(horizontalRegular: true, verticalRegular: false),
                       "a landscape Plus/Max phone is regular wide but compact tall")
        XCTAssertFalse(ReceiverLayoutClass.isRoomy(horizontalRegular: false, verticalRegular: true))
        XCTAssertFalse(ReceiverLayoutClass.isRoomy(horizontalRegular: false, verticalRegular: false))
    }

    func testLayoutClassStateStartedCompactBecomesRoomyOnARoomyWindow() {
        // Demo Mode's own control store starts from the device idiom (compact on
        // an iPhone) and must follow the window exactly like the live store.
        var demo = ReceiverLayoutClassState(startsRoomy: false)
        var live = ReceiverLayoutClassState(startsRoomy: false)
        let demoChange = demo.update(horizontalRegular: true, verticalRegular: true, hasSavedPreferences: true)
        let liveChange = live.update(horizontalRegular: true, verticalRegular: true, hasSavedPreferences: true)
        XCTAssertTrue(demo.isRoomy)
        XCTAssertTrue(demoChange.roomyChanged)
        XCTAssertEqual(demoChange, liveChange)
        let folded = demo.update(horizontalRegular: false, verticalRegular: true, hasSavedPreferences: true)
        XCTAssertFalse(demo.isRoomy)
        XCTAssertTrue(folded.roomyChanged)
        let same = demo.update(horizontalRegular: false, verticalRegular: false, hasSavedPreferences: true)
        XCTAssertFalse(same.roomyChanged, "no change, no relayout")
    }

    // MARK: - Settings presentation latch

    func testSettingsPresentationFollowsTheWindowWhileClosed() {
        XCTAssertEqual(SettingsPresentationStyle.style(roomy: true), .fullScreen)
        XCTAssertEqual(SettingsPresentationStyle.style(roomy: false), .sheet)
        XCTAssertEqual(SettingsPresentationStyle.resolved(latched: nil, roomyNow: true), .fullScreen)
        XCTAssertEqual(SettingsPresentationStyle.resolved(latched: nil, roomyNow: false), .sheet)
    }

    func testSettingsPresentationIsDecidedOnceWhenItOpens() {
        // Opened folded, then the device unfolds while Settings is open.
        let openedCompact = SettingsPresentationStyle.style(roomy: false)
        XCTAssertEqual(SettingsPresentationStyle.resolved(latched: openedCompact, roomyNow: true), .sheet,
                       "the sheet stays a sheet: nothing is dismissed and nothing else presented")
        // Opened unfolded, then folded.
        let openedRoomy = SettingsPresentationStyle.style(roomy: true)
        XCTAssertEqual(SettingsPresentationStyle.resolved(latched: openedRoomy, roomyNow: false), .fullScreen)
    }

    // MARK: - First run on a roomy window

    private func makeRepository() throws -> (ReceiverControlPreferencesRepository, UserDefaults, String) {
        let suite = "DuoAdaptiveControlsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ReceiverControlPreferencesRepository(defaults: defaults), defaults, suite)
    }

    func testFirstRoomyWindowWithNothingSavedAdoptsTheIPadDefaultsOnce() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(repository.hasSavedPreferences)
        var state = ReceiverLayoutClassState(startsRoomy: false)
        let first = state.update(horizontalRegular: true, verticalRegular: true,
                                 hasSavedPreferences: repository.hasSavedPreferences)
        let adopted = try XCTUnwrap(first.adoptedPreferences)
        XCTAssertEqual(adopted.inputMode, .direct)
        XCTAssertEqual(adopted.padControlLayout, .custom)
        XCTAssertNotNil(adopted.activeCustomLayout)
        // Fold, unfold: the defaults are never applied again.
        _ = state.update(horizontalRegular: false, verticalRegular: false, hasSavedPreferences: false)
        let unfolded = state.update(horizontalRegular: true, verticalRegular: true, hasSavedPreferences: false)
        XCTAssertNil(unfolded.adoptedPreferences)
    }

    func testSavedPreferencesAreNeverReplacedByRoomyDefaults() throws {
        let (repository, defaults, suite) = try makeRepository()
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = ReceiverControlPreferences()
        saved.inputMode = .trackpad
        repository.save(saved)
        XCTAssertTrue(repository.hasSavedPreferences)
        var state = ReceiverLayoutClassState(startsRoomy: false)
        let change = state.update(horizontalRegular: true, verticalRegular: true,
                                  hasSavedPreferences: repository.hasSavedPreferences)
        XCTAssertNil(change.adoptedPreferences)
        XCTAssertEqual(repository.load().inputMode, .trackpad)
    }

    func testRoomyDefaultsOnlyApplyToTheFirstWindowThatStartedCompact() {
        // First seen compact: a later unfold keeps the phone defaults.
        var compactFirst = ReceiverLayoutClassState(startsRoomy: false)
        XCTAssertNil(compactFirst.update(horizontalRegular: false, verticalRegular: true,
                                         hasSavedPreferences: false).adoptedPreferences)
        XCTAssertNil(compactFirst.update(horizontalRegular: true, verticalRegular: true,
                                         hasSavedPreferences: false).adoptedPreferences)
        // An iPad already starts roomy with the iPad defaults: nothing to adopt.
        var pad = ReceiverLayoutClassState(startsRoomy: true)
        XCTAssertNil(pad.update(horizontalRegular: true, verticalRegular: true,
                                hasSavedPreferences: false).adoptedPreferences)
    }

    // MARK: - Reachability

    func testEveryRoomyStandardControlHasACompactCounterpartOrADocumentedException() {
        let functionTray = FunctionTrayProfile.canonical()
        var exceptions: [PadStandardControl] = []
        for control in PadStandardControl.allCases {
            switch control.compactCounterpart {
            case .trayItem(let item):
                XCTAssertEqual(control.kind, .tray(item), "\(control)")
            case .functionTrayAction(let id):
                XCTAssertEqual(control.kind, .function(id), "\(control)")
                let configuration = functionTray.items.first { $0.id == id }
                XCTAssertNotNil(configuration, "\(control) is a built-in Function Tray action")
                XCTAssertEqual(configuration?.isVisible, false, "opt-in in the Function Tray editor, not on by default")
            case .arrowKeysButton:
                XCTAssertEqual(control, .arrowKeys)
            case .documentedException(let reason):
                XCTAssertFalse(reason.isEmpty, "\(control) needs a documented reason")
                exceptions.append(control)
            }
        }
        XCTAssertEqual(exceptions, [.moveView], "the reviewed exceptions, and no others")
    }

    func testEveryCompactTrayItemHasARoomyCounterpart() {
        for item in ControlTrayItem.allCases {
            switch item.roomyCounterpart {
            case .standardControl(let control):
                XCTAssertEqual(control.kind, .tray(item), "\(item)")
            case .profileModifier:
                XCTAssertNotNil(item.modifier, "\(item)")
            case .permanentSettings:
                XCTAssertEqual(item, .settings)
            }
        }
    }

    func testTheRoomyRailCarriesEveryStandardControlWhenAllAreAvailable() {
        let groups = PadRailComposition.mainGroups(
            visibility: PadStandardControlVisibility(),
            availability: .init(modifiers: ControlModifier.allCases, keyboardAvailable: true,
                                moveViewAvailable: true, arrowKeysAvailable: true))
        let kinds = Set(groups.joined())
        for control in PadStandardControl.allCases {
            XCTAssertTrue(kinds.contains(control.kind), "\(control) is on the roomy rail")
        }
    }

    // MARK: - Roomy arrow keys

    func testArrowKeysSitAfterKeyboardInTheKeysGroupWhenAvailable() throws {
        let available = PadRailComposition.Availability(modifiers: ControlModifier.allCases, keyboardAvailable: true,
                                                        moveViewAvailable: true, arrowKeysAvailable: true)
        let groups = PadRailComposition.mainGroups(visibility: PadStandardControlVisibility(), availability: available)
        XCTAssertEqual(Array(groups[1].suffix(2)), [CustomControlKind.tray(.keyboard), .arrowKeys])
        var hidden = PadStandardControlVisibility()
        hidden.setVisible(false, .arrowKeys)
        XCTAssertFalse(PadRailComposition.mainGroups(visibility: hidden, availability: available)
            .joined().contains(.arrowKeys))
        var off = available
        off.arrowKeysAvailable = false
        XCTAssertFalse(PadRailComposition.mainGroups(visibility: PadStandardControlVisibility(), availability: off)
            .joined().contains(.arrowKeys), "Show Arrow Keys off, or no input: no control")
        XCTAssertEqual(PadStandardControl.arrowKeys.kind, .arrowKeys)
        XCTAssertFalse(CustomControlKind.arrowKeys.isOneTapAction, "its own tap handling, like Move View")
    }

    func testArrowKeysPlacementRoundTripsAndOlderBuildsDropOnlyIt() throws {
        let placement = CustomControlPlacement(kind: .arrowKeys, x: 0.4, y: 0.6)
        let decoded = try JSONDecoder().decode(CustomControlPlacement.self, from: JSONEncoder().encode(placement))
        XCTAssertEqual(decoded, placement)
        let mixed = Data(#"[{"kind":"arrowKeys"},{"kind":"tray","value":"escape"},{"kind":"hologram"}]"#.utf8)
        let kinds = try JSONDecoder().decode(LossyDecodableArray<CustomControlKind>.self, from: mixed).elements
        XCTAssertEqual(kinds, [.arrowKeys, .tray(.escape)])
    }

    func testShowArrowKeysIsOfferedInBothLayouts() {
        for isPad in [false, true] {
            for layout in PadControlLayoutMode.allCases {
                XCTAssertTrue(PadControlSettingsVisibility(isPad: isPad, layout: layout).showsArrowKeys)
            }
            let ids = MobileSettingsSearchIndex.items(isPad: isPad, debug: false).map(\.id)
            XCTAssertTrue(ids.contains("arrowKeys"), "isPad=\(isPad)")
            XCTAssertEqual(ids.contains("trayPlacement"), !isPad, "Landscape Tray Side is compact only")
            XCTAssertEqual(ids.contains("controlLayout"), isPad, "Control Layout is roomy only")
        }
    }

    func testRoomyKeypadOpensBesideItsControlAndClearsAFold() {
        let bounds = CGRect(x: 12, y: 12, width: 645, height: 847)
        let key: CGFloat = 42
        let gap: CGFloat = 4
        let plain = PadEdgeGeometry.arrowKeypadLayout(
            anchor: CGRect(x: 600, y: 420, width: 44, height: 44), edge: .trailing, bounds: bounds, key: key, gap: gap)
        let keypad = plain.keypad ?? .null
        XCTAssertTrue(bounds.contains(keypad))
        XCTAssertTrue(bounds.contains(plain.modifiers ?? .null))
        XCTAssertFalse(keypad.intersects(plain.toggle), "beside the control, never over it")
        XCTAssertEqual(keypad.size, ArrowKeypadGeometry.size(key: key, gap: gap))

        let fold = CGRect(x: 314.5, y: 0, width: 40, height: 871)
        let split = PadEdgeGeometry.arrowKeypadLayout(
            anchor: CGRect(x: 420, y: 420, width: 44, height: 44), edge: .trailing, bounds: bounds, key: key, gap: gap,
            divisions: [fold])
        XCTAssertFalse(fold.intersects(split.keypad ?? .null), "the keypad is never cut by the crease")
        XCTAssertFalse(fold.intersects(split.modifiers ?? .null))
    }

    // MARK: - Folds

    private struct Fold {
        let name: String
        let frames: [CGRect]
    }

    /// Duo-like unfolded windows, in points.
    private let duoSizes: [CGSize] = [CGSize(width: 669, height: 871), CGSize(width: 871, height: 669)]

    private func safeInsets(for size: CGSize) -> ControlSafeInsets {
        size.width > size.height
            ? ControlSafeInsets(top: 20, leading: 0, bottom: 20, trailing: 48)
            : ControlSafeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    }

    private func folds(in size: CGSize) -> [Fold] {
        [Fold(name: "vertical", frames: [CGRect(x: size.width / 2 - 20, y: 0, width: 40, height: size.height)]),
         Fold(name: "horizontal", frames: [CGRect(x: 0, y: size.height / 2 - 20, width: size.width, height: 40)])]
    }

    func testStripAndOverlayControlsNeverTouchAFoldAndStayInTheSafeArea() {
        let metrics = PadControlMetrics()
        for size in duoSizes {
            let container = CGRect(origin: .zero, size: size)
            let safe = safeInsets(for: size)
            let safeRect = safe.safeRect(in: size).insetBy(dx: -0.01, dy: -0.01)
            for fold in folds(in: size) {
                for strip in [true, false] {
                    for mainEdge in ControlEdge.allCases {
                        for functionEdge in ControlEdge.allCases {
                            let label = "\(size) \(fold.name) strip=\(strip) main=\(mainEdge) function=\(functionEdge)"
                            let layout = PadEdgeGeometry.layout(
                                container: container, safeInsets: safe, reservesStrips: strip,
                                mainEdge: mainEdge, functionEdge: functionEdge,
                                mainGroupCounts: [4, 8, 2],
                                mainGroupAlignments: [.start, .center, .end],
                                functionGroupCounts: [2, 2], metrics: metrics, divisions: fold.frames)
                            let cells = layout.mainCells + layout.functionCells
                            XCTAssertEqual(cells.count, 18, "\(label): nothing is lost to the fold")
                            for cell in cells {
                                for division in fold.frames {
                                    XCTAssertFalse(division.intersects(cell), "\(label): \(cell) crosses the fold")
                                }
                                XCTAssertTrue(safeRect.contains(cell), "\(label): \(cell) leaves the safe area")
                            }
                            for i in cells.indices {
                                for j in cells.indices where j > i {
                                    XCTAssertFalse(cells[i].intersects(cells[j]), "\(label): \(i) overlaps \(j)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testRailsWithoutAFoldAreUnchanged() {
        let size = duoSizes[0]
        let container = CGRect(origin: .zero, size: size)
        func layout(_ divisions: [CGRect]) -> PadEdgeLayout {
            PadEdgeGeometry.layout(container: container, safeInsets: safeInsets(for: size), reservesStrips: false,
                                   mainEdge: .top, functionEdge: .top, mainGroupCounts: [4, 8, 2],
                                   functionGroupCounts: [2, 2], metrics: PadControlMetrics(), divisions: divisions)
        }
        XCTAssertEqual(layout([]), layout([CGRect(x: 0, y: 0, width: 0, height: 0)]))
        // A fold nowhere near the rail changes nothing either.
        XCTAssertEqual(layout([]), layout([CGRect(x: 0, y: 400, width: 669, height: 40)]),
                       "a horizontal fold does not cross a top rail")
    }

    func testCustomControlsNeverStraddleAFold() {
        for size in duoSizes {
            let container = CGRect(origin: .zero, size: size)
            let safe = safeInsets(for: size)
            let area = CustomLayoutGeometry.layoutArea(container: container, safeInsets: safe)
            let safeRect = safe.safeRect(in: size).insetBy(dx: -0.01, dy: -0.01)
            for fold in folds(in: size) {
                for portrait in [false, true] {
                    var arrangement = CustomControlArrangement.radialTemplate(corner: .bottomTrailing, portrait: portrait)
                    // Controls placed right on the crease, either way it runs.
                    let onTheCrease: [(CustomControlKind, Double, Double)] = [
                        (.arrowKeys, 0.5, 0.5), (.moveView, 0.5, 0.2), (.tray(.dock), 0.5, 0.8),
                        (.tray(.tab), 0.2, 0.5), (.tray(.escape), 0.8, 0.5),
                    ]
                    for (kind, x, y) in onTheCrease {
                        arrangement.placements.append(CustomControlPlacement(kind: kind, x: x, y: y))
                    }
                    let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: 44,
                                                             divisions: fold.frames)
                    XCTAssertEqual(frames.count, arrangement.placements.count)
                    for (id, frame) in frames {
                        for division in fold.frames {
                            XCTAssertFalse(division.intersects(frame), "\(size) \(fold.name) \(id): \(frame)")
                        }
                        XCTAssertTrue(area.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(size) \(fold.name) \(id)")
                        XCTAssertTrue(safeRect.contains(frame), "\(size) \(fold.name) \(id) in the safe area")
                    }
                }
            }
        }
    }

    func testCustomFramesWithoutAFoldAreExactlyTheStoredPlacements() {
        let size = duoSizes[1]
        let area = CustomLayoutGeometry.layoutArea(container: CGRect(origin: .zero, size: size),
                                                   safeInsets: safeInsets(for: size))
        let arrangement = CustomControlArrangement.radialTemplate(corner: .topLeading, portrait: false)
        XCTAssertEqual(CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: 44),
                       CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: 44, divisions: []))
    }

    func testCanvasPublicationIsResolvedAfterASizeChange() {
        let portrait = duoSizes[0]
        let landscape = duoSizes[1]
        let publication = PadCanvasPublication(canvas: CGRect(x: 0, y: 0, width: 600, height: 871),
                                               containerSize: portrait)
        XCTAssertEqual(PadCanvasPublication.resolved(publication, in: portrait),
                       CGRect(x: 0, y: 0, width: 600, height: 871))
        XCTAssertEqual(PadCanvasPublication.resolved(publication, in: landscape),
                       CGRect(origin: .zero, size: landscape),
                       "a fold or rotation uses the whole new container until the layout republishes")
        XCTAssertEqual(PadCanvasPublication.resolved(nil, in: landscape), CGRect(origin: .zero, size: landscape))
    }
}
