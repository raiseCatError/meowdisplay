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

    // MARK: - Navigation History Tests

    @MainActor
    func testNavigationModelInitialState() {
        let nav = SettingsNavigationModel()
        XCTAssertEqual(nav.current, .overview)
        XCTAssertFalse(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)
        XCTAssertTrue(nav.backStack.isEmpty)
        XCTAssertTrue(nav.forwardStack.isEmpty)
    }

    @MainActor
    func testNavigationModelSequentialNavigation() {
        let nav = SettingsNavigationModel()
        nav.navigateTo(.displays)
        XCTAssertEqual(nav.current, .displays)
        XCTAssertTrue(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)
        XCTAssertEqual(nav.backStack, [.overview])

        nav.navigateTo(.streaming)
        XCTAssertEqual(nav.current, .streaming)
        XCTAssertEqual(nav.backStack, [.overview, .displays])
        XCTAssertFalse(nav.canGoForward)
    }

    @MainActor
    func testNavigationModelDuplicateConsecutiveNavigationIsIgnored() {
        let nav = SettingsNavigationModel()
        nav.navigateTo(.displays)
        XCTAssertEqual(nav.backStack, [.overview])

        // Navigating to the same category again should be a no-op
        nav.navigateTo(.displays)
        XCTAssertEqual(nav.current, .displays)
        XCTAssertEqual(nav.backStack, [.overview])
        XCTAssertFalse(nav.canGoForward)
    }

    @MainActor
    func testNavigationModelBackAndForwardTraversal() {
        let nav = SettingsNavigationModel()
        nav.navigateTo(.displays)
        nav.navigateTo(.streaming)

        // Overview -> Displays -> Streaming
        XCTAssertEqual(nav.current, .streaming)

        // Back: Streaming -> Displays
        nav.goBack()
        XCTAssertEqual(nav.current, .displays)
        XCTAssertTrue(nav.canGoBack)
        XCTAssertTrue(nav.canGoForward)
        XCTAssertEqual(nav.forwardStack, [.streaming])

        // Back: Displays -> Overview
        nav.goBack()
        XCTAssertEqual(nav.current, .overview)
        XCTAssertFalse(nav.canGoBack)
        XCTAssertTrue(nav.canGoForward)
        XCTAssertEqual(nav.forwardStack, [.streaming, .displays])

        // Forward: Overview -> Displays
        nav.goForward()
        XCTAssertEqual(nav.current, .displays)
        XCTAssertTrue(nav.canGoBack)
        XCTAssertTrue(nav.canGoForward)
        XCTAssertEqual(nav.forwardStack, [.streaming])

        // Forward: Displays -> Streaming
        nav.goForward()
        XCTAssertEqual(nav.current, .streaming)
        XCTAssertTrue(nav.canGoBack)
        XCTAssertFalse(nav.canGoForward)
        XCTAssertTrue(nav.forwardStack.isEmpty)
    }

    @MainActor
    func testNavigationModelDivergentHistoryClearsForward() {
        let nav = SettingsNavigationModel()
        nav.navigateTo(.displays)
        nav.navigateTo(.streaming)

        // Back to Displays
        nav.goBack()
        XCTAssertEqual(nav.current, .displays)
        XCTAssertTrue(nav.canGoForward)
        XCTAssertEqual(nav.forwardStack, [.streaming])

        // Manually choose Input: Forward history to Streaming must be discarded!
        nav.navigateTo(.input)
        XCTAssertEqual(nav.current, .input)
        XCTAssertFalse(nav.canGoForward, "Forward history must be discarded upon divergent navigation")
        XCTAssertTrue(nav.forwardStack.isEmpty)
        XCTAssertEqual(nav.backStack, [.overview, .displays])

        // Stepping back now should return to Displays, then Overview
        nav.goBack()
        XCTAssertEqual(nav.current, .displays)
        nav.goBack()
        XCTAssertEqual(nav.current, .overview)
        XCTAssertFalse(nav.canGoBack)
    }

    @MainActor
    func testNavigationModelEmptyStackGuards() {
        let nav = SettingsNavigationModel()
        // Calling goBack or goForward when stacks are empty should be safe no-ops
        nav.goBack()
        XCTAssertEqual(nav.current, .overview)
        nav.goForward()
        XCTAssertEqual(nav.current, .overview)
    }

    // MARK: - Search Index Tests

    func testSearchIndexFindsAllTopLevelCategories() {
        let index = SettingsSearchIndex.shared
        for category in SettingsCategory.allCases {
            let results = index.search(query: category.label)
            XCTAssertFalse(results.isEmpty, "Search should return results for category: \(category.label)")
            XCTAssertTrue(results.contains(where: { $0.category == category }), "Results should contain category: \(category.label)")
        }
    }

    func testSearchIndexQueryRanking() {
        let index = SettingsSearchIndex.shared
        let results = index.search(query: "display")
        XCTAssertFalse(results.isEmpty)
        // Top-level "Displays" should rank first
        XCTAssertEqual(results.first?.category, .displays)
        XCTAssertEqual(results.first?.title, "Displays")
    }

    func testSearchIndexFindsSubSettings() {
        let index = SettingsSearchIndex.shared

        // "codec" -> Streaming (HEVC, H.264)
        let codecResults = index.search(query: "codec")
        XCTAssertFalse(codecResults.isEmpty)
        XCTAssertTrue(codecResults.contains(where: { $0.category == .streaming }))

        // "hevc" -> Streaming
        let hevcResults = index.search(query: "hevc")
        XCTAssertFalse(hevcResults.isEmpty)
        XCTAssertTrue(hevcResults.contains(where: { $0.category == .streaming }))

        // "h.264" -> Streaming
        let h264Results = index.search(query: "h.264")
        XCTAssertFalse(h264Results.isEmpty)
        XCTAssertTrue(h264Results.contains(where: { $0.category == .streaming }))

        // "mirror" -> Displays
        let mirrorResults = index.search(query: "mirror")
        XCTAssertFalse(mirrorResults.isEmpty)
        XCTAssertTrue(mirrorResults.contains(where: { $0.category == .displays }))

        // "extend" -> Displays
        let extendResults = index.search(query: "extend")
        XCTAssertFalse(extendResults.isEmpty)
        XCTAssertTrue(extendResults.contains(where: { $0.category == .displays }))

        // "resolution" -> Displays
        let resResults = index.search(query: "resolution")
        XCTAssertFalse(resResults.isEmpty)
        XCTAssertTrue(resResults.contains(where: { $0.category == .displays }))

        // "input" -> Input
        let inputResults = index.search(query: "input")
        XCTAssertFalse(inputResults.isEmpty)
        XCTAssertTrue(inputResults.contains(where: { $0.category == .input }))

        // "remote" -> Remote Access and Remote Pairing
        let remoteResults = index.search(query: "remote")
        XCTAssertFalse(remoteResults.isEmpty)
        XCTAssertTrue(remoteResults.contains(where: { $0.category == .remoteAccess }))

        // "available" -> System (Keep Mac Available)
        let availResults = index.search(query: "available")
        XCTAssertFalse(availResults.isEmpty)
        XCTAssertTrue(availResults.contains(where: { $0.category == .system }))

        // "device" -> Devices
        let deviceResults = index.search(query: "device")
        XCTAssertFalse(deviceResults.isEmpty)
        XCTAssertTrue(deviceResults.contains(where: { $0.category == .devices }))
    }

    func testSearchIndexEmptyAndWhitespaceQueries() {
        let index = SettingsSearchIndex.shared
        XCTAssertTrue(index.search(query: "").isEmpty)
        XCTAssertTrue(index.search(query: "   \n\t  ").isEmpty)
    }

    func testSearchIndexCaseInsensitiveAndTrimsWhitespace() {
        let index = SettingsSearchIndex.shared
        let results1 = index.search(query: "  STREAMING  ")
        let results2 = index.search(query: "streaming")
        XCTAssertEqual(results1.map(\.id), results2.map(\.id))
    }
}
