import XCTest

/// Home over a kept session (#121, review C6): clipboard sharing keeps working as the person set
/// it up, and the kept-session card says so while copies go to the Mac on their own. A fake device
/// clipboard and a recorded wire: never the owner's clipboard.
@MainActor
final class KeptSessionClipboardTests: XCTestCase {
    private final class FakeDevice: ClipboardPlatform {
        var changeCount = 0
        var reads = 0
        var toRead: ClipLocalContent?
        func write(_ items: [[(kind: ClipKind, data: Data)]]) -> Int { changeCount += 1; return changeCount }
        func read(textOnly: Bool, maxBytes: Int, completion: @escaping @MainActor (ClipLocalContent?) -> Void) {
            reads += 1
            completion(toRead)
        }
    }

    private var suite: String!
    private var sent: [[String: Any]] = []

    override func setUp() async throws {
        suite = "kept-session-clipboard-\(UUID().uuidString)"
        sent = []
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private var events: Int { sent.filter { $0["op"] as? String == "event" }.count }

    /// Clipboard on and the Mac's owner allowed it (the Mac reports `ready` both ways).
    private func sharing(autoSend: Bool) -> (ClipboardModel, FakeDevice) {
        let defaults = UserDefaults(suiteName: suite)!
        let model = ClipboardModel(defaults: defaults, origin: "phone-1",
                                   tempRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let device = FakeDevice()
        model.platform = device
        model.send = { [unowned self] in self.sent.append($0); return true }
        model.enabled = true
        model.autoSend = autoSend
        model.setAvailable(true)
        model.handle(ClipboardMessage(obj: ["type": ClipboardWire.type, "op": "state", "state": "ready",
                                            "toDevice": true, "toMac": true]))
        XCTAssertTrue(model.canSendToMac)
        device.toRead = ClipLocalContent(items: [[(.text, Data("copied elsewhere".utf8))]], files: [])
        return (model, device)
    }

    /// The app comes back with Home over a kept session and something was copied meanwhile:
    /// with "Send copies…" off nothing is read or sent; the device only offers to send it.
    func testKeptSessionHomeSendsClipboardOnlyWhenAutoSendIsOn() {
        let (asking, askingDevice) = sharing(autoSend: false)
        askingDevice.changeCount += 1
        asking.checkLocal(automatic: true)
        XCTAssertEqual(askingDevice.reads, 0, "never read without the opt-in")
        XCTAssertEqual(events, 0)
        XCTAssertTrue(asking.localChangePending)

        sent = []
        let (automatic, automaticDevice) = sharing(autoSend: true)
        automaticDevice.changeCount += 1
        automatic.checkLocal(automatic: true)
        XCTAssertEqual(automaticDevice.reads, 1)
        XCTAssertEqual(events, 1, "the person's own opt-in: it still goes to the Mac")
    }

    /// The card's note shows exactly while copies go to the Mac on their own.
    func testTheNoteShowsOnlyWhileCopiesGoToTheMacOnTheirOwn() {
        for kept in [false, true] {
            for canSend in [false, true] {
                for auto in [false, true] {
                    let text = KeptSessionClipboardNote.text(keptSession: kept, canSendToMac: canSend, autoSend: auto,
                                                             macName: "Studio")
                    XCTAssertEqual(text != nil, kept && canSend && auto, "kept=\(kept) canSend=\(canSend) auto=\(auto)")
                }
            }
        }
        let text = KeptSessionClipboardNote.text(keptSession: true, canSendToMac: true, autoSend: true, macName: "Studio")
        XCTAssertEqual(text?.contains("Clipboard sharing with Studio is still on"), true)
    }

    /// The note follows the real clipboard state: off once sharing stops (Clipboard turned off
    /// here, or the session ends), so it never claims sharing that isn't happening.
    func testTheNoteFollowsTheClipboardState() {
        let (model, _) = sharing(autoSend: true)
        func note() -> String? {
            KeptSessionClipboardNote.text(keptSession: true, canSendToMac: model.canSendToMac, autoSend: model.autoSend,
                                          macName: "Studio")
        }
        XCTAssertNotNil(note())
        model.autoSend = false
        XCTAssertNil(note())
        model.autoSend = true
        model.enabled = false
        XCTAssertNil(note())
        model.enabled = true
        model.setAvailable(false)
        XCTAssertNil(note(), "the session ended")
    }
}
