import Foundation
import Combine

/// How this device's last Remote Access knock at each paired Mac ended, kept in memory so the
/// iPhone/iPad Home row can say why a Connect over Remote didn't finish (Android keeps the same
/// fact as `RemoteAttempt`). Status only: it never decides whether to knock, retry or trust
/// anything, and nothing here is saved, logged or sent.
@MainActor
final class RemoteKnockOutcomes: ObservableObject {
    static let shared = RemoteKnockOutcomes()

    struct Outcome: Equatable, Sendable {
        var result: RemoteKnockResult
        var at: Date
    }

    @Published private(set) var latest: [String: Outcome] = [:]
    /// When each peer was last reset: a knock that ended before then belongs to an earlier attempt.
    private var resetAt: [String: Date] = [:]

    init() {}

    /// From any queue: the knock at `peerID` ended with `result` at `at`.
    nonisolated static func record(_ result: RemoteKnockResult, peerID: String, at: Date = Date()) {
        Task { @MainActor in shared.apply(result, peerID: peerID, at: at) }
    }

    /// Keeps the newest result per peer. A cancelled knock says nothing about the Mac, so it never
    /// replaces a result that does.
    func apply(_ result: RemoteKnockResult, peerID: String, at: Date) {
        guard result != .cancelled else { return }
        if let reset = resetAt[peerID], at < reset { return }
        if let current = latest[peerID], current.at > at { return }
        latest[peerID] = Outcome(result: result, at: at)
    }

    /// Forgets `peerID`'s result, before a new Connect, so the row never shows an older attempt's.
    func reset(peerID: String, at: Date = Date()) {
        resetAt[peerID] = at
        latest.removeValue(forKey: peerID)
    }

    func outcome(forPeerID peerID: String) -> Outcome? { latest[peerID] }
}
