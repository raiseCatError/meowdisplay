import Foundation
import Network
import Security

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
///
/// Pulled out of MacSender.swift (Phase 1 of the MT-C1 transport-isolation
/// design) so `MacSenderTransportController` and its unit tests can
/// reference these types without pulling in all of `MacSender.swift`.
/// Narrow carrier for the single non-Sendable leaf in `TLSSessionConfig`:
/// the `SecIdentity` credential handle. Unchecked is truthful here because
/// the wrapped reference is never mutated after `init` — it's used only as
/// an opaque credential passed straight into `TLSConfigurator`'s Security/
/// Network.framework TLS setup — and this wrapper adds no synchronization
/// and exposes no mutable state of its own.
struct SendableSecIdentity: @unchecked Sendable {
    let value: SecIdentity
}

struct TLSSessionConfig: Sendable {
    let identity: SendableSecIdentity
    let pinnedPeerSPKI: Data
    let peerID: String
}

enum SenderTransport: Sendable {
    // `tls` is REQUIRED: no production or debug path dials plaintext media.
    case tcp(NWEndpoint, tls: TLSSessionConfig)
    // Native usbmuxd dial; nil udid = first device. `tls` is REQUIRED — USB
    // media is only ever reachable through the same pinned mutual-TLS path
    // as LAN/Remote (see USBTLSBridge). There is deliberately no port here:
    // the target is always the receiver's existing trusted TLS listener
    // (WireCrypto.tlsPort), never the legacy plaintext media port.
    case usb(udid: String?, tls: TLSSessionConfig)
}
