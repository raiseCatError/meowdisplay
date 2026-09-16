import Foundation
import Network

struct PairingEnvelope: Codable {
    enum Kind: String, Codable { case hello, confirmation }
    let kind: Kind
    let hello: PairingHello?
    let confirmation: PairingConfirmation?

    static func hello(_ value: PairingHello) -> Self {
        .init(kind: .hello, hello: value, confirmation: nil)
    }
    static func confirmation(_ value: PairingConfirmation) -> Self {
        .init(kind: .confirmation, hello: nil, confirmation: value)
    }
}

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

enum PairingNetwork {
    static func runInitiator(connection: NWConnection, localID: String, localName: String,
                             prompt: PairingPromptModel, expectedPeerID: String? = nil,
                             autoConfirm: Bool = false) async throws -> PendingPairing {
        let timeout = pairingTimeout(for: connection)
        defer { timeout.cancel() }
        try await waitUntilReady(connection)
        Log.info("pairDebug: initiator connected")
        guard let spki = TrustStore.shared.ownSPKI() else { throw PairingError.invalidKey }
        let handshake = PairingHandshake(role: .initiator, deviceID: localID,
                                         displayName: localName, identitySPKI: spki)
        try await PairingFraming.send(.hello(handshake.localHello), on: connection)
        let response = try await PairingFraming.receive(on: connection)
        guard response.kind == .hello, let peerHello = response.hello else { throw PairingError.malformedMessage }
        if let expectedPeerID, peerHello.deviceID != expectedPeerID { throw PairingError.identityChanged }
        let result = try handshake.result(peerHello: peerHello)
        let pending = classify(result.pending)
        logReady(pending)
        let accepted: Bool
        if autoConfirm { accepted = true }
        else { accepted = await prompt.request(pending) }
        Log.info("pairDebug: localConfirmation=\(accepted)")
        try await PairingFraming.send(.confirmation(result.confirmation(accepted: accepted)), on: connection)
        guard accepted else { throw PairingError.rejected }
        let reply = try await PairingFraming.receive(on: connection)
        guard reply.kind == .confirmation, let confirmation = reply.confirmation else {
            throw PairingError.malformedMessage
        }
        try result.verify(confirmation)
        Log.info("pairDebug: remoteConfirmation=\(confirmation.accepted)")
        try persist(pending)
        Log.info("pairDebug: trust persisted")
        return pending
    }

    static func runResponder(connection: NWConnection, localID: String, localName: String,
                             prompt: PairingPromptModel, autoConfirm: Bool = false) async throws -> PendingPairing {
        let timeout = pairingTimeout(for: connection)
        defer { timeout.cancel() }
        try await waitUntilReady(connection)
        Log.info("pairDebug: responder connected")
        let request = try await PairingFraming.receive(on: connection)
        guard request.kind == .hello, let peerHello = request.hello else { throw PairingError.malformedMessage }
        guard let spki = TrustStore.shared.ownSPKI() else { throw PairingError.invalidKey }
        let handshake = PairingHandshake(role: .responder, deviceID: localID,
                                         displayName: localName, identitySPKI: spki)
        let result = try handshake.result(peerHello: peerHello)
        let pending = classify(result.pending)
        logReady(pending)
        try await PairingFraming.send(.hello(handshake.localHello), on: connection)
        let accepted: Bool
        if autoConfirm { accepted = true }
        else { accepted = await prompt.request(pending) }
        Log.info("pairDebug: localConfirmation=\(accepted)")
        try await PairingFraming.send(.confirmation(result.confirmation(accepted: accepted)), on: connection)
        guard accepted else { throw PairingError.rejected }
        let reply = try await PairingFraming.receive(on: connection)
        guard reply.kind == .confirmation, let confirmation = reply.confirmation else {
            throw PairingError.malformedMessage
        }
        try result.verify(confirmation)
        Log.info("pairDebug: remoteConfirmation=\(confirmation.accepted)")
        try persist(pending)
        Log.info("pairDebug: trust persisted")
        return pending
    }

    private static func logReady(_ pending: PendingPairing) {
        Log.info("pairDebug: classification=\(String(describing: pending.classification))")
        Log.info("pairDebug: SAS ready")
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
        var pending = pending
        switch TrustPinPolicy.decision(existing: TrustStore.shared.pin(peerID: pending.peerID),
                                       presented: pending.peerSPKI) {
        case .new: pending.classification = .newPeer
        case .match: pending.classification = .rePairSameKey
        case .identityChanged: pending.classification = .identityChanged
        }
        return pending
    }

    /// Runs only after both sides have confirmed the same fresh SAS — trust
    /// is never mutated on the strength of a matching peer ID alone. An
    /// identity change is persisted only because the user explicitly saw and
    /// confirmed that specific warning through to a verified confirmation.
    private static func persist(_ pending: PendingPairing) throws {
        guard TrustStore.shared.setPin(peerID: pending.peerID, spki: pending.peerSPKI,
                                       displayName: pending.peerName,
                                       allowIdentityChange: pending.classification == .identityChanged)
        else { throw PairingError.identityChanged }
        Log.info("deviceUI: knownPeer added peerID=\(pending.peerID)")
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
