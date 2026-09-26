import XCTest

/// Every Maximum FPS picker (the Mac's per-device control, the iPhone app,
/// the Mac receiver) offers only the tiers reachable right now, while the
/// preference keeps whatever was chosen. SwiftUI requires the selection to
/// be one of the tags, so the shown tier is derived — and must never
/// rewrite the preference just by being shown.
final class MaxFPSPickerTests: XCTestCase {
    private let allTiers = EncoderCapability.supportedFPSTiers

    private func preference(_ fps: Int) -> ReceiverMaxFPSPreference {
        ReceiverMaxFPSPreference(enabled: true, maxFPS: fps)
    }

    // MARK: - PickerSelection.ceiling

    func testOfferedValueIsShownAsIs() {
        for tier in allTiers {
            XCTAssertEqual(PickerSelection.ceiling(tier, among: allTiers), tier)
        }
    }

    func testHiddenCeilingShowsTheHighestOfferedTierBelowIt() {
        XCTAssertEqual(PickerSelection.ceiling(120, among: [1, 5, 10, 24, 30, 60]), 60, "120 on a 60 Hz display")
        XCTAssertEqual(PickerSelection.ceiling(60, among: [1, 5, 10, 24, 30]), 30, "encode size too large for 60")
        XCTAssertEqual(PickerSelection.ceiling(90, among: allTiers), 60, "a non-tier value from the wire")
    }

    func testCeilingBelowEveryTagShowsTheLowestTag() {
        XCTAssertEqual(PickerSelection.ceiling(3, among: [30, 5, 60]), 5)
    }

    func testNoTagsLeavesTheStoredValue() {
        XCTAssertEqual(PickerSelection.ceiling(120, among: [Int]()), 120)
    }

    func testShownValueIsAlwaysATag() {
        let tagSets = [allTiers, [1, 5, 10, 24, 30, 60], [1, 5, 10, 24, 30], [1], [60, 30], [24, 120]]
        for tags in tagSets {
            for stored in 1...240 {
                XCTAssertTrue(tags.contains(PickerSelection.ceiling(stored, among: tags)), "\(stored) in \(tags)")
            }
        }
    }

    // MARK: - Mac per-device picker (ReceiverDeviceDetailView)

    /// The exact tags and selection the Mac's view builds for a 60 Hz device.
    func testMacPickerOnASixtyHertzDevice() {
        let tiers = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 60, encoderSafeFPS: 120)
        XCTAssertEqual(tiers, [1, 5, 10, 24, 30, 60])
        XCTAssertEqual(MaxFPSPicker.selection(preference(120), among: tiers), 60)
        XCTAssertEqual(MaxFPSPicker.selection(preference(30), among: tiers), 30)
    }

    /// An encode size whose safe rate is 118 hides 120 even on ProMotion.
    func testMacPickerWhenTheEncodeSizeCapsTheRate() {
        let tiers = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 120, encoderSafeFPS: 118)
        XCTAssertFalse(tiers.contains(120))
        XCTAssertEqual(MaxFPSPicker.selection(preference(120), among: tiers), 60)
    }

    // MARK: - Receiver pickers (iPhone app, Mac receiver)

    func testReceiverOffersEveryTierUntilTheMacReportsSome() {
        XCTAssertEqual(MaxFPSPicker.tiers(reported: nil), allTiers)
        XCTAssertEqual(MaxFPSPicker.tiers(reported: []), allTiers, "an empty report must not empty the picker")
        XCTAssertEqual(MaxFPSPicker.tiers(reported: [1, 5, 10, 24, 30, 60]), [1, 5, 10, 24, 30, 60])
    }

    func testReceiverSelectionIsAlwaysOfferedAndThePreferenceStaysPut() {
        let stored = preference(120)
        for reported in [nil, [], [1, 5, 10, 24, 30, 60], [1, 5, 10, 24, 30], allTiers] as [[Int]?] {
            let tiers = MaxFPSPicker.tiers(reported: reported)
            XCTAssertTrue(tiers.contains(MaxFPSPicker.selection(stored, among: tiers)), "\(String(describing: reported))")
        }
        XCTAssertEqual(stored.maxFPS, 120)
        // The remembered choice comes back when its tier does.
        XCTAssertEqual(MaxFPSPicker.selection(stored, among: MaxFPSPicker.tiers(reported: [1, 5, 10, 24, 30, 60])), 60)
        XCTAssertEqual(MaxFPSPicker.selection(stored, among: MaxFPSPicker.tiers(reported: allTiers)), 120)
    }
}
