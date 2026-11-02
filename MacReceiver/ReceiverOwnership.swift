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
/// launch order and Debug and Release builds, and the kernel drops it if the
/// owner quits or crashes, so a stale owner can't block anyone. The file is
/// never unlinked: a waiting receiver must keep locking the same file the
/// owner holds.
///
/// The file is `~/Library/Application Support/MeowDisplay/receiver.lock`,
/// reached one component at a time from the home directory without
/// following a symlink, and every directory on the way must belong to this
/// user and be writable by nobody else, so no other account can swap a
/// component, plant a link, or hold the lock to keep this Mac from being a
/// display. If anything there is unexpected the receiver doesn't start
/// (`ReceiverLockProblem` says what to fix) rather than run unowned.
///
/// Per user: receivers in two different login sessions don't see each
/// other's lock. The ports are system-wide, so there the listener bind is
/// the final word: the second one's bind fails ("address in use") and
/// `ReceiverController` says the port is taken.
final class ReceiverOwnershipLock {
    private let root: String
    private let directories: [String]
    private let fileName: String
    private var descriptor: Int32 = -1

    /// `directories` are created under `root` as needed; `root` itself is
    /// trusted to be this user's (the home directory in production).
    init(root: String = ReceiverOwnershipLock.homeDirectory,
         directories: [String] = ["Library", "Application Support", "MeowDisplay"],
         fileName: String = "receiver.lock") {
        self.root = root
        self.directories = directories
        self.fileName = fileName
    }

    /// From the account database, not `$HOME`.
    static var homeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    var path: String {
        ([root] + directories + [fileName]).joined(separator: "/")
    }

    var isHeld: Bool { descriptor >= 0 }

    /// Takes ownership if nobody else has it. Idempotent while held.
    func tryAcquire() -> ReceiverOwnershipAttempt {
        if isHeld { return .acquired }
        let fd: Int32
        switch openLockFile() {
        case .success(let opened): fd = opened
        case .failure(let problem):
            Log.info("receiver ownership lock unusable: \(problem.path): \(problem.reason)")
            return .unusable(problem)
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            return .acquired
        }
        let lockError = errno
        close(fd)
        if lockError == EWOULDBLOCK { return .heldByAnotherReceiver }
        return .unusable(ReceiverLockProblem(path: path, reason: .system(lockError)))
    }

    /// Unlocks and closes. The file stays: unlinking it would let the next
    /// receiver lock a new file while a waiting one still holds the old.
    func release() {
        guard isHeld else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }

    // MARK: - Opening the file safely

    private func openLockFile() -> Result<Int32, ReceiverLockProblem> {
        var current = root
        var directory = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return .failure(problem(at: current, errno: errno)) }
        defer { close(directory) }
        if let reason = Self.validateDirectory(directory) {
            return .failure(ReceiverLockProblem(path: current, reason: reason))
        }
        for name in directories {
            current += "/" + name
            if mkdirat(directory, name, 0o700) != 0, errno != EEXIST {
                return .failure(problem(at: current, errno: errno))
            }
            // Never through a symlink: each step is relative to the
            // directory already checked.
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let error = errno
                // Only to name the problem: a symlinked folder fails with
                // ENOTDIR here, not ELOOP.
                var info = stat()
                if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK {
                    return .failure(ReceiverLockProblem(path: current, reason: .symbolicLink))
                }
                return .failure(problem(at: current, errno: error))
            }
            close(directory)
            directory = next
            if let reason = Self.validateDirectory(directory) {
                return .failure(ReceiverLockProblem(path: current, reason: reason))
            }
        }
        current += "/" + fileName
        // O_NONBLOCK: a FIFO planted here must not hang the app on open.
        let fd = openat(directory, fileName, O_RDONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(problem(at: current, errno: errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno
            close(fd)
            return .failure(ReceiverLockProblem(path: current, reason: .system(error)))
        }
        if let reason = Self.validateFile(info) {
            close(fd)
            return .failure(ReceiverLockProblem(path: current, reason: reason))
        }
        // An older build's file may be 0644; it's ours, so tighten it.
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        return .success(fd)
    }

    private func problem(at path: String, errno code: Int32) -> ReceiverLockProblem {
        switch code {
        case ELOOP: ReceiverLockProblem(path: path, reason: .symbolicLink)
        case ENOTDIR: ReceiverLockProblem(path: path, reason: .notADirectory)
        case EACCES, EPERM, EROFS: ReceiverLockProblem(path: path, reason: .permissionDenied)
        default: ReceiverLockProblem(path: path, reason: .system(code))
        }
    }

    private static func validateDirectory(_ fd: Int32) -> ReceiverLockProblem.Reason? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .system(errno) }
        return validateDirectory(info)
    }

    /// A directory this user owns that nobody else can write to.
    static func validateDirectory(_ info: stat, uid: uid_t = getuid()) -> ReceiverLockProblem.Reason? {
        guard info.st_mode & S_IFMT == S_IFDIR else { return .notADirectory }
        guard info.st_uid == uid else { return .ownedByAnotherUser }
        guard info.st_mode & 0o022 == 0 else { return .writableByOthers }
        return nil
    }

    /// A plain file this user owns, with no other name (a hard link could
    /// point it at a file elsewhere).
    static func validateFile(_ info: stat, uid: uid_t = getuid()) -> ReceiverLockProblem.Reason? {
        guard info.st_mode & S_IFMT == S_IFREG else { return .notARegularFile }
        guard info.st_uid == uid else { return .ownedByAnotherUser }
        guard info.st_nlink == 1 else { return .hardLinked }
        return nil
    }
}

enum ReceiverOwnershipAttempt: Equatable {
    case acquired
    case heldByAnotherReceiver
    /// The lock file can't be used safely; nothing was locked.
    case unusable(ReceiverLockProblem)
}

/// Why the ownership lock couldn't be used, and where.
struct ReceiverLockProblem: Error, Equatable {
    enum Reason: Equatable {
        case symbolicLink
        case notADirectory
        case notARegularFile
        case ownedByAnotherUser
        case writableByOthers
        case hardLinked
        case permissionDenied
        case system(Int32)
    }

    let path: String
    let reason: Reason

    /// What the user sees: what's wrong, where, and what to do.
    var message: String {
        let what: String = switch reason {
        case .symbolicLink: String(localized: "is a symbolic link")
        case .notADirectory: String(localized: "is not a folder")
        case .notARegularFile: String(localized: "is not a regular file")
        case .ownedByAnotherUser: String(localized: "belongs to another user")
        case .writableByOthers: String(localized: "can be changed by other users")
        case .hardLinked: String(localized: "has more than one name (a hard link)")
        case .permissionDenied: String(localized: "can't be opened (permission denied)")
        case .system(let code): String(cString: strerror(code))
        }
        return String(localized: "This Mac can't be a display: \(path) \(what). MeowDisplay uses it to make sure only one receiver runs at a time. Remove or fix it, then click Try Again.")
    }
}

/// Whether a Mac receiver may start now. Pure, so both launch orders are
/// testable without a second app.
enum ReceiverStartGate {
    enum Decision: Equatable {
        case start
        /// Another receiver owns the ports: show `ReceiverController`'s
        /// conflict message and try again shortly.
        case waitForOtherReceiver
        /// Ownership can't be established safely: don't start, don't retry
        /// by itself, say what to fix.
        case cannotStart(ReceiverLockProblem)
    }

    /// `otherReceiverRunning`: a receiver that predates the lock (an
    /// already-released MeowDisplay Receiver) seen by its bundle id. It binds
    /// without asking, so starting next to it would only fail to bind.
    static func decide(otherReceiverRunning: Bool, attempt: () -> ReceiverOwnershipAttempt) -> Decision {
        if otherReceiverRunning { return .waitForOtherReceiver }
        switch attempt() {
        case .acquired: return .start
        case .heldByAnotherReceiver: return .waitForOtherReceiver
        case .unusable(let problem): return .cannotStart(problem)
        }
    }

    /// How often a waiting receiver checks again.
    static let retryInterval: TimeInterval = 2
}

/// The status line for receiver ports that fail to bind (`ReceiverPortHealth`).
enum ReceiverPortMessage {
    /// What a failing bind means for this Mac, or nil when every receiver
    /// port is listening. The listeners keep retrying, so it clears itself.
    static func text(for failures: [ReceiverPortFailure]) -> String? {
        if let media = failures.first(where: { $0.port == WireCrypto.tlsPort }) {
            return media.addressInUse
                ? String(localized: "Port \(String(media.port)) is in use by another app or another user on this Mac, so no Mac can connect. Quit it, and this Mac becomes available by itself.")
                : String(localized: "Port \(String(media.port)) couldn't be opened, so no Mac can connect. MeowDisplay keeps trying.")
        }
        if let pairing = failures.first(where: { $0.port == WireCrypto.pairingPort }) {
            return pairing.addressInUse
                ? String(localized: "Port \(String(pairing.port)) is in use by another app or another user on this Mac, so new Macs can't pair. Paired Macs can still connect.")
                : String(localized: "Port \(String(pairing.port)) couldn't be opened, so new Macs can't pair. Paired Macs can still connect.")
        }
        return nil
    }
}
