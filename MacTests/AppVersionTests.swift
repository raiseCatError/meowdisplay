import XCTest

final class AppVersionTests: XCTestCase {
    func testTheVersionShowsItsBuild() {
        XCTAssertEqual(AppVersion.display(version: "2.0", build: "214"), "2.0 (214)")
    }

    func testABuildThatAddsNothingIsLeftOut() {
        XCTAssertEqual(AppVersion.display(version: "2.0", build: nil), "2.0")
        XCTAssertEqual(AppVersion.display(version: "2.0", build: ""), "2.0")
        XCTAssertEqual(AppVersion.display(version: "2.0", build: " "), "2.0")
        XCTAssertEqual(AppVersion.display(version: "2.0", build: "2.0"), "2.0")
    }

    func testNoVersionReadsDev() {
        XCTAssertEqual(AppVersion.display(version: nil, build: nil), "dev")
        XCTAssertEqual(AppVersion.display(version: "", build: "7"), "dev (7)")
    }
}
