import XCTest

/// Schema 21 (owner decision 2026-10-30): Classic Direct Touch for everyone; phones start in
/// Trackpad and iPads in Direct Touch, new installs and upgraded ones alike. Same rule as Android's
/// TouchStylePreferenceTest.schema21MakesEveryoneClassicAndPhonesTrackpad.
final class InputDefaultsTests: XCTestCase {
    private func repository() -> ReceiverControlPreferencesRepository {
        let suite = "InputDefaultsTests-\(UUID().uuidString)"
        return ReceiverControlPreferencesRepository(defaults: UserDefaults(suiteName: suite)!)
    }

    func testNewInstallsAreClassicWithTrackpadOnPhonesAndDirectTouchOnIPad() {
        XCTAssertEqual(ReceiverControlPreferences().touchStyle, .classic)
        XCTAssertEqual(ReceiverControlPreferences.schemaVersion, 21)
        XCTAssertEqual(ReceiverControlPreferences.initial(isPad: false).inputMode, .trackpad)
        XCTAssertEqual(ReceiverControlPreferences.initial(isPad: true).inputMode, .direct)
    }

    func testUpgradedInstallsMoveOnceAndLaterChoicesStick() throws {
        let repo = repository()
        var saved = ReceiverControlPreferences()
        saved.version = 20
        saved.touchStyle = .natural
        saved.inputMode = .direct
        saved.smartTouchEnabled = false
        repo.defaults.set(try JSONEncoder().encode(saved), forKey: ReceiverControlPreferencesRepository.defaultsKey)

        let phone = repo.load(initial: .initial(isPad: false))
        XCTAssertEqual(phone.touchStyle, .classic)
        XCTAssertEqual(phone.inputMode, .trackpad)
        XCTAssertFalse(phone.smartTouchEnabled, "other choices are kept")
        let pad = repo.load(initial: .initial(isPad: true))
        XCTAssertEqual(pad.touchStyle, .classic)
        XCTAssertEqual(pad.inputMode, .direct)

        var chosen = phone
        chosen.touchStyle = .natural
        repo.defaults.set(try JSONEncoder().encode(chosen), forKey: ReceiverControlPreferencesRepository.defaultsKey)
        XCTAssertEqual(repo.load(initial: .initial(isPad: false)).touchStyle, .natural, "once migrated, a later choice sticks")
    }
}
