import XCTest

/// iPhone/iPad Auto-Lock: held off only while a Mac's picture is watched in the foreground, with
/// a short grace for reconnects (Shared/ScreenAwakePolicy.swift).
final class ScreenAwakePolicyTests: XCTestCase {
    private func i(enabled: Bool = true, foreground: Bool = true, watching: Bool = true, streaming: Bool = true) -> ScreenAwakePolicy.Inputs {
        .init(enabled: enabled, foreground: foreground, watching: watching, streaming: streaming)
    }

    func testAwakeOnlyWhileTheMacsPictureIsWatchedInTheForeground() {
        XCTAssertTrue(ScreenAwakePolicy.decide(i(), sinceStreaming: 0).awake, "Mirror, Extend or Window mode, on screen")
        XCTAssertFalse(ScreenAwakePolicy.decide(i(foreground: false), sinceStreaming: 0).awake, "backgrounded")
        XCTAssertFalse(ScreenAwakePolicy.decide(i(watching: false), sinceStreaming: 0).awake, "Home, Settings or the demo")
        XCTAssertFalse(ScreenAwakePolicy.decide(i(enabled: false), sinceStreaming: 0).awake, "turned off in Settings")
        XCTAssertFalse(ScreenAwakePolicy.decide(i(streaming: false), sinceStreaming: nil).awake, "never streamed: disconnected")
        XCTAssertTrue(ScreenAwakePolicy.defaultEnabled, "on by default")
    }

    func testALostConnectionKeepsItAwakeBrieflyThenAutoLockReturns() {
        let early = ScreenAwakePolicy.decide(i(streaming: false), sinceStreaming: 5)
        XCTAssertTrue(early.awake, "a quick reconnect doesn't let the screen lock")
        XCTAssertEqual(early.recheckIn ?? 0, ScreenAwakePolicy.reconnectGrace - 5, accuracy: 1e-9, "looks again when the grace ends")
        let late = ScreenAwakePolicy.decide(i(streaming: false), sinceStreaming: ScreenAwakePolicy.reconnectGrace)
        XCTAssertFalse(late.awake, "a connection that stays failed gives Auto-Lock back")
        XCTAssertNil(late.recheckIn)
        XCTAssertNil(ScreenAwakePolicy.decide(i(), sinceStreaming: 0).recheckIn, "streaming needs no timer")
        XCTAssertFalse(ScreenAwakePolicy.decide(i(streaming: false), sinceStreaming: -1).awake, "a clock oddity never holds it awake")
    }
}
