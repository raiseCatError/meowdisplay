import Network
import XCTest

/// Mac/DiscoveryBrowserStateLog.swift: one privacy-safe line per Bonjour browser state change (#263).
final class DiscoveryBrowserStateLogTests: XCTestCase {
    private typealias Summary = DiscoveryBrowserStateSummary

    private let policyDenied = Summary(phase: .waiting, failure: .init(kind: .dns, code: -65570))

    func testReadyLogsOnceThenDedupes() {
        var log = DiscoveryBrowserStateLog()
        let ready = Summary(phase: .ready)
        XCTAssertEqual(log.line(for: ready, role: .receivers), "discovery: browser=receivers state=ready")
        XCTAssertNil(log.line(for: ready, role: .receivers))
    }

    func testWaitingWithPolicyDeniedIsLabelled() {
        var log = DiscoveryBrowserStateLog()
        XCTAssertEqual(log.line(for: policyDenied, role: .receivers),
                       "discovery: browser=receivers state=waiting error=dns:-65570 policyDenied")
    }

    func testWaitingWithOtherDNSErrorIsNotLabelled() {
        var log = DiscoveryBrowserStateLog()
        let other = Summary(phase: .waiting, failure: .init(kind: .dns, code: -65563))
        XCTAssertEqual(log.line(for: other, role: .receivers),
                       "discovery: browser=receivers state=waiting error=dns:-65563")
    }

    func testPolicyDeniedCodeOnANonDNSErrorIsNotLabelled() {
        var log = DiscoveryBrowserStateLog()
        let posix = Summary(phase: .waiting, failure: .init(kind: .posix, code: -65570))
        XCTAssertEqual(log.line(for: posix, role: .receivers),
                       "discovery: browser=receivers state=waiting error=posix:-65570")
    }

    func testFailedPosixErrorIsFormatted() {
        var log = DiscoveryBrowserStateLog()
        let failed = Summary(phase: .failed, failure: .init(kind: .posix, code: 50))
        XCTAssertEqual(log.line(for: failed, role: .quicHints),
                       "discovery: browser=quicHints state=failed error=posix:50")
    }

    func testChangedErrorCodeLogsAgain() {
        var log = DiscoveryBrowserStateLog()
        let first = Summary(phase: .waiting, failure: .init(kind: .dns, code: -65563))
        XCTAssertNotNil(log.line(for: first, role: .receivers))
        XCTAssertNil(log.line(for: first, role: .receivers))
        XCTAssertEqual(log.line(for: policyDenied, role: .receivers),
                       "discovery: browser=receivers state=waiting error=dns:-65570 policyDenied")
    }

    func testTheTwoBrowsersDedupeIndependently() {
        var log = DiscoveryBrowserStateLog()
        let ready = Summary(phase: .ready)
        XCTAssertEqual(log.line(for: ready, role: .receivers), "discovery: browser=receivers state=ready")
        XCTAssertEqual(log.line(for: ready, role: .quicHints), "discovery: browser=quicHints state=ready")
        XCTAssertNil(log.line(for: ready, role: .receivers))
        XCTAssertNil(log.line(for: ready, role: .quicHints))
    }

    func testCancelledIsLogged() {
        var log = DiscoveryBrowserStateLog()
        XCTAssertNotNil(log.line(for: Summary(phase: .ready), role: .receivers))
        XCTAssertEqual(log.line(for: Summary(phase: .cancelled), role: .receivers),
                       "discovery: browser=receivers state=cancelled")
    }

    func testNetworkStatesMapToSummaries() {
        XCTAssertEqual(Summary(.setup), Summary(phase: .setup))
        XCTAssertEqual(Summary(.ready), Summary(phase: .ready))
        XCTAssertEqual(Summary(.cancelled), Summary(phase: .cancelled))
        XCTAssertEqual(Summary(.waiting(.dns(-65570))), policyDenied)
        XCTAssertEqual(Summary(.failed(.posix(.ECONNREFUSED))),
                       Summary(phase: .failed, failure: .init(kind: .posix, code: 61)))
    }
}
