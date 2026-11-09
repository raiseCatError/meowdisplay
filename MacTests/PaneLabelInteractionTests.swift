import XCTest

/// Taps and holds on pane titles, including the folded (icon only) title beside the Mac's menu
/// bar (Shared/PaneLabelInteraction.swift). Owner's iPhone QA (build 9000022): a folded title
/// needed one hold to unfold and a second hold for its options.
final class PaneLabelInteractionTests: XCTestCase {
    private typealias I = PaneLabelInteraction
    private let pane = I.Target(tile: "a", tab: nil)

    // MARK: Holding

    /// The cause: the hold marked the label held, which unfolded the strip mid-gesture; the view
    /// carrying the gesture was replaced, the gesture cancelled, and no menu opened. Held, the
    /// strip now keeps the form it was held in until the finger lifts.
    func testAHeldLabelKeepsTheFormItWasHeldInUntilTheFingerLifts() {
        // Beside the menu bar, nothing held: folded.
        XCTAssertTrue(I.folded(sharesRow: true, hasWindows: true, expanded: false, held: false, dragging: false, heldFolded: nil))
        // Held in the folded form: still folded, while held and while dragging from it (the menu
        // bar steps aside during a drag, so `sharesRow` goes false too).
        XCTAssertTrue(I.folded(sharesRow: true, hasWindows: true, expanded: false, held: true, dragging: false, heldFolded: true))
        XCTAssertTrue(I.folded(sharesRow: false, hasWindows: true, expanded: false, held: true, dragging: true, heldFolded: true))
        // Held unfolded: stays unfolded even if the strip would fold meanwhile.
        XCTAssertFalse(I.folded(sharesRow: true, hasWindows: true, expanded: false, held: true, dragging: false, heldFolded: false))
    }

    func testTheStripFoldsOnlyBesideTheMenuBarWhenNothingIsGoingOn() {
        func folded(sharesRow: Bool = true, hasWindows: Bool = true, expanded: Bool = false, held: Bool = false, dragging: Bool = false) -> Bool {
            I.folded(sharesRow: sharesRow, hasWindows: hasWindows, expanded: expanded, held: held, dragging: dragging, heldFolded: nil)
        }
        XCTAssertTrue(folded())
        XCTAssertFalse(folded(sharesRow: false), "no menu bar in the row: full titles")
        XCTAssertFalse(folded(hasWindows: false), "an empty pane says Empty")
        XCTAssertFalse(folded(expanded: true), "tapped, held or scrolled: shown in full for a while")
        XCTAssertFalse(folded(dragging: true), "another drag over the panes: full titles to drop between")
    }

    func testOneHoldOnTheFoldedIconOpensItsOptionsWithTheTitlesInFull() {
        XCTAssertEqual(I.holdEnded(cancelled: false, dragging: false, heldHere: true, folded: true), .menu(expand: true))
        XCTAssertEqual(I.holdEnded(cancelled: false, dragging: false, heldHere: true, folded: false), .menu(expand: false))
    }

    func testAHoldThatMovedDropsAndACancelledOneNeitherDropsNorOpensTheMenu() {
        XCTAssertEqual(I.holdEnded(cancelled: false, dragging: true, heldHere: true, folded: true), .drop)
        XCTAssertEqual(I.holdEnded(cancelled: true, dragging: true, heldHere: true, folded: true), .cancelDrag,
                       "never dropped where the finger happened to be when the system took the touch")
        XCTAssertEqual(I.holdEnded(cancelled: true, dragging: false, heldHere: true, folded: true), .nothing)
        XCTAssertEqual(I.holdEnded(cancelled: false, dragging: false, heldHere: false, folded: false), .nothing,
                       "another label's hold")
    }

    // MARK: Tapping, one tab

    func testATapOnTheSelectedPanesFoldedIconSelectsItAndShowsTheTitles() {
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: true, folded: true, last: nil, now: 10, held: false), .select(expand: true))
    }

    func testATapOnAnUnfoldedOrUnselectedTitleOnlySelects() {
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: true, folded: false, last: nil, now: 10, held: false), .select(expand: false))
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: false, folded: true, last: nil, now: 10, held: false), .select(expand: false),
                       "a pane that isn't selected yet is selected first, as before")
    }

    // MARK: Tapping, several tabs

    func testTabsAreSwitchedOrSelectedAndKeptShown() {
        XCTAssertEqual(I.tap(I.Target(tile: "a", tab: 2), shown: false, highlighted: false, folded: false, last: nil, now: 10, held: false),
                       .showTab(2, expand: true))
        XCTAssertEqual(I.tap(I.Target(tile: "a", tab: 0), shown: true, highlighted: true, folded: true, last: nil, now: 10, held: false),
                       .select(expand: true), "the folded strip shows only the shown tab")
    }

    // MARK: Double tap (Fullscreen on This Device)

    func testTheFirstTapActsAtOnceAndASecondOnTheSameTitleTogglesFullscreen() {
        let first = I.tap(pane, shown: true, highlighted: true, folded: false, last: nil, now: 10, held: false)
        XCTAssertEqual(first, .select(expand: false), "no waiting to see whether another tap follows")
        let last = I.Tap(target: pane, at: 10, folded: false)
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: true, folded: false, last: last, now: 10.2, held: false), .toggleFullscreen)
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: true, folded: false, last: last, now: 10.4, held: false), .select(expand: false),
                       "too slow: two single taps")
        XCTAssertEqual(I.tap(I.Target(tile: "b", tab: nil), shown: true, highlighted: false, folded: false, last: last, now: 10.2, held: false),
                       .select(expand: false), "another pane's title")
        XCTAssertEqual(I.tap(pane, shown: true, highlighted: true, folded: false, last: I.Tap(target: pane, at: 11, folded: false), now: 10.9,
                             held: false), .select(expand: false), "a clock that went back is no double tap")
    }

    /// The first tap on the folded icon unfolds the titles, so the second lands on whichever
    /// title is under the finger now: still the same double tap, never a tab switch.
    func testADoubleTapOnTheFoldedIconStillTogglesFullscreen() {
        let last = I.Tap(target: I.Target(tile: "a", tab: 2), at: 10, folded: true)
        XCTAssertEqual(I.tap(I.Target(tile: "a", tab: 0), shown: false, highlighted: false, folded: false, last: last, now: 10.25, held: false),
                       .toggleFullscreen)
        XCTAssertEqual(I.tap(I.Target(tile: "b", tab: 0), shown: false, highlighted: false, folded: false, last: last, now: 10.25, held: false),
                       .showTab(0, expand: true), "only on the same pane's titles")
    }

    func testTapsDoNothingWhileALabelIsHeld() {
        XCTAssertNil(I.tap(pane, shown: true, highlighted: true, folded: true, last: nil, now: 10, held: true))
    }
}
