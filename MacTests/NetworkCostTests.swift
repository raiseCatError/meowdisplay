import XCTest

final class NetworkCostTests: XCTestCase {
    private typealias Report = NetworkCost.EndpointReport
    private typealias Evidence = NetworkCost.CostEvidence

    private func report(_ cost: NetworkCost.Cost, _ confidence: NetworkCost.Confidence,
                        interface: NetworkCost.Interface = .unknown,
                        reachability: NetworkCost.Reachability = .local) -> Report {
        Report(reachability: reachability, interface: interface, cost: Evidence(cost: cost, confidence: confidence))
    }

    // MARK: - Combining sender and receiver evidence

    func testCombineTruthTable() {
        let all = NetworkCost.Cost.allCases.flatMap { cost in
            NetworkCost.Confidence.allCases.map { Evidence(cost: cost, confidence: $0) }
        }
        for sender in all {
            for receiver in all {
                let result = NetworkCost.combine(sender: report(sender.cost, sender.confidence),
                                                 receiver: report(receiver.cost, receiver.confidence)).cost
                let clear = [sender, receiver].filter { $0.confidence >= .medium }
                let clearMetered = clear.filter { $0.cost.isMetered }
                if !clearMetered.isEmpty {
                    // Either side clearly metered → metered, most restrictive wins.
                    XCTAssertTrue(result.cost.isMetered, "\(sender) + \(receiver)")
                    XCTAssertGreaterThanOrEqual(result.confidence, .medium)
                    let expected: NetworkCost.Cost = clearMetered.contains { $0.cost == .constrained }
                        ? .constrained : .expensive
                    XCTAssertEqual(result.cost, expected, "\(sender) + \(receiver)")
                } else if clear.count == 2, clear.allSatisfy({ $0.cost == .unmetered }) {
                    XCTAssertEqual(result.cost, .unmetered)
                    XCTAssertEqual(result.confidence, min(sender.confidence, receiver.confidence))
                } else {
                    // Never clear, never unmetered: unknown stays unknown, and
                    // weak metered hints stay low confidence.
                    XCTAssertNotEqual(result.cost, .unmetered, "\(sender) + \(receiver)")
                    XCTAssertEqual(result.confidence, .low, "\(sender) + \(receiver)")
                }
            }
        }
    }

    func testUnmeteredNeedsBothSides() {
        let macOnEthernet = report(.unmetered, .high, interface: .wired)
        XCTAssertEqual(NetworkCost.combine(sender: macOnEthernet, receiver: .unknown).cost.cost, .unknown)
        XCTAssertEqual(NetworkCost.combine(sender: macOnEthernet, receiver: report(.expensive, .high, interface: .cellular)).cost.cost,
                       .expensive)
        XCTAssertEqual(NetworkCost.combine(sender: macOnEthernet, receiver: report(.unmetered, .medium)).cost,
                       Evidence(cost: .unmetered, confidence: .medium))
    }

    func testTunnelIsNotCellularAndWiFiIsNotUnmetered() {
        // A Tailscale tunnel with no cost evidence is unknown, not cellular.
        let tunnel = report(.unknown, .low, interface: .tunnel, reachability: .remote)
        let combined = NetworkCost.combine(sender: tunnel, receiver: tunnel)
        XCTAssertEqual(combined.cost.cost, .unknown)
        XCTAssertEqual(combined.interface, .tunnel)
        XCTAssertEqual(combined.reachability, .remote)
        XCTAssertEqual(NetworkCost.dataPolicy(path: combined, preference: .auto, answer: .unanswered).policy, .normal)

        // A phone hotspot is Wi-Fi and expensive.
        let hotspot = report(.expensive, .high, interface: .wifi)
        let viaHotspot = NetworkCost.combine(sender: hotspot, receiver: report(.unmetered, .high, interface: .wifi))
        XCTAssertEqual(viaHotspot.cost.cost, .expensive)
        XCTAssertEqual(viaHotspot.interface, .wifi)
    }

    func testRemoteRouteSaysNothingAboutCost() {
        let remote = Report(route: .remote, cost: .unknown)
        XCTAssertEqual(remote.reachability, .remote)
        XCTAssertEqual(remote.interface, .unknown)
        XCTAssertEqual(remote.cost.cost, .unknown)
        XCTAssertEqual(Report(route: .usb, cost: .unknown).interface, .wired)
        XCTAssertEqual(Report(route: .awdl, cost: .unknown).interface, .wifi)
        XCTAssertEqual(Report(route: .lan, cost: .unknown).reachability, .local)
    }

    func testReachabilityCombination() {
        let local = report(.unknown, .low, reachability: .local)
        let remote = report(.unknown, .low, reachability: .remote)
        let unknown = report(.unknown, .low, reachability: .unknown)
        XCTAssertEqual(NetworkCost.combine(sender: local, receiver: local).reachability, .local)
        XCTAssertEqual(NetworkCost.combine(sender: local, receiver: remote).reachability, .remote)
        XCTAssertEqual(NetworkCost.combine(sender: local, receiver: unknown).reachability, .unknown)
    }

    // MARK: - Data policy

    private func path(_ cost: NetworkCost.Cost, _ confidence: NetworkCost.Confidence) -> NetworkCost.PathAssessment {
        NetworkCost.PathAssessment(reachability: .remote, interface: .unknown,
                                   cost: Evidence(cost: cost, confidence: confidence))
    }

    func testDataPolicyTable() {
        for cost in NetworkCost.Cost.allCases {
            for confidence in NetworkCost.Confidence.allCases {
                for answer in NetworkCost.MeteredAnswer.allCases {
                    let p = path(cost, confidence)
                    XCTAssertEqual(NetworkCost.dataPolicy(path: p, preference: .off, answer: answer),
                                   .init(policy: .normal, reason: .preferenceOff))
                    XCTAssertEqual(NetworkCost.dataPolicy(path: p, preference: .on, answer: answer),
                                   .init(policy: .saver, reason: .preferenceOn))
                    let auto = NetworkCost.dataPolicy(path: p, preference: .auto, answer: answer)
                    if answer == .keepQuality {
                        XCTAssertEqual(auto, .init(policy: .normal, reason: .higherQualityOverride))
                    } else if confidence >= .medium && cost == .constrained {
                        XCTAssertEqual(auto, .init(policy: .saver, reason: .lowDataMode))
                    } else if confidence >= .medium && cost == .expensive {
                        XCTAssertEqual(auto, .init(policy: .saver, reason: .meteredPath))
                    } else {
                        XCTAssertEqual(auto, .init(policy: .normal, reason: .notClearlyMetered))
                    }
                }
            }
        }
    }

    func testPolicyNeverRefusesToStream() {
        XCTAssertEqual(NetworkCost.DataPolicy.allCases, [.normal, .saver])
    }

    func testPreferenceCombination() {
        XCTAssertEqual(NetworkCost.DataPreference.combined(sender: .on, receiver: .off), .on)
        XCTAssertEqual(NetworkCost.DataPreference.combined(sender: .off, receiver: .auto), .auto)
        XCTAssertEqual(NetworkCost.DataPreference.combined(sender: .off, receiver: .off), .off)
        XCTAssertEqual(NetworkCost.DataPreference.combined(sender: .auto, receiver: .on), .on)
    }

    // MARK: - One-time suggestion

    private let metered = NetworkCost.PathAssessment(reachability: .remote, interface: .cellular,
                                                     cost: .init(cost: .expensive, confidence: .high))
    private let wifi = NetworkCost.PathAssessment(reachability: .local, interface: .wifi,
                                                  cost: .init(cost: .unmetered, confidence: .high))

    func testAsksOncePerEpisode() {
        var tracker = NetworkCostSuggestionTracker()
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 0), .ask(episode: 1))
        for second in stride(from: 5.0, through: 100, by: 5) {
            XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: second),
                           .none(.alreadyAskedThisEpisode))
        }
    }

    func testNeverAsksOnUnknownOrWeakEvidence() {
        var tracker = NetworkCostSuggestionTracker()
        let cases: [NetworkCost.PathAssessment] = [
            .init(reachability: .remote, interface: .tunnel, cost: .unknown),
            .init(reachability: .remote, interface: .cellular, cost: .init(cost: .expensive, confidence: .low)),
            .init(reachability: .remote, interface: .cellular, cost: .init(cost: .expensive, confidence: .medium)),
            .init(reachability: .remote, interface: .wifi, cost: .init(cost: .unmetered, confidence: .high)),
            // Low Data Mode is honoured silently, not asked about.
            .init(reachability: .remote, interface: .cellular, cost: .init(cost: .constrained, confidence: .high)),
        ]
        for (index, path) in cases.enumerated() {
            XCTAssertEqual(tracker.observe(path: path, preference: .auto, liveMedia: true, now: Double(index)),
                           .none(.noClearMeteredEvidence))
        }
    }

    func testNeverAsksWithoutLiveMediaOrWithAnExplicitPreference() {
        var tracker = NetworkCostSuggestionTracker()
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: false, now: 0), .none(.notLive))
        XCTAssertEqual(tracker.observe(path: metered, preference: .on, liveMedia: true, now: 1), .none(.preferenceNotAuto))
        XCTAssertEqual(tracker.observe(path: metered, preference: .off, liveMedia: true, now: 2), .none(.preferenceNotAuto))
        // Still the first time the user could actually answer it.
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 3), .ask(episode: 1))
    }

    func testRemembersTheAnswer() throws {
        for answer in [NetworkCost.MeteredAnswer.saveData, .keepQuality] {
            var tracker = NetworkCostSuggestionTracker()
            XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 0), .ask(episode: 1))
            tracker.record(answer: answer)
            // A new episode much later still doesn't ask.
            _ = tracker.observe(path: wifi, preference: .auto, liveMedia: true, now: 10)
            XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 1000), .none(.answered))
            // The answer survives persistence.
            let data = try JSONEncoder().encode(tracker)
            let restored = try JSONDecoder().decode(NetworkCostSuggestionTracker.self, from: data)
            XCTAssertEqual(restored.answer, answer)
        }
    }

    func testFlapInsideGraceIsTheSameEpisode() {
        var tracker = NetworkCostSuggestionTracker()
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 0), .ask(episode: 1))
        tracker.recordDismissal()
        XCTAssertEqual(tracker.observe(path: wifi, preference: .auto, liveMedia: true, now: 30),
                       .none(.noClearMeteredEvidence))
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 60),
                       .none(.alreadyAskedThisEpisode))
    }

    func testNewEpisodeAfterGraceAndDismissalLimit() {
        var tracker = NetworkCostSuggestionTracker()
        let grace = NetworkCostSuggestionTracker.episodeEndGraceSeconds
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 0), .ask(episode: 1))
        tracker.recordDismissal()
        _ = tracker.observe(path: wifi, preference: .auto, liveMedia: true, now: grace + 1)
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: grace + 2), .ask(episode: 2))
        tracker.recordDismissal()
        _ = tracker.observe(path: wifi, preference: .auto, liveMedia: true, now: 3 * grace)
        XCTAssertEqual(tracker.observe(path: metered, preference: .auto, liveMedia: true, now: 3 * grace + 1),
                       .none(.dismissedTooOften))
    }
}
