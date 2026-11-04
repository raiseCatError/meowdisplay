import XCTest

/// One Streaming setting change restarts streaming once, whether it came from
/// a receiver's request or from Settings ▸ Streaming.
final class StreamingRestartLedgerTests: XCTestCase {
    private let base = StreamingRestartLedger.Settings(mode: .custom, profile: .performance, customFrameRate: .auto,
                                                      priority: .auto, codec: .auto, quality: .best)

    func testAReceiverRequestRestartsOnceEvenWithTheStreamingWindowOpen() {
        var ledger = StreamingRestartLedger()
        var requested = base
        requested.priority = .preferLatency
        // The request handler applies the change and restarts.
        ledger.restarted(with: requested)
        // The open window's onChange then sees the same change: no second restart.
        XCTAssertFalse(ledger.needsRestart(for: requested))
    }

    func testAProfileRequestSettingTwoValuesRestartsOnce() {
        var ledger = StreamingRestartLedger()
        var requested = base
        requested.profile = .custom
        requested.customFrameRate = CustomFrameRateSelection.allCases.last!
        ledger.restarted(with: requested)
        XCTAssertFalse(ledger.needsRestart(for: requested), "profile onChange")
        XCTAssertFalse(ledger.needsRestart(for: requested), "frame rate onChange")
    }

    func testAChangeMadeInTheWindowRestarts() {
        var ledger = StreamingRestartLedger()
        XCTAssertTrue(ledger.needsRestart(for: base), "nothing rebuilt yet")
        ledger.restarted(with: base)
        for change in [\StreamingRestartLedger.Settings.quality] as [WritableKeyPath<StreamingRestartLedger.Settings, StreamQuality>] {
            var edited = base
            edited[keyPath: change] = StreamQuality.allCases.first { $0 != base.quality }!
            XCTAssertTrue(ledger.needsRestart(for: edited))
        }
        var edited = base
        edited.codec = CodecPreference.allCases.first { $0 != base.codec }!
        XCTAssertTrue(ledger.needsRestart(for: edited))
        ledger.restarted(with: edited)
        XCTAssertTrue(ledger.needsRestart(for: base), "changing it back restarts again")
    }
}
