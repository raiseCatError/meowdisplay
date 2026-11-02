import XCTest

/// Guards the String Catalogs community translators work in: they must stay
/// English-sourced, carry no language other than English until a human
/// contributes one, and keep the core UI strings each app shows.
final class StringCatalogTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let catalogs = [
        "Mac/Localizable.xcstrings",
        "Mac/InfoPlist.xcstrings",
        "iOS/Localizable.xcstrings",
        "iOS/InfoPlist.xcstrings",
        "MacReceiver/Localizable.xcstrings",
        "MacReceiver/InfoPlist.xcstrings",
    ]

    private func strings(in path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(path))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en", path)
        return try XCTUnwrap(catalog["strings"] as? [String: [String: Any]], path)
    }

    func testCatalogsAreEnglishSourcedWithNoOtherLanguages() throws {
        for path in Self.catalogs {
            let entries = try strings(in: path)
            XCTAssertFalse(entries.isEmpty, path)
            for (key, entry) in entries {
                let languages = Set((entry["localizations"] as? [String: Any]).map { Array($0.keys) } ?? [])
                XCTAssertTrue(languages.isSubset(of: ["en"]), "\(path): \(key) has \(languages)")
            }
        }
    }

    func testCatalogsContainCoreStrings() throws {
        let expected = [
            "Mac/Localizable.xcstrings": ["Overview", "Displays", "Mirror", "Extend", "Pairing Request", "1 device connected"],
            "iOS/Localizable.xcstrings": ["Direct Touch", "Trackpad", "Control", "Display Paused", "Codes Match"],
            "MacReceiver/Localizable.xcstrings": ["Waiting for a Mac…", "How to Connect", "Wake & Connect", "Show Window", "Codes Match"],
            "iOS/InfoPlist.xcstrings": ["NSLocalNetworkUsageDescription", "NSFaceIDUsageDescription"],
        ]
        for (path, keys) in expected {
            let entries = try strings(in: path)
            for key in keys {
                XCTAssertNotNil(entries[key], "\(path) is missing \"\(key)\"")
            }
        }
    }
}
