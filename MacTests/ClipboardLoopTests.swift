import AppKit
import XCTest

/// The receiver's ClipboardModel against the Mac's ClipboardHub, wired message to message:
/// join and grant, copies both ways (inline and fetched), no echo, Mac files saved on request.
/// A fake device clipboard and a private Mac pasteboard: never the owner's clipboard.
@MainActor
final class ClipboardLoopTests: XCTestCase {
    private final class FakeDevice: ClipboardPlatform {
        var changeCount = 0
        var items: [[(kind: ClipKind, data: Data)]] = []
        var toRead: ClipLocalContent?
        func write(_ items: [[(kind: ClipKind, data: Data)]]) -> Int { self.items = items; changeCount += 1; return changeCount }
        func read(textOnly: Bool, maxBytes: Int, completion: @escaping @MainActor (ClipLocalContent?) -> Void) { completion(toRead) }
        var text: String? { items.first?.first { $0.kind == .text }.map { String(decoding: $0.data, as: UTF8.self) } }
    }

    private var suite: String!
    private var pb: NSPasteboard!
    private var tmp: URL!

    override func setUp() async throws {
        suite = "clipboard-loop-\(UUID().uuidString)"
        pb = NSPasteboard.withUniqueName()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clip-loop-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        pb.releaseGlobally()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPhoneAndMacShareCopiesBothWays() throws {
        let defaults = UserDefaults(suiteName: suite)!
        let hub = ClipboardHub(defaults: defaults, pasteboard: pb, origin: "mac-1", staging: tmp.appendingPathComponent("mac"))
        hub.anySessionHasEffectiveInput = { false }
        hub.enabled = true
        ClipboardDevicePolicyStore.setPolicy(ClipboardDevicePolicy(access: .always), peerID: "phone-1", anySessionHasEffectiveInput: false, defaults: defaults)
        let phone = ClipboardModel(defaults: defaults, origin: "phone-1", tempRoot: tmp.appendingPathComponent("phone"))
        let device = FakeDevice()
        phone.platform = device
        // Messages are delivered asynchronously, like the real transport.
        var ref: ClipboardPeerRef!
        ref = ClipboardPeerRef(sessionID: "s1", peerID: "phone-1", name: "Phone", generation: 1, send: { m in
            let box = ClipboardMessage(obj: m)
            DispatchQueue.main.async { phone.handle(box) }
        })
        phone.send = { m in
            let box = ClipboardMessage(obj: m)
            DispatchQueue.main.async { hub.handle(ref, box.obj) }
            return true
        }
        func settle(_ t: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

        phone.enabled = true
        phone.setAvailable(true)
        settle()
        XCTAssertEqual(phone.macState, .ready)
        XCTAssertTrue(phone.toDevice && phone.toMac)

        // Mac → phone: a short text inline, then a long one fetched in ranges.
        pb.clearContents(); pb.setString("from the Mac ✓", forType: .string); hub.pollNow()
        settle()
        XCTAssertEqual(device.text, "from the Mac ✓")
        let long = String(repeating: "0123456789", count: 50_000)
        pb.clearContents(); pb.setString(long, forType: .string); hub.pollNow()
        settle(1)
        XCTAssertEqual(device.text, long)

        // The phone's own write is not a copy to send back.
        phone.checkLocal(automatic: true)
        settle()
        XCTAssertEqual(pb.string(forType: .string), long)

        // Phone → Mac: something copied in another app, sent when the app comes back.
        phone.autoSend = true
        device.changeCount += 1
        device.toRead = ClipLocalContent(items: [[(.text, Data("from the phone".utf8)), (.html, Data("<b>from the phone</b>".utf8))]], files: [])
        phone.checkLocal(automatic: true)
        settle()
        XCTAssertEqual(pb.string(forType: .string), "from the phone")
        XCTAssertEqual(pb.data(forType: .html), Data("<b>from the phone</b>".utf8))
        // The Mac's write of it isn't sent back to the phone as a new copy.
        let before = device.changeCount
        hub.pollNow()
        settle()
        XCTAssertEqual(device.changeCount, before)

        // Mac files: listed, fetched only when the phone asks, hierarchy kept.
        let src = tmp.appendingPathComponent("src/Folder/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: src.deletingLastPathComponent().appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 300_000).write(to: src.appendingPathComponent("b.bin"))
        pb.clearContents(); pb.writeObjects([src.deletingLastPathComponent() as NSURL]); hub.pollNow()
        settle()
        let listed = try XCTUnwrap(phone.macFiles)
        XCTAssertEqual(Set(listed.files.map { $0.path.joined(separator: "/") }), ["Folder", "Folder/sub", "Folder/a.txt", "Folder/sub/b.bin"])
        phone.getMacFiles(.save)
        settle(1.5)
        let export = try XCTUnwrap(phone.export)
        XCTAssertEqual(export.urls.map(\.lastPathComponent), ["Folder"])
        XCTAssertEqual(try Data(contentsOf: export.urls[0].appendingPathComponent("sub/b.bin")).count, 300_000)
        phone.exportFinished(export, completed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.directory.path), "temporary copies are removed")

        // Turning it off on the phone stops everything.
        phone.enabled = false
        settle()
        pb.clearContents(); pb.setString("after off", forType: .string); hub.pollNow()
        settle()
        XCTAssertNotEqual(device.text, "after off")
    }
}
