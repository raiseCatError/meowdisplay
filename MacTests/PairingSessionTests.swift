import CryptoKit
import XCTest

/// In-memory pairing transport with TCP-like semantics: frames sent before a
/// close are still delivered, sends to a closed peer silently "succeed", and
/// inbound delivery can be held to force deterministic race orderings.
private final class MemoryTransport: PairingTransport, @unchecked Sendable {
    private enum Held { case frame(PairingEnvelope), eof }
    private let lock = NSLock()
    private weak var peer: MemoryTransport?
    private var continuation: AsyncThrowingStream<PairingEnvelope, Error>.Continuation!
    private var iterator: AsyncThrowingStream<PairingEnvelope, Error>.Iterator
    private var paused = false
    private var held: [Held] = []
    private var closed = false

    init() {
        var c: AsyncThrowingStream<PairingEnvelope, Error>.Continuation!
        let stream = AsyncThrowingStream<PairingEnvelope, Error> { c = $0 }
        continuation = c
        iterator = stream.makeAsyncIterator()
    }

    static func pair() -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport(), b = MemoryTransport()
        a.peer = b; b.peer = a
        return (a, b)
    }

    private func deliver(_ item: Held) {
        lock.lock(); defer { lock.unlock() }
        if paused { held.append(item); return }
        push(item)
    }

    private func push(_ item: Held) {
        switch item {
        case .frame(let e): continuation.yield(e)
        case .eof: continuation.finish()
        }
    }

    func pauseInbound() { lock.lock(); paused = true; lock.unlock() }
    func resumeInbound() {
        lock.lock(); paused = false
        let items = held; held = []
        items.forEach(push)
        lock.unlock()
    }

    private func checkClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func send(_ envelope: PairingEnvelope) async throws {
        if checkClosed() { throw PairingError.malformedMessage }
        peer?.deliver(.frame(envelope))
    }

    func receive() async throws -> PairingEnvelope {
        guard let envelope = try await iterator.next() else { throw PairingError.malformedMessage }
        return envelope
    }

    func sendLastAndClose(_ envelope: PairingEnvelope?) {
        lock.lock(); closed = true; lock.unlock()
        if let envelope { peer?.deliver(.frame(envelope)) }
        peer?.deliver(.eof)
        continuation.finish(throwing: PairingError.malformedMessage)
    }
}

private final class Decider: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var early: Bool?
    private(set) var asked = false
    func decide() async -> Bool {
        await withCheckedContinuation { c in
            lock.lock(); asked = true
            if let early { self.early = nil; lock.unlock(); c.resume(returning: early); return }
            continuation = c; lock.unlock()
        }
    }
    func resolve(_ value: Bool) {
        lock.lock()
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(returning: value); return }
        early = value; lock.unlock()
    }
}

/// Structurally synchronized: every access to `savedStorage` is lock-protected,
/// so this test double is truthfully Sendable rather than merely unchecked.
///
/// Type: Hints
/// Mutable state: `savedStorage: [String]`
/// Synchronization: `NSLock` around every read and write
/// Why all accesses are safe: no access reaches `savedStorage` outside the lock
/// Why unchecked is necessary: `RemoteEndpointHinting` is not `Sendable` itself
/// Why scope is narrow: test-private, only used by `Side`
private final class Hints: RemoteEndpointHinting, @unchecked Sendable {
    private let lock = NSLock()
    private var savedStorage: [String] = []
    func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String) {
        lock.lock(); savedStorage.append(peerID); lock.unlock()
    }
    var saved: [String] { lock.lock(); defer { lock.unlock() }; return savedStorage }
}

/// Test-local `PeerTrustStoring` conformer with genuine lock-protected state,
/// used in place of the production `InMemoryPeerTrustStore` (whose `pins` are
/// unsynchronized and not truthfully Sendable) wherever a `Side` crosses a
/// concurrency domain.
///
/// Type: TestPeerTrustStore
/// Mutable state: `pinsStorage: [String: Data]`
/// Synchronization: `NSLock` around every read and write
/// Why all accesses are safe: no access reaches `pinsStorage` outside the lock,
/// and no callback is invoked while the lock is held
/// Why unchecked is necessary: `PeerTrustStoring` is not `Sendable` itself
/// Why scope is narrow: test-private, only used by `Side`
private final class TestPeerTrustStore: PeerTrustStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pinsStorage: [String: Data] = [:]

    func pin(peerID: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return pinsStorage[peerID]
    }

    func setPin(peerID: String, spki: Data, displayName: String, allowIdentityChange: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch TrustPinPolicy.decision(existing: pinsStorage[peerID], presented: spki) {
        case .new, .match: pinsStorage[peerID] = spki; return true
        case .identityChanged:
            guard allowIdentityChange else { return false }
            pinsStorage[peerID] = spki
            return true
        }
    }

    func forget(peerID: String) { lock.lock(); pinsStorage[peerID] = nil; lock.unlock() }

    var pinCount: Int { lock.lock(); defer { lock.unlock() }; return pinsStorage.count }
}

/// Bridges @Sendable closures crossing into `PairingSessionCore.run` to the
/// @MainActor `PairingPromptModel` without ever making the production model
/// itself Sendable. Every access to `prompt` happens on MainActor: `request`
/// awaits into it (an ordinary actor hop), and the fire-and-forget methods
/// hop over explicitly. The handle itself holds no independently mutable
/// unsynchronized state.
///
/// Type: PromptHandle
/// Mutable state: none (a single `let` reference to the MainActor model)
/// Synchronization: all access to `prompt` occurs on MainActor, either via
/// `await` (actor hop) or `Task { @MainActor in ... }`
/// Why all accesses are safe: `prompt`'s own state is only ever touched while
/// isolated to MainActor
/// Why unchecked is necessary: `PairingPromptModel` is not `Sendable`
/// Why scope is narrow: test-private, only used by the shared-prompt tests
private final class PromptHandle: @unchecked Sendable {
    private let prompt: PairingPromptModel
    init(_ prompt: PairingPromptModel) { self.prompt = prompt }

    func request(_ value: PendingPairing, token: UUID) async -> Bool {
        await prompt.request(value, token: token)
    }
    func peerAborted(token: UUID) {
        Task { @MainActor [prompt] in prompt.peerAborted(token: token) }
    }
    func markCommitting(token: UUID) {
        Task { @MainActor [prompt] in prompt.markCommitting(token: token) }
    }
}

private final class Side {
    let store = TestPeerTrustStore()
    let hints = Hints()
    let decider = Decider()
    let gate = PairingCommitGate()
    let slot = PairingAbortSlot()
    let role: PairingHandshake.Role
    let result: PairingResult
    let transport: MemoryTransport
    // Backed by the existing thread-safe PairingFlag rather than an
    // unsynchronized Bool, since Side itself stays non-Sendable and this is
    // read from tests while `start()`'s Task is still running.
    private let committingFlag = PairingFlag()
    var committing: Bool { committingFlag.isSet }
    var task: Task<Void, Error>?

    init(role: PairingHandshake.Role, result: PairingResult, transport: MemoryTransport) {
        self.role = role; self.result = result; self.transport = transport
    }

    func start(remoteHost: String? = nil) {
        // Hoist every value the Task needs into local, Sendable constants
        // before creating it: the closure must not capture `self`/`Side`.
        let role = role
        let result = result
        let pending = result.pending
        let transport = transport
        let gate = gate
        let slot = slot
        let store = store
        let hints: RemoteEndpointHinting? = remoteHost == nil ? nil : hints
        let decider = decider
        let committingFlag = committingFlag
        task = Task {
            try await PairingSessionCore.run(
                role: role, result: result, pending: pending, transport: transport,
                gate: gate, abortSlot: slot, decide: { _ in await decider.decide() },
                onPeerAbort: { decider.resolve(false) }, onCommitting: { committingFlag.set() },
                store: store, remoteHost: remoteHost, hints: hints)
        }
    }

    /// What the UI Cancel button does.
    @discardableResult
    func cancel() -> Bool {
        let ok = PairingSessionCore.cancelAttempt(gate: gate, slot: slot, transport: transport)
        if ok { decider.resolve(false) }
        return ok
    }

    func outcome() async -> Result<Void, Error> { await task!.result }
    /// Synchronous accessor so a @MainActor caller can await the task's
    /// result without sending non-Sendable `Side` across an isolation
    /// boundary: `Task<Void, Error>` itself is unconditionally Sendable.
    var taskHandle: Task<Void, Error> { task! }
    var pinCount: Int { store.pinCount }
}

final class PairingSessionTests: XCTestCase {
    private let initiatorID = "22222222-2222-2222-2222-222222222222"
    private let responderID = "11111111-1111-1111-1111-111111111111"

    private func makePair() throws -> (initiator: Side, responder: Side, iT: MemoryTransport, rT: MemoryTransport) {
        let phone = PairingHandshake(role: .initiator, deviceID: initiatorID, displayName: "Phone",
                                     identitySPKI: Data("phone identity".utf8))
        let mac = PairingHandshake(role: .responder, deviceID: responderID, displayName: "Mac",
                                   identitySPKI: Data("mac identity".utf8))
        let (a, b) = MemoryTransport.pair()
        let i = Side(role: .initiator, result: try phone.result(peerHello: mac.localHello), transport: a)
        let r = Side(role: .responder, result: try mac.result(peerHello: phone.localHello), transport: b)
        // Watchdog standing in for the real 65s network backstop. Capture
        // only the (Sendable) transport, never Side itself.
        for side in [i, r] {
            let transport = side.transport
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); transport.sendLastAndClose(nil) }
        }
        return (i, r, a, b)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<2000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func assertNoTrust(_ sides: Side..., file: StaticString = #filePath, line: UInt = #line) {
        for side in sides {
            XCTAssertEqual(side.pinCount, 0, file: file, line: line)
            XCTAssertTrue(side.hints.saved.isEmpty, file: file, line: line)
        }
    }

    // MARK: normal completion

    func testBothConfirmBothFinalize() async throws {
        let (i, r, _, _) = try makePair()
        i.start(remoteHost: "100.64.0.7"); r.start()
        i.decider.resolve(true); r.decider.resolve(true)
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertNoThrow(try io.get()); XCTAssertNoThrow(try ro.get())
        XCTAssertNotNil(i.store.pin(peerID: responderID))
        XCTAssertNotNil(r.store.pin(peerID: initiatorID))
        XCTAssertEqual(i.hints.saved, [responderID])
        XCTAssertFalse(i.cancel() && i.gate.isCommitted, "cancel is invalid after the commit point")
    }

    // MARK: the hardware bug — REPRO A / B

    /// Initiator confirms, cancels while waiting, responder confirms afterwards.
    func testInitiatorConfirmsCancelsThenResponderConfirms_NoTrust() async throws {
        let (i, r, _, _) = try makePair()
        i.start(remoteHost: "100.64.0.7"); r.start()
        i.decider.resolve(true)
        await waitUntil(r.decider.asked)
        XCTAssertTrue(i.cancel())
        r.decider.resolve(true)            // responder user taps Codes Match afterwards
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
        XCTAssertFalse(r.committing, "responder must never reach its commit point")
    }

    /// Responder confirms, cancels while waiting, initiator confirms afterwards.
    func testResponderConfirmsCancelsThenInitiatorConfirms_NoTrust() async throws {
        let (i, r, _, _) = try makePair()
        i.start(remoteHost: "100.64.0.7"); r.start()
        r.decider.resolve(true)
        await waitUntil(i.decider.asked)
        XCTAssertTrue(r.cancel())
        i.decider.resolve(true)
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
    }

    /// Same, but the abort frame is lost: a previously delivered acceptance
    /// alone must still be insufficient.
    func testDroppedAbortStillCannotComplete_InitiatorCancels() async throws {
        let (i, r, iT, _) = try makePair()
        i.start(); r.start()
        i.decider.resolve(true)
        await waitUntil(r.decider.asked)
        XCTAssertTrue(i.gate.cancel())
        iT.sendLastAndClose(nil)           // close only, no abort frame
        r.decider.resolve(true)
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
    }

    func testDroppedAbortStillCannotComplete_ResponderCancels() async throws {
        let (i, r, _, rT) = try makePair()
        i.start(); r.start()
        r.decider.resolve(true)
        await waitUntil(i.decider.asked)
        XCTAssertTrue(r.gate.cancel())
        rT.sendLastAndClose(nil)
        i.decider.resolve(true)            // initiator even reaches its commit point
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
    }

    // MARK: races

    func testCancelBeforeAnyConfirmation() async throws {
        let (i, r, _, _) = try makePair()
        i.start(); r.start()
        await waitUntil(i.decider.asked && r.decider.asked)
        XCTAssertTrue(i.cancel())
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get())
        XCTAssertThrowsError(try ro.get())
        if case .failure(let e) = ro { XCTAssertEqual(e as? PairingError, .cancelledByPeer) }
        assertNoTrust(i, r)
    }

    /// Commit is already in flight toward the responder when the responder
    /// cancels: cancel wins (gate still open), commit is ignored, no trust.
    func testCancelWinsRaceAgainstInFlightCommit() async throws {
        let (i, r, _, rT) = try makePair()
        i.start(); r.start()
        r.decider.resolve(true)
        await waitUntil(i.decider.asked)
        rT.pauseInbound()                  // hold the initiator's frames at the responder
        i.decider.resolve(true)            // initiator commits immediately
        await waitUntil(i.committing)
        XCTAssertTrue(r.cancel(), "responder has not received the commit yet: cancel is valid")
        rT.resumeInbound()                 // stale commit arrives after local cancel
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
    }

    /// Commit wins: responder persisted, so Cancel is refused and the UI must
    /// move to success rather than offering Cancel.
    func testCommitWinsThenCancelIsRefused() async throws {
        let (i, r, _, _) = try makePair()
        i.start(); r.start()
        r.decider.resolve(true); i.decider.resolve(true)
        let (io, ro) = (await i.outcome(), await r.outcome())
        XCTAssertNoThrow(try io.get()); XCTAssertNoThrow(try ro.get())
        XCTAssertFalse(r.cancel())
        XCTAssertFalse(i.cancel())
        XCTAssertNotNil(r.store.pin(peerID: initiatorID))
    }

    func testPeerRejectionIsRejectedNotCancelled() async throws {
        let (i, r, _, _) = try makePair()
        i.start(); r.start()
        r.decider.resolve(false); i.decider.resolve(true)
        let (io, ro) = (await i.outcome(), await r.outcome())
        if case .failure(let e) = io { XCTAssertEqual(e as? PairingError, .rejected) } else { XCTFail() }
        XCTAssertThrowsError(try ro.get())
        assertNoTrust(i, r)
    }

    // MARK: stale / new generation

    func testNewAttemptAfterCancelledAttemptPairsNormally() async throws {
        do {
            let (i, r, _, _) = try makePair()
            i.start(); r.start()
            i.decider.resolve(true)
            await waitUntil(r.decider.asked)
            XCTAssertTrue(i.cancel())
            _ = await (i.outcome(), r.outcome())
            assertNoTrust(i, r)
        }
        let (i2, r2, _, _) = try makePair()   // fresh generation: new keys, transcript, transport
        i2.start(remoteHost: "mac.tail1234.ts.net"); r2.start()
        i2.decider.resolve(true); r2.decider.resolve(true)
        let (io, ro) = (await i2.outcome(), await r2.outcome())
        XCTAssertNoThrow(try io.get()); XCTAssertNoThrow(try ro.get())
        XCTAssertEqual(i2.pinCount, 1); XCTAssertEqual(r2.pinCount, 1)
    }

    /// Frames from a previous attempt's transcript never authenticate here.
    func testStaleCommitFromOtherAttemptIsRejected() async throws {
        let old = try makePair()
        let fresh = try makePair()
        let staleCommit = PairingEnvelope.step(.commit, old.initiator.result.stepAuthenticator(.commit))
        XCTAssertThrowsError(try fresh.responder.result.verifyStep(.commit, authenticator: staleCommit.authenticator!))
    }

    func testForgedAbortIsNotAnAuthenticatedCancel() throws {
        let (_, r, _, _) = try makePair()
        XCTAssertThrowsError(try r.result.verifyStep(.abort, authenticator: Data(repeating: 7, count: 32)))
    }

    func testCancelledAttemptNeverProducesSuccessFeedback() {
        for error in [PairingError.cancelledByPeer, .rejected, .invalidConfirmation] {
            XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(error)), .none)
        }
    }

    func testGateLinearization() {
        let a = PairingCommitGate()
        XCTAssertTrue(a.beginCommit()); XCTAssertFalse(a.cancel()); XCTAssertFalse(a.beginCommit())
        let b = PairingCommitGate()
        XCTAssertTrue(b.cancel()); XCTAssertFalse(b.beginCommit()); XCTAssertTrue(b.cancel())
    }

    // MARK: two concurrent attempts sharing one prompt (Mac LAN listener shape)

    @MainActor
    func testConcurrentAttemptBCannotAffectAttemptAOnSharedPrompt() async throws {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let promptHandle = PromptHandle(prompt)
        let a = try makePair()    // legitimate attempt; responder side uses the prompt
        let b = try makePair()    // unrelated attempt to the same listener
        let (tokenA, tokenB) = (UUID(), UUID())
        var aCancelled = 0
        prompt.registerAttempt(tokenA) {
            aCancelled += 1
            return PairingSessionCore.cancelAttempt(gate: a.responder.gate, slot: a.responder.slot,
                                                    transport: a.responder.transport)
        }
        prompt.registerAttempt(tokenB) {
            PairingSessionCore.cancelAttempt(gate: b.responder.gate, slot: b.responder.slot,
                                             transport: b.responder.transport)
        }
        func run(_ pair: (initiator: Side, responder: Side, iT: MemoryTransport, rT: MemoryTransport),
                 token: UUID) {
            pair.initiator.start()
            // Hoist locals so the Task captures no non-Sendable `Side`/`pair`.
            let result = pair.responder.result
            let pending = pair.responder.result.pending
            let transport = pair.responder.transport
            let gate = pair.responder.gate
            let slot = pair.responder.slot
            let store = pair.responder.store
            // Typed explicitly @Sendable: PairingSessionCore.run executes off
            // the main actor, so these closures must not be inferred as
            // MainActor-isolated merely because they're built inside a Task
            // created from @MainActor code.
            let decide: @Sendable (PendingPairing) async -> Bool = { await promptHandle.request($0, token: token) }
            let onPeerAbort: @Sendable () -> Void = { promptHandle.peerAborted(token: token) }
            let onCommitting: @Sendable () -> Void = { promptHandle.markCommitting(token: token) }
            pair.responder.task = Task {
                try await PairingSessionCore.run(
                    role: .responder, result: result, pending: pending,
                    transport: transport, gate: gate, abortSlot: slot,
                    decide: decide, onPeerAbort: onPeerAbort, onCommitting: onCommitting,
                    store: store)
            }
        }
        run(a, token: tokenA)
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: true)                       // A: local confirm → waiting
        a.initiator.decider.resolve(false)                // (A's peer stays undecided/irrelevant)
        run(b, token: tokenB)                             // B connects: duplicate, refused
        _ = await b.responder.taskHandle.result
        b.initiator.cancel()                              // B's peer sends a valid abort for B
        Task { @MainActor in prompt.attemptEnded(token: tokenB) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(prompt.owner, tokenA)
        XCTAssertNotNil(prompt.confirmedLocally, "A's waiting state survived B")
        prompt.cancelWaiting()                            // A's real Cancel
        XCTAssertEqual(aCancelled, 1)
        XCTAssertTrue(a.responder.gate.isCancelled, "A's own connection was the one cancelled")
        XCTAssertFalse(b.responder.gate.isCommitted)
        XCTAssertEqual(a.responder.pinCount, 0)
    }

    // MARK: Transport-independent ceremony (LAN / USB / Remote share this core)

    /// No transport can confirm on the user's behalf: with nobody answering the
    /// SAS, both sides ask and neither trusts (USB/loopback used to auto-confirm).
    func testCeremonyRequiresExplicitSASOnBothSides() async throws {
        let (i, r, _, _) = try makePair()
        i.start(); r.start()
        await waitUntil(i.decider.asked && r.decider.asked)
        XCTAssertTrue(i.decider.asked && r.decider.asked)
        XCTAssertEqual(i.pinCount, 0); XCTAssertEqual(r.pinCount, 0)
        XCTAssertFalse(i.gate.isCommitted); XCTAssertFalse(r.gate.isCommitted)
        _ = i.cancel()
        _ = await (i.outcome(), r.outcome())
    }

    /// Local confirm → waiting → real cancel → late peer confirm: no trust.
    /// (Runs through the shared prompt exactly like the LAN/USB responder path.)
    @MainActor
    func testWaitingCancelThenLatePeerConfirmCannotEstablishTrust() async throws {
        let prompt = PairingPromptModel.granting(timeoutNanoseconds: 5_000_000_000)
        let promptHandle = PromptHandle(prompt)
        let pair = try makePair()
        let token = UUID()
        let side = pair.responder
        prompt.registerAttempt(token) {
            PairingSessionCore.cancelAttempt(gate: side.gate, slot: side.slot, transport: side.transport)
        }
        pair.initiator.start()
        // Hoist locals so the Task captures no non-Sendable `Side`.
        let result = side.result
        let pending = side.result.pending
        let transport = side.transport
        let gate = side.gate
        let slot = side.slot
        let store = side.store
        let decide: @Sendable (PendingPairing) async -> Bool = { await promptHandle.request($0, token: token) }
        let onPeerAbort: @Sendable () -> Void = { promptHandle.peerAborted(token: token) }
        let onCommitting: @Sendable () -> Void = { promptHandle.markCommitting(token: token) }
        side.task = Task {
            try await PairingSessionCore.run(
                role: .responder, result: result, pending: pending,
                transport: transport, gate: gate, abortSlot: slot,
                decide: decide, onPeerAbort: onPeerAbort, onCommitting: onCommitting,
                store: store)
        }
        while prompt.pending == nil { await Task.yield() }
        prompt.decide(accept: true)
        while prompt.confirmedLocally == nil { await Task.yield() }   // owner auth resolves asynchronously
        XCTAssertNotNil(prompt.confirmedLocally, "waiting state after local confirm")
        prompt.cancelWaiting()
        XCTAssertNil(prompt.confirmedLocally)
        pair.initiator.decider.resolve(true)              // late peer confirm
        let (io, ro) = (await pair.initiator.taskHandle.result, await side.taskHandle.result)
        XCTAssertThrowsError(try io.get()); XCTAssertThrowsError(try ro.get())
        XCTAssertEqual(side.pinCount, 0); XCTAssertEqual(pair.initiator.pinCount, 0)
    }

    func testUSBPolicyPairsOnlyUnpinnedPeersAndNeverReplacesPins() {
        XCTAssertTrue(USBPairingPolicy.shouldBeginPairing(hasPin: false, alreadyAttemptedThisSession: false))
        XCTAssertFalse(USBPairingPolicy.shouldBeginPairing(hasPin: true, alreadyAttemptedThisSession: false),
                       "already-trusted USB just connects")
        XCTAssertFalse(USBPairingPolicy.shouldBeginPairing(hasPin: false, alreadyAttemptedThisSession: true))
        XCTAssertFalse(USBPairingPolicy.allowIdentityChange)
    }

    func testChangedIdentityOverUSBIsAHardFailureAndKeepsThePin() throws {
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: responderID, spki: Data("original".utf8), displayName: "Phone")
        let phone = PairingHandshake(role: .initiator, deviceID: initiatorID, displayName: "Mac",
                                     identitySPKI: Data("mac identity".utf8))
        let impostor = PairingHandshake(role: .responder, deviceID: responderID, displayName: "Phone",
                                        identitySPKI: Data("impostor".utf8))
        let pending = PairingClassifier.classify(try phone.result(peerHello: impostor.localHello).pending,
                                                 existingPin: store.pin(peerID: responderID))
        XCTAssertThrowsError(try PairingClassifier.check(pending, allowIdentityChange: USBPairingPolicy.allowIdentityChange))
        XCTAssertEqual(store.pin(peerID: responderID), Data("original".utf8))
    }

    func testFinalizationOnlyFeedbackIsTransportIndependent() {
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.success(())), .success)
        XCTAssertEqual(PairingOutcomeFeedback.forCompletion(Result<Void, Error>.failure(PairingError.cancelledByPeer)), .none)
    }

    /// Loopback must never be treated as approval: the receiver and the
    /// pairing network layer no longer contain any auto-confirm path.
    func testNoAutoConfirmOrLoopbackApprovalRemains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Shared/StreamReceiver.swift", "Shared/PairingNetwork.swift", "Mac/OpenSidecarMacApp.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("autoConfirm"), "\(path) must not auto-confirm pairing")
            XCTAssertFalse(source.contains("isLoopback(connection"), "\(path) must not approve by loopback")
        }
    }

    /// v13: LAN must no longer silently allow identity replacement. Every
    /// LAN initiator/responder call site (Mac and iOS) must pass an explicit
    /// `allowIdentityChange: false`, matching Remote/USB, rather than relying
    /// on a default that used to be `true`.
    func testLANCallSitesExplicitlyRefuseIdentityChange() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let macSource = try String(contentsOf: root.appendingPathComponent("Mac/OpenSidecarMacApp.swift"), encoding: .utf8)
        let iosSource = try String(contentsOf: root.appendingPathComponent("Shared/StreamReceiver.swift"), encoding: .utf8)
        // Every runInitiator/runResponder call in both files must name
        // allowIdentityChange explicitly — none may rely on the default.
        for source in [macSource, iosSource] {
            var searchRange = source.startIndex..<source.endIndex
            var callCount = 0
            while let callRange = source.range(of: "PairingNetwork.run", range: searchRange) {
                callCount += 1
                // Balanced-paren scan from the call's opening "(" so nested
                // calls like `Host.current().localizedName` don't truncate it.
                var depth = 0
                var idx = callRange.upperBound
                var end = idx
                while idx < source.endIndex {
                    let c = source[idx]
                    if c == "(" { depth += 1 }
                    else if c == ")" { depth -= 1; if depth == 0 { end = source.index(after: idx); break } }
                    idx = source.index(after: idx)
                }
                let call = source[callRange.lowerBound..<end]
                XCTAssertTrue(call.contains("allowIdentityChange:"),
                              "call site missing explicit allowIdentityChange: \(call.prefix(300))")
                searchRange = end..<source.endIndex
            }
            XCTAssertGreaterThan(callCount, 0)
        }
    }

    func testDefaultAllowIdentityChangeIsFalse() throws {
        let phone = PairingHandshake(role: .initiator, deviceID: initiatorID, displayName: "Mac",
                                     identitySPKI: Data("mac identity".utf8))
        let impostor = PairingHandshake(role: .responder, deviceID: responderID, displayName: "Phone",
                                        identitySPKI: Data("impostor".utf8))
        let store = InMemoryPeerTrustStore()
        store.setPin(peerID: responderID, spki: Data("original".utf8), displayName: "Phone")
        let pending = PairingClassifier.classify(try phone.result(peerHello: impostor.localHello).pending,
                                                 existingPin: store.pin(peerID: responderID))
        // No allowIdentityChange argument at all: relies on PairingClassifier's
        // own default, mirroring PairingNetwork's new false default.
        XCTAssertThrowsError(try PairingClassifier.check(pending, allowIdentityChange: false))
    }

    func testRemoteWordingDoesNotLeakIntoSharedCeremonyCopy() {
        for text in [PairingCopy.sasTitle, PairingCopy.sasHelper, PairingCopy.waitingTitle,
                     PairingCopy.waitingHelper(otherDevice: "your Mac")] {
            XCTAssertFalse(text.contains("Pair Over Remote"))
        }
        XCTAssertTrue(PairingCopy.connectingHelper(target: .mac).contains("Pair Over Remote"),
                      "Remote wording lives only in the Remote pre-SAS helper")
    }
}
