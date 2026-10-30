import Foundation

/// Bounds connections that haven't authenticated yet. A listener reachable by anyone on the
/// network (pairing, the Remote Access knock) takes a slot per connection until the peer has
/// proved something; when every slot is taken, newcomers are closed at once. Each slot is
/// also limited in time by `deadline`, so a silent connection can't keep one for long.
final class PreAuthSlots: @unchecked Sendable {
    /// How long a connection may take to say its first word.
    static let deadline: TimeInterval = 10
    static let pairing = PreAuthSlots(limit: 4)
    static let remoteKnock = PreAuthSlots(limit: 8)

    let limit: Int
    private let lock = NSLock()
    private var used = 0

    init(limit: Int) { self.limit = limit }

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard used < limit else { return false }
        used += 1
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        used = max(0, used - 1)
    }

    var inUse: Int {
        lock.lock(); defer { lock.unlock() }
        return used
    }
}

/// Releases a slot exactly once, whichever of handshake, failure or deadline comes first.
final class OneShotRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return action != nil
    }

    func release() {
        lock.lock()
        let run = action
        action = nil
        lock.unlock()
        run?()
    }
}
