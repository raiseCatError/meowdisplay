import Foundation

/// Pure, dependency-free validation for a user-entered Remote (Tailscale)
/// endpoint — same shape as `ReconnectPolicy`/`AutoConnectPolicy` so it can
/// be unit tested without SwiftUI or networking. Deliberately does not
/// resolve DNS or require a `100.x` Tailscale address: a MagicDNS name or a
/// normal hostname is valid, and the target machine may be offline (asleep,
/// off Tailscale) at the moment its endpoint is saved.
enum RemoteEndpointValidation {
    enum Error: Swift.Error, Equatable {
        case emptyHost
        case invalidHost
        case invalidPort
    }

    /// Validates and normalizes a host/port pair typed into the Remote
    /// Access editor. Trims incidental whitespace only — never rewrites the
    /// address the user typed.
    static func validate(host rawHost: String, port rawPort: String) -> Result<(host: String, port: UInt16), Error> {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.emptyHost) }
        guard isSyntacticallyValidHost(host) else { return .failure(.invalidHost) }
        guard let port = UInt16(rawPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            return .failure(.invalidPort)
        }
        return .success((host, port))
    }

    /// Accepts IPv4, IPv6 (bracketed or bare), and DNS-style hostnames
    /// (including MagicDNS names like `mac.tailnet-name.ts.net`). This is a
    /// syntax check only — no resolution, no "must look like Tailscale"
    /// requirement. Tailscale is networking, not trust.
    static func isSyntacticallyValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }

        var candidate = host
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
        }

        // IPv4 or IPv6 literal.
        if candidate.contains(":") || isIPv4Literal(candidate) {
            var addr = in6_addr()
            if candidate.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 { return true }
            var addr4 = in_addr()
            if candidate.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 { return true }
            return false
        }

        // Hostname: dot-separated labels of letters/digits/hyphen, no empty
        // labels, no leading/trailing hyphen per label.
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        return true
    }

    private static func isIPv4Literal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
