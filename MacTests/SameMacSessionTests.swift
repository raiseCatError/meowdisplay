import XCTest

/// Several people logged in to one Mac (Fast User Switching), each with
/// their own MeowDisplay: opt-in discovery hints, the receiver's grouping,
/// and the sender's input gate while a session is switched out.
final class SameMacSessionTests: XCTestCase {
    private let familyMac = "Family-MacBook"

    private func advertisement(_ label: String?, host: String = "Family MacBook", localHost: String? = "Family-MacBook",
                               availability: MacLoginSessionAvailability = .available) -> SenderSessionAdvertisement? {
        SenderSessionAdvertisement(hostName: host, localHostName: localHost, sessionLabel: label,
                                   availability: availability)
    }

    private func entry(_ id: String, name: String, _ advertisement: SenderSessionAdvertisement?) -> NearbyMacDirectory.Entry {
        var txt = ["id": id, "pv": "22", "pp": "13"]
        for (key, value) in advertisement?.txtFields ?? [:] { txt[key] = value }
        return .init(serviceName: name, txt: txt)
    }

    private let alex = "A0000000-0000-4000-8000-00000000000A"
    private let mom = "B0000000-0000-4000-8000-00000000000B"
    private let dad = "C0000000-0000-4000-8000-00000000000C"
    private let office = "D0000000-0000-4000-8000-00000000000D"

    // MARK: - Sender advertisement

    func testEverySessionOfOneMacSharesTheHostGroupAndNothingElse() throws {
        let a = try XCTUnwrap(advertisement("Alex"))
        let m = try XCTUnwrap(advertisement("Mom"))
        XCTAssertEqual(a.hostGroup, m.hostGroup)
        XCTAssertEqual(a.hostGroup.count, 16)
        XCTAssertNotEqual(a.displayName, m.displayName)
        XCTAssertEqual(a.displayName, "Family MacBook — Alex")
        XCTAssertEqual(SenderSessionAdvertisement.hostGroup(localHostName: "family-macbook"),
                       SenderSessionAdvertisement.hostGroup(localHostName: " Family-MacBook "),
                       "the system's host name, case and spacing aside")
        XCTAssertNotEqual(a.hostGroup, advertisement("Alex", localHost: "Office-Mac")?.hostGroup)
        XCTAssertFalse(a.hostGroup.contains("family"), "the group is a digest, not the name")
    }

    func testNoLabelOrNoHostNameMeansNoSessionAdvertisement() {
        XCTAssertNil(advertisement(nil))
        XCTAssertNil(advertisement("   "))
        XCTAssertNil(advertisement("Alex", localHost: nil))
        XCTAssertNil(advertisement("Alex", localHost: ""))
    }

    func testLabelsAndNamesStayWithinBonjourLimits() throws {
        let long = String(repeating: "Ä", count: 80)
        let session = try XCTUnwrap(advertisement(long, host: String(repeating: "🐱", count: 40)))
        XCTAssertEqual(session.sessionLabel.count, SessionDiscoveryTXT.maximumLabelLength)
        XCTAssertLessThanOrEqual(session.displayName.utf8.count, 63)
        XCTAssertEqual(session.txtFields["ss"], "a")
        XCTAssertEqual(advertisement("Alex", availability: .switchedOut)?.txtFields["ss"], "i")
    }

    func testTheOptInIsPerUserAndNeedsALabel() throws {
        let suite = "SameMacSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SessionDiscoveryPreferences.isEnabled(defaults: defaults), "off by default")
        defaults.set(true, forKey: SessionDiscoveryPreferences.enabledKey)
        XCTAssertFalse(SessionDiscoveryPreferences.isEnabled(defaults: defaults),
                       "never falls back to the account name")
        defaults.set("  Alex ", forKey: SessionDiscoveryPreferences.labelKey)
        XCTAssertTrue(SessionDiscoveryPreferences.isEnabled(defaults: defaults))
        let ad = SessionDiscoveryPreferences.advertisement(hostName: "Family MacBook", localHostName: familyMac,
                                                           onConsole: false, defaults: defaults)
        XCTAssertEqual(ad?.sessionLabel, "Alex")
        XCTAssertEqual(ad?.availability, .switchedOut)
        defaults.set(false, forKey: SessionDiscoveryPreferences.enabledKey)
        XCTAssertNil(SessionDiscoveryPreferences.advertisement(hostName: "Family MacBook", localHostName: familyMac,
                                                               onConsole: true, defaults: defaults))
    }

    // MARK: - Receiver grouping

    func testThreeSessionsOfOneMacAreOneMacWithThreeSessions() throws {
        let groups = NearbyMacDirectory.groups(from: [
            entry(dad, name: "Family MacBook — Dad", advertisement("Dad")),
            entry(alex, name: "Family MacBook — Alex", advertisement("Alex")),
            entry(mom, name: "Family MacBook — Mom", advertisement("Mom", availability: .switchedOut)),
            entry(office, name: "Office Mac", nil),
        ])
        XCTAssertEqual(groups.map(\.title), ["Family MacBook", "Office Mac"])
        let family = try XCTUnwrap(groups.first)
        XCTAssertTrue(family.isMultiSession)
        XCTAssertEqual(family.sessions.map(\.rowTitle), ["Alex", "Dad", "Mom"])
        XCTAssertEqual(family.sessions.map(\.installID), [alex, dad, mom])
        XCTAssertEqual(family.sessions.map(\.availability), [.available, .available, .switchedOut])
        XCTAssertFalse(groups[1].isMultiSession)
        XCTAssertEqual(groups[1].sessions.first?.rowTitle, "Office Mac")
    }

    func testOrdinarySendersAreListedExactlyAsBefore() {
        let groups = NearbyMacDirectory.groups(from: [
            entry(office, name: "Office Mac", nil),
            .init(serviceName: "Old Mac", txt: [:]),
            .init(serviceName: "Odd Mac", txt: ["id": "not-a-uuid"]),
        ])
        XCTAssertEqual(groups.map(\.title), ["Odd Mac", "Office Mac", "Old Mac"])
        XCTAssertTrue(groups.allSatisfy { !$0.isMultiSession && $0.sessions.first?.availability == .available })
        XCTAssertEqual(groups.first { $0.title == "Old Mac" }?.sessions.first?.installID, nil)
    }

    func testOneOptedInSessionReadsAsOneMacRow() throws {
        let groups = NearbyMacDirectory.groups(from: [entry(alex, name: "Family MacBook — Alex", advertisement("Alex"))])
        let only = try XCTUnwrap(groups.first)
        XCTAssertFalse(only.isMultiSession)
        XCTAssertEqual(only.title, "Family MacBook — Alex")
        XCTAssertEqual(only.sessions.first?.rowTitle, "Family MacBook — Alex")
    }

    func testTheSameSenderSeenTwiceIsOneRow() {
        let groups = NearbyMacDirectory.groups(from: [
            entry(alex, name: "Family MacBook — Alex", advertisement("Alex")),
            entry(alex, name: "Family MacBook — Alex", advertisement("Alex")),
            entry(mom, name: "Family MacBook — Mom", advertisement("Mom")),
        ])
        XCTAssertEqual(groups.first?.sessions.count, 2)
    }

    func testDuplicateLabelsStayDistinguishable() {
        let groups = NearbyMacDirectory.groups(from: [
            entry(alex, name: "Family MacBook — Alex", advertisement("Alex")),
            entry(dad, name: "Family MacBook — Alex (2)", advertisement("alex")),
        ])
        let titles = groups.first?.sessions.map(\.rowTitle) ?? []
        XCTAssertEqual(Set(titles.map { $0.lowercased() }).count, 2, "\(titles)")
        XCTAssertEqual(groups.first?.sessions.map(\.installID), [alex, dad], "each keeps its own identity")
    }

    func testSameNamedMacsElsewhereAreNotMerged() {
        let groups = NearbyMacDirectory.groups(from: [
            entry(alex, name: "MacBook — Alex", advertisement("Alex", host: "MacBook", localHost: "MacBook-1")),
            entry(mom, name: "MacBook — Mom", advertisement("Mom", host: "MacBook", localHost: "MacBook-2")),
        ])
        XCTAssertEqual(groups.count, 2, "grouping follows the host group, never the display name")
    }

    func testMalformedHintsFallBackToAnOrdinaryRow() {
        let good = advertisement("Alex")!.txtFields
        func with(_ change: (inout [String: String]) -> Void) -> NearbyMacDirectory.Entry {
            var txt = good
            change(&txt)
            txt["id"] = UUID().uuidString
            return .init(serviceName: "Spoof", txt: txt)
        }
        let malformed = [
            with { $0["hg"] = "XYZ" },
            with { $0["hg"] = "0123456789ABCDEF" },
            with { $0["hg"] = String(repeating: "a", count: 17) },
            with { $0["hn"] = nil },
            with { $0["hn"] = "   " },
            with { $0["sl"] = nil },
            with { $0["sl"] = String(repeating: "x", count: 33) },
        ]
        for spoof in malformed {
            let groups = NearbyMacDirectory.groups(from: [entry(alex, name: "Family MacBook — Alex", advertisement("Alex")), spoof])
            XCTAssertEqual(groups.count, 2, "\(spoof.txt)")
            XCTAssertEqual(groups.first { $0.title == "Spoof" }?.sessions.first?.sessionLabel, nil)
        }
        // A hint without an install id never groups.
        var noID = good
        noID["id"] = nil
        XCTAssertEqual(NearbyMacDirectory.groups(from: [.init(serviceName: "No ID", txt: noID)]).first?.title, "No ID")
    }

    func testAnUnknownSessionStateIsShownAsAvailable() {
        var txt = advertisement("Alex")!.txtFields
        txt["ss"] = "z"
        txt["id"] = alex
        XCTAssertEqual(NearbyMacDirectory.groups(from: [.init(serviceName: "x", txt: txt)]).first?.sessions.first?.availability,
                       .available)
    }

    /// Logging out withdraws that session's service; the rest of the Mac stays.
    func testASessionThatLogsOutLeavesTheOthers() {
        let before = NearbyMacDirectory.groups(from: [
            entry(alex, name: "Family MacBook — Alex", advertisement("Alex")),
            entry(mom, name: "Family MacBook — Mom", advertisement("Mom")),
        ])
        XCTAssertEqual(before.first?.sessions.count, 2)
        let after = NearbyMacDirectory.groups(from: [entry(mom, name: "Family MacBook — Mom", advertisement("Mom"))])
        XCTAssertEqual(after.first?.title, "Family MacBook — Mom")
    }

    // MARK: - Sender input gate

    func testTheConsoleStateOnlyReportsRealChanges() {
        let console = LoginSessionConsole(onConsole: true)
        XCTAssertTrue(console.isOnConsole)
        XCTAssertFalse(console.set(onConsole: true))
        XCTAssertTrue(console.set(onConsole: false))
        XCTAssertFalse(console.isOnConsole)
        XCTAssertTrue(console.set(onConsole: true))
    }

    func testThisTestRunnerIsOnTheConsoleOrHasNoGUISession() {
        // A Mac without Fast User Switching must keep injecting exactly as
        // before; the default reading must never be "switched out" here.
        XCTAssertTrue(LoginSessionConsole.windowServerReportsOnConsole())
    }
}
