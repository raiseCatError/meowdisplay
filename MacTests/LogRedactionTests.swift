import XCTest

final class LogRedactionTests: XCTestCase {
    private func r(_ s: String) -> String { LogRedaction.redact(s) }

    func testIPv4KeepsOnlyTheFirstOctet() {
        XCTAssertEqual(r("dialing 100.101.102.103:9001"), "dialing 100.x.x.x:9001")
        XCTAssertEqual(r("lan=192.168.1.20 ok"), "lan=192.x.x.x ok")
        XCTAssertEqual(r("bound 127.0.0.1 and 0.0.0.0"), "bound 127.0.0.1 and 0.0.0.0")
        XCTAssertEqual(r("version 2.0.0.1234"), "version 2.0.0.1234", "a four-part build number isn't an address")
        XCTAssertEqual(r("ratio 1.5 at 30.0 fps"), "ratio 1.5 at 30.0 fps")
    }

    func testIPv6AndMACKeepOnlyTheFirstGroup() {
        XCTAssertEqual(r("tailnet fd7a:115c:a1e0::1234 up"), "tailnet fd7a:… up")
        XCTAssertEqual(r("link fe80::1c2b:3d4e%en0"), "link fe80:…")
        XCTAssertEqual(r("wake aa:bb:cc:dd:ee:ff"), "wake aa:…")
        XCTAssertEqual(r("[22:45:53.593] connected"), "[22:45:53.593] connected", "timestamps stay")
        XCTAssertEqual(r("at 12:34:56"), "at 12:34:56")
    }

    func testMagicDNSNamesAndUUIDs() {
        XCTAssertEqual(r("host my-mac.tail1234.ts.net"), "host ….ts.net")
        XCTAssertEqual(r("peerID=3F2504E0-4F89-11D3-9A0C-0305E82C3301 paired"), "peerID=3F2504E0… paired")
    }

    func testOrdinaryLinesAreUnchanged() {
        let line = "capture started: 2556x1179 display 3 at 120 fps (HEVC)"
        XCTAssertEqual(r(line), line)
        XCTAssertEqual(r("no punctuation here"), "no punctuation here")
    }
}
