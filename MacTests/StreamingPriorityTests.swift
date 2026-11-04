import XCTest

final class StreamingPriorityTests: XCTestCase {

    // MARK: - Policy mapping (bounded encode-depth)

    func testAutoUsesBalancedDepthOfTwo() {
        XCTAssertEqual(StreamingPriorityPolicy.maxPendingEncodes(for: .auto), 2)
    }

    func testPreferLatencyTightensToOne() {
        XCTAssertEqual(StreamingPriorityPolicy.maxPendingEncodes(for: .preferLatency), 1)
    }

    func testPreferFPSOpensToThree() {
        XCTAssertEqual(StreamingPriorityPolicy.maxPendingEncodes(for: .preferFPS), 3)
    }

    func testEachPriorityMapsToADistinctDepth() {
        let depths = Set(StreamingPriority.allCases.map(StreamingPriorityPolicy.maxPendingEncodes(for:)))
        XCTAssertEqual(depths.count, StreamingPriority.allCases.count)
    }

    // MARK: - Enum/default parsing

    /// The pickers read Latency | Balanced | Smoothness, Balanced the default.
    /// Only the names and order changed: the raw values are what the wire and
    /// every saved setting carry, so an existing choice keeps its meaning.
    func testPickersShowLatencyBalancedSmoothnessOverUnchangedRawValues() {
        XCTAssertEqual(StreamingPriority.pickerOrder.map(\.label), ["Latency", "Balanced", "Smoothness"])
        XCTAssertEqual(StreamingPriority.pickerOrder.map(\.rawValue), ["preferLatency", "auto", "preferFPS"])
        XCTAssertEqual(Set(StreamingPriority.pickerOrder), Set(StreamingPriority.allCases))
        XCTAssertEqual(StreamingPriority.pickerOrder.count, StreamingPriority.allCases.count)
        XCTAssertEqual(StreamingPriority(rawValue: "") ?? .auto, .auto)
        XCTAssertEqual(StreamingPriority.auto.label, "Balanced")
    }

    func testAllCasesHaveNonEmptyLabelAndExplanation() {
        for priority in StreamingPriority.allCases {
            XCTAssertFalse(priority.label.isEmpty)
            XCTAssertFalse(priority.explanation.isEmpty)
        }
    }

    func testUnknownPersistedRawValueFallsBackToAuto() {
        // Simulates a downgrade/corrupted-defaults scenario, same shape as
        // StreamingProfile's fallback — must never crash the reload path.
        let reloaded = StreamingPriority(rawValue: "some-future-priority") ?? .auto
        XCTAssertEqual(reloaded, .auto)
    }

    func testAbsentPersistedValueResolvesToAuto() {
        // Existing users with no stored value must resolve to Auto.
        let reloaded = StreamingPriority(rawValue: "") ?? .auto
        XCTAssertEqual(reloaded, .auto)
    }

    // MARK: - Wire-version currency

    // Superseded as "the current version" by mirrorUnavailableWireVersion
    // (17) at a later milestone — see MirrorUnavailableOfferPolicyTests for
    // that canary now.
    func testStreamingPriorityWireVersionIsFixedAt16() {
        XCTAssertEqual(WireProtocol.streamingPriorityWireVersion, 16)
    }

    // MARK: - Persistence survives reload

    func testPersistedPrioritySurvivesReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(StreamingPriority.preferFPS.rawValue, forKey: "streamingPriority")
        let reloaded = StreamingPriority(rawValue: defaults.string(forKey: "streamingPriority") ?? "") ?? .auto
        XCTAssertEqual(reloaded, .preferFPS)

        defaults.set(StreamingPriority.preferLatency.rawValue, forKey: "streamingPriority")
        let reloadedAgain = StreamingPriority(rawValue: defaults.string(forKey: "streamingPriority") ?? "") ?? .auto
        XCTAssertEqual(reloadedAgain, .preferLatency)
    }
}
