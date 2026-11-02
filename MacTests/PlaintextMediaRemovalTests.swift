import XCTest

/// Production media/control/input transport is pinned mTLS only. Port 9000
/// plaintext, the `-host` plaintext override and any TLS→plaintext fallback
/// are gone; these guards keep them from coming back.
final class PlaintextMediaRemovalTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testReceiverHasNoPlaintextListener() throws {
        let receiver = try source("Shared/StreamReceiver.swift")
        XCTAssertFalse(receiver.contains("NWParameters(tls: nil"), "receiver must not open a non-TLS listener")
        XCTAssertFalse(receiver.contains("func startListener"))
        XCTAssertFalse(receiver.contains("requiredLocalEndpoint"), "no loopback-bound listener")
        XCTAssertFalse(receiver.contains("NWParameters.udp"), "no unauthenticated UDP cursor listener")
        XCTAssertTrue(receiver.contains("func startTLSListener"))
    }

    func testSenderCannotRepresentOrDialPlaintext() throws {
        let sender = try source("Mac/MacSender.swift")
        // `SenderTransport`/`TLSSessionConfig` moved to their own file (MT-C1
        // Phase 1) so `MacSenderTransportController` and its unit tests can
        // see them without depending on all of MacSender.swift.
        let transport = try source("Mac/SenderTransport.swift")
        XCTAssertTrue(transport.contains("case tcp(NWEndpoint, tls: TLSSessionConfig)"))
        XCTAssertFalse(sender.contains("tls: nil"))
        XCTAssertFalse(transport.contains("tls: nil"))
        XCTAssertFalse(sender.contains("allowsPlaintext"))
        XCTAssertFalse(sender.contains("port: 9000"))
    }

    func testManualHostOverrideRemoved() throws {
        let app = try source("Mac/OpenSidecarMacApp.swift")
        XCTAssertFalse(app.contains("forKey: \"host\""))
        XCTAssertFalse(app.contains("tls: nil"))
    }

    func testSecureUSBBridgeTargetsTLSPortOnly() throws {
        let bridge = try source("Mac/USBTLSBridge.swift")
        XCTAssertTrue(bridge.contains("WireCrypto.tlsPort"))
        XCTAssertFalse(bridge.contains("9000"))
    }

    func testUSBPairingFailureCopyIsSanitizedAndBounded() throws {
        struct Raw: Error, LocalizedError {
            var errorDescription: String? { String(repeating: "secret-detail ", count: 200) }
        }
        let message = RemotePairingFailure.message(for: Raw())
        XCTAssertLessThan(message.count, 60)
        XCTAssertFalse(message.contains("secret"))
        let app = try source("Mac/OpenSidecarMacApp.swift")
        XCTAssertFalse(app.contains("USB pairing failed: \\(error"))
    }

    func testInputAuthorizationRemainsSeparateFromTransport() throws {
        let sender = try source("Mac/MacSender.swift")
        XCTAssertTrue(sender.contains("inputControl") || sender.contains("InputControl"))
    }
}
