import XCTest

/// iPhone/iPad Remote Access setup and status wording (iOS/RemoteAccessGuidance.swift) and the
/// in-memory knock results the Home row reads (Shared/RemoteKnockOutcomes.swift).
final class RemoteAccessGuidanceTests: XCTestCase {
    private let allKnockResults: [RemoteKnockResult] = [
        .delivered, .notAccepted, .identityMismatch(otherPeerID: nil), .identityMismatch(otherPeerID: "B"),
        .timedOut, .refused, .unreachable, .dnsFailed, .failed, .cancelled,
    ]

    // MARK: - Problem from the last knock

    func testEveryKnockResultMapsToTheAndroidReason() {
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .dnsFailed), .addressNotFound)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .timedOut), .timedOut)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .refused), .refused)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .unreachable), .noRoute)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .failed), .notMeowDisplay)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .identityMismatch(otherPeerID: nil)), .differentMac)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .identityMismatch(otherPeerID: "B")), .differentMac)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .notAccepted), .notAccepted)
        XCTAssertEqual(RemoteAccessProblem(lastKnock: .delivered), .didNotConnectBack,
                       "a delivered knock and no session means the Mac didn't connect back")
        XCTAssertNil(RemoteAccessProblem(lastKnock: .cancelled), "a cancelled knock says nothing about the Mac")
    }

    func testIdentityProblemsMatchTheKnockSecurityFailures() {
        for result in allKnockResults {
            guard let problem = RemoteAccessProblem(lastKnock: result) else { continue }
            XCTAssertEqual(problem.isIdentityProblem, result.isSecurityFailure, "\(result)")
        }
    }

    func testEveryProblemSaysWhatHappenedAndWhatToDo() {
        let summaries = RemoteAccessProblem.allCases.map { $0.summary(deviceKind: "iPhone") }
        XCTAssertEqual(Set(summaries).count, RemoteAccessProblem.allCases.count, "each reason reads differently")
        for problem in RemoteAccessProblem.allCases {
            XCTAssertFalse(problem.summary(deviceKind: "iPhone").isEmpty, "\(problem)")
            let hint = problem.hint(deviceKind: "iPhone")
            XCTAssertFalse(hint.isEmpty, "\(problem)")
            XCTAssertFalse(hint.contains("Oops") || hint.contains("!"), "\(problem): plain tone")
        }
        XCTAssertTrue(RemoteAccessProblem.noRoute.hint(deviceKind: "iPad").contains("This iPad"))
        XCTAssertTrue(RemoteAccessProblem.notAccepted.summary(deviceKind: "iPad").contains("this iPad"))
        XCTAssertTrue(RemoteAccessProblem.timedOut.hint(deviceKind: "iPhone").contains("Tailscale"))
    }

    func testDifferentMacNamesThePairedMacThatAnsweredWhenKnown() {
        let named = RemoteAccessProblem.differentMac.hint(deviceKind: "iPhone", otherMacName: "Studio")
        XCTAssertTrue(named.contains("Studio"))
        XCTAssertTrue(named.contains("Nothing was connected"))
        let unnamed = RemoteAccessProblem.differentMac.hint(deviceKind: "iPhone")
        XCTAssertTrue(unnamed.contains("Nothing was connected"))
        XCTAssertNotEqual(named, unnamed)
    }

    // MARK: - Home row

    func testProgressOnlyRefinesAConnectOverRemote() {
        typealias Row = RemoteConnectRowStatus
        for stage in [WakeConnectStage.preparing, .waking, .waitingForConnection] {
            XCTAssertEqual(Row.progress(stage: stage, wakePacketsSent: 0, hasSavedAddress: true, lastKnock: nil), .contacting)
            XCTAssertEqual(Row.progress(stage: stage, wakePacketsSent: 0, hasSavedAddress: true, lastKnock: .timedOut), .contacting,
                           "a knock that failed is retried while the attempt runs")
            XCTAssertEqual(Row.progress(stage: stage, wakePacketsSent: 0, hasSavedAddress: true, lastKnock: .delivered), .waitingForMac)
            XCTAssertNil(Row.progress(stage: stage, wakePacketsSent: 0, hasSavedAddress: false, lastKnock: nil),
                         "no saved address: nothing is sent over Remote")
            XCTAssertNil(Row.progress(stage: stage, wakePacketsSent: 1, hasSavedAddress: true, lastKnock: nil),
                         "Wake-on-LAN was sent: Waking… is true")
        }
        for stage in [WakeConnectStage.idle, .authenticating, .promoting, .waitingForVideo, .connected, .failed("timedOut")] {
            XCTAssertNil(Row.progress(stage: stage, wakePacketsSent: 0, hasSavedAddress: true, lastKnock: .delivered), "\(stage)")
        }
        XCTAssertEqual(Row.Progress.contacting.text, "Contacting your Mac…")
        XCTAssertEqual(Row.Progress.waitingForMac.text, "Waiting for your Mac to connect…")
    }

    func testOnlyATimedOutAttemptWhoseMacNeverConnectedIsExplained() {
        typealias Row = RemoteConnectRowStatus
        XCTAssertEqual(Row.problem(failureReason: "timedOut", macConnected: false, hasSavedAddress: true, lastKnock: .unreachable), .noRoute)
        XCTAssertEqual(Row.problem(failureReason: "timedOut", macConnected: false, hasSavedAddress: true, lastKnock: .delivered), .didNotConnectBack)
        XCTAssertNil(Row.problem(failureReason: "timedOut", macConnected: true, hasSavedAddress: true, lastKnock: .delivered),
                     "the Mac connected: the knock isn't why it failed")
        XCTAssertNil(Row.problem(failureReason: "timedOut", macConnected: false, hasSavedAddress: false, lastKnock: .timedOut))
        XCTAssertNil(Row.problem(failureReason: "timedOut", macConnected: false, hasSavedAddress: true, lastKnock: nil))
        XCTAssertNil(Row.problem(failureReason: "timedOut", macConnected: false, hasSavedAddress: true, lastKnock: .cancelled))
        for reason in ["cancelled", "peerForgotten", "protocolIncompatible", nil] {
            XCTAssertNil(Row.problem(failureReason: reason, macConnected: false, hasSavedAddress: true, lastKnock: .timedOut),
                         "\(reason ?? "nil") keeps its own words")
        }
    }

    // MARK: - Setup page

    func testSetupStateAndWhenBeforeYouStartOpensByItself() {
        let none = RemoteAccessSetup(pairedPeerIDs: [], savedAddressPeerIDs: [])
        XCTAssertEqual(none, .needsPairing)
        XCTAssertTrue(none.showsPrerequisitesExpanded)

        let paired = RemoteAccessSetup(pairedPeerIDs: ["A", "B"], savedAddressPeerIDs: [])
        XCTAssertEqual(paired, .needsAddress)
        XCTAssertTrue(paired.showsPrerequisitesExpanded)

        XCTAssertEqual(RemoteAccessSetup(pairedPeerIDs: ["A"], savedAddressPeerIDs: ["Gone"]), .needsAddress,
                       "an address left for a Mac that is no longer paired doesn't count")
        XCTAssertEqual(RemoteAccessSetup(pairedPeerIDs: [], savedAddressPeerIDs: ["Gone"]), .needsPairing)

        let ready = RemoteAccessSetup(pairedPeerIDs: ["A", "B"], savedAddressPeerIDs: ["B"])
        XCTAssertEqual(ready, .ready)
        XCTAssertFalse(ready.showsPrerequisitesExpanded)
    }

    func testSuggestionPrefersIPv4ThenANameThenIPv6() {
        let v4 = "100.101.102.103", v6 = "fd7a:115c:a1e0::1", name = "mac.tailnet-name.ts.net"
        XCTAssertEqual(RemoteAddressSuggestion.host(sharedNames: [name], sharedIPs: [v6, v4], saved: nil), v4)
        XCTAssertEqual(RemoteAddressSuggestion.host(sharedNames: [name], sharedIPs: [v6], saved: nil), name)
        XCTAssertEqual(RemoteAddressSuggestion.host(sharedNames: [], sharedIPs: [v6], saved: nil), v6)
        XCTAssertNil(RemoteAddressSuggestion.host(sharedNames: [], sharedIPs: [], saved: nil))
    }

    func testSuggestionIsHiddenWhenItIsAlreadyTheSavedAddress() {
        XCTAssertNil(RemoteAddressSuggestion.host(sharedNames: [], sharedIPs: ["100.64.0.1"], saved: "100.64.0.1"))
        XCTAssertNil(RemoteAddressSuggestion.host(sharedNames: ["Mac.Tail.ts.net"], sharedIPs: [], saved: " mac.tail.ts.net "))
        XCTAssertEqual(RemoteAddressSuggestion.host(sharedNames: [], sharedIPs: ["100.64.0.2"], saved: "100.64.0.1"), "100.64.0.2",
                       "a different shared address is offered; replacing the saved one is still the person's choice")
    }

    func testSharedAddressesStayASuggestionWhileTheAppleReceiverGateIsClosed() {
        XCTAssertEqual(RemoteAddressSuggestion.connectsAutomatically, TailnetFamilies.appleReceiverKnocking != .none)
        XCTAssertFalse(RemoteAddressSuggestion.connectsAutomatically,
                       "iPhone/iPad automatic knocking needs device verification first (#81, #95); update the Remote Access copy with it")
    }

    func testTailscaleLinksAreOfficialHTTPSPages() {
        XCTAssertEqual(TailscaleLinks.appStore.scheme, "https")
        XCTAssertEqual(TailscaleLinks.appStore.host, "apps.apple.com")
        XCTAssertTrue(TailscaleLinks.appStore.path.hasSuffix("/id1470499037"))
        XCTAssertEqual(TailscaleLinks.vpnOnDemand.scheme, "https")
        XCTAssertEqual(TailscaleLinks.vpnOnDemand.host, "tailscale.com")
    }

    func testPairOverRemoteUnreachableSaysToCheckTailscale() {
        XCTAssertTrue(RemotePairingGuidance.detail(for: .unreachable)?.contains("Tailscale") == true)
        XCTAssertEqual(RemotePairingGuidance.detail(for: .keyChanged), RemotePairingFailureKind.keyChanged.detail)
        XCTAssertNil(RemotePairingGuidance.detail(for: .rejected))
    }

    // MARK: - Settings search

    func testSearchFindsRemoteAccessSetupItems() {
        let expectations: [(String, String)] = [
            ("tailscale", "shareTailscaleAddresses"), ("before you start", "remoteAccessPrerequisites"),
            ("install tailscale", "remoteAccessPrerequisites"), ("vpn on demand", "remoteAccessPrerequisites"),
            ("magicdns", "remoteAddress"), ("ip address", "remoteAddress"), ("pair over remote", "pairOverRemote"),
            ("didn't connect back", "remoteAccessHelp"), ("troubleshooting", "remoteAccessHelp"),
        ]
        for (query, id) in expectations {
            let results = MobileSettingsSearchIndex.search(query, isPad: false, debug: false)
            XCTAssertEqual(results.first?.category, .remoteAccess, query)
            XCTAssertTrue(results.contains { $0.id == id }, "\(query) finds \(id)")
        }
    }
}

/// The Home row's source of knock results: newest per Mac, never an earlier attempt's.
@MainActor
final class RemoteKnockOutcomesTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testNewestResultPerMacWins() {
        let outcomes = RemoteKnockOutcomes()
        outcomes.apply(.timedOut, peerID: "A", at: t0)
        outcomes.apply(.delivered, peerID: "A", at: t0.addingTimeInterval(2))
        outcomes.apply(.unreachable, peerID: "A", at: t0.addingTimeInterval(1))
        XCTAssertEqual(outcomes.outcome(forPeerID: "A")?.result, .delivered, "an older knock that lands late doesn't win")
        outcomes.apply(.refused, peerID: "B", at: t0)
        XCTAssertEqual(outcomes.outcome(forPeerID: "B")?.result, .refused)
        XCTAssertEqual(outcomes.outcome(forPeerID: "A")?.result, .delivered, "each Mac keeps its own")
    }

    func testCancelledNeverReplacesAResult() {
        let outcomes = RemoteKnockOutcomes()
        outcomes.apply(.dnsFailed, peerID: "A", at: t0)
        outcomes.apply(.cancelled, peerID: "A", at: t0.addingTimeInterval(1))
        XCTAssertEqual(outcomes.outcome(forPeerID: "A")?.result, .dnsFailed)
        outcomes.apply(.cancelled, peerID: "C", at: t0)
        XCTAssertNil(outcomes.outcome(forPeerID: "C"))
    }

    func testResetIgnoresKnocksFromBeforeIt() {
        let outcomes = RemoteKnockOutcomes()
        outcomes.apply(.notAccepted, peerID: "A", at: t0)
        outcomes.reset(peerID: "A", at: t0.addingTimeInterval(5))
        XCTAssertNil(outcomes.outcome(forPeerID: "A"))
        outcomes.apply(.timedOut, peerID: "A", at: t0.addingTimeInterval(4))
        XCTAssertNil(outcomes.outcome(forPeerID: "A"), "a knock that ended before the new Connect belongs to the old one")
        outcomes.apply(.delivered, peerID: "A", at: t0.addingTimeInterval(6))
        XCTAssertEqual(outcomes.outcome(forPeerID: "A")?.result, .delivered)
    }

    func testRecordFromAnotherQueueArrivesOnTheMainActor() async {
        let peerID = "record-\(UUID().uuidString)"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                RemoteKnockOutcomes.record(.identityMismatch(otherPeerID: "B"), peerID: peerID)
                done.resume()
            }
        }
        for _ in 0..<50 where RemoteKnockOutcomes.shared.outcome(forPeerID: peerID) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(RemoteKnockOutcomes.shared.outcome(forPeerID: peerID)?.result, .identityMismatch(otherPeerID: "B"))
        RemoteKnockOutcomes.shared.reset(peerID: peerID)
    }
}
