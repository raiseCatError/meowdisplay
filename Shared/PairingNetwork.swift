import Foundation
import Network

enum PairingFraming {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= WireCrypto.maxPairingFrameBytes else { throw PairingError.malformedMessage }
        var length = UInt32(body.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(body)
        return framed
    }

    static func send(_ envelope: PairingEnvelope, on connection: NWConnection) async throws {
        let data = try encode(envelope)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func receive(on connection: NWConnection) async throws -> PairingEnvelope {
        let header = try await receiveExactly(4, on: connection)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= WireCrypto.maxPairingFrameBytes else {
            throw PairingError.malformedMessage
        }
        let body = try await receiveExactly(Int(length), on: connection)
        do { return try JSONDecoder().decode(PairingEnvelope.self, from: body) }
        catch { throw PairingError.malformedMessage }
    }

    private static func receiveExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let needed = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: needed, maximumLength: needed) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: complete ? PairingError.malformedMessage : .malformedMessage) }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

/// `PairingTransport` over the pairing `NWConnection`.
final class NWPairingTransport: PairingTransport, @unchecked Sendable {
    private let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func send(_ envelope: PairingEnvelope) async throws { try await PairingFraming.send(envelope, on: connection) }
    func receive() async throws -> PairingEnvelope { try await PairingFraming.receive(on: connection) }
    func sendLastAndClose(_ envelope: PairingEnvelope?) {
        let connection = connection
        guard let envelope, let data = try? PairingFraming.encode(envelope) else { connection.cancel(); return }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum PairingNetwork {
    static func runInitiator(connection: NWConnection, localID: String, localName: String,
                             prompt: PairingPromptModel, expectedPeerID: String? = nil,
                             allowIdentityChange: Bool = false,
                             isCurrent: @escaping @Sendable () -> Bool = { true },
                             remoteHost: String? = nil, attemptToken: UUID = UUID(),
                             onHandshakeReached: (@Sendable () -> Void)? = nil) async throws -> PendingPairing {
        let (transport, gate, slot) = await beginAttempt(connection: connection, prompt: prompt, token: attemptToken)
        defer { Task { @MainActor in prompt.attemptEnded(token: attemptToken) } }
        let timeout = pairingTimeout(for: connection)
        defer { timeout.cancel() }
        try await waitUntilReady(connection)
        Log.info("pairDebug: initiator connected")
        guard let spki = TrustStore.shared.ownSPKI() else { throw PairingError.invalidKey }
        let handshake = PairingHandshake(role: .initiator, deviceID: localID,
                                         displayName: localName, identitySPKI: spki)
        // v13 commit-then-reveal: commit to our real hello first, so the
        // responder must choose its own hello before ever seeing ours — it
        // cannot adaptively pick a nonce to grind the derived SAS.
        let commitment = PairingHelloCommitment.compute(initiatorHello: handshake.localHello)
        try await PairingFraming.send(.helloCommit(commitment), on: connection)
        let response = try await PairingFraming.receive(on: connection)
        guard response.kind == .hello, let peerHello = response.hello else { throw PairingError.malformedMessage }
        if let expectedPeerID, peerHello.deviceID != expectedPeerID { throw PairingError.identityChanged }
        try await PairingFraming.send(.helloReveal(handshake.localHello), on: connection)
        let result = try handshake.result(peerHello: peerHello)
        var pending = classify(result.pending)
        try PairingClassifier.check(pending, allowIdentityChange: allowIdentityChange)
        if let remoteHost {
            pending.changesRemoteEndpoint = RemoteHintChange.wouldChange(
                existing: RemoteEndpointStore.endpoint(forPeerID: pending.peerID), newHost: remoteHost)
        }
        onHandshakeReached?()
        // A cancelled/superseded attempt must never surface a SAS prompt.
        guard isCurrent(), !gate.isCancelled else { throw PairingError.rejected }
        logReady(pending)
        try await PairingSessionCore.run(
            role: .initiator, result: result, pending: pending, transport: transport,
            gate: gate, abortSlot: slot,
            decide: { pending in
                let accepted = await prompt.request(pending, token: attemptToken)
                // Owner-auth failure/cancel surfaces its own error, not "rejected".
                if !accepted, let error = await prompt.takeOutcomeError(token: attemptToken) { throw error }
                return accepted
            },
            onPeerAbort: { Task { @MainActor in prompt.peerAborted(token: attemptToken) } },
            onCommitting: { Task { @MainActor in prompt.markCommitting(token: attemptToken) } },
            store: TrustStore.shared, isCurrent: isCurrent, remoteHost: remoteHost,
            hints: remoteHost == nil ? nil : RemoteEndpointStoreHints())
        logFinalized(pending)
        return pending
    }

    static func runResponder(connection: NWConnection, localID: String, localName: String,
                             prompt: PairingPromptModel,
                             allowIdentityChange: Bool = false,
                             isCurrent: @escaping @Sendable () -> Bool = { true },
                             attemptToken: UUID = UUID(),
                             throttle: PairingCommitThrottleGate = .shared) async throws -> PendingPairing {
        let (transport, gate, slot) = await beginAttempt(connection: connection, prompt: prompt, token: attemptToken)
        defer { Task { @MainActor in prompt.attemptEnded(token: attemptToken) } }
        let timeout = pairingTimeout(for: connection)
        defer { timeout.cancel() }
        try await waitUntilReady(connection)
        Log.info("pairDebug: responder connected")

        // v13 pre-SAS ceremony. Nothing of ours goes out — not even our own
        // hello — until a valid `helloCommit` is admitted by the throttle:
        // the responder must never send its hello, let alone show a SAS,
        // before receiving and accepting a commitment.
        let request = try await PairingFraming.receive(on: connection)
        guard request.kind == .helloCommit, let commitment = request.helloCommitment, commitment.count == 32 else {
            throw PairingError.malformedMessage
        }
        guard case .admitted(let throttleToken) = await throttle.admitCommitment() else {
            throw PairingError.tooManyAttempts
        }
        var throttleResolved = false
        // Any early return below (malformed reveal, timeout, disconnect,
        // mismatch, cancelled attempt) counts as a failed attempt unless the
        // reveal is later verified — never a post-SAS user cancellation,
        // which happens much later in `PairingSessionCore.run`, well after
        // this defer already resolved the throttle on success.
        defer { if !throttleResolved { Task { await throttle.revealFailed() } } }

        guard let spki = TrustStore.shared.ownSPKI() else { throw PairingError.invalidKey }
        let handshake = PairingHandshake(role: .responder, deviceID: localID,
                                         displayName: localName, identitySPKI: spki)
        guard isCurrent(), !gate.isCancelled else { throw PairingError.rejected }
        try await PairingFraming.send(.hello(handshake.localHello), on: connection)

        let reveal = try await receiveWithDeadline(PairingCommitThrottle.revealDeadline, on: connection)
        guard reveal.kind == .helloReveal, let peerHello = reveal.hello else { throw PairingError.malformedMessage }
        guard PairingHelloCommitment.verify(commitment, revealedInitiatorHello: peerHello) else {
            throw PairingError.commitmentMismatch
        }
        let result = try handshake.result(peerHello: peerHello)
        let pending = classify(result.pending)
        try PairingClassifier.check(pending, allowIdentityChange: allowIdentityChange)
        guard isCurrent(), !gate.isCancelled else { throw PairingError.rejected }
        // Reveal matched, hello validated, guards passed: this attempt no
        // longer counts against the anti-reroll throttle, and only now may
        // the SAS ever reach the screen.
        throttleResolved = true
        await throttle.revealSucceeded()
        logReady(pending)
        try await PairingSessionCore.run(
            role: .responder, result: result, pending: pending, transport: transport,
            gate: gate, abortSlot: slot,
            decide: { pending in
                let accepted = await prompt.request(pending, token: attemptToken)
                // Owner-auth failure/cancel surfaces its own error, not "rejected".
                if !accepted, let error = await prompt.takeOutcomeError(token: attemptToken) { throw error }
                return accepted
            },
            onPeerAbort: { Task { @MainActor in prompt.peerAborted(token: attemptToken) } },
            onCommitting: { Task { @MainActor in prompt.markCommitting(token: attemptToken) } },
            store: TrustStore.shared, isCurrent: isCurrent)
        // The ceremony reached authenticated trust completion (commit
        // verified and `PairingFinalizer` ran inside `PairingSessionCore.run`)
        // for THIS admitted attempt: only now is prior failure history
        // forgiven, never merely on a cheap self-consistent reveal.
        await throttle.pairingSucceeded(token: throttleToken)
        logFinalized(pending)
        return pending
    }

    /// Registers the prompt's Cancel path for this attempt: the same gate,
    /// abort frame and connection the handshake itself uses.
    private static func beginAttempt(connection: NWConnection, prompt: PairingPromptModel,
                                    token: UUID) async
        -> (NWPairingTransport, PairingCommitGate, PairingAbortSlot) {
        let transport = NWPairingTransport(connection)
        let gate = PairingCommitGate()
        let slot = PairingAbortSlot()
        await MainActor.run {
            prompt.registerAttempt(token) {
                PairingSessionCore.cancelAttempt(gate: gate, slot: slot, transport: transport)
            }
        }
        return (transport, gate, slot)
    }

    private static func logFinalized(_ pending: PendingPairing) {
        Log.info("pairDebug: trust persisted")
        Log.info("deviceUI: knownPeer added peerID=\(pending.peerID)")
    }

    private static func logReady(_ pending: PendingPairing) {
        Log.info("pairDebug: classification=\(String(describing: pending.classification))")
        Log.info("pairDebug: SAS ready")
    }

    /// Receives one frame, failing with `.malformedMessage` if it doesn't
    /// arrive within `seconds` — the responder's ~5-second reveal deadline
    /// after sending its own hello, distinct from the overall attempt
    /// deadline `pairingTimeout` enforces.
    private static func receiveWithDeadline(_ seconds: TimeInterval,
                                            on connection: NWConnection) async throws -> PairingEnvelope {
        try await withThrowingTaskGroup(of: PairingEnvelope.self) { group in
            group.addTask { try await PairingFraming.receive(on: connection) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PairingError.malformedMessage
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func pairingTimeout(for connection: NWConnection) -> Task<Void, Never> {
        Task {
            // The prompt owns the 60-second confirmation deadline. Keep the
            // network backstop slightly later so it cannot cancel the socket
            // before the prompt sends its explicit timeout rejection.
            try? await Task.sleep(nanoseconds: 65_000_000_000)
            guard !Task.isCancelled else { return }
            Log.info("pairDebug: pairing timed out")
            connection.cancel()
        }
    }

    /// Classifies against current trust *before* prompting — this never
    /// gates whether the request is shown, only what the prompt says. An
    /// existing pin for this peer ID is exactly the case the UI must call
    /// out (re-pair, or identity-changed), never silently skip.
    private static func classify(_ pending: PendingPairing) -> PendingPairing {
        PairingClassifier.classify(pending, existingPin: TrustStore.shared.pin(peerID: pending.peerID))
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = OneShotCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await completion.resume(returning: ()) }
                case .failed(let error):
                    Task { await completion.resume(throwing: error) }
                case .cancelled:
                    Task { await completion.resume(throwing: PairingError.rejected) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "pairing.connection"))
        }
    }
}

/// Delivers a `CheckedContinuation` at most once even when Network.framework's
/// state-update handler races timeout/receive/cancel/failure callbacks against
/// each other on its own dispatch queue; the actor serializes the race instead
/// of relying on an unsynchronized captured flag.
actor OneShotCompletion<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
