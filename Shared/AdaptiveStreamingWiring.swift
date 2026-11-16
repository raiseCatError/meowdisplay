// Compiled into every app target and MacTests (see project.yml `sources`).
// Phase 2 of adaptive Automatic streaming (issue #123): the wire keys, the
// receiver-side telemetry window and hello state, path-to-cost mapping and
// the data-saving policy rule the Mac applies. Every wire key is optional on
// an existing message (`hello`, `stats`, `ping`): absent means today's
// behaviour. Documented in PROTOCOL.md 6.20.

import Foundation
#if canImport(Network)
import Network
#endif

// MARK: - Wire keys and parsing

enum AdaptiveStreamingWire {
    // `hello` (receiver → Mac)
    /// The receiver screen's current effective refresh in Hz (Low Power Mode
    /// can hold ProMotion at 60). Sent together with `telemetryKey`.
    static let effectiveRefreshKey = "effHz"
    /// The receiver will add the windowed telemetry keys to `stats` while the
    /// Mac announces adaptive mode.
    static let telemetryKey = "adaptiveTelemetry"
    /// Cost hint for the receiver's own media path: class and confidence and
    /// interface kind only. Never an SSID, address or carrier.
    static let costKey = "cost"
    static let costClassKey = "cost"
    static let costConfidenceKey = "conf"
    static let costInterfaceKey = "iface"
    /// "Use less data" preference: "off" / "on" / "auto".
    static let saveDataKey = "saveData"
    /// The remembered answer to the one-time suggestion: "saveData" or
    /// "keepQuality". Absent = not answered.
    static let saveDataAnswerKey = "saveDataAnswer"
    static let telemetryVersion = 1

    // `ping` (Mac → receiver)
    /// `1` while the Mac runs the adaptive controller for this session: the
    /// receiver then sends `stats` every 2 s instead of every 5 s.
    static let announceKey = "adaptive"

    // `stats` (receiver → Mac)
    static let windowKey = "win"
    static let deliveredFPSKey = "deliveredFps"
    static let decodedFPSKey = "decodedFps"
    static let enqueuedFPSKey = "enqFps"
    static let decodeP95Key = "dec95"
    static let presentationAgeKey = "presAge"
    static let lateKey = "late"
    static let jitterKey = "jit"
    static let thermalKey = "thermal"
    static let lowPowerKey = "lowPower"
    /// Existing `stats` key (round trip in ms), read as part of the telemetry.
    static let rttKey = "rtt"

    static let refreshRangeHz = 1...240
    static let windowRangeSeconds = 0.5...30.0
    static let fpsRange = 0.0...1000.0
    static let msRange = 0.0...60_000.0
    static let countRange = 0...100_000
    static let thermalRange = 0...3

    /// Highest `adaptiveTelemetry` version read as "telemetry" (a later
    /// version still means telemetry; an absurd one reads as absent).
    static let telemetryVersionRange = telemetryVersion...10_000
    /// Wire values are clamped to this before they are rounded and scaled.
    static let wireValueLimit = 1_000_000.0

    /// A finite JSON number that is not a JSON bool (`PeerNumber.double`).
    static func number(_ value: Any?) -> Double? {
        PeerNumber.double(value)
    }

    /// A JSON bool (never a number).
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        PeerNumber.double(value, in: range)
    }

    /// True only for `"adaptive": 1` on a Mac ping.
    static func isAnnounced(inPing object: [String: Any]) -> Bool {
        number(object[announceKey]) == 1
    }

    /// The ping suffix the Mac adds while it runs the controller.
    static func pingSuffix(announcing: Bool) -> String {
        announcing ? ",\"\(announceKey)\":1" : ""
    }

    /// Rounded to 0.1 after clamping (never infinity on the wire); nil for
    /// a non-finite value, which is then left out.
    fileprivate static func rounded(_ value: Double) -> Double? {
        PeerNumber.roundedTenths(value, limit: wireValueLimit)
    }
}

extension NetworkCost.Confidence {
    var wireName: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: return nil
        }
    }
}

/// The optional adaptive keys of a receiver `hello`.
struct AdaptiveHelloFields: Equatable, Sendable {
    var effectiveRefreshHz: Int?
    /// Only true together with `effectiveRefreshHz` (lead decision: the two
    /// travel together, so a telemetry peer always has a negotiable FPS ladder).
    var telemetry = false
    var cost: NetworkCost.EndpointReport?
    var saveData: NetworkCost.DataPreference?
    var saveDataAnswer: NetworkCost.MeteredAnswer?

    var wireFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let hz = effectiveRefreshHz {
            fields[AdaptiveStreamingWire.effectiveRefreshKey] = hz
            if telemetry { fields[AdaptiveStreamingWire.telemetryKey] = AdaptiveStreamingWire.telemetryVersion }
        }
        if let cost {
            fields[AdaptiveStreamingWire.costKey] = [
                AdaptiveStreamingWire.costClassKey: cost.cost.cost.rawValue,
                AdaptiveStreamingWire.costConfidenceKey: cost.cost.confidence.wireName,
                AdaptiveStreamingWire.costInterfaceKey: cost.interface.rawValue,
            ]
        }
        if let saveData { fields[AdaptiveStreamingWire.saveDataKey] = saveData.rawValue }
        if let answer = saveDataAnswer, answer != .unanswered {
            fields[AdaptiveStreamingWire.saveDataAnswerKey] = answer.rawValue
        }
        return fields
    }

    /// Garbage or out-of-range values read as absent (old behaviour).
    static func parse(_ object: [String: Any]) -> AdaptiveHelloFields {
        var fields = AdaptiveHelloFields()
        // Range-checked on the Double before any conversion (#123 F1).
        fields.effectiveRefreshHz = PeerNumber.int(object[AdaptiveStreamingWire.effectiveRefreshKey],
                                                   in: AdaptiveStreamingWire.refreshRangeHz)
        if fields.effectiveRefreshHz != nil,
           PeerNumber.int(object[AdaptiveStreamingWire.telemetryKey],
                          in: AdaptiveStreamingWire.telemetryVersionRange) != nil {
            fields.telemetry = true
        }
        if let dict = object[AdaptiveStreamingWire.costKey] as? [String: Any],
           let costRaw = dict[AdaptiveStreamingWire.costClassKey] as? String,
           let cost = NetworkCost.Cost(rawValue: costRaw),
           let confRaw = dict[AdaptiveStreamingWire.costConfidenceKey] as? String,
           let confidence = NetworkCost.Confidence(wireName: confRaw) {
            let interface = (dict[AdaptiveStreamingWire.costInterfaceKey] as? String)
                .flatMap(NetworkCost.Interface.init(rawValue:)) ?? .unknown
            fields.cost = NetworkCost.EndpointReport(
                reachability: .unknown, interface: interface,
                cost: NetworkCost.CostEvidence(cost: cost, confidence: confidence))
        }
        fields.saveData = (object[AdaptiveStreamingWire.saveDataKey] as? String)
            .flatMap(NetworkCost.DataPreference.init(rawValue:))
        fields.saveDataAnswer = (object[AdaptiveStreamingWire.saveDataAnswerKey] as? String)
            .flatMap(NetworkCost.MeteredAnswer.init(rawValue:))
            .flatMap { $0 == .unanswered ? nil : $0 }
        return fields
    }
}

/// When a receiver re-sends `hello` for an adaptive change (#123 A9): only
/// when something the Mac uses changed since the last hello that went out
/// (effective refresh, telemetry flag, cost class and confidence, "Use less
/// data" and its answer; the interface kind alone is informational), and at
/// most once per `minimumIntervalSeconds`. Checked on every ping tick, so
/// the latest state always goes out once the interval has passed. Pure.
struct AdaptiveHelloResendGate: Equatable, Sendable {
    static let minimumIntervalSeconds: TimeInterval = 5

    /// The part of the hello fields the Mac acts on.
    struct MacView: Equatable, Sendable {
        var effectiveRefreshHz: Int?
        var telemetry: Bool
        var cost: NetworkCost.CostEvidence?
        var saveData: NetworkCost.DataPreference?
        var saveDataAnswer: NetworkCost.MeteredAnswer?

        init(_ fields: AdaptiveHelloFields) {
            effectiveRefreshHz = fields.effectiveRefreshHz
            telemetry = fields.effectiveRefreshHz != nil && fields.telemetry
            cost = fields.cost?.cost
            saveData = fields.saveData
            saveDataAnswer = fields.saveDataAnswer == .unanswered ? nil : fields.saveDataAnswer
        }
    }

    private(set) var lastSent: MacView?
    private(set) var lastSentAt: TimeInterval?

    /// A hello went out (for any reason) carrying `fields`.
    mutating func noteSent(_ fields: AdaptiveHelloFields, now: TimeInterval) {
        lastSent = MacView(fields)
        lastSentAt = now
    }

    /// Whether to re-send now. Before the first hello of a session there is
    /// nothing to re-send: that hello carries the current values.
    func shouldResend(_ fields: AdaptiveHelloFields, now: TimeInterval) -> Bool {
        guard let lastSent, MacView(fields) != lastSent else { return false }
        guard let lastSentAt else { return true }
        return now - lastSentAt >= Self.minimumIntervalSeconds || now < lastSentAt
    }
}

/// The optional windowed keys of a receiver `stats` message.
struct AdaptiveReceiverTelemetry: Equatable, Sendable {
    var windowSeconds: Double
    /// Frames that reached the receiver's presentation hand-off.
    var deliveredFPS: Double?
    var decodedFPS: Double?
    var enqueuedFPS: Double?
    var decodeP95Ms: Double?
    var presentationAgeMs: Double?
    var lateDrops: Int?
    /// From the existing `rtt` key.
    var rttMs: Double?
    /// Mean absolute change between consecutive round trips in the window.
    var jitterMs: Double?
    var thermal: AdaptiveThermalLevel?
    var lowPower: Bool?

    /// The new keys only (`rtt` already rides on `stats`).
    var wireFields: [String: Any] {
        typealias W = AdaptiveStreamingWire
        var fields: [String: Any] = [:]
        if let window = W.rounded(windowSeconds) { fields[W.windowKey] = window }
        if let deliveredFPS, let v = W.rounded(deliveredFPS) { fields[W.deliveredFPSKey] = v }
        if let decodedFPS, let v = W.rounded(decodedFPS) { fields[W.decodedFPSKey] = v }
        if let enqueuedFPS, let v = W.rounded(enqueuedFPS) { fields[W.enqueuedFPSKey] = v }
        if let decodeP95Ms, let v = W.rounded(decodeP95Ms) { fields[W.decodeP95Key] = v }
        if let presentationAgeMs, let v = W.rounded(presentationAgeMs) { fields[W.presentationAgeKey] = v }
        if let lateDrops { fields[W.lateKey] = lateDrops }
        if let jitterMs, let v = W.rounded(jitterMs) { fields[W.jitterKey] = v }
        if let thermal { fields[W.thermalKey] = thermal.rawValue }
        if let lowPower { fields[W.lowPowerKey] = lowPower }
        return fields
    }

    /// nil when the window key is absent or invalid (an old receiver, or a
    /// stats message sent without the adaptive announce). Other invalid
    /// values read as absent.
    static func parse(_ object: [String: Any]) -> AdaptiveReceiverTelemetry? {
        typealias W = AdaptiveStreamingWire
        guard let window = W.number(object[W.windowKey], in: W.windowRangeSeconds) else { return nil }
        var t = AdaptiveReceiverTelemetry(windowSeconds: window)
        t.deliveredFPS = W.number(object[W.deliveredFPSKey], in: W.fpsRange)
        t.decodedFPS = W.number(object[W.decodedFPSKey], in: W.fpsRange)
        t.enqueuedFPS = W.number(object[W.enqueuedFPSKey], in: W.fpsRange)
        t.decodeP95Ms = W.number(object[W.decodeP95Key], in: W.msRange)
        t.presentationAgeMs = W.number(object[W.presentationAgeKey], in: W.msRange)
        // Range-checked on the Double before any conversion (#123 F1).
        t.lateDrops = PeerNumber.int(object[W.lateKey], in: W.countRange)
        t.rttMs = W.number(object[W.rttKey], in: W.msRange)
        t.jitterMs = W.number(object[W.jitterKey], in: W.msRange)
        t.thermal = PeerNumber.int(object[W.thermalKey], in: W.thermalRange).flatMap(AdaptiveThermalLevel.init(rawValue:))
        t.lowPower = W.bool(object[W.lowPowerKey])
        return t
    }
}

// MARK: - Receiver side

enum AdaptiveTelemetryCadence {
    /// Today's `stats` cadence: every 5 one-second FPS windows.
    static let legacyStatsWindows = 5
    /// While the Mac announces adaptive mode: every 2 windows (~2 s).
    static let adaptiveStatsWindows = 2
    /// An announce older than this no longer counts (the Mac pings every 2 s).
    static let announceStaleSeconds: TimeInterval = 6

    static func statsWindows(announced: Bool) -> Int {
        announced ? adaptiveStatsWindows : legacyStatsWindows
    }
}

/// Whether the Mac currently announces adaptive mode. Every Mac ping
/// carries the key or not; a missing ping for `announceStaleSeconds` ends it.
struct AdaptiveAnnounceTracker: Equatable, Sendable {
    private var announcedAt: TimeInterval?

    mutating func observePing(announced: Bool, now: TimeInterval) {
        announcedAt = announced ? now : nil
    }

    func isActive(now: TimeInterval) -> Bool {
        guard let announcedAt else { return false }
        return now - announcedAt < AdaptiveTelemetryCadence.announceStaleSeconds
    }

    mutating func reset() { announcedAt = nil }
}

/// The receiver's own counters for one `stats` window. Independent of the
/// diagnostics switch.
struct AdaptiveReceiverTelemetryWindow: Equatable, Sendable {
    private var start: TimeInterval?
    private var frames = 0
    private var lastRTT: Double?
    private var jitterSum = 0.0
    private var jitterSamples = 0

    mutating func noteFrame(now: TimeInterval) {
        if start == nil { start = now }
        frames += 1
    }

    mutating func noteRTT(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        if let lastRTT {
            jitterSum += abs(ms - lastRTT)
            jitterSamples += 1
        }
        lastRTT = ms
    }

    /// Ends the window. nil when it is too short to mean anything.
    mutating func drain(now: TimeInterval, decodeP95Ms: Double?, thermal: AdaptiveThermalLevel?,
                        lowPower: Bool?) -> AdaptiveReceiverTelemetry? {
        defer {
            start = now
            frames = 0
            jitterSum = 0
            jitterSamples = 0
        }
        guard let start else { return nil }
        let seconds = now - start
        guard AdaptiveStreamingWire.windowRangeSeconds.contains(seconds) else { return nil }
        var t = AdaptiveReceiverTelemetry(windowSeconds: seconds)
        t.deliveredFPS = Double(frames) / seconds
        t.decodeP95Ms = decodeP95Ms.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        t.jitterMs = jitterSamples > 0 ? jitterSum / Double(jitterSamples) : nil
        t.thermal = thermal
        t.lowPower = lowPower
        return t
    }

    mutating func reset() { self = AdaptiveReceiverTelemetryWindow() }
}

enum ReceiverEffectiveRefresh {
    /// Low Power Mode holds ProMotion screens at 60 Hz.
    static let lowPowerCapHz = 60

    /// The refresh the screen can actually show now. nil for a screen that
    /// reports nothing usable (the hello then carries no effective refresh).
    static func resolve(maximumFramesPerSecond: Int, lowPowerMode: Bool) -> Int? {
        guard maximumFramesPerSecond > 0 else { return nil }
        let effective = lowPowerMode ? min(maximumFramesPerSecond, lowPowerCapHz) : maximumFramesPerSecond
        return min(max(effective, AdaptiveStreamingWire.refreshRangeHz.lowerBound),
                   AdaptiveStreamingWire.refreshRangeHz.upperBound)
    }
}

extension AdaptiveThermalLevel {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

// MARK: - Path to cost evidence

extension NetworkCost {
    /// The facts an endpoint can read from its live media connection's path.
    struct PathFlags: Equatable, Sendable {
        var usesCellular = false
        var usesWiFi = false
        var usesWired = false
        var usesLoopback = false
        /// A VPN/tunnel interface (Tailscale is `utun`).
        var isTunnel = false
        var isExpensive = false
        var isConstrained = false
    }

    /// Interface names that are tunnels (their underlay is invisible here).
    static func isTunnelInterfaceName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
    }

    /// One endpoint's report from its own media connection's path.
    /// - The connection's own path is high confidence.
    /// - A tunnel is never cellular: its flags are kept as medium-confidence
    ///   evidence when set, and "not expensive" through a tunnel stays unknown.
    /// - USB/loopback is wired and unmetered.
    static func endpointReport(_ flags: PathFlags, reachability: Reachability) -> EndpointReport {
        func flagged(_ confidence: Confidence) -> CostEvidence? {
            if flags.isConstrained { return CostEvidence(cost: .constrained, confidence: confidence) }
            if flags.isExpensive { return CostEvidence(cost: .expensive, confidence: confidence) }
            return nil
        }
        if flags.usesLoopback {
            return EndpointReport(reachability: reachability, interface: .wired,
                                  cost: CostEvidence(cost: .unmetered, confidence: .high))
        }
        let interface: Interface
        if flags.usesCellular {
            interface = .cellular
        } else if flags.usesWiFi {
            interface = .wifi
        } else if flags.usesWired {
            interface = .wired
        } else if flags.isTunnel {
            interface = .tunnel
        } else {
            interface = .unknown
        }
        switch interface {
        case .cellular, .wifi, .wired:
            return EndpointReport(reachability: reachability, interface: interface,
                                  cost: flagged(.high) ?? CostEvidence(cost: .unmetered, confidence: .high))
        case .tunnel, .unknown:
            return EndpointReport(reachability: reachability, interface: interface, cost: flagged(.medium) ?? .unknown)
        }
    }

    /// The data policy the Mac applies for one receiver (lead decisions,
    /// phase 2): saver when the receiver's preference is On; in Automatic,
    /// saver on clear Low Data Mode (at either end), or on a clearly metered
    /// path once the user accepted the one-time suggestion. A clearly metered
    /// path that is not answered yet stays normal (the receiver asks). A
    /// receiver that sends no preference is an older receiver (or the Mac
    /// Receiver, which has no setting): normal, as today.
    ///
    /// "Use less data: Off" is full quality always, Low Data Mode included
    /// (a deliberate, reversible override). Answering "No" to the mobile-data
    /// suggestion (`keepQuality`) only means "don't save on mobile data": the
    /// preference stays Automatic, so Low Data Mode still saves.
    static func receiverDataPolicy(path: PathAssessment, preference: DataPreference?,
                                   answer: MeteredAnswer?) -> PolicyDecision {
        guard let preference else { return PolicyDecision(policy: .normal, reason: .notReported) }
        var answer = answer ?? .unanswered
        if preference == .auto, answer == .keepQuality, path.cost.cost == .constrained,
           path.cost.confidence >= clearEvidenceConfidence {
            // The mobile-data answer does not cover Low Data Mode.
            answer = .unanswered
        }
        let decision = dataPolicy(path: path, preference: preference, answer: answer)
        if preference == .auto, answer == .unanswered, decision.reason == .meteredPath {
            return PolicyDecision(policy: .normal, reason: .awaitingAnswer)
        }
        return decision
    }
}

extension NetworkCost {
    /// What the Mac's own path contributes to a receiver's data policy (lead
    /// decision, phase 2): only Low Data Mode set by the Mac's user
    /// (`constrained`) counts. A metered Mac path (`expensive`) alone never
    /// changes quality, so it is dropped to unknown here; unmetered and
    /// unknown pass through unchanged (they never select saver).
    static func macSidePolicyEvidence(_ report: EndpointReport) -> EndpointReport {
        guard report.cost.cost == .expensive else { return report }
        var filtered = report
        filtered.cost = .unknown
        return filtered
    }
}

#if canImport(Network)
extension NetworkCost.PathFlags {
    init(path: NWPath) {
        let names = path.availableInterfaces.map(\.name)
        self.init(usesCellular: path.usesInterfaceType(.cellular),
                  usesWiFi: path.usesInterfaceType(.wifi),
                  usesWired: path.usesInterfaceType(.wiredEthernet),
                  usesLoopback: path.usesInterfaceType(.loopback),
                  isTunnel: path.usesInterfaceType(.other) && names.contains(where: NetworkCost.isTunnelInterfaceName),
                  isExpensive: path.isExpensive,
                  isConstrained: path.isConstrained)
    }
}
#endif

// MARK: - "Use less data" settings (receiver)

/// Persisted "Use less data" choice and the suggestion's answer. Receiver
/// local; the Mac only sees the hello keys.
struct UseLessDataSettings: Equatable, Sendable {
    static let preferenceKey = "useLessData"
    static let answerKey = "useLessDataAnswer"
    static let dismissalsKey = "useLessDataDismissals"

    var preference: NetworkCost.DataPreference = .auto
    var answer: NetworkCost.MeteredAnswer = .unanswered
    var dismissals = 0

    static func load(_ defaults: UserDefaults = .standard) -> UseLessDataSettings {
        UseLessDataSettings(
            preference: defaults.string(forKey: preferenceKey).flatMap(NetworkCost.DataPreference.init(rawValue:)) ?? .auto,
            answer: defaults.string(forKey: answerKey).flatMap(NetworkCost.MeteredAnswer.init(rawValue:)) ?? .unanswered,
            dismissals: max(defaults.integer(forKey: dismissalsKey), 0))
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(preference.rawValue, forKey: Self.preferenceKey)
        defaults.set(answer.rawValue, forKey: Self.answerKey)
        defaults.set(dismissals, forKey: Self.dismissalsKey)
    }
}

/// What a receiver reports about "Use less data" in `hello` (#123). Pure:
/// the one place that decides which of the two keys go out.
enum UseLessDataReporting: Equatable, Sendable {
    /// A build without the setting (or before it was read): neither key.
    /// Absent means today's behaviour on the Mac (never data-saving).
    case none
    /// The Mac Receiver: `saveData` only. It has no mobile-data suggestion,
    /// so it never sends `saveDataAnswer`, and Automatic saves only on clear
    /// Low Data Mode (at either end).
    case preferenceOnly
    /// iOS: `saveData` and, once answered, `saveDataAnswer`.
    case preferenceAndAnswer

    func helloValues(_ settings: UseLessDataSettings)
        -> (saveData: NetworkCost.DataPreference?, answer: NetworkCost.MeteredAnswer?) {
        switch self {
        case .none:
            return (nil, nil)
        case .preferenceOnly:
            return (settings.preference, nil)
        case .preferenceAndAnswer:
            return (settings.preference, settings.answer == .unanswered ? nil : settings.answer)
        }
    }
}

/// The receiver's adaptive state for the live session: what its hello
/// reports, the telemetry window, the Mac's announce and the one-time
/// suggestion. Thread-safe; one per process (`shared`), since effective
/// refresh, path and preference describe this device, not one connection.
final class ReceiverAdaptiveState: @unchecked Sendable {
    static let shared = ReceiverAdaptiveState()
    /// Posted on the main queue when the one-time suggestion should show.
    static let suggestionNotification = Notification.Name("meowAdaptiveDataSuggestion")

    private let lock = NSLock()
    private var effectiveRefreshHz: Int?
    private var pathReport: NetworkCost.EndpointReport?
    private var settings = UseLessDataSettings()
    private var resendGate = AdaptiveHelloResendGate()
    private var announce = AdaptiveAnnounceTracker()
    private var window = AdaptiveReceiverTelemetryWindow()
    private var tracker = NetworkCostSuggestionTracker()
    private var lastFrameAt: TimeInterval?
    /// Only receivers with a prompt UI ask (iOS).
    private var suggestionsEnabled = false
    /// What hello carries about "Use less data": nothing until the app
    /// reports its setting (`setSettings`): iOS the preference and answer,
    /// the Mac Receiver the preference only.
    private var reporting = UseLessDataReporting.none

    init() {}

    // Hello inputs (re-sent on change)

    func setEffectiveRefresh(_ hz: Int?) {
        lock.lock(); defer { lock.unlock() }
        effectiveRefreshHz = hz
    }

    func setPath(_ report: NetworkCost.EndpointReport) {
        lock.lock(); defer { lock.unlock() }
        pathReport = report
    }

    func setSettings(_ newSettings: UseLessDataSettings, suggestionsEnabled: Bool? = nil,
                     reporting newReporting: UseLessDataReporting = .preferenceAndAnswer) {
        lock.lock(); defer { lock.unlock() }
        if let suggestionsEnabled { self.suggestionsEnabled = suggestionsEnabled }
        if newSettings.answer != tracker.answer { tracker.record(answer: newSettings.answer) }
        while tracker.dismissals < newSettings.dismissals { tracker.recordDismissal() }
        reporting = newReporting
        settings = newSettings
    }

    var currentSettings: UseLessDataSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    var helloFields: AdaptiveHelloFields {
        lock.lock(); defer { lock.unlock() }
        return currentFieldsLocked()
    }

    private func currentFieldsLocked() -> AdaptiveHelloFields {
        let useLessData = reporting.helloValues(settings)
        return AdaptiveHelloFields(
            effectiveRefreshHz: effectiveRefreshHz, telemetry: effectiveRefreshHz != nil,
            cost: pathReport, saveData: useLessData.saveData, saveDataAnswer: useLessData.answer)
    }

    /// True when the caller should re-send hello now
    /// (`AdaptiveHelloResendGate`): something the Mac uses changed since the
    /// last hello, and the last one is at least the minimum interval old.
    func consumeHelloResend(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return resendGate.shouldResend(currentFieldsLocked(), now: now)
    }

    /// Called when a hello goes out for any reason, with the fields it carries.
    func noteHelloSent(_ fields: AdaptiveHelloFields, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        resendGate.noteSent(fields, now: now)
    }

    // Mac announce and stats cadence

    func observeMacPing(_ object: [String: Any], now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        announce.observePing(announced: AdaptiveStreamingWire.isAnnounced(inPing: object), now: now)
    }

    func statsEveryWindows(now: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        return AdaptiveTelemetryCadence.statsWindows(announced: announce.isActive(now: now))
    }

    func noteFrame(now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        window.noteFrame(now: now)
        lastFrameAt = now
    }

    func noteRTT(_ ms: Double) {
        lock.lock(); defer { lock.unlock() }
        window.noteRTT(ms)
    }

    /// Ends the telemetry window on every `stats` report; the keys are
    /// returned only while the Mac announces adaptive mode, so `stats` to
    /// every other Mac stays exactly as before.
    func drainTelemetryFields(now: TimeInterval, decodeP95Ms: Double?) -> [String: Any] {
        let thermal = AdaptiveThermalLevel(ProcessInfo.processInfo.thermalState)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        lock.lock(); defer { lock.unlock() }
        let telemetry = window.drain(now: now, decodeP95Ms: decodeP95Ms, thermal: thermal, lowPower: lowPower)
        guard announce.isActive(now: now), let telemetry else { return [:] }
        return telemetry.wireFields
    }

    /// A new session: no announce, no window.
    func resetSession() {
        lock.lock(); defer { lock.unlock() }
        announce.reset()
        window.reset()
        lastFrameAt = nil
    }

    // One-time suggestion

    /// Evaluates the suggestion; true exactly once per episode.
    func checkSuggestion(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard suggestionsEnabled else { return false }
        let live = lastFrameAt.map { now - $0 < 5 } ?? false
        let path = NetworkCost.combine(sender: .unknown, receiver: pathReport ?? .unknown)
        if case .ask = tracker.observe(path: path, preference: settings.preference, liveMedia: live, now: now) {
            return true
        }
        return false
    }

    /// The suggestion's answer (remembered) or a dismissal. Returns the
    /// settings to persist.
    func recordSuggestion(answer: NetworkCost.MeteredAnswer?) -> UseLessDataSettings {
        lock.lock(); defer { lock.unlock() }
        if let answer {
            tracker.record(answer: answer)
            settings.answer = answer
        } else {
            tracker.recordDismissal()
            settings.dismissals = tracker.dismissals
        }
        return settings
    }
}

// MARK: - Diagnostics record

/// One controller decision as the diagnostics view and export show it:
/// enum codes and numbers only.
struct StreamDiagnosticsAdaptiveDecision: Codable, Equatable, Sendable {
    static let maxRecorded = 32

    /// Built from device uptime (`StreamDiagnosticsClock`), then re-based by the recorder
    /// when it stores the decision: as recorded, seconds since the recorder's last reset.
    var atSeconds: Double
    var action: AdaptiveStreamingDecision.Action
    var reason: AdaptiveStreamingDecision.Reason
    var cause: AdaptiveStreamingDecision.Cause
    var changed: [AdaptiveStreamingDecision.Dimension]
    var rasterScale: Double?
    var bitrateMbps: Double?
    var fps: Int?
    var evidence: AdaptiveStreamingEvidence

    init(_ decision: AdaptiveStreamingDecision, atMs: Double) {
        atSeconds = (atMs / 100).rounded() / 10
        action = decision.action
        reason = decision.reason
        cause = decision.cause
        changed = decision.changed
        rasterScale = decision.point?.rasterScale
        bitrateMbps = decision.point.map { Double($0.bitrate) / 1_000_000 }
        fps = decision.point?.fps
        evidence = decision.evidence
    }
}
