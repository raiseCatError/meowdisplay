import Foundation
import Network

/// Which of the sender's Bonjour browsers a state change belongs to.
enum DiscoveryBrowserRole: String, Sendable {
    /// The `_opensidecar._tcp` receiver browser.
    case receivers
    /// The QUIC reachability-hint browser.
    case quicHints
}

/// A Network-free summary of `NWBrowser.State`, so the dedupe and formatting logic
/// is testable without Network objects.
struct DiscoveryBrowserStateSummary: Equatable, Sendable {
    enum Phase: String, Sendable {
        case setup, ready, waiting, failed, cancelled
        /// A state this build predates; logged rather than guessed at.
        case unknown
    }

    enum ErrorKind: String, Sendable {
        case posix, dns, tls
        /// Any other `NWError` kind.
        case other
    }

    struct Failure: Equatable, Sendable {
        let kind: ErrorKind
        let code: Int
    }

    /// `kDNSServiceErr_PolicyDenied`: what a Local Network privacy block looks like to a browser.
    static let policyDeniedCode = -65570

    let phase: Phase
    let failure: Failure?

    init(phase: Phase, failure: Failure? = nil) {
        self.phase = phase
        self.failure = failure
    }

    init(_ state: NWBrowser.State) {
        switch state {
        case .setup: self.init(phase: .setup)
        case .ready: self.init(phase: .ready)
        case .cancelled: self.init(phase: .cancelled)
        case .waiting(let error): self.init(phase: .waiting, failure: Self.failure(of: error))
        case .failed(let error): self.init(phase: .failed, failure: Self.failure(of: error))
        @unknown default: self.init(phase: .unknown)
        }
    }

    /// Keeps only the error's kind and numeric code: the associated values can carry
    /// more than the privacy rule allows in a log.
    private static func failure(of error: NWError) -> Failure {
        switch error {
        case .posix(let code): Failure(kind: .posix, code: Int(code.rawValue))
        case .dns(let code): Failure(kind: .dns, code: Int(code))
        case .tls(let status): Failure(kind: .tls, code: Int(status))
        // Newer kinds (e.g. `.wifiAware` on recent SDKs) keep no code: only these three are documented here.
        default: Failure(kind: .other, code: 0)
        }
    }

    var isPolicyDenied: Bool {
        failure?.kind == .dns && failure?.code == Self.policyDeniedCode
    }
}

/// Turns browser state changes into log lines, one per distinct change per browser.
///
/// A browser stuck in `.waiting` or dead in `.failed` otherwise leaves no trace. The
/// lines carry only the role, state and error kind/code, never service or device
/// names, TXT contents, endpoints, addresses or install ids. Not thread-safe: keep it
/// on the queue the browsers run on.
struct DiscoveryBrowserStateLog: Sendable {
    private var lastSeen: [DiscoveryBrowserRole: DiscoveryBrowserStateSummary] = [:]

    /// The line to write for `state`, or nil when it equals the last state (error code
    /// included) seen for `role`.
    mutating func line(for state: DiscoveryBrowserStateSummary, role: DiscoveryBrowserRole) -> String? {
        guard lastSeen[role] != state else { return nil }
        lastSeen[role] = state
        var line = "discovery: browser=\(role.rawValue) state=\(state.phase.rawValue)"
        if let failure = state.failure {
            line += " error=\(failure.kind.rawValue):\(failure.code)"
        }
        if state.isPolicyDenied {
            line += " policyDenied"
        }
        return line
    }
}
