import XCTest

/// The sidebar selection bug (rows rendering but clicks never changing the
/// detail page) was a `List(selection:)` wiring defect in `MacSettingsView`,
/// not a data problem — but a distinct `id` per case, matching `rawValue`,
/// is the precondition `List(selection:)`/`.tag(_:)` selection relies on, so
/// it's worth locking down here.
final class SettingsCategoryTests: XCTestCase {
    func testEveryCategoryHasAUniqueStableID() {
        let ids = SettingsCategory.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate SettingsCategory ids would break List selection")
    }

    func testIDMatchesRawValue() {
        for category in SettingsCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }

    func testOverviewIsTheFirstCategory() {
        // The default selection (`MacSettingsView`'s initial `selection`
        // state) must be a real case in `allCases` or the sidebar opens
        // with nothing highlighted.
        XCTAssertEqual(SettingsCategory.allCases.first, .overview)
    }

    func testDeveloperOnlyExistsInDebugBuilds() {
        #if DEBUG
        XCTAssertTrue(SettingsCategory.allCases.contains(.developer))
        #else
        XCTAssertFalse(SettingsCategory.allCases.map(\.rawValue).contains("developer"))
        #endif
    }

    func testEveryCategoryHasANonEmptyLabelAndSystemImage() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }
}
