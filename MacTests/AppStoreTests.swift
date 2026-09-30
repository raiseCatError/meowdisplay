import XCTest

/// MeowDisplay has no App Store listing of its own yet, and the ID this repo
/// used to carry belongs to upstream OpenDisplay's app. Nothing may send a
/// user to that listing: not a deep link, not the Mac's `updateRequired`, not
/// a receiver fallback.
final class AppStoreTests: XCTestCase {
    /// Upstream OpenDisplay's listing ID, spelled as a number so its digits
    /// never appear as text in the repository (see the scan below).
    private static let upstreamID = String(6_780_264_891)
    /// Stands in for MeowDisplay's own listing once it has one.
    private static let ownID = "1234567890"

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func upstreamLinks() -> [String] {
        let id = Self.upstreamID
        return [
            "itms-apps://apps.apple.com/app/id\(id)",
            "https://apps.apple.com/app/id\(id)",
            "https://apps.apple.com/us/app/opendisplay/id\(id)?mt=8",
            "itms-apps://itunes.apple.com/app/id\(id)",
            "HTTPS://APPS.APPLE.COM/app/id\(id)",
        ]
    }

    // MARK: - Without a listing

    func testWithoutAListingThereIsNoStoreLink() {
        XCTAssertNil(AppStore.listingURL(appID: nil, scheme: "itms-apps"))
        XCTAssertNil(AppStore.listingURL(appID: nil, scheme: "https"))
        XCTAssertNil(AppStore.listingURL(appID: "", scheme: "https"))
        XCTAssertNil(AppStore.listingURL(appID: "id123", scheme: "https"), "digits only")
        XCTAssertEqual(AppStore.updateDestination(appID: nil), AppStore.projectURL)
        XCTAssertFalse(AppStore.isAppStoreLink(AppStore.updateDestination(appID: nil)))
    }

    func testWithoutAListingEveryOfferedStoreLinkBecomesTheProjectPage() {
        for link in upstreamLinks() + ["itms-apps://apps.apple.com/app/id\(Self.ownID)",
                                       "itms-services://?action=download-manifest"] {
            let resolved = AppStore.resolveReceiverUpdateURL(link, appID: nil)
            XCTAssertEqual(resolved, AppStore.projectURL, link)
            XCTAssertFalse(AppStore.isAppStoreLink(resolved), link)
        }
    }

    /// What the app ships with today: whatever it is configured to, it is
    /// never upstream's listing, and with no listing it links nothing in the
    /// App Store at all.
    func testShippedConfigurationNeverLinksTheUpstreamListing() {
        XCTAssertNotEqual(AppStore.iOSAppID, Self.upstreamID)
        var emitted = [AppStore.receiverUpdateURL]
        emitted += [AppStore.updateURL, AppStore.webURL].compactMap { $0 }
        emitted += upstreamLinks().map { AppStore.resolveReceiverUpdateURL($0) }
        emitted.append(AppStore.resolveReceiverUpdateURL(nil))
        for url in emitted {
            XCTAssertFalse(url.absoluteString.contains(Self.upstreamID), url.absoluteString)
        }
        if AppStore.iOSAppID == nil {
            XCTAssertNil(AppStore.updateURL)
            XCTAssertNil(AppStore.webURL)
            XCTAssertEqual(AppStore.receiverUpdateURL, AppStore.projectURL)
            for url in emitted {
                XCTAssertFalse(AppStore.isAppStoreLink(url), url.absoluteString)
            }
        }
    }

    func testTheShippingListingIsMeowDisplaysOwn() {
        XCTAssertEqual(AppStore.iOSAppID, "6817552864")
        XCTAssertEqual(AppStore.updateURL?.absoluteString, "itms-apps://apps.apple.com/app/id6817552864")
        XCTAssertEqual(AppStore.webURL?.absoluteString, "https://apps.apple.com/app/id6817552864")
        XCTAssertEqual(AppStore.receiverUpdateURL, AppStore.updateURL)
    }

    // MARK: - With a listing

    func testOwnListingIsLinkedOnceConfigured() {
        XCTAssertEqual(AppStore.listingURL(appID: Self.ownID, scheme: "itms-apps")?.absoluteString,
                       "itms-apps://apps.apple.com/app/id\(Self.ownID)")
        XCTAssertEqual(AppStore.listingURL(appID: Self.ownID, scheme: "https")?.absoluteString,
                       "https://apps.apple.com/app/id\(Self.ownID)")
        XCTAssertEqual(AppStore.updateDestination(appID: Self.ownID),
                       AppStore.listingURL(appID: Self.ownID, scheme: "itms-apps"))
        for link in ["itms-apps://apps.apple.com/app/id\(Self.ownID)",
                     "https://apps.apple.com/de/app/meowdisplay/id\(Self.ownID)"] {
            XCTAssertEqual(AppStore.resolveReceiverUpdateURL(link, appID: Self.ownID).absoluteString, link)
        }
    }

    func testAnotherAppsListingIsReplacedEvenWithAListing() {
        let own = AppStore.updateDestination(appID: Self.ownID)
        for link in upstreamLinks() + ["itms-apps://apps.apple.com/app/id\(Self.ownID)9",
                                       "https://apps.apple.com/app/meowdisplay"] {
            XCTAssertEqual(AppStore.resolveReceiverUpdateURL(link, appID: Self.ownID), own, link)
        }
    }

    // MARK: - Other offered links

    func testHTTPSLinksOutsideTheAppStoreAreKept() {
        for link in [AppStore.projectURL.absoluteString,
                     "https://github.com/raiseCatError/MeowDisplay/releases/latest"] {
            XCTAssertEqual(AppStore.resolveReceiverUpdateURL(link, appID: nil).absoluteString, link)
        }
    }

    func testAnythingElseFallsBackToTheUpdateDestination() {
        for link in [nil, "", "http://github.com/raiseCatError/MeowDisplay", "javascript:alert(1)",
                     "tel:123", "file:///etc/hosts", "meowdisplay://update", "https://", "not a url"] {
            XCTAssertEqual(AppStore.resolveReceiverUpdateURL(link, appID: nil), AppStore.projectURL,
                           link ?? "nil")
        }
    }

    // MARK: - Source

    /// The upstream listing ID must not survive anywhere it could be emitted
    /// or copied from: app code, plists, string catalogs, project/CI and
    /// fastlane config, the website, or the top-level docs.
    func testUpstreamListingIDAppearsNowhereInTheRepository() throws {
        let manager = FileManager.default
        let root = Self.repoRoot
        let textExtensions: Set<String> = ["swift", "h", "m", "plist", "xcstrings", "xcprivacy", "entitlements",
                                           "yml", "yaml", "json", "md", "html", "ts", "tsx", "js", "mjs", "css",
                                           "txt", "rb", "sh", ""]
        // Gitignored local notes, which a checkout may or may not have.
        let untracked: Set<String> = ["CLAUDE.md", "PROJECT_BRIEF.md", "ICON_WORKFLOW.md"]
        var files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !untracked.contains($0.lastPathComponent) }
        for directory in ["Shared", "iOS", "Mac", "MacReceiver", "src", "public", "tools", "fastlane", ".github"] {
            let enumerator = try XCTUnwrap(manager.enumerator(at: root.appendingPathComponent(directory),
                                                              includingPropertiesForKeys: nil), directory)
            while let url = enumerator.nextObject() as? URL { files.append(url) }
        }
        var scanned = 0
        var offenders: [String] = []
        for url in files where textExtensions.contains(url.pathExtension) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if text.contains(Self.upstreamID) {
                offenders.append(String(url.path.dropFirst(root.path.count)))
            }
        }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "AppStore.swift" })
        XCTAssertGreaterThan(scanned, 100, "the scan should cover the repository's sources")
        XCTAssertEqual(offenders, [])
    }
}
