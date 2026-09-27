// Compiled into both receivers (Mac Receiver, iOS) and the Mac sender (which
// shares Shared/), plus the unit tests. The receiver's QUIC edge: the QUIC
// listener's ownership, every accepted QUIC connection (NWConnectionGroup)
// and the validation of its streams, up to the point where each stream is
// handed to the EXISTING session machinery — the Control stream to
// `ReceiverPipelineActor.handleIncomingConnection` (exactly like a TCP
// connection), Video/Audio to `ReceiverFramePipeline` once that Control
// stream is the adopted session. No second application protocol exists.

import Foundation
import Network

/// QUIC application error handling (PROTOCOL.md §2.4). The documented
/// codes are recorded in a bounded local log line when either side closes a
/// connection for a violation; the connection is then cancelled. v1 does not
/// put the code on the wire: the SDK's `NWProtocolQUIC.Metadata.
/// applicationError` takes an SDK-specific value type whose construction
/// could not be verified against the installed SDK for this change, and a
/// guessed API is not worth the risk for a diagnostic. Closing is what
/// matters for safety, and it never depends on the code.
enum QUICApplicationClose {
    static func mark(_ connection: NWConnection, error: QUICApplicationError) {
        Log.info("quic: closing with application error \(error)")
    }
}

/// Timeouts for not-yet-trusted QUIC work on the receiver.
enum QUICReceiverLimits {
    /// Live QUIC connections (current session + candidates racing to
    /// replace it). A connection that would exceed it is refused outright.
    static let maxLiveGroups = 4
    /// From stream arrival to a complete, valid 8-byte preface.
    static let prefaceTimeout: TimeInterval = 5
    /// From connection acceptance to its Control stream reaching the session
    /// pipeline; a connection that never presents Control is closed.
    static let applicationHandshakeTimeout: TimeInterval = 10
}

/// Lock-protected sole owner of the currently installed QUIC listener's
/// identity plus the shared registry of live QUIC connections — the QUIC
/// twin of `TLSListenerState`, same idiom: plain reference swaps under the
/// lock, `===` identity checks, framework calls only after releasing it.
final class QUICReceiverContext: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NWListener?
    private var listening = false
    private var availabilityObserver: (@Sendable (Bool) -> Void)?
    let groups = QUICReceiverGroupRegistry()

    func hasCurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    func currentListener() -> NWListener? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func install(_ listener: NWListener) {
        lock.lock(); defer { lock.unlock() }
        current = listener
    }

    func isCurrent(_ listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current === listener
    }

    /// A stale callback for a superseded listener never clears the newer one.
    @discardableResult
    func clearIfCurrent(_ listener: NWListener) -> Bool {
        lock.lock()
        let matched = current === listener
        if matched { current = nil }
        lock.unlock()
        if matched { setListening(false) }
        return matched
    }

    /// Cancels the listener; with `closeGroups`, also every live QUIC
    /// connection it accepted — explicit teardown (lock, quit, Forget's
    /// session close) passes true; the post-pairing trust refresh does not,
    /// matching the TLS listener, whose accepted connections also survive a
    /// rebuild (a live session is revoked through the pipeline instead).
    func cancelCurrent(closeGroups: Bool = false) {
        lock.lock()
        let listener = current
        current = nil
        lock.unlock()
        listener?.cancel()
        setListening(false)
        if closeGroups { groups.closeAll(error: nil) }
    }

    /// Whether hello may advertise QUIC: only while a listener is bound.
    func isListening() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listening
    }

    func setListening(_ value: Bool) {
        lock.lock()
        let changed = listening != value
        listening = value
        let observer = availabilityObserver
        lock.unlock()
        if changed { observer?(value) }
    }

    func setAvailabilityObserver(_ observer: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        availabilityObserver = observer
    }
}

/// Every live accepted QUIC connection, bounded by
/// `QUICReceiverLimits.maxLiveGroups`. The pipeline actor retires a group
/// through here whenever it lets go of that group's Control stream, so a
/// QUIC connection can never outlive the session connection it carried.
final class QUICReceiverGroupRegistry: @unchecked Sendable {
    // Invariant: `groups`/`nextID` only under `lock`; no callout while held.
    private let lock = NSLock()
    private var groups: [Int: QUICReceiverGroup] = [:]
    private var nextID = 0
    let maxLiveGroups: Int

    init(maxLiveGroups: Int = QUICReceiverLimits.maxLiveGroups) {
        self.maxLiveGroups = maxLiveGroups
    }

    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return groups.count
    }

    /// Registers a newly accepted connection, or returns nil when the bound
    /// is reached (the caller cancels it — nothing was allocated for it).
    func admit(_ make: (Int) -> QUICReceiverGroup) -> QUICReceiverGroup? {
        lock.lock(); defer { lock.unlock() }
        guard groups.count < maxLiveGroups else { return nil }
        nextID += 1
        let group = make(nextID)
        groups[nextID] = group
        return group
    }

    func release(id: Int) {
        lock.lock(); defer { lock.unlock() }
        groups[id] = nil
    }

    func owner(ofControlStream stream: NWConnection) -> QUICReceiverGroup? {
        lock.lock()
        let all = Array(groups.values)
        lock.unlock()
        return all.first { $0.isControlStream(stream) }
    }

    /// The session let go of `stream` (replaced, dropped, revoked): if it
    /// was a QUIC Control stream, its whole connection closes with it.
    func retire(controlStream stream: NWConnection, error: QUICApplicationError? = nil) {
        owner(ofControlStream: stream)?.close(error)
    }

    /// Forget/Block: every QUIC connection that has not yet handed a Control
    /// stream to the session (so carries no application authority yet) is
    /// closed; handed-off ones are revoked through the pipeline like TCP.
    func closeUnboundGroups(error: QUICApplicationError) {
        lock.lock()
        let all = Array(groups.values)
        lock.unlock()
        for group in all where !group.hasHandedOffControl { group.close(error) }
    }

    func closeAll(error: QUICApplicationError?) {
        lock.lock()
        let all = Array(groups.values)
        lock.unlock()
        for group in all { group.close(error) }
    }
}

/// One accepted QUIC connection on the receiver.
///
/// `@unchecked Sendable` invariant: every mutable field below is read and
/// written only while holding `lock`; no Network.framework call, callback or
/// actor hop happens while it is held (take under the lock, release, then
/// call). The Network.framework objects themselves are only started,
/// cancelled and read from — their own thread-safety covers that.
final class QUICReceiverGroup: @unchecked Sendable {
    let id: Int
    private let group: NWConnectionGroup
    private let registry: QUICReceiverGroupRegistry
    private let queue: DispatchQueue
    private let onControlStream: @Sendable (NWConnection) -> Void
    private let onMediaReady: @Sendable (QUICReceiverGroup) -> Void

    private let lock = NSLock()
    private var channels = QUICChannelRegistry()
    private var streams: [NWConnection] = []
    private var control: NWConnection?
    private var pendingMedia: [(TransportChannel, NWConnection)] = []
    private var closed = false

    init(id: Int, group: NWConnectionGroup, registry: QUICReceiverGroupRegistry, queue: DispatchQueue,
         onControlStream: @escaping @Sendable (NWConnection) -> Void,
         onMediaReady: @escaping @Sendable (QUICReceiverGroup) -> Void) {
        self.id = id
        self.group = group
        self.registry = registry
        self.queue = queue
        self.onControlStream = onControlStream
        self.onMediaReady = onMediaReady
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    var hasHandedOffControl: Bool {
        lock.lock(); defer { lock.unlock() }
        return control != nil
    }

    var controlStream: NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return control
    }

    func isControlStream(_ stream: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return control === stream
    }

    func start() {
        // Weak captures: the registry is what keeps a live connection's
        // owner alive; once closed and released, late callbacks are no-ops.
        let id = self.id
        group.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Log.info("quicListener: connection \(id) failed: \(error)")
                self?.close(nil)
            case .cancelled:
                self?.close(nil)
            default:
                break
            }
        }
        group.newConnectionHandler = { [weak self] stream in
            guard let self else { stream.cancel(); return }
            self.accept(stream)
        }
        group.start(queue: queue)
        #if DEBUG
        Log.info("quicListener: connection \(id) accepted")
        #endif
        queue.asyncAfter(deadline: .now() + QUICReceiverLimits.applicationHandshakeTimeout) { [weak self] in
            guard let self, !self.isClosed, !self.hasHandedOffControl else { return }
            Log.info("quicListener: connection \(id) presented no Control stream in time — closing")
            self.close(.protocolViolation)
        }
    }

    /// A stream the Mac opened. Topology is enforced before anything is
    /// read from it; its channel comes only from its preface.
    func accept(_ stream: NWConnection) {
        lock.lock()
        if closed {
            lock.unlock()
            stream.cancel()
            return
        }
        // The receiver never opens streams, so every incoming stream is
        // sender-initiated; unidirectional streams are refused at the
        // transport (`initialMaxStreamsUnidirectional = 0`).
        let topologyError = channels.beginStream(initiatedBy: .sender)
        if topologyError == nil { streams.append(stream) }
        lock.unlock()
        if let topologyError {
            stream.cancel()
            close(topologyError)
            return
        }
        let id = self.id
        // Read nothing until the accepted stream is `.ready`. A stream that
        // fails first is a TRANSPORT failure of this connection (on iOS the
        // accepted stream flow is still setting up when it is handed to us,
        // and dies with its connection) — never a peer protocol violation.
        stream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isClosed, !self.isRegistered(stream) else { return }
            switch state {
            case .ready:
                #if DEBUG
                Log.info("quicListener: connection \(id) stream ready — reading its preface")
                #endif
                self.readPreface(of: stream)
            case .failed(let error), .waiting(let error):
                self.closeForTransportFailure("stream \(state) before its preface: \(error)")
            default:
                break
            }
        }
        stream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + QUICReceiverLimits.prefaceTimeout) { [weak self] in
            guard let self, !self.isClosed, !self.isRegistered(stream) else { return }
            Log.info("quicListener: connection \(id) stream sent no valid preface in time — closing")
            self.close(.invalidStreamPreface)
        }
    }

    /// Exactly 8 bytes: Network.framework reassembles a split preface, and
    /// nothing past it is consumed here. Only ever issued once per stream,
    /// from its `.ready` transition.
    private func readPreface(of stream: NWConnection) {
        lock.lock()
        let first = !prefaceReads.contains(ObjectIdentifier(stream))
        if first { prefaceReads.insert(ObjectIdentifier(stream)) }
        lock.unlock()
        guard first else { return }
        stream.receive(minimumIncompleteLength: QUICStreamPreface.length,
                       maximumLength: QUICStreamPreface.length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            switch Self.prefaceReadOutcome(data: data, isComplete: isComplete, error: error) {
            case .parsed(let channel):
                self.register(stream, channel: channel)
            case .violation(let violation):
                self.close(violation)
            case .transportFailure(let detail):
                self.closeForTransportFailure("preface read failed: \(detail)")
            }
        }
    }

    enum PrefaceReadOutcome: Equatable {
        case parsed(TransportChannel)
        /// The peer sent bytes that are not a valid preface, or ended the
        /// stream before a whole one: a protocol violation.
        case violation(QUICApplicationError)
        /// The read itself failed (the stream or its connection went away):
        /// a transport failure, reported as such and never as a violation.
        case transportFailure(String)
    }

    /// Pure classification of the preface read's completion.
    static func prefaceReadOutcome(data: Data?, isComplete: Bool, error: NWError?) -> PrefaceReadOutcome {
        if let error { return .transportFailure("\(error)") }
        guard let data, !data.isEmpty else {
            return isComplete ? .violation(.invalidStreamPreface) : .transportFailure("no data")
        }
        guard data.count == QUICStreamPreface.length else { return .violation(.invalidStreamPreface) }
        switch QUICStreamPreface.parse(data) {
        case .parsed(let preface, _): return .parsed(preface.channel)
        case .rejected(let rejection): return .violation(rejection)
        case .needMoreData: return .violation(.invalidStreamPreface)
        }
    }

    /// The connection broke underneath us (not the peer's fault as far as
    /// the protocol is concerned): close it without an application error.
    private func closeForTransportFailure(_ detail: String) {
        Log.info("quicListener: connection \(id) transport failure — \(detail)")
        close(nil)
    }

    private var registeredStreams: [ObjectIdentifier] = []
    /// Streams whose single preface read has been issued (under `lock`).
    private var prefaceReads: Set<ObjectIdentifier> = []

    private func isRegistered(_ stream: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registeredStreams.contains(ObjectIdentifier(stream))
    }

    /// Records a stream whose preface named `channel` (internal only so the
    /// hostless tests can drive topology without a live QUIC handshake).
    func register(_ stream: NWConnection, channel: TransportChannel) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        if let duplicate = channels.register(channel) {
            lock.unlock()
            close(duplicate)
            return
        }
        registeredStreams.append(ObjectIdentifier(stream))
        if channel == .control {
            control = stream
        } else {
            pendingMedia.append((channel, stream))
        }
        lock.unlock()
        if channel == .control {
            // Exactly the TCP path from here: park-or-adopt, hello, identity,
            // admission — all in `ReceiverPipelineActor`.
            onControlStream(stream)
        } else {
            onMediaReady(self)
        }
    }

    /// Media streams validated but not yet attached to the session pipeline.
    /// Taken once; the pipeline attaches them only while this connection's
    /// Control stream is the adopted session connection.
    func takePendingMedia() -> [(TransportChannel, NWConnection)] {
        lock.lock(); defer { lock.unlock() }
        let taken = pendingMedia
        pendingMedia.removeAll()
        return taken
    }

    /// Closes the whole QUIC connection (idempotent), with an application
    /// error code when this side detected a violation.
    func close(_ error: QUICApplicationError?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let allStreams = streams
        let controlStream = control
        streams.removeAll()
        pendingMedia.removeAll()
        lock.unlock()
        registry.release(id: id)
        if let error {
            Log.info("quicListener: closing connection \(id) appError=\(error)")
            if let target = controlStream ?? allStreams.first {
                QUICApplicationClose.mark(target, error: error)
            }
        }
        for stream in allStreams { stream.cancel() }
        group.cancel()
    }
}

/// The receiver's QUIC listener — started and torn down alongside the TLS
/// listener (`StreamReceiver.startTLSListener` / `scheduleTLSListenerRefresh`
/// / `closeSession`), obeying the same pairing suppression and trust refresh.
enum QUICReceiverListener {
    static func startIfNeeded(
        context: QUICReceiverContext, identity: SecIdentity, queue: DispatchQueue,
        pairingSuppressionState: PairingSuppressionState, advertisementState: ReceiverAdvertisementState,
        pipeline: ReceiverPipelineActor, installID: String, advertisedProtocolVersion: Int
    ) {
        guard QUICRuntimeAvailability.isAvailable, !context.hasCurrent(),
              let quic = TLSConfigurator.pinnedQUICOptions(
                identity: identity,
                pinnedSPKIs: { TrustStore.shared.allPinnedPeerSPKIs() },
                isListener: true, queue: queue) else { return }
        // Exactly the three bidirectional sender-opened streams; no
        // unidirectional streams (wrong direction for this protocol).
        quic.initialMaxStreamsBidirectional = QUICChannelRegistry.maxStreams
        quic.initialMaxStreamsUnidirectional = 0
        do {
            let params = listenerParameters(quic: quic)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: QUICTransport.udpPort)!)
            context.install(listener)
            listener.service = quicService(advertisementState: advertisementState, installID: installID,
                                           protocolVersion: advertisedProtocolVersion)
            let groups = context.groups
            listener.newConnectionGroupHandler = { [weak listener] group in
                guard let listener, context.isCurrent(listener) else { group.cancel(); return }
                guard !pairingSuppressionState.isSuppressed() else {
                    Log.info("pairDebug: QUIC media auto-connect suppressed reason=pairingInProgress")
                    group.cancel()
                    return
                }
                let admitted = groups.admit { id in
                    QUICReceiverGroup(
                        id: id, group: group, registry: groups, queue: queue,
                        onControlStream: { stream in
                            Log.info("reconnectDebug: incoming QUIC control stream")
                            Task { await pipeline.handleIncomingConnection(stream) }
                        },
                        onMediaReady: { owner in
                            Task { await pipeline.attachQUICMedia(from: owner) }
                        })
                }
                guard let admitted else {
                    Log.info("quicListener: refused a connection — \(groups.maxLiveGroups) already live")
                    group.cancel()
                    return
                }
                admitted.start()
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    Log.info("reconnectDebug: listenerReady QUIC udpPort=\(QUICTransport.udpPort)")
                    context.setListening(true)
                case .failed(let error):
                    Log.info("QUIC listener failed: \(error)")
                    guard let listener, context.clearIfCurrent(listener) else { return }
                    queue.asyncAfter(deadline: .now() + 1) {
                        guard let identity = TrustStore.shared.ownIdentity() else { return }
                        startIfNeeded(
                            context: context, identity: identity, queue: queue,
                            pairingSuppressionState: pairingSuppressionState,
                            advertisementState: advertisementState, pipeline: pipeline,
                            installID: installID, advertisedProtocolVersion: advertisedProtocolVersion)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            Log.info("QUIC listener could not be created: \(error) — TCP remains available")
        }
    }

    /// The QUIC listener's parameters — the one definition production and
    /// the loopback QUIC tests share.
    ///
    /// Deliberately WITHOUT `allowLocalEndpointReuse` (unlike the TCP
    /// listener, where it only eases re-binding after TIME_WAIT). A QUIC
    /// server demultiplexes every accepted connection by UDP 4-tuple on the
    /// listener's own port; with local-endpoint reuse on, a second binding
    /// of UDP 9001 (a stale listener during a re-arm) is silently allowed,
    /// and on iPhone the listener's new-flow path was observed receiving
    /// datagrams of an already-accepted connection, failing to register a
    /// duplicate flow for that same 4-tuple (NECP ADD_FLOW "File exists"),
    /// and taking the live connection down with it (EINVAL). Without reuse a
    /// re-arm that races an old binding fails with EADDRINUSE and retries
    /// (`startIfNeeded`'s 1 s backoff) instead of sharing the port.
    static func listenerParameters(quic: NWProtocolQUIC.Options) -> NWParameters {
        let params = NWParameters(quic: quic)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = false
        params.serviceClass = .interactiveVideo
        return params
    }

    /// `_meowdisp-q._udp`: `id`/`pv`/`qv` only — a capability HINT, never
    /// trust, never the one-shot `cr` token.
    static func quicService(advertisementState: ReceiverAdvertisementState, installID: String,
                            protocolVersion: Int) -> NWListener.Service {
        var txt = NWTXTRecord()
        for (key, value) in QUICDiscoveryHint.txtFields(installID: installID, protocolVersion: protocolVersion) {
            txt[key] = value
        }
        return NWListener.Service(name: advertisementState.currentServiceName(),
                                  type: QUICTransport.bonjourServiceType, domain: nil, txtRecord: txt)
    }
}

/// Host-side mirror of `ReceiverSessionAdmission.admitted` for the current
/// adoption generation, readable synchronously from `ReceiverFramePipeline`
/// (QUIC media is refused until the connection it belongs to is admitted).
/// Same lock-protected idiom as the other receiver state boxes.
final class ReceiverMediaAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int?
    private var admitted = false

    /// A new connection was adopted at `generation`: nothing admitted yet.
    func begin(generation: Int) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        admitted = false
    }

    func set(admitted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.admitted = admitted
    }

    func isAdmitted(generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return admitted && self.generation == generation
    }
}
