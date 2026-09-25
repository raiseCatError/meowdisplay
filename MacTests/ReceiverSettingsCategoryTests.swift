import XCTest

/// Mac Receiver Settings sidebar: the category set, its search index, and
/// the Back/Forward history (same semantics as Mac Sender's).
final class ReceiverSettingsCategoryTests: XCTestCase {
    func testCategoriesHaveUniqueStableIDs() {
        let ids = ReceiverSettingsCategory.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for category in ReceiverSettingsCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
        XCTAssertEqual(ReceiverSettingsCategory.allCases.first, .overview)
    }

    /// Display-only: the receiving Mac's keyboard/trackpad are not forwarded,
    /// so there must be no Input page to imply otherwise.
    func testThereIsNoInputCategory() {
        XCTAssertFalse(ReceiverSettingsCategory.allCases.map(\.rawValue).contains("input"))
    }

    func testDeveloperOnlyExistsInDebugBuilds() {
        #if DEBUG
        XCTAssertTrue(ReceiverSettingsCategory.allCases.contains(.developer))
        #else
        XCTAssertFalse(ReceiverSettingsCategory.allCases.map(\.rawValue).contains("developer"))
        #endif
    }

    func testSharedCategoriesMatchSenderNamesAndSymbols() {
        for category in ReceiverSettingsCategory.allCases {
            guard let sender = SettingsCategory(rawValue: category.rawValue) else {
                return XCTFail("\(category) has no Mac Sender counterpart")
            }
            XCTAssertEqual(category.label, sender.label)
            XCTAssertEqual(category.systemImage, sender.systemImage)
        }
    }

    func testSearchIDsAreUnique() {
        let ids = ReceiverSettingsSearchIndex.shared.allItems.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testSearchFindsReceiverSettingsOnTheirPages() {
        let index = ReceiverSettingsSearchIndex.shared
        XCTAssertEqual(index.search(query: "A/V Sync").first?.category, .streaming)
        XCTAssertEqual(index.search(query: "resync").first?.category, .streaming)
        XCTAssertEqual(index.search(query: "Mirror Display").first?.category, .displays)
        XCTAssertEqual(index.search(query: "use full display").first?.category, .displays)
        XCTAssertEqual(index.search(query: "full screen").first?.category, .displays)
        XCTAssertEqual(index.search(query: "forget").first?.category, .devices)
        XCTAssertEqual(index.search(query: "tailscale").first?.category, .remoteAccess)
        XCTAssertEqual(index.search(query: "Performance Overlay").first?.category, .system)
        XCTAssertEqual(index.search(query: "logs").first?.category, .system)
    }

    func testTopLevelCategoryRanksFirstForItsOwnName() {
        let first = ReceiverSettingsSearchIndex.shared.search(query: "Streaming").first
        XCTAssertEqual(first?.id, "category.streaming")
        XCTAssertNil(first?.subtitle)
    }

    func testSearchNeverOffersSenderOnlySettings() {
        let index = ReceiverSettingsSearchIndex.shared
        XCTAssertTrue(index.search(query: "caffeinate").isEmpty)
        XCTAssertTrue(index.search(query: "accessibility").isEmpty)
        XCTAssertTrue(index.search(query: "Allow Input").isEmpty)
    }

    func testBlankAndUnknownQueriesReturnNothing() {
        let index = ReceiverSettingsSearchIndex.shared
        XCTAssertTrue(index.search(query: "   ").isEmpty)
        XCTAssertTrue(index.search(query: "zzqxv").isEmpty)
    }

    @MainActor
    func testNavigationHistory() {
        let nav = ReceiverSettingsNavigationModel()
        XCTAssertEqual(nav.current, .overview)
        XCTAssertFalse(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)

        nav.navigateTo(.displays)
        nav.navigateTo(.streaming)
        nav.navigateTo(.streaming)
        XCTAssertEqual(nav.backStack, [.overview, .displays])

        nav.goBack()
        XCTAssertEqual(nav.current, .displays)
        XCTAssertTrue(nav.canGoForward)
        nav.goForward()
        XCTAssertEqual(nav.current, .streaming)

        nav.goBack()
        nav.navigateTo(.system)
        XCTAssertFalse(nav.canGoForward, "a new destination discards Forward history")
        XCTAssertEqual(nav.backStack, [.overview, .displays])
    }

    // MARK: - Sidebar selection sync (no navigation from rendering)

    private func result(_ id: String, _ category: ReceiverSettingsCategory) -> ReceiverSettingsSearchItem {
        ReceiverSettingsSearchItem(id: id, title: id, category: category, keywords: [], systemImage: "gear")
    }

    func testDerivedSelectionFollowsNavigationState() {
        XCTAssertEqual(ReceiverSidebarSelection.derived(current: .displays, isSearching: false, results: [],
                                                        selectedSearchItemID: "x"), .category(.displays))
        let a = result("a", .displays), b = result("b", .streaming)
        XCTAssertEqual(ReceiverSidebarSelection.derived(current: .streaming, isSearching: true, results: [a, b],
                                                        selectedSearchItemID: nil), .searchResult(b))
        XCTAssertEqual(ReceiverSidebarSelection.derived(current: .streaming, isSearching: true, results: [a, b],
                                                        selectedSearchItemID: "a"), .searchResult(a))
        XCTAssertNil(ReceiverSidebarSelection.derived(current: .system, isSearching: true, results: [a],
                                                      selectedSearchItemID: "gone"))
    }

    @MainActor
    func testSelectingNavigatesOnceAndEchoesAndClearsDoNot() {
        let nav = ReceiverSettingsNavigationModel()
        if let destination = ReceiverSidebarSelection.destination(of: .category(.displays)) { nav.navigateTo(destination) }
        XCTAssertEqual(nav.backStack, [.overview])
        // The highlight re-derived from the model, fed back: no history change.
        let echoed = ReceiverSidebarSelection.derived(current: nav.current, isSearching: false, results: [],
                                                      selectedSearchItemID: nil)
        if let destination = ReceiverSidebarSelection.destination(of: echoed) { nav.navigateTo(destination) }
        XCTAssertNil(ReceiverSidebarSelection.destination(of: nil))
        XCTAssertEqual(nav.backStack, [.overview])
        XCTAssertEqual(nav.current, .displays)
        XCTAssertEqual(ReceiverSidebarSelection.destination(of: .searchResult(result("a", .streaming))), .streaming)
    }
}
