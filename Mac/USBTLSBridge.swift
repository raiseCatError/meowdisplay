// USB is a route, not a trust mode. USBTLSBridge exists to turn a usbmux
// tunnel into a plain loopback TCP endpoint that MacSender can dial with the
// EXACT SAME TLSConfigurator/TLSSessionConfig path already used for LAN and
// Remote — see `MacSender.connectTCP`. It contains zero cryptography and
// zero MEOW protocol awareness: it relays opaque bytes only, in both
// directions, between the usbmux tunnel and the one local TCP connection it
// accepts. TLS 1.3 mutual authentication and SPKI/TrustStore pin
// verification happen exactly as they do on LAN, entirely outside this file,
// on the connection that dials the port this bridge exposes.
//
// Network.framework cannot layer NWProtocolTLS onto an NWConnection after
// it is already connected (TLS parameters are fixed at `nw_connection_create`
// and apply from the connection's first byte) — confirmed against the
// Network.framework SDK headers before this file was written. usbmuxd's
// `Connect` verb hands back exactly such an already-connected, non-TLS
// `NWConnection` (see `Usbmux.connect`). This bridge is the smallest way to
// still reuse Network.framework's own TLS engine end-to-end: a local
// loopback splice only ever carries TLS ciphertext, so it can never become a
// second trust boundary.

import Foundation
import Network

/// Bidirectional, bounded, opaque byte relay between two already-started
/// `NWConnection`s. Never inspects content. Tears both legs down the moment
/// either side EOFs, fails to send, fails to receive, or is cancelled.
private final class ByteSplice {
    private let a: NWConnection
    private let b: NWConnection
    private let onTornDown: () -> Void
    private let lock = NSLock()
    private var torn = false

    init(_ a: NWConnection, _ b: NWConnection, onTornDown: @escaping () -> Void) {
        self.a = a
        self.b = b
        self.onTornDown = onTornDown
    }

    func start() {
        pump(from: a, to: b)
        pump(from: b, to: a)
    }

    private func pump(from src: NWConnection, to dst: NWConnection) {
        // 64 KiB: generous enough for a video frame chunk without letting
        // an unbounded amount of ciphertext queue up in this process.
        src.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete || error != nil {
                        self.teardown()
                    } else {
                        self.pump(from: src, to: dst)
                    }
                })
            } else if isComplete || error != nil {
                teardown()
            } else {
                pump(from: src, to: dst)
            }
        }
    }

    func teardown() {
        lock.lock()
        let alreadyTorn = torn
        torn = true
        lock.unlock()
        guard !alreadyTorn else { return }
        a.cancel()
        b.cancel()
        onTornDown()
    }
}

/// Establishes one usbmux tunnel to the receiver's existing trusted TLS
/// media port and exposes it as a one-shot local loopback listener.
///
/// Lifecycle: `start()` dials usbmuxd and binds the local listener, then
/// returns the local port. The listener accepts exactly one connection —
/// cancelling itself synchronously, before any other work, inside that same
/// accept callback — and from then on relays opaque bytes between that one
/// local connection and the usbmux tunnel. `cancel()` tears everything down
/// (idempotent, safe to call at any point in the lifecycle, from any queue).
///
/// A local process that connects to the bridge port before the intended
/// client does would only ever see itself accepted as that one connection
/// (denial-of-service at worst) — it gains no MEOW session, because nothing
/// here performs or implies authentication. That happens entirely on the
/// far side of the splice, in `TLSConfigurator`, unaffected by this file.
final class USBTLSBridge {
    enum Failure: Error, LocalizedError {
        case listenerFailed(Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let error): return "USB secure bridge listener failed: \(error)"
            case .cancelled: return "USB secure bridge was cancelled"
            }
        }
    }

    private let udid: String?
    private let queue: DispatchQueue
    private let dialTunnel: (String?, UInt16, DispatchQueue) async throws -> NWConnection
    private var tunnel: NWConnection?
    private var listener: NWListener?
    private var splice: ByteSplice?
    private var cancelled = false

    /// `dialTunnel` is `Usbmux.dial` in production (always targeting
    /// `WireCrypto.tlsPort` — see `start()`) and an injected fake opaque
    /// tunnel in tests, which is why it has no default here: this file must
    /// not need to see `Usbmux`'s own (heavier) dependency chain to compile,
    /// and every call site stays explicit about what it's dialing.
    init(udid: String?, queue: DispatchQueue,
         dialTunnel: @escaping (String?, UInt16, DispatchQueue) async throws -> NWConnection) {
        self.udid = udid
        self.queue = queue
        self.dialTunnel = dialTunnel
    }

    /// Dials usbmuxd (`WireCrypto.tlsPort` — the receiver's existing trusted
    /// TLS media listener, never the legacy plaintext port) and binds the
    /// local one-shot listener. Must be awaited from `queue`. Throws without
    /// leaving anything running on failure.
    func start() async throws -> NWEndpoint.Port {
        let tunnelConn = try await dialTunnel(udid, WireCrypto.tlsPort, queue)
        let bound: NWEndpoint.Port = try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard !cancelled else {
                    tunnelConn.cancel()
                    cont.resume(throwing: Failure.cancelled)
                    return
                }
                self.tunnel = tunnelConn
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
                let listener: NWListener
                do {
                    listener = try NWListener(using: params)
                } catch {
                    self.tunnel = nil
                    tunnelConn.cancel()
                    cont.resume(throwing: Failure.listenerFailed(error))
                    return
                }
                self.listener = listener
                var resumed = false
                listener.newConnectionHandler = { [weak self] localConn in
                    guard let self else { localConn.cancel(); return }
                    self.queue.async {
                        // One-shot: only ever act on the FIRST accepted
                        // connection, and stop listening before doing
                        // anything else with it.
                        guard self.listener === listener, !self.cancelled else {
                            localConn.cancel()
                            return
                        }
                        listener.cancel()
                        self.listener = nil
                        localConn.start(queue: self.queue)
                        let splice = ByteSplice(localConn, tunnelConn) { [weak self] in
                            self?.cancel()
                        }
                        self.splice = splice
                        splice.start()
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        guard let self, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            guard !resumed, let port = listener.port else { return }
                            resumed = true
                            cont.resume(returning: port)
                        case .failed(let error):
                            if !resumed {
                                resumed = true
                                cont.resume(throwing: Failure.listenerFailed(error))
                            }
                            self.cancel()
                        default:
                            break
                        }
                    }
                }
                listener.start(queue: queue)
            }
        }
        return bound
    }

    /// Tears down whatever part of the bridge is currently alive. Idempotent
    /// and safe to call from any queue, at any point in the lifecycle —
    /// before `start()` returns, mid-splice, or after normal teardown.
    func cancel() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            listener?.cancel()
            listener = nil
            splice?.teardown()
            splice = nil
            tunnel?.cancel()
            tunnel = nil
        }
    }
}
