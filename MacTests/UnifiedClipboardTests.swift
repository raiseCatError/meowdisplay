import XCTest

/// Unified Clipboard ordering (PROTOCOL.md 6.15): no loops, no echoes, no clock-based
/// winners, reconnects are not copies, concurrent copies converge and keep the loser.
/// Also writes/checks fixtures/clipboard/vectors.json (WRITE_CLIPBOARD_VECTORS=1), which the
/// Android port replays.
final class UnifiedClipboardTests: XCTestCase {

    // MARK: Scenario runner (shared with the Android replay through the vectors file)

    /// One scripted step: `copy` (dev, hash), `recv` (dev, event "origin:seq"), `merge` (dev, from).
    private struct Step { var dev: String; var op: String; var hash: String? = nil; var event: String? = nil; var from: String? = nil }

    private func run(_ devices: [String], _ steps: [Step]) -> [[String: Any]] {
        var syncs = Dictionary(uniqueKeysWithValues: devices.map { ($0, ClipboardSync(origin: $0)) })
        var events: [String: ClipHeader] = [:]
        var out: [[String: Any]] = []
        func name(_ h: ClipHeader?) -> Any { h.map { "\($0.id.origin):\($0.id.seq)" } ?? NSNull() }
        for s in steps {
            var step: [String: Any] = ["dev": s.dev, "op": s.op]
            var expect: [String: Any] = [:]
            switch s.op {
            case "copy":
                step["hash"] = s.hash!
                if let h = syncs[s.dev]!.localCopy(contentHash: s.hash!) {
                    events["\(h.id.origin):\(h.id.seq)"] = h
                    expect["event"] = name(h)
                    expect["lc"] = Int(h.lamport)
                    expect["ctx"] = h.context.mapValues { Int($0) }
                } else {
                    expect["event"] = NSNull()
                }
            case "recv":
                step["event"] = s.event!
                let d = syncs[s.dev]!.receive(events[s.event!]!)
                expect["decision"] = d.rawValue
            case "merge":
                step["from"] = s.from!
                syncs[s.dev]!.merge(seen: syncs[s.from!]!.seen)
            default:
                XCTFail("unknown op")
            }
            expect["current"] = name(syncs[s.dev]!.current)
            expect["alt"] = name(syncs[s.dev]!.alternative)
            step["expect"] = expect
            out.append(step)
        }
        return out
    }

    private func copy(_ dev: String, _ hash: String) -> Step { Step(dev: dev, op: "copy", hash: hash) }
    private func recv(_ dev: String, _ event: String) -> Step { Step(dev: dev, op: "recv", event: event) }
    private func merge(_ dev: String, from: String) -> Step { Step(dev: dev, op: "merge", from: from) }

    private var scenarios: [(name: String, devices: [String], steps: [Step])] {
        [
            ("copy, apply, copy back", ["mac", "phone"], [
                copy("mac", "A"), recv("phone", "mac:1"),
                copy("phone", "A"),                      // the same content again: nothing new
                copy("phone", "B"), recv("mac", "phone:1"),
                recv("mac", "phone:1"),                  // a repeat
                recv("phone", "phone:1"),                // our own, coming back
            ]),
            ("simultaneous copies converge", ["mac", "phone"], [
                copy("mac", "X"), copy("phone", "Y"),
                recv("mac", "phone:1"), recv("phone", "mac:1"),
                copy("mac", "Z"), recv("phone", "mac:2"), // a later copy settles it and drops the alternative
            ]),
            ("a newer local copy is never overwritten by an older update", ["mac", "phone"], [
                copy("mac", "A"), recv("phone", "mac:1"),
                copy("phone", "B"),                      // saw mac:1
                copy("mac", "C"),                        // concurrent with phone:1
                recv("phone", "mac:2"), recv("mac", "phone:1"),
            ]),
            ("reconnect is not a copy", ["mac", "phone"], [
                copy("phone", "A"), merge("mac", from: "phone"),
                recv("mac", "phone:1"),                  // the reconnect hello said it was seen
                copy("phone", "B"), recv("mac", "phone:2"),
            ]),
            ("Mac relays between two receivers without loops", ["mac", "ipad", "moto"], [
                copy("ipad", "A"), recv("mac", "ipad:1"), recv("moto", "ipad:1"),
                recv("ipad", "ipad:1"),                  // relayed back by mistake: echo
                copy("moto", "B"), recv("mac", "moto:1"), recv("ipad", "moto:1"),
                copy("mac", "C"), recv("ipad", "mac:1"), recv("moto", "mac:1"),
                recv("moto", "moto:1"),
            ]),
            ("three-way race, everyone agrees", ["mac", "ipad", "moto"], [
                copy("mac", "M"), copy("ipad", "I"), copy("moto", "O"),
                recv("mac", "ipad:1"), recv("mac", "moto:1"),
                recv("ipad", "mac:1"), recv("ipad", "moto:1"),
                recv("moto", "mac:1"), recv("moto", "ipad:1"),
            ]),
            ("Lamport order beats origin order", ["mac", "phone"], [
                copy("mac", "A"), recv("phone", "mac:1"), copy("phone", "B"),   // phone lc 2
                copy("mac", "C"), copy("mac", "D"), copy("mac", "E"),            // mac lc 4, concurrent with phone:1
                recv("mac", "phone:1"), recv("phone", "mac:4"),
            ]),
        ]
    }

    private func vectors() -> [String: Any] {
        ["about": "Generated by MacTests/UnifiedClipboardTests.swift (WRITE_CLIPBOARD_VECTORS=1); replayed by the Android port.",
         "scenarios": scenarios.map { ["name": $0.name, "devices": $0.devices, "steps": run($0.devices, $0.steps)] }]
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/clipboard/vectors.json")
    }

    func testSharedVectors() throws {
        let generated = vectors()
        let data = try JSONSerialization.data(withJSONObject: generated, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["WRITE_CLIPBOARD_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL)
        }
        let saved = try Data(contentsOf: Self.fixtureURL)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: saved) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       "fixtures/clipboard/vectors.json is stale: rerun with WRITE_CLIPBOARD_VECTORS=1")
    }

    // MARK: The rules, stated directly

    private func last(_ out: [[String: Any]], _ i: Int) -> [String: Any] { out[i]["expect"] as! [String: Any] }

    func testApplyingAndRepeatsNeverMakeEventsOrLoops() {
        let out = run(["mac", "phone"], scenarios[0].steps)
        XCTAssertEqual(last(out, 1)["decision"] as? String, "apply")
        XCTAssertTrue(last(out, 2)["event"] is NSNull, "copying what is already shared makes no event")
        XCTAssertEqual(last(out, 4)["decision"] as? String, "apply")
        XCTAssertEqual(last(out, 5)["decision"] as? String, "duplicate")
        XCTAssertEqual(last(out, 6)["decision"] as? String, "echo")
    }

    func testSimultaneousCopiesConvergeAndKeepTheOther() {
        let out = run(["mac", "phone"], scenarios[1].steps)
        // Same Lamport counter: the larger origin id wins, on both devices.
        XCTAssertEqual(last(out, 2)["current"] as? String, "phone:1")
        XCTAssertEqual(last(out, 2)["alt"] as? String, "mac:1")
        XCTAssertEqual(last(out, 3)["decision"] as? String, "alternative")
        XCTAssertEqual(last(out, 3)["current"] as? String, "phone:1")
        XCTAssertEqual(last(out, 3)["alt"] as? String, "mac:1")
        XCTAssertEqual(last(out, 5)["current"] as? String, "mac:2")
        XCTAssertTrue(last(out, 5)["alt"] is NSNull)
    }

    func testOrderComesFromCausalityNotClocks() {
        let out = run(["mac", "phone"], scenarios[6].steps)
        // mac:4 has the higher Lamport counter: it wins on both sides although phone:1 was
        // copied "after" in nobody's clock.
        XCTAssertEqual(last(out, 6)["current"] as? String, "mac:4")
        XCTAssertEqual(last(out, 7)["current"] as? String, "mac:4")
        XCTAssertEqual(last(out, 7)["alt"] as? String, "phone:1")
    }

    func testThreeWayRaceAgreesEverywhere() {
        let out = run(["mac", "ipad", "moto"], scenarios[5].steps)
        let finals = [4, 6, 8].map { last(out, $0)["current"] as? String }
        XCTAssertEqual(Set(finals.compactMap { $0 }), ["moto:1"])
    }

    func testReconnectIsNotACopy() {
        let out = run(["mac", "phone"], scenarios[3].steps)
        XCTAssertEqual(last(out, 2)["decision"] as? String, "duplicate")
        XCTAssertEqual(last(out, 4)["decision"] as? String, "apply")
    }

    // MARK: Wire

    func testEventsRoundTripAndHostileOnesAreRefused() throws {
        var sync = ClipboardSync(origin: "mac-1")
        let rep = ClipRep(kind: .text, size: 5, hash: ClipHash.of(Data("hello".utf8)), inline: Data("hello".utf8))
        let big = ClipRep(kind: .png, size: 900_000, hash: "0123456789abcdef", blob: 0)
        let files = [ClipFile(path: ["Folder"], size: 0, dir: true), ClipFile(path: ["Folder", "a.txt"], size: 12, dir: false, blob: 1)]
        let items = [ClipItem(reps: [rep, big])]
        let header = try XCTUnwrap(sync.localCopy(contentHash: ClipEvent.contentHash(items: items, files: files)))
        let event = ClipEvent(header: header, at: 1_700_000_000_000, items: items, files: files)
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: event.wire)) as! [String: Any]
        XCTAssertEqual(ClipEvent.parse(json), event)
        XCTAssertEqual(event.summary, "1 item")

        for bad in [["..", "x"], ["a/b"], ["a\0"], [""], ["a\\b"]] {
            var j = json
            j["files"] = [["p": bad, "n": 1, "dir": false, "b": 1]]
            XCTAssertNil(ClipEvent.parse(j), "\(bad) could leave its folder")
        }
        var noData = json
        noData["items"] = [["reps": [["t": "text", "n": 5, "h": "0123456789abcdef"]]]]
        noData["files"] = nil
        XCTAssertNil(ClipEvent.parse(noData), "a representation with neither bytes nor a blob")
        var unknown = json
        unknown["items"] = [["reps": [["t": "com.example.secret", "n": 5, "h": "0123456789abcdef", "b": 3], ["t": "text", "n": 5, "h": rep.hash, "d": "aGVsbG8="]]]]
        XCTAssertEqual(ClipEvent.parse(unknown)?.items.first?.reps.map(\.kind), [.text], "unknown types are skipped, not fatal")
        var lying = json
        lying["items"] = [["reps": [["t": "text", "n": 9, "h": rep.hash, "d": "aGVsbG8="]]]]
        XCTAssertNil(ClipEvent.parse(lying), "inline bytes must match the declared size")
    }

    func testBlobsArriveVerifiedRangeByRange() {
        let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
        let id = ClipEventID(origin: "mac-1", seq: 3)
        var fetch = ClipBlobFetch(req: 9, id: id, blob: 0, size: bytes.count, expectedHash: ClipHash.of(bytes))
        var assembled = Data()
        var reads = 0
        while let read = fetch.nextRead() {
            reads += 1
            let off = read["off"] as! Int, n = read["n"] as! Int
            XCTAssertLessThanOrEqual(n, ClipboardWire.readMax)
            for m in ClipBlobWire.answer(req: 9, offset: off, bytes: bytes.subdata(in: off..<off + n)) {
                switch fetch.handle(m) {
                case .more: break
                case .rangeDone(let d): assembled.append(d)
                case .failed(let e): return XCTFail(e)
                }
            }
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(assembled, bytes)

        // A tampered part fails the range; an error ends the fetch with its code.
        var bad = ClipBlobFetch(req: 1, id: id, blob: 0, size: 10, expectedHash: nil)
        _ = bad.nextRead()
        var parts = ClipBlobWire.answer(req: 1, offset: 0, bytes: Data(repeating: 1, count: 10))
        parts[0]["d"] = Data(repeating: 2, count: 10).base64EncodedString()
        XCTAssertEqual(bad.handle(parts[0]), .more)
        XCTAssertEqual(bad.handle(parts[1]), .failed("digest"))
        var gone = ClipBlobFetch(req: 2, id: id, blob: 0, size: 10, expectedHash: nil)
        _ = gone.nextRead()
        XCTAssertEqual(gone.handle(ClipBlobWire.answer(req: 2, offset: 0, bytes: nil, error: "changed")[0]), .failed("changed"))
        // A whole-blob digest that doesn't match fails at the end.
        var wrong = ClipBlobFetch(req: 3, id: id, blob: 0, size: 4, expectedHash: "0000000000000000")
        _ = wrong.nextRead()
        let ok = ClipBlobWire.answer(req: 3, offset: 0, bytes: Data([1, 2, 3, 4]))
        XCTAssertEqual(wrong.handle(ok[0]), .more)
        XCTAssertEqual(wrong.handle(ok[1]), .failed("digest"))
        // More than the outstanding read asked for is refused before it is buffered.
        var big = ClipBlobFetch(req: 4, id: id, blob: 0, size: 5_000_000, expectedHash: nil)
        let first = big.nextRead()!
        XCTAssertEqual(first["n"] as? Int, ClipboardWire.readMax)
        var off = 0, step = ClipBlobFetch.Step.more
        while step == .more, off < 400_000 {
            step = big.handle(["op": "data", "off": off, "d": Data(count: ClipboardWire.partBytes).base64EncodedString()])
            off += ClipboardWire.partBytes
        }
        XCTAssertEqual(step, .failed("badRange"))
        XCTAssertLessThanOrEqual(off, ClipboardWire.readMax + ClipboardWire.partBytes)
    }
}
