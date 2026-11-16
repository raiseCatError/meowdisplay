import CoreGraphics
import XCTest

/// Receiver chrome that adapts to the window and the text size instead of a device model (#121):
/// Stage Peek's buttons, and the Main Tray on the narrowest screens.
final class ReceiverAdaptiveLayoutTests: XCTestCase {
    // "Expand", "Compact", "Add as Tile" and a long translation ("Als Kachel hinzufügen").
    private let expand = [6]
    private let compactAndTile = [7, 11]
    private let longGerman = [9, 22]

    private func shows(_ titles: [Int], scale: CGFloat, width: CGFloat) -> Bool {
        StagePeekToolbarLayout.showsTitles(titles: titles, textScale: scale, available: width)
    }

    func testTheToolbarKeepsItsTitlesAtTheDefaultTextSizeOnEveryUsualWidth() {
        // A 320 point Slide Over, a 360 point small phone, ordinary and large phones, a split iPad.
        for width: CGFloat in [320, 360, 375, 393, 430, 507, 744, 1032] {
            XCTAssertTrue(shows(expand, scale: 1, width: width), "Expand @\(width)")
            XCTAssertTrue(shows(compactAndTile, scale: 1, width: width), "Compact + Add as Tile @\(width)")
        }
    }

    func testTheToolbarDropsToIconsWhenTheTitlesWouldNotFit() {
        // Large text on a phone, and a longer translation on a narrow window.
        XCTAssertFalse(shows(compactAndTile, scale: 1.5, width: 393))
        XCTAssertFalse(shows(compactAndTile, scale: 1.3, width: 320))
        XCTAssertFalse(shows(longGerman, scale: 1, width: 320))
        XCTAssertFalse(shows(longGerman, scale: 1, width: 360))
        // Accessibility text sizes, every phone width.
        for width: CGFloat in [320, 360, 375, 393, 430] {
            XCTAssertFalse(shows(compactAndTile, scale: 2.2, width: width), "AX @\(width)")
            XCTAssertFalse(shows(expand, scale: 3, width: width), "AX Expand @\(width)")
        }
        // The same words keep their titles where there is room.
        XCTAssertTrue(shows(longGerman, scale: 1, width: 744))
    }

    func testTheDecisionOnlyEverMovesTowardIcons() {
        for titles in [expand, compactAndTile, longGerman] {
            for width in stride(from: CGFloat(280), through: 900, by: 20) {
                var seenIcons = false
                for scale in stride(from: CGFloat(1), through: 3.5, by: 0.1) {
                    let titled = shows(titles, scale: scale, width: width)
                    if !titled { seenIcons = true }
                    XCTAssertFalse(seenIcons && titled, "no flicker back to titles as text grows (\(titles) @\(width), \(scale))")
                }
            }
        }
    }

    func testIconsAloneFitEvenAtTheLargestTextOnTheNarrowestWindow() {
        // Three buttons, icons only, at the largest sizes: inside a 320 point window.
        for scale in [1, 1.5, 2, 2.5, 3] as [CGFloat] {
            let width = StagePeekToolbarLayout.width(titles: compactAndTile, showsTitles: false, textScale: scale)
            XCTAssertLessThanOrEqual(width, 320 - 2 * StagePeekToolbarLayout.margin, "scale \(scale)")
        }
    }

    func testTheToolbarWidthMatchesWhatTheLayoutAlreadyAssumed() {
        // The row used to be centred as if it were at most 260 points wide.
        let widest = StagePeekToolbarLayout.width(titles: compactAndTile, showsTitles: true, textScale: 1)
        XCTAssertEqual(widest, 266, accuracy: 6)
        XCTAssertEqual(StagePeekToolbarLayout.width(titles: [], closeButton: false, showsTitles: true, textScale: 1), 0)
        // A text size below the default never makes it narrower than the default.
        XCTAssertEqual(StagePeekToolbarLayout.width(titles: expand, showsTitles: true, textScale: 0.8),
                       StagePeekToolbarLayout.width(titles: expand, showsTitles: true, textScale: 1))
    }

    // MARK: - Main Tray on the narrowest screens

    func testTheMainTrayStaysOnScreenOnEverySmallWidthAndHeight() {
        // 320 (Display Zoom, Slide Over), 360 (iPhone 13 mini reference) and 375: portrait widths,
        // and the heights of the same phones in landscape (the tray runs along the short edge).
        for length: CGFloat in [320, 360, 375, 390, 393, 402] {
            let chip = ControlTrayGeometry.fittedChipDiameter(count: 9, length: length)
            let tray = 9 * chip + 8 * 4 + 4
            XCTAssertLessThanOrEqual(tray, length, "\(length)pt screen")
            XCTAssertGreaterThanOrEqual(chip, 30, "never an unreadable chip at \(length)pt")
            XCTAssertLessThanOrEqual(chip, 40)
            if length >= 360 {
                XCTAssertLessThanOrEqual(tray, length - 24, "keeps its side margins at \(length)pt")
            }
        }
    }

    func testAnEightKeyTrayKeepsFullSizeChipsWherever9DoNot() {
        // Hiding one chip (Dock, say) is the user's way to a bigger target on a small phone.
        XCTAssertGreaterThan(ControlTrayGeometry.fittedChipDiameter(count: 6, length: 360),
                             ControlTrayGeometry.fittedChipDiameter(count: 9, length: 360))
        XCTAssertEqual(ControlTrayGeometry.fittedChipDiameter(count: 6, length: 360), 40)
    }
}
