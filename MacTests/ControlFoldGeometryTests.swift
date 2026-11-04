import CoreGraphics
import XCTest

/// iPhone Duo folds (tracker #99): the receiver's own bar and overlays stay
/// off the crease. Fixtures are the inner display's measured geometry: book
/// pose 951 × 669 with the band at x 455.5–495.5, laptop pose 669 × 951 with
/// it at y 455.5–495.5 (the 40 pt band includes the system's margins).
final class ControlFoldGeometryTests: XCTestCase {
    private let book = CGRect(x: 0, y: 0, width: 951, height: 669)
    private let bookFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private let laptop = CGRect(x: 0, y: 0, width: 669, height: 951)
    private let laptopFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    // MARK: - Pieces

    func testWithoutAFoldTheWholeAreaIsOnePiece() {
        XCTAssertEqual(ControlFoldGeometry.pieces(of: book, divisions: []), [book])
    }

    func testAFoldLeavesTwoPieces() {
        XCTAssertEqual(ControlFoldGeometry.pieces(of: book, divisions: [bookFold]),
                       [CGRect(x: 0, y: 0, width: 455.5, height: 669), CGRect(x: 495.5, y: 0, width: 455.5, height: 669)])
        XCTAssertEqual(ControlFoldGeometry.pieces(of: laptop, divisions: [laptopFold]),
                       [CGRect(x: 0, y: 0, width: 669, height: 455.5), CGRect(x: 0, y: 495.5, width: 669, height: 455.5)])
    }

    // MARK: - Centred overlays

    func testAnOverlayAwayFromTheFoldIsUntouched() {
        let prompt = CGRect(x: 100, y: 560, width: 200, height: 44)
        XCTAssertEqual(ControlFoldGeometry.clearOfFolds(prompt, in: book, divisions: [bookFold]), prompt)
        XCTAssertEqual(ControlFoldGeometry.clearOfFolds(prompt, in: book, divisions: []), prompt)
    }

    func testACentredOverlayMovesWhollyToOneSideOfABookFold() {
        let prompt = CGRect(x: 375.5, y: 560, width: 200, height: 44)   // centred on the crease
        let moved = ControlFoldGeometry.clearOfFolds(prompt, in: book, divisions: [bookFold])
        XCTAssertFalse(moved.intersects(bookFold))
        XCTAssertEqual(moved.minY, prompt.minY)
        XCTAssertGreaterThan(moved.minX, bookFold.maxX, "a tie goes to the trailing piece")
    }

    func testACentredCardMovesToTheLowerHalfInLaptopPose() {
        let card = CGRect(x: 134.5, y: 375.5, width: 400, height: 200)   // centred on the crease
        let moved = ControlFoldGeometry.clearOfFolds(card, in: laptop, divisions: [laptopFold])
        XCTAssertFalse(moved.intersects(laptopFold))
        XCTAssertGreaterThan(moved.minY, laptopFold.maxY, "a tie goes to the lower, flat half")
        XCTAssertEqual(moved.minX, card.minX)
    }

    func testAnOverlayMostlyOnOneSideStaysOnThatSide() {
        let prompt = CGRect(x: 300, y: 300, width: 200, height: 44)   // mostly left of the crease
        let moved = ControlFoldGeometry.clearOfFolds(prompt, in: book, divisions: [bookFold])
        XCTAssertLessThanOrEqual(moved.maxX, bookFold.minX)
    }

    // MARK: - Keyboard bar

    private func bar(_ container: CGRect, keyboardTop: CGFloat, folds: [CGRect],
                     count: Int = 9, leading: Int = 4) -> ControlFoldGeometry.KeyboardBar {
        ControlFoldGeometry.keyboardBar(count: count, leadingCount: leading, item: 44, gap: 6, padding: 6,
                                        container: container, keyboardTop: keyboardTop, divisions: folds)
    }

    func testWithoutAFoldTheBarIsOneCentredRowAboveTheKeyboard() {
        let layout = bar(CGRect(x: 0, y: 0, width: 393, height: 852), keyboardTop: 500, folds: [])
        XCTAssertEqual(layout.bars.count, 1)
        XCTAssertEqual(layout.cells.count, 9)
        XCTAssertEqual(layout.bars[0].midX, 196.5, accuracy: 0.5)
        XCTAssertEqual(layout.bars[0].maxY, 492, accuracy: 0.5)
        XCTAssertEqual(layout.item, 44)
    }

    func testABookFoldSplitsTheBarAroundTheCrease() {
        let layout = bar(book, keyboardTop: 400, folds: [bookFold])
        XCTAssertEqual(layout.bars.count, 2)
        XCTAssertEqual(layout.cells.count, 9)
        for frame in layout.bars + layout.cells {
            XCTAssertFalse(frame.intersects(bookFold), "\(frame) is on the crease")
        }
        XCTAssertLessThan(layout.bars[0].maxX, bookFold.minX, "modifiers on the left")
        XCTAssertGreaterThan(layout.bars[1].minX, bookFold.maxX, "the rest on the right")
        XCTAssertTrue(layout.cells.prefix(4).allSatisfy { $0.maxX < bookFold.minX })
        XCTAssertEqual(layout.bars[0].maxY, layout.bars[1].maxY)
        XCTAssertEqual(layout.bars[0].maxY, 392, accuracy: 0.5)
        XCTAssertLessThanOrEqual(layout.paletteArea.maxX, bookFold.minX, "the palette opens beside the modifiers")
    }

    func testALaptopFoldLiftsTheBarAboveTheCrease() {
        // The keyboard and typing strip reach up to about y = 518.
        let layout = bar(laptop, keyboardTop: 518, folds: [laptopFold])
        XCTAssertEqual(layout.bars.count, 1)
        XCTAssertFalse(layout.bars[0].intersects(laptopFold))
        XCTAssertLessThanOrEqual(layout.bars[0].maxY, laptopFold.minY)
        XCTAssertTrue(layout.cells.allSatisfy { !$0.intersects(laptopFold) })
    }

    func testABookFoldKeepsTheArrowKeypadOnItsOwnHalf() {
        // Bar order: four modifiers, Esc, Tab, Return, Arrow Keys, Hide.
        let layout = bar(book, keyboardTop: 400, folds: [bookFold])
        let arrowCell = layout.cells[7]
        let centre = CGPoint(x: arrowCell.midX, y: arrowCell.midY)
        let piece = ControlFoldGeometry.pieces(of: book, divisions: [bookFold]).first { $0.contains(centre) }
        XCTAssertNotNil(piece)
        let keypad = ControlTrayGeometry.keyboardBarKeypadFrame(
            safe: piece ?? book, bar: layout.bars[1], item: arrowCell,
            keypadSize: ArrowKeypadGeometry.size(key: 42, gap: 4), palette: nil)
        XCTAssertFalse(keypad.intersects(bookFold), "\(keypad) is on the crease")
        XCTAssertTrue((piece ?? book).contains(keypad))
        XCTAssertLessThanOrEqual(keypad.maxY, layout.bars[1].minY, "above its bar")
    }

    func testALaptopFoldFarFromTheKeyboardChangesNothing() {
        let layout = bar(laptop, keyboardTop: 900, folds: [laptopFold])
        let plain = bar(laptop, keyboardTop: 900, folds: [])
        XCTAssertEqual(layout, plain)
    }
}
