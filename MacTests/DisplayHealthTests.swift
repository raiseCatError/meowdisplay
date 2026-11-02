import XCTest

final class DisplayHealthTests: XCTestCase {
    private func reading(
        isOnline: Bool = true,
        isActive: Bool = true,
        boundsEmpty: Bool = false,
        hasValidMode: Bool = true,
        mirrorState: DisplayReading.MirrorState = .notMirrored
    ) -> DisplayReading {
        DisplayReading(id: 1, isOnline: isOnline, isActive: isActive,
                       boundsEmpty: boundsEmpty, hasValidMode: hasValidMode, mirrorState: mirrorState)
    }

    func testHealthyDisplayIsUsable() {
        XCTAssertEqual(DisplayUsability.evaluate(reading()), .usable)
    }

    func testOfflineDisplayIsStale() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(isOnline: false)),
                       .stale(reason: "CGDisplayIsOnline=false"))
    }

    func testInactiveDisplayIsStale() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(isActive: false)),
                       .stale(reason: "CGDisplayIsActive=false"))
    }

    /// Upstream PR #219: a torn-down/offline CGVirtualDisplay can retain
    /// non-empty bounds while online/active are false — but empty bounds on
    /// their own must still be caught (a display registered with nothing to
    /// show is not usable either).
    func testEmptyBoundsIsStale() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(boundsEmpty: true)),
                       .stale(reason: "bounds empty"))
    }

    func testInvalidModeIsStale() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(hasValidMode: false)),
                       .stale(reason: "no valid display mode"))
    }

    func testMirroredDisplayIsStale() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(mirrorState: .mirrored)),
                       .stale(reason: "in a system mirror set"))
    }

    /// Upstream PR #250: CGDisplayIsInMirrorSet returning -1 (a released or
    /// unregistered display) must never be treated as "mirrored" — an
    /// otherwise-healthy reading with an unknown mirror state stays usable.
    func testUnknownMirrorStateIsNotTreatedAsMirrored() {
        XCTAssertEqual(DisplayUsability.evaluate(reading(mirrorState: .unknown)), .usable)
    }

    func testOnlyTheFirstFailingCheckIsReported() {
        // Multiple simultaneous failures: the decision is still deterministic
        // and doesn't crash combining reasons.
        let result = DisplayUsability.evaluate(reading(isOnline: false, isActive: false, boundsEmpty: true))
        XCTAssertEqual(result, .stale(reason: "CGDisplayIsOnline=false"))
    }

    func testDiagnosticSummaryIncludesMirrorAndMainState() {
        var r = reading(isActive: false, mirrorState: .mirrored)
        r.mirrorsDisplay = 7
        r.isMain = true
        XCTAssertEqual(r.diagnosticSummary,
                       "displayID=1 inMirrorSet=mirrored mirrors=7 active=false online=true main=true")
    }
}
