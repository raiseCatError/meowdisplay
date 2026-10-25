import Darwin
import Foundation

/// Which Mac receiver owns this Mac's receiver ports (TLS and QUIC 9001,
/// pairing 9002) and Bonjour services. MeowDisplay's "Use This Mac as a
/// Display" role and the standalone MeowDisplay Receiver both take it before
/// creating any listener, so whichever starts second never binds, advertises
/// or races for a connection: it waits, says why, and starts by itself once
/// the owner lets go.
///
/// A kernel `flock` on one file, not a process-name check: it holds across
/// launch order, Debug and Release builds and user accounts (the ports are
/// system-wide), and the kernel drops it if the owner quits or crashes, so a
/// stale owner can't block anyone.
final class ReceiverOwnershipLock {
    /// System-wide, so receivers in other user sessions see it too.
    static let sharedPath = "/Users/Shared/.meowdisplay-receiver.lock"

    private let paths: [String]
    private var descriptor: Int32 = -1

    /// `paths` are tried in order; the per-user fallback is used only if the
    /// shared one can't be opened.
    init(paths: [String] = ReceiverOwnershipLock.defaultPaths) {
        self.paths = paths
    }

    static var defaultPaths: [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let fallback = support?.appendingPathComponent("MeowDisplay/receiver.lock").path
        return [sharedPath] + [fallback].compactMap { $0 }
    }

    var isHeld: Bool { descriptor >= 0 }

    /// Takes ownership if nobody else has it. Idempotent while held.
    func tryAcquire() -> ReceiverOwnershipAttempt {
        if isHeld { return .acquired }
        for path in paths {
            let directory = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // Read-only is enough to lock, and works on a file another
            // account created.
            let fd = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return .acquired
            }
            let lockError = errno
            close(fd)
            if lockError == EWOULDBLOCK { return .heldByAnotherReceiver }
        }
        // No lock file could be opened at all: don't make this Mac unusable
        // as a display over a file-system problem. Listener binds still fail
        // cleanly (EADDRINUSE) if the ports are taken.
        return .unavailable
    }

    func release() {
        guard isHeld else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

enum ReceiverOwnershipAttempt: Equatable {
    case acquired
    case heldByAnotherReceiver
    /// The lock file couldn't be opened anywhere.
    case unavailable
}

/// Whether a Mac receiver may start now. Pure, so both launch orders are
/// testable without a second app.
enum ReceiverStartGate {
    enum Decision: Equatable {
        case start
        /// Another receiver owns the ports: show `ReceiverController`'s
        /// conflict message and try again shortly.
        case waitForOtherReceiver
    }

    /// `otherReceiverRunning`: a receiver that predates the lock (an
    /// already-released MeowDisplay Receiver) seen by its bundle id. It binds
    /// without asking, so starting next to it would only fail to bind.
    static func decide(otherReceiverRunning: Bool, attempt: () -> ReceiverOwnershipAttempt) -> Decision {
        if otherReceiverRunning { return .waitForOtherReceiver }
        switch attempt() {
        case .acquired, .unavailable: return .start
        case .heldByAnotherReceiver: return .waitForOtherReceiver
        }
    }

    /// How often a waiting receiver checks again.
    static let retryInterval: TimeInterval = 2
}
