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
}
