import Network
import XCTest

/// Two Mac receivers on one Mac — MeowDisplay's "Use This Mac as a Display"
/// role and the standalone MeowDisplay Receiver — in either launch order.
/// Each lock instance stands in for one app: `flock` locks belong to an open
/// file, so two instances conflict exactly as two processes do.
final class ReceiverOwnershipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiverOwnershipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var lockPath: String { directory.appendingPathComponent("receiver.lock").path }

    private func app() -> ReceiverOwnershipLock { ReceiverOwnershipLock(paths: [lockPath]) }

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

    func testAReadOnlyLockFileFromAnotherAccountStillWorks() throws {
        FileManager.default.createFile(atPath: lockPath, contents: nil,
                                       attributes: [.posixPermissions: 0o444])
        let first = app(), second = app()
        XCTAssertEqual(first.tryAcquire(), .acquired)
        XCTAssertEqual(second.tryAcquire(), .heldByAnotherReceiver)
    }

    func testFallsBackWhenTheSharedLocationIsUnusable() {
        let unusable = "/dev/null/meowdisplay/receiver.lock"
        let first = ReceiverOwnershipLock(paths: [unusable, lockPath])
        let second = ReceiverOwnershipLock(paths: [unusable, lockPath])
        XCTAssertEqual(first.tryAcquire(), .acquired)
        XCTAssertEqual(second.tryAcquire(), .heldByAnotherReceiver)
    }

    func testNoUsableLockFileDoesNotStopTheReceiver() {
        let lock = ReceiverOwnershipLock(paths: ["/dev/null/meowdisplay/receiver.lock"])
        XCTAssertEqual(lock.tryAcquire(), .unavailable)
        XCTAssertEqual(ReceiverStartGate.decide(otherReceiverRunning: false) { lock.tryAcquire() }, .start,
                       "a file-system problem must not make this Mac unusable as a display")
    }

    func testTheDefaultLockIsSystemWide() {
        XCTAssertEqual(ReceiverOwnershipLock.defaultPaths.first, "/Users/Shared/.meowdisplay-receiver.lock",
                       "the ports are system-wide, so the owner must be too")
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
