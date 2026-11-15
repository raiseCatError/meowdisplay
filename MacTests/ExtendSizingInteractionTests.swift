import XCTest

/// #262 (declared physical size) together with #281 (Desktop Size): the
/// declared size never depends on Desktop Size, every combination keeps the
/// physical-size minimums, and the published points always fit the
/// reservation made at creation, so switching Desktop Size or rotating stays
/// an in-place resize.
final class ExtendSizingInteractionTests: XCTestCase {

    private struct Receiver { let name: String; let wide: Int; let high: Int }

    private let receivers = [
        Receiver(name: "iPhone 15 Pro portrait", wide: 1179, high: 2556),
        Receiver(name: "iPhone 15 Pro landscape", wide: 2556, high: 1179),
        Receiver(name: "iPhone SE portrait", wide: 750, high: 1334),
        Receiver(name: "iPad mini portrait", wide: 1488, high: 2266),
        Receiver(name: "iPad Pro 13 landscape", wide: 2752, high: 2064),
        Receiver(name: "Mac Receiver 5K", wide: 5120, high: 2880),
    ]

    private func aspects(for r: Receiver) -> [Double] {
        let physical = Double(r.wide) / Double(r.high)
        let automatic = ExtendDisplayShapePreference.standard.resolvedAspect(receiverPhysicalAspect: physical)
        let full = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true)
            .resolvedAspect(receiverPhysicalAspect: physical)
        return [automatic, full, 1.0, 32.0 / 9.0]
    }

    func testDeclaredSizeIsTheSameForEveryDesktopSize() {
        for r in receivers {
            for aspect in aspects(for: r) {
                let sizes = ExtendDesktopSize.allCases.map {
                    ExtendPhysicalSize.millimetres(for: ExtendDisplayPlan.resolve(
                        receiverPixelsWide: r.wide, receiverPixelsHigh: r.high, aspect: aspect, desktopSize: $0))
                }
                XCTAssertEqual(Set(sizes.map { "\($0.width)x\($0.height)" }).count, 1, "\(r.name) aspect \(aspect)")
            }
        }
    }

    func testEveryCombinationKeepsThePhysicalSizeMinimums() {
        for r in receivers {
            for aspect in aspects(for: r) {
                for size in ExtendDesktopSize.allCases {
                    let plan = ExtendDisplayPlan.resolve(
                        receiverPixelsWide: r.wide, receiverPixelsHigh: r.high, aspect: aspect, desktopSize: size)
                    let mm = ExtendPhysicalSize.millimetres(for: plan)
                    XCTAssertGreaterThanOrEqual(mm.width, ExtendPhysicalSize.minimumWidth, "\(r.name) \(size)")
                    XCTAssertGreaterThanOrEqual(mm.width * mm.height, ExtendPhysicalSize.minimumArea, "\(r.name) \(size)")
                }
            }
        }
    }

    func testPublishedPointsFitTheReservationInBothOrientations() {
        for r in receivers {
            for aspect in aspects(for: r) {
                let created = ExtendDisplayPlan.resolve(
                    receiverPixelsWide: r.wide, receiverPixelsHigh: r.high, aspect: aspect, desktopSize: .standard)
                for size in ExtendDesktopSize.allCases {
                    for (w, h) in [(r.wide, r.high), (r.high, r.wide)] {
                        let later = ExtendDisplayPlan.resolve(
                            receiverPixelsWide: w, receiverPixelsHigh: h, aspect: aspect, desktopSize: size)
                        XCTAssertLessThanOrEqual(max(later.wide, later.high), created.reservedPointsPerAxis,
                                                 "\(r.name) \(size) after rotation")
                    }
                }
            }
        }
    }

    func testLargerTextLowersTheDeclaredDensityOnly() {
        let plan = { (size: ExtendDesktopSize) in
            ExtendDisplayPlan.resolve(receiverPixelsWide: 2556, receiverPixelsHigh: 1179,
                                      aspect: 2556.0 / 1179.0, desktopSize: size)
        }
        let standard = plan(.standard)
        let largest = plan(.largest)
        let mm = ExtendPhysicalSize.millimetres(for: standard)
        XCTAssertEqual(mm, ExtendPhysicalSize.millimetres(for: largest))
        XCTAssertLessThan(Double(largest.wide) / Double(mm.width), Double(standard.wide) / Double(mm.width))
    }
}
