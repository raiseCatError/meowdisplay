import XCTest

/// #255 QA 9000047: a session admitted while the Mac slept showed the locked cover with only
/// Settings and Disconnect, and never the "Mac is asleep" cover, because both rules needed a picture.
final class SessionCoverPolicyTests: XCTestCase {
    func testASessionBeforeItsFirstPictureIsOnScreenUnderACover() {
        XCTAssertTrue(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true, keptOnHome: false, demoShown: false))
    }

    func testAShownSurfaceIsOnScreenAsBefore() {
        // Recovery keeps the surface shown while not connected.
        XCTAssertTrue(SessionCoverPolicy.sessionOnScreen(surfaceShown: true, connected: false, keptOnHome: false, demoShown: false))
    }

    func testNothingIsOnScreenWithoutASessionOrBehindHomeOrTheDemo() {
        XCTAssertFalse(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: false, keptOnHome: false, demoShown: false))
        XCTAssertFalse(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true, keptOnHome: true, demoShown: false))
        XCTAssertFalse(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true, keptOnHome: false, demoShown: true))
    }

    func testBackToHomeIsOfferedOnACoverBeforeTheFirstPicture() {
        let onScreen = SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true, keptOnHome: false, demoShown: false)
        XCTAssertTrue(SessionCoverPolicy.homeAvailable(connected: true, sessionOnScreen: onScreen, presentation: .session))
    }

    func testBackToHomeIsNotOfferedWhenAlreadyKeptOrDisconnected() {
        XCTAssertFalse(SessionCoverPolicy.homeAvailable(connected: true, sessionOnScreen: true,
                                                        presentation: .homeKeepingSession(macPeerID: "mac")))
        XCTAssertFalse(SessionCoverPolicy.homeAvailable(connected: false, sessionOnScreen: true, presentation: .session))
        XCTAssertFalse(SessionCoverPolicy.homeAvailable(connected: true, sessionOnScreen: false, presentation: .session))
    }

    func testHomeFromACoverKeepsASessionWithoutAPictureAndResumeReturns() {
        let retained = SessionCoverPolicy.surfaceRetainedForHome(retainsSurface: true, hasPicture: false, fromCover: true)
        var presentation = ReceiverSessionPresentation.session
        XCTAssertTrue(presentation.showHome(surfaceRetained: retained, macPeerID: "mac"))
        XCTAssertTrue(presentation.keepsSessionOnHome)
        // Under Home the cover is gone; still connected, the session stays kept.
        XCTAssertFalse(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true,
                                                          keptOnHome: presentation.keepsSessionOnHome, demoShown: false))
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: true, macPeerID: "mac"))
        XCTAssertTrue(presentation.resume())
        XCTAssertTrue(SessionCoverPolicy.sessionOnScreen(surfaceShown: false, connected: true,
                                                         keptOnHome: presentation.keepsSessionOnHome, demoShown: false))
    }

    func testWithoutACoverHomeStillNeedsAPicture() {
        XCTAssertFalse(SessionCoverPolicy.surfaceRetainedForHome(retainsSurface: true, hasPicture: false, fromCover: false))
        XCTAssertTrue(SessionCoverPolicy.surfaceRetainedForHome(retainsSurface: true, hasPicture: true, fromCover: false))
        XCTAssertFalse(SessionCoverPolicy.surfaceRetainedForHome(retainsSurface: false, hasPicture: true, fromCover: true))
    }
}
