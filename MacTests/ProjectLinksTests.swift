import XCTest

final class ProjectLinksTests: XCTestCase {
    func testGitHubIsTheProjectPageEverywhere() {
        XCTAssertEqual(ProjectLinks.gitHub.absoluteString, "https://github.com/raiseCatError/meowdisplay")
        XCTAssertEqual(AppStore.projectURL, ProjectLinks.gitHub)
    }

    func testPrivacyPolicyIsMeowDisplaysOwnPage() {
        XCTAssertEqual(ProjectLinks.privacyPolicy.absoluteString, "https://meowdisplay.app/privacy")
        XCTAssertEqual(ProjectLinks.privacyPolicy.scheme, "https")
    }

    /// Settings > About links the privacy policy, and Demo Mode shows that
    /// same About page (not a demo copy), so the link is there in both modes.
    func testAboutLinksThePrivacyPolicyInNormalAndDemoMode() throws {
        XCTAssertEqual(DemoSettingsPresentation.presentation(for: .about), .shared)
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("iOS/ReceiverSettings.swift"), encoding: .utf8)
        let about = try XCTUnwrap(settings.range(of: "private struct AboutSettingsPage"))
        let page = settings[about.lowerBound...]
        // The struct ends at the first closing brace in column 0.
        let end = page.range(of: "\n}\n")?.lowerBound ?? page.endIndex
        XCTAssertTrue(page[..<end].contains("Link(destination: ProjectLinks.privacyPolicy)"),
                      "the About page must link the privacy policy")
    }

    func testNoSupportActionShipsWithoutAConfiguredPage() {
        // Until the Ko-fi page exists, no "Support MeowDisplay" action is shown.
        XCTAssertEqual(ProjectLinks.support, ProjectLinks.supportURL(from: ProjectLinks.koFiPage))
        if ProjectLinks.koFiPage == nil { XCTAssertNil(ProjectLinks.support) }
    }

    func testARealKoFiPageIsOffered() {
        for page in ["https://ko-fi.com/meowdisplay", "https://www.ko-fi.com/meowdisplay"] {
            XCTAssertEqual(ProjectLinks.supportURL(from: page)?.absoluteString, page)
        }
    }

    func testAnythingButAKoFiPageIsNeverOffered() {
        for page in [nil, "", "   ", "https://ko-fi.com", "https://ko-fi.com/", "http://ko-fi.com/meowdisplay",
                     "https://example.com/meowdisplay", "https://ko-fi.com.evil.example/meowdisplay",
                     "ko-fi.com/meowdisplay", "javascript:alert(1)", "https://ko-fi.com/<name>"] {
            XCTAssertNil(ProjectLinks.supportURL(from: page), page ?? "nil")
        }
    }
}
