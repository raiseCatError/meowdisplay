import Foundation

/// Which Tailscale endpoints a Mac reports for automatic Remote Access may be kept (Android:
/// TailnetEndpointFilter.kt; both run fixtures/remote/tailnet-endpoint-vectors.json).
///
/// An endpoint is only a routing hint: the pinned mutual-TLS handshake decides who answers. The
/// filter keeps the hints narrow anyway, so a report can never point this device at a LAN or
/// public address, Tailscale's own service address, or another tailnet: only 100.64.0.0/10,
/// fd7a:115c:a1e0::/48 and MagicDNS names (`<host>.<tailnet>.ts.net`). Pure and DNS-free.
enum TailnetEndpointFilter {
    static let maxNames = 2
    static let maxAddresses = 4

    enum Reason: String, Equatable, Sendable {
        /// Not a well-formed name or address.
        case invalid
        /// Well-formed, but not a Tailscale address or MagicDNS name.
        case notTailnet
        /// Tailscale's own service address (100.100.100.100), never a peer.
        case reserved
        /// A MagicDNS name in a tailnet other than the one expected.
        case otherTailnet
        /// Past the per-report cap.
        case overCap
    }

    struct Rejection: Equatable, Sendable {
        /// The value as reported, trimmed.
        let value: String
        let reason: Reason
    }

    struct Result: Equatable, Sendable {
        var names: [String] = []
        var addresses: [String] = []
        /// In the order the values came in: names first, then addresses.
        var rejected: [Rejection] = []
    }

    /// - Parameter tailnet: the expected tailnet's MagicDNS suffix (`tail1234.ts.net`), when known.
    static func filter(names: [String], addresses: [String], tailnet: String? = nil) -> Result {
        var result = Result()
        let suffix = tailnet.map { normalizedName($0) }
        for raw in names {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch name(value, tailnet: suffix) {
            case .failure(let reason):
                result.rejected.append(Rejection(value: value, reason: reason))
            case .success(let normalized):
                if result.names.contains(normalized) { continue }
                if result.names.count >= maxNames {
                    result.rejected.append(Rejection(value: value, reason: .overCap))
                } else {
                    result.names.append(normalized)
                }
            }
        }
        for raw in addresses {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch address(value) {
            case .failure(let reason):
                result.rejected.append(Rejection(value: value, reason: reason))
            case .success(let normalized):
                if result.addresses.contains(normalized) { continue }
                if result.addresses.count >= maxAddresses {
                    result.rejected.append(Rejection(value: value, reason: .overCap))
                } else {
                    result.addresses.append(normalized)
                }
            }
        }
        return result
    }

    // MARK: Names

    private static func normalizedName(_ text: String) -> String {
        var lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }

    private static func name(_ value: String, tailnet: String?) -> Swift.Result<String, Reason> {
        let normalized = normalizedName(value)
        guard normalized.utf8.count <= 253 else { return .failure(.invalid) }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
            else { return .failure(.invalid) }
        }
        // <host>.<tailnet>.ts.net: at least one label in front of the tailnet's own name.
        guard labels.count >= 4, normalized.hasSuffix(".ts.net") else { return .failure(.notTailnet) }
        if let tailnet, !normalized.hasSuffix("." + tailnet) { return .failure(.otherTailnet) }
        return .success(normalized)
    }

    // MARK: Addresses

    private static let tailnetV6Prefix: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]

    private static func address(_ value: String) -> Swift.Result<String, Reason> {
        if value.contains(":") {
            guard let bytes = parseIPv6(value) else { return .failure(.invalid) }
            guard Array(bytes.prefix(6)) == tailnetV6Prefix else { return .failure(.notTailnet) }
            return .success(formatIPv6(bytes))
        }
        guard let bytes = parseIPv4(value) else { return .failure(.invalid) }
        if bytes == [100, 100, 100, 100] { return .failure(.reserved) }
        guard bytes[0] == 100, bytes[1] & 0xC0 == 0x40 else { return .failure(.notTailnet) }
        return .success(bytes.map(String.init).joined(separator: "."))
    }

    /// A canonical dotted quad: four decimal parts, no leading zeros (an address that some parsers
    /// read as octal is no address).
    static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            out.append(value)
        }
        return out
    }

    /// 16 bytes, or nil. No zone ids; an embedded IPv4 tail follows the dotted-quad rules.
    static func parseIPv6(_ text: String) -> [UInt8]? {
        guard !text.contains("%"), text.utf8.count <= 45 else { return nil }
        if let tail = text.split(separator: ":", omittingEmptySubsequences: false).last, tail.contains("."),
           parseIPv4(String(tail)) == nil { return nil }
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// RFC 5952: lowercase hex, no leading zeros, the longest run of two or more zero groups
    /// (the first on a tie) written `::`.
    static func formatIPv6(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let groups = (0..<8).map { Int(bytes[$0 * 2]) << 8 | Int(bytes[$0 * 2 + 1]) }
        var bestStart = -1, bestLength = 0, runStart = -1
        for i in 0...8 {
            if i < 8, groups[i] == 0 {
                if runStart < 0 { runStart = i }
            } else if runStart >= 0 {
                if i - runStart > bestLength { bestStart = runStart; bestLength = i - runStart }
                runStart = -1
            }
        }
        if bestLength < 2 { bestStart = -1 }
        func hex(_ range: Range<Int>) -> String {
            range.map { String(groups[$0], radix: 16) }.joined(separator: ":")
        }
        guard bestStart >= 0 else { return hex(0..<8) }
        return hex(0..<bestStart) + "::" + hex((bestStart + bestLength)..<8)
    }
}
