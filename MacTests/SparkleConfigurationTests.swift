import XCTest

/// Pins the Sparkle auto-update configuration both direct-distribution Mac
/// apps ship with: MeowDisplay's own feeds and EdDSA public key, signed-feed
/// enforcement, and no forced automatic checks or installs. Checks
/// project.yml (the source of truth) and the Info.plists XcodeGen generates
/// from it (what actually lands in the app bundles).
final class SparkleConfigurationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let publicEDKey = "M9Je3RXE9GYGv7ZvVmJj2xK2FrpSR/rQvbuZFfYORcU="

    private struct MacApp {
        let target: String
        let infoPlist: String
        let feedURL: String
    }

    private static let apps = [
        MacApp(target: "OpenSidecarMac", infoPlist: "Mac/Info.plist",
               feedURL: "https://meowdisplay.app/appcast.xml"),
        MacApp(target: "OpenSidecarMacReceiver", infoPlist: "MacReceiver/Info.plist",
               feedURL: "https://meowdisplay.app/appcast-receiver.xml"),
    ]

    /// Upstream OpenDisplay's feed hosts and public key: trusting either
    /// would let upstream's releases update MeowDisplay installs.
    private static let upstreamPublicEDKey = "rYxlIePmwzi2bRo/qIsuY2TqTnQ34li2gQhJpGBiumw="
    private static let upstreamFeedHosts = ["opendisplay.app", "peetzweg.github.io"]

    func testProjectConfiguresEachMacAppsOwnFeedAndKey() throws {
        for app in Self.apps {
            let info = try Self.infoProperties(ofTarget: app.target)
            XCTAssertEqual(info["SUFeedURL"], app.feedURL, app.target)
            XCTAssertEqual(info["SUPublicEDKey"], Self.publicEDKey, app.target)
            XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"], "true", app.target)
            XCTAssertEqual(info["SURequireSignedFeed"], "true", app.target)
        }
    }

    /// With SUEnableAutomaticChecks unset Sparkle asks before it starts
    /// checking in the background; setting it either way skips that prompt.
    /// Automatic installation stays the user's opt-in too.
    func testProjectLeavesAutomaticChecksAndInstallsToTheUser() throws {
        for app in Self.apps {
            let info = try Self.infoProperties(ofTarget: app.target)
            XCTAssertNil(info["SUEnableAutomaticChecks"], app.target)
            XCTAssertNil(info["SUAutomaticallyUpdate"], app.target)
        }
    }

    func testGeneratedInfoPlistsCarryTheSparkleConfiguration() throws {
        for app in Self.apps {
            let url = Self.repoRoot.appendingPathComponent(app.infoPlist)
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["SUFeedURL"] as? String, app.feedURL, app.infoPlist)
            XCTAssertEqual(plist["SUPublicEDKey"] as? String, Self.publicEDKey, app.infoPlist)
            XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true, app.infoPlist)
            XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true, app.infoPlist)
            XCTAssertNil(plist["SUEnableAutomaticChecks"], app.infoPlist)
            XCTAssertNil(plist["SUAutomaticallyUpdate"], app.infoPlist)
        }
    }

    func testNothingPointsAtUpstreamOpenDisplayUpdates() throws {
        var sources = [try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
                                  encoding: .utf8)]
        for app in Self.apps {
            sources.append(try String(contentsOf: Self.repoRoot.appendingPathComponent(app.infoPlist),
                                      encoding: .utf8))
        }
        for source in sources {
            XCTAssertFalse(source.contains(Self.upstreamPublicEDKey))
            for host in Self.upstreamFeedHosts {
                XCTAssertFalse(source.contains("https://\(host)/"), host)
            }
        }
    }

    /// `key: value` pairs directly under a target's `info.properties`.
    private static func infoProperties(ofTarget name: String) throws -> [String: String] {
        let spec = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = spec.components(separatedBy: "\n")
        let targets = try XCTUnwrap(lines.firstIndex(of: "targets:"))
        let start = try XCTUnwrap(lines[targets...].firstIndex(of: "  \(name):"), "\(name) not found")
        let properties = try XCTUnwrap(
            lines[start...].firstIndex(of: "      properties:"), "\(name) has no info properties")
        var result: [String: String] = [:]
        for line in lines[(properties + 1)...] {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }
            // The block ends at the first key indented less than a property.
            guard line.prefix(while: { $0 == " " }).count >= 8 else { break }
            guard let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon])
            let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}
