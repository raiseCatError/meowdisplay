import CoreGraphics
import XCTest

/// Issue #20: independent Mirror/Extend per connected device.
///
/// `SyntheticMac` drives the real `DisplayModeCoordinator` and
/// `VirtualDisplayRegistry` the way `SenderController`/`MacSender` do —
/// begin a pipeline, rebuild exactly the sessions the coordinator names, end
/// a session — with synthetic receivers and fake display IDs standing in for
/// real devices and `CGVirtualDisplay`s. It proves the decision logic for the
/// combinations below; it does not prove real WindowServer, ScreenCaptureKit
/// or multi-device hardware behavior (see MULTI_DEVICE.md's physical
/// checklist for that).
final class DisplayModeAssignmentTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DisplayModeAssignmentTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Synthetic multi-receiver Mac

    /// One pipeline build per session: what mode it was built with and, in
    /// Extend, which virtual display it got.
    private struct Pipeline: Equatable {
        let assignment: DeviceDisplayAssignment
        let virtualDisplayID: CGDirectDisplayID?
    }

    private final class SyntheticMac {
        var coordinator: DisplayModeCoordinator
        let registry = VirtualDisplayRegistry()
        private(set) var pipelines: [String: Pipeline] = [:]
        private(set) var builds: [String: Int] = [:]
        private var nextDisplayID: CGDirectDisplayID = 100
        private var owners: [String: NSObject] = [:]
        /// Stands in for each live `VirtualDisplay` instance.
        private var displays: [String: NSObject] = [:]
        var hasUsablePhysicalDisplay = true

        init(defaults: DisplayModeDefaults = .init(mode: .extend, mirrorDisplayUUID: nil),
             videoEnabled: Bool = true, store: UserDefaults) {
            coordinator = DisplayModeCoordinator(defaults: defaults, videoEnabled: videoEnabled, store: store)
        }

        func connect(_ sessionID: String, peer: String?) {
            build(sessionID, assignment: coordinator.begin(sessionID: sessionID, peerID: peer))
        }

        /// Receiver vanished (disconnect, crash, cable pull): the pipeline
        /// and its display go away with the session.
        func drop(_ sessionID: String) {
            releaseDisplay(sessionID)
            pipelines.removeValue(forKey: sessionID)
            coordinator.end(sessionID: sessionID)
        }

        func requestMode(_ mode: CaptureMode, _ sessionID: String) -> DisplayModeChangeOutcome {
            let outcome = coordinator.requestMode(mode, sessionID: sessionID,
                                                  hasUsablePhysicalDisplay: hasUsablePhysicalDisplay)
            apply(outcome, sessionID)
            return outcome
        }

        func requestMirrorSource(_ source: MirrorSourcePreference, _ sessionID: String) -> DisplayModeChangeOutcome {
            let outcome = coordinator.requestMirrorSource(source, sessionID: sessionID)
            apply(outcome, sessionID)
            return outcome
        }

        func setDefaultMode(_ mode: CaptureMode) -> Set<String> {
            let rebuilds = coordinator.setDefaultMode(mode)
            rebuilds.forEach { rebuild($0.key, assignment: $0.value) }
            return Set(rebuilds.keys)
        }

        func setDefaultMirrorDisplay(_ uuid: String?) -> Set<String> {
            let rebuilds = coordinator.setDefaultMirrorDisplay(uuid)
            rebuilds.forEach { rebuild($0.key, assignment: $0.value) }
            return Set(rebuilds.keys)
        }

        func identify(_ sessionID: String, peer: String) -> DisplayModeChangeOutcome {
            let outcome = coordinator.identify(sessionID: sessionID, peerID: peer)
            apply(outcome, sessionID)
            return outcome
        }

        func mode(_ sessionID: String) -> CaptureMode? { pipelines[sessionID]?.assignment.mode }
        func display(_ sessionID: String) -> CGDirectDisplayID? { pipelines[sessionID]?.virtualDisplayID }

        func apply(_ outcome: DisplayModeChangeOutcome, _ sessionID: String) {
            if case .rebuild(let assignment) = outcome { rebuild(sessionID, assignment: assignment) }
        }

        /// `SenderController.rebuild(_:)`: stop the old pipeline, build a new
        /// one for the same target. The coordinator entry survives because
        /// `begin` finds it.
        private func rebuild(_ sessionID: String, assignment: DeviceDisplayAssignment) {
            releaseDisplay(sessionID)
            let rebuilt = coordinator.begin(sessionID: sessionID, peerID: nil)
            XCTAssertEqual(rebuilt, assignment, "a rebuild must carry the assignment it was planned with")
            build(sessionID, assignment: rebuilt)
        }

        private func build(_ sessionID: String, assignment: DeviceDisplayAssignment) {
            builds[sessionID, default: 0] += 1
            var displayID: CGDirectDisplayID?
            if assignment.mode == .extend {
                let owner = owners[sessionID] ?? NSObject()
                owners[sessionID] = owner
                let id = nextDisplayID
                nextDisplayID += 1
                let display = NSObject()
                displays[sessionID] = display
                registry.register(ObjectIdentifier(display), displayID: id,
                                  identity: VirtualDisplayIdentity(serial: id, productID: 0x4F53),
                                  owner: ObjectIdentifier(owner))
                displayID = id
            }
            pipelines[sessionID] = Pipeline(assignment: assignment, virtualDisplayID: displayID)
        }

        private func releaseDisplay(_ sessionID: String) {
            if let display = displays.removeValue(forKey: sessionID) { registry.unregister(ObjectIdentifier(display)) }
        }
    }

    // MARK: - Single device keeps the pre-#20 behavior

    func testDeviceWithoutItsOwnChoiceFollowsTheMacDefault() {
        let mac = SyntheticMac(defaults: .init(mode: .mirror, mirrorDisplayUUID: "DISPLAY-A"), store: store)
        mac.connect("usb:1", peer: "ipad")
        XCTAssertEqual(mac.mode("usb:1"), .mirror)
        XCTAssertEqual(mac.pipelines["usb:1"]?.assignment.mirrorDisplayUUID, "DISPLAY-A")
        XCTAssertFalse(mac.pipelines["usb:1"]!.assignment.modeIsDeviceChoice)
    }

    func testChangingTheDefaultRebuildsAFollowingDeviceLikeTheOldGlobalSwitch() {
        let mac = SyntheticMac(store: store)
        mac.connect("usb:1", peer: "iphone")
        XCTAssertEqual(mac.setDefaultMode(.mirror), ["usb:1"])
        XCTAssertEqual(mac.mode("usb:1"), .mirror)
        XCTAssertEqual(mac.builds["usb:1"], 2)
        XCTAssertNil(mac.display("usb:1"), "Mirror owns no virtual display")
        XCTAssertEqual(mac.registry.count, 0)
    }

    func testSettingTheDefaultToItsCurrentValueRebuildsNothing() {
        let mac = SyntheticMac(store: store)
        mac.connect("usb:1", peer: "iphone")
        XCTAssertEqual(mac.setDefaultMode(.extend), [])
        XCTAssertEqual(mac.builds["usb:1"], 1)
    }

    // MARK: - Mirror + Extend

    func testMirrorAndExtendRunSideBySideAndOnlyTheSwitchedDeviceRebuilds() {
        let mac = SyntheticMac(store: store)
        mac.connect("wifi:ipad", peer: "ipad")
        mac.connect("usb:iphone", peer: "iphone")
        let ipadDisplay = mac.display("wifi:ipad")

        XCTAssertEqual(mac.requestMode(.mirror, "usb:iphone"),
                       .rebuild(DeviceDisplayAssignment(mode: .mirror, mirrorDisplayUUID: nil,
                                                        modeIsDeviceChoice: true, mirrorSourceIsDeviceChoice: false)))
        XCTAssertEqual(mac.mode("usb:iphone"), .mirror)
        XCTAssertEqual(mac.mode("wifi:ipad"), .extend)
        XCTAssertEqual(mac.builds["wifi:ipad"], 1, "the iPad's pipeline is untouched")
        XCTAssertEqual(mac.display("wifi:ipad"), ipadDisplay, "and keeps the same virtual display")
        XCTAssertEqual(mac.registry.displayIDs, [ipadDisplay!])
    }

    func testAMirroringDeviceIgnoresALaterDefaultChange() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "ipad")
        mac.connect("b", peer: "iphone")
        _ = mac.requestMode(.mirror, "b")
        // Default flips to Mirror and back: only the follower moves.
        XCTAssertEqual(mac.setDefaultMode(.mirror), ["a"])
        XCTAssertEqual(mac.setDefaultMode(.extend), ["a"])
        XCTAssertEqual(mac.mode("b"), .mirror)
        XCTAssertEqual(mac.builds["b"], 2)
    }

    // MARK: - Extend + Extend

    func testTwoExtendedDevicesGetDistinctVirtualDisplays() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "ipad-a")
        mac.connect("b", peer: "ipad-b")
        XCTAssertNotNil(mac.display("a"))
        XCTAssertNotNil(mac.display("b"))
        XCTAssertNotEqual(mac.display("a"), mac.display("b"))
        XCTAssertEqual(mac.registry.count, 2)
    }

    func testOneExtendedDeviceSwitchingToMirrorLeavesTheOtherDisplayInPlace() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "ipad-a")
        mac.connect("b", peer: "ipad-b")
        let bDisplay = mac.display("b")
        _ = mac.requestMode(.mirror, "a")
        XCTAssertEqual(mac.registry.displayIDs, [bDisplay!], "A's display is released, B's survives")
        _ = mac.requestMode(.extend, "a")
        XCTAssertEqual(mac.registry.count, 2)
        XCTAssertNotEqual(mac.display("a"), bDisplay)
        XCTAssertEqual(mac.builds["b"], 1)
    }

    // MARK: - Mirror + Mirror

    func testTwoMirroringDevicesTargetDifferentDisplaysIndependently() {
        let mac = SyntheticMac(defaults: .init(mode: .mirror, mirrorDisplayUUID: nil), store: store)
        mac.connect("a", peer: "iphone")
        mac.connect("b", peer: "ipad")
        _ = mac.requestMirrorSource(.display(uuid: "BUILT-IN"), "a")
        _ = mac.requestMirrorSource(.display(uuid: "STUDIO"), "b")
        XCTAssertEqual(mac.pipelines["a"]?.assignment.mirrorDisplayUUID, "BUILT-IN")
        XCTAssertEqual(mac.pipelines["b"]?.assignment.mirrorDisplayUUID, "STUDIO")
        XCTAssertEqual(mac.builds["a"], 2)
        XCTAssertEqual(mac.builds["b"], 2)

        // Re-choosing A's source rebuilds A only.
        XCTAssertEqual(mac.requestMirrorSource(.automatic, "a"),
                       .rebuild(DeviceDisplayAssignment(mode: .mirror, mirrorDisplayUUID: nil,
                                                        modeIsDeviceChoice: false, mirrorSourceIsDeviceChoice: true)))
        XCTAssertEqual(mac.builds["b"], 2)
    }

    func testDefaultMirrorSourceMovesOnlyMirroringFollowers() {
        let mac = SyntheticMac(defaults: .init(mode: .mirror, mirrorDisplayUUID: nil), store: store)
        mac.connect("follower", peer: "iphone")
        mac.connect("chooser", peer: "ipad")
        mac.connect("extender", peer: "ipad-pro")
        _ = mac.requestMirrorSource(.display(uuid: "STUDIO"), "chooser")
        _ = mac.requestMode(.extend, "extender")
        XCTAssertEqual(mac.setDefaultMirrorDisplay("BUILT-IN"), ["follower"],
                       "the device with its own source and the Extend device are unaffected")
    }

    func testChoosingAMirrorSourceWhileExtendingIsRememberedWithoutARebuild() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "ipad")
        XCTAssertEqual(mac.requestMirrorSource(.display(uuid: "STUDIO"), "a"), .unchanged)
        XCTAssertEqual(mac.builds["a"], 1)
        _ = mac.requestMode(.mirror, "a")
        XCTAssertEqual(mac.pipelines["a"]?.assignment.mirrorDisplayUUID, "STUDIO")
    }

    // MARK: - Three or more receivers

    func testThreeReceiversInTheIssueTableRunIndependently() {
        // iPad A Extend · iPhone Mirror · iPad B Extend.
        let mac = SyntheticMac(store: store)
        mac.connect("ipad-a", peer: "A")
        mac.connect("iphone", peer: "P")
        mac.connect("ipad-b", peer: "B")
        _ = mac.requestMode(.mirror, "iphone")

        XCTAssertEqual(mac.mode("ipad-a"), .extend)
        XCTAssertEqual(mac.mode("iphone"), .mirror)
        XCTAssertEqual(mac.mode("ipad-b"), .extend)
        XCTAssertEqual(Set([mac.display("ipad-a"), mac.display("ipad-b")]).count, 2)
        XCTAssertEqual(mac.builds, ["ipad-a": 1, "iphone": 2, "ipad-b": 1])
    }

    func testFiveReceiversInEveryModeMixKeepTheirOwnModes() {
        let mac = SyntheticMac(store: store)
        let modes: [CaptureMode] = [.extend, .mirror, .extend, .mirror, .extend]
        for (index, mode) in modes.enumerated() {
            mac.connect("s\(index)", peer: "peer\(index)")
            _ = mac.requestMode(mode, "s\(index)")
        }
        for (index, mode) in modes.enumerated() { XCTAssertEqual(mac.mode("s\(index)"), mode) }
        XCTAssertEqual(mac.registry.count, 3)
        XCTAssertEqual(mac.setDefaultMode(.mirror), [], "every device has its own choice")
    }

    // MARK: - Connect / disconnect / reconnect / restart

    func testDisconnectingOneDeviceLeavesTheOthersAndReleasesOnlyItsDisplay() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "A")
        mac.connect("b", peer: "B")
        mac.connect("c", peer: "C")
        _ = mac.requestMode(.mirror, "b")
        let cDisplay = mac.display("c")
        mac.drop("a")
        XCTAssertEqual(mac.registry.displayIDs, [cDisplay!])
        XCTAssertEqual(mac.mode("b"), .mirror)
        XCTAssertNil(mac.coordinator.assignment(sessionID: "a"))
    }

    func testInterleavedConnectsAndDisconnectsNeverLeakEntriesOrDisplays() {
        let mac = SyntheticMac(store: store)
        for round in 0..<20 {
            mac.connect("a\(round)", peer: "A")
            mac.connect("b\(round)", peer: "B")
            _ = mac.requestMode(round.isMultiple(of: 2) ? .mirror : .extend, "a\(round)")
            mac.drop("b\(round)")
            mac.connect("b\(round)", peer: "B")
            mac.drop("a\(round)")
            mac.drop("b\(round)")
        }
        XCTAssertTrue(mac.coordinator.live.isEmpty)
        XCTAssertEqual(mac.registry.count, 0)
        // A's last request (round 19: Extend) is what it remembers.
        XCTAssertEqual(DeviceDisplayModeStore.load(peerID: "A", defaults: store).mode, .extend)
    }

    func testReceiverCrashMidSwitchLeavesNoStaleState() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "A")
        mac.connect("b", peer: "B")
        _ = mac.requestMode(.mirror, "a")
        mac.drop("a")   // crashed right after the rebuild began
        mac.coordinator.retain(sessionIDs: ["b"])
        XCTAssertEqual(Set(mac.coordinator.live.keys), ["b"])
        mac.connect("a", peer: "A")
        XCTAssertEqual(mac.mode("a"), .mirror, "the choice survives the crash")
    }

    func testDeviceKeepsItsModeAcrossARouteChange() {
        let mac = SyntheticMac(store: store)
        mac.connect("usb:1", peer: "iphone")
        _ = mac.requestMode(.mirror, "usb:1")
        mac.drop("usb:1")
        mac.connect("wifi:iphone", peer: "iphone")
        XCTAssertEqual(mac.mode("wifi:iphone"), .mirror)
    }

    func testSenderRestartRestoresEachDevicesModeAndSource() {
        do {
            let mac = SyntheticMac(store: store)
            mac.connect("a", peer: "A")
            mac.connect("b", peer: "B")
            mac.connect("c", peer: "C")
            _ = mac.requestMode(.mirror, "b")
            _ = mac.requestMirrorSource(.display(uuid: "STUDIO"), "b")
        }
        // New process: nothing live, only the store survives.
        let restarted = SyntheticMac(store: store)
        restarted.connect("c", peer: "C")
        restarted.connect("b", peer: "B")
        restarted.connect("a", peer: "A")
        XCTAssertEqual(restarted.mode("a"), .extend)
        XCTAssertEqual(restarted.mode("b"), .mirror)
        XCTAssertEqual(restarted.pipelines["b"]?.assignment.mirrorDisplayUUID, "STUDIO")
        XCTAssertEqual(restarted.mode("c"), .extend)
        XCTAssertEqual(restarted.registry.count, 2, "no displays carried over from the old process")
    }

    func testAnUnidentifiedSessionIsRebuiltOnceItsHelloRevealsAStoredChoice() {
        DeviceDisplayModeStore.save(.init(mode: .mirror, mirrorSource: nil), peerID: "iphone", defaults: store)
        let mac = SyntheticMac(store: store)
        mac.connect("usb:unresolved", peer: nil)
        XCTAssertEqual(mac.mode("usb:unresolved"), .extend, "no install id yet: the default")
        guard case .rebuild = mac.identify("usb:unresolved", peer: "iphone") else {
            return XCTFail("the stored Mirror choice must be applied")
        }
        XCTAssertEqual(mac.mode("usb:unresolved"), .mirror)
        XCTAssertEqual(mac.identify("usb:unresolved", peer: "iphone"), .unchanged, "never twice")
    }

    func testIdentifyingAFollowingDeviceRebuildsNothing() {
        let mac = SyntheticMac(store: store)
        mac.connect("usb:1", peer: nil)
        XCTAssertEqual(mac.identify("usb:1", peer: "iphone"), .unchanged)
        XCTAssertEqual(mac.builds["usb:1"], 1)
    }

    func testStagedModeForAnUnidentifiedSessionIsUsedByItsFirstPipeline() {
        var coordinator = DisplayModeCoordinator(defaults: .init(mode: .extend, mirrorDisplayUUID: nil),
                                                 videoEnabled: true, store: store)
        coordinator.stage(.mirror, sessionID: "usb:new")
        XCTAssertEqual(coordinator.begin(sessionID: "usb:new", peerID: nil).mode, .mirror)
        // A one-off choice survives later default changes for that session.
        XCTAssertTrue(coordinator.setDefaultMode(.mirror).isEmpty)
        XCTAssertTrue(coordinator.setDefaultMode(.extend).isEmpty)
        XCTAssertEqual(coordinator.assignment(sessionID: "usb:new")?.mode, .mirror)
    }

    func testDeviceChoiceRecordedBeforeConnectingIsUsed() {
        var coordinator = DisplayModeCoordinator(defaults: .init(mode: .extend, mirrorDisplayUUID: nil),
                                                 videoEnabled: true, store: store)
        coordinator.setDeviceMode(.mirror, peerID: "iphone")
        XCTAssertEqual(coordinator.begin(sessionID: "wifi:iphone", peerID: "iphone").mode, .mirror)
    }

    // MARK: - Rejections never touch anything

    func testMirrorRequestWithoutAPhysicalDisplayIsRejectedAndNotRemembered() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "A")
        mac.connect("b", peer: "B")
        mac.hasUsablePhysicalDisplay = false
        XCTAssertEqual(mac.requestMode(.mirror, "a"), .rejected(.noPhysicalDisplay))
        XCTAssertEqual(mac.mode("a"), .extend)
        XCTAssertEqual(mac.builds, ["a": 1, "b": 1])
        XCTAssertTrue(DeviceDisplayModeStore.load(peerID: "A", defaults: store).isFollowingDefault)
    }

    func testExtendRequestWhileVideoIsOffIsRejected() {
        let mac = SyntheticMac(defaults: .init(mode: .mirror, mirrorDisplayUUID: nil), videoEnabled: false, store: store)
        mac.connect("a", peer: "A")
        XCTAssertEqual(mac.requestMode(.extend, "a"), .rejected(.videoOff))
        XCTAssertEqual(mac.mode("a"), .mirror)
    }

    func testRequestForAnEndedSessionIsRejected() {
        let mac = SyntheticMac(store: store)
        XCTAssertEqual(mac.requestMode(.mirror, "gone"), .rejected(.unknownSession))
        XCTAssertEqual(mac.requestMirrorSource(.automatic, "gone"), .rejected(.unknownSession))
        XCTAssertEqual(mac.coordinator.followDefault(sessionID: "gone"), .rejected(.unknownSession))
    }

    func testRepeatingTheCurrentModeIsUnchangedButBecomesTheDevicesChoice() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "A")
        XCTAssertEqual(mac.requestMode(.extend, "a"), .unchanged)
        XCTAssertEqual(DeviceDisplayModeStore.load(peerID: "A", defaults: store).mode, .extend)
        XCTAssertEqual(mac.setDefaultMode(.mirror), [], "now pinned to Extend")
    }

    func testFollowDefaultDropsTheDevicesChoice() {
        let mac = SyntheticMac(store: store)
        mac.connect("a", peer: "A")
        _ = mac.requestMode(.mirror, "a")
        let outcome = mac.coordinator.followDefault(sessionID: "a")
        mac.apply(outcome, "a")
        XCTAssertEqual(mac.mode("a"), .extend)
        XCTAssertNil(store.dictionary(forKey: "displayMode.A"), "nothing left to remember")
    }

    func testFollowDefaultModeKeepsTheDevicesMirrorSource() {
        let mac = SyntheticMac(defaults: .init(mode: .mirror, mirrorDisplayUUID: nil), store: store)
        mac.connect("a", peer: "A")
        _ = mac.requestMode(.extend, "a")
        _ = mac.requestMirrorSource(.display(uuid: "STUDIO"), "a")
        mac.apply(mac.coordinator.followDefaultMode(sessionID: "a"), "a")
        XCTAssertEqual(mac.mode("a"), .mirror)
        XCTAssertEqual(mac.pipelines["a"]?.assignment.mirrorDisplayUUID, "STUDIO")
        mac.apply(mac.coordinator.requestMirrorSource(nil, sessionID: "a"), "a")
        XCTAssertNil(mac.pipelines["a"]?.assignment.mirrorDisplayUUID)
        XCTAssertNil(store.dictionary(forKey: "displayMode.A"))
    }

    // MARK: - Video Off

    func testVideoOffTransitionsEveryExtendSessionAndRemembersMirror() {
        var coordinator = DisplayModeCoordinator(defaults: .init(mode: .extend, mirrorDisplayUUID: nil),
                                                 videoEnabled: true, store: store)
        _ = coordinator.begin(sessionID: "a", peerID: "A")
        _ = coordinator.begin(sessionID: "b", peerID: "B")
        _ = coordinator.begin(sessionID: "c", peerID: "C")
        _ = coordinator.requestMode(.extend, sessionID: "b", hasUsablePhysicalDisplay: true)
        _ = coordinator.requestMode(.mirror, sessionID: "c", hasUsablePhysicalDisplay: true)

        XCTAssertEqual(coordinator.disableVideo(hasUsablePhysicalDisplay: true), ["a", "b"])
        XCTAssertEqual(coordinator.defaultMode, .mirror)
        XCTAssertEqual(DeviceDisplayModeStore.load(peerID: "B", defaults: store).mode, .mirror)
        for id in ["a", "b", "c"] { XCTAssertEqual(coordinator.assignment(sessionID: id)?.mode, .mirror) }

        coordinator.enableVideo()
        XCTAssertEqual(coordinator.resolvedAssignment(peerID: "B").mode, .mirror, "Video On never restores Extend")
    }

    func testHeadlessVideoOffKeepsExtend() {
        var coordinator = DisplayModeCoordinator(defaults: .init(mode: .extend, mirrorDisplayUUID: nil),
                                                 videoEnabled: true, store: store)
        _ = coordinator.begin(sessionID: "a", peerID: "A")
        XCTAssertEqual(coordinator.disableVideo(hasUsablePhysicalDisplay: false), [])
        XCTAssertEqual(coordinator.defaultMode, .extend)
        XCTAssertEqual(coordinator.assignment(sessionID: "a")?.mode, .extend)
    }

    func testSummaryNamesTheModeItsOriginAndTheMirrorSource() {
        XCTAssertEqual(DeviceDisplayAssignment(mode: .extend, mirrorDisplayUUID: "X", modeIsDeviceChoice: false,
                                               mirrorSourceIsDeviceChoice: false).summary,
                       "Extend (Mac default)")
        XCTAssertEqual(DeviceDisplayAssignment(mode: .mirror, mirrorDisplayUUID: nil, modeIsDeviceChoice: true,
                                               mirrorSourceIsDeviceChoice: false).summary,
                       "Mirror (this device's choice) · Automatic display")
        XCTAssertEqual(DeviceDisplayAssignment(mode: .mirror, mirrorDisplayUUID: "X", modeIsDeviceChoice: false,
                                               mirrorSourceIsDeviceChoice: true).summary,
                       "Mirror (Mac default) · Selected display")
    }

    // MARK: - Persistence

    func testStoreRoundTripsEveryShape() {
        let shapes: [DeviceDisplayModePreference] = [
            .init(mode: .mirror, mirrorSource: nil),
            .init(mode: .extend, mirrorSource: .automatic),
            .init(mode: nil, mirrorSource: .display(uuid: "X")),
            .init(mode: .mirror, mirrorSource: .display(uuid: "Y")),
        ]
        for shape in shapes {
            DeviceDisplayModeStore.save(shape, peerID: "p", defaults: store)
            XCTAssertEqual(DeviceDisplayModeStore.load(peerID: "p", defaults: store), shape)
        }
        DeviceDisplayModeStore.save(.followsDefault, peerID: "p", defaults: store)
        XCTAssertNil(store.dictionary(forKey: "displayMode.p"))
    }

    func testDevicesAreStoredSeparately() {
        DeviceDisplayModeStore.save(.init(mode: .mirror, mirrorSource: nil), peerID: "A", defaults: store)
        XCTAssertTrue(DeviceDisplayModeStore.load(peerID: "B", defaults: store).isFollowingDefault)
        DeviceDisplayModeStore.remove(peerID: "A", defaults: store)
        XCTAssertTrue(DeviceDisplayModeStore.load(peerID: "A", defaults: store).isFollowingDefault)
    }

    func testUnreadableRecordFollowsTheDefault() {
        store.set(["mode": "sideways", "mirrorSource": "display"], forKey: "displayMode.p")
        XCTAssertEqual(DeviceDisplayModeStore.load(peerID: "p", defaults: store), .followsDefault)
    }

    // MARK: - Mirror source resolution and lost displays

    private let builtIn = MirrorSourceCandidate(displayID: 1, persistentID: "BUILT-IN")
    private let studio = MirrorSourceCandidate(displayID: 2, persistentID: "STUDIO")
    private let ipadDesktop = MirrorSourceCandidate(displayID: 100, persistentID: "MEOW-IPAD")

    func testAutomaticWithoutMeowDisplaysIsTheFirstDisplayAsBefore() {
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: nil, in: [studio, builtIn], excluding: []),
                       .automatic(2))
    }

    func testAutomaticNeverMirrorsAnotherDevicesExtendedDesktop() {
        // WindowServer may list a MeowDisplay virtual display first.
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: nil, in: [ipadDesktop, builtIn], excluding: [100]),
                       .automatic(1))
    }

    func testExplicitPickOfAnotherDevicesDesktopIsHonored() {
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: "MEOW-IPAD", in: [ipadDesktop, builtIn],
                                                    excluding: [100]),
                       .selected(100))
    }

    func testLostSelectedDisplayFallsBackToAutomaticAndSaysSo() {
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: "STUDIO", in: [ipadDesktop, builtIn],
                                                    excluding: [100]),
                       .selectedUnavailable(uuid: "STUDIO", fallback: 1))
    }

    func testOnlyMeowDisplaysLeftMeansNothingToMirror() {
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: nil, in: [ipadDesktop], excluding: [100]),
                       .unavailable)
        XCTAssertEqual(MirrorSourceResolver.resolve(selectedUUID: "STUDIO", in: [ipadDesktop], excluding: [100]),
                       .unavailable)
    }

    func testCaptureRecoveryReattachesOrFallsBackPastMeowDisplays() {
        XCTAssertEqual(MirrorSourceResolver.recoveryDisplay(preferred: 2, in: [ipadDesktop, builtIn, studio],
                                                            excluding: [100]), 2)
        // The mirrored external display was unplugged.
        XCTAssertEqual(MirrorSourceResolver.recoveryDisplay(preferred: 2, in: [ipadDesktop, builtIn],
                                                            excluding: [100]), 1)
        XCTAssertNil(MirrorSourceResolver.recoveryDisplay(preferred: 2, in: [ipadDesktop], excluding: [100]))
    }

    // MARK: - Virtual display identity

    func testRegistryTracksOwnershipAndCleanup() {
        let registry = VirtualDisplayRegistry()
        let a = NSObject(), b = NSObject(), display = NSObject()
        let identity = VirtualDisplayIdentity(serial: 7, productID: 0x4F53)
        registry.register(ObjectIdentifier(display), displayID: 100, identity: identity, owner: ObjectIdentifier(a))
        XCTAssertTrue(registry.isClaimed(identity, byOtherThan: ObjectIdentifier(b)))
        XCTAssertFalse(registry.isClaimed(identity, byOtherThan: ObjectIdentifier(a)), "a session's own display")
        XCTAssertEqual(registry.displayIDs(ownedBy: ObjectIdentifier(a)), [100])
        registry.unregister(ObjectIdentifier(display))
        XCTAssertFalse(registry.isClaimed(identity, byOtherThan: ObjectIdentifier(b)))
        XCTAssertEqual(registry.count, 0)
    }

    func testLateReleaseOfAnOldDisplayKeepsANewerOneWithTheSameID() {
        let registry = VirtualDisplayRegistry()
        let old = NSObject(), new = NSObject(), owner = NSObject()
        let identity = VirtualDisplayIdentity(serial: 7, productID: 0x4F53)
        registry.register(ObjectIdentifier(old), displayID: 100, identity: identity, owner: ObjectIdentifier(owner))
        registry.register(ObjectIdentifier(new), displayID: 100, identity: identity, owner: ObjectIdentifier(owner))
        registry.unregister(ObjectIdentifier(old))
        XCTAssertEqual(registry.displayIDs, [100])
    }

    func testIdentityPlannerProbesTheUsualOffsetsWhenNothingCollides() {
        XCTAssertEqual(VirtualDisplayIdentityPlanner.offsets(serial: 50, baseOffset: 0) { _ in false }, [0, 1, 2])
        XCTAssertEqual(VirtualDisplayIdentityPlanner.offsets(serial: 50, baseOffset: 4) { _ in false }, [4, 5, 6])
    }

    func testIdentityPlannerSkipsAnIdentityAnotherLiveSessionHolds() {
        // Two devices whose serials collide (an FNV-1a hash collision, or a
        // fallback identity landing on another device's base identity).
        let held = VirtualDisplayIdentityPlanner.identity(serial: 50, offset: 0)
        let offsets = VirtualDisplayIdentityPlanner.offsets(serial: 50, baseOffset: 0) { $0 == held }
        XCTAssertEqual(offsets, [1, 2, 3])
        XCTAssertEqual(VirtualDisplayIdentityPlanner.identity(serial: 50, offset: 1),
                       VirtualDisplayIdentity(serial: 51, productID: 0x4F54))
    }

    func testIdentityPlannerIsBoundedWhenEverythingCollides() {
        XCTAssertEqual(VirtualDisplayIdentityPlanner.offsets(serial: 50, baseOffset: 0) { _ in true }, [])
    }

    func testIdentityPlannerAgainstALiveRegistry() {
        let registry = VirtualDisplayRegistry()
        let other = NSObject(), me = NSObject(), display = NSObject()
        registry.register(ObjectIdentifier(display), displayID: 100, identity: VirtualDisplayIdentityPlanner.identity(serial: 50, offset: 0),
                          owner: ObjectIdentifier(other))
        let mine = VirtualDisplayIdentityPlanner.offsets(serial: 50, baseOffset: 0) {
            registry.isClaimed($0, byOtherThan: ObjectIdentifier(me))
        }
        XCTAssertEqual(mine.first, 1)
    }

    // MARK: - Input lands on each device's own display

    func testEachReceiversInputMapsIntoItsOwnDisplay() {
        // iPad A extends (VD 100 at x=1512), iPhone mirrors the built-in
        // display (id 1 at the origin), iPad B extends (VD 101 at x=-1366).
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1512, height: 982),
            100: CGRect(x: 1512, y: 0, width: 1366, height: 1024),
            101: CGRect(x: -1366, y: 0, width: 1366, height: 1024),
        ]
        let receivers: [(mode: InputTargetMode, virtual: CGDirectDisplayID?, expected: CGPoint)] = [
            (.extend, 100, CGPoint(x: 1512 + 683, y: 512)),
            (.mirror, nil, CGPoint(x: 756, y: 491)),
            (.extend, 101, CGPoint(x: -1366 + 683, y: 512)),
        ]
        for receiver in receivers {
            let target = InputTargetResolver.displayID(mode: receiver.mode, mirrorDisplayID: 1,
                                                       virtualDisplayID: receiver.virtual)
            let point = InputCoordinateMapper.point(x: 0.5, y: 0.5, in: bounds[target!]!)
            XCTAssertEqual(point, receiver.expected)
        }
    }

    func testExtendSessionWithoutADisplayHasNoInputTarget() {
        // Mid-rebuild: input must be dropped, never sent to another display.
        XCTAssertNil(InputTargetResolver.displayID(mode: .extend, mirrorDisplayID: 1, virtualDisplayID: nil))
    }
}
