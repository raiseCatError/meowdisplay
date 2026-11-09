import CoreGraphics
import XCTest

/// QA 9000034 (iPad): after typing the password on the Mac's lock screen and pressing Return, the
/// keyboard went away but the control tray stayed raised as if it were still up.
final class SoftwareKeyboardPresenceTests: XCTestCase {
    private let raised = CGRect(x: 0, y: 0, width: 1080, height: 412)

    func testAnOpenKeyboardOnAShownSurfaceKeepsItsPlace() {
        XCTAssertEqual(SoftwareKeyboardPresence.visibleRect(reported: raised, keyboardActive: true, surfaceShown: true), raised)
        XCTAssertNil(SoftwareKeyboardPresence.visibleRect(reported: nil, keyboardActive: true, surfaceShown: true),
                     "open but floating or undocked: nothing to keep clear of")
    }

    func testUnlockingClosesTheKeyboardAndTheTrayGoesBack() {
        // The lock screen's surface reported the keyboard, then was rebuilt for Window view and
        // never said it closed; the keyboard closed with the lock screen.
        XCTAssertNil(SoftwareKeyboardPresence.visibleRect(reported: raised, keyboardActive: false, surfaceShown: true))
    }

    func testASurfaceThatIsGoneReportsNothing() {
        XCTAssertNil(SoftwareKeyboardPresence.visibleRect(reported: raised, keyboardActive: true, surfaceShown: false),
                     "between the lock screen and Window view no picture is shown")
    }
}
