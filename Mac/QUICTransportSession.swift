import Foundation
import Network

/// One pinned-mutual-authenticated QUIC connection (tunnel) from the Mac
/// sender, with its three long-lived reliable streams: Control
/// (bidirectional), Video and Audio (Mac -> receiver).
///
/// Isolation invariant: owned exclusively by `MacSenderTransportController`
/// and touched ONLY on its serial `queue` (the sender's `sender.video`
/// queue). It is deliberately NOT `Sendable` and is never captured by a
/// Network.framework callback: those capture the controller weakly plus the
/// immutable `generation`, hop to `queue`, and look the live session up
/// again — so a callback from a cancelled/superseded group can never touch
/// the current one (see `MacSenderTransportController.currentQUICSession(generation:)`).
final class QUICTransportSession {
    let generation: Int
    let group: NWConnectionGroup
    let dialStartedAt: Date
    private(set) var streams: [TransportChannel: NWConnection] = [:]
    /// This Mac's pin check accepted the receiver's certificate.
    var peerVerifiedAt: Date?
    /// The group finished its QUIC/TLS handshake (pins verified).
    var groupReadyAt: Date?
    /// The Control stream is ready and adopted as the session connection.
    var controlReadyAt: Date?
    /// The authenticated application `hello` was accepted on this session.
    var applicationReadyAt: Date?
    /// A failure was already reported for this session; later callbacks for
    /// the same breakage stay quiet.
    var failureReported = false

    init(generation: Int, group: NWConnectionGroup, dialStartedAt: Date = Date()) {
        self.generation = generation
        self.group = group
        self.dialStartedAt = dialStartedAt
    }

    var control: NWConnection? { streams[.control] }
    var isApplicationReady: Bool { applicationReadyAt != nil }

    func stream(for channel: TransportChannel) -> NWConnection? { streams[channel] }

    func install(_ stream: NWConnection, for channel: TransportChannel) {
        precondition(streams[channel] == nil, "one stream per channel")
        streams[channel] = stream
    }

    /// Cancels every stream and the tunnel. Idempotent.
    func cancel(applicationError: QUICApplicationError? = nil) {
        if let applicationError, let control {
            QUICApplicationClose.mark(control, error: applicationError)
        }
        for stream in streams.values { stream.cancel() }
        group.cancel()
    }
}

/// A QUIC failure as the controller reports it to `MacSender`, which owns
/// the Auto/TCP/QUIC decision (`TransportProtocolSelector`).
struct QUICTransportFailure {
    let error: NWError?
    let failureClass: QUICFailureClass
    /// The session had passed the authenticated application handshake —
    /// i.e. this is a LIVE QUIC failure, not a dial failure.
    let established: Bool
    let detail: String
}
