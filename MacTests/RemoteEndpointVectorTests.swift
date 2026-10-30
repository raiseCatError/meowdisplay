import XCTest

/// Remote Access endpoint syntax and the knock frame against the vectors the Kotlin port runs too
/// (fixtures/remote/*.json; AndroidReceiver core RemoteEndpointTest and RemoteKnockFrameTest). If the
/// two sides ever disagree about what an address means, one of these fails.
final class RemoteEndpointVectorTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/remote/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func cases(_ root: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(root[key] as? [[String: Any]])
    }

    private func name(_ error: RemoteEndpointValidation.Error) -> String {
        switch error {
        case .emptyHost: "emptyHost"
        case .invalidHost: "invalidHost"
        case .invalidPort: "invalidPort"
        }
    }

    func testValidateMatchesTheSharedVectors() throws {
        let vectors = try cases(try fixture("endpoint-vectors.json"), "validate")
        XCTAssertGreaterThanOrEqual(vectors.count, 60)
        for c in vectors {
            let label = c["name"] as? String ?? "?"
            let host = try XCTUnwrap(c["host"] as? String, label)
            let port = try XCTUnwrap(c["port"] as? String, label)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], label)
            let result = RemoteEndpointValidation.validate(host: host, port: port)
            if let error = expect["error"] as? String {
                guard case .failure(let actual) = result else { XCTFail("\(label): expected \(error), got \(result)"); continue }
                XCTAssertEqual(name(actual), error, label)
            } else {
                guard case .success(let value) = result else { XCTFail("\(label): expected valid, got \(result)"); continue }
                XCTAssertEqual(value.host, expect["host"] as? String, label)
                XCTAssertEqual(Int(value.port), (expect["port"] as? NSNumber)?.intValue, label)
            }
        }
    }

    func testPairingEndpointMatchesTheSharedVectors() throws {
        let vectors = try cases(try fixture("endpoint-vectors.json"), "pairingEndpoint")
        XCTAssertGreaterThanOrEqual(vectors.count, 10)
        for c in vectors {
            let label = c["name"] as? String ?? "?"
            let host = try XCTUnwrap(c["host"] as? String, label)
            let port = try XCTUnwrap(c["port"] as? String, label)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], label)
            let result = RemotePairingEndpoint.make(host: host, port: port)
            if let error = expect["error"] as? String {
                guard case .failure(let actual) = result else { XCTFail("\(label): expected \(error), got \(result)"); continue }
                XCTAssertEqual(name(actual), error, label)
            } else {
                guard case .success(let endpoint) = result else { XCTFail("\(label): expected valid, got \(result)"); continue }
                XCTAssertEqual(endpoint.host, expect["host"] as? String, label)
                XCTAssertEqual(Int(endpoint.port), (expect["port"] as? NSNumber)?.intValue, label)
            }
        }
    }

    // MARK: - Knock frame

    private func data(hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private func intent(_ wire: String) throws -> SessionInvitationIntent {
        try XCTUnwrap(SessionInvitationIntent(rawValue: wire))
    }

    func testKnockFramesMatchTheSharedBytes() throws {
        let root = try fixture("knock-frame-vectors.json")
        let encode = try cases(root, "encode")
        XCTAssertEqual(encode.count, 2)
        for c in encode {
            let wire = try XCTUnwrap(c["intent"] as? String)
            XCTAssertEqual(RemoteConnectRequestIntent.frame(for: try intent(wire)), data(hex: try XCTUnwrap(c["hex"] as? String)), wire)
        }
    }

    func testTheMacReadsAnythingButOneWellFormedFrameAsAutomatic() throws {
        let decode = try cases(try fixture("knock-frame-vectors.json"), "decode")
        XCTAssertGreaterThanOrEqual(decode.count, 12)
        for c in decode {
            let label = c["name"] as? String ?? "?"
            let hex = try XCTUnwrap(c["hex"] as? String, label)
            let frame: Data? = hex.isEmpty ? nil : data(hex: hex)
            XCTAssertEqual(RemoteConnectRequestIntent.intent(fromFrame: frame),
                           try intent(try XCTUnwrap(c["intent"] as? String, label)), label)
        }
    }
}
