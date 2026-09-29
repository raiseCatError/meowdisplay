import CoreGraphics
import XCTest

/// Concentric radial layouts, mirrored Two-Hand Assist, one-tap keyboard
/// chords, share codes, the editor Preview, Settings search, and the Local
/// View Navigation / Allow Input split.
final class CustomLayoutRefinementTests: XCTestCase {
    private let base: CGFloat = 44

    private func referenceArea(portrait: Bool) -> CGRect {
        CGRect(origin: .zero, size: portrait ? CustomControlArrangement.referencePortrait
                                             : CustomControlArrangement.referenceLandscape)
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Unwrapped angles of `points` around `origin`, relative to the
    /// corner's horizontal edge, in sweep order (0...π/2).
    private func sweepOffsets(_ points: [CGPoint], origin: CGPoint, corner: ControlCorner) -> [CGFloat] {
        let start = CornerArcGeometry.horizontalEdgeAngle(corner)
        let sign: CGFloat = CornerArcGeometry.sweep(corner) > 0 ? 1 : -1
        return points.map { point in
            ManualViewportState.normalizedAngle((atan2(point.y - origin.y, point.x - origin.x) - start) * sign)
        }
    }

    // MARK: - Concentric radial template

    func testTemplateIsSettingsThenUtilitiesThenModifiersOnConcentricArcs() throws {
        for corner in ControlCorner.allCases {
            for portrait in [false, true] {
                let label = "\(corner) portrait=\(portrait)"
                let arrangement = CustomControlArrangement.radialTemplate(corner: corner, portrait: portrait)
                let area = referenceArea(portrait: portrait)
                let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
                let origin = center(try XCTUnwrap(frames["settings"]))
                let utilities = CustomControlArrangement.templateUtilities.map { center(frames[$0.stableID]!) }
                let modifiers = CustomControlArrangement.templateModifiers.map { center(frames[$0.rawValue]!) }
                let utilityRadii = utilities.map { distance($0, origin) }
                let modifierRadii = modifiers.map { distance($0, origin) }
                // Every layer is one true arc: a single radius.
                for radius in utilityRadii { XCTAssertEqual(radius, utilityRadii[0], accuracy: 0.5, label) }
                for radius in modifierRadii { XCTAssertEqual(radius, modifierRadii[0], accuracy: 0.5, label) }
                // Settings → utilities → modifiers, each layer clear of the last.
                XCTAssertGreaterThanOrEqual(utilityRadii[0], base * 0.9 + 8 - 0.5, label)
                XCTAssertGreaterThanOrEqual(modifierRadii[0] - utilityRadii[0],
                                            base * 0.45 + base / 2 + 8 - 0.5, label)
                // Even angular distribution, in order along the sweep.
                for points in [utilities, modifiers] {
                    let offsets = sweepOffsets(points, origin: origin, corner: corner)
                    let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
                    for step in steps {
                        XCTAssertGreaterThan(step, 0, "\(label) ordered")
                        XCTAssertEqual(step, steps[0], accuracy: 0.01, "\(label) evenly spaced")
                    }
                    for offset in offsets {
                        XCTAssertGreaterThanOrEqual(offset, -0.001, label)
                        XCTAssertLessThanOrEqual(offset, .pi / 2 + 0.001, label)
                    }
                }
            }
        }
    }

    func testArcAnglesSweepFromEachCornersHorizontalEdgeTowardItsVerticalEdge() {
        let expected: [ControlCorner: (start: CGFloat, end: CGFloat)] = [
            .topLeading: (0, .pi / 2), .topTrailing: (.pi, .pi / 2),
            .bottomLeading: (0, -.pi / 2), .bottomTrailing: (.pi, 1.5 * .pi),
        ]
        for corner in ControlCorner.allCases {
            let angles = CornerArcGeometry.angles(count: 3, radius: 200, corner: corner, diameter: 10,
                                                  edgeDistances: CGSize(width: 100, height: 100))
            let (start, end) = expected[corner]!
            XCTAssertEqual(angles[0], start, accuracy: 0.001, "\(corner)")
            XCTAssertEqual(angles[1], (start + end) / 2, accuracy: 0.001, "\(corner)")
            XCTAssertEqual(angles[2], end, accuracy: 0.001, "\(corner)")
        }
    }

    func testArcsStayClearOfTheCornerEdges() {
        let edges = CGSize(width: 20, height: 30)
        for corner in ControlCorner.allCases {
            let origin = CGPoint(x: 500, y: 500)
            let points = CornerArcGeometry.points(count: 5, radius: 120, origin: origin, corner: corner,
                                                  diameter: 44, edgeDistances: edges)
            for point in points {
                // Distance to the vertical and horizontal edge lines.
                XCTAssertGreaterThanOrEqual(abs(point.x - origin.x) + edges.width, 22 - 0.01, "\(corner)")
                XCTAssertGreaterThanOrEqual(abs(point.y - origin.y) + edges.height, 22 - 0.01, "\(corner)")
            }
        }
    }

    // MARK: - Palette on the next arc

    func testPaletteBloomsOnTheArcDirectlyOutsideTheModifiers() throws {
        for corner in ControlCorner.allCases {
            let arrangement = CustomControlArrangement.radialTemplate(corner: corner, portrait: false)
            let area = referenceArea(portrait: false)
            let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
            let origin = center(try XCTUnwrap(frames["settings"]))
            let modifierRadius = distance(center(frames["command"]!), origin)
            let keyDiameter = CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: base)
            let points = CustomLayoutGeometry.palettePoints(count: 5, anchorID: "command", arrangement: arrangement,
                                                            frames: frames, area: area, baseDiameter: base, spacing: 8)
            XCTAssertEqual(points.count, 5)
            let expected = modifierRadius + base / 2 + keyDiameter / 2 + 8
            for point in points {
                XCTAssertEqual(distance(point, origin), expected, accuracy: 0.5, "\(corner): attached to the modifiers")
            }
            let offsets = sweepOffsets(points, origin: origin, corner: corner)
            let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
            for step in steps { XCTAssertEqual(step, steps[0], accuracy: 0.01, "\(corner) evenly spaced") }
            for point in points {
                for frame in frames.values {
                    XCTAssertGreaterThanOrEqual(distance(point, center(frame)), frame.width / 2 + keyDiameter / 2 - 0.5)
                }
            }
        }
    }

    func testLargePalettesContinueOnTheNextArcOut() throws {
        let arrangement = CustomControlArrangement.radialTemplate(corner: .bottomTrailing, portrait: false)
        let area = referenceArea(portrait: false)
        let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
        let origin = center(try XCTUnwrap(frames["settings"]))
        let points = CustomLayoutGeometry.palettePoints(count: 14, anchorID: "option", arrangement: arrangement,
                                                        frames: frames, area: area, baseDiameter: base, spacing: 8)
        let radii = Set(points.map { Int(distance($0, origin).rounded()) })
        XCTAssertGreaterThan(radii.count, 1)
        for i in points.indices {
            for j in points.indices where j > i {
                XCTAssertGreaterThanOrEqual(distance(points[i], points[j]),
                                            CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: base) - 0.5)
            }
        }
    }

    func testAModifierMovedAwayFromTheCornerBloomsAroundItself() throws {
        var arrangement = CustomControlArrangement.radialTemplate(corner: .bottomTrailing, portrait: false)
        let index = try XCTUnwrap(arrangement.placements.firstIndex { $0.id == "command" })
        arrangement.placements[index].x = 0.4
        arrangement.placements[index].y = 0.4
        let area = referenceArea(portrait: false)
        let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
        XCTAssertNil(CornerCluster.resolve(arrangement: arrangement, frames: frames, area: area))
        let anchor = center(frames["command"]!)
        let points = CustomLayoutGeometry.palettePoints(count: 4, anchorID: "command", arrangement: arrangement,
                                                        frames: frames, area: area, baseDiameter: base, spacing: 8)
        for point in points { XCTAssertLessThan(distance(point, anchor), 200) }
    }

    // MARK: - Two-Hand Assist

    func testHelperModifiersAreTheModifierArcMirrored() throws {
        for corner in ControlCorner.allCases {
            for portrait in [false, true] {
                let arrangement = CustomControlArrangement.radialTemplate(corner: corner, portrait: portrait)
                let area = referenceArea(portrait: portrait)
                let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
                let helpers = TwoHandAssist.helperPoints(count: 4, arrangement: arrangement, frames: frames,
                                                         area: area, itemDiameter: base, spacing: 8)
                let mirroredModifiers = CustomControlArrangement.templateModifiers.map { item -> CGPoint in
                    let point = center(frames[item.rawValue]!)
                    return CGPoint(x: area.minX + area.maxX - point.x, y: point.y)
                }
                XCTAssertEqual(helpers.count, 4)
                for (helper, expected) in zip(helpers, mirroredModifiers) {
                    XCTAssertEqual(helper.x, expected.x, accuracy: 0.5, "\(corner) portrait=\(portrait)")
                    XCTAssertEqual(helper.y, expected.y, accuracy: 0.5, "\(corner) portrait=\(portrait)")
                }
                // A real arc around the mirrored anchor.
                let settings = center(frames["settings"]!)
                let mirroredOrigin = CGPoint(x: area.minX + area.maxX - settings.x, y: settings.y)
                let radii = helpers.map { distance($0, mirroredOrigin) }
                for radius in radii { XCTAssertEqual(radius, radii[0], accuracy: 0.5) }
                let offsets = sweepOffsets(helpers, origin: mirroredOrigin,
                                           corner: CornerArcGeometry.mirroredHorizontally(corner))
                let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
                for step in steps { XCTAssertEqual(step, steps[0], accuracy: 0.01) }
            }
        }
    }

    func testMoreIdleActionsWidenTheMirroredArcInsteadOfCrowdingIt() {
        let arrangement = CustomControlArrangement.radialTemplate(corner: .bottomTrailing, portrait: true)
        let area = referenceArea(portrait: true)
        let frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base)
        let points = TwoHandAssist.helperPoints(count: 7, arrangement: arrangement, frames: frames, area: area,
                                                itemDiameter: base, spacing: 8)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(distance(a, b), base + 8 - 0.5)
        }
        for point in points { XCTAssertLessThan(point.x, area.midX) }
    }

    // MARK: - One-tap keyboard shortcuts

    func testChordPlanPressesThenReleasesEveryKeyInReverse() {
        let shortcut = KeyboardShortcut(usage: 14, modifiers: ModifierChord([.shift, .command]), additionalUsages: [32])
        let events = KeyboardChordPlan.events(for: shortcut)
        XCTAssertEqual(events.map(\.phase), [.down, .down, .up, .up])
        XCTAssertEqual(events.map(\.usage), [14, 32, 32, 14])
        XCTAssertTrue(events.allSatisfy { $0.modifiers == ["command", "shift"] })
        var held = Set<Int>()
        for event in events {
            if event.phase == .down { XCTAssertTrue(held.insert(event.usage).inserted) }
            else { XCTAssertNotNil(held.remove(event.usage)) }
        }
        XCTAssertTrue(held.isEmpty, "no key is left held")
    }

    func testKeyboardShortcutCodableStaysBackwardCompatible() throws {
        let plain = KeyboardShortcut(usage: 24, modifiers: ModifierChord([.control]))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("additionalUsages"), "ordinary shortcuts encode exactly as before")
        let legacy = try JSONDecoder().decode(KeyboardShortcut.self,
                                              from: Data(#"{"usage":24,"modifiers":{"modifiers":["control"]}}"#.utf8))
        XCTAssertEqual(legacy, plain)
        let chord = KeyboardShortcut(usage: 14, modifiers: ModifierChord(), additionalUsages: [32])
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcut.self, from: JSONEncoder().encode(chord)), chord)
        XCTAssertTrue(chord.isValid)
        XCTAssertFalse(KeyboardShortcut(usage: 14, modifiers: ModifierChord(), additionalUsages: [14]).isValid)
        XCTAssertFalse(KeyboardShortcut(usage: 999, modifiers: ModifierChord()).isValid)
    }

    func testShortcutPlacementsRoundTrip() throws {
        let item = ShortcutItem(id: "u", title: "Underline", displayKey: "U", usage: 24,
                                modifiers: ModifierChord([.control]), systemImage: "underline")
        let placement = CustomControlPlacement(kind: .shortcut(item), x: 0.3, y: 0.7)
        let decoded = try JSONDecoder().decode(CustomControlPlacement.self, from: JSONEncoder().encode(placement))
        XCTAssertEqual(decoded, placement)
        XCTAssertNil(decoded.palette)
    }

    // MARK: - Share codes

    private func sampleLayout() -> CustomControlLayout {
        var layout = CustomControlLayout.radialTemplate(id: "local-id", name: "Drawing", corner: .bottomLeading)
        let shortcut = ShortcutItem(id: "k3", title: "K then 3", displayKey: "K3", usage: 14,
                                    modifiers: ModifierChord(), systemImage: nil)
        var item = shortcut
        item.action = .keyboardShortcut(KeyboardShortcut(usage: 14, modifiers: ModifierChord(), additionalUsages: [32]))
        layout.portrait.placements.append(CustomControlPlacement(id: "k3", kind: .shortcut(item), x: 0.5, y: 0.2, size: 1.2))
        layout.landscape.placements.removeLast()
        layout.twoHandAssist = false
        return layout
    }

    func testShareCodeRoundTripsTheLayout() throws {
        let layout = sampleLayout()
        let code = try CustomLayoutShareCode.encode(layout)
        XCTAssertTrue(code.hasPrefix("MDL1-"))
        let summary = try CustomLayoutShareCode.decode(code).get()
        XCTAssertNotEqual(summary.layout.id, layout.id, "an import is a new layout")
        XCTAssertEqual(summary.layout.name, "Drawing")
        XCTAssertEqual(summary.layout.landscape, layout.landscape)
        XCTAssertEqual(summary.layout.portrait, layout.portrait, "portrait survives independently")
        XCTAssertEqual(summary.layout.twoHandAssist, false)
        XCTAssertEqual(summary.shortcutCount, 1)
        XCTAssertEqual(summary.landscapeControls, layout.landscape.placements.count)
        XCTAssertEqual(summary.portraitControls, layout.portrait.placements.count)
        XCTAssertEqual(summary.warnings, [])
        // Whitespace from chat apps doesn't matter.
        XCTAssertNoThrow(try CustomLayoutShareCode.decode(" \n" + code.prefix(20) + "\n" + code.dropFirst(20)).get())
    }

    func testCorruptedAndForeignCodesAreRejected() throws {
        let code = try CustomLayoutShareCode.encode(sampleLayout())
        var chars = Array(code)
        let index = chars.count / 2
        chars[index] = chars[index] == "A" ? "B" : "A"
        XCTAssertEqual(CustomLayoutShareCode.decode(String(chars)).failure, .corrupted)
        XCTAssertEqual(CustomLayoutShareCode.decode(String(code.dropLast(3))).failure, .corrupted)
        XCTAssertEqual(CustomLayoutShareCode.decode("hello").failure, .notAShareCode)
        XCTAssertEqual(CustomLayoutShareCode.decode("MDL2-" + code.dropFirst(5)).failure, .unsupportedVersion(2))
        XCTAssertEqual(CustomLayoutShareCode.decode("MDL1-" + String(repeating: "A", count: 70_000)).failure,
                       .tooLarge)
    }

    func testShareCodesCarryOnlyLayoutData() throws {
        let code = try CustomLayoutShareCode.encode(sampleLayout())
        let body = code.dropFirst(5).split(separator: ".")[0]
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        let json = try (compressed as NSData).decompressed(using: .zlib) as Data
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["name", "landscape", "portrait", "twoHandAssist", "assistActionIDs"])
        let text = String(decoding: json, as: UTF8.self).lowercased()
        for secret in ["local-id", "peer", "trust", "certificate", "token", "tailscale", "allowinput"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func testImportsAddANewLayoutWithinTheLimit() throws {
        var preferences = ReceiverControlPreferences()
        preferences.createCustomLayout(id: "a")
        let existing = preferences.customLayouts[0]
        let summary = try CustomLayoutShareCode.decode(CustomLayoutShareCode.encode(existing)).get()
        guard case .imported(let id) = preferences.importCustomLayout(summary.layout) else {
            return XCTFail("import refused")
        }
        XCTAssertEqual(preferences.customLayouts.count, 2)
        XCTAssertEqual(preferences.customLayouts[0], existing, "never overwrites")
        XCTAssertEqual(preferences.customLayouts.first { $0.id == id }?.name, existing.name + " 2")
        while preferences.canCreateCustomLayout { preferences.createCustomLayout() }
        XCTAssertEqual(preferences.importCustomLayout(summary.layout), .limitReached)
        XCTAssertEqual(preferences.customLayouts.count, CustomControlLayout.maximumCount)
    }

    func testImportSanitizesAndWarnsAboutUnknownContent() throws {
        var layout = sampleLayout()
        layout.name = String(repeating: "x", count: 200)
        layout.portrait.placements.append(CustomControlPlacement(id: "f", kind: .function("teleport"), x: 0.5, y: 0.5))
        let summary = try CustomLayoutShareCode.decode(CustomLayoutShareCode.encode(layout)).get()
        XCTAssertEqual(summary.layout.name.count, CustomLayoutShareCode.maximumNameLength)
        XCTAssertEqual(summary.warnings, [.unknownActions(1)])
    }

    // MARK: - Editor and Preview

    func testPreviewNeverSendsAndShowsWhatWouldBeSent() throws {
        var session = CustomLayoutPreviewSession()
        session.tapModifier(.command)
        session.tapAssistModifier(.shift)
        XCTAssertEqual(session.interaction.activeChord, ModifierChord([.command, .shift]))
        let redo = ShortcutItem(title: "Redo", displayKey: "Z", usage: 29, modifiers: ModifierChord([.command, .shift]))
        session.tapPaletteAction(redo)
        XCTAssertEqual(session.feedback, .wouldSend("⌘⇧Z"))
        let showDesktop = try XCTUnwrap(FunctionTrayProfile.canonical().items.first { $0.id == "show-desktop" }).item
        session.tapAction(showDesktop)
        XCTAssertEqual(session.feedback, .wouldPerform("Show Desktop"))
        session.reset()
        XCTAssertEqual(session.interaction, ControlInteractionState())
    }

    func testEditorAndRuntimeShareOneGeometryAndSnapOnlyChangesStoredPositions() {
        let area = CGRect(x: 12, y: 36, width: 1170, height: 766)
        let point = CGPoint(x: area.minX + area.width * 0.503, y: area.minY + area.height * 0.25)
        let free = CustomLayoutGeometry.droppedPosition(for: point, in: area, diameter: 44,
                                                        snapToEdges: false, snapToGuides: false)
        XCTAssertEqual(free.x, 0.503, accuracy: 0.0001)
        let snapped = CustomLayoutGeometry.droppedPosition(for: point, in: area, diameter: 44,
                                                           snapToEdges: false, snapToGuides: true)
        XCTAssertEqual(snapped.x, 0.5)
        XCTAssertEqual(snapped.y, 0.25, accuracy: 0.0001)
        let arrangement = CustomControlArrangement.radialTemplate(corner: .topLeading, portrait: false)
        XCTAssertEqual(CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base),
                       CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: base))
    }

    // MARK: - Settings search

    func testSearchFindsRealSettingsOnTheirPages() {
        let expectations: [(String, MobileSettingsCategory)] = [
            ("Smart Touch", .input), ("Rotation", .gestures), ("Control Layout", .controls),
            ("Auto-hide", .controls), ("Move View", .gestures), ("Remote Access", .remoteAccess),
            ("QUIC", .connections), ("Control Size", .controls), ("Two-Hand Assist", .controls),
            ("show desktop", .controls), ("lip sync", .audio),
        ]
        for (query, category) in expectations {
            XCTAssertEqual(MobileSettingsSearchIndex.search(query, isPad: true, debug: false).first?.category,
                           category, query)
        }
    }

    func testSearchRespectsDeviceAndBuild() {
        XCTAssertTrue(MobileSettingsSearchIndex.search("Control Size", isPad: false, debug: true).isEmpty)
        XCTAssertTrue(MobileSettingsSearchIndex.search("notch debug", isPad: true, debug: false).isEmpty)
        XCTAssertFalse(MobileSettingsSearchIndex.search("notch debug", isPad: true, debug: true).isEmpty)
        XCTAssertTrue(MobileSettingsSearchIndex.search("   ", isPad: true, debug: true).isEmpty)
        XCTAssertEqual(MobileSettingsSearchIndex.search("gestures", isPad: true, debug: false).first?.id,
                       "category.gestures")
        let ids = MobileSettingsSearchIndex.items(isPad: true, debug: true).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Local View Navigation

    func testLocalNavigationWorksWithInputOff() {
        XCTAssertTrue(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed: false,
                                                                      localNavigationAllowed: true, videoEnabled: true))
        XCTAssertFalse(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed: false,
                                                                       localNavigationAllowed: false, videoEnabled: true),
                       "both off: the view is locked")
        XCTAssertTrue(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed: true,
                                                                      localNavigationAllowed: false, videoEnabled: true))
        var gate = ReceiverMultiFingerGestureGate(voiceOverRunning: false)
        XCTAssertTrue(gate.update(remoteInputAllowed: false, localNavigationAllowed: true))
        XCTAssertTrue(gate.isEnabled(.twoFingerViewport))
        XCTAssertTrue(gate.isEnabled(.viewportDoubleTap))
        XCTAssertFalse(gate.isEnabled(.threeFingerSwipe))
        XCTAssertFalse(gate.isEnabled(.threeFingerTap))
        XCTAssertFalse(gate.isEnabled(.pinchSpread))
        _ = gate.update(remoteInputAllowed: false, localNavigationAllowed: false)
        for kind in ReceiverMultiFingerRecognizer.allCases { XCTAssertFalse(gate.isEnabled(kind)) }
        _ = gate.update(remoteInputAllowed: true, localNavigationAllowed: false)
        XCTAssertFalse(gate.isEnabled(.viewportDoubleTap))
        XCTAssertTrue(gate.isEnabled(.twoFingerViewport), "remote scrolling still works")
    }

    func testLocalNavigationNeverRoutesAnythingToTheMac() {
        for intent in [TwoFingerGestureIntent.undecided, .scroll, .viewportZoomPan] {
            for localNavigation in [true, false] {
                for video in [true, false] {
                    for pinch in ReceiverGestureTarget.allCases {
                        for rotate in ReceiverGestureTarget.allCases {
                            let routes = TwoFingerRoutingPolicy.routes(
                                intent: intent, remoteInputAllowed: false, localNavigationAllowed: localNavigation,
                                videoEnabled: video, pinchTarget: pinch, rotateTarget: rotate)
                            XCTAssertTrue(routes.isSubset(of: [.viewport]))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .viewportZoomPan, remoteInputAllowed: false,
                                                     localNavigationAllowed: true, videoEnabled: true,
                                                     pinchTarget: .viewport, rotateTarget: .disabled), [.viewport])
    }

    func testDisabledLocalNavigationLeavesRemoteRoutesIntact() {
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .viewportZoomPan, remoteInputAllowed: true,
                                                     localNavigationAllowed: false, videoEnabled: true,
                                                     pinchTarget: .viewport, rotateTarget: .disabled), [])
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .viewportZoomPan, remoteInputAllowed: true,
                                                     localNavigationAllowed: false, videoEnabled: true,
                                                     pinchTarget: .app, rotateTarget: .disabled), [.appCommands])
        XCTAssertEqual(TwoFingerRoutingPolicy.routes(intent: .scroll, remoteInputAllowed: true,
                                                     localNavigationAllowed: false, videoEnabled: true,
                                                     pinchTarget: .viewport, rotateTarget: .disabled), [.remoteScroll])
        XCTAssertFalse(LocalViewNavigationPolicy.allowsViewportChanges(localNavigationAllowed: true, videoEnabled: false))
    }

    func testVoiceOverStillOverridesEverything() {
        var gate = ReceiverMultiFingerGestureGate(voiceOverRunning: true)
        _ = gate.update(remoteInputAllowed: true, localNavigationAllowed: true)
        for kind in ReceiverMultiFingerRecognizer.allCases { XCTAssertFalse(gate.isEnabled(kind)) }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
