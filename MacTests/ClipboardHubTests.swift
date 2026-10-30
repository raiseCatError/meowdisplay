import AppKit
import XCTest

/// The Mac's Unified Clipboard end to end with two fake devices, on a private pasteboard and a
/// private settings suite (never the owner's clipboard or settings): grants, copies both
/// ways, relay without loops, ranged fetches, private items, Pause and Block.
@MainActor
final class ClipboardHubTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var pb: NSPasteboard!
    private var staging: URL!
    private var hub: ClipboardHub!
    private var outbox: [String: [[String: Any]]] = [:]

    override func setUp() async throws {
        suite = "clipboard-hub-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        pb = NSPasteboard.withUniqueName()
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("clip-hub-\(UUID().uuidString)")
        hub = ClipboardHub(defaults: defaults, pasteboard: pb, origin: "mac-1", staging: staging)
        hub.anySessionHasEffectiveInput = { false }
        outbox = [:]
    }

    override func tearDown() async throws {
        pb.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: staging)
    }

    private func ref(_ name: String) -> ClipboardPeerRef {
        ClipboardPeerRef(sessionID: "s-\(name)", peerID: "install-\(name)", name: name, generation: 1,
                         send: { [weak self] m in self?.outbox[name, default: []].append(m) })
    }

    private func take(_ name: String, op: String? = nil) -> [[String: Any]] {
        let all = outbox[name] ?? []
        outbox[name] = []
        return op.map { o in all.filter { $0["op"] as? String == o } } ?? all
    }

    private func join(_ name: String, dir: ClipDirection = .both) {
        hub.handle(ref(name), ["type": "clip", "op": "join", "on": true, "dir": dir.rawValue, "types": "all", "files": true, "max": 10_000_000])
    }

    private func allow(_ name: String, _ access: ClipboardAccess = .always, direction: ClipDirection = .both) {
        ClipboardDevicePolicyStore.setPolicy(ClipboardDevicePolicy(access: access, direction: direction), peerID: "install-\(name)",
                                             anySessionHasEffectiveInput: false, defaults: defaults)
    }

    private func copyOnMac(_ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        hub.pollNow()
    }

    private func event(from origin: String, seq: Int, text: String, context: [String: Int] = [:]) -> [String: Any] {
        var sync = ClipboardSync(origin: origin, seq: UInt64(seq - 1), lamport: UInt64(seq - 1))
        sync.merge(seen: context.mapValues { UInt64($0) })
        let data = Data(text.utf8)
        let rep = data.count <= ClipboardWire.inlineBytes
            ? ClipRep(kind: .text, size: data.count, hash: ClipHash.of(data), inline: data)
            : ClipRep(kind: .text, size: data.count, hash: ClipHash.of(data), blob: 0)
        let items = [ClipItem(reps: [rep])]
        let h = sync.localCopy(contentHash: ClipEvent.contentHash(items: items, files: []))!
        return ClipEvent(header: h, at: 0, items: items, files: []).wire
    }

    func testOffUntilEnabledAndBlockedDevicesGetNothing() {
        join("phone")
        XCTAssertEqual(take("phone", op: "state").last?["state"] as? String, "off")
        allow("phone", .block)
        hub.enabled = true
        XCTAssertEqual(take("phone", op: "state").last?["state"] as? String, "denied")
        copyOnMac("secret")
        XCTAssertTrue(take("phone", op: "event").isEmpty)
        hub.handle(ref("phone"), event(from: "install-phone", seq: 1, text: "from phone"))
        XCTAssertEqual(pb.string(forType: .string), "secret", "a blocked device's copy never lands")
    }

    func testCopiesFlowBothWaysAndTheRelayNeverLoops() throws {
        hub.enabled = true
        allow("ipad"); allow("moto")
        join("ipad"); join("moto")
        let state = try XCTUnwrap(take("ipad", op: "state").last)
        XCTAssertEqual(state["state"] as? String, "ready")
        XCTAssertEqual(state["toDevice"] as? Bool, true)
        XCTAssertEqual(state["toMac"] as? Bool, true)
        _ = take("moto")

        // A copy on the Mac goes to both devices, with the Mac as its origin.
        copyOnMac("héllo ✓\nline 2")
        for d in ["ipad", "moto"] {
            let e = try XCTUnwrap(take(d, op: "event").first.flatMap(ClipEvent.parse))
            XCTAssertEqual(e.id.origin, "mac-1")
            XCTAssertEqual(e.items.first?.rep(.text)?.inline, Data("héllo ✓\nline 2".utf8))
        }
        hub.pollNow()
        XCTAssertTrue(take("ipad", op: "event").isEmpty, "no change, no event")

        // The iPad's copy lands on the Mac's pasteboard and goes on to the Moto, not back.
        hub.handle(ref("ipad"), event(from: "install-ipad", seq: 1, text: "from iPad", context: ["mac-1": 1]))
        XCTAssertEqual(pb.string(forType: .string), "from iPad")
        XCTAssertTrue(take("ipad", op: "event").isEmpty, "never back to its origin")
        let relayed = try XCTUnwrap(take("moto", op: "event").first.flatMap(ClipEvent.parse))
        XCTAssertEqual(relayed.id, ClipEventID(origin: "install-ipad", seq: 1))
        // MeowDisplay's own write is not a new Mac copy.
        hub.pollNow()
        XCTAssertTrue(take("moto", op: "event").isEmpty)
        XCTAssertTrue(take("ipad", op: "event").isEmpty)
        // A repeat changes nothing.
        hub.handle(ref("moto"), relayed.wire)
        XCTAssertEqual(pb.string(forType: .string), "from iPad")
        XCTAssertEqual(hub.lastTransfer?.toMac, true)
    }

    func testLargeCopiesAreFetchedAndServedInVerifiedRanges() throws {
        hub.enabled = true
        allow("phone"); allow("tablet")
        join("phone"); join("tablet")
        _ = take("phone"); _ = take("tablet")

        // From the phone: the Mac asks for the blob range by range.
        let big = String(repeating: "abcdefghij", count: 30_000)   // 300 KB
        hub.handle(ref("phone"), event(from: "install-phone", seq: 1, text: big))
        var guardCount = 0
        while let read = take("phone", op: "read").first, guardCount < 10 {
            guardCount += 1
            let off = read["off"] as! Int, n = read["n"] as! Int
            let bytes = Data(big.utf8).subdata(in: off..<off + n)
            for m in ClipBlobWire.answer(req: read["req"] as! Int, offset: off, bytes: bytes) { hub.handle(ref("phone"), m) }
        }
        XCTAssertEqual(guardCount, 2)
        XCTAssertEqual(pb.string(forType: .string), big)

        // The tablet gets it from the Mac, which now serves what it fetched.
        let e = try XCTUnwrap(take("tablet", op: "event").first.flatMap(ClipEvent.parse))
        let rep = try XCTUnwrap(e.items.first?.rep(.text))
        XCTAssertNil(rep.inline)
        var fetch = ClipBlobFetch(req: 1, id: e.id, blob: rep.blob!, size: rep.size, expectedHash: rep.hash)
        var got = Data()
        while let read = fetch.nextRead() {
            hub.handle(ref("tablet"), read)
            let exp = expectation(description: "served")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
            wait(for: [exp], timeout: 2)
            for m in take("tablet") {
                if case .rangeDone(let d) = fetch.handle(m) { got.append(d) }
            }
        }
        XCTAssertEqual(got, Data(big.utf8))
    }

    func testPrivateItemsPauseAndOneWayDevices() throws {
        hub.enabled = true
        allow("phone", direction: .toMac)
        join("phone")
        XCTAssertEqual(take("phone", op: "state").last?["toDevice"] as? Bool, false)
        copyOnMac("not for the phone")
        XCTAssertTrue(take("phone", op: "event").isEmpty, "Device to Mac only")

        allow("phone")
        hub.setPolicy(ClipboardDevicePolicy(access: .always, direction: .both), peerID: "install-phone")
        _ = take("phone")
        pb.clearContents()
        pb.setString("hunter2", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        hub.pollNow()
        XCTAssertTrue(take("phone", op: "event").isEmpty, "marked private by its app")
        XCTAssertTrue(hub.skippedPrivate)

        hub.paused = true
        XCTAssertEqual(take("phone", op: "state").last?["state"] as? String, "paused")
        copyOnMac("while paused")
        XCTAssertTrue(take("phone", op: "event").isEmpty)
        hub.handle(ref("phone"), event(from: "install-phone", seq: 1, text: "ignored while paused"))
        XCTAssertEqual(pb.string(forType: .string), "while paused")

        hub.paused = false
        _ = take("phone")
        copyOnMac("after pause")
        XCTAssertEqual(take("phone", op: "event").count, 1)
        hub.revoke(peerID: "install-phone")
        XCTAssertEqual(take("phone", op: "state").last?["state"] as? String, "revoked")
        copyOnMac("after revoke")
        XCTAssertTrue(take("phone", op: "event").isEmpty)
    }
}
