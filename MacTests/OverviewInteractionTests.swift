import CoreGraphics
import Foundation
import XCTest

/// Pure-logic coverage for the full-screen Multi-Display Overview's gesture reducer: what pans,
/// pinches, taps and double-taps do to the camera and the selection, zoom limits and the recovery
/// button's visibility.
final class OverviewInteractionTests: XCTestCase {

    private let viewport = CGSize(width: 400, height: 700)
    private let viewScale = 3.0

    /// Two real displays side by side and this device's own display under the first:
    /// bounds 3840 x 1980, with an empty corner under the second display.
    private func makeModel() -> DisplayOverviewModel {
        DisplayOverviewModel(displays: [
            OverviewDisplay(id: 1, name: "Studio", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2, isMain: true),
            OverviewDisplay(id: 2, name: "Side", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 2),
            OverviewDisplay(id: 3, name: "iPhone", frame: CGRect(x: 0, y: 1080, width: 1440, height: 900),
                            isVirtual: true, isMeow: true, isOwn: true),
        ])
    }

    /// Four 4K displays in a row: far wider than tall, so fit-all is tiny.
    private func makeWideModel() -> DisplayOverviewModel {
        DisplayOverviewModel(displays: (0..<4).map { index in
            OverviewDisplay(id: UInt32(index + 1), name: "Wall \(index + 1)",
                            frame: CGRect(x: CGFloat(index) * 3840, y: 0, width: 3840, height: 2160),
                            scale: 2, isMain: index == 0)
        })
    }

    private func makeInteraction(_ model: DisplayOverviewModel? = nil) -> OverviewInteraction {
        OverviewInteraction(model: model ?? makeModel(), viewport: viewport, viewDisplayScale: viewScale)
    }

    private var viewCentre: CGPoint { CGPoint(x: viewport.width / 2, y: viewport.height / 2) }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: Double = 1e-6,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(actual.x), Double(expected.x), accuracy: accuracy, "x \(message)", file: file, line: line)
        XCTAssertEqual(Double(actual.y), Double(expected.y), accuracy: accuracy, "y \(message)", file: file, line: line)
    }

    /// The view point where `world` is drawn now.
    private func viewPoint(_ interaction: OverviewInteraction, world: CGPoint) -> CGPoint {
        interaction.camera.viewPoint(world: world, viewport: interaction.viewport)
    }

    // MARK: Start

    func testStartsFramedOnTheWholeArrangement() {
        let interaction = makeInteraction()
        XCTAssertEqual(interaction.camera, interaction.fitAllCamera)
        XCTAssertTrue(interaction.isArrangementVisible)
        XCTAssertFalse(interaction.showsRecovery)
        XCTAssertEqual(interaction.model.selected, 1, "the main display starts selected")
    }

    func testNoViewportYetNeverOffersRecovery() {
        let interaction = OverviewInteraction(model: makeModel(), viewDisplayScale: viewScale)
        XCTAssertFalse(interaction.showsRecovery)
    }

    func testOverviewRequestsOneBoundedSharpStillOnlyAtHigherZoom() {
        var interaction = makeInteraction()
        XCTAssertNil(interaction.detailRequest)
        let focal = viewPoint(interaction, world: CGPoint(x: 960, y: 540))
        interaction.pinch(factor: 4, focal: focal)
        XCTAssertEqual(interaction.detailRequest, OverviewDisplayDetailRequest(id: 1, maxSide: 1600))
        interaction.pan(byView: CGPoint(x: 80_000, y: 80_000))
        XCTAssertNil(interaction.detailRequest)
        interaction.fitAll()
        XCTAssertNil(interaction.detailRequest)
    }

    func testDetailThumbnailWireRejectsUnboundedImagesAndUnknownSizes() {
        let request = OverviewDisplayDetailRequest(id: 7, maxSide: 1600)
        XCTAssertEqual(OverviewDisplayDetailRequest.parse(request.wire), request)
        XCTAssertNil(OverviewDisplayDetailRequest.parse(["id": 7, "maxSide": 32_000]))
        let overBudget = String(repeating: "A", count: OverviewDisplayDetailRequest.maxBase64 + 4)
        XCTAssertNil(WorkspaceEvent.parse(type: WireMessage.displayThumbnail,
                                          ["id": 7, "detail": 1600, "jpeg": overBudget]))
    }

    // MARK: Pinch

    func testPinchKeepsTheWorldPointUnderTheFocalPoint() {
        var interaction = makeInteraction()
        let focal = CGPoint(x: 120, y: 500)
        let world = interaction.camera.worldPoint(view: focal, viewport: viewport)
        let before = interaction.camera.scale

        interaction.pinch(factor: 1.8, focal: focal)

        XCTAssertEqual(interaction.camera.scale, before * 1.8, accuracy: 1e-12)
        assertPoint(viewPoint(interaction, world: world), focal)
    }

    func testPinchAnchorHoldsAcrossRepeatedStepsAndZoomOut() {
        var interaction = makeInteraction()
        let focal = CGPoint(x: 330, y: 90)
        let world = interaction.camera.worldPoint(view: focal, viewport: viewport)

        for factor in [1.3, 1.3, 0.8, 2.0, 0.9] { interaction.pinch(factor: factor, focal: focal) }

        assertPoint(viewPoint(interaction, world: world), focal)
    }

    func testPinchWithMovingFocalPointDragsTheContentAlong() {
        var interaction = makeInteraction()
        let start = CGPoint(x: 120, y: 500)
        let now = CGPoint(x: 150, y: 470)
        let world = interaction.camera.worldPoint(view: start, viewport: viewport)

        interaction.pinch(factor: 2, focal: now, focalTranslation: CGVector(dx: 30, dy: -30))

        assertPoint(viewPoint(interaction, world: world), now)
    }

    func testPinchIgnoresNonsenseFactors() {
        var interaction = makeInteraction()
        let camera = interaction.camera
        interaction.pinch(factor: .nan, focal: viewCentre)
        interaction.pinch(factor: 0, focal: viewCentre)
        interaction.pinch(factor: -2, focal: viewCentre)
        XCTAssertEqual(interaction.camera.scale, camera.scale)
    }

    // MARK: Zoom limits

    func testZoomInIsClampedToTheLimit() {
        var interaction = makeInteraction()
        interaction.pinch(factor: 1e9, focal: viewCentre)
        XCTAssertEqual(interaction.camera.scale, interaction.zoomLimits.max, accuracy: 1e-9)
    }

    func testZoomOutIsClampedToHalfOfFitAll() {
        var interaction = makeInteraction()
        let fit = interaction.fitAllCamera.scale
        interaction.pinch(factor: 1e-9, focal: viewCentre)
        XCTAssertEqual(interaction.camera.scale, 0.5 * fit, accuracy: 1e-12)
    }

    func testLimitsUseTheSelectedDisplaysDensityAndTheScreenScale() {
        var interaction = makeInteraction()
        // A Retina display shown on a 3x screen: one source pixel is 2/3 of a view point.
        XCTAssertEqual(interaction.zoomLimits.max, 8 * 2.0 / 3.0, accuracy: 1e-12)
        interaction.select(id: 2)
        XCTAssertEqual(interaction.zoomLimits.max, 8 * 2.0 / 3.0, accuracy: 1e-12)
    }

    func testDeepZoomGoesFarBeyondEightTimesFitAllOnAWideArrangement() {
        var interaction = makeInteraction(makeWideModel())
        let fit = interaction.fitAllCamera.scale
        interaction.pinch(factor: 1e9, focal: viewCentre)
        XCTAssertGreaterThan(interaction.camera.scale, 8 * fit * 10, "deep zoom is not capped at 8x fit-all")
        XCTAssertEqual(interaction.camera.scale, 8 * 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: Pan

    func testPanIsNotClamped() {
        var interaction = makeInteraction()
        let world = interaction.camera.worldPoint(view: viewCentre, viewport: viewport)

        interaction.pan(byView: CGVector(dx: 1_000_000, dy: -250_000))

        assertPoint(viewPoint(interaction, world: world),
                    CGPoint(x: viewCentre.x + 1_000_000, y: viewCentre.y - 250_000), accuracy: 1e-3)
    }

    func testPanFollowsTheFinger() {
        var interaction = makeInteraction()
        let world = CGPoint(x: 960, y: 540)
        let before = viewPoint(interaction, world: world)

        interaction.pan(byView: CGVector(dx: 25, dy: -40))

        assertPoint(viewPoint(interaction, world: world), CGPoint(x: before.x + 25, y: before.y - 40))
    }

    // MARK: Taps

    func testTapSelectsARealDisplayAndKeepsTheCamera() {
        var interaction = makeInteraction()
        let camera = interaction.camera
        let outcome = interaction.tap(atView: viewPoint(interaction, world: CGPoint(x: 2880, y: 540)))
        XCTAssertEqual(outcome, .selected(2))
        XCTAssertEqual(interaction.model.selected, 2)
        XCTAssertEqual(interaction.camera, camera)
    }

    func testDoubleTapOnADisplayZoomsToIt() {
        var interaction = makeInteraction()
        let fit = interaction.fitAllCamera.scale
        let outcome = interaction.doubleTap(atView: viewPoint(interaction, world: CGPoint(x: 2880, y: 540)))

        XCTAssertEqual(outcome, .zoomedToDisplay(2))
        XCTAssertEqual(interaction.model.selected, 2)
        XCTAssertGreaterThan(interaction.camera.scale, fit)
        let rect = interaction.viewRect(of: interaction.model.display(withID: 2)!)
        assertPoint(CGPoint(x: rect.midX, y: rect.midY), viewCentre, accuracy: 1e-6)
        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(rect), "the whole display is in view")
    }

    func testDoubleTapOnEmptySpaceFitsAll() {
        var interaction = makeInteraction()
        interaction.doubleTap(atView: viewPoint(interaction, world: CGPoint(x: 2880, y: 540)))
        XCTAssertNotEqual(interaction.camera, interaction.fitAllCamera)

        // Far outside the arrangement.
        let outcome = interaction.doubleTap(atView: viewPoint(interaction, world: CGPoint(x: 100_000, y: 100_000)))

        XCTAssertEqual(outcome, .fitAll)
        XCTAssertEqual(interaction.camera, interaction.fitAllCamera)
    }

    func testSingleTapOnEmptySpaceDoesNothing() {
        var interaction = makeInteraction()
        let before = interaction
        XCTAssertEqual(interaction.tap(atView: viewPoint(interaction, world: CGPoint(x: 100_000, y: 100_000))), .none)
        XCTAssertEqual(interaction, before)
    }

    func testPlaceholdersAbsorbTapsAndDoubleTaps() {
        var interaction = makeInteraction()
        let camera = interaction.camera
        let onPlaceholder = viewPoint(interaction, world: CGPoint(x: 720, y: 1500))
        XCTAssertEqual(interaction.target(atView: onPlaceholder), .placeholder(3))

        XCTAssertEqual(interaction.tap(atView: onPlaceholder), .absorbed)
        XCTAssertEqual(interaction.doubleTap(atView: onPlaceholder), .absorbed)

        XCTAssertEqual(interaction.model.selected, 1, "a placeholder is never selected by touch")
        XCTAssertEqual(interaction.camera, camera, "and a double-tap on it is not Fit All")
    }

    func testTargetsDistinguishDisplaysPlaceholdersAndEmptySpace() {
        let interaction = makeInteraction()
        XCTAssertEqual(interaction.target(atView: viewPoint(interaction, world: CGPoint(x: 10, y: 10))), .display(1))
        XCTAssertEqual(interaction.target(atView: viewPoint(interaction, world: CGPoint(x: 2000, y: 10))), .display(2))
        XCTAssertEqual(interaction.target(atView: viewPoint(interaction, world: CGPoint(x: 10, y: 1500))), .placeholder(3))
        XCTAssertEqual(interaction.target(atView: viewPoint(interaction, world: CGPoint(x: 3000, y: 1500))), .emptySpace)
    }

    // MARK: Recovery

    func testRecoveryAppearsAfterPanningEverythingAwayAndFitAllRestores() {
        var interaction = makeInteraction()
        XCTAssertFalse(interaction.showsRecovery)

        interaction.pan(byView: CGVector(dx: 200_000, dy: 0))
        XCTAssertFalse(interaction.isArrangementVisible)
        XCTAssertTrue(interaction.showsRecovery)

        interaction.fitAll()
        XCTAssertTrue(interaction.isArrangementVisible)
        XCTAssertFalse(interaction.showsRecovery)
        XCTAssertEqual(interaction.camera, interaction.fitAllCamera)
    }

    func testZoomingOutToTheLimitKeepsTheArrangementVisible() {
        var interaction = makeInteraction()
        interaction.pinch(factor: 1e-9, focal: viewCentre)
        XCTAssertFalse(interaction.showsRecovery)
    }

    // MARK: Selection

    func testSelectingNextAndPreviousFramesTheDisplayAndWraps() {
        var interaction = makeInteraction()

        interaction.select(.next)
        XCTAssertEqual(interaction.model.selected, 2)
        var rect = interaction.viewRect(of: interaction.model.display(withID: 2)!)
        assertPoint(CGPoint(x: rect.midX, y: rect.midY), viewCentre)
        XCTAssertTrue(interaction.selectionCanBeShown)

        interaction.select(.next)
        XCTAssertEqual(interaction.model.selected, 3)
        XCTAssertFalse(interaction.selectionCanBeShown, "this device's own display has no pane actions")
        rect = interaction.viewRect(of: interaction.model.display(withID: 3)!)
        assertPoint(CGPoint(x: rect.midX, y: rect.midY), viewCentre)

        interaction.select(.next)
        XCTAssertEqual(interaction.model.selected, 1)
        interaction.select(.previous)
        XCTAssertEqual(interaction.model.selected, 3)
    }

    // MARK: Layout and catalog updates

    func testViewportChangeRefitsOnlyWhileTheCameraWasNeverMoved() {
        var following = makeInteraction()
        following.updateLayout(viewport: CGSize(width: 800, height: 400))
        XCTAssertEqual(following.camera, following.fitAllCamera)

        var moved = makeInteraction()
        moved.pan(byView: CGVector(dx: 40, dy: 10))
        let camera = moved.camera
        moved.updateLayout(viewport: CGSize(width: 800, height: 400))
        XCTAssertEqual(moved.camera, camera)
    }

    /// A fold, unfold or rotation while the overview is open: a tap right after it lands on the tile
    /// drawn under the finger in the NEW layout, whether the camera refits or was moved before.
    func testATapAfterAViewportChangeHitsTheTileDrawnThere() {
        for moveFirst in [false, true] {
            var interaction = makeInteraction()
            if moveFirst { interaction.pan(byView: CGVector(dx: 30, dy: -20)) }
            interaction.updateLayout(viewport: CGSize(width: 820, height: 1180))
            interaction.tap(atView: viewPoint(interaction, world: CGPoint(x: 2880, y: 540)))
            XCTAssertEqual(interaction.model.selected, 2, "moved first: \(moveFirst)")
            interaction.updateLayout(viewport: CGSize(width: 1180, height: 820))
            interaction.tap(atView: viewPoint(interaction, world: CGPoint(x: 960, y: 540)))
            XCTAssertEqual(interaction.model.selected, 1, "moved first: \(moveFirst)")
        }
    }

    func testCatalogRefreshKeepsSelectionAndCamera() {
        var interaction = makeInteraction()
        interaction.tap(atView: viewPoint(interaction, world: CGPoint(x: 2880, y: 540)))
        interaction.pan(byView: CGVector(dx: 15, dy: 15))
        let camera = interaction.camera

        let extra = OverviewDisplay(id: 4, name: "Extra", frame: CGRect(x: 3840, y: 0, width: 1280, height: 720), scale: 1)
        interaction.update(model: DisplayOverviewModel(displays: makeModel().displays + [extra]))

        XCTAssertEqual(interaction.model.selected, 2)
        XCTAssertEqual(interaction.model.drawnDisplays.count, 4)
        XCTAssertEqual(interaction.camera, camera)
    }

    func testUnchangedCatalogIsIgnored() {
        var interaction = makeInteraction()
        interaction.select(id: 2)
        let before = interaction
        interaction.update(model: makeModel())
        XCTAssertEqual(interaction, before)
    }

    func testSelectionFallsBackWhenItsDisplayDisappears() {
        var interaction = makeInteraction()
        interaction.select(id: 2)
        let withoutSecond = DisplayOverviewModel(displays: makeModel().displays.filter { $0.id != 2 })
        interaction.update(model: withoutSecond)
        XCTAssertEqual(interaction.model.selected, 1)
    }

    // MARK: Labels

    func testLabelSizeIsReadableOnSmallTilesAndCappedOnLargeOnes() {
        XCTAssertEqual(OverviewInteraction.labelPointSize(forTileHeight: 0), 10)
        XCTAssertEqual(OverviewInteraction.labelPointSize(forTileHeight: 196), 14, accuracy: 1e-9)
        XCTAssertEqual(OverviewInteraction.labelPointSize(forTileHeight: 100_000), 18)
        XCTAssertEqual(OverviewInteraction.labelPointSize(forTileHeight: .nan), 10)
    }

    func testVisiblePartOfAHugeTileIsClippedToTheViewport() {
        let interaction = makeInteraction()
        let visible = interaction.visibleRect(of: CGRect(x: -5000, y: -5000, width: 10_000, height: 10_000))
        XCTAssertEqual(visible, CGRect(origin: .zero, size: viewport))
    }
}
