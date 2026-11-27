import CoreGraphics
import XCTest

/// Where the local calculator appears, when, and how it stays compatible
/// with saved settings, layouts and share codes from builds before it.
final class LocalCalculatorPlacementTests: XCTestCase {

    // MARK: Policy

    func testTheButtonIgnoresInputGrantsAndFollowsOnlyItsOwnChoices() {
        XCTAssertFalse(LocalCalculatorPolicy.showsButton(added: false, trayCollapsed: false, keyboardBarShown: false),
                       "not shown until added")
        XCTAssertTrue(LocalCalculatorPolicy.showsButton(added: true, trayCollapsed: false, keyboardBarShown: false))
        XCTAssertFalse(LocalCalculatorPolicy.showsButton(added: true, trayCollapsed: true, keyboardBarShown: false),
                       "a tray collapsed to Settings takes it along")
        XCTAssertFalse(LocalCalculatorPolicy.showsButton(added: true, trayCollapsed: false, keyboardBarShown: true))
        XCTAssertTrue(LocalCalculatorPolicy.showsPanel(open: true, keyboardBarShown: false))
        XCTAssertFalse(LocalCalculatorPolicy.showsPanel(open: true, keyboardBarShown: true))
        XCTAssertFalse(LocalCalculatorPolicy.showsPanel(open: false, keyboardBarShown: false))
    }

    // MARK: Panel size

    func testThePanelFitsASmallIPhoneInBothOrientationsWithFullSizeKeys() {
        // iPhone SE: 375 × 667, no insets once the status bar is hidden.
        let landscape = LocalCalculatorPanelMetrics.fitting(CGSize(width: 667 - 24, height: 375 - 24), preferredKey: 54)
        XCTAssertGreaterThanOrEqual(landscape.key, 44, "44 pt touch targets")
        XCTAssertLessThanOrEqual(landscape.size.height, 375 - 24)
        let portrait = LocalCalculatorPanelMetrics.fitting(CGSize(width: 375 - 24, height: 667 - 24), preferredKey: 54)
        XCTAssertEqual(portrait.key, 54)
        XCTAssertLessThanOrEqual(portrait.size.width, 375 - 24)
    }

    func testKeysGrowWithDynamicTypeOnlyAsFarAsTheSpaceAllows() {
        let roomy = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(LocalCalculatorPanelMetrics.fitting(roomy, preferredKey: 70).key, 70)
        XCTAssertEqual(LocalCalculatorPanelMetrics.fitting(roomy, preferredKey: 200).key, LocalCalculatorPanelMetrics.maximumKey)
        XCTAssertEqual(LocalCalculatorPanelMetrics.fitting(CGSize(width: 100, height: 100), preferredKey: 54).key,
                       LocalCalculatorPanelMetrics.minimumKey, "never smaller than the minimum")
    }

    // MARK: iPhone button

    private struct Phone {
        let container: CGRect
        let safe: ControlSafeInsets
        let portrait: Bool
        let notchSide: LandscapeTraySide?
        let main: CGRect
        let function: [CGRect]

        /// The real tray geometry for a default iPhone 15-sized screen: Main
        /// Tray trailing, Function Tray on the opposite side, Zoom / Edit /
        /// Return groups.
        init(portrait: Bool, mainSide: LandscapeTraySide = .trailing, position: FunctionTrayPosition = .oppositeSide) {
            let size = portrait ? CGSize(width: 393, height: 852) : CGSize(width: 852, height: 393)
            container = CGRect(origin: .zero, size: size)
            safe = portrait ? ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
                : ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
            self.portrait = portrait
            notchSide = portrait ? nil : .leading
            let tray = portrait ? CGSize(width: 369, height: 41) : CGSize(width: 41, height: 369)
            let layout = ControlTrayGeometry.layout(container: container, safeInsets: safe, keyboardVisibleRect: nil,
                                                    portrait: portrait, side: mainSide, traySize: tray,
                                                    paletteSize: .zero, avoidNotch: true, notchSide: notchSide)
            main = layout.trayFrame
            let groups = [2, 2, 1].map { count -> CGSize in
                let length = CGFloat(count) * 40 + CGFloat(count - 1) * 4 + 4
                return portrait ? CGSize(width: length, height: 44) : CGSize(width: 44, height: length)
            }
            function = ControlTrayGeometry.functionTrayLayout(
                container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: portrait,
                mainSide: layout.side, position: position, mainTrayFrame: main, groupSizes: groups,
                avoiding: nil, avoidNotch: true, notchSide: notchSide, bottomRow: true)
        }

        func button(occupied: [CGRect]? = nil, reserved: [ControlReservedRegion] = [], keyboard: CGRect? = nil) -> CGRect {
            LocalCalculatorPlacement.phoneButtonFrame(container: container, safeInsets: safe, keyboardVisibleRect: keyboard,
                                                      portrait: portrait, diameter: 40,
                                                      occupied: occupied ?? ([main] + function), avoidNotch: true,
                                                      notchSide: notchSide, reservedRegions: reserved)
        }
    }

    private func assertClear(_ frame: CGRect, of others: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for other in others {
            XCTAssertFalse(frame.insetBy(dx: -9, dy: -9).intersects(other), "\(frame) touches \(other)", file: file, line: line)
        }
    }

    func testPortraitButtonSitsInTheUpperLeftCornerBesideTheDynamicIsland() {
        let phone = Phone(portrait: true)
        let button = phone.button()
        XCTAssertEqual(button, CGRect(x: 12, y: 12, width: 40, height: 40))
        let island = ControlTrayGeometry.unsafeRegions(in: phone.container, safeInsets: phone.safe, portrait: true)
        assertClear(button, of: [phone.main] + phone.function)
        XCTAssertFalse(island.contains { $0.intersects(button) }, "clear of the Dynamic Island band")
    }

    func testLandscapeButtonStaysTopLeftBesideTheFunctionTraysCornerGroup() {
        let phone = Phone(portrait: false)
        let button = phone.button()
        XCTAssertEqual(button.minY, 12, "on the top edge")
        XCTAssertLessThan(button.maxX, phone.container.midX, "in the left half")
        XCTAssertGreaterThan(button.minX, phone.function[0].maxX, "past the Zoom group, which doesn't move")
        assertClear(button, of: [phone.main] + phone.function)
    }

    func testLandscapeWithTheMainTrayOnTheLeftStillFindsTheUpperLeft() {
        let phone = Phone(portrait: false, mainSide: .leading)
        let button = phone.button()
        XCTAssertEqual(button.minY, 12)
        XCTAssertLessThan(button.maxX, phone.container.midX)
        assertClear(button, of: [phone.main] + phone.function)
    }

    func testTheButtonKeepsOffReservedRegions() {
        let phone = Phone(portrait: true)
        let camera = ControlReservedRegion(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 70, height: 70))
        let button = phone.button(reserved: [camera])
        XCTAssertFalse(button.intersects(camera.frame))
        XCTAssertLessThan(button.minY, 200, "still near the top")
        let hinge = ControlReservedRegion(kind: .division, frame: CGRect(x: 0, y: 0, width: 393, height: 80))
        XCTAssertFalse(phone.button(reserved: [hinge]).intersects(hinge.frame))
    }

    func testTheButtonStaysAboveTheKeyboard() {
        let phone = Phone(portrait: true)
        let keyboard = CGRect(x: 0, y: 0, width: 393, height: 500)
        XCTAssertTrue(keyboard.contains(phone.button(keyboard: keyboard)))
    }

    func testTheOtherControlsNeverMoveForIt() {
        // The calculator is placed from their frames; their geometry takes no
        // calculator input at all, so adding it can't shift them.
        let before = Phone(portrait: false)
        _ = before.button()
        let after = Phone(portrait: false)
        XCTAssertEqual(before.main, after.main)
        XCTAssertEqual(before.function, after.function)
    }

    // MARK: Panel

    func testThePanelOpensBelowTheButtonInPortraitAndBesideItInLandscape() {
        let size = CGSize(width: 250, height: 400)
        let tall = CGRect(x: 12, y: 71, width: 369, height: 735)
        let fromTop = LocalCalculatorPlacement.panelFrame(button: CGRect(x: 12, y: 12, width: 40, height: 40),
                                                          size: size, bounds: tall)
        XCTAssertEqual(fromTop.origin, CGPoint(x: 12, y: 71), "below, inside the safe area")
        let wide = CGRect(x: 71, y: 12, width: 710, height: 348)
        let small = CGSize(width: 214, height: 340)
        let beside = LocalCalculatorPlacement.panelFrame(button: CGRect(x: 66, y: 12, width: 40, height: 40),
                                                         size: small, bounds: wide)
        XCTAssertEqual(beside.minX, 116, "to the right of the button")
        XCTAssertTrue(wide.contains(beside))
    }

    func testThePanelNeverCoversItsButtonAndOpensTowardTheMiddle() {
        let bounds = CGRect(x: 12, y: 12, width: 1000, height: 700)
        let size = CGSize(width: 300, height: 450)
        for button in [CGRect(x: 12, y: 12, width: 44, height: 44), CGRect(x: 956, y: 12, width: 44, height: 44),
                       CGRect(x: 12, y: 656, width: 44, height: 44), CGRect(x: 956, y: 656, width: 44, height: 44),
                       CGRect(x: 500, y: 300, width: 44, height: 44)] {
            let panel = LocalCalculatorPlacement.panelFrame(button: button, size: size, bounds: bounds)
            XCTAssertTrue(bounds.contains(panel), "\(button)")
            XCTAssertFalse(panel.intersects(button), "\(button)")
        }
    }

    func testThePanelStepsAroundOtherControlsWhenItCan() {
        let bounds = CGRect(x: 71, y: 12, width: 710, height: 348)
        let returnKey = CGRect(x: 70, y: 337, width: 44, height: 44)
        let panel = LocalCalculatorPlacement.panelFrame(button: CGRect(x: 66, y: 12, width: 40, height: 40),
                                                        size: CGSize(width: 214, height: 346), bounds: bounds,
                                                        obstacles: [returnKey])
        XCTAssertFalse(panel.intersects(returnKey))
        XCTAssertTrue(bounds.contains(panel))
    }

    // MARK: Custom layouts

    func testANewCalculatorLandsInTheFreeUpperLeftOfACustomLayout() {
        for portrait in [false, true] {
            let template = CustomControlLayout.radialTemplate(name: "T").arrangement(portrait: portrait)
            let spot = template.suggestedCalculatorPosition(portrait: portrait)
            XCTAssertLessThan(spot.x, 0.2, "left")
            XCTAssertLessThan(spot.y, 0.1, "top")
        }
        var crowded = CustomControlArrangement(corner: .topLeading, placements: [])
        let first = crowded.suggestedCalculatorPosition(portrait: false)
        crowded.placements.append(CustomControlPlacement(kind: .tray(.escape), x: first.x, y: first.y))
        let next = crowded.suggestedCalculatorPosition(portrait: false)
        XCTAssertEqual(next.y, first.y)
        XCTAssertGreaterThan(next.x, first.x, "the next free spot along the top")
    }

    // MARK: Defaults and compatibility

    func testTheCalculatorButtonIsShownByDefault() {
        XCTAssertTrue(ReceiverControlPreferences().showsCalculatorButton)
        XCTAssertTrue(ReceiverControlPreferences.initial(isPad: false).showsCalculatorButton)
        XCTAssertTrue(ReceiverControlPreferences.initial(isPad: true).showsCalculatorButton)
        for slot in ControlProfileSlot.allCases {
            XCTAssertFalse(FunctionTrayProfile.canonical(slot: slot).items.contains { $0.id.contains("calc") },
                           "not a Function Tray action, so no profile ever carries it")
        }
        for portrait in [false, true] {
            XCTAssertFalse(CustomControlLayout.radialTemplate(name: "T").arrangement(portrait: portrait)
                .placements.contains { $0.kind == .calculator }, "templates don't place it")
        }
    }

    func testSettingsSavedBeforeTheCalculatorLoadUnchanged() throws {
        var older = ReceiverControlPreferences.initial(isPad: true)
        older.trayEnabled = false
        older.createCustomLayout()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
        object["showsCalculatorButton"] = nil
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalCalculatorPlacementTests-\(UUID().uuidString)"))
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let loaded = ReceiverControlPreferencesRepository(defaults: defaults).load(initial: .initial(isPad: true))
        XCTAssertTrue(loaded.showsCalculatorButton, "on by default since 2.2")
        XCTAssertFalse(loaded.trayEnabled)
        XCTAssertEqual(loaded.customLayouts, older.customLayouts, "saved layouts are neither reset nor given a calculator")
    }

    func testTurningTheButtonOnNeverTouchesProfilesOrLayouts() throws {
        var preferences = ReceiverControlPreferences.initial(isPad: true)
        preferences.showsCalculatorButton = false
        preferences.createCustomLayout()
        var shown = preferences
        shown.showsCalculatorButton = true
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as? [String: Any])
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), [], "the key is always written")
        let changed = after.keys.filter { !NSDictionary(dictionary: [$0: after[$0]!]).isEqual(to: [$0: before[$0]!]) }
        XCTAssertEqual(changed, ["showsCalculatorButton"],
                       "an older build reads everything it knows exactly as before, plus one key it ignores")
        let decoded = try JSONDecoder().decode(ReceiverControlPreferences.self, from: JSONEncoder().encode(shown))
        XCTAssertTrue(decoded.showsCalculatorButton)
        XCTAssertEqual(decoded, shown)
    }

    func testSettingsSavedWhileTheCalculatorWasOffByDefaultShowItOnce() throws {
        var older = ReceiverControlPreferences.initial(isPad: false)
        older.showsCalculatorButton = false
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
        object["calculatorDefaultRevision"] = nil
        let migrated = try JSONDecoder().decode(ReceiverControlPreferences.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(migrated.showsCalculatorButton, "turned on once")
        var removed = migrated
        removed.showsCalculatorButton = false
        let again = try JSONDecoder().decode(ReceiverControlPreferences.self, from: JSONEncoder().encode(removed))
        XCTAssertFalse(again.showsCalculatorButton, "a later choice to remove it is kept")
    }

    func testADowngradeAndSaveLosesOnlyTheButtonChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalCalculatorPlacementTests-\(UUID().uuidString)"))
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = ReceiverControlPreferences.initial(isPad: false)
        preferences.showsCalculatorButton = false
        preferences.hapticsEnabled = false
        repository.save(preferences)
        // An older build (same schema) re-saves what it knows: everything
        // but the calculator key.
        var older = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(defaults.data(forKey: ReceiverControlPreferencesRepository.defaultsKey))) as? [String: Any])
        older["showsCalculatorButton"] = nil
        let olderSave = ReceiverControlPreferencesRepository.keepingNewerFields(
            try JSONSerialization.data(withJSONObject: older),
            over: defaults.data(forKey: ReceiverControlPreferencesRepository.defaultsKey))
        defaults.set(olderSave, forKey: ReceiverControlPreferencesRepository.defaultsKey)
        let back = repository.load(initial: .initial(isPad: false))
        XCTAssertTrue(back.showsCalculatorButton, "back to the default: shown")
        var expected = preferences
        expected.showsCalculatorButton = true
        XCTAssertEqual(back, expected, "nothing else changed")
    }

    func testTheCalculatorPlacementRoundTrips() throws {
        let kind = CustomControlKind.calculator
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(kind), encoding: .utf8))
        XCTAssertEqual(json, #"{"kind":"calculator"}"#)
        XCTAssertEqual(try JSONDecoder().decode(CustomControlKind.self, from: Data(json.utf8)), .calculator)
        XCTAssertTrue(kind.isOneTapAction, "a tap toggles it; it never joins the chord gesture")
        XCTAssertNil(kind.modifier)
        XCTAssertEqual(kind.stableID, "calculator")
    }

    func testThisBuildStillDropsOnlyUnknownControls() throws {
        let json = #"{"corner":"topLeading","placements":[{"id":"a","kind":{"kind":"calculator"},"x":0.1,"y":0.1,"size":1},{"id":"b","kind":{"kind":"hologram"},"x":0.2,"y":0.2,"size":1},{"id":"c","kind":{"kind":"tray","value":"command"},"x":0.3,"y":0.3,"size":1,"palette":{"shape":"arc","spacing":1}}]}"#
        let arrangement = try JSONDecoder().decode(CustomControlArrangement.self, from: Data(json.utf8))
        XCTAssertEqual(arrangement.placements.map(\.id), ["a", "c"])
    }

    // MARK: An older build reading the calculator

    /// `CustomControlKind`'s decoder as every build before the calculator
    /// shipped it (origin/dev 32c89c56): four kinds, anything else throws.
    private enum LegacyKind: Decodable, Equatable {
        case tray(ControlTrayItem), function(String), moveView, shortcut(ShortcutItem)

        private enum CodingKeys: String, CodingKey { case kind, value, shortcut }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "tray":
                let raw = try container.decode(String.self, forKey: .value)
                guard let item = ControlTrayItem(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Unknown tray item")
                }
                self = .tray(item)
            case "function": self = .function(try container.decode(String.self, forKey: .value))
            case "moveView": self = .moveView
            case "shortcut":
                let item = try container.decode(ShortcutItem.self, forKey: .shortcut)
                guard case .keyboardShortcut(let shortcut) = item.action, shortcut.isValid else {
                    throw DecodingError.dataCorruptedError(forKey: .shortcut, in: container, debugDescription: "Invalid")
                }
                self = .shortcut(item)
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown control kind")
            }
        }
    }

    private struct LegacyPlacement: Decodable {
        var id: String
        var kind: LegacyKind
        var x: Double
        var y: Double
        var size: Double
        var palette: PalettePresentation?
    }

    /// The older arrangement: placements decode lossily (unchanged here).
    private struct LegacyArrangement: Decodable {
        var corner: ControlCorner
        var placements: [LegacyPlacement]

        private enum CodingKeys: String, CodingKey { case corner, placements }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corner = try container.decodeIfPresent(ControlCorner.self, forKey: .corner) ?? .bottomTrailing
            placements = (try container.decodeIfPresent(LossyDecodableArray<LegacyPlacement>.self,
                                                        forKey: .placements))?.elements ?? []
        }
    }

    private struct LegacyLayout: Decodable {
        var id: String
        var name: String
        var landscape: LegacyArrangement
        var portrait: LegacyArrangement
        var twoHandAssist: Bool
        var assistActionIDs: [String]
        var functionProfile: ControlProfileSlot?
    }

    private func layoutWithACalculator() -> CustomControlLayout {
        var layout = CustomControlLayout.radialTemplate(name: "With Calculator")
        for portrait in [false, true] {
            var arrangement = layout.arrangement(portrait: portrait)
            let spot = arrangement.suggestedCalculatorPosition(portrait: portrait)
            arrangement.placements.insert(CustomControlPlacement(id: "calc", kind: .calculator, x: spot.x, y: spot.y), at: 3)
            layout.setArrangement(arrangement, portrait: portrait)
        }
        return layout
    }

    func testAnOlderBuildReadsALayoutWithACalculatorAndKeepsEverythingElse() throws {
        let layout = layoutWithACalculator()
        let data = try JSONEncoder().encode(layout)
        let legacy = try JSONDecoder().decode(LegacyLayout.self, from: data)
        XCTAssertEqual(legacy.id, layout.id)
        XCTAssertEqual(legacy.name, layout.name)
        XCTAssertEqual(legacy.twoHandAssist, layout.twoHandAssist)
        XCTAssertEqual(legacy.assistActionIDs, layout.assistActionIDs)
        for portrait in [false, true] {
            let current = layout.arrangement(portrait: portrait).placements.filter { $0.kind != .calculator }
            let old = portrait ? legacy.portrait : legacy.landscape
            XCTAssertEqual(old.placements.map(\.id), current.map(\.id), "only the calculator is dropped, in order")
            XCTAssertEqual(old.placements.map(\.x), current.map(\.x))
            XCTAssertEqual(old.placements.map(\.y), current.map(\.y))
            XCTAssertEqual(old.placements.map(\.size), current.map(\.size))
        }
    }

    func testAnOlderBuildReadsSavedSettingsWithACalculatorLayout() throws {
        var preferences = ReceiverControlPreferences.initial(isPad: true)
        preferences.showsCalculatorButton = true
        preferences.customLayouts = [layoutWithACalculator(), CustomControlLayout.radialTemplate(name: "Plain")]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        let layouts = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["customLayouts"]))
        let legacy = try JSONDecoder().decode(LossyDecodableArray<LegacyLayout>.self, from: layouts).elements
        XCTAssertEqual(legacy.map(\.name), ["With Calculator", "Plain"], "no layout is lost")
        XCTAssertEqual(legacy[1].landscape.placements.count,
                       preferences.customLayouts[1].landscape.placements.count)
    }

    func testShareCodesCarryTheCalculatorAndOlderBuildsSkipJustIt() throws {
        let layout = layoutWithACalculator()
        let code = try CustomLayoutShareCode.encode(layout)
        guard case .success(let summary) = CustomLayoutShareCode.decode(code) else { return XCTFail("decodes") }
        XCTAssertEqual(summary.warnings, [], "this build knows it")
        XCTAssertTrue(summary.layout.landscape.placements.contains { $0.kind == .calculator })
        XCTAssertEqual(summary.landscapeControls, layout.landscape.placements.count)

        // The payload an older build decodes: same JSON, its own kinds.
        let body = String(code.dropFirst("MDL1-".count).split(separator: ".")[0])
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let json = try (XCTUnwrap(Data(base64Encoded: base64)) as NSData).decompressed(using: .zlib) as Data
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let landscape = try JSONDecoder().decode(LegacyArrangement.self,
                                                 from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["landscape"])))
        let raw = try XCTUnwrap((object["landscape"] as? [String: Any])?["placements"] as? [Any]).count
        XCTAssertEqual(landscape.placements.count, raw - 1, "the older import keeps every other control")
        XCTAssertEqual(raw - landscape.placements.count, 1, "and reports one skipped control")
    }
    // MARK: Round 4 (owner QA): beside the trays, not in the top lane

    func testTheButtonSitsBesideTheMainTrayInPortrait() {
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        let safe = ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let tray = CGRect(x: 100, y: 760, width: 190, height: 44)
        let function = CGRect(x: 120, y: 700, width: 150, height: 44)
        let frame = LocalCalculatorPlacement.phoneButtonFrame(
            container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: true, diameter: 44,
            occupied: [tray, function], avoidNotch: true, tray: tray, trayHorizontal: true, beside: [function])
        XCTAssertEqual(frame, CGRect(x: 300, y: 760, width: 44, height: 44), "at the tray's end, in its row")
        XCTAssertFalse(frame.intersects(tray.insetBy(dx: -9, dy: -9)))
    }

    func testTheButtonStaysLowBesideALandscapeColumn() {
        let container = CGRect(x: 0, y: 0, width: 852, height: 393)
        let safe = ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let tray = CGRect(x: 736, y: 30, width: 44, height: 320)
        let frame = LocalCalculatorPlacement.phoneButtonFrame(
            container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: false, diameter: 44,
            occupied: [tray], avoidNotch: true, tray: tray, trayHorizontal: false)
        XCTAssertGreaterThan(frame.minY, container.midY, "never up in the top lane")
        XCTAssertFalse(frame.intersects(tray))
        XCTAssertLessThan(abs(frame.maxY - tray.maxY), 1, "beside the column's bottom end")
    }

    func testWithoutRoomByTheTraysItFallsBackToTheUpperLeft() {
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        let tray = CGRect(x: 12, y: 760, width: 369, height: 80)
        let above = CGRect(x: 12, y: 600, width: 369, height: 150)
        let frame = LocalCalculatorPlacement.phoneButtonFrame(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: true, diameter: 44,
            occupied: [tray, above], avoidNotch: false, tray: tray, trayHorizontal: true)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 12))
    }

    // MARK: Round 4 (owner QA): stashing at an edge like a floating window

    private let stashBounds = CGRect(x: 12, y: 60, width: 369, height: 740)

    func testAFlickTowardASideEdgeStashesIt() {
        let frame = CGRect(x: 150, y: 200, width: 200, height: 300)
        let stash = LocalCalculatorStashGeometry.release(frame, velocity: CGVector(dx: 2_400, dy: 0), bounds: stashBounds)
        XCTAssertEqual(stash?.edge, .right)
        XCTAssertNil(LocalCalculatorStashGeometry.release(frame, velocity: CGVector(dx: 300, dy: 0), bounds: stashBounds),
                     "a slow move stays inside")
        XCTAssertNil(LocalCalculatorStashGeometry.release(frame, velocity: CGVector(dx: 0, dy: 3_000), bounds: stashBounds),
                     "never the top or bottom edge")
    }

    func testPulledMoreThanHalfPastAnEdgeStashesIt() {
        let dragged = LocalCalculatorStashGeometry.dragged(CGRect(x: -200, y: 300, width: 200, height: 300), bounds: stashBounds)
        XCTAssertEqual(dragged.maxX, stashBounds.minX + LocalCalculatorStashGeometry.strip, "its strip stays inside")
        XCTAssertEqual(LocalCalculatorStashGeometry.release(dragged, velocity: .zero, bounds: stashBounds)?.edge, .left)
        let topped = LocalCalculatorStashGeometry.dragged(CGRect(x: 100, y: -500, width: 200, height: 300), bounds: stashBounds)
        XCTAssertEqual(topped.minY, stashBounds.minY, "never past the top")
    }

    func testAStashedWindowShowsAStripAndComesBackFlush() {
        let stash = LocalCalculatorStash(edge: .right, offset: 0.5)
        let waiting = LocalCalculatorStashGeometry.waiting(size: CGSize(width: 200, height: 300), stash: stash, bounds: stashBounds)
        XCTAssertEqual(waiting.strip.width, LocalCalculatorStashGeometry.strip)
        XCTAssertEqual(waiting.strip.maxX, stashBounds.maxX)
        XCTAssertEqual(waiting.window.minX, stashBounds.maxX - LocalCalculatorStashGeometry.strip)
        XCTAssertEqual(waiting.window.midY, stashBounds.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(LocalCalculatorStashGeometry.touchArea(waiting.strip, edge: .right).width, 44)
        let back = LocalCalculatorStashGeometry.restored(CGRect(x: 40, y: 100, width: 200, height: 300), stash: stash,
                                                         bounds: stashBounds)
        XCTAssertEqual(back.maxX, stashBounds.maxX, "flush with the edge it waited at")
        XCTAssertEqual(back.size, CGSize(width: 200, height: 300), "its own size")
        XCTAssertTrue(stashBounds.contains(back))
    }

    func testATapOrAPullBringsItBack() {
        XCTAssertTrue(LocalCalculatorStashGeometry.pullRestores(inward: 0, projected: 0, travel: 2), "a tap")
        XCTAssertTrue(LocalCalculatorStashGeometry.pullRestores(inward: 40, projected: 40, travel: 40))
        XCTAssertFalse(LocalCalculatorStashGeometry.pullRestores(inward: -30, projected: -60, travel: 30), "pushed back in")
        XCTAssertFalse(LocalCalculatorStashGeometry.pullRestores(inward: 2, projected: 4, travel: 30), "slid along the edge")
    }
    // Codex round 8.
    func testTheStripKeepsOffControlsOnItsEdge() {
        let stash = LocalCalculatorStash(edge: .right, offset: 0.5)
        let rail = CGRect(x: stashBounds.maxX - 50, y: stashBounds.midY - 200, width: 60, height: 400)
        let waiting = LocalCalculatorStashGeometry.waiting(size: CGSize(width: 200, height: 300), stash: stash,
                                                           bounds: stashBounds, obstacles: [rail])
        let touch = try? XCTUnwrap(waiting.touch)
        XCTAssertNotNil(touch)
        XCTAssertFalse(touch.map { $0.intersects(rail) } ?? true, "a tap on the rail never lands on the strip")
        XCTAssertLessThanOrEqual(waiting.strip.height, LocalCalculatorStashGeometry.maximumStripLength)
        XCTAssertTrue(waiting.window.minY <= waiting.strip.minY && waiting.strip.maxY <= waiting.window.maxY,
                      "the strip is part of the window")
        let full = CGRect(x: stashBounds.maxX - 50, y: stashBounds.minY, width: 60, height: stashBounds.height)
        XCTAssertNil(LocalCalculatorStashGeometry.waiting(size: CGSize(width: 200, height: 300), stash: stash,
                                                          bounds: stashBounds, obstacles: [full]).touch,
                     "no clear place: only the calculator button brings it back")
    }

    // Codex round 9: the strip finds a free gap between controls, nearest where it was let go.
    func testTheStripFindsTheGapNearestWhereItWasLetGo() {
        let stash = LocalCalculatorStash(edge: .right, offset: 0.5) // wanted centre y 430
        let size = CGSize(width: 200, height: 300)
        func controls(gapBottom: CGFloat) -> [CGRect] {
            [CGRect(x: stashBounds.maxX - 50, y: stashBounds.minY, width: 60, height: 334 - stashBounds.minY),
             CGRect(x: stashBounds.maxX - 50, y: gapBottom, width: 60, height: stashBounds.maxY - gapBottom)]
        }
        let roomy = LocalCalculatorStashGeometry.waiting(size: size, stash: stash, bounds: stashBounds,
                                                         obstacles: controls(gapBottom: 456))
        XCTAssertEqual(roomy.strip.midY, 396, "as close to 430 as the 120 pt strip fits in 334–456")
        XCTAssertEqual(roomy.strip.height, LocalCalculatorStashGeometry.maximumStripLength)
        XCTAssertNotNil(roomy.touch)
        let tight = LocalCalculatorStashGeometry.waiting(size: size, stash: stash, bounds: stashBounds,
                                                         obstacles: controls(gapBottom: 400))
        XCTAssertEqual(tight.strip.height, LocalCalculatorStashGeometry.touchDepth, "a short strip where a long one can't fit")
        XCTAssertEqual(tight.strip.midY, 378)
        XCTAssertFalse(tight.touch.map { area in controls(gapBottom: 400).contains { $0.intersects(area) } } ?? true)
    }

    // Codex round 10: both trays hidden, only the gear (its 50 pt drawn footprint) shows.
    func testWithBothTraysHiddenItSitsBesideTheGear() {
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        let safe = ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let gear = CGRect(x: 171.5, y: 852 - 34 - 12 - 50, width: 50, height: 50)
        for arrowSide in [LandscapeTraySide.leading, .trailing, nil] {
            let frame = LocalCalculatorPlacement.phoneButtonFrame(
                container: container, safeInsets: safe, keyboardVisibleRect: nil, portrait: true, diameter: 44,
                occupied: [gear], avoidNotch: false, tray: gear, trayHorizontal: true, beside: [], arrowSide: arrowSide)
            XCTAssertFalse(frame.intersects(gear), "\(String(describing: arrowSide))")
            XCTAssertLessThan(abs(frame.midY - gear.midY), 60, "beside the gear, not the top lane: \(frame)")
        }
    }

    func testWithoutAMainTrayItSitsBesideAFunctionGroup() {
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        let function = CGRect(x: 120, y: 760, width: 150, height: 44)
        let frame = LocalCalculatorPlacement.phoneButtonFrame(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: true, diameter: 44,
            occupied: [function], avoidNotch: false, tray: nil, trayHorizontal: true, beside: [function])
        XCTAssertEqual(frame, CGRect(x: 280, y: 760, width: 44, height: 44))
    }
}
