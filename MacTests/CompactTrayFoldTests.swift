import CoreGraphics
import XCTest

/// The compact phone tray on an iPhone Duo's cover window (466 × 678 pt, a
/// portrait window the roomy iPad-style controls never take) with one
/// synthetic fold: a vertical band at x 221–245 and a horizontal one at
/// y 327–351 (24 pt, the band including the system's margins). The
/// composition below follows `ReceiverControlOverlay.phoneBody`: the Main
/// Tray's layout, the row split around a vertical fold, the Function Tray's
/// groups and the arrow button, with the default item lists and metrics.
final class CompactTrayFoldTests: XCTestCase {
    private let container = CGRect(x: 0, y: 0, width: 466, height: 678)
    private let verticalFold = CGRect(x: 221, y: 0, width: 24, height: 678)
    private let horizontalFold = CGRect(x: 0, y: 327, width: 466, height: 24)

    private let chip: CGFloat = 40
    private let gap: CGFloat = 4
    private let slack: CGFloat = 4

    private struct Compact {
        var trayRow: ControlFoldGeometry.TrayRow?
        var trayFrame: CGRect
        var trayCells: [CGRect]
        var functionFrames: [CGRect]
        var functionChips: [CGRect]
        var arrowToggle: CGRect

        var controls: [CGRect] { trayCells + functionChips + [arrowToggle] }
    }

    private func compact(divisions: [CGRect]) -> Compact {
        let regions = divisions.map { ControlReservedRegion(kind: .division, frame: $0) }
        let items = ControlProfile.canonical().visibleTrayItems
        let groups = FunctionTrayProfile.canonical().visibleGroups
        let count = items.count
        let item = ControlTrayGeometry.fittedChipDiameter(count: count, length: container.width,
                                                          preferred: chip, gap: gap, slack: slack)
        let drawnLength = CGFloat(count) * item + CGFloat(count - 1) * gap
        let traySize = CGSize(width: drawnLength + slack, height: item + slack)
        let base = ControlTrayGeometry.layout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: true, side: .trailing,
            traySize: traySize, paletteSize: CGSize(width: 200, height: 44), avoidNotch: true,
            reservedRegions: regions)
        let row = ControlFoldGeometry.trayRow(
            count: count, item: chip, gap: gap, slack: slack, placed: base.trayFrame,
            wantedWidth: traySize.width, container: container, divisions: divisions)

        let trayFrame = row?.frame ?? base.trayFrame
        let cells: [CGRect]
        if let row {
            cells = row.cells
        } else {
            let startX = trayFrame.midX - drawnLength / 2
            cells = (0..<count).map { index in
                CGRect(x: startX + CGFloat(index) * (item + gap), y: trayFrame.midY - item / 2,
                       width: item, height: item)
            }
        }
        let renderedSize = row?.frame.size ?? traySize
        let rendered = CGRect(x: trayFrame.midX - renderedSize.width / 2, y: trayFrame.midY - renderedSize.height / 2,
                              width: renderedSize.width, height: renderedSize.height)

        let groupSizes = groups.map { group in
            CGSize(width: CGFloat(group.count) * chip + CGFloat(group.count - 1) * gap + slack, height: chip + slack)
        }
        let functionFrames = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: true,
            mainSide: base.side, position: .sameSide, mainTrayFrame: rendered, groupSizes: groupSizes,
            avoiding: nil, avoidNotch: true, reservedRegions: regions, bottomRow: true)
        var functionChips: [CGRect] = []
        for (frame, group) in zip(functionFrames, groups) {
            let width = CGFloat(group.count) * chip + CGFloat(group.count - 1) * gap
            functionChips += (0..<group.count).map { index in
                CGRect(x: frame.midX - width / 2 + CGFloat(index) * (chip + gap), y: frame.midY - chip / 2,
                       width: chip, height: chip)
            }
        }
        let arrows = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: container, safeInsets: .zero, portrait: true, side: .trailing,
            toggleSize: CGSize(width: chip + slack, height: chip + slack), keypadOpen: false, key: 42, gap: 4,
            mainTrayFrame: rendered, obstacles: [rendered] + functionFrames, avoidNotch: true,
            reservedRegions: regions)
        return Compact(trayRow: row, trayFrame: trayFrame, trayCells: cells, functionFrames: functionFrames,
                       functionChips: functionChips, arrowToggle: arrows.toggle)
    }

    private func assertClear(_ layout: Compact, of fold: CGRect, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let items = ControlProfile.canonical().visibleTrayItems.count
        XCTAssertEqual(layout.trayCells.count, items, "no tray chip is dropped (\(context))", file: file, line: line)
        XCTAssertEqual(layout.functionChips.count, 5, "no function chip is dropped (\(context))", file: file, line: line)
        for (index, frame) in layout.controls.enumerated() {
            XCTAssertTrue(container.contains(frame), "control \(index) \(frame) is inside the window (\(context))",
                          file: file, line: line)
            XCTAssertFalse(frame.intersects(fold), "control \(index) \(frame) is off the fold (\(context))",
                           file: file, line: line)
        }
        for (index, frame) in layout.controls.enumerated() {
            for other in layout.controls.indices where other > index {
                XCTAssertFalse(frame.intersects(layout.controls[other]),
                               "controls \(index) and \(other) do not overlap (\(context))", file: file, line: line)
            }
        }
    }

    // MARK: - A vertical fold

    func testCompactTrayKeepsEveryControlInsideAndOffAVerticalFold() {
        assertClear(compact(divisions: [verticalFold]), of: verticalFold, "vertical fold")
    }

    func testCompactTraySplitsAroundAVerticalFoldKeepingItemOrder() throws {
        let layout = compact(divisions: [verticalFold])
        let row = try XCTUnwrap(layout.trayRow, "a nine-chip row cannot fit one 221 pt piece")
        XCTAssertEqual(row.counts, [5, 4])
        XCTAssertEqual(row.itemRanges, [0..<5, 5..<9])
        XCTAssertEqual(row.item, 35, "chips shrink just enough for the fuller piece")
        XCTAssertEqual(layout.trayCells.map(\.minX), layout.trayCells.map(\.minX).sorted(), "left to right, in order")
        XCTAssertTrue(layout.trayCells.prefix(5).allSatisfy { $0.maxX <= verticalFold.minX })
        XCTAssertTrue(layout.trayCells.suffix(4).allSatisfy { $0.minX >= verticalFold.maxX })
        XCTAssertEqual(row.groups.count, 2)
        XCTAssertTrue(row.groups.allSatisfy { !$0.intersects(verticalFold) }, "touch regions stay off the fold")
        // The drawn stack is the nine chips, the gaps inside each group (seven) and the
        // fold's empty gap with the stack's own spacing on both sides of it.
        let drawn = CGFloat(9) * row.item + CGFloat(7) * gap + row.spacers[0] + 2 * gap
        XCTAssertEqual(row.frame.width - slack, drawn, accuracy: 0.001)
    }

    func testCompactFunctionGroupsStayWholeOnEachSideOfAVerticalFold() {
        let layout = compact(divisions: [verticalFold])
        XCTAssertEqual(layout.functionFrames.count, 3)
        XCTAssertLessThanOrEqual(layout.functionFrames[0].maxX, verticalFold.minX)
        XCTAssertLessThanOrEqual(layout.functionFrames[1].maxX, verticalFold.minX)
        XCTAssertGreaterThanOrEqual(layout.functionFrames[2].minX, verticalFold.maxX)
        XCTAssertEqual(layout.functionFrames.map(\.width), [88, 88, 44])
    }

    /// Runs on `functionTrayLayout` alone: a row wider than the piece beside
    /// the fold used to be clamped into that piece, so its groups overlapped
    /// one another and the first sat on the fold.
    func testFunctionGroupsDoNotOverlapOrTouchAVerticalFold() {
        let regions = [ControlReservedRegion(kind: .division, frame: verticalFold)]
        let mainTray = CGRect(x: 13, y: 627, width: 420.5, height: 39)
        let frames = ControlTrayGeometry.functionTrayLayout(
            container: container, safeInsets: .zero, keyboardVisibleRect: nil, portrait: true,
            mainSide: .trailing, position: .sameSide, mainTrayFrame: mainTray,
            groupSizes: [CGSize(width: 88, height: 44), CGSize(width: 88, height: 44), CGSize(width: 44, height: 44)],
            avoiding: nil, avoidNotch: true, reservedRegions: regions, bottomRow: true)
        XCTAssertEqual(frames.count, 3)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(container.contains(frame), "group \(index) \(frame) is inside the window")
            XCTAssertFalse(frame.intersects(verticalFold), "group \(index) \(frame) is off the fold")
            for other in frames.indices where other > index {
                XCTAssertFalse(frame.intersects(frames[other]), "groups \(index) and \(other) do not overlap")
            }
        }
    }

    // MARK: - A horizontal fold

    func testCompactTrayKeepsEveryControlInsideAndOffAHorizontalFold() {
        let layout = compact(divisions: [horizontalFold])
        XCTAssertNil(layout.trayRow, "a horizontal fold needs no split: the row fits the piece below it")
        assertClear(layout, of: horizontalFold, "horizontal fold")
    }

    // MARK: - No fold

    func testCompactTrayWithoutAFoldIsExactlyAsBefore() {
        let layout = compact(divisions: [])
        XCTAssertNil(layout.trayRow)
        XCTAssertEqual(layout.trayFrame, CGRect(x: 35, y: 622, width: 396, height: 44))
        XCTAssertEqual(layout.trayCells.first, CGRect(x: 37, y: 624, width: 40, height: 40))
        XCTAssertEqual(layout.functionFrames, [CGRect(x: 109, y: 568, width: 88, height: 44),
                                               CGRect(x: 211, y: 568, width: 88, height: 44),
                                               CGRect(x: 313, y: 568, width: 44, height: 44)])
        XCTAssertEqual(layout.arrowToggle, CGRect(x: 410, y: 568, width: 44, height: 44))
        assertClear(layout, of: .null, "no fold")
    }

    // MARK: - The split itself

    func testTrayRowIsNilWithoutAVerticalFoldOrWhenTheRowWasNotSqueezed() {
        let placed = CGRect(x: 35, y: 622, width: 396, height: 44)
        XCTAssertNil(ControlFoldGeometry.trayRow(count: 9, item: 40, gap: 4, slack: 4, placed: placed,
                                                 wantedWidth: 396, container: container, divisions: [verticalFold]),
                     "the layout gave the row all it asked for")
        let squeezed = CGRect(x: 257, y: 622, width: 197, height: 44)
        XCTAssertNil(ControlFoldGeometry.trayRow(count: 9, item: 40, gap: 4, slack: 4, placed: squeezed,
                                                 wantedWidth: 396, container: container, divisions: []))
        XCTAssertNil(ControlFoldGeometry.trayRow(count: 9, item: 40, gap: 4, slack: 4, placed: squeezed,
                                                 wantedWidth: 396, container: container,
                                                 divisions: [horizontalFold]))
        XCTAssertNil(ControlFoldGeometry.trayRow(count: 9, item: 40, gap: 4, slack: 4, placed: squeezed,
                                                 wantedWidth: 396, container: container,
                                                 divisions: [CGRect(x: 221, y: 0, width: 24, height: 300)]),
                     "a vertical fold that stops above the row does not touch it")
    }

    func testTrayRowOffCentreFoldPutsMoreChipsInTheWiderPiece() throws {
        let fold = CGRect(x: 100, y: 0, width: 24, height: 678)   // pieces 100 and 342 wide
        let squeezed = CGRect(x: 136, y: 622, width: 318, height: 44)
        let row = try XCTUnwrap(ControlFoldGeometry.trayRow(
            count: 9, item: 40, gap: 4, slack: 4, placed: squeezed, wantedWidth: 396, container: container,
            divisions: [fold]))
        XCTAssertEqual(row.counts.reduce(0, +), 9)
        XCTAssertGreaterThan(row.counts[1], row.counts[0])
        XCTAssertEqual(row.cells.count, 9)
        XCTAssertTrue(row.cells.allSatisfy { container.contains($0) && !$0.intersects(fold) })
    }

    func testGroupRowIsNilWithoutAVerticalFoldCrossingIt() {
        let sizes = [CGSize(width: 88, height: 44), CGSize(width: 44, height: 44)]
        XCTAssertNil(ControlFoldGeometry.groupRow(sizes: sizes, groupGap: 14, y: 568, height: 44,
                                                  container: container, divisions: []))
        XCTAssertNil(ControlFoldGeometry.groupRow(sizes: sizes, groupGap: 14, y: 568, height: 44,
                                                  container: container, divisions: [horizontalFold]))
    }
}
