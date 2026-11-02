import XCTest
@testable import ShieldCore

final class KeeperPolicyTests: XCTestCase {
    func testNothingTheAppSendsUncovers() {
        var p = KeeperPolicy(nonce: "n")
        XCTAssertEqual(p.handle(.peer(.cover(session: "a"))), [.showCovers])
        for line in [#"{"cmd":"uncover"}"#, #"{"cmd":"hide"}"#, #"{"cmd":"unlock","password":"x"}"#, "garbage"] {
            let actions = p.handle(.peer(WireMessage.parse(line)))
            XCTAssertFalse(actions.contains(.hideCovers), line)
        }
        _ = p.handle(.peer(.sessionEnded(session: "a")))
        XCTAssertEqual(p.phase, .held, "ending the session keeps the cover")
    }

    func testOnlyPhysicalInputWithThePasswordUnlocks() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "a")))
        XCTAssertFalse(p.handle(.localUnlock(physical: false, authenticated: true)).contains(.hideCovers))
        XCTAssertFalse(p.handle(.localUnlock(physical: true, authenticated: false)).contains(.hideCovers))
        XCTAssertTrue(p.isCovering)
        XCTAssertEqual(p.handle(.localUnlock(physical: true, authenticated: true)),
                       [.hideCovers, .log("unlocked with this Mac's login password"), .notifyPeerUnlocked])
        XCTAssertEqual(p.phase, .idle)
    }

    func testACrashWhileCoveringKeepsTheCoverAndLocks() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "a")))
        let actions = p.handle(.peerGone)
        XCTAssertTrue(actions.contains(.lockScreen))
        XCTAssertFalse(actions.contains(.hideCovers))
        XCTAssertFalse(actions.contains(.exitProcess))
        XCTAssertEqual(p.phase, .held)
        XCTAssertEqual(p.handle(.peerGone), [], "reported once")
    }

    func testACleanQuitWhileCoveringStaysCoveredWithoutLocking() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "a")))
        _ = p.handle(.peer(.cleanQuit(nonce: "n")))
        let actions = p.handle(.peerGone)
        XCTAssertFalse(actions.contains(.lockScreen))
        XCTAssertFalse(actions.contains(.hideCovers))
        XCTAssertEqual(p.phase, .held)
        XCTAssertEqual(p.handle(.localUnlock(physical: true, authenticated: true)).last, .exitProcess,
                       "after unlock with no app, the keeper leaves")
    }

    func testAForgedCleanQuitStillCountsAsACrash() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "a")))
        _ = p.handle(.peer(.cleanQuit(nonce: "guess")))
        XCTAssertTrue(p.handle(.peerGone).contains(.lockScreen))
    }

    func testNoOrphanWhenNothingIsCovered() {
        var p = KeeperPolicy(nonce: "n")
        XCTAssertEqual(p.handle(.peerGone).last, .exitProcess)
        var q = KeeperPolicy(nonce: "n")
        _ = q.handle(.peer(.cover(session: "a")))
        _ = q.handle(.localUnlock(physical: true, authenticated: true))
        XCTAssertEqual(q.handle(.peerGone).last, .exitProcess)
    }

    func testAHungKeeperLocksBeforeItsCoverGoes() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "a")))
        let actions = p.handle(.mainThreadStalled)
        XCTAssertEqual(actions.filter { $0 != .log("main thread stalled while covering: locking, then exiting") },
                       [.lockScreen, .exitProcess], "lock comes first")
    }

    func testSessionsAreCounted() {
        var p = KeeperPolicy(nonce: "n")
        _ = p.handle(.peer(.cover(session: "iPhone")))
        _ = p.handle(.peer(.cover(session: "iPad")))
        _ = p.handle(.peer(.sessionEnded(session: "iPhone")))
        XCTAssertEqual(p.phase, .covering(["iPad"]))
        _ = p.handle(.peer(.sessionEnded(session: "iPad")))
        XCTAssertEqual(p.phase, .held)
        _ = p.handle(.peer(.cover(session: "Moto")))
        XCTAssertEqual(p.phase, .covering(["Moto"]))
    }

    func testWireRoundTrip() {
        for m in [WireMessage.cover(session: "a"), .sessionEnded(session: "b"), .cleanQuit(nonce: "c")] {
            XCTAssertEqual(WireMessage.parse(String(m.line.dropLast())), m)
        }
        XCTAssertEqual(KeeperHello.parse(String(KeeperHello(nonce: "z").line.dropLast())), KeeperHello(nonce: "z"))
    }
}
