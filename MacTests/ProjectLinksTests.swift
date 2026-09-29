import XCTest

final class ProjectLinksTests: XCTestCase {
    func testGitHubIsTheProjectPageEverywhere() {
        XCTAssertEqual(ProjectLinks.gitHub.absoluteString, "https://github.com/raiseCatError/meowdisplay")
        XCTAssertEqual(AppStore.projectURL, ProjectLinks.gitHub)
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
