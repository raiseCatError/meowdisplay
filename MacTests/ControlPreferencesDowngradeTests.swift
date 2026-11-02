import XCTest

/// Settings written by a newer build survive running an older one (audit O6): they used to be
/// reset to defaults and then overwritten on the next save.
final class ControlPreferencesDowngradeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "ControlPreferencesDowngradeTests-\(UUID().uuidString)")
    }

    private func store(_ object: [String: Any]) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ReceiverControlPreferencesRepository.defaultsKey)
    }

    private func stored() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: ReceiverControlPreferencesRepository.defaultsKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testANewerBuildsSettingsAreReadNotReset() throws {
        let newer = ReceiverControlPreferences.schemaVersion + 3
        try store(["version": newer, "trayEnabled": false, "futureSetting": "kept"])
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var initial = ReceiverControlPreferences()
        initial.trayEnabled = true
        let loaded = repository.load(initial: initial)
        XCTAssertFalse(loaded.trayEnabled, "the newer build's choice, not the initial default")
        XCTAssertEqual(loaded.version, newer)
    }

    func testSavingKeepsTheNewerBuildsOwnFields() throws {
        let newer = ReceiverControlPreferences.schemaVersion + 3
        try store(["version": newer, "trayEnabled": false, "futureSetting": "kept"])
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        var preferences = repository.load()
        preferences.trayEnabled = true
        repository.save(preferences)
        let after = try stored()
        XCTAssertEqual(after["futureSetting"] as? String, "kept", "a field this build doesn't know survives")
        XCTAssertEqual(after["trayEnabled"] as? Bool, true, "a field it knows is written as now")
        XCTAssertEqual(after["version"] as? Int, newer, "the newer build won't migrate its own data again")
    }

    func testSettingsFromThisSchemaAreSavedAsBefore() throws {
        try store(["version": ReceiverControlPreferences.schemaVersion, "futureSetting": "dropped"])
        let repository = ReceiverControlPreferencesRepository(defaults: defaults)
        repository.save(repository.load())
        XCTAssertNil(try stored()["futureSetting"])
        XCTAssertEqual(try stored()["version"] as? Int, ReceiverControlPreferences.schemaVersion)
    }
}
