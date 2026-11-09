import XCTest

/// Pure-logic coverage for the Dock / Menu Bar / Dock & Menu Bar presence
/// modes — the state-tracking rules, not `NSStatusItem`/AppKit windowing
/// (that lives in `MenuBarPresenceController` and isn't exercised here, same
/// convention as `ReconnectPolicyTests`/`AutoConnectPolicyTests`).
final class AppPresentationTests: XCTestCase {
    func testDockShowsOnlyDockIcon() {
        XCTAssertTrue(AppPresentation.dock.showsDockIcon)
        XCTAssertFalse(AppPresentation.dock.showsMenuBarIcon)
    }

    func testMenuBarShowsOnlyMenuBarIcon() {
        XCTAssertFalse(AppPresentation.menuBar.showsDockIcon)
        XCTAssertTrue(AppPresentation.menuBar.showsMenuBarIcon)
    }

    func testDockAndMenuBarShowsBoth() {
        XCTAssertTrue(AppPresentation.dockAndMenuBar.showsDockIcon)
        XCTAssertTrue(AppPresentation.dockAndMenuBar.showsMenuBarIcon)
    }

    /// Backward compatibility: `dock`/`menuBar` kept their original raw
    /// values when `dockAndMenuBar` was added, so existing installs restore
    /// the same mode they had before this change.
    func testPreviouslyPersistedRawValuesStillDecode() {
        XCTAssertEqual(AppPresentation(rawValue: "dock"), .dock)
        XCTAssertEqual(AppPresentation(rawValue: "menuBar"), .menuBar)
    }

    func testExactlyThreeModesAreOffered() {
        XCTAssertEqual(Set(AppPresentation.allCases), [.dock, .menuBar, .dockAndMenuBar])
    }

    // MARK: - Default for new installs (2.1.0)

    private var suites: [String] = []

    private func freshDefaults() -> UserDefaults {
        let name = "AppPresentationTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    func testANewInstallStartsAsDockAndMenuBarAndSavesIt() {
        let defaults = freshDefaults()
        XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), .dockAndMenuBar)
        XCTAssertEqual(defaults.string(forKey: "presentation"), "dockAndMenuBar")
        // Sparkle's first-launch flag, written after the first resolve, changes nothing later.
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), .dockAndMenuBar)
    }

    func testAnEarlierInstallThatNeverChoseKeepsMenuBarOnly() {
        for marker in AppPresentationStore.previousLaunchMarkers {
            let defaults = freshDefaults()
            defaults.set(true, forKey: marker)
            XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), .menuBar, marker)
            XCTAssertEqual(defaults.string(forKey: "presentation"), "menuBar", "saved, so it never changes: \(marker)")
        }
    }

    func testASavedChoiceIsAlwaysKept() {
        for saved in AppPresentation.allCases {
            for usedBefore in [false, true] {
                let defaults = freshDefaults()
                defaults.set(saved.rawValue, forKey: "presentation")
                if usedBefore { defaults.set(true, forKey: "SUHasLaunchedBefore") }
                XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), saved)
                XCTAssertEqual(defaults.string(forKey: "presentation"), saved.rawValue)
            }
        }
    }

    func testAValueFromANewerVersionIsLeftAlone() {
        let defaults = freshDefaults()
        defaults.set("somethingNewer", forKey: "presentation")
        XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), .menuBar)
        XCTAssertEqual(defaults.string(forKey: "presentation"), "somethingNewer")
    }

    func testResolvingAgainChangesNothing() {
        let defaults = freshDefaults()
        let first = AppPresentationStore.resolve(defaults: defaults)
        defaults.set(["id"], forKey: "knownReceiverIdentifiers")   // a device paired during the first run
        XCTAssertEqual(AppPresentationStore.resolve(defaults: defaults), first)
    }
}
