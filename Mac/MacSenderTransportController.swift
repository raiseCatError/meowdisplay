import Foundation
import Network

// MacSenderTransportController — owns the live NWConnection and its
// Network.framework callback plumbing (viability/path/state handlers, the
// wired-cable upgrade probe, and same-peer migration) on behalf of
// `MacSender`.
//
// `@unchecked Sendable` invariant (Phase 1 of the MT-C1 transport-isolation
// design):
//   * this class exists as an `@unchecked Sendable` ONLY so a stable
//     reference to it may be captured by Network.framework's `@Sendable`
//     callback closures (`stateUpdateHandler`, `pathUpdateHandler`,
//     `viabilityUpdateHandler`, `NWPathMonitor.pathUpdateHandler`);
//   * the conformance does NOT imply internal synchronization — there is no
//     lock and no actor here;
//   * every mutable property below is confined to `queue`, the same serial
//     `sender.video` queue `MacSender` itself runs its connection-handling
//     methods on. `queue` is owned by `MacSender` and handed in at init —
//     this controller never creates a queue of its own;
//   * every method that reads or writes that state validates the
//     confinement with `dispatchPrecondition(.onQueue(queue))` in DEBUG,
//     except the one deliberately reentrant entry point
//     (`stopCurrentConnectionSynchronously()`), documented below;
//   * `MacSender` itself remains non-Sendable and is never captured by any
//     closure this controller installs — cross-boundary effects run through
//     the narrow, synchronous `MacSenderTransportDelegate` instead.
final class MacSenderTransportController: @unchecked Sendable {
    private let queue: DispatchQueue
    private let endpointName: String
    private let statusSink: MacSenderStatusSink
    weak var delegate: MacSenderTransportDelegate?

    // Reentrancy token for `stopCurrentConnectionSynchronously()` — see its
    // doc comment. Not used anywhere else: normal methods rely on the
    // `dispatchPrecondition` calls above, not this key.
    private let queueSpecificKey = DispatchSpecificKey<Void>()

    init(queue: DispatchQueue, endpointName: String, statusSink: MacSenderStatusSink) {
        self.queue = queue
        self.endpointName = endpointName
        self.statusSink = statusSink
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    // MARK: - Queue-confined mutable state (Phase 1)

    private var stopped = false
    private var connection: NWConnection?
    private var connectionReady = false
    private var currentPathDirectLink = false
    private var currentPathUsesWiFi = false
    private var currentRoute: ConnectionRoute?
    private var upgradeTimer: DispatchSourceTimer?
    private var upgradeProbes: [NWConnection] = []
    private var probeRoundGeneration = 0
    private var lastLoggedCandidates: [String] = []
    private var wiredPathMonitor: NWPathMonitor?
    private var wiredPathWasSatisfied: Bool?
    private var dialGeneration = 0

    // MARK: - Read-only accessors used by MacSender's remaining dial/send code

    var currentConnection: NWConnection? {
        dispatchPrecondition(condition: .onQueue(queue))
        return connection
    }

    var isReady: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return connectionReady
    }

    var isDirectLink: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return currentPathDirectLink
    }

    var usesWiFi: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return currentPathUsesWiFi
    }

    var route: ConnectionRoute? {
        dispatchPrecondition(condition: .onQueue(queue))
        return currentRoute
    }

    var currentDialGeneration: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return dialGeneration
    }

    // MARK: - Dial-generation / connection mechanics used by MacSender's
    // still-owned dial code (connectTCP/connectUSB/switchTransport/
    // scheduleReconnect/reportTrustFailure/hello security checks)

    @discardableResult
    func bumpDialGeneration() -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        dialGeneration += 1
        return dialGeneration
    }

    /// Installs a freshly dialed connection as the current one (connectTCP,
    /// after building the `NWConnection`). Does not touch `connectionReady`
    /// — that only flips true once `becomeReady` runs.
    func installConnection(_ conn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection = conn
    }

    /// Cancels and clears the current connection without any of the
    /// broader teardown `stopCurrentConnectionSynchronously()` performs —
    /// the ordinary "we're about to redial" shape used by
    /// scheduleReconnect/switchTransport/reportTrustFailure/the hello
    /// security-rejection paths.
    func cancelAndClearConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        connection?.cancel()
        connection = nil
    }

    func resetPathClassificationForRedial() {
        dispatchPrecondition(condition: .onQueue(queue))
        currentPathDirectLink = false
    }

    func markNotReady() {
        dispatchPrecondition(condition: .onQueue(queue))
        connectionReady = false
    }

    /// Sends a pre-framed payload on the current connection iff one exists
    /// and is ready. Returns whether the send was handed to the connection.
    @discardableResult
    func send(content: Data, completion: @escaping @Sendable (NWError?) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection, connectionReady else { return false }
        connection.send(content: content, completion: .contentProcessed { completion($0) })
        return true
    }

    // MARK: - becomeReady (Phase 1 transport half)

    /// Bookkeeping shared by both transports once a connection is live.
    /// Non-transport effects (session generation, cursor/audio reset,
    /// control-channel read loop) are emitted through `delegate` at the
    /// exact points the pre-Phase-1 `MacSender.becomeReady` performed them
    /// inline, preserving observable ordering even though the code now
    /// lives on both sides of the delegate boundary.
    func becomeReady(_ conn: NWConnection, transport: SenderTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection === conn, !stopped else { return }
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        delegate?.transportSessionBecameReady(on: conn)

        // An established connection whose interface vanishes does NOT get a
        // .failed/.waiting state update — NW keeps it and flags it
        // non-viable. Viability is the prompt unplug signal. Only the
        // direct cable link acts on it.
        conn.viabilityUpdateHandler = { [weak self] viable in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn, !viable, self.currentPathDirectLink else { return }
                self.delegate?.transportLinkDied("path no longer viable")
            }
        }
        conn.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn,
                      let liveTransport = self.delegate?.transportDialingContext().transport else { return }
                self.reportRoute(for: conn, path: path, transport: liveTransport)
            }
        }
        delegate?.transportShouldBeginReceiving(on: conn)
        if let path = conn.currentPath {
            reportRoute(for: conn, path: path, transport: transport)
        }
        // -forceUpgradeProbe YES: dev knob — loopback runs never look like
        // WiFi, so this is the only way to exercise probe+migrate on one Mac.
        if currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe") {
            startUpgradeProbing(transport: transport)
        } else {
            stopUpgradeProbing()   // already off WiFi — nothing better to find
        }
    }

    // MARK: - Route / direct-link classification

    /// (Re)decide whether the live session rides the direct host-to-host
    /// cable. Address shape alone is not enough: the peer must also be a
    /// Mac receiver, the only receiver a TCP cable session can exist with.
    func refreshDirectLinkClassification(for conn: NWConnection, transport: SenderTransport, peerDevice: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection === conn, case .tcp = transport,
              peerDevice == "Mac",
              let path = conn.currentPath else {
            currentPathDirectLink = false
            return
        }
        let wired = TransportSafety.isWiredDirectLinkPath(
            usesWiFi: path.usesInterfaceType(.wifi),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesCellular: path.usesInterfaceType(.cellular),
            interfaceNames: path.availableInterfaces.map(\.name))
        currentPathDirectLink = wired
            && Self.endpointIsLinkLocal(path.remoteEndpoint ?? conn.endpoint)
    }

    private func reportRoute(for conn: NWConnection, path: NWPath, transport: SenderTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection === conn, connectionReady else { return }
        let peerDevice = delegate?.transportPeerDeviceKind()
        refreshDirectLinkClassification(for: conn, transport: transport, peerDevice: peerDevice)

        let names = path.availableInterfaces.map(\.name)
        let isUSBTransport: Bool
        if case .usb = transport {
            isUSBTransport = true
        } else {
            isUSBTransport = false
        }
        let route = ConnectionRoute.classify(
            isUSB: isUSBTransport,
            interfaceNames: names,
            remoteEndpointDescription: String(describing: path.remoteEndpoint ?? conn.endpoint))
        // AWDL is wireless even on systems where its NWPath does not report
        // `.wifi`; keep the existing wired-upgrade probe eligible there.
        currentPathUsesWiFi = path.usesInterfaceType(.wifi) || route == .awdl

        Log.info("connection path to \(endpointName): \(names.joined(separator: ","))"
            + " route=\(route.rawValue) direct=\(currentPathDirectLink)")
        currentRoute = route
        let sink = statusSink
        Task { @MainActor in sink.publishTransportPath(route) }
    }

    /// True when the far end of a connection is a link-local address
    /// (fe80::/10 or 169.254/16). The USB-C/Thunderbolt host-to-host link
    /// hands out nothing else — necessary for "riding the direct cable",
    /// but not sufficient: see refreshDirectLinkClassification.
    private static func endpointIsLinkLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.isLinkLocal
        case .ipv6(let addr): return addr.isLinkLocal
        case .name(let name, _):
            let bare = name.lowercased()
            return bare.hasPrefix("169.254.") || bare.hasPrefix("fe80:")
        @unknown default: return false
        }
    }

    // MARK: - Cable upgrade (PROTOCOL.md 6.4)

    /// Arm the periodic probe. Cheap when there is nothing to find: with no
    /// advertised addresses, or on the USB transport, it never fires a dial.
    private func startUpgradeProbing(transport: SenderTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        lastLoggedCandidates = []
        upgradeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in self?.probeForCablePathUsingLiveContext() }
        timer.resume()
        upgradeTimer = timer
        wiredPathMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        wiredPathWasSatisfied = nil
        // The handler also fires once at start with the current state; only
        // a transition to satisfied means a cable was just plugged.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                let satisfied = path.status == .satisfied
                defer { self.wiredPathWasSatisfied = satisfied }
                guard satisfied, self.wiredPathWasSatisfied == false else { return }
                Log.info("local wired path appeared — probing cable paths now")
                self.probeForCablePathUsingLiveContext(force: true)
            }
        }
        monitor.start(queue: queue)
        wiredPathMonitor = monitor
    }

    private func stopUpgradeProbing() {
        dispatchPrecondition(condition: .onQueue(queue))
        upgradeTimer?.cancel()
        upgradeTimer = nil
        wiredPathMonitor?.cancel()
        wiredPathMonitor = nil
        wiredPathWasSatisfied = nil
        probeRoundGeneration += 1   // orphan any pending sweep
        upgradeProbes.forEach { $0.cancel() }
        upgradeProbes.removeAll()
    }

    /// Timer/monitor callbacks fire with no per-call context of their own —
    /// fetch the live transport/peer-address set from `MacSender` through
    /// the narrow delegate accessor right before probing, exactly as the
    /// pre-Phase-1 code read `self.transport`/`self.peerAddrs` directly.
    private func probeForCablePathUsingLiveContext(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let context = delegate?.transportDialingContext() else { return }
        probeForCablePath(transport: context.transport, peerAddrs: context.peerAddrs, force: force)
    }

    /// One probe round: dial every candidate (receiver address × local
    /// interface for link-local IPv6) with WiFi forbidden. mDNS resolution
    /// stalls under interface restrictions; literal addresses do not.
    func probeForCablePath(transport: SenderTransport, peerAddrs: [String], force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped, connectionReady,
              currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe"),
              case .tcp = transport, !peerAddrs.isEmpty else { return }
        if force {
            upgradeProbes.forEach { $0.cancel() }
            upgradeProbes.removeAll()
        } else {
            guard upgradeProbes.isEmpty else { return }   // a round is still in flight
        }

        var candidates: [NWEndpoint.Host] = []
        var linkLocal: [NWEndpoint.Host] = []
        let scopes = Self.candidateInterfaceNames()
        for addr in peerAddrs {
            if addr.lowercased().hasPrefix("fe80:") {
                for iface in scopes {
                    linkLocal.append(NWEndpoint.Host("\(addr)%\(iface)"))
                }
            } else {
                candidates.append(NWEndpoint.Host(addr))
            }
        }
        candidates.append(contentsOf: linkLocal)
        guard !candidates.isEmpty else { return }
        let candidateNames = candidates.prefix(16).map { "\($0)" }
        if candidateNames != lastLoggedCandidates {
            lastLoggedCandidates = candidateNames
            Log.info("probing \(candidateNames.count) candidate cable paths"
                     + " (direct \(candidates.count - linkLocal.count),"
                     + " fe80 scopes \(scopes.joined(separator: ","))) — repeats every 10s")
        }
        probeRoundGeneration += 1
        let round = probeRoundGeneration

        for host in candidates.prefix(16) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            guard case .tcp(_, let config) = transport,
                  let tlsOptions = TLSConfigurator.mutualTLSOptions(
                    identity: config.identity.value,
                    pinnedSPKIs: { [config.pinnedPeerSPKI] },
                    isListener: false, queue: queue) else { continue }
            let params = NWParameters(tls: tlsOptions, tcp: tcp)
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
            let probePort = NWEndpoint.Port(rawValue: WireCrypto.tlsPort)!
            let probe = NWConnection(host: host, port: probePort, using: params)
            upgradeProbes.append(probe)
            probe.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard self.upgradeProbes.contains(where: { $0 === probe }) else { return }
                    switch state {
                    case .ready:
                        if let path = probe.currentPath, !path.usesInterfaceType(.wifi),
                           let liveTransport = self.delegate?.transportDialingContext().transport {
                            self.migrate(to: probe, transport: liveTransport)
                        } else {
                            self.upgradeProbes.removeAll { $0 === probe }
                            probe.cancel()
                        }
                    case .failed, .waiting:
                        self.upgradeProbes.removeAll { $0 === probe }
                        probe.cancel()
                    default: break
                    }
                }
            }
            probe.start(queue: queue)
        }
        // Sweep stragglers so the next round starts clean. Generation-gated:
        // a forced round may have replaced this one, and the old sweep must
        // not cancel the new round's probes mid-dial.
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.probeRoundGeneration == round else { return }
            self.upgradeProbes.forEach { $0.cancel() }
            self.upgradeProbes.removeAll()
        }
    }

    /// Swap the live session onto the probed connection. Same shape as a
    /// reconnect: the receiver parks the newcomer, adopts it on our first
    /// bytes, and the abandoned WiFi socket's EOF is ignored as stale.
    ///
    /// NOTE: this handler contains no TLS/trust-failure branch — the probe
    /// connection's TLS configuration/pinning is set up identically to the
    /// primary dial in `probeForCablePath`; a trust failure here surfaces as
    /// `.failed`/`.waiting` exactly like any other transport failure, same
    /// as before Phase 1.
    private func migrate(to conn: NWConnection, transport: SenderTransport) {
        dispatchPrecondition(condition: .onQueue(queue))
        let names = conn.currentPath?.availableInterfaces.map(\.name)
            .joined(separator: ",") ?? "?"
        Log.info("cable path answered (\(names)) — migrating the session off WiFi")
        // Same reasoning as switchTransport: the underlying connection is
        // being replaced, so any held hardware key must not survive it.
        delegate?.transportCancelActiveInput()
        upgradeProbes.removeAll { $0 === conn }
        stopUpgradeProbing()
        dialGeneration += 1   // a redial in flight must not clobber this
        // Detach the old connection's handler BEFORE cancelling: its
        // .cancelled callback arrives after becomeReady below and would
        // reset connectionReady, silently blackholing every send on the
        // migrated connection.
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                switch state {
                case .failed(let error):
                    Log.info("connection failed: \(error)")
                    self.delegate?.transportSessionInvalidated(reason: "connectionFailed")
                    self.delegate?.transportLinkDied("failed: \(error)")
                case .waiting(let error):
                    Log.info("connection waiting: \(error) — will retry")
                    self.delegate?.transportSessionInvalidated(reason: "connectionWaiting")
                    self.delegate?.transportLinkDied("waiting: \(error)")
                case .cancelled:
                    self.delegate?.transportSessionInvalidated(reason: "connectionCancelled")
                default: break
                }
            }
        }
        becomeReady(conn, transport: transport)
    }

    /// Local zones a link-local probe could ride: interfaces that are up,
    /// not loopback, and hold a link-local IPv6 address of their own.
    private static func candidateInterfaceNames() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("anpi") { continue }
            let isLinkLocal = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var a = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &a) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
            }
            guard isLinkLocal else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    // MARK: - Reconnect mechanism (connection identity only; policy stays
    // in MacSender per the accepted design)

    @discardableResult
    func resetForRedial() -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        currentPathDirectLink = false
        dialGeneration += 1
        connection?.cancel()
        connection = nil
        return dialGeneration
    }

    /// Cancels the current connection WITHOUT clearing it — matches the
    /// pre-Phase-1 trust-failure/security-rejection sites, which cancel but
    /// deliberately leave `connection` non-nil (the session is ending via
    /// `stopped`/`onTrustFailure`, not redialing).
    func cancelConnectionWithoutClearing() {
        dispatchPrecondition(condition: .onQueue(queue))
        connection?.cancel()
    }

    var isUpgradeProbingActive: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return upgradeTimer != nil
    }

    func resetForTransportSwitch() {
        dispatchPrecondition(condition: .onQueue(queue))
        currentPathDirectLink = false
        dialGeneration += 1
        connection?.cancel()
        connection = nil
        stopUpgradeProbing()
    }

    // MARK: - Any-context send (Phase 1 hardening, MT-C1 CR2)

    /// Sends a pre-framed payload iff a ready connection exists — same
    /// semantics as `send(content:completion:)` above, but safe to call
    /// from ANY thread or Task, not just `queue`.
    ///
    /// `MacSender`'s JSON/media send helpers historically read
    /// `connection`/`connectionReady` directly with no queue confinement at
    /// all, so callers reached from ScreenCaptureKit's async setup chain
    /// (`start()` → `startCapture` → `setupEncoder` → `sendStreamCodecState`,
    /// which runs on the Swift cooperative Task executor and never hops onto
    /// `queue`) worked only by accident — a plain optional/Bool read
    /// tolerates being raced, `NWConnection.send` is itself thread-safe.
    /// Now that this state is confined behind a DEBUG
    /// `dispatchPrecondition`, such a caller must hop onto `queue` first
    /// instead of touching `currentConnection`/`isReady` itself.
    ///
    /// Same reentrancy technique as `stopCurrentConnectionSynchronously()`:
    /// already on `queue`, this runs inline — identical to calling
    /// `send(content:completion:)` directly, so every existing on-queue
    /// caller keeps its exact synchronous enqueue-order relative to other
    /// `queue`-confined work. Off `queue`, it hops once via `queue.async` —
    /// fire-and-forget, since no caller here ever awaited the pre-Phase-1
    /// synchronous read's result either.
    func sendFromAnyContext(content: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            _ = send(content: content, completion: completion)
        } else {
            queue.async { [weak self] in
                _ = self?.send(content: content, completion: completion)
            }
        }
    }

    // MARK: - STOP-B: reentrancy-safe synchronous stop

    /// Cancels and clears the current connection and its transport-owned
    /// bookkeeping, synchronously relative to the caller — `MacSender.stop()`
    /// must observe `connection == nil` before it returns, exactly as the
    /// pre-Phase-1 code did by touching `connection` directly on the
    /// MainActor.
    ///
    /// Safe to call from any thread: off `queue` it does a bounded
    /// `queue.sync`; called reentrantly from `queue` itself (a future
    /// caller already inside a `queue`-confined method) it runs inline
    /// instead of self-deadlocking on `queue.sync`. The queue-confined body
    /// deliberately calls no delegate method, touches no MainActor state and
    /// posts to no `statusSink` — it does only the teardown safe to run
    /// under `queue.sync` with no risk of blocking on the very thread that
    /// might be waiting for it.
    func stopCurrentConnectionSynchronously() {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopCurrentConnectionOnQueue()
        } else {
            queue.sync { stopCurrentConnectionOnQueue() }
        }
    }

    private func stopCurrentConnectionOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        connection?.cancel()
        connection = nil
        upgradeTimer?.cancel()
        upgradeTimer = nil
        wiredPathMonitor?.cancel()
        wiredPathMonitor = nil
        probeRoundGeneration += 1
        upgradeProbes.forEach { $0.cancel() }
        upgradeProbes.removeAll()
    }
}

/// Semantic effects `MacSenderTransportController` reports back to
/// `MacSender` at the exact points the pre-Phase-1 `becomeReady`/`migrate`/
/// state-handler code performed this work inline. Every method here is
/// called synchronously on `sender.video` — never hopped to another queue,
/// never re-entered. Implementations must not block: the controller may be
/// mid-callback from Network.framework when they run.
protocol MacSenderTransportDelegate: AnyObject {
    /// The authoritative (MacSender-owned) session/generation bookkeeping —
    /// `authenticatedSession.beginTransport()`, cursor/audio reset, watchdog
    /// grace-window reset — that must land at the exact instant a
    /// connection is adopted. Runs after the controller has already flipped
    /// `isReady` true and before it installs the viability/path handlers or
    /// begins receiving, matching the ordering `becomeReady` used before
    /// Phase 1.
    func transportSessionBecameReady(on connection: NWConnection)
    /// Starts the control-channel read loop (`receiveControl`). Kept on
    /// `MacSender` since it parses the wire protocol, including the
    /// security-sensitive `hello` handshake — not transport mechanism.
    func transportShouldBeginReceiving(on connection: NWConnection)
    /// A live route changed (already classified/logged by the controller);
    /// forwarded here only for callers that still want it as an effect
    /// (currently none beyond the `statusSink` publish the controller does
    /// itself) — kept for parity with a future Phase that needs it.
    func transportPathChanged(_ route: ConnectionRoute?)
    /// The transport-owned identity invalidation point a `.failed`/
    /// `.waiting`/`.cancelled` transition (migrate's handler) used to call
    /// `invalidateApplicationSession(reason:)` for, inline.
    func transportSessionInvalidated(reason: String)
    /// The direct-cable-link-death / "treat like any other drop" decision
    /// point — forwards to the unchanged, MacSender-owned `linkDied(_:)`.
    func transportLinkDied(_ detail: String)
    /// A connection identity is about to be replaced (migrate) — cancel any
    /// input a stale connection was holding, exactly as `migrate(to:)` did
    /// inline via `inputInjector?.cancelActiveInput()`.
    func transportCancelActiveInput()
    /// `lastHello?.device`, read fresh for direct-link classification.
    func transportPeerDeviceKind() -> String?
    /// The live `transport`/`peerAddrs` MacSender currently holds, read
    /// fresh by the probe timer/wired-path-monitor callbacks, which have no
    /// per-call context of their own.
    func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String])
}
