import XCTest

final class WakeInspectorProcessTests: XCTestCase {
    func testParsesWompLine() {
        XCTAssertEqual(WakeInspector.parseWakeForNetworkAccess(" sleep 1\n womp                 1\n"), .enabled)
        XCTAssertEqual(WakeInspector.parseWakeForNetworkAccess(" womp                 0\n"), .disabled)
        XCTAssertEqual(WakeInspector.parseWakeForNetworkAccess(" sleep 1\n"), .unknown)
    }

    /// Runs the real read-only `pmset -g` off the main thread and returns;
    /// the old synchronous helper blocked (and spun) the caller's run loop.
    func testStatusLookupIsAsyncAndCompletes() async {
        let status = await WakeInspector.wakeForNetworkAccessStatus()
        XCTAssertTrue([.enabled, .disabled, .unknown].contains(status))
    }
}
