import XCTest

/// App Store Connect refuses an iOS build that calls a required-reason API
/// without declaring it in the app's privacy manifest. Pins the iOS
/// manifest's content, keeps it in step with what the iOS target's own
/// sources call, and checks that project.yml copies it into the app bundle.
final class PrivacyManifestTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let manifestPath = "iOS/PrivacyInfo.xcprivacy"

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(Self.manifestPath))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func declaredReasons() throws -> [String: [String]] {
        let entries = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(declared[category], "\(category) is declared twice")
            declared[category] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String], category)
        }
        return declared
    }

    func testNoTrackingAndNoCollectedData() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [Any])
        XCTAssertTrue(collected.isEmpty, "the app collects no data")
    }

    /// Each code is the one Apple documents for how the app uses the API:
    /// CA92.1 — UserDefaults read and written by the app itself (no App
    /// Group); C617.1 — metadata of a file in the app container (Log.swift
    /// sizing its own connection log).
    func testDeclaresTheRequiredReasonAPIsWithTheirReasons() throws {
        XCTAssertEqual(try declaredReasons(), [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        ])
    }

    /// A required-reason API newly called from `iOS/` or `Shared/` (both
    /// compiled into the iOS app) must be declared before it can ship, and
    /// a declaration must not outlive its last use. Comments are ignored.
    func testDeclaredCategoriesMatchWhatTheIOSSourcesCall() throws {
        let patterns: [String: [String]] = [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults", "@AppStorage"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": [
                "attributesOfItem", "creationDate", "modificationDate", "contentModificationDateKey",
                "creationDateKey", "getattrlist", "stat(", "fstat(", "fstatat(", "lstat(",
            ],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
            "NSPrivacyAccessedAPICategoryDiskSpace": [
                "volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "systemSize",
                "statfs(", "statvfs(", "fstatfs(", "fstatvfs(",
            ],
            "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
        ]
        var used: Set<String> = []
        for directory in ["iOS", "Shared"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: Self.repoRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil))
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let code = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                    .joined(separator: "\n")
                for (category, needles) in patterns where needles.contains(where: code.contains) {
                    used.insert(category)
                }
            }
        }
        XCTAssertTrue(used.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "the scan found nothing")
        XCTAssertEqual(Set(try declaredReasons().keys), used)
    }

    /// The manifest only counts if it is inside the .app: project.yml must put
    /// it in the iOS target's Copy Bundle Resources, and there must be no
    /// manifest under Shared/, which every target — the Mac apps included —
    /// compiles in.
    func testProjectCopiesTheManifestIntoTheIOSApp() throws {
        let spec = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let target = try Self.iOSTargetLines(of: spec)
        let entry = try XCTUnwrap(target.firstIndex(of: "- path: \(Self.manifestPath)"),
                                  "the iOS target does not list the manifest")
        XCTAssertEqual(target[entry + 1], "buildPhase: resources")
        XCTAssertEqual(spec.components(separatedBy: "PrivacyInfo.xcprivacy").count - 1, 1,
                       "only the iOS target lists the manifest")

        let shared = try FileManager.default.contentsOfDirectory(
            atPath: Self.repoRoot.appendingPathComponent("Shared").path)
        XCTAssertFalse(shared.contains { $0.hasSuffix(".xcprivacy") })
    }

    /// Export compliance as declared in App Store Connect: standard, exempt
    /// encryption only. Declared in the Info.plist so later uploads are not
    /// asked again; no documentation code applies.
    func testIOSAppDeclaresNoNonExemptEncryption() throws {
        let spec = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let target = try Self.iOSTargetLines(of: spec)
        XCTAssertTrue(target.contains("ITSAppUsesNonExemptEncryption: false"))
        XCTAssertFalse(spec.contains("ITSEncryptionExportComplianceCode"))
    }

    /// The iOS target's block of project.yml, each line trimmed.
    private static func iOSTargetLines(of spec: String) throws -> [String] {
        let lines = spec.components(separatedBy: "\n")
        let targets = try XCTUnwrap(lines.firstIndex(of: "targets:"))
        let start = try XCTUnwrap(lines[targets...].firstIndex(of: "  OpenSidecariOS:"), "iOS target not found")
        // The block ends at the next key indented as deeply as a target or less.
        let end = lines[(start + 1)...].firstIndex { line in
            let content = line.trimmingCharacters(in: .whitespaces)
            return !content.isEmpty && !content.hasPrefix("#") && line.prefix { $0 == " " }.count <= 2
        } ?? lines.endIndex
        return lines[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
