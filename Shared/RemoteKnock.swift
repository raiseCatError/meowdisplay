import Foundation
import Network

/// How a Remote Access knock ended (Android: `KnockResult` in RemoteKnock.kt). The recovery policy
/// decides from this whether to try again; the security failures end a run for good.
enum RemoteKnockResult: Equatable, Sendable {
    /// The pinned Mac took the frame.
    case delivered
    /// The Mac at the address is this device's pinned Mac, and it refused this device's
    /// certificate: it no longer trusts it.
    case notAccepted
    /// Someone else's key answered at the saved address: another paired Mac (named when known)
    /// or an unknown one. Never retried.
    case identityMismatch(otherPeerID: String?)
    case timedOut
    case refused
    case unreachable
    case dnsFailed
    case failed
    case cancelled

    var isSecurityFailure: Bool {
        if case .identityMismatch = self { return true }
        return self == .notAccepted
    }
}

/// The pure part of a knock's outcome, tested without a network.
enum RemoteKnockClassifier {
    /// Why the connection ended, reduced to what classification needs.
    enum Ending: Equatable, Sendable {
        /// After the frame went out, the Mac closed (or sent anything): it read the frame.
        case closedAfterFrame
        case deadline
        case cancelled
        case tls
        case dns
        case posix(Int32)
        case other
    }

    static func ending(for error: NWError) -> Ending {
        switch error {
        case .tls: return .tls
        case .dns: return .dns
        case .posix(let code): return .posix(code.rawValue)
        default: return .other
        }
    }

    /// - Parameters:
    ///   - frameSent: the intent frame was handed to TLS without error.
    ///   - presented: the key the answering side presented, if the handshake got that far.
    ///   - expected: this Mac's pin.
    ///   - otherPeer: the paired peer a presented key belongs to, if any.
    static func classify(_ ending: Ending, frameSent: Bool, presented: Data?, expected: Data,
                         otherPeer: (Data) -> String? = { _ in nil }) -> RemoteKnockResult {
        if let presented, presented != expected { return .identityMismatch(otherPeerID: otherPeer(presented)) }
        switch ending {
        case .cancelled: return .cancelled
        case .closedAfterFrame: return .delivered
        case .deadline: return frameSent ? .delivered : .timedOut
        case .tls:
            // TLS 1.3: the client can see the handshake done before the Mac has checked this
            // device's certificate; an alert after that, from the pinned Mac, is its refusal.
            return presented == expected ? .notAccepted : .failed
        default:
            // The frame left: an untidy close afterwards doesn't undo that (Android: IOException after write).
            if frameSent { return .delivered }
            switch ending {
            case .dns: return .dnsFailed
            case .posix(ECONNREFUSED): return .refused
            case .posix(EHOSTUNREACH), .posix(ENETUNREACH), .posix(ENETDOWN): return .unreachable
            case .posix(ETIMEDOUT): return .timedOut
            default: return .failed
            }
        }
    }
}

/// One knock: pinned mutual TLS to the Mac's connect-request listener, one intent frame, then
/// wait for the Mac to close (or refuse this device), within `deadline`. Never trusts what the
/// address presents; it only reports it.
final class RemoteKnock: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var frameSent = false
    private var presented: Data?
    private var connection: NWConnection?
    private let expected: Data
    private let otherPeer: @Sendable (Data) -> String?
    private let completion: @Sendable (RemoteKnockResult) -> Void

    private init(expected: Data, otherPeer: @escaping @Sendable (Data) -> String?,
                 completion: @escaping @Sendable (RemoteKnockResult) -> Void) {
        self.expected = expected
        self.otherPeer = otherPeer
        self.completion = completion
    }

    /// Starts a knock. `makeTLS` builds the pinned client options, passing the observer this
    /// knock uses to record the presented key. Returns the knock (to cancel it).
    @discardableResult
    static func start(host: String, port: UInt16, frame: Data, expected: Data,
                      makeTLS: (@escaping @Sendable (Data?) -> Void) -> NWProtocolTLS.Options?,
                      queue: DispatchQueue, deadline: TimeInterval = 8,
                      otherPeer: @escaping @Sendable (Data) -> String? = { _ in nil },
                      completion: @escaping @Sendable (RemoteKnockResult) -> Void) -> RemoteKnock {
        let knock = RemoteKnock(expected: expected, otherPeer: otherPeer, completion: completion)
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let tls = makeTLS({ key in knock.record(presented: key) }) else {
            queue.async { knock.finish(.other) }
            return knock
        }
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), using: params)
        knock.lock.lock(); knock.connection = connection; knock.lock.unlock()
        // The handlers hold the knock until it finishes (`finish` drops the connection and its
        // handler), so a caller may fire and forget.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { knock.finish(RemoteKnockClassifier.ending(for: error)); return }
                    knock.markSent()
                    // The Mac closes once it has read the frame, or alerts if it refuses this device.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, error in
                        knock.finish(error.map(RemoteKnockClassifier.ending(for:)) ?? .closedAfterFrame)
                    }
                })
            case .waiting(let error), .failed(let error):
                knock.finish(RemoteKnockClassifier.ending(for: error))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + deadline) { knock.finish(.deadline) }
        return knock
    }

    func cancel() { finish(.cancelled) }

    private func record(presented key: Data?) {
        lock.lock(); presented = key; lock.unlock()
    }

    private func markSent() {
        lock.lock(); frameSent = true; lock.unlock()
    }

    private func finish(_ ending: RemoteKnockClassifier.Ending) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = RemoteKnockClassifier.classify(ending, frameSent: frameSent, presented: presented,
                                                    expected: expected, otherPeer: otherPeer)
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        completion(result)
    }
}
