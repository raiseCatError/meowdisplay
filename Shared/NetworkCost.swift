// Compiled into every app target and MacTests (see project.yml `sources`).
// Pure, Foundation-only network-cost model for the adaptive Automatic
// streaming controller (issue #123, 2026-11-14 research addendum,
// "Network-cost/path model: independent dimensions, not remote = cellular").

import Foundation

/// Four independent descriptions of the live media path. None of them
/// implies another:
/// - reachability (local or remote) is topology, not billing;
/// - the interface is what each endpoint can see, and a tunnel hides its
///   underlay (Tailscale can ride over cellular or over unmetered Wi-Fi);
/// - cost is what the platform says about metering, each with a confidence;
///   Wi-Fi is not proof of unmetered (a phone hotspot is Wi-Fi), and a
///   tunnel is not proof of cellular;
/// - live performance is measured by `AdaptiveStreamingController`, never
///   inferred from the other three.
///
/// The output is a data policy (normal or saver). There is deliberately no
/// "refuse to stream" outcome: data saving lowers the operating point, it
/// never denies an explicitly started stream.
enum NetworkCost {
    enum Reachability: String, Sendable, Codable, CaseIterable {
        /// LAN, AWDL or USB.
        case local
        /// VPN/Tailscale or the internet.
        case remote
        case unknown
    }

    enum Interface: String, Sendable, Codable, CaseIterable {
        case wifi
        case wired
        case cellular
        /// A VPN/tunnel whose underlay this endpoint cannot see.
        case tunnel
        case unknown
    }

    enum Cost: String, Sendable, Codable, CaseIterable {
        case unmetered
        /// Metered: cellular or a hotspot (`NWPath.isExpensive`,
        /// Android without `NET_CAPABILITY_NOT_METERED`).
        case expensive
        /// Low Data Mode / Data Saver (`NWPath.isConstrained`): the user
        /// already asked the OS to save data.
        case constrained
        case unknown

        /// How strongly the cost asks for data saving.
        fileprivate var restrictiveness: Int {
            switch self {
            case .unknown: return 0
            case .unmetered: return 1
            case .expensive: return 2
            case .constrained: return 3
            }
        }

        var isMetered: Bool { self == .expensive || self == .constrained }
    }

    /// How much an endpoint's cost evidence can be trusted.
    /// - high: the actual media connection's own path
    ///   (`NWConnection.currentPath`, the Android `Network` the socket is
    ///   bound to).
    /// - medium: the process-wide default path (`NWPathMonitor`,
    ///   `ConnectivityManager.activeNetwork`) while the media path is not
    ///   tunnelled.
    /// - low: inference (a tunnel interface, an interface name, a route
    ///   class). Never enough to change policy or to ask the user.
    enum Confidence: Int, Sendable, Codable, CaseIterable, Comparable {
        case low
        case medium
        case high

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct CostEvidence: Equatable, Sendable, Codable {
        var cost: Cost
        var confidence: Confidence

        static let unknown = CostEvidence(cost: .unknown, confidence: .low)
    }

    /// One endpoint's view of the established media path.
    struct EndpointReport: Equatable, Sendable, Codable {
        var reachability: Reachability
        var interface: Interface
        var cost: CostEvidence

        static let unknown = EndpointReport(reachability: .unknown, interface: .unknown, cost: .unknown)

        init(reachability: Reachability, interface: Interface, cost: CostEvidence) {
            self.reachability = reachability
            self.interface = interface
            self.cost = cost
        }

        /// Maps the Mac's existing route classification. The route says
        /// nothing about cost, so cost stays as given.
        init(route: ConnectionRoute, cost: CostEvidence) {
            switch route {
            case .usb:
                self.init(reachability: .local, interface: .wired, cost: cost)
            case .awdl:
                self.init(reachability: .local, interface: .wifi, cost: cost)
            case .lan:
                self.init(reachability: .local, interface: .unknown, cost: cost)
            case .remote:
                self.init(reachability: .remote, interface: .unknown, cost: cost)
            }
        }
    }

    /// Both endpoints' evidence, combined.
    struct PathAssessment: Equatable, Sendable {
        var reachability: Reachability
        /// The more informative of the two interfaces (cellular over Wi-Fi
        /// over wired over tunnel over unknown). Diagnostic only: policy
        /// never reads it.
        var interface: Interface
        var cost: CostEvidence
    }

    /// Cost evidence that is at least this confident is "clear".
    static let clearEvidenceConfidence: Confidence = .medium

    /// Combines sender-side and receiver-side evidence conservatively:
    /// - either side CLEARLY metered (expensive/constrained at medium
    ///   confidence or more) makes the path metered, the most restrictive
    ///   clear report winning;
    /// - unmetered needs BOTH sides to say so clearly (the receiver on
    ///   cellular pays even when the Mac is on Ethernet);
    /// - anything else stays unknown. Low-confidence metered hints are kept
    ///   as low-confidence evidence (visible in diagnostics) but never count
    ///   as clear.
    static func combine(sender: EndpointReport, receiver: EndpointReport) -> PathAssessment {
        let reachability: Reachability
        if sender.reachability == .remote || receiver.reachability == .remote {
            reachability = .remote
        } else if sender.reachability == .local && receiver.reachability == .local {
            reachability = .local
        } else {
            reachability = .unknown
        }

        let clear = [sender.cost, receiver.cost].filter { $0.confidence >= clearEvidenceConfidence }
        let cost: CostEvidence
        if let metered = clear.filter({ $0.cost.isMetered }).max(by: { lhs, rhs in
            (lhs.cost.restrictiveness, lhs.confidence) < (rhs.cost.restrictiveness, rhs.confidence)
        }) {
            cost = metered
        } else if clear.count == 2, clear.allSatisfy({ $0.cost == .unmetered }) {
            cost = CostEvidence(cost: .unmetered, confidence: min(clear[0].confidence, clear[1].confidence))
        } else if let hint = [sender.cost, receiver.cost].filter({ $0.cost.isMetered }).max(by: {
            $0.cost.restrictiveness < $1.cost.restrictiveness
        }) {
            cost = CostEvidence(cost: hint.cost, confidence: .low)
        } else {
            cost = .unknown
        }

        return PathAssessment(reachability: reachability,
                              interface: moreInformative(sender.interface, receiver.interface),
                              cost: cost)
    }

    private static func moreInformative(_ lhs: Interface, _ rhs: Interface) -> Interface {
        let order: [Interface] = [.cellular, .wifi, .wired, .tunnel, .unknown]
        let li = order.firstIndex(of: lhs) ?? order.count
        let ri = order.firstIndex(of: rhs) ?? order.count
        return li <= ri ? lhs : rhs
    }

    // MARK: - Data policy

    /// The "Use less data" preference.
    enum DataPreference: String, Sendable, Codable, CaseIterable {
        /// Never save data automatically.
        case off
        /// Always save data.
        case on
        /// Save data when the path is clearly metered (the default).
        case auto

        /// Both endpoints' preferences: the more data-saving one wins
        /// (on > auto > off), so a Mac on a paid hotspot can ask for saving
        /// even when the receiver does not.
        static func combined(sender: DataPreference, receiver: DataPreference) -> DataPreference {
            if sender == .on || receiver == .on { return .on }
            if sender == .auto || receiver == .auto { return .auto }
            return .off
        }
    }

    /// The remembered answer to the one-time metered suggestion. `keepQuality`
    /// is also the deliberate higher-quality override in Settings: it is
    /// stored, predictable and reversible (set it back to `unanswered` or
    /// `saveData`).
    enum MeteredAnswer: String, Sendable, Codable, CaseIterable {
        case unanswered
        case saveData
        case keepQuality
    }

    enum DataPolicy: String, Sendable, Codable, CaseIterable {
        case normal
        case saver
    }

    enum PolicyReason: String, Sendable, Codable, CaseIterable {
        case preferenceOff
        case preferenceOn
        case higherQualityOverride
        case lowDataMode
        case meteredPath
        case notClearlyMetered
    }

    struct PolicyDecision: Equatable, Sendable {
        let policy: DataPolicy
        let reason: PolicyReason
    }

    /// Precedence: an explicit Settings choice (off/on) first, then the
    /// remembered higher-quality override, then clear metered evidence.
    /// Unknown or low-confidence cost never selects saver on its own.
    static func dataPolicy(path: PathAssessment, preference: DataPreference,
                           answer: MeteredAnswer) -> PolicyDecision {
        switch preference {
        case .off: return PolicyDecision(policy: .normal, reason: .preferenceOff)
        case .on: return PolicyDecision(policy: .saver, reason: .preferenceOn)
        case .auto: break
        }
        if answer == .keepQuality { return PolicyDecision(policy: .normal, reason: .higherQualityOverride) }
        guard path.cost.confidence >= clearEvidenceConfidence else {
            return PolicyDecision(policy: .normal, reason: .notClearlyMetered)
        }
        switch path.cost.cost {
        case .constrained: return PolicyDecision(policy: .saver, reason: .lowDataMode)
        case .expensive: return PolicyDecision(policy: .saver, reason: .meteredPath)
        case .unmetered, .unknown: return PolicyDecision(policy: .normal, reason: .notClearlyMetered)
        }
    }
}

// MARK: - One-time metered suggestion

/// Decides when to show "This connection may use mobile data. Save data
/// automatically?". Asks at most once per reliable detection episode,
/// never on unknown or low-confidence evidence, never once answered, and
/// never again after `maxDismissals` dismissals without an answer.
///
/// An episode starts when clear `expensive` evidence appears on a live media
/// path and ends only after that evidence has been absent for
/// `episodeEndGraceSeconds`, so a Wi-Fi/cellular flap or a reconnect inside
/// the grace period is the same episode and is never asked twice.
/// Low Data Mode (`constrained`) is not asked about: the user already told
/// the OS, and the data policy honours it silently.
///
/// Value type with an injected clock: the owner persists `answer` and
/// `dismissals` (Codable) and keeps the rest in memory.
struct NetworkCostSuggestionTracker: Equatable, Sendable, Codable {
    static let suggestionConfidence: NetworkCost.Confidence = .high
    static let episodeEndGraceSeconds: TimeInterval = 120
    static let maxDismissals = 2

    enum Decision: Equatable, Sendable {
        case ask(episode: UInt64)
        case none(Reason)
    }

    enum Reason: String, Equatable, Sendable, Codable {
        case answered
        case preferenceNotAuto
        case notLive
        case noClearMeteredEvidence
        case alreadyAskedThisEpisode
        case dismissedTooOften
    }

    private(set) var answer: NetworkCost.MeteredAnswer = .unanswered
    private(set) var dismissals = 0
    private(set) var episode: UInt64 = 0
    private var inEpisode = false
    private var lastEvidenceAt: TimeInterval?
    private var askedEpisode: UInt64?

    init(answer: NetworkCost.MeteredAnswer = .unanswered, dismissals: Int = 0) {
        self.answer = answer
        self.dismissals = dismissals
    }

    /// Call on every path or preference change and periodically while
    /// streaming. Returns `.ask` exactly once per episode; the caller shows
    /// the prompt and then reports `record(answer:)` or `recordDismissal()`.
    mutating func observe(path: NetworkCost.PathAssessment, preference: NetworkCost.DataPreference,
                          liveMedia: Bool, now: TimeInterval) -> Decision {
        let clearMetered = liveMedia && path.cost.cost == .expensive
            && path.cost.confidence >= Self.suggestionConfidence
        if clearMetered {
            if !inEpisode {
                inEpisode = true
                episode &+= 1
            }
            lastEvidenceAt = now
        } else if inEpisode, let last = lastEvidenceAt, now - last >= Self.episodeEndGraceSeconds {
            inEpisode = false
        }

        if answer != .unanswered { return .none(.answered) }
        if preference != .auto { return .none(.preferenceNotAuto) }
        if !liveMedia { return .none(.notLive) }
        guard clearMetered else { return .none(.noClearMeteredEvidence) }
        if dismissals >= Self.maxDismissals { return .none(.dismissedTooOften) }
        if askedEpisode == episode { return .none(.alreadyAskedThisEpisode) }
        askedEpisode = episode
        return .ask(episode: episode)
    }

    /// The user's answer, or a later change in Settings. Remembered.
    mutating func record(answer: NetworkCost.MeteredAnswer) {
        self.answer = answer
    }

    mutating func recordDismissal() {
        dismissals += 1
    }
}
