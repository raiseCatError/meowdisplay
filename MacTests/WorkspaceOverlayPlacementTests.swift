import CoreGraphics
import XCTest

/// Window view's own overlays against the iPhone's unsafe edges and the receiver's controls
/// (owner's iPhone QA of build 9000022, 2026-11-06). Fixtures are the iPhone 14 Pro Max as its
/// `notchTrace` reported it: 430 x 932 pt portrait, safe insets top 59 / bottom 34, the Dynamic
/// Island's exclusion (126.5, 0, 177 x 59), the Home indicator's (164, 898, 102 x 34). Landscape
/// is 932 x 430 with 59 pt on both sides and 21 at the bottom; the Island's own band comes from
/// `ControlTrayGeometry.unsafeRegions` for whichever side holds it.
final class WorkspaceOverlayPlacementTests: XCTestCase {
    private typealias P = WorkspaceOverlayPlacement

    // MARK: Fixtures

    private let portrait = CGRect(x: 0, y: 0, width: 430, height: 932)
    private let portraitInsets = ControlSafeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    private var portraitSafe: CGRect { portraitInsets.safeRect(in: portrait.size) }
    private let island = CGRect(x: 126.5, y: 0, width: 177, height: 59)
    private let homeIndicator = CGRect(x: 164, y: 898, width: 102, height: 34)

    private let landscape = CGRect(x: 0, y: 0, width: 932, height: 430)
    private let landscapeInsets = ControlSafeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
    private var landscapeSafe: CGRect { landscapeInsets.safeRect(in: landscape.size) }

    /// iPad Pro 11" in landscape: a status bar's 24 pt at the top, the Home indicator's 20 below.
    private let pad = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let padInsets = ControlSafeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)

    /// Measured on the owner's screenshots: Cancel / Float / Remove… and the chip.
    private let dropBar = CGSize(width: 404, height: 44)
    private let chipSize = CGSize(width: 216, height: 30)

    /// The collapsed tray's Settings gear exactly as the app lays it out (46 pt chip + slack).
    private func gear(_ container: CGRect, _ insets: ControlSafeInsets, portrait: Bool,
                      notchSide: LandscapeTraySide? = nil) -> CGRect {
        ControlTrayGeometry.layout(container: container, safeInsets: insets, keyboardVisibleRect: nil,
                                   portrait: portrait, side: .trailing, traySize: CGSize(width: 50, height: 50),
                                   paletteSize: .zero, avoidNotch: true, notchSide: notchSide).trayFrame
    }

    /// The full nine-chip Main Tray (40 pt chips, as `fittedChipDiameter` gives on 430 pt).
    private func fullTray(_ container: CGRect, _ insets: ControlSafeInsets, portrait: Bool,
                          notchSide: LandscapeTraySide? = nil) -> CGRect {
        let size = portrait ? CGSize(width: 396, height: 44) : CGSize(width: 44, height: 396)
        return ControlTrayGeometry.layout(container: container, safeInsets: insets, keyboardVisibleRect: nil,
                                          portrait: portrait, side: .trailing, traySize: size,
                                          paletteSize: .zero, avoidNotch: true, notchSide: notchSide).trayFrame
    }

    /// The title pill's largest extent for a float of `content` (as the receiver draws it).
    private func pillSize(_ content: CGRect) -> CGSize {
        let b = WorkspaceFloatLayering.pillBounds(WorkspaceRect(x: Double(content.minX), y: Double(content.minY),
                                                                width: Double(content.width), height: Double(content.height)))
        return CGSize(width: b.width, height: b.height)
    }

    private func islandBand(_ side: LandscapeTraySide) -> CGRect {
        ControlTrayGeometry.unsafeRegions(in: landscape, safeInsets: landscapeInsets, portrait: false, notchSide: side)
            .first { $0.width < $0.height }!
    }

    // MARK: Drop bar (Cancel / Float / Remove…)

    func testTheOldDropBarSatOnTheSettingsGear() {
        // Root cause (screenshots 1 and 9): centred `picture.maxY - 64`, the gear under Float.
        let g = gear(portrait, portraitInsets, portrait: true)
        XCTAssertEqual(g, CGRect(x: 190, y: 848, width: 50, height: 50))
        let old = CGRect(x: portrait.midX - dropBar.width / 2, y: portrait.maxY - 64 - dropBar.height / 2,
                         width: dropBar.width, height: dropBar.height)
        XCTAssertTrue(old.intersects(g))
    }

    func testPortraitDropBarClearsTheGearAndTheHomeIndicator() {
        let g = gear(portrait, portraitInsets, portrait: true)
        let bar = P.bottomBar(size: dropBar, preferredMidY: portrait.maxY - P.dropBarLift, picture: portrait,
                              safe: portraitSafe, avoiding: [g])
        XCTAssertFalse(bar.insetBy(dx: -7, dy: -7).intersects(g), "a gap from the gear")
        XCTAssertFalse(bar.intersects(homeIndicator))
        XCTAssertTrue(portraitSafe.contains(bar))
        XCTAssertEqual(bar.midX, portrait.midX, "still centred")
        XCTAssertEqual(bar.maxY, g.minY - P.gap, "just above it, not further")
    }

    func testPortraitDropBarClearsTheFullTrayAndTheFunctionTray() {
        let tray = fullTray(portrait, portraitInsets, portrait: true)
        XCTAssertEqual(tray, CGRect(x: 17, y: 854, width: 396, height: 44), "notchTrace's finalMain")
        let groups = ControlTrayGeometry.functionTrayLayout(
            container: portrait, safeInsets: portraitInsets, keyboardVisibleRect: nil, portrait: true,
            mainSide: .trailing, position: .sameSide, mainTrayFrame: tray,
            groupSizes: [CGSize(width: 92, height: 44), CGSize(width: 136, height: 44), CGSize(width: 48, height: 44)],
            avoiding: nil, avoidNotch: true, bottomRow: true)
        let bar = P.bottomBar(size: dropBar, preferredMidY: portrait.maxY - P.dropBarLift, picture: portrait,
                              safe: portraitSafe, avoiding: [tray] + groups)
        for control in [tray] + groups { XCTAssertFalse(bar.intersects(control), "\(control)") }
        XCTAssertTrue(portraitSafe.contains(bar))
    }

    func testDropBarClearsAnOpenArrowKeypad() {
        let tray = fullTray(portrait, portraitInsets, portrait: true)
        let arrows = ControlTrayGeometry.arrowKeysLayoutWithModifiers(
            container: portrait, safeInsets: portraitInsets, portrait: true, side: .trailing,
            toggleSize: CGSize(width: 44, height: 44), keypadOpen: true, key: 42, gap: 4,
            mainTrayFrame: tray, obstacles: [tray], avoidNotch: true)
        let controls = [tray] + arrows.occupied
        let bar = P.bottomBar(size: dropBar, preferredMidY: portrait.maxY - P.dropBarLift, picture: portrait,
                              safe: portraitSafe, avoiding: controls)
        for control in controls { XCTAssertFalse(bar.intersects(control), "\(control)") }
        XCTAssertTrue(portraitSafe.contains(bar))
    }

    func testDropBarClearsTheKeyboardAndItsBar() {
        let keyboard = CGRect(x: 0, y: 596, width: 430, height: 336)
        let keyboardBar = CGRect(x: 8, y: 544, width: 414, height: 48)
        let bar = P.bottomBar(size: dropBar, preferredMidY: portrait.maxY - P.dropBarLift, picture: portrait,
                              safe: portraitSafe, avoiding: [keyboard, keyboardBar])
        XCTAssertLessThanOrEqual(bar.maxY, keyboardBar.minY - P.gap)
    }

    func testLandscapeDropBarStaysPutBesideTheSideTrayOnEitherIslandSide() {
        for side in [LandscapeTraySide.leading, .trailing] {
            let tray = fullTray(landscape, landscapeInsets, portrait: false, notchSide: side)
            let preferred = landscape.maxY - P.dropBarLift
            let bar = P.bottomBar(size: dropBar, preferredMidY: preferred, picture: landscape,
                                  safe: landscapeSafe, avoiding: [tray, gear(landscape, landscapeInsets, portrait: false, notchSide: side)])
            XCTAssertEqual(bar.midY, preferred, "nothing in the way: where it always was")
            XCTAssertTrue(landscapeSafe.contains(bar))
            XCTAssertFalse(bar.intersects(islandBand(side)))
            XCTAssertFalse(bar.intersects(tray))
        }
    }

    func testLandscapeDropBarClearsTheFunctionTrayBottomRow() {
        let tray = fullTray(landscape, landscapeInsets, portrait: false, notchSide: .trailing)
        let groups = ControlTrayGeometry.functionTrayLayout(
            container: landscape, safeInsets: landscapeInsets, keyboardVisibleRect: nil, portrait: false,
            mainSide: .trailing, position: .sameSide, mainTrayFrame: tray,
            groupSizes: [CGSize(width: 44, height: 92), CGSize(width: 228, height: 44), CGSize(width: 136, height: 44)],
            avoiding: nil, avoidNotch: true, notchSide: .trailing, bottomRow: true)
        let bar = P.bottomBar(size: dropBar, preferredMidY: landscape.maxY - P.dropBarLift, picture: landscape,
                              safe: landscapeSafe, avoiding: [tray] + groups)
        for control in [tray] + groups { XCTAssertFalse(bar.intersects(control), "\(control)") }
        XCTAssertTrue(landscapeSafe.contains(bar))
    }

    func testPadDropBarIsUnchangedWhereNothingCollides() {
        // A letterboxed 16:10 picture: the bar keeps its old place, 64 pt above the picture's bottom.
        let picture = CGRect(x: 0, y: 44.25, width: 1194, height: 746.25)
        let safe = padInsets.safeRect(in: pad.size)
        let bar = P.bottomBar(size: dropBar, preferredMidY: picture.maxY - P.dropBarLift, picture: picture,
                              safe: safe, avoiding: [CGRect(x: 1120, y: 300, width: 50, height: 240)])
        XCTAssertEqual(bar, CGRect(x: picture.midX - 202, y: picture.maxY - 64 - 22, width: 404, height: 44))
    }

    func testAFoldRunningTheWholeHeightDoesNotStopTheBarClearingTheGear() {
        // A division among the obstacles (iPhone Duo book pose) can't be cleared by moving up.
        let fold = CGRect(x: 195, y: 0, width: 40, height: 932)
        let g = gear(portrait, portraitInsets, portrait: true)
        let bar = P.bottomBar(size: dropBar, preferredMidY: portrait.maxY - P.dropBarLift, picture: portrait,
                              safe: portraitSafe, avoiding: [fold, g])
        XCTAssertFalse(bar.intersects(g))
        XCTAssertEqual(bar.maxY, g.minY - P.gap)
    }

    func testABarWithNoClearSpotStaysLowestInsideTheSafeArea() {
        let wall = CGRect(x: 0, y: 59, width: 430, height: 839)
        let bar = P.bottomBar(size: dropBar, preferredMidY: 900, picture: portrait, safe: portraitSafe, avoiding: [wall])
        XCTAssertEqual(bar.maxY, portraitSafe.maxY - P.gap)
    }

    func testArrangeBarClearsTheGear() {
        let g = gear(portrait, portraitInsets, portrait: true)
        let size = CGSize(width: 260, height: 36)
        let old = CGRect(x: portrait.midX - 130, y: portraitSafe.maxY - 44 - 18, width: 260, height: 36)
        XCTAssertTrue(old.intersects(g), "the old Arrange bar sat on the gear too")
        let bar = P.bottomBar(size: size, preferredMidY: portraitSafe.maxY - 44, picture: portrait,
                              safe: portraitSafe, avoiding: [g])
        XCTAssertFalse(bar.intersects(g))
        XCTAssertTrue(portraitSafe.contains(bar))
    }

    // MARK: Placement chip ("Pane · Circle to switch")

    func testTheOldChipSatUnderTheDynamicIsland() {
        let old = CGRect(x: portrait.midX - chipSize.width / 2, y: portrait.minY + 34 - chipSize.height / 2,
                         width: chipSize.width, height: chipSize.height)
        XCTAssertTrue(old.intersects(island))
    }

    func testPortraitChipIsBelowTheDynamicIslandAndCentred() {
        let chip = P.chip(size: chipSize, picture: portrait, safe: portraitSafe, avoiding: [])
        XCTAssertFalse(chip.intersects(island))
        XCTAssertEqual(chip.minY, portraitSafe.minY + P.gap)
        XCTAssertEqual(chip.midX, portrait.midX)
    }

    func testChipSlidesBesideATitleWhenTheRowHasRoom() {
        // A pane above another: its label strip at the top left, below the Island.
        let title = CGRect(x: 0, y: 59, width: 120, height: P.paneTitleHeight)
        let chip = P.chip(size: chipSize, picture: portrait, safe: portraitSafe, avoiding: [title])
        XCTAssertFalse(chip.insetBy(dx: -7, dy: -7).intersects(title))
        XCTAssertEqual(chip.minY, portraitSafe.minY + P.gap, "same row")
        XCTAssertFalse(chip.intersects(island))
        XCTAssertTrue(portraitSafe.contains(chip))
    }

    func testChipStepsBelowTitlesWhenTheRowHasNoRoom() {
        // Two panes side by side (screenshot 1): a title at the top of each.
        let titles = [CGRect(x: 0, y: 59, width: 94, height: 40), CGRect(x: 215, y: 59, width: 110, height: 40)]
        let chip = P.chip(size: chipSize, picture: portrait, safe: portraitSafe, avoiding: titles)
        for t in titles { XCTAssertFalse(chip.intersects(t)) }
        XCTAssertEqual(chip.minY, 99 + P.gap)
        XCTAssertEqual(chip.midX, portrait.midX)
    }

    func testLandscapeChipIsInsideTheSafeAreaOnEitherIslandSide() {
        for side in [LandscapeTraySide.leading, .trailing] {
            let chip = P.chip(size: chipSize, picture: landscape, safe: landscapeSafe, avoiding: [])
            XCTAssertTrue(landscapeSafe.contains(chip))
            XCTAssertFalse(chip.intersects(islandBand(side)))
            XCTAssertEqual(chip.midY, 34, "nothing unsafe at the top in landscape: where it always was")
        }
    }

    func testPadChipKeepsItsPlaceBelowALetterboxedPictureTopAndClearsTheStatusBarOtherwise() {
        let letterboxed = CGRect(x: 0, y: 44.25, width: 1194, height: 746.25)
        let safe = padInsets.safeRect(in: pad.size)
        XCTAssertEqual(P.chip(size: chipSize, picture: letterboxed, safe: safe, avoiding: []).midY, letterboxed.minY + 34)
        let full = P.chip(size: chipSize, picture: pad, safe: safe, avoiding: [])
        XCTAssertGreaterThanOrEqual(full.minY, 24 + P.gap)
    }

    func testWithoutASafeAreaTheChipIsWhereItWas() {
        // The Mac Receiver passes none.
        let picture = CGRect(x: 0, y: 0, width: 1280, height: 800)
        XCTAssertEqual(P.chip(size: chipSize, picture: picture, safe: nil, avoiding: []).midY, 34)
    }

    // MARK: First-use circling tip

    func testTheOldTipReachedUnderTheIslandAndOverAPaneTitle() {
        // Screenshot 1: centred at the safe top + 44, about 120 pt tall.
        let old = CGRect(x: 16, y: 59 + 44 - 60, width: 398, height: 120)
        XCTAssertTrue(old.minY < portraitSafe.minY)
        XCTAssertTrue(old.intersects(CGRect(x: 0, y: 59, width: 94, height: 40)))
    }

    func testPortraitTipIsInsideTheSafeAreaClearOfTheChipAndTitles() {
        let titles = [CGRect(x: 0, y: 59, width: 94, height: 40), CGRect(x: 215, y: 59, width: 110, height: 40)]
        let chip = P.chip(size: chipSize, picture: portrait, safe: portraitSafe, avoiding: titles)
        let tip = P.tip(size: CGSize(width: 398, height: 120), picture: portrait, safe: portraitSafe,
                        chip: chip, avoiding: titles)
        XCTAssertTrue(portraitSafe.contains(tip))
        XCTAssertFalse(tip.intersects(chip))
        for t in titles { XCTAssertFalse(tip.intersects(t)) }
        XCTAssertFalse(tip.intersects(island))
    }

    func testTipClearsAFloatPillNearTheTop() {
        let pill = P.floatPill(content: CGRect(x: 40, y: 140, width: 300, height: 220), size: CGSize(width: 306, height: 30),
                               safe: portraitSafe, picture: portrait)
        let chip = P.chip(size: chipSize, picture: portrait, safe: portraitSafe, avoiding: [pill])
        let tip = P.tip(size: CGSize(width: 398, height: 120), picture: portrait, safe: portraitSafe,
                        chip: chip, avoiding: [pill])
        XCTAssertFalse(tip.intersects(pill))
        XCTAssertFalse(tip.intersects(chip))
        XCTAssertTrue(portraitSafe.contains(tip))
    }

    func testLandscapeTipIsInsideTheSafeArea() {
        let chip = P.chip(size: chipSize, picture: landscape, safe: landscapeSafe, avoiding: [])
        let tip = P.tip(size: CGSize(width: 440, height: 70), picture: landscape, safe: landscapeSafe,
                        chip: chip, avoiding: [])
        XCTAssertTrue(landscapeSafe.contains(tip))
        XCTAssertFalse(tip.intersects(chip))
        for side in [LandscapeTraySide.leading, .trailing] { XCTAssertFalse(tip.intersects(islandBand(side))) }
    }

    // MARK: Floats' title pills

    func testAPillUnderTheDynamicIslandMovesIntoTheSafeAreaOnTheFloat() {
        // A float resting at the top: `WorkspaceFloatGeometry.clamped` allows its content at 30 pt.
        let content = CGRect(x: 100, y: 30, width: 230, height: 200)
        let size = pillSize(content)
        let raw = CGRect(x: content.midX - size.width / 2, y: content.minY - size.height / 2, width: size.width, height: size.height)
        XCTAssertTrue(raw.intersects(island), "where it was")
        let pill = P.floatPill(content: content, size: size, safe: portraitSafe, picture: portrait)
        XCTAssertFalse(pill.intersects(island))
        XCTAssertGreaterThanOrEqual(pill.minY, portraitSafe.minY)
        XCTAssertEqual(pill.midX, content.midX)
        XCTAssertTrue(content.contains(CGPoint(x: pill.midX, y: pill.midY)), "still on its float")
    }

    func testAPillBesideTheIslandInLandscapeMovesAlongTheTopEdge() {
        for side in [LandscapeTraySide.leading, .trailing] {
            let content = side == .leading ? CGRect(x: 0, y: 150, width: 240, height: 160)
                                           : CGRect(x: 692, y: 150, width: 240, height: 160)
            let size = pillSize(content)
            let pill = P.floatPill(content: content, size: size, safe: landscapeSafe, picture: landscape)
            XCTAssertFalse(pill.intersects(islandBand(side)), "\(side)")
            XCTAssertEqual(pill.midY, content.minY, "still on the top edge")
            XCTAssertTrue(landscapeSafe.contains(pill))
        }
    }

    func testAPillInsideTheSafeAreaIsUntouched() {
        let content = CGRect(x: 60, y: 300, width: 300, height: 200)
        let size = pillSize(content)
        XCTAssertEqual(P.floatPill(content: content, size: size, safe: portraitSafe, picture: portrait),
                       CGRect(x: content.midX - size.width / 2, y: 300 - size.height / 2, width: size.width, height: size.height))
        XCTAssertEqual(P.floatPill(content: content, size: size, safe: nil, picture: portrait).midY, 300)
    }

    func testAPillNeverLeavesItsFloat() {
        // The shortest float a phone allows (80 pt), resting as high as it may: the pill goes no
        // lower than the float's own bottom.
        let content = CGRect(x: 100, y: 30, width: 200, height: 80)
        let pill = P.floatPill(content: content, size: CGSize(width: 206, height: 30), safe: portraitSafe, picture: portrait)
        XCTAssertLessThanOrEqual(pill.midY, content.maxY)
        XCTAssertGreaterThanOrEqual(pill.midY, content.minY)
    }

    func testAPillMovesWithAFloatComingInPastTheTopEdge() {
        // Restoring out of a top-edge tuck: the pill keeps the place it has at the edge, moving
        // with the float instead of sliding over it, and nothing jumps where it crosses the edge.
        let size = CGSize(width: 206, height: 30)
        func offset(_ y: CGFloat) -> CGFloat {
            let content = CGRect(x: 100, y: y, width: 200, height: 180)
            return P.floatPill(content: content, size: size, safe: portraitSafe, picture: portrait).midY - content.minY
        }
        XCTAssertEqual(offset(-150), offset(-40))
        XCTAssertEqual(offset(-40), offset(0))
        XCTAssertEqual(offset(-0.001), offset(0), accuracy: 0.01)
        XCTAssertEqual(offset(0), portraitSafe.minY + 15, "at the edge: just inside the safe area")
    }

    func testAPillMovesWithAFloatComingInPastASideEdge() {
        let size = CGSize(width: 206, height: 30)
        // Portrait: nothing unsafe at the sides, the pill stays centred on the float, off screen with it.
        for x: CGFloat in [-150, 330] {
            let content = CGRect(x: x, y: 300, width: 250, height: 180)
            XCTAssertEqual(P.floatPill(content: content, size: size, safe: portraitSafe, picture: portrait).midX, content.midX)
        }
        // Landscape, the Island's side: inside the safe area at the edge, then with the float.
        func offset(_ x: CGFloat) -> CGFloat {
            let content = CGRect(x: x, y: 150, width: 240, height: 160)
            return P.floatPill(content: content, size: size, safe: landscapeSafe, picture: landscape).midX - content.midX
        }
        XCTAssertEqual(offset(-200), offset(0))
        XCTAssertEqual(offset(-0.001), offset(0), accuracy: 0.01)
        let atEdge = P.floatPill(content: CGRect(x: 0, y: 150, width: 240, height: 160), size: size,
                                 safe: landscapeSafe, picture: landscape)
        XCTAssertEqual(atEdge.minX, landscapeSafe.minX, "at the edge: just inside the safe area")
    }

    // MARK: Floats' grabbers

    private func grabber(_ content: CGRect) -> CGRect {
        let y = P.grabberMidY(content: content, picture: portrait, safe: portraitSafe)
        return CGRect(x: content.midX - 38, y: y - 14, width: 76, height: 28)
    }

    func testTheOldGrabberSatOnTheHomeIndicator() {
        // Below the float whenever the picture's bottom left room: here, on the Home indicator.
        let content = CGRect(x: 100, y: 600, width: 230, height: 300)
        let old = content.maxY + 12 <= portrait.maxY - 4 ? content.maxY + 10 : content.maxY - 10
        XCTAssertTrue(CGRect(x: content.midX - 38, y: old - 14, width: 76, height: 28).intersects(homeIndicator))
        XCTAssertLessThanOrEqual(grabber(content).maxY, homeIndicator.minY)
    }

    func testAGrabberWithRoomStaysBelowItsFloat() {
        let content = CGRect(x: 100, y: 300, width: 230, height: 300)
        XCTAssertEqual(P.grabberMidY(content: content, picture: portrait, safe: portraitSafe), content.maxY + 10)
        XCTAssertEqual(P.grabberMidY(content: content, picture: portrait, safe: nil), content.maxY + 10)
    }

    func testAFloatRestingAtTheBottomKeepsItsGrabberAboveTheHomeIndicator() {
        let content = CGRect(x: 100, y: 632, width: 230, height: 300)
        let g = grabber(content)
        XCTAssertLessThanOrEqual(g.maxY, portraitSafe.maxY)
        XCTAssertTrue(content.contains(CGPoint(x: g.midX, y: g.midY)), "inside the float")
    }

    func testAGrabberMovesWithAFloatComingInPastTheBottomEdge() {
        func offset(_ y: CGFloat) -> CGFloat {
            let content = CGRect(x: 100, y: y, width: 230, height: 300)
            return P.grabberMidY(content: content, picture: portrait, safe: portraitSafe) - content.maxY
        }
        XCTAssertEqual(offset(900), offset(700))
        XCTAssertEqual(offset(632.001), offset(632), accuracy: 0.01)
    }
}
