import Foundation

/// Masks what identifies a person's devices or network before a line reaches a log, so a log
/// attached to a bug report doesn't publish them:
///  - IPv4 addresses keep their first octet ("100.x.x.x" still says Tailscale, "192.x.x.x" a
///    home network); loopback and the unspecified address are left alone;
///  - IPv6 and MAC addresses keep their first group ("fd7a:…");
///  - Tailscale MagicDNS names become "….ts.net";
///  - UUIDs (install and peer IDs) keep their first 8 characters, enough to tell devices
///    apart within one log.
/// Device and Mac names aren't recognizable by shape and stay as they are.
enum LogRedaction {
    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w.]*\d)"#)
    /// Two or more colons with "::", or four or more groups: never a "12:34:56" time.
    private static let ipv6OrMAC = try! NSRegularExpression(
        pattern: #"(?<![\w:.])(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{0,4})*::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?|::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*|[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){3,7})(?:%[\w.]+)?(?![\w:]|\.\d)"#)
    private static let magicDNS = try! NSRegularExpression(
        pattern: #"(?<![\w-])(?:[\w-]+\.)+ts\.net\b"#, options: [.caseInsensitive])
    private static let uuid = try! NSRegularExpression(
        pattern: #"\b([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)

    static func redact(_ line: String) -> String {
        // Cheap exits keep ordinary lines (most of them) off the regex engine.
        guard line.contains(where: { $0 == "." || $0 == ":" || $0 == "-" }) else { return line }
        var out = line
        out = replace(uuid, in: out) { m, s in s(m.range(at: 1)) + "…" }
        out = replace(magicDNS, in: out) { _, _ in "….ts.net" }
        out = replace(ipv6OrMAC, in: out) { m, s in
            let whole = s(m.range)
            let first = whole.prefix { $0 != ":" }
            return (first.isEmpty ? "" : String(first)) + ":…"
        }
        out = replace(ipv4, in: out) { m, s in
            let octets = (1...4).map { s(m.range(at: $0)) }
            guard octets.allSatisfy({ (Int($0) ?? 256) <= 255 }) else { return s(m.range) }
            if octets[0] == "127" || octets.allSatisfy({ $0 == "0" }) { return s(m.range) }
            return "\(octets[0]).x.x.x"
        }
        return out
    }

    private static func replace(_ regex: NSRegularExpression, in text: String,
                                _ make: (NSTextCheckingResult, (NSRange) -> String) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            result += make(m) { ns.substring(with: $0) }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
