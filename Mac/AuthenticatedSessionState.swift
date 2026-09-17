import Foundation

/// The final, pure authorization rule for a sender application handshake.
/// Keeping this separate from Keychain and Network.framework makes revocation
/// semantics directly testable.
enum SenderApplicationAuthorization {
    static func isAllowed(intendedPeerID: String?, authenticatedPeerID: String,
                          authenticatedSPKI: Data?, currentPinnedSPKI: Data?) -> Bool {
        guard let intendedPeerID,
              intendedPeerID == authenticatedPeerID,
              let authenticatedSPKI,
              let currentPinnedSPKI else { return false }
        return authenticatedSPKI == currentPinnedSPKI
    }
}

/// Thread-safe generation gate separating a transport-level connection from
/// a peer that has actually spoken the MeowDisplay application protocol.
final class AuthenticatedSessionState {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var applicationReady = false

    @discardableResult
    func beginTransport() -> UInt64 {
        lock.lock()
        generation &+= 1
        applicationReady = false
        let value = generation
        lock.unlock()
        return value
    }

    func markApplicationReady(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        applicationReady = true
        return true
    }

    @discardableResult
    func invalidate(generation expected: UInt64? = nil) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let expected, expected != generation { return generation }
        generation &+= 1
        applicationReady = false
        return generation
    }

    func isLive(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return applicationReady && generation == expected
    }

    var liveGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return applicationReady ? generation : nil
    }
}
