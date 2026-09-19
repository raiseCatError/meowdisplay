import Foundation

/// One pairing frame. `authenticator` carries the role-bound HMAC for the
/// commit / commitAck / abort steps (see `PairingResult.Step`).
struct PairingEnvelope: Codable {
    /// `helloCommit` / `hello` / `helloReveal` are the v13 pre-SAS ceremony,
    /// strictly ordered: initiator commit → responder hello → initiator
    /// reveal. They are deliberately distinct from `commit`/`commitAck`,
    /// which remain the later, unrelated live trust-finalization steps (see
    /// `PairingResult.Step`) — a cryptographic hello commitment is not the
    /// authenticated trust commit.
    enum Kind: String, Codable { case helloCommit, hello, helloReveal, confirmation, commit, commitAck, abort }
    let kind: Kind
    let hello: PairingHello?
    let confirmation: PairingConfirmation?
    var authenticator: Data? = nil
    var helloCommitment: Data? = nil

    static func helloCommit(_ commitment: Data) -> Self {
        .init(kind: .helloCommit, hello: nil, confirmation: nil, helloCommitment: commitment)
    }
    static func hello(_ value: PairingHello) -> Self {
        .init(kind: .hello, hello: value, confirmation: nil)
    }
    static func helloReveal(_ value: PairingHello) -> Self {
        .init(kind: .helloReveal, hello: value, confirmation: nil)
    }
    static func confirmation(_ value: PairingConfirmation) -> Self {
        .init(kind: .confirmation, hello: nil, confirmation: value)
    }
    static func step(_ kind: Kind, _ authenticator: Data) -> Self {
        .init(kind: kind, hello: nil, confirmation: nil, authenticator: authenticator)
    }
}

protocol PairingTransport: AnyObject, Sendable {
    func send(_ envelope: PairingEnvelope) async throws
    func receive() async throws -> PairingEnvelope
    /// Synchronously queue one last frame (if any) and then close.
    func sendLastAndClose(_ envelope: PairingEnvelope?)
}

/// The linearization point of a pairing attempt. `open` → `committed` or
/// `cancelled`, decided atomically: cancel wins only while still open, and a
/// commit can only begin while still open. Once `committed`, Cancel is no
/// longer valid; before that, a cancel guarantees this side never commits.
final class PairingCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0 // 0 open, 1 committed, 2 cancelled
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return state == 2 }
    var isCommitted: Bool { lock.lock(); defer { lock.unlock() }; return state == 1 }
    func beginCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == 0 else { return false }
        state = 1; return true
    }
    /// `false` when it is too late (already committed).
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == 1 { return false }
        state = 2; return true
    }
}

final class PairingAbortSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PairingEnvelope?
    var envelope: PairingEnvelope? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ envelope: PairingEnvelope) { lock.lock(); value = envelope; lock.unlock() }
}

/// Reads peer frames concurrently with the local SAS prompt so an
/// authenticated abort ends the attempt immediately, even while the SAS is on
/// screen. A frame that claims to be an abort but fails authentication ends the
/// attempt as malformed (it is never trusted).
final class PairingFramePump: @unchecked Sendable {
    let peerAborted = PairingFlag()
    private var iterator: AsyncThrowingStream<PairingEnvelope, Error>.Iterator

    init(transport: PairingTransport, result: PairingResult, onPeerAbort: @escaping @Sendable () -> Void) {
        var continuation: AsyncThrowingStream<PairingEnvelope, Error>.Continuation!
        let stream = AsyncThrowingStream<PairingEnvelope, Error> { continuation = $0 }
        iterator = stream.makeAsyncIterator()
        let cont = continuation!
        let aborted = peerAborted
        Task {
            do {
                while true {
                    let envelope = try await transport.receive()
                    if envelope.kind == .abort {
                        if let auth = envelope.authenticator,
                           (try? result.verifyStep(.abort, authenticator: auth)) != nil {
                            aborted.set(); onPeerAbort()
                            cont.finish(throwing: PairingError.cancelledByPeer)
                        } else {
                            cont.finish(throwing: PairingError.malformedMessage)
                        }
                        return
                    }
                    cont.yield(envelope)
                }
            } catch { cont.finish(throwing: error) }
        }
    }

    func next() async throws -> PairingEnvelope {
        guard let envelope = try await iterator.next() else { throw PairingError.malformedMessage }
        return envelope
    }
}

/// Post-hello pairing state machine, independent of Network.framework and the
/// Keychain so both roles can be exercised in-process.
///
/// Sequence after both hellos (SAS shown on both devices):
///   1. Each side: local decision → `confirmation(accepted)`  (PROVISIONAL)
///   2. Initiator, once it has locally accepted AND verified the responder's
///      accept: `commit`  ← linearization point for the initiator (no cancel after)
///   3. Responder, having locally accepted and verified the initiator's accept,
///      receives `commit`: persists trust, replies `commitAck`  ← linearization
///      point for the responder
///   4. Initiator receives `commitAck`: persists trust.
/// A local accept alone never lets the peer persist: the responder only
/// finalizes on a live `commit`, which the initiator sends only after both
/// accepted, and the initiator only finalizes on the responder's live ack.
/// Cancel before the point aborts the attempt (authenticated `abort` frame,
/// best effort, then close); a dropped abort still cannot complete anything
/// because the missing commit/ack never arrives.
enum PairingSessionCore {
    static func cancelAttempt(gate: PairingCommitGate, slot: PairingAbortSlot,
                              transport: PairingTransport) -> Bool {
        guard gate.cancel() else { return false }
        transport.sendLastAndClose(slot.envelope)
        return true
    }

    static func run(role: PairingHandshake.Role, result: PairingResult, pending: PendingPairing,
                    transport: PairingTransport, gate: PairingCommitGate, abortSlot: PairingAbortSlot,
                    decide: (PendingPairing) async throws -> Bool,
                    onPeerAbort: @escaping @Sendable () -> Void = {},
                    onCommitting: () -> Void = {},
                    store: PeerTrustStoring, isCurrent: () -> Bool = { true },
                    remoteHost: String? = nil, hints: RemoteEndpointHinting? = nil) async throws {
        abortSlot.set(.step(.abort, result.stepAuthenticator(.abort)))
        let pump = PairingFramePump(transport: transport, result: result, onPeerAbort: onPeerAbort)

        if pump.peerAborted.isSet { throw PairingError.cancelledByPeer }
        let accepted = try await decide(pending)
        if pump.peerAborted.isSet { throw PairingError.cancelledByPeer }
        if gate.isCancelled { throw PairingError.rejected }
        try await transport.send(.confirmation(result.confirmation(accepted: accepted)))
        guard accepted else { throw PairingError.rejected }

        func finalize(_ peerConfirmation: PairingConfirmation) throws {
            try PairingFinalizer.complete(result: result, pending: pending,
                                          peerConfirmation: peerConfirmation, store: store,
                                          isCurrent: isCurrent, remoteHost: remoteHost, hints: hints)
        }

        switch role {
        case .initiator:
            let reply = try await pump.next()
            guard reply.kind == .confirmation, let confirmation = reply.confirmation else {
                throw PairingError.malformedMessage
            }
            try result.verify(confirmation)
            guard gate.beginCommit() else { throw PairingError.rejected }
            onCommitting()
            try await transport.send(.step(.commit, result.stepAuthenticator(.commit)))
            let ack = try await pump.next()
            guard ack.kind == .commitAck, let auth = ack.authenticator else { throw PairingError.malformedMessage }
            try result.verifyStep(.commitAck, authenticator: auth)
            try finalize(confirmation)
        case .responder:
            var peerConfirmation: PairingConfirmation?
            while true {
                let frame = try await pump.next()
                switch frame.kind {
                case .confirmation:
                    guard let confirmation = frame.confirmation else { throw PairingError.malformedMessage }
                    try result.verify(confirmation)
                    peerConfirmation = confirmation
                case .commit:
                    guard let confirmation = peerConfirmation, let auth = frame.authenticator else {
                        throw PairingError.malformedMessage
                    }
                    try result.verifyStep(.commit, authenticator: auth)
                    guard gate.beginCommit() else { throw PairingError.rejected }
                    onCommitting()
                    try finalize(confirmation)
                    // Already committed and persisted: a lost ack cannot undo it.
                    try? await transport.send(.step(.commitAck, result.stepAuthenticator(.commitAck)))
                    return
                default:
                    throw PairingError.malformedMessage
                }
            }
        }
    }
}
