import XCTest

final class KnownDeviceCleanupTests: XCTestCase {
    private func e(_ id: String, _ name: String, _ day: Int?, inUse: Bool = false) -> KnownDeviceCleanup.Entry {
        .init(id: id, name: name, paired: day.map { Date(timeIntervalSince1970: Double($0) * 86_400) }, inUse: inUse)
    }

    func testKeepsTheNewestPairingOfEachNameAndRemovesOlderCopies() {
        let old = KnownDeviceCleanup.superseded([e("a", "Meowdisplay iPhone", 1), e("b", "meowdisplay iphone ", 5), e("c", "Meowdisplay iPhone", 3),
                                                  e("d", "iPad", 2), e("x", "Pixel", nil), e("y", "Pixel", 4)])
        XCTAssertEqual(Set(old.map(\.id)), ["a", "c", "x"])
    }

    func testNeverRemovesAConnectedOrNearbyDevice() {
        // The connected one is older: it stays, and the newer offline copy is the old entry.
        let old = KnownDeviceCleanup.superseded([e("a", "iPhone", 1, inUse: true), e("b", "iPhone", 9), e("c", "iPhone", 5, inUse: true)])
        XCTAssertEqual(old.map(\.id), ["b"])
        XCTAssertTrue(KnownDeviceCleanup.superseded([e("a", "Mac", 1), e("b", "Other Mac", 2)]).isEmpty, "different names are different devices")
    }
}
