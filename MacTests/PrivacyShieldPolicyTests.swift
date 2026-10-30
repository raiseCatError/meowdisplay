import XCTest

/// Privacy Shield rules: on by default for remote connections, off for local ones; covers while
/// any connected device's kind has it on; a local reveal lasts until the Mac has had no physical
/// input for the relock time; only hardware input counts as someone at the Mac.
final class PrivacyShieldPolicyTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [PrivacyShieldPolicy.remoteKey, PrivacyShieldPolicy.localKey]

    override func setUp() { for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) } }
    override func tearDown() { for k in keys { if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }

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
}
