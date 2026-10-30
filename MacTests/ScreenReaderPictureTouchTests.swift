import XCTest

/// With VoiceOver or TalkBack on, the Mac picture never turns the screen reader's own gestures
/// into Mac input: it takes touches only after the user turns on Direct Touch.
final class ScreenReaderPictureTouchTests: XCTestCase {
    func testWithoutAScreenReaderThePictureTakesTouchesAsBefore() {
        let policy = ScreenReaderPictureTouch(screenReaderRunning: false)
        XCTAssertTrue(policy.picturePassesTouches)
        XCTAssertFalse(policy.allowsDirectInteraction)
        XCTAssertNil(policy.directTouchActionTurnsOn, "no action offered")
    }

    func testAScreenReaderBlocksPictureTouchesUntilDirectTouch() {
        var policy = ScreenReaderPictureTouch(screenReaderRunning: true)
        XCTAssertFalse(policy.picturePassesTouches, "explore, double tap and pass-through reach nothing")
        XCTAssertFalse(policy.allowsDirectInteraction)
        XCTAssertEqual(policy.directTouchActionTurnsOn, true)
        XCTAssertTrue(policy.setDirectTouch(true))
        XCTAssertTrue(policy.picturePassesTouches)
        XCTAssertTrue(policy.allowsDirectInteraction)
        XCTAssertEqual(policy.directTouchActionTurnsOn, false, "the action now turns it off")
        XCTAssertTrue(policy.setDirectTouch(false))
        XCTAssertFalse(policy.picturePassesTouches)
    }

    func testTurningTheScreenReaderOnMidSessionBlocksTouches() {
        var policy = ScreenReaderPictureTouch(screenReaderRunning: false)
        XCTAssertTrue(policy.update(screenReaderRunning: true))
        XCTAssertFalse(policy.picturePassesTouches)
    }

    func testDirectTouchNeverOutlivesTheScreenReader() {
        var policy = ScreenReaderPictureTouch(screenReaderRunning: true)
        policy.setDirectTouch(true)
        policy.update(screenReaderRunning: false)
        XCTAssertFalse(policy.directTouch)
        policy.update(screenReaderRunning: true)
        XCTAssertFalse(policy.picturePassesTouches, "turning VoiceOver on again starts blocked")
    }

    func testDirectTouchCannotBeTurnedOnWithoutAScreenReader() {
        var policy = ScreenReaderPictureTouch(screenReaderRunning: false)
        XCTAssertFalse(policy.setDirectTouch(true))
        XCTAssertFalse(policy.directTouch)
    }
}
