import Darwin
import Network
import XCTest

/// Two Mac receivers on one Mac — MeowDisplay's "Use This Mac as a Display"
/// role and the standalone MeowDisplay Receiver — in either launch order.
/// In-process, each lock instance stands in for one app: `flock` locks
/// belong to an open file, so two instances conflict exactly as two
/// processes do. `LockHolder` checks that against a real second process.
final class ReceiverOwnershipTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiverOwnershipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        // Undo any permissions a test took away, so the folder can go.
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let item as String in items {
                chmod(root.appendingPathComponent(item).path, 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private let directories = ["Application Support", "MeowDisplay"]
    private var lockDirectory: String { root.appendingPathComponent("Application Support/MeowDisplay").path }
    private var lockPath: String { lockDirectory + "/receiver.lock" }

    private func app() -> ReceiverOwnershipLock {
        ReceiverOwnershipLock(root: root.path, directories: directories)
    }

    private func makeLockDirectory() throws {
        try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func reason(_ attempt: ReceiverOwnershipAttempt) -> ReceiverLockProblem.Reason? {
        if case .unusable(let problem) = attempt { return problem.reason }
        return nil
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        return info.st_mode & 0o777
    }

    // MARK: - Launch orders

    func testDisplayRoleFirstThenStandaloneReceiver() {
        let displayRole = app(), standalone = app()
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { displayRole.tryAcquire() }, .start)
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { standalone.tryAcquire() },
                       .waitForOtherReceiver, "the second receiver never binds or advertises")
        XCTAssertFalse(standalone.isHeld)

        displayRole.release() // role turned off, after its listeners closed
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { standalone.tryAcquire() }, .start,
                       "the waiting receiver takes over on its next retry")
    }

    func testStandaloneReceiverFirstThenDisplayRole() {
        let standalone = app(), displayRole = app()
        XCTAssertEqual(standalone.tryAcquire(), .acquired)
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: true) { displayRole.tryAcquire() },
                       .waitForOtherReceiver)
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { displayRole.tryAcquire() },
                       .waitForOtherReceiver, "the lock alone also keeps it waiting")
        standalone.release() // quit
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { displayRole.tryAcquire() }, .start)
    }

    func testAReceiverWithoutTheLockStillMakesTheDisplayRoleWait() {
        // Already-released MeowDisplay Receiver builds bind without the lock: seen by bundle
        // id, and the lock isn't even taken while it runs.
        let displayRole = app()
        var attempted = false
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: true) {
            attempted = true
            return displayRole.tryAcquire()
        }, .waitForOtherReceiver)
        XCTAssertFalse(attempted)
        XCTAssertFalse(displayRole.isHeld)
    }

    // MARK: - Another process

    func testAnotherProcessHoldingTheLockMakesThisReceiverWait() throws {
        XCTAssertEqual(app().tryAcquire(), .acquired) // creates the file; released at once
        let other = try LockHolder(path: lockPath)
        XCTAssertTrue(other.holds)
        let receiver = app()
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { receiver.tryAcquire() },
                       .waitForOtherReceiver)
        other.quit() // a normal exit
        XCTAssertEqual(receiver.tryAcquire(), .acquired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
    }

    func testThisReceiverFirstKeepsAnotherProcessOut() throws {
        let receiver = app()
        XCTAssertEqual(receiver.tryAcquire(), .acquired)
        XCTAssertFalse(try LockHolder(path: lockPath).holds, "the other process can't take it")
        receiver.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "release never unlinks the file")
        let other = try LockHolder(path: lockPath)
        XCTAssertTrue(other.holds, "after release it can")
        XCTAssertEqual(receiver.tryAcquire(), .heldByAnotherReceiver)
        other.quit()
        XCTAssertEqual(receiver.tryAcquire(), .acquired, "and this one reacquires once it's gone")
    }

    func testAKilledOwnerNeverBlocksTheNextReceiver() throws {
        XCTAssertEqual(app().tryAcquire(), .acquired)
        let other = try LockHolder(path: lockPath)
        XCTAssertTrue(other.holds)
        XCTAssertEqual(app().tryAcquire(), .heldByAnotherReceiver)
        other.kill() // SIGKILL: no cleanup ran, the kernel dropped the lock
        XCTAssertEqual(app().tryAcquire(), .acquired)
    }

    // MARK: - The lock

    func testAQuitOrCrashedOwnerNeverBlocksTheNextReceiver() {
        var owner: ReceiverOwnershipLock? = app()
        XCTAssertEqual(owner?.tryAcquire(), .acquired)
        let next = app()
        XCTAssertEqual(next.tryAcquire(), .heldByAnotherReceiver)
        owner = nil // the kernel drops a flock with its file, as on quit or crash
        XCTAssertEqual(next.tryAcquire(), .acquired)
    }

    func testAcquiringIsIdempotentWhileHeld() {
        let owner = app()
        XCTAssertEqual(owner.tryAcquire(), .acquired)
        XCTAssertEqual(owner.tryAcquire(), .acquired)
        owner.release()
        owner.release()
        XCTAssertFalse(owner.isHeld)
    }

    func testCreatesAPrivateFolderAndFile() {
        XCTAssertEqual(app().tryAcquire(), .acquired)
        XCTAssertEqual(app().path, lockPath)
        XCTAssertEqual(mode(lockDirectory), 0o700)
        XCTAssertEqual(mode(lockPath) & 0o077, 0, "nobody else can read or write it")
    }

    func testAnExistingLockFileIsReusedAndTightened() throws {
        try makeLockDirectory()
        FileManager.default.createFile(atPath: lockPath, contents: nil, attributes: [.posixPermissions: 0o644])
        let owner = app()
        XCTAssertEqual(owner.tryAcquire(), .acquired)
        XCTAssertEqual(mode(lockPath), 0o600)
        XCTAssertEqual(app().tryAcquire(), .heldByAnotherReceiver, "the same file, not a replacement")
    }

    func testASymlinkAtTheLockPathIsRefused() throws {
        try makeLockDirectory()
        let target = root.appendingPathComponent("planted-target").path
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: target)
        XCTAssertEqual(reason(app().tryAcquire()), .symbolicLink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "nothing created through the link")

        // Pointing at a real file of this user's doesn't make it acceptable.
        FileManager.default.createFile(atPath: target, contents: nil)
        XCTAssertEqual(reason(app().tryAcquire()), .symbolicLink)
    }

    func testASymlinkedFolderIsRefused() throws {
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Application Support"),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: lockDirectory, withDestinationPath: elsewhere.path)
        let attempt = app().tryAcquire()
        XCTAssertEqual(reason(attempt), .symbolicLink)
        if case .unusable(let problem) = attempt { XCTAssertEqual(problem.path, lockDirectory) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [],
                       "nothing created through the link")
    }

    func testAHardLinkedLockFileIsRefused() throws {
        try makeLockDirectory()
        let other = root.appendingPathComponent("other").path
        FileManager.default.createFile(atPath: other, contents: nil, attributes: [.posixPermissions: 0o600])
        try FileManager.default.linkItem(atPath: other, toPath: lockPath)
        XCTAssertEqual(reason(app().tryAcquire()), .hardLinked)
    }

    func testANonRegularLockFileIsRefused() throws {
        try makeLockDirectory()
        try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: false)
        XCTAssertEqual(reason(app().tryAcquire()), .notARegularFile)

        // A FIFO would block a plain open() until a writer came along.
        try FileManager.default.removeItem(atPath: lockPath)
        XCTAssertEqual(mkfifo(lockPath, 0o600), 0)
        XCTAssertEqual(reason(app().tryAcquire()), .notARegularFile)
    }

    func testAFileWhereAFolderShouldBeIsRefused() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Application Support"),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: lockDirectory, contents: nil)
        XCTAssertEqual(reason(app().tryAcquire()), .notADirectory)
    }

    func testAFolderOthersCanWriteToIsRefused() throws {
        try makeLockDirectory()
        XCTAssertEqual(chmod(lockDirectory, 0o777), 0)
        XCTAssertEqual(reason(app().tryAcquire()), .writableByOthers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath), "nothing created there")
    }

    func testAnUnwritableFolderIsReportedNotIgnored() throws {
        try makeLockDirectory()
        XCTAssertEqual(chmod(lockDirectory, 0o500), 0)
        let attempt = app().tryAcquire()
        XCTAssertEqual(reason(attempt), .permissionDenied)
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { attempt },
                       .cannotStart(ReceiverLockProblem(path: lockPath, reason: .permissionDenied)),
                       "never starts as though it owned the ports")
    }

    func testAFolderOwnedByAnotherUserIsRefused() {
        // /Library belongs to root.
        let lock = ReceiverOwnershipLock(root: "/Library", directories: ["MeowDisplay-should-not-exist"])
        XCTAssertEqual(reason(lock.tryAcquire()), .ownedByAnotherUser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Library/MeowDisplay-should-not-exist"))
    }

    func testFilesAndFoldersOfAnotherUserAreRefused() {
        var file = stat()
        file.st_mode = S_IFREG | 0o600
        file.st_uid = getuid()
        file.st_nlink = 1
        XCTAssertNil(ReceiverOwnershipLock.validateFile(file))
        XCTAssertEqual(ReceiverOwnershipLock.validateFile(file, uid: getuid() + 1), .ownedByAnotherUser)

        var folder = stat()
        folder.st_mode = S_IFDIR | 0o700
        folder.st_uid = getuid()
        XCTAssertNil(ReceiverOwnershipLock.validateDirectory(folder))
        XCTAssertEqual(ReceiverOwnershipLock.validateDirectory(folder, uid: getuid() + 1), .ownedByAnotherUser)
        folder.st_mode = S_IFDIR | 0o720
        XCTAssertEqual(ReceiverOwnershipLock.validateDirectory(folder), .writableByOthers)
    }

    func testTheDefaultLockIsInThisUsersOwnLibrary() {
        let path = ReceiverOwnershipLock().path
        XCTAssertEqual(path, ReceiverOwnershipLock.homeDirectory + "/Library/Application Support/MeowDisplay/receiver.lock")
        XCTAssertFalse(path.hasPrefix("/Users/Shared"), "never a directory other accounts can write to")
    }

    // MARK: - What the user sees

    func testProblemsAreExplainedWithWhatToDo() {
        let problem = ReceiverLockProblem(path: "/x/receiver.lock", reason: .symbolicLink)
        XCTAssertTrue(problem.message.contains("/x/receiver.lock"))
        XCTAssertTrue(problem.message.contains("Try Again"))

        XCTAssertNil(ReceiverPortMessage.text(for: []))
        let media = ReceiverPortMessage.text(for: [
            ReceiverPortFailure(port: WireCrypto.pairingPort, addressInUse: true),
            ReceiverPortFailure(port: WireCrypto.tlsPort, addressInUse: true),
        ])
        XCTAssertEqual(media?.contains("9001"), true, "the media port matters most")
        XCTAssertEqual(media?.contains("in use"), true)
        let pairing = ReceiverPortMessage.text(for: [
            ReceiverPortFailure(port: WireCrypto.pairingPort, addressInUse: true),
        ])
        XCTAssertEqual(pairing?.contains("9002"), true)
        XCTAssertEqual(pairing?.contains("Paired Macs can still connect"), true)
        let other = ReceiverPortMessage.text(for: [
            ReceiverPortFailure(port: WireCrypto.tlsPort, addressInUse: false),
        ])
        XCTAssertEqual(other?.contains("couldn't be opened"), true)
    }

    // MARK: - A port taken by another app

    /// Another process (standing in for another user's receiver or an
    /// unrelated app) holds a port; the receivers' own listener parameters
    /// fail to bind it, and `ReceiverPortHealth` reports exactly that until
    /// the listener is ready. An ephemeral port, never 9001/9002, so a
    /// running MeowDisplay is undisturbed.
    func testAPortTakenByAnotherProcessIsReportedAsInUse() throws {
        let other = try PortHolder()
        let health = ReceiverPortHealth()
        let reported = expectation(description: "reported")
        health.setObserver { failures in
            if failures == [ReceiverPortFailure(port: WireCrypto.tlsPort, addressInUse: true)] { reported.fulfill() }
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: try XCTUnwrap(NWEndpoint.Port(rawValue: other.port)))
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { health.record(port: WireCrypto.tlsPort, error: error) }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        wait(for: [reported], timeout: 5)
        listener.cancel()

        health.clear(port: WireCrypto.tlsPort)
        XCTAssertEqual(health.current(), [], "a listener that comes up clears it")
        other.quit()
    }

    // MARK: - Listener ownership after stop

    func testAStoppedReceiverNeverReopensAListener() throws {
        let tls = TLSListenerState()
        let first = try NWListener(using: .tcp)
        XCTAssertTrue(tls.install(first))
        tls.retire()
        XCTAssertTrue(tls.isRetired())
        // A retry scheduled before stop() (after a failed bind) arrives late.
        XCTAssertFalse(tls.install(try NWListener(using: .tcp)))
        XCTAssertTrue(tls.currentListener() === first, "the refused listener is never installed")

        let quic = QUICReceiverContext()
        quic.retire()
        XCTAssertFalse(quic.install(try NWListener(using: .udp)))
        XCTAssertFalse(quic.hasCurrent())

        let pairing = PairingListenerState()
        pairing.retire()
        XCTAssertFalse(pairing.install(try NWListener(using: .tcp)))
        XCTAssertFalse(pairing.hasCurrent())
    }

    func testAFailedPairingListenerIsClearedSoItCanRetry() throws {
        let pairing = PairingListenerState()
        let failed = try NWListener(using: .tcp)
        XCTAssertTrue(pairing.install(failed))
        XCTAssertFalse(pairing.clearIfCurrent(try NWListener(using: .tcp)), "a stale failure clears nothing")
        XCTAssertTrue(pairing.clearIfCurrent(failed))
        XCTAssertFalse(pairing.hasCurrent(), "startPairingListener's guard lets the retry through")
    }

    // MARK: - What a second bind actually does

    /// Why ownership is needed at all, measured rather than assumed: with
    /// the receivers' own listener parameters (`allowLocalEndpointReuse`),
    /// a second process binding the same port fails with EADDRINUSE — it
    /// neither shares the port nor takes it over. Without the lock that
    /// failure would be silent and retried forever.
    func testASecondBindOnABusyReceiverPortFails() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let owner = try NWListener(using: parameters)
        let ready = expectation(description: "owner ready")
        owner.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        owner.newConnectionHandler = { $0.cancel() }
        owner.start(queue: .main)
        wait(for: [ready], timeout: 5)
        defer { owner.cancel() }
        let port = try XCTUnwrap(owner.port)

        let second = try NWListener(using: parameters, on: port)
        let failed = expectation(description: "second bind fails")
        second.stateUpdateHandler = { state in
            if case .failed(let error) = state, case .posix(let code) = error, code == .EADDRINUSE {
                failed.fulfill()
            }
        }
        second.newConnectionHandler = { $0.cancel() }
        second.start(queue: .main)
        wait(for: [failed], timeout: 5)
        second.cancel()
    }
}

/// A separate process taking the same `flock(2)` on the same file, the way
/// the other receiver app does: Perl's `flock` is the system call.
private final class LockHolder {
    private let process = Process()
    private let input = Pipe()
    /// It got the lock (and holds it until `quit()` or `kill()`); false: the
    /// lock was taken and it exited.
    private(set) var holds = false

    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use Fcntl qw(:flock);
            open(my $f, "<", $ARGV[0]) or exit 2;
            flock($f, LOCK_EX | LOCK_NB) or exit 3;
            $| = 1; print "locked\\n";
            <STDIN>;
            """, path]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        holds = line == "locked\n"
        if !holds {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 3, "exits because the lock is taken, nothing else")
        }
    }

    /// Exits normally.
    func quit() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    /// Dies without any chance to clean up.
    func kill() {
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    deinit {
        if process.isRunning { kill() }
    }
}

/// A separate process listening on an ephemeral TCP port, dual-stack like
/// an `NWListener`.
private final class PortHolder {
    private let process = Process()
    private let input = Pipe()
    private(set) var port: UInt16 = 0

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use Socket qw(:all);
            socket(my $s, AF_INET6, SOCK_STREAM, 0) or exit 2;
            setsockopt($s, IPPROTO_IPV6, IPV6_V6ONLY, 0);
            bind($s, pack_sockaddr_in6(0, IN6ADDR_ANY)) or exit 3;
            listen($s, 5) or exit 4;
            my ($port) = unpack_sockaddr_in6(getsockname($s));
            $| = 1; print "$port\\n";
            <STDIN>;
            """]
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        port = try XCTUnwrap(UInt16(line.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func quit() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
