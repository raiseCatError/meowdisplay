import Foundation

/// Which addresses survive the caps of the cable upgrade (PROTOCOL.md 6.4):
/// the receiver's 12-entry `hello.addrs` list and the sender's 16-dial
/// probe round. Both caps and their limits are unchanged. Under a cap the
/// output is exactly what the old first-come cut produced; over it, the
/// entries a direct cable needs are kept ahead of the ones that cannot
/// carry it, and the kept entries stay in their original order.
enum CableCandidateSelection {
    // MARK: - Receiver: hello.addrs

    static let advertisedAddressLimit = 12

    struct AdvertisedAddress: Equatable, Sendable {
        let interface: String
        let address: String
    }

    /// Deduplicates by address (first occurrence wins, as before) and keeps
    /// at most `limit`. Over the limit the order of preference is:
    /// 1. addresses of `bridge*` interfaces (Thunderbolt Bridge carries
    ///    the host-to-host cable on macOS);
    /// 2. other link-local addresses (fe80::/10, 169.254/16): a bare
    ///    Thunderbolt port or other host-to-host link has nothing else;
    /// 3. everything else (routable addresses, which a cable never uses).
    /// Interface name and address text are all this needs; no lookups.
    static func advertisedAddresses(_ candidates: [AdvertisedAddress],
                                    limit: Int = advertisedAddressLimit) -> [String] {
        var unique: [AdvertisedAddress] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.address).inserted {
            unique.append(candidate)
        }
        guard unique.count > limit else { return unique.map(\.address) }
        return keepByRank(unique, limit: limit) { candidate in
            if candidate.interface.hasPrefix("bridge") { return 0 }
            return isLinkLocal(candidate.address) ? 1 : 2
        }.map(\.address)
    }

    // MARK: - Sender: probe dials

    static let probeCandidateLimit = 16

    struct ProbeCandidate: Equatable, Sendable {
        /// The host to dial: an address, or `fe80::…%scope`.
        let host: String
        /// The local interface a link-local candidate is scoped to.
        let scope: String?
    }

    /// The candidates one probe round dials. Up to `limit` the list is
    /// returned untouched (duplicates included, as before). Over it,
    /// duplicates go first, then the order of preference is:
    /// 1. link-local candidates on a non-Wi-Fi scope, and unscoped
    ///    link-local addresses (the cable);
    /// 2. other direct (unscoped) candidates;
    /// 3. link-local candidates on a Wi-Fi scope, which the probe's
    ///    Wi-Fi prohibition makes undialable.
    /// `wifiScopes` is asked only over the limit.
    static func probeCandidates(_ candidates: [ProbeCandidate], limit: Int = probeCandidateLimit,
                                wifiScopes: () -> Set<String>) -> [ProbeCandidate] {
        guard candidates.count > limit else { return candidates }
        var unique: [ProbeCandidate] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.host.lowercased()).inserted {
            unique.append(candidate)
        }
        guard unique.count > limit else { return unique }
        let wifi = wifiScopes()
        return keepByRank(unique, limit: limit) { candidate in
            // An unscoped link-local address (the cable's 169.254 address)
            // is as likely the cable as a scoped fe80 one.
            guard let scope = candidate.scope else { return isLinkLocal(candidate.host) ? 0 : 1 }
            return wifi.contains(scope) ? 2 : 0
        }
    }

    // MARK: - Shared

    /// Keeps the `limit` best-ranked entries (lower rank first, earlier
    /// entry first within a rank) and returns them in their original order.
    private static func keepByRank<T>(_ items: [T], limit: Int, rank: (T) -> Int) -> [T] {
        let kept = items.indices
            .sorted { lhs, rhs in
                let (l, r) = (rank(items[lhs]), rank(items[rhs]))
                return l != r ? l < r : lhs < rhs
            }
            .prefix(max(0, limit))
        return kept.sorted().map { items[$0] }
    }

    static func isLinkLocal(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.hasPrefix("169.254.") { return true }
        guard lower.count >= 4, lower.hasPrefix("fe"),
              let third = lower.dropFirst(2).first, "89ab".contains(third) else { return false }
        return lower.count == 4 || lower.dropFirst(4).first == ":"
    }
}
