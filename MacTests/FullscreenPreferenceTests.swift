import XCTest

/// Mac Receiver "Open in Full Screen" and the video window's lifetime rules
/// in `MacReceiver/ReceiverWindowLifecycle.swift`.
final class FullscreenPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FullscreenPreferenceTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func lifecycle() -> ReceiverWindowLifecycle {
        ReceiverWindowLifecycle(preference: FullscreenPreference(defaults: defaults))
    }

    // MARK: - Preference

    func testDefaultsToFullscreen() {
        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    func testWindowedChoiceSurvivesRelaunch() {
        FullscreenPreference(defaults: defaults).wantsFullscreen = false
        XCTAssertFalse(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    func testFullscreenChoiceSurvivesRelaunch() {
        FullscreenPreference(defaults: defaults).wantsFullscreen = false
        FullscreenPreference(defaults: defaults).wantsFullscreen = true
        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    // MARK: - Fresh windows

    func testEnabledPreferenceMakesAFreshWindowRequestFullscreen() {
        var life = lifecycle()
        XCTAssertTrue(life.windowCreated())
    }

    func testDisabledPreferenceLeavesAFreshWindowWindowed() {
        FullscreenPreference(defaults: defaults).wantsFullscreen = false
        var life = lifecycle()
        XCTAssertFalse(life.windowCreated())
    }

    // MARK: - Green button

    func testNativeFullscreenEntryAndExitUpdateThePreference() {
        var life = lifecycle()
        _ = life.windowCreated()
        life.fullscreenChanged(entered: false)
        XCTAssertFalse(FullscreenPreference(defaults: defaults).wantsFullscreen)
        life.fullscreenChanged(entered: true)
        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    func testProgrammaticTeardownDoesNotRecordWindowed() {
        var life = lifecycle()
        _ = life.windowCreated()
        life.windowClosing()
        // Closing a full screen window reports an exit afterwards.
        life.fullscreenChanged(entered: false)
        XCTAssertTrue(FullscreenPreference(defaults: defaults).wantsFullscreen)
    }

    // MARK: - Reconnect grace

    func testStreamingLossSchedulesADelayedClose() {
        var life = lifecycle()
        _ = life.windowCreated()
        let token = life.scheduleClose()
        XCTAssertEqual(life.pendingClose, token)
        XCTAssertEqual(ReceiverWindowLifecycle.closeGrace, 2)
        XCTAssertTrue(life.consumeClose(token))
        XCTAssertNil(life.pendingClose)
    }

    func testResumingWithinGraceCancelsTheClose() {
        var life = lifecycle()
        _ = life.windowCreated()
        let token = life.scheduleClose()
        life.cancelPendingClose()
        XCTAssertFalse(life.consumeClose(token))
    }

    func testStaleCloseCannotTakeDownANewerWindow() {
        var life = lifecycle()
        _ = life.windowCreated()
        let stale = life.scheduleClose()
        life.cancelPendingClose()             // resumed
        let current = life.scheduleClose()    // dropped again later
        XCTAssertFalse(life.consumeClose(stale), "the first gap's timer must not act")
        XCTAssertTrue(life.consumeClose(current))
    }

    func testClosingTheWindowVoidsAPendingClose() {
        var life = lifecycle()
        _ = life.windowCreated()
        let token = life.scheduleClose()
        life.windowClosing()                  // user closed it meanwhile
        XCTAssertFalse(life.consumeClose(token))
    }
}
