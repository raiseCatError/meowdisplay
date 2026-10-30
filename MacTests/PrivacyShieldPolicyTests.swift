import XCTest

/// Privacy Shield rules: on by default for remote connections, off for local ones; covers while
/// any connected device's kind has it on; a local reveal lasts until the Mac has had no physical
/// input for the relock time; only hardware input counts as someone at the Mac.
final class PrivacyShieldPolicyTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [PrivacyShieldPolicy.remoteKey, PrivacyShieldPolicy.localKey]

    override func setUp() { for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) } }
    override func tearDown() { for k in keys { if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }

    func testACoveredDeviceDisconnectingKeepsTheCoverUntilUnlockedAtTheMac() {
        // A reconnect or mode switch ends the session: the cover must not drop, even briefly.
        XCTAssertTrue(PrivacyShieldPolicy.holdsAfterDisconnect(showing: true, endedProtected: true))
        XCTAssertFalse(PrivacyShieldPolicy.holdsAfterDisconnect(showing: false, endedProtected: true), "nothing covered: nothing to hold")
        XCTAssertFalse(PrivacyShieldPolicy.holdsAfterDisconnect(showing: true, endedProtected: false), "an unprotected device ended")
        // Held with no device connected: still covered, whichever settings are on.
        XCTAssertTrue(PrivacyShieldPolicy.shouldCover(remoteOn: false, localOn: false, sessions: [], revealed: false,
                                                      physicalIdle: 0, relockAfter: 300, held: true))
        // Only an unlock at the Mac (a reveal) uncovers it.
        XCTAssertFalse(PrivacyShieldPolicy.shouldCover(remoteOn: true, localOn: true, sessions: [], revealed: true,
                                                       physicalIdle: 1, relockAfter: 300, held: true))
        XCTAssertFalse(PrivacyShieldPolicy.shouldCover(remoteOn: true, localOn: true, sessions: [], revealed: false,
                                                       physicalIdle: 0, relockAfter: 300, held: false))
    }

    func testLockMacReportsWhatMacOSDid() {
        XCTAssertEqual(MacScreenLock.result(posted: true, lockedAfter: true), .locked)
        XCTAssertEqual(MacScreenLock.result(posted: true, lockedAfter: false), .failed)
        XCTAssertEqual(MacScreenLock.result(posted: false, lockedAfter: false), .accessibility)
        XCTAssertEqual(LockMacResult(rawValue: "control"), .control)
    }

    func testRemoteIsOnAndLocalIsOffByDefaultAndChoicesStick() {
        XCTAssertTrue(PrivacyShieldPolicy.isOn(remote: true))
        XCTAssertFalse(PrivacyShieldPolicy.isOn(remote: false))
        UserDefaults.standard.set(false, forKey: PrivacyShieldPolicy.remoteKey)
        UserDefaults.standard.set(true, forKey: PrivacyShieldPolicy.localKey)
        XCTAssertFalse(PrivacyShieldPolicy.isOn(remote: true))
        XCTAssertTrue(PrivacyShieldPolicy.isOn(remote: false))
    }

    func testCoversWhileAnyConnectedDeviceHasItOn() {
        func cover(_ sessions: [Bool], remoteOn: Bool = true, localOn: Bool = false) -> Bool {
            PrivacyShieldPolicy.shouldCover(remoteOn: remoteOn, localOn: localOn, sessions: sessions, revealed: false, physicalIdle: 0, relockAfter: 300)
        }
        XCTAssertFalse(cover([]), "nothing connected")
        XCTAssertTrue(cover([true]), "a remote device")
        XCTAssertFalse(cover([false]), "a local device, local off")
        XCTAssertTrue(cover([false], localOn: true))
        XCTAssertTrue(cover([false, true]), "until every remote session ends")
        XCTAssertFalse(cover([true], remoteOn: false))
    }

    func testARevealLastsUntilTheMacIsIdleForTheRelockTime() {
        func cover(idle: TimeInterval) -> Bool {
            PrivacyShieldPolicy.shouldCover(remoteOn: true, localOn: false, sessions: [true], revealed: true, physicalIdle: idle, relockAfter: 300)
        }
        XCTAssertFalse(cover(idle: 10))
        XCTAssertFalse(cover(idle: 299))
        XCTAssertTrue(cover(idle: 300), "five minutes without physical input: covered again")
    }

    func testOnlyHardwareInputCountsAsSomeoneAtTheMac() {
        XCTAssertTrue(PrivacyShieldPolicy.isPhysical(sourcePID: 0))
        XCTAssertFalse(PrivacyShieldPolicy.isPhysical(sourcePID: Int64(ProcessInfo.processInfo.processIdentifier)), "MeowDisplay's remote input")
        XCTAssertFalse(PrivacyShieldPolicy.isPhysical(sourcePID: 4242), "another app's synthetic input")
    }

    func testEveryPhysicalDisplayIsCoveredButNotMeowDisplaysOwnVirtualOnes() {
        XCTAssertEqual(PrivacyShieldPolicy.coveredDisplays([1, 2, 33], virtual: [33]), [1, 2])
        XCTAssertEqual(PrivacyShieldPolicy.coveredDisplays([1], virtual: []), [1])
    }

    func testTheCoverWindowListReportsChangesOnly() {
        _ = PrivacyShieldWindows.replace(with: [])
        XCTAssertTrue(PrivacyShieldWindows.replace(with: [10, 11]))
        XCTAssertFalse(PrivacyShieldWindows.replace(with: [10, 11]))
        XCTAssertEqual(PrivacyShieldWindows.current, [10, 11])
        XCTAssertTrue(PrivacyShieldWindows.replace(with: []))
    }

    func testUnlockingPausesRemoteInputUntilItEnds() {
        XCTAssertFalse(PrivacyShieldWindows.isUnlocking)
        PrivacyShieldWindows.isUnlocking = true
        XCTAssertTrue(PrivacyShieldWindows.isUnlocking, "InputInjector's sink and system gestures drop remote input meanwhile")
        PrivacyShieldWindows.isUnlocking = false
        XCTAssertFalse(PrivacyShieldWindows.isUnlocking)
    }

    func testTheCoverMessageDimsThenGoesDarkWithNoOneAtTheMac() {
        XCTAssertEqual(PrivacyShieldPolicy.coverLook(idle: 0), .bright)
        XCTAssertEqual(PrivacyShieldPolicy.coverLook(idle: 59), .bright)
        XCTAssertEqual(PrivacyShieldPolicy.coverLook(idle: 60), .dim)
        XCTAssertEqual(PrivacyShieldPolicy.coverLook(idle: 299), .dim)
        XCTAssertEqual(PrivacyShieldPolicy.coverLook(idle: 300), .dark, "pure black: an OLED panel's pixels are off")
    }

    func testTheCoverMessageMovesAcrossTheScreenAndStaysOnIt() {
        let block = PrivacyShieldPolicy.coverBlock
        for screen in [CGSize(width: 1470, height: 956), CGSize(width: 3008, height: 1692), CGSize(width: 1024, height: 768)] {
            let room = CGRect(origin: .zero, size: screen).insetBy(dx: 24, dy: 24)
            var seen = Set<String>()
            var previous: CGPoint?
            for step in 0..<500 {
                let c = PrivacyShieldPolicy.coverCenter(step: step, screen: screen)
                let rect = CGRect(x: c.x - block.width / 2, y: c.y - block.height / 2, width: block.width, height: block.height)
                XCTAssertTrue(room.contains(rect), "step \(step) on \(screen): \(rect) leaves the screen")
                if let p = previous {
                    // Always a different ninth of the screen, so the lit pixels change every minute.
                    let gap = max(abs(c.x - p.x) / (screen.width - block.width - 48), abs(c.y - p.y) / (screen.height - block.height - 48))
                    XCTAssertGreaterThan(gap, 0.08, "step \(step) on \(screen) barely moved")
                }
                previous = c
                seen.insert("\(Int(c.x)),\(Int(c.y))")
            }
            XCTAssertGreaterThan(seen.count, 450, "spots vary from round to round on \(screen)")
        }
        // A screen smaller than the block: centred, never off screen.
        XCTAssertEqual(PrivacyShieldPolicy.coverCenter(step: 3, screen: CGSize(width: 600, height: 180)), CGPoint(x: 300, y: 90))
    }

    // MARK: Touch ID

    func testTouchIDIsUsedOnlyWhenAllowedAndAvailable() {
        XCTAssertEqual(PrivacyShieldPolicy.unlockMethod(touchIDAllowed: true, touchIDAvailable: true), .touchIDOrPassword)
        XCTAssertEqual(PrivacyShieldPolicy.unlockMethod(touchIDAllowed: false, touchIDAvailable: true), .password,
                       "the owner turned Touch ID off")
        XCTAssertEqual(PrivacyShieldPolicy.unlockMethod(touchIDAllowed: true, touchIDAvailable: false), .password,
                       "no sensor, no enrolled finger, or the lid is closed")
    }

    func testTheTouchIDSheetIsHiddenFromDevicesLikeThePasswordDialog() {
        XCTAssertTrue(PrivacyShieldPolicy.unlockPromptBundleIDs.contains("com.apple.SecurityAgent"))
        XCTAssertTrue(PrivacyShieldPolicy.unlockPromptBundleIDs.contains("com.apple.LocalAuthentication.UIAgent"))
        XCTAssertTrue(PrivacyShieldPolicy.unlockPromptBundleIDs.contains("com.apple.coreautha"))
    }

    // MARK: While the Mac asks for its password

    func testOnlyLivenessHandshakeAndTeardownAreHandledWhileUnlocking() {
        for type in ["ping", "stats", "kf", "hello", WireMessage.sessionInviteResponse, WireMessage.sleeping, WireMessage.closing] {
            XCTAssertTrue(PrivacyShieldPolicy.handlesWhileUnlocking(type), type)
        }
        for type in ["touch", "pointer", "scroll", "keyboard", "gesture", "pencil", WireMessage.windowAction, WireMessage.workspaceFocus,
                     WireMessage.workspaceRequest, LockMacWire.request, WireMessage.filesRequest, ClipboardWire.type,
                     WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest, WireMessage.appCatalogRequest,
                     WireMessage.nativeAppGesture, WireMessage.displayModeRequest, WireMessage.videoRequest, "unknownType"] {
            XCTAssertFalse(PrivacyShieldPolicy.handlesWhileUnlocking(type), type)
        }
    }

    func testOnlyReleasesArePostedWhileUnlocking() {
        XCTAssertTrue(PrivacyShieldPolicy.postsWhileUnlocking(.keyUp, flags: []))
        XCTAssertTrue(PrivacyShieldPolicy.postsWhileUnlocking(.leftMouseUp, flags: []))
        XCTAssertTrue(PrivacyShieldPolicy.postsWhileUnlocking(.rightMouseUp, flags: []))
        XCTAssertTrue(PrivacyShieldPolicy.postsWhileUnlocking(.flagsChanged, flags: []), "every modifier released")
        XCTAssertFalse(PrivacyShieldPolicy.postsWhileUnlocking(.flagsChanged, flags: .maskShift), "a modifier going down")
        XCTAssertFalse(PrivacyShieldPolicy.postsWhileUnlocking(.keyDown, flags: []))
        XCTAssertFalse(PrivacyShieldPolicy.postsWhileUnlocking(.leftMouseDown, flags: []))
        XCTAssertFalse(PrivacyShieldPolicy.postsWhileUnlocking(.mouseMoved, flags: []))
        XCTAssertFalse(PrivacyShieldPolicy.postsWhileUnlocking(.scrollWheel, flags: []))
    }

    // MARK: Removing the cover takes the person at the Mac

    func testACoveredShieldIgnoresSettingsTurnedOffBehindItsBack() {
        let up = (remote: true, local: false)
        let external = PrivacyShieldPolicy.latched(up, stored: (remote: false, local: false), ownerConfirmed: false)
        XCTAssertTrue(external.remote, "defaults write can't turn the covered shield off")
        let on = PrivacyShieldPolicy.latched(up, stored: (remote: true, local: true), ownerConfirmed: false)
        XCTAssertTrue(on.local, "turning one on always counts")
        let confirmed = PrivacyShieldPolicy.latched(up, stored: (remote: false, local: false), ownerConfirmed: true)
        XCTAssertFalse(confirmed.remote, "the person at the Mac, confirmed, can turn it off")
    }

    func testOnlyLoginwindowsLogoutRestartOrShutdownSkipsTheLock() {
        let logout: UInt32 = 0x6C6F_676F, shutdown: UInt32 = 0x7368_7574
        XCTAssertTrue(PrivacyShieldPolicy.isSystemEnding(quitReason: logout, senderBundleID: "com.apple.loginwindow"))
        XCTAssertTrue(PrivacyShieldPolicy.isSystemEnding(quitReason: shutdown, senderBundleID: "com.apple.loginwindow"))
        XCTAssertFalse(PrivacyShieldPolicy.isSystemEnding(quitReason: logout, senderBundleID: "com.apple.Terminal"), "another app can't skip it")
        XCTAssertFalse(PrivacyShieldPolicy.isSystemEnding(quitReason: 0x7175_6974, senderBundleID: "com.apple.loginwindow"), "an unknown reason locks")
        XCTAssertFalse(PrivacyShieldPolicy.isSystemEnding(quitReason: nil, senderBundleID: "com.apple.loginwindow"))
    }

}
