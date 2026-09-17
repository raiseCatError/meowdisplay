import XCTest

/// Covers the hidden Cat Mode unlock/enable rules in `CatMode` — the pure
/// logic behind the nine-tap easter egg on the About/version row. UI
/// wiring (AppStorage, the tap gesture, the alert) is exercised manually;
/// this locks down the state machine it's built on.
final class CatModeTests: XCTestCase {
    func testTapsOneThroughEightDoNotUnlock() {
        var tapCount = 0
        for _ in 1...8 {
            let result = CatMode.registerTap(tapCount: tapCount, alreadyUnlocked: false)
            tapCount = result.tapCount
            XCTAssertFalse(result.justUnlocked)
        }
        XCTAssertEqual(tapCount, 8)
    }

    func testNinthTapUnlocks() {
        var tapCount = 0
        var unlocked = false
        for _ in 1..<CatMode.requiredTaps {
            let result = CatMode.registerTap(tapCount: tapCount, alreadyUnlocked: unlocked)
            tapCount = result.tapCount
        }
        let ninth = CatMode.registerTap(tapCount: tapCount, alreadyUnlocked: unlocked)
        unlocked = ninth.justUnlocked
        XCTAssertTrue(ninth.justUnlocked)
        XCTAssertTrue(unlocked)
        XCTAssertEqual(ninth.tapCount, CatMode.requiredTaps)
    }

    func testFurtherTapsAfterUnlockDoNotRepeatedlyTrigger() {
        // Once unlocked, a tap on the same row is a no-op — it must never
        // re-fire the "Cat Mode unlocked" confirmation.
        let result = CatMode.registerTap(tapCount: 12, alreadyUnlocked: true)
        XCTAssertFalse(result.justUnlocked)
        XCTAssertEqual(result.tapCount, 12, "tap count should not advance once already unlocked")
    }

    func testLockedUsersCannotEnableCatModeThroughNormalUIState() {
        XCTAssertFalse(CatMode.resolveEnabled(requestedEnabled: true, unlocked: false),
                        "a locked user flipping the (unshown) toggle on must never resolve to enabled")
    }

    func testUnlockedUsersCanEnableAndDisableCatMode() {
        XCTAssertTrue(CatMode.resolveEnabled(requestedEnabled: true, unlocked: true))
        XCTAssertFalse(CatMode.resolveEnabled(requestedEnabled: false, unlocked: true))
    }

    func testUnlockedAndEnabledStatePersistAcrossRelaunchSimulation() {
        let defaults = UserDefaults(suiteName: #file)!
        defer { defaults.removePersistentDomain(forName: #file) }

        defaults.set(true, forKey: CatMode.unlockedDefaultsKey)
        defaults.set(true, forKey: CatMode.enabledDefaultsKey)

        // Simulate a relaunch: a fresh read from the same domain.
        let unlockedAfterRelaunch = defaults.bool(forKey: CatMode.unlockedDefaultsKey)
        let enabledAfterRelaunch = CatMode.resolveEnabled(
            requestedEnabled: defaults.bool(forKey: CatMode.enabledDefaultsKey),
            unlocked: unlockedAfterRelaunch
        )

        XCTAssertTrue(unlockedAfterRelaunch)
        XCTAssertTrue(enabledAfterRelaunch)
    }

    func testDisablingCatModeRestoresNormalPresentation() {
        let defaults = UserDefaults(suiteName: #file)!
        defer { defaults.removePersistentDomain(forName: #file) }

        defaults.set(true, forKey: CatMode.unlockedDefaultsKey)
        defaults.set(true, forKey: CatMode.enabledDefaultsKey)
        XCTAssertTrue(CatMode.resolveEnabled(requestedEnabled: defaults.bool(forKey: CatMode.enabledDefaultsKey),
                                              unlocked: defaults.bool(forKey: CatMode.unlockedDefaultsKey)))

        defaults.set(false, forKey: CatMode.enabledDefaultsKey)
        let stillUnlocked = defaults.bool(forKey: CatMode.unlockedDefaultsKey)
        let nowEnabled = CatMode.resolveEnabled(requestedEnabled: defaults.bool(forKey: CatMode.enabledDefaultsKey),
                                                 unlocked: stillUnlocked)

        XCTAssertTrue(stillUnlocked, "disabling Cat Mode must not re-lock it")
        XCTAssertFalse(nowEnabled, "presentation must fall back to normal once disabled")
    }
}
