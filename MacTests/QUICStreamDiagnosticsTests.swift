import XCTest
import Network
import Security
import CryptoKit
import X509
import SwiftASN1

/// TEMPORARY diagnostics (removed before merge): what a production-shaped
/// QUIC listener actually receives per stream, under variants of the
/// sender's stream pattern. Logs only; asserts nothing.
final class QUICStreamDiagnosticsTests: XCTestCase {
    private let queue = DispatchQueue(label: "quic.stream.diagnostics")
    private var keychain: SecKeychain?
    private var keychainPath = ""

    override func setUpWithError() throws {
        keychainPath = NSTemporaryDirectory() + "meow-quic-diag-\(UUID().uuidString).keychain"
        let password = UUID().uuidString
        var created: SecKeychain?
        guard SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &created) == errSecSuccess,
              let created else { throw XCTSkip("no keychain") }
        keychain = created
    }

    override func tearDown() {
        if let keychain { SecKeychainDelete(keychain) }
        try? FileManager.default.removeItem(atPath: keychainPath)
    }

    private final class Log2: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let start = Date()
        func add(_ s: String) {
            lock.lock(); lines.append(String(format: "+%.0fms ", Date().timeIntervalSince(start) * 1000) + s); lock.unlock()
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private func identity() throws -> (SecIdentity, Data) {
        // Same construction as QUICSecureTransportTests.makeIdentity.
        let test = QUICSecureTransportTestsIdentityFactory(keychain: keychain!)
        return try test.make()
    }

    private func wait(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    private func run(_ name: String, serverLimits: Bool, payloadWithPreface: Bool, channels: [TransportChannel],
                     bidiLimit: Int = QUICChannelRegistry.maxStreams) throws {
        let (serverID, serverSPKI) = try identity()
        let (clientID, clientSPKI) = try identity()
        let log = Log2()
        let serverOptions = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: serverID, pinnedSPKIs: { [clientSPKI] }, isListener: true, queue: queue))
        if serverLimits {
            serverOptions.initialMaxStreamsBidirectional = bidiLimit
            serverOptions.initialMaxStreamsUnidirectional = 0
        }
        let listener = try NWListener(using: QUICReceiverListener.listenerParameters(quic: serverOptions), on: .any)
        let queue = self.queue
        let holder = Holder()
        listener.newConnectionGroupHandler = { group in
            log.add("server: group accepted")
            group.stateUpdateHandler = { state in log.add("server: group state \(state)") }
            group.newConnectionHandler = { stream in
                let md = stream.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                log.add("server: stream delivered id=\(md.map { String($0.streamIdentifier) } ?? "nil") state=\(stream.state)")
                holder.keep(stream)
                stream.stateUpdateHandler = { state in
                    let md2 = stream.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                    log.add("server: stream id=\(md2.map { String($0.streamIdentifier) } ?? "nil") state \(state)")
                    if case .ready = state {
                        let label = md2.map { String($0.streamIdentifier) } ?? "nil"
                        Self.readAll(stream, label: label, log: log)
                    }
                }
                stream.start(queue: queue)
            }
            holder.keep(group)
            group.start(queue: queue)
        }
        listener.start(queue: queue)
        let deadline = Date().addingTimeInterval(5)
        while listener.state != .ready && Date() < deadline { wait(0.05) }
        log.add("server: listener \(listener.state) port=\(String(describing: listener.port))")
        let clientOptions = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: clientID, pinnedSPKIs: { [serverSPKI] }, isListener: false, queue: queue))
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: listener.port!)),
                                      using: NWParameters(quic: clientOptions))
        group.stateUpdateHandler = { state in
            log.add("client: group state \(state)")
            guard case .ready = state else { return }
            for channel in channels {
                let created: NWConnection? = NWConnection(from: group)
                guard let stream = created else { log.add("client: NWConnection(from:) nil"); return }
                holder.keep(stream)
                stream.stateUpdateHandler = { s in
                    let md = stream.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                    log.add("client: \(channel) id=\(md.map { String($0.streamIdentifier) } ?? "nil") state \(s)")
                }
                stream.start(queue: queue)
                var bytes = QUICStreamPreface(channel: channel).encode()
                if payloadWithPreface { bytes += QUICFrameAssembler.frame(Data("{\"type\":\"x\"}".utf8)) }
                stream.send(content: bytes, completion: .contentProcessed { e in
                    log.add("client: \(channel) sent \(bytes.count)B error=\(String(describing: e))")
                })
            }
        }
        group.newConnectionHandler = { $0.cancel() }
        group.start(queue: queue)
        wait(4)
        print("=== QUICDIAG \(name) ===")
        for l in log.all { print("QUICDIAG \(name) \(l)") }
        group.cancel()
        listener.cancel()
        holder.cancelAll()
        wait(0.3)
    }

    private static func readAll(_ stream: NWConnection, label: String, log: Log2) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, complete, error in
            log.add("server: stream id=\(label) read \(data?.count ?? -1)B first=\(data.map { Array($0.prefix(8)) } ?? []) complete=\(complete) error=\(String(describing: error))")
            if data != nil, error == nil, !complete { readAll(stream, label: label, log: log) }
        }
    }

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var groups: [NWConnectionGroup] = []
        func keep(_ c: NWConnection) { lock.lock(); connections.append(c); lock.unlock() }
        func keep(_ g: NWConnectionGroup) { lock.lock(); groups.append(g); lock.unlock() }
        func cancelAll() {
            lock.lock(); let c = connections; let g = groups; connections = []; groups = []; lock.unlock()
            c.forEach { $0.cancel() }; g.forEach { $0.cancel() }
        }
    }

    func testDiagnoseStreamDelivery() throws {
        try run("A-limits3-prefaceOnly-3streams", serverLimits: true, payloadWithPreface: false,
                channels: [.control, .video, .audio])
        try run("B-limits3-withPayload-3streams", serverLimits: true, payloadWithPreface: true,
                channels: [.control, .video, .audio])
        try run("C-defaultLimits-prefaceOnly-3streams", serverLimits: false, payloadWithPreface: false,
                channels: [.control, .video, .audio])
        try run("D-limits3-prefaceOnly-2streams", serverLimits: true, payloadWithPreface: false,
                channels: [.video, .control])
        try run("E-limits4-prefaceOnly-3streams", serverLimits: true, payloadWithPreface: false,
                channels: [.control, .video, .audio], bidiLimit: 4)
    }
}

/// Identity factory shared with the diagnostics (mirrors QUICSecureTransportTests).
struct QUICSecureTransportTestsIdentityFactory {
    let keychain: SecKeychain

    func make() throws -> (SecIdentity, Data) {
        var cfError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true],
        ] as CFDictionary, &cfError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?,
              let p256 = try? P256.Signing.PublicKey(x963Representation: x963) else { throw XCTSkip("key") }
        let signer = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName("meow-diag-\(UUID().uuidString)") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(p256),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(3600),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
            issuerPrivateKey: signer)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCert = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else { throw XCTSkip("cert") }
        guard SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCert, kSecUseKeychain: keychain] as CFDictionary, nil) == errSecSuccess else { throw XCTSkip("add") }
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(keychain, secCert, &identity) == errSecSuccess, let identity else { throw XCTSkip("identity") }
        return (identity, p256.derRepresentation)
    }
}
