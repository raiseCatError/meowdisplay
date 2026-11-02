import XCTest

/// `Mac/StartupHandoffPolicy.swift`: session startup runs once, so a connection
/// superseded before capture starts must hand startup on — the empty Window mode
/// picker over Personal Hotspot (QUIC hello, then the TCP hot swap ~60 ms later).
final class StartupHandoffPolicyTests: XCTestCase {
    func testInitialConnectionStartsCapture() {
        XCTAssertEqual(StartupHandoffPolicy.afterHello(isLive: true, attempt: 0, stopped: false), .proceed)
        XCTAssertEqual(StartupHandoffPolicy.afterAdmission(admittedGeneration: 1, helloGeneration: 1, isAdmitted: true,
                                                           attempt: 0, stopped: false), .proceed)
    }

    func testHotspotSwitchToTCPBeforeCaptureFollowsTheNewConnection() {
        // QUIC hello at generation 1, superseded by the TCP connection before admission.
        XCTAssertEqual(StartupHandoffPolicy.afterHello(isLive: false, attempt: 0, stopped: false), .follow)
        // Admission lands for generation 3 while the hello we hold is still generation 1.
        XCTAssertEqual(StartupHandoffPolicy.afterAdmission(admittedGeneration: 3, helloGeneration: 1, isAdmitted: true,
                                                           attempt: 0, stopped: false), .follow)
        // Next pass: TCP generation 3 hello, admitted — capture starts.
        XCTAssertEqual(StartupHandoffPolicy.afterHello(isLive: true, attempt: 1, stopped: false), .proceed)
        XCTAssertEqual(StartupHandoffPolicy.afterAdmission(admittedGeneration: 3, helloGeneration: 3, isAdmitted: true,
                                                           attempt: 1, stopped: false), .proceed)
    }

    func testReconnectBeforeCaptureFollowsButAdmissionStaysRequired() {
        XCTAssertEqual(StartupHandoffPolicy.afterAdmission(admittedGeneration: 2, helloGeneration: 2, isAdmitted: false,
                                                           attempt: 0, stopped: false), .follow,
                       "an admission revoked by a reconnect never starts capture")
    }

    func testStopOrEndlessChurnEndsStartup() {
        XCTAssertEqual(StartupHandoffPolicy.afterHello(isLive: true, attempt: 0, stopped: true), .giveUp)
        XCTAssertEqual(StartupHandoffPolicy.afterHello(isLive: false, attempt: StartupHandoffPolicy.limit - 1, stopped: false), .giveUp)
        XCTAssertEqual(StartupHandoffPolicy.afterAdmission(admittedGeneration: 2, helloGeneration: 1, isAdmitted: true,
                                                           attempt: StartupHandoffPolicy.limit - 1, stopped: false), .giveUp)
    }
}
