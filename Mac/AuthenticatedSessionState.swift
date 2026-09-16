import Foundation

/// Thread-safe generation gate separating a transport-level connection from
/// a peer that has actually spoken the OpenDisplay application protocol.
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
