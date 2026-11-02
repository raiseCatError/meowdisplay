import XCTest

/// Large control messages in parts (PROTOCOL.md 6.14): every part fits a control frame, and the
/// receiver reassembles only an ordered, complete, digest-checked message within its bounds.
final class ControlChunksTests: XCTestCase {
    private func message(_ bytes: Int) -> Data {
        let jpeg = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).base64EncodedString()
        return try! JSONSerialization.data(withJSONObject: ["type": "files", "op": "preview", "ok": true, "jpeg": jpeg])
    }

    private func assemble(_ parts: [[String: Any]], into a: inout ControlChunkAssembler, now: TimeInterval = 0) -> ControlChunkAssembler.Outcome {
        var last = ControlChunkAssembler.Outcome.pending
        for p in parts { last = a.add(p, now: now) }
        return last
    }

    func testRoundTripAndEveryPartFitsOneControlFrame() throws {
        for size in [1, 16_000, 22_000, 23_999, 520_000, 2_900_000] {
            let m = message(size)
            let parts = try XCTUnwrap(ControlChunkWire.split(m, id: 9))
            for p in parts {
                let frame = try JSONSerialization.data(withJSONObject: p)
                XCTAssertLessThan(frame.count, 32_768, "a part must pass PROTOCOL.md 4's control test")
                XCTAssertEqual(frame.first, UInt8(ascii: "{"))
                XCTAssertFalse(frame.contains(0))
            }
            var a = ControlChunkAssembler()
            XCTAssertEqual(assemble(parts, into: &a), .complete(m))
            XCTAssertEqual(a.inFlight, 0)
        }
    }

    func testInterleavedMessagesAssembleIndependently() throws {
        let m1 = message(60_000), m2 = message(90_000)
        let p1 = try XCTUnwrap(ControlChunkWire.split(m1, id: 1)), p2 = try XCTUnwrap(ControlChunkWire.split(m2, id: 2))
        var a = ControlChunkAssembler()
        var done: [Data] = []
        for k in 0..<max(p1.count, p2.count) {
            for p in [p1, p2] where k < p.count {
                if case .complete(let d) = a.add(p[k], now: 1) { done.append(d) }
            }
        }
        XCTAssertEqual(Set(done), [m1, m2])
    }

    func testGapReorderDuplicateAndMissingStartAreDropped() throws {
        let parts = try XCTUnwrap(ControlChunkWire.split(message(100_000), id: 3))
        XCTAssertGreaterThan(parts.count, 3)
        var a = ControlChunkAssembler()
        XCTAssertEqual(a.add(parts[0], now: 0), .pending)
        XCTAssertEqual(a.add(parts[2], now: 0), .dropped("out of order"))
        XCTAssertEqual(a.inFlight, 0, "a gap abandons the whole message")
        XCTAssertEqual(a.add(parts[1], now: 0), .dropped("no start"))
        var b = ControlChunkAssembler()
        _ = b.add(parts[0], now: 0); _ = b.add(parts[1], now: 0)
        XCTAssertEqual(b.add(parts[1], now: 0), .dropped("out of order"), "a repeated part is a gap too")
    }

    func testDigestLengthAndHeaderAreChecked() throws {
        var parts = try XCTUnwrap(ControlChunkWire.split(message(50_000), id: 4))
        parts[0]["sha"] = "0000000000000000"
        var a = ControlChunkAssembler()
        XCTAssertEqual(assemble(parts, into: &a), .dropped("digest"))

        var big = try XCTUnwrap(ControlChunkWire.split(message(50_000), id: 5))
        big[0]["len"] = ControlChunkWire.maxTotalBytes + 1
        XCTAssertEqual(a.add(big[0], now: 0), .dropped("bad header"))

        var short = try XCTUnwrap(ControlChunkWire.split(message(50_000), id: 6))
        short[0]["len"] = (short[0]["len"] as! Int) - 10
        XCTAssertEqual(assemble(short, into: &a), .dropped("too long"))

        var junk = try XCTUnwrap(ControlChunkWire.split(message(50_000), id: 7))
        junk[1]["d"] = "%%%not base64%%%"
        var c = ControlChunkAssembler()
        _ = c.add(junk[0], now: 0)
        XCTAssertEqual(c.add(junk[1], now: 0), .dropped("bad base64"))
        XCTAssertEqual(c.inFlight, 0)
        XCTAssertNil(ControlChunkWire.split(Data(count: ControlChunkWire.maxTotalBytes + 1), id: 1), "the sender never splits past the bound")
    }

    func testStalePartialsExpireAndInFlightIsBounded() throws {
        var a = ControlChunkAssembler()
        let parts = (1...6).map { try! XCTUnwrap(ControlChunkWire.split(message(40_000), id: $0)) }
        for (k, p) in parts.enumerated() { _ = a.add(p[0], now: Double(k)) }
        XCTAssertEqual(a.inFlight, ControlChunkWire.maxInFlight, "the oldest is evicted")
        XCTAssertEqual(a.add(parts[0][1], now: 6), .dropped("no start"), "id 1 was the oldest")
        XCTAssertEqual(a.add(parts[5][1], now: 6 + ControlChunkWire.timeout + 1), .dropped("no start"), "timed out")
        XCTAssertEqual(a.inFlight, 0)
    }

    /// fixtures/receiver-protocol/control-chunks.json, shared with the Kotlin receiver.
    func testSharedVector() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/receiver-protocol/control-chunks.json")
        let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let message = Data((v["message"] as! String).utf8)
        let expected = v["parts"] as! [[String: Any]]
        XCTAssertEqual(ControlChunkWire.digest(message), v["sha"] as? String)
        let parts = try XCTUnwrap(ControlChunkWire.split(message, id: v["id"] as! Int, partBytes: v["partBytes"] as! Int))
        XCTAssertEqual(parts.map { $0 as NSDictionary }, expected.map { $0 as NSDictionary })
        var a = ControlChunkAssembler()
        XCTAssertEqual(assemble(expected, into: &a), .complete(message))
    }
}
