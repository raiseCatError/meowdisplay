import CoreGraphics
import XCTest

/// The Compact Dock on a short band, a phone in landscape (#130): the fade and the card height
/// follow the band, the drawn fade and the hit test agree, and a roomy band is left as it was.
final class StagePeekCompactBandTests: XCTestCase {
    /// Mirrors the overlay's band: the search and app carousel end 128 points under the safe area's
    /// top, the toolbar's top edge is 50 points over its bottom.
    private func band(_ safe: CGRect) -> CGRect {
        StagePeekLayout.dockRegion(safe: safe, controlsAbove: safe.minY + 128, controlsBelow: safe.maxY - 50)
    }

    private let aspects: [Double] = [1.6, 0.75, 1.33, 2.0, 1.0, 1.78, 1.5, 1.3, 1.6]

    private func cards(_ safe: CGRect, position: Double, pad: Bool = false, fit: Bool) -> [StagePeekCard] {
        StagePeekLayout.cards(aspects: aspects, position: position, expansion: 0, edge: .left, safe: safe,
                              isPad: pad, reduceMotion: false, region: band(safe), fitsRegion: fit)
    }

    /// Short iPhone landscapes by safe area (the Dynamic Island / notch sits in the leading inset).
    private let landscapes: [(String, CGRect)] = [
        ("iPhone SE 667x375", CGRect(x: 0, y: 0, width: 667, height: 375)),
        ("small notch 724x375", CGRect(x: 44, y: 0, width: 724, height: 375)),
        ("iPhone 15 734x372", CGRect(x: 59, y: 0, width: 734, height: 372)),
        ("iPhone 14 Pro Max 814x393", CGRect(x: 59, y: 0, width: 814, height: 393)),
        ("older small 568x320", CGRect(x: 0, y: 0, width: 568, height: 320)),
    ]

    func testTheFadeFollowsTheBandAndIsUnchangedWhenRoomy() {
        XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: 178), 17.8, accuracy: 0.001)
        XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: 280), StagePeekConfig.dockFade, accuracy: 0.001)
        XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: 700), StagePeekConfig.dockFade)
        XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: 0), 0)
        XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: -5), 0)
    }

    func testTheCardHeightEasesBackToTheUsualOneAsTheBandGrows() {
        let usual: CGFloat = 100
        XCTAssertEqual(StagePeekCompactBand.cardHeight(usual: usual, bandHeight: 400), usual)
        XCTAssertEqual(StagePeekCompactBand.cardHeight(usual: usual, bandHeight: 900), usual)
        XCTAssertEqual(StagePeekCompactBand.cardHeight(usual: usual, bandHeight: 180), 180 * 0.34, accuracy: 0.001)
        var previous: CGFloat = 0
        for h in stride(from: CGFloat(0), through: 600, by: 10) {
            let value = StagePeekCompactBand.cardHeight(usual: usual, bandHeight: h)
            XCTAssertGreaterThanOrEqual(value, previous, "no jump as the band grows (\(h))")
            XCTAssertLessThanOrEqual(value, usual)
            previous = value
        }
    }

    func testAShortLandscapeKeepsTheHighlightedCardClearAndShowsItsNeighbours() {
        for (name, safe) in landscapes {
            let region = band(safe)
            let fade = StagePeekCompactBand.fade(bandHeight: region.height)
            for position in [2.0, 3.0, 4.0, 5.0] {
                let cs = cards(safe, position: position, fit: true)
                let focus = cs.first(where: \.highlighted)!
                XCTAssertGreaterThanOrEqual(focus.center.y - focus.size.height / 2, region.minY + fade - 0.5,
                                            "\(name) @\(position): the highlighted card clears the top fade")
                XCTAssertLessThanOrEqual(focus.center.y + focus.size.height / 2, region.maxY - fade + 0.5,
                                         "\(name) @\(position): and the bottom one")
                let tappable = cs.filter { StagePeekLayout.hit($0.center, cards: cs, region: region, fade: fade) == $0.index }
                XCTAssertGreaterThanOrEqual(tappable.count, 3, "\(name) @\(position): the card and a neighbour either side")
                // The old geometry showed fewer, or faded the highlighted card itself.
                let before = cards(safe, position: position, fit: false)
                let beforeTappable = before.filter {
                    StagePeekLayout.hit($0.center, cards: before, region: region) == $0.index
                }
                XCTAssertGreaterThanOrEqual(tappable.count, beforeTappable.count, "\(name) @\(position)")
            }
        }
    }

    func testEveryCardTheMaskShowsIsATouchTargetAndNothingFadedOutIs() {
        for (name, safe) in landscapes {
            let region = band(safe)
            let fade = StagePeekCompactBand.fade(bandHeight: region.height)
            let cs = cards(safe, position: 3, fit: true)
            for c in cs {
                // Walk down the card's centre line; the mask is half shown from `fade / 2` in from an end.
                for y in stride(from: c.center.y - c.size.height / 2 + 1, through: c.center.y + c.size.height / 2 - 1, by: 2) {
                    let p = CGPoint(x: c.center.x, y: y)
                    let hit = StagePeekLayout.hit(p, cards: cs, region: region, fade: fade)
                    let shownAtHalf = y >= region.minY + fade / 2 && y <= region.maxY - fade / 2
                    if !shownAtHalf { XCTAssertNil(hit, "\(name): a point faded under half is not a card (y \(y))") }
                    if shownAtHalf, hit != nil {
                        XCTAssertTrue(cs.contains { $0.index == hit })
                    }
                }
            }
            // Just inside the half-shown line a card is tappable, just outside it is not.
            let inside = cs.first { c in
                let y = region.minY + fade / 2 + 1
                return y > c.center.y - c.size.height / 2 && y < c.center.y + c.size.height / 2
            }
            if let c = inside {
                let p = CGPoint(x: c.center.x, y: region.minY + fade / 2 + 1)
                XCTAssertNotNil(StagePeekLayout.hit(p, cards: cs, region: region, fade: fade), name)
                XCTAssertNil(StagePeekLayout.hit(CGPoint(x: p.x, y: region.minY + fade / 2 - 1), cards: cs, region: region, fade: fade), name)
            }
        }
    }

    func testARoomyBandAndTheNormalDockAreUnchanged() {
        let portrait = CGRect(x: 0, y: 47, width: 393, height: 771)
        let tablet = CGRect(x: 0, y: 24, width: 1032, height: 1342)
        let splitTablet = CGRect(x: 0, y: 24, width: 507, height: 1000)
        for (safe, pad) in [(portrait, false), (tablet, true), (splitTablet, true)] {
            for position in [0.0, 2.0, 4.5, 8.0] {
                XCTAssertEqual(cards(safe, position: position, pad: pad, fit: true), cards(safe, position: position, pad: pad, fit: false),
                               "\(safe) @\(position)")
            }
            XCTAssertEqual(StagePeekCompactBand.fade(bandHeight: band(safe).height), StagePeekConfig.dockFade)
        }
        // Normal has no band: asking to fit one changes nothing.
        let normal = StagePeekLayout.cards(aspects: aspects, position: 3, expansion: 0, edge: .left, safe: landscapes[2].1,
                                           isPad: false, reduceMotion: false, region: nil, fitsRegion: true)
        XCTAssertEqual(normal, StagePeekLayout.cards(aspects: aspects, position: 3, expansion: 0, edge: .left, safe: landscapes[2].1,
                                                     isPad: false, reduceMotion: false))
    }

    func testExpandingStillReachesTheFullSizedStackOnAShortBand() {
        let safe = landscapes[2].1
        let region = band(safe)
        for fit in [false, true] {
            let expanded = StagePeekLayout.cards(aspects: aspects, position: 3, expansion: 1, edge: .left, safe: safe, isPad: false,
                                                 reduceMotion: false, region: region, fitsRegion: fit)
            let focus = expanded.first(where: \.highlighted)!
            XCTAssertGreaterThan(focus.size.height, StagePeekCompactBand.cardHeight(usual: safe.height * 0.26, bandHeight: region.height) * 1.1)
        }
        let on = StagePeekLayout.cards(aspects: aspects, position: 3, expansion: 1, edge: .left, safe: safe, isPad: false,
                                       reduceMotion: false, region: region, fitsRegion: true)
        let off = StagePeekLayout.cards(aspects: aspects, position: 3, expansion: 1, edge: .left, safe: safe, isPad: false,
                                        reduceMotion: false, region: region, fitsRegion: false)
        XCTAssertEqual(on, off, "fully expanded, the band no longer shapes the cards")
    }

    func testTheDefaultHitFadeIsTheOldOne() {
        let safe = landscapes[2].1
        let region = band(safe)
        let cs = cards(safe, position: 3, fit: false)
        for c in cs {
            XCTAssertEqual(StagePeekLayout.hit(c.center, cards: cs, region: region),
                           StagePeekLayout.hit(c.center, cards: cs, region: region, fade: StagePeekConfig.dockFade))
        }
    }
}
