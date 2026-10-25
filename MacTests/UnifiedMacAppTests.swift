import XCTest

/// The unified MeowDisplay app: the sender and "Use This Mac as a Display"
/// in one bundle. Pins what keeps existing installs safe — the sender's
/// identity, pins, settings, bundle id and feed are untouched — and the rules
/// that keep the two roles apart. These run in a hostless, unsigned test
/// bundle: they prove the configuration and decision logic, not live
/// Keychain isolation, TCC or networking on a signed build (see
/// UNIFIED_MAC_APP.md's physical checklist).
final class UnifiedMacAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UnifiedMacAppTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Roles

    func testDisplayRoleIsOffForEveryExistingInstall() {
        let state = MacAppRoleState(defaults: defaults)
        XCTAssertFalse(state.receiverEnabled)
        XCTAssertTrue(state.senderMayConnect)
        XCTAssertEqual(state.launchEffects, [], "a sender install never starts advertising a receiver by itself")
    }

    func testTurningTheDisplayRoleOnEndsSharingThenStartsTheReceiver() {
        var state = MacAppRoleState(defaults: defaults)
        XCTAssertEqual(state.setReceiverEnabled(true, defaults: defaults), [.endSenderSessions, .startReceiver])
        XCTAssertFalse(state.senderMayConnect)
        XCTAssertEqual(state.setReceiverEnabled(true, defaults: defaults), [], "idempotent")
    }

    func testTurningItOffStopsTheReceiverThenResumesSharing() {
        var state = MacAppRoleState(defaults: defaults)
        _ = state.setReceiverEnabled(true, defaults: defaults)
        XCTAssertEqual(state.setReceiverEnabled(false, defaults: defaults), [.stopReceiver, .resumeSender])
        XCTAssertTrue(state.senderMayConnect)
        XCTAssertEqual(state.setReceiverEnabled(false, defaults: defaults), [])
    }

    func testTheChoiceSurvivesARelaunch() {
        var state = MacAppRoleState(defaults: defaults)
        _ = state.setReceiverEnabled(true, defaults: defaults)
        let relaunched = MacAppRoleState(defaults: defaults)
        XCTAssertTrue(relaunched.receiverEnabled)
        XCTAssertEqual(relaunched.launchEffects, [.startReceiver])
        XCTAssertFalse(relaunched.senderMayConnect, "no sender session can start before the receiver is up")
    }

    func testRapidTogglingAlwaysEndsInOneConsistentRole() {
        var state = MacAppRoleState(defaults: defaults)
        var receiverRunning = false
        for index in 0..<50 {
            for effect in state.setReceiverEnabled(index.isMultiple(of: 3), defaults: defaults) {
                switch effect {
                case .startReceiver: XCTAssertFalse(receiverRunning); receiverRunning = true
                case .stopReceiver: XCTAssertTrue(receiverRunning); receiverRunning = false
                case .endSenderSessions, .resumeSender: break
                }
            }
            XCTAssertEqual(receiverRunning, state.receiverEnabled)
            XCTAssertEqual(state.senderMayConnect, !receiverRunning)
        }
    }

    func testTheStandaloneReceiverRunningBlocksTheDisplayRole() {
        XCTAssertTrue(StandaloneReceiverConflict.isRunning(
            among: ["com.apple.finder", nil, "com.raisecaterror.meowdisplay.mac.receiver"]))
        XCTAssertTrue(StandaloneReceiverConflict.isRunning(among: ["com.raisecaterror.meowdisplay.mac.receiver.debug"]))
        XCTAssertFalse(StandaloneReceiverConflict.isRunning(
            among: ["com.raisecaterror.meowdisplay.mac", "com.raisecaterror.meowdisplay.ios", nil]))
    }

    // MARK: - Trust stays per role

    func testTheSendersKeychainNamesAreExactlyTheOriginalOnes() {
        // Every existing sender identity and pin lives under these names; a
        // change here would orphan them and force every user to re-pair.
        XCTAssertEqual(TrustStore.Namespace.standard.identityLabel, "com.opendisplay.identity.v1")
        XCTAssertEqual(TrustStore.Namespace.standard.pinService, "com.opendisplay.trust.v1")
        XCTAssertEqual(TrustStore.shared.namespace, .standard)
    }

    func testTheReceiverRoleHasItsOwnIdentityAndPins() {
        let receiver = TrustStore.Namespace.macReceiverRole
        XCTAssertNotEqual(receiver.identityLabel, TrustStore.Namespace.standard.identityLabel)
        XCTAssertNotEqual(receiver.pinService, TrustStore.Namespace.standard.pinService)
        XCTAssertFalse(receiver.pinService == TrustStore.Namespace.standard.identityLabel
                           || receiver.identityLabel == TrustStore.Namespace.standard.pinService)
    }

    func testOnlyTheUnifiedAppSeparatesTheReceiverRole() {
        XCTAssertTrue(ReceiverRoleConfiguration.separateTrust(infoDictionary: ["MeowDisplayReceiverRoleTrust": "separate"]))
        XCTAssertFalse(ReceiverRoleConfiguration.separateTrust(infoDictionary: [:]), "iPhone/iPad, standalone receiver")
        XCTAssertFalse(ReceiverRoleConfiguration.separateTrust(infoDictionary: nil))
        XCTAssertFalse(ReceiverRoleConfiguration.separateTrust(infoDictionary: ["MeowDisplayReceiverRoleTrust": "shared"]))
        // This hostless bundle declares nothing: the receiver path keeps the
        // shared store, as the iPhone/iPad app and standalone receiver do.
        XCTAssertTrue(TrustStore.receiverRole === TrustStore.shared)
    }

    func testOnlyTheReceiverRolesReconnectSettingMovesInTheUnifiedApp() {
        XCTAssertEqual(ReceiverRoleConfiguration.defaultsKey("autoReconnectEnabled", separate: false), "autoReconnectEnabled")
        XCTAssertEqual(ReceiverRoleConfiguration.defaultsKey("autoReconnectEnabled", separate: true),
                       "receiver.autoReconnectEnabled")
        XCTAssertEqual(StreamReceiver.autoReconnectKey, "autoReconnectEnabled", "unchanged outside the unified app")
    }

    // MARK: - No self-discovery

    func testEachRoleNeverSeesTheOther() {
        let results = ["IPHONE", "OWN-RECEIVER", nil, "OTHER-MAC"]
        XCTAssertEqual(SameAppPeerFilter.excludingSameApp(results, ownIDs: ["OWN-RECEIVER"], txtID: { $0 }),
                       ["IPHONE", nil, "OTHER-MAC"])
        XCTAssertEqual(SameAppPeerFilter.excludingSameApp(results, ownIDs: [], txtID: { $0 }), results)
        XCTAssertFalse(SameAppPeerFilter.isSameApp(txtID: nil, ownIDs: ["X"]), "an id-less legacy service is kept")
    }

    func testAReceiverOnlyAppHasNoSameAppPeer() {
        defaults.set("SOME-ID", forKey: "installID")
        XCTAssertNil(SameAppPeerFilter.receiverRoleInstallID(defaults: defaults))
    }

    // MARK: - Packaging

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()

    private func targetBlock(_ name: String) throws -> String {
        let spec = try String(contentsOf: Self.repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = spec.components(separatedBy: "\n")
        let targets = try XCTUnwrap(lines.firstIndex(of: "targets:"))
        let start = try XCTUnwrap(lines[targets...].firstIndex(of: "  \(name):"), name)
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("  ") && !$0.hasPrefix("   ") && $0.hasSuffix(":") }
            ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    func testTheUnifiedAppKeepsTheSendersIdentityFloorAndFeed() throws {
        let sender = try targetBlock("OpenSidecarMac")
        XCTAssertTrue(sender.contains("PRODUCT_BUNDLE_IDENTIFIER: com.raisecaterror.meowdisplay.mac\n"),
                      "TCC grants, Keychain group and Sparkle all key on this id")
        XCTAssertTrue(sender.contains("deploymentTarget: \"14.0\""))
        XCTAssertTrue(sender.contains("SUFeedURL: https://meowdisplay.app/appcast.xml"))
        XCTAssertTrue(sender.contains("MeowDisplayReceiverRoleTrust: separate"))
        XCTAssertTrue(sender.contains("path: MacReceiver"))
        for excluded in ["OpenSidecarMacReceiverApp.swift", "Info.plist", "\"*.entitlements\"", "\"*.xcstrings\"", "Assets.xcassets"] {
            XCTAssertTrue(sender.contains("- \(excluded)"), "the receiver's \(excluded) stays out of MeowDisplay.app")
        }
    }

    func testTheStandaloneReceiverStillShipsForMacOS12() throws {
        let receiver = try targetBlock("OpenSidecarMacReceiver")
        XCTAssertTrue(receiver.contains("deploymentTarget: \"12.0\""))
        XCTAssertTrue(receiver.contains("PRODUCT_BUNDLE_IDENTIFIER: com.raisecaterror.meowdisplay.mac.receiver\n"))
        XCTAssertTrue(receiver.contains("SUFeedURL: https://meowdisplay.app/appcast-receiver.xml"))
        XCTAssertFalse(receiver.contains("MeowDisplayReceiverRoleTrust"), "its users keep their identity and pins")
    }

    // MARK: - Dock and Command-Tab

    func testTheDisplayWindowAlwaysMakesTheAppRegular() {
        XCTAssertFalse(MacAppActivationPolicy.isRegular(showsDockIcon: false, displayWindowVisible: false),
                       "menu-bar-only, as the user chose")
        XCTAssertTrue(MacAppActivationPolicy.isRegular(showsDockIcon: true, displayWindowVisible: false))
        XCTAssertTrue(MacAppActivationPolicy.isRegular(showsDockIcon: false, displayWindowVisible: true),
                      "Command-Tab must leave a full-screen display window, whatever the presentation setting")
        XCTAssertTrue(MacAppActivationPolicy.isRegular(showsDockIcon: true, displayWindowVisible: true))
    }

    // MARK: - Settings

    func testTheDisplayRoleHasItsOwnSettingsPage() {
        let categories = Array(SettingsCategory.allCases)
        let index = categories.firstIndex(of: .displayRole)
        XCTAssertNotNil(index)
        XCTAssertEqual(index.flatMap { categories.indices.contains($0 + 1) ? categories[$0 + 1] : nil }, .system,
                       "beside the sender's pages, before System")
        XCTAssertEqual(SettingsCategory.displayRole.label, "This Mac as a Display")
        XCTAssertFalse(SettingsCategory.displayRole.systemImage.isEmpty)
        for query in ["This Mac as a Display", "paired macs", "receiver name"] {
            XCTAssertEqual(SettingsSearchIndex.shared.search(query: query).first?.category, .displayRole, query)
        }
    }

    /// The display role's settings page and the receiver views it reuses
    /// only ever touch the receiver role's trust and settings.
    func testReceiverSettingsNeverReachTheSendersTrustOrKeys() throws {
        let files = ["Mac/DisplayRoleSection.swift", "Shared/SessionInvitationViews.swift"]
            + (try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("MacReceiver").path))
                .filter { $0.hasSuffix(".swift") }.map { "MacReceiver/\($0)" }
        for file in files {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["TrustStore.shared", "role: .sender", "\"incomingSessionAutomaticallyAllow\"",
                              "\"incomingSessionPeerPolicy.v1\"", "\"remoteEndpointHints.v1\"",
                              "\"wakeMetadataHints.v1\""] {
                XCTAssertFalse(source.contains(forbidden), "\(file) uses \(forbidden)")
            }
        }
    }
}
