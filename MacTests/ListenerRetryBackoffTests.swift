import XCTest

final class ListenerRetryBackoffTests: XCTestCase {
    func testTheDelayDoublesUpToAMinuteAndResetsWhenReady() {
        var backoff = ListenerRetryBackoff()
        XCTAssertEqual((0..<9).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        backoff.ready()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testOnlySomeFailuresAreLogged() {
        var backoff = ListenerRetryBackoff()
        var logged: [Int] = []
        for _ in 0..<30 {
            _ = backoff.nextDelay()
            if backoff.shouldLog { logged.append(backoff.failures) }
        }
        XCTAssertEqual(logged, [1, 2, 3, 10, 20, 30])
    }
}
