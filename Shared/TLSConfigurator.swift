// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Shared but NOT Foundation-only: imports Network, Security, CryptoKit.

import Foundation
import Network
import Security
import CryptoKit

/// Builds pinned mutual-TLS 1.3 `NWProtocolTLS.Options` for both the phone
/// listener and the Mac dialer. Returns nil on any
/// failure — the caller treats that as a hard stop; it must NEVER fall back
/// to plaintext for a pinned peer, and there is no force-unwrap in the
/// identity path.
enum TLSConfigurator {
    /// - identity:    own SecIdentity from TrustStore.ownIdentity()
    /// - pinnedSPKIs: closure returning the current pinned-SPKI set; MUST read
    ///                an in-memory snapshot (TrustStore.allPinnedPeerSPKIs on
    ///                the phone, a captured single-element array on the Mac).
    ///                It is invoked on `queue` during handshakes — Keychain
    ///                I/O in it is forbidden.
    /// - isListener:  true ⇒ additionally require a client certificate.
    /// - queue:       the connection's serial queue; verify block runs here.
    static func mutualTLSOptions(identity: SecIdentity,
                                  pinnedSPKIs: @escaping () -> [Data],
                                  isListener: Bool,
                                  queue: DispatchQueue) -> NWProtocolTLS.Options? {
        guard let secIdentity = sec_identity_create(identity) else {
            Log.info("ERROR: sec_identity_create failed — identity unusable, refusing TLS setup")
            return nil // no crash, no plaintext fallback
        }
        let tls = NWProtocolTLS.Options()
        applyPinnedMutualAuthentication(
            to: tls.securityProtocolOptions, identity: secIdentity,
            pinnedSPKIs: pinnedSPKIs, isListener: isListener, queue: queue)
        return tls
    }

    /// The QUIC twin of `mutualTLSOptions`: QUIC's built-in TLS 1.3 gets the
    /// EXACT same identity, the same client-certificate requirement on the
    /// listener and the same SPKI verify block — there is no QUIC-specific
    /// key, pin or trust store. Additionally:
    ///   * ALPN is fixed to `QUICTransport.alpn`; a peer without it fails
    ///     the handshake (RFC 9001 §8.1) instead of negotiating anything else;
    ///   * session tickets and resumption are disabled, so no PSK ever
    ///     exists to carry 0-RTT early data — every MeowDisplay QUIC
    ///     connection is a full, freshly authenticated 1-RTT handshake, and
    ///     no replay-sensitive control message can arrive as early data.
    /// Returns nil (never a weaker configuration) when the identity is
    /// unusable; the caller then refuses QUIC exactly like TLS.
    static func pinnedQUICOptions(identity: SecIdentity,
                                  pinnedSPKIs: @escaping () -> [Data],
                                  isListener: Bool,
                                  queue: DispatchQueue,
                                  alpn: String = QUICTransport.alpn) -> NWProtocolQUIC.Options? {
        guard let secIdentity = sec_identity_create(identity) else {
            Log.info("ERROR: sec_identity_create failed — identity unusable, refusing QUIC setup")
            return nil
        }
        let quic = NWProtocolQUIC.Options(alpn: [alpn])
        let sec = quic.securityProtocolOptions
        applyPinnedMutualAuthentication(
            to: sec, identity: secIdentity,
            pinnedSPKIs: pinnedSPKIs, isListener: isListener, queue: queue)
        // No 0-RTT: without tickets/resumption there is no pre-shared key a
        // later connection could send early data under.
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        return quic
    }

    /// Shared by TCP/TLS and QUIC so the two can never drift apart.
    private static func applyPinnedMutualAuthentication(to sec: sec_protocol_options_t,
                                                        identity: sec_identity_t,
                                                        pinnedSPKIs: @escaping () -> [Data],
                                                        isListener: Bool,
                                                        queue: DispatchQueue) {
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13) // min == max: downgrade-proof
        sec_protocol_options_set_local_identity(sec, identity)          // both roles present a cert
        if isListener {
            // Without this the listener silently degrades to one-way server
            // auth.
            sec_protocol_options_set_peer_authentication_required(sec, true)
        }
        sec_protocol_options_set_verify_block(sec, { _, sec_trust, complete in
            // Self-signed world: pinning REPLACES chain trust — deliberately
            // no SecTrustEvaluateWithError.
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  let spki = spkiDER(of: leaf) else {
                complete(false)
                return
            }
            // Same-source rule: re-encode through the SAME CryptoKit encoder
            // that produced every pinned value, so pinned == extracted
            // byte-for-byte. Plain Data equality — both operands public,
            // so a constant-time compare is deliberately not needed.
            complete(pinnedSPKIs().contains(spki))
        }, queue)
    }

    /// The pinning representation of a certificate's public key — the same
    /// CryptoKit re-encode every stored pin was produced with.
    static func spkiDER(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let pub = try? P256.Signing.PublicKey(x963Representation: x963) else { return nil }
        return pub.derRepresentation
    }

    /// The authenticated peer's SPKI for a live connection, whichever secure
    /// transport carries it: a TCP connection's TLS metadata, or a QUIC
    /// stream's QUIC metadata (QUIC integrates TLS 1.3, so its handshake
    /// metadata lives on the QUIC protocol, not a separate TLS layer). Nil
    /// when the connection has not finished its handshake.
    static func authenticatedPeerSPKI(of connection: NWConnection) -> Data? {
        let securityMetadata: sec_protocol_metadata_t
        if let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            securityMetadata = tls.securityProtocolMetadata
        } else if let quic = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
            securityMetadata = quic.securityProtocolMetadata
        } else {
            return nil
        }
        var result: Data?
        sec_protocol_metadata_access_peer_certificate_chain(securityMetadata) { certificate in
            guard result == nil else { return }
            let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
            result = spkiDER(of: secCert)
        }
        return result
    }
}
