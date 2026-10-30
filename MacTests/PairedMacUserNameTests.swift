import XCTest

/// The Mac's user name reaches paired devices only through the authenticated welcome, can be
/// turned off on the Mac, and is cleaned before it's shown.
final class PairedMacUserNameTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "PairedMacUserNameTests-\(UUID().uuidString)")! }

    func testTheMacSendsItsUserUnlessTurnedOff() {
        let d = defaults()
        XCTAssertEqual(PairedMacUserName.outgoing(defaults: d, fullName: "Jai Sukka"), "Jai Sukka", "on by default")
        d.set(false, forKey: PairedMacUserName.showKey)
        XCTAssertNil(PairedMacUserName.outgoing(defaults: d, fullName: "Jai Sukka"))
    }

    func testNamesAreCleanedAndCapped() {
        XCTAssertEqual(PairedMacUserName.clean("  Jai\nSukka\u{0007} "), "JaiSukka")
        XCTAssertNil(PairedMacUserName.clean("   "))
        XCTAssertEqual(PairedMacUserName.clean(String(repeating: "x", count: 200))?.count, PairedMacUserName.maxLength)
    }

    func testAReceiverKeepsItPerMacAndDropsItWhenTheMacStopsSending() {
        let d = defaults()
        PairedMacUserName.record("Jai Sukka", peerID: "mac-A", defaults: d)
        PairedMacUserName.record("Other Person", peerID: "mac-B", defaults: d)
        XCTAssertEqual(PairedMacUserName.name(peerID: "mac-A", defaults: d), "Jai Sukka")
        XCTAssertEqual(PairedMacUserName.name(peerID: "mac-B", defaults: d), "Other Person")
        PairedMacUserName.record(nil, peerID: "mac-A", defaults: d)   // turned off on that Mac
        XCTAssertNil(PairedMacUserName.name(peerID: "mac-A", defaults: d))
        PairedMacUserName.record("Someone", peerID: nil, defaults: d)  // no authenticated peer: ignored
        XCTAssertEqual(PairedMacUserName.name(peerID: "mac-B", defaults: d), "Other Person")
    }
}
