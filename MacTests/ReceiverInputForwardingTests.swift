import CoreGraphics
import XCTest

/// Issue #12: a receiving Mac's keyboard and trackpad driving the sending
/// Mac. These drive the real `ReceiverInputForwarder` with synthetic AppKit
/// event sequences and check every command it would send. They prove the
/// receiver's rules; they do not prove how a physical trackpad or keyboard
/// feels (see RECEIVER_INPUT.md's physical checklist).
final class ReceiverInputForwardingTests: XCTestCase {

    // MARK: - Geometry

    func testExactFitMapsCornersAndFlipsY() {
        let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: 1440, height: 900),
                                             videoSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(geometry.fittedRect, CGRect(x: 0, y: 0, width: 1440, height: 900))
        // AppKit's origin is bottom-left; the wire's is top-left.
        XCTAssertEqual(geometry.normalized(CGPoint(x: 0, y: 900))?.point, CGPoint(x: 0, y: 0))
        XCTAssertEqual(geometry.normalized(CGPoint(x: 1440, y: 0))?.point, CGPoint(x: 1, y: 1))
        XCTAssertEqual(geometry.normalized(CGPoint(x: 360, y: 675))?.point, CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(geometry.videoPixelsPerPoint, 2)
    }

    func testWideWindowLetterboxesAndLetterboxIsOutsideThePicture() {
        // A 16:10 stream in a 2:1 window: bars left and right.
        let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: 2000, height: 1000),
                                             videoSize: CGSize(width: 3200, height: 2000))
        XCTAssertEqual(geometry.fittedRect, CGRect(x: 200, y: 0, width: 1600, height: 1000))
        let inBar = geometry.normalized(CGPoint(x: 100, y: 500))!
        XCTAssertFalse(inBar.inside)
        XCTAssertEqual(inBar.point, CGPoint(x: 0, y: 0.5))
        XCTAssertTrue(geometry.normalized(CGPoint(x: 1000, y: 500))!.inside)
    }

    func testTallWindowPillarboxes() {
        let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: 800, height: 1000),
                                             videoSize: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(geometry.fittedRect, CGRect(x: 0, y: 250, width: 800, height: 500))
        XCTAssertEqual(geometry.normalized(CGPoint(x: 400, y: 500))?.point, CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(geometry.normalized(CGPoint(x: 400, y: 900))!.inside)
    }

    func testResizingKeepsTheSameNormalizedPointAndRescalesScrollUnits() {
        let video = CGSize(width: 2880, height: 1800)
        for (width, expectedScale) in [(1440.0, 2.0), (720.0, 4.0), (2880.0, 1.0)] {
            let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: width, height: width * 0.625), videoSize: video)
            XCTAssertEqual(geometry.normalized(CGPoint(x: width / 2, y: width * 0.625 / 4))?.point,
                           CGPoint(x: 0.5, y: 0.75))
            XCTAssertEqual(geometry.videoPixelsPerPoint!, expectedScale, accuracy: 1e-9)
        }
    }

    func testMixedResolutionFullScreenStreamFitsInsideTheScreen() {
        // A 1920×1200 stream full screen on a 2560×1440-point display.
        let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: 2560, height: 1440),
                                             videoSize: CGSize(width: 1920, height: 1200))
        let rect = geometry.fittedRect!
        XCTAssertEqual(rect.height, 1440)
        XCTAssertEqual(rect.width, 2304)
        XCTAssertEqual(rect.minX, 128)
        XCTAssertEqual(geometry.videoPixelsPerPoint!, 1920.0 / 2304.0, accuracy: 1e-9)
    }

    func testDragFarOutsideTheWindowClampsToTheEdge() {
        let geometry = ReceiverVideoGeometry(viewSize: CGSize(width: 1000, height: 500),
                                             videoSize: CGSize(width: 2000, height: 1000))
        let result = geometry.normalized(CGPoint(x: 5000, y: -300))!
        XCTAssertEqual(result.point, CGPoint(x: 1, y: 1))
        XCTAssertFalse(result.inside)
    }

    func testUnknownVideoSizeMapsNothing() {
        XCTAssertNil(ReceiverVideoGeometry(viewSize: CGSize(width: 100, height: 100), videoSize: .zero).normalized(.zero))
        XCTAssertNil(ReceiverVideoGeometry(viewSize: .zero, videoSize: CGSize(width: 10, height: 10)).videoPixelsPerPoint)
    }

    // MARK: - Key map

    func testEveryMappedKeyRoundTripsThroughTheSendersInjectionTable() {
        for keyCode in MacVirtualKeyMap.mappedKeyCodes {
            let usage = MacVirtualKeyMap.hidUsage(forKeyCode: keyCode)!
            guard let senderUsage = HIDKeyUsage(rawValue: usage) else {
                return XCTFail("sender has no injection for usage \(usage) (key code \(keyCode))")
            }
            XCTAssertEqual(senderUsage.keyCode, CGKeyCode(keyCode), "usage \(usage)")
        }
    }

    func testMappingIsOneToOne() {
        let usages = MacVirtualKeyMap.mappedKeyCodes.compactMap(MacVirtualKeyMap.hidUsage(forKeyCode:))
        XCTAssertEqual(Set(usages).count, usages.count)
        XCTAssertGreaterThanOrEqual(usages.count, 100, "a full keyboard, F-keys, navigation and keypad")
    }

    func testModifierKeysTravelAsModifiersNotKeys() {
        // Command, Shift, Option, Control (both sides), Caps Lock, Fn.
        for keyCode: UInt16 in [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x39, 0x3F] {
            XCTAssertNil(MacVirtualKeyMap.hidUsage(forKeyCode: keyCode))
        }
    }

    func testRepresentativeKeys() {
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x00), 4)     // A
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x32), 53)    // `
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x60), 62)    // F5
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x73), 74)    // Home
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x0A), 100)   // ISO §
        XCTAssertEqual(MacVirtualKeyMap.hidUsage(forKeyCode: 0x4C), 88)    // keypad Enter
    }

    func testModifierStateFromRawFlags() {
        // NSEvent.ModifierFlags: capsLock 1<<16, shift 17, control 18, option 19, command 20.
        let state = ReceiverModifierState(rawFlags: (1 << 16) | (1 << 17) | (1 << 20) | (1 << 23))
        XCTAssertEqual(state.held, [.shift, .command])
        XCTAssertTrue(state.capsLock)
        XCTAssertEqual(ReceiverModifierState(rawFlags: 0), ReceiverModifierState())
    }

    // MARK: - Helpers

    private let center = CGPoint(x: 0.5, y: 0.5)
    private let none = ReceiverModifierState()

    private func controlling() -> ReceiverInputForwarder {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.windowKeyChanged(true)
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.status, .controlling)
        return forwarder
    }

    private func mods(_ held: Set<ControlModifier>, capsLock: Bool = false) -> ReceiverModifierState {
        ReceiverModifierState(held: held, capsLock: capsLock)
    }

    // MARK: - View only by default

    func testANewSessionIsViewOnlyAndForwardsNothing() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.windowKeyChanged(true)
        XCTAssertEqual(forwarder.status, .viewOnly)
        XCTAssertEqual(forwarder.pointerMoved(center, inside: true), [])
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true), [])
        XCTAssertNil(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none), "typed keys stay local")
        XCTAssertEqual(forwarder.modifiersChanged(mods([.command])), [])
        XCTAssertEqual(forwarder.scrolled(dxPoints: 0, dyPoints: 5, inside: true, videoPixelsPerPoint: 2), [])
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .began, delta: 0.1), [])
    }

    func testRequestControlUsesTheExistingRequestOnce() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        XCTAssertEqual(forwarder.requestControl(), [.requestControl(true)])
        _ = forwarder.grantChanged(.requesting)
        XCTAssertEqual(forwarder.status, .requesting)
        XCTAssertEqual(forwarder.requestControl(), [], "already waiting")
        _ = forwarder.grantChanged(.notAllowed)
        XCTAssertEqual(forwarder.status, .declined)
        XCTAssertEqual(forwarder.requestControl(), [.requestControl(true)], "may ask again")
        _ = forwarder.grantChanged(.requestsDisabled)
        XCTAssertEqual(forwarder.requestControl(), [], "the Mac refuses requests from this device")
    }

    func testAnOldSendingMacOffersNoControl() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: false)
        _ = forwarder.windowKeyChanged(true)
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.status, .unavailable)
        XCTAssertEqual(forwarder.requestControl(), [])
        XCTAssertNil(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none))
    }

    func testGrantedButNotFrontmostStaysLocal() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.status, .inactive)
        XCTAssertNil(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none))
        XCTAssertEqual(forwarder.pointerMoved(center, inside: true), [])
    }

    // MARK: - Pointer

    func testHoverMovesForwardOnlyOverThePictureAndDeduplicate() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.pointerMoved(CGPoint(x: 0.2, y: 0.3), inside: true), [.pointerMove(x: 0.2, y: 0.3)])
        XCTAssertEqual(forwarder.pointerMoved(CGPoint(x: 0.2, y: 0.3), inside: true), [])
        XCTAssertEqual(forwarder.pointerMoved(CGPoint(x: 0, y: 0.3), inside: false), [], "letterbox hover")
    }

    func testClickDragReleaseOutsideTheVideo() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 1, at: CGPoint(x: 0.4, y: 0.4), inside: true),
                       [.pointerMove(x: 0.4, y: 0.4), .pointerDown(.left, clickCount: 1)])
        XCTAssertEqual(forwarder.pointerMoved(CGPoint(x: 0.9, y: 0.4), inside: true), [.pointerMove(x: 0.9, y: 0.4)])
        // Dragged past the edge: still forwarded, clamped by the geometry.
        XCTAssertEqual(forwarder.pointerMoved(CGPoint(x: 1, y: 0.4), inside: false), [.pointerMove(x: 1, y: 0.4)])
        XCTAssertEqual(forwarder.pointerUp(.left, at: CGPoint(x: 1, y: 0.4)), [.pointerUp(.left, clickCount: 1)])
        XCTAssertFalse(forwarder.holdsInput)
    }

    func testReleaseAtANewPositionMovesFirst() {
        var forwarder = controlling()
        _ = forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true)
        XCTAssertEqual(forwarder.pointerUp(.left, at: CGPoint(x: 0.6, y: 0.5)),
                       [.pointerMove(x: 0.6, y: 0.5), .pointerUp(.left, clickCount: 1)])
    }

    func testDoubleClickAndRightClickCarryTheirCountsAndButton() {
        var forwarder = controlling()
        _ = forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true)
        _ = forwarder.pointerUp(.left, at: center)
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 2, at: center, inside: true).last,
                       .pointerDown(.left, clickCount: 2))
        XCTAssertEqual(forwarder.pointerUp(.left, at: center), [.pointerUp(.left, clickCount: 2)])
        XCTAssertEqual(forwarder.pointerDown(.right, clickCount: 1, at: center, inside: true).last,
                       .pointerDown(.right, clickCount: 1))
        XCTAssertEqual(forwarder.pointerUp(.right, at: center), [.pointerUp(.right, clickCount: 1)])
    }

    func testASecondButtonDuringADragIsIgnoredAndItsReleaseNeverSent() {
        var forwarder = controlling()
        _ = forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true)
        XCTAssertEqual(forwarder.pointerDown(.right, clickCount: 1, at: center, inside: true), [])
        XCTAssertEqual(forwarder.pointerUp(.right, at: center), [])
        XCTAssertEqual(forwarder.pointerUp(.left, at: center), [.pointerUp(.left, clickCount: 1)])
    }

    func testClickInTheLetterboxDoesNothing() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 1, at: CGPoint(x: 0, y: 0.5), inside: false), [])
        XCTAssertEqual(forwarder.pointerUp(.left, at: nil), [])
    }

    func testWindowLosingFocusMidDragReleasesTheButton() {
        var forwarder = controlling()
        _ = forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true)
        XCTAssertEqual(forwarder.windowKeyChanged(false), [.pointerUp(.left, clickCount: 1), .cancelAll])
        XCTAssertEqual(forwarder.status, .inactive)
        XCTAssertEqual(forwarder.pointerUp(.left, at: center), [], "AppKit's late mouse-up is not sent twice")
    }

    func testScrollConvertsPointsToVideoPixels() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.scrolled(dxPoints: -1.5, dyPoints: 4, inside: true, videoPixelsPerPoint: 2),
                       [.scroll(dx: -3, dy: 8)])
        XCTAssertEqual(forwarder.scrolled(dxPoints: 0, dyPoints: 4, inside: false, videoPixelsPerPoint: 2), [])
        XCTAssertEqual(forwarder.scrolled(dxPoints: 0, dyPoints: 0, inside: true, videoPixelsPerPoint: 2), [])
    }

    func testPinchAndRotateFollowTheirLifecycle() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.gesture(.rotate, phase: .changed, delta: 0.1), [], "no began")
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .began, delta: 0), [.gesture(.magnify, .began, delta: 0)])
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .changed, delta: 0.05), [.gesture(.magnify, .changed, delta: 0.05)])
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .ended, delta: 0), [.gesture(.magnify, .ended, delta: 0)])
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .ended, delta: 0), [])
    }

    func testFocusLossMidPinchCancelsIt() {
        var forwarder = controlling()
        _ = forwarder.gesture(.magnify, phase: .began, delta: 0)
        XCTAssertEqual(forwarder.windowKeyChanged(false), [.gesture(.magnify, .cancelled, delta: 0), .cancelAll])
        XCTAssertEqual(forwarder.gesture(.magnify, phase: .ended, delta: 0), [])
    }

    // MARK: - Keyboard

    func testTypingWithModifiersFollowsTheDownUpLifecycle() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.modifiersChanged(mods([.command])), [.modifierDown(.command)])
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x08, isRepeat: false, modifiers: mods([.command])),
                       [.keyDown(usage: 6, modifiers: ["command"], isRepeat: false)])
        XCTAssertEqual(forwarder.keyUp(keyCode: 0x08), [.keyUp(usage: 6, modifiers: ["command"])])
        XCTAssertEqual(forwarder.modifiersChanged(mods([])), [.modifierUp(.command)])
        XCTAssertFalse(forwarder.holdsInput)
    }

    func testShortcutWithSeveralModifiers() {
        var forwarder = controlling()
        _ = forwarder.modifiersChanged(mods([.command]))
        XCTAssertEqual(forwarder.modifiersChanged(mods([.command, .shift])), [.modifierDown(.shift)])
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x14, isRepeat: false, modifiers: mods([.command, .shift])),
                       [.keyDown(usage: 32, modifiers: ["command", "shift"], isRepeat: false)])
    }

    func testModifierHeldFromCommandTabIsNeverSent() {
        // Command is still down from the Command-Tab that brought this window
        // forward: the sending Mac must not see a Command-Q.
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.grantChanged(.allowed)
        _ = forwarder.modifiersChanged(mods([.command]))   // pressed while another app was in front
        _ = forwarder.windowKeyChanged(true)
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x0C, isRepeat: false, modifiers: mods([.command])),
                       [.keyDown(usage: 20, modifiers: [], isRepeat: false)])
        XCTAssertEqual(forwarder.modifiersChanged(mods([])), [], "its release isn't sent either")
    }

    func testKeyRepeatIsForwardedOnlyForAKeyThisMacPressed() {
        var forwarder = controlling()
        _ = forwarder.keyDown(keyCode: 0x33, isRepeat: false, modifiers: none)
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x33, isRepeat: true, modifiers: none),
                       [.keyDown(usage: 42, modifiers: [], isRepeat: true)])
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x7B, isRepeat: true, modifiers: none), [],
                       "a repeat of a key pressed before forwarding began")
    }

    func testDuplicateDownWithoutRepeatIsNotSentTwice() {
        var forwarder = controlling()
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none)
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none), [])
    }

    func testKeyUpForAKeyPressedBeforeForwardingStaysLocal() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.windowKeyChanged(true)
        XCTAssertNil(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none))
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.keyUp(keyCode: 0x00), [], "consumed but not sent: no down reached the other Mac")
    }

    func testCapsLockTravelsAsANamedModifier() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: mods([], capsLock: true)),
                       [.keyDown(usage: 4, modifiers: ["capsLock"], isRepeat: false)])
    }

    func testAKeyWithNoUsageIsConsumedNotLeaked() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.keyDown(keyCode: 0xFF, isRepeat: false, modifiers: none), [])
    }

    // MARK: - Pause shortcut and release

    func testPauseShortcutReleasesEverythingAndKeepsTheGrant() {
        var forwarder = controlling()
        _ = forwarder.modifiersChanged(mods([.control]))
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: mods([.control]))
        _ = forwarder.modifiersChanged(mods([.control, .option]))
        let commands = forwarder.keyDown(keyCode: MacVirtualKeyMap.escapeKeyCode, isRepeat: false,
                                         modifiers: mods([.control, .option]))
        XCTAssertEqual(commands, [.keyUp(usage: 4, modifiers: ["control"]), .modifierUp(.option),
                                  .modifierUp(.control), .cancelAll],
                       "Escape itself never reaches the other Mac")
        XCTAssertEqual(forwarder.status, .paused)
        XCTAssertEqual(forwarder.grant, .allowed)
        XCTAssertNil(forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none), "paused: keys stay local")
        XCTAssertEqual(forwarder.modifiersChanged(mods([])), [], "released modifiers aren't released twice")
    }

    func testAClickOnThePictureResumesAndIsNotForwarded() {
        var forwarder = controlling()
        _ = forwarder.pause()
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true), [])
        XCTAssertEqual(forwarder.status, .controlling)
        XCTAssertEqual(forwarder.pointerUp(.left, at: center), [], "the resume click's release isn't sent")
        XCTAssertEqual(forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true).last,
                       .pointerDown(.left, clickCount: 1))
    }

    func testPauseShortcutWithoutControlIsAnOrdinaryLocalKey() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.windowKeyChanged(true)
        XCTAssertNil(forwarder.keyDown(keyCode: MacVirtualKeyMap.escapeKeyCode, isRepeat: false,
                                       modifiers: mods([.control, .option])))
    }

    func testPlainEscapeIsForwarded() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.keyDown(keyCode: MacVirtualKeyMap.escapeKeyCode, isRepeat: false, modifiers: none),
                       [.keyDown(usage: 41, modifiers: [], isRepeat: false)])
    }

    func testReleaseControlGivesTheGrantBack() {
        var forwarder = controlling()
        _ = forwarder.keyDown(keyCode: 0x31, isRepeat: false, modifiers: none)
        XCTAssertEqual(forwarder.releaseControl(),
                       [.keyUp(usage: 44, modifiers: []), .cancelAll, .requestControl(false)])
        _ = forwarder.grantChanged(.off)
        XCTAssertEqual(forwarder.status, .viewOnly)
    }

    func testReleaseWhileRequestingWithdrawsTheRequest() {
        var forwarder = ReceiverInputForwarder()
        forwarder.setConnected(true, inputSupported: true)
        _ = forwarder.grantChanged(.requesting)
        XCTAssertEqual(forwarder.releaseControl(), [.requestControl(false)])
    }

    func testFocusLossWithNothingHeldSendsNothing() {
        var forwarder = controlling()
        XCTAssertEqual(forwarder.windowKeyChanged(false), [])
    }

    // MARK: - Revocation, disconnects, reconnects

    func testRevocationMidTypingReleasesAndStopsForwarding() {
        var forwarder = controlling()
        _ = forwarder.modifiersChanged(mods([.shift]))
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: mods([.shift]))
        _ = forwarder.pointerDown(.left, clickCount: 1, at: center, inside: true)
        XCTAssertEqual(forwarder.grantChanged(.off),
                       [.pointerUp(.left, clickCount: 1), .keyUp(usage: 4, modifiers: ["shift"]),
                        .modifierUp(.shift), .cancelAll])
        XCTAssertEqual(forwarder.status, .viewOnly)
        XCTAssertNil(forwarder.keyUp(keyCode: 0x00), "the release after revocation stays local")
        XCTAssertEqual(forwarder.pointerMoved(center, inside: true), [])
    }

    func testDisconnectDuringInputSendsNothingAndClearsState() {
        var forwarder = controlling()
        _ = forwarder.modifiersChanged(mods([.command]))
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: mods([.command]))
        forwarder.setConnected(false, inputSupported: false)
        XCTAssertFalse(forwarder.holdsInput)
        XCTAssertEqual(forwarder.status, .unavailable)
    }

    func testReconnectStartsViewOnlyWithNoStaleKeys() {
        var forwarder = controlling()
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none)
        _ = forwarder.pause()
        forwarder.setConnected(false, inputSupported: false)
        forwarder.setConnected(true, inputSupported: true)
        XCTAssertEqual(forwarder.status, .viewOnly, "a new session's grant starts off")
        XCTAssertFalse(forwarder.paused)
        XCTAssertNil(forwarder.keyUp(keyCode: 0x00))
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.status, .controlling)
    }

    func testSenderResetClearsTrackingWithoutSending() {
        var forwarder = controlling()
        _ = forwarder.keyDown(keyCode: 0x00, isRepeat: false, modifiers: none)
        forwarder.senderReset()
        XCTAssertFalse(forwarder.holdsInput)
        XCTAssertEqual(forwarder.windowKeyChanged(false), [])
    }

    func testRegrantAfterPauseClearsThePause() {
        var forwarder = controlling()
        _ = forwarder.pause()
        _ = forwarder.grantChanged(.off)
        _ = forwarder.grantChanged(.allowed)
        XCTAssertEqual(forwarder.status, .controlling)
    }

    // MARK: - Presentation

    func testIndicatorOffersTheOneRelevantAction() {
        XCTAssertNil(ReceiverControlStatus.unavailable.title)
        XCTAssertEqual(ReceiverControlStatus.viewOnly.action, .request)
        XCTAssertEqual(ReceiverControlStatus.declined.action, .request)
        XCTAssertNil(ReceiverControlStatus.requestsDisabled.action)
        for status: ReceiverControlStatus in [.requesting, .inactive, .paused, .controlling] {
            XCTAssertEqual(status.action, .release)
        }
        XCTAssertTrue(ReceiverControlStatus.controlling.hint!.contains(ReceiverInputForwarder.releaseShortcutLabel))
    }

    /// Asking the Mac for control is "Request Control" in every app (TERMINOLOGY.md).
    func testControlLabelsUseTheCanonicalRequestControlNames() {
        XCTAssertEqual(ReceiverControlStatus.requesting.title, "Requesting Control…")
        XCTAssertEqual(ReceiverControlStatus.declined.title, "Control Declined")
        XCTAssertEqual(ReceiverControlStatus.requestsDisabled.title, "Control Not Available")
        XCTAssertEqual(ReceiverControlStatus.inactive.title, "Control Allowed")
        XCTAssertEqual(ReceiverControlStatus.paused.title, "Paused")
        XCTAssertEqual(ReceiverControlStatus.controlling.title, "Controlling")
        XCTAssertEqual(SessionInputWireState.requesting.receiverDisplayText, "Requesting Control…")
        XCTAssertEqual(SessionInputWireState.allowed.receiverDisplayText, "Control Allowed")
        XCTAssertEqual(SessionInputWireState.notAllowed.receiverDisplayText, "Control Declined")
        XCTAssertEqual(SessionInputWireState.requestsDisabled.receiverDisplayText, "Control Not Available")
        XCTAssertEqual(ReceiverControlStatus.requestsDisabled.hint,
                       "The other Mac doesn't accept control requests from this Mac.")
    }

    func testCursorEchoHandsBackToTheSendingMacAfterLocalMovementStops() {
        var echo = CursorEchoPolicy()
        XCTAssertTrue(echo.appliesRemotePosition(at: 10))
        echo.localMove(at: 10)
        XCTAssertFalse(echo.appliesRemotePosition(at: 10.1))
        XCTAssertTrue(echo.appliesRemotePosition(at: 10 + CursorEchoPolicy.holdAfterLocalMove))
        echo.localMove(at: 20)
        echo.reset()
        XCTAssertTrue(echo.appliesRemotePosition(at: 20))
    }

    // MARK: - Sender side

    func testScrollRemainderKeepsSlowTrackpadScrolls() {
        var remainder = ScrollRemainder()
        var total: Int32 = 0
        for _ in 0..<10 { total += remainder.take(dxPoints: 0, dyPoints: 0.3).dy }
        XCTAssertEqual(total, 3, "ten 0.3-point deltas scroll three points, not zero")
    }

    func testScrollRemainderStillRoundsASingleDeltaToNearest() {
        var remainder = ScrollRemainder()
        XCTAssertEqual(remainder.take(dxPoints: 0.6, dyPoints: -2.4).dx, 1)
        remainder.reset()
        XCTAssertEqual(remainder.take(dxPoints: 0, dyPoints: -2.4).dy, -2)
    }

    func testScrollRemainderNeverDriftsAcrossDirectionChanges() {
        var remainder = ScrollRemainder()
        var total: Int32 = 0
        let deltas = [0.4, 0.4, -0.3, 1.7, -0.9, 0.2, 0.25]
        for delta in deltas { total += remainder.take(dxPoints: 0, dyPoints: delta).dy }
        XCTAssertEqual(Double(total) + remainder.y, deltas.reduce(0, +), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(abs(remainder.y), 0.5)
    }

    func testSenderRepeatsOnlyHeldKeys() {
        var held = HeldKeyTracker()
        XCTAssertFalse(held.allowsRepeat(.deleteOrBackspace))
        held.down(.deleteOrBackspace)
        XCTAssertTrue(held.allowsRepeat(.deleteOrBackspace))
        held.up(.deleteOrBackspace)
        XCTAssertFalse(held.allowsRepeat(.deleteOrBackspace), "a repeat can't outlive its key")
    }

    func testSenderParsesTheNewUsagesAndOldOnesUnchanged() {
        XCTAssertEqual(HIDKeyUsage.parse(62 as NSNumber)?.keyCode, 96)    // F5
        XCTAssertEqual(HIDKeyUsage.parse(74 as NSNumber)?.keyCode, 115)   // Home
        XCTAssertEqual(HIDKeyUsage.parse(42 as NSNumber)?.keyCode, 51)    // Backspace, as before
        XCTAssertNil(HIDKeyUsage.parse(200 as NSNumber), "still ignores unknown usages")
    }

    // MARK: - Cost

    /// Per-event cost of the receiver's decision layer, for the record (no
    /// threshold): a 120 Hz trackpad produces ~120 moves a second.
    func testPointerMoveDecisionCost() {
        measure {
            var forwarder = controlling()
            for index in 0..<10_000 {
                let x = Double(index % 1000) / 1000
                _ = forwarder.pointerMoved(CGPoint(x: x, y: 0.5), inside: true)
            }
        }
    }
}
