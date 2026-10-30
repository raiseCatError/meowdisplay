import CryptoKit
import Foundation

// Same-Mac login sessions (opt-in). With Fast User Switching several people
// can be logged in to one Mac at once, each running their own MeowDisplay
// with their own identity, pairings and settings. Each one advertises
// `_opendisplay-mac-pair._tcp` under the Mac's name, so a receiver's Nearby
// list used to show indistinguishable "Family MacBook", "Family MacBook (2)"
// rows. A sender whose user opted in adds four TXT hints so receivers can
// show one Mac with its sessions:
//
//   hg  host group: an opaque digest of the Mac's local host name, the same
//       for every session on that Mac (the name itself is already public:
//       mDNS publishes it). Grouping only; never identity or trust.
//   hn  the Mac's own name, for the group heading.
//   sl  the session label the user chose (never the account name).
//   ss  `a` while this login session is on the console, `i` while it is
//       switched out (it can't capture or take input then).
//
// Everything in a TXT record is unauthenticated. These fields only arrange
// and label the list: pairing, pins, approval and input stay per session
// and keyed by the pinned install id exactly as for separate Macs.

enum SessionDiscoveryTXT {
    static let hostGroup = "hg"
    static let hostName = "hn"
    static let sessionLabel = "sl"
    static let sessionState = "ss"

    /// Longest label a sender advertises or a receiver shows.
    static let maximumLabelLength = 32
    static let maximumHostNameLength = 63
}

/// Whether a login session can share right now.
enum MacLoginSessionAvailability: String, Equatable, Sendable {
    /// On the console: can capture and take input.
    case available = "a"
    /// Logged in but switched out (Fast User Switching).
    case switchedOut = "i"
}

/// What one opted-in sender session advertises.
struct SenderSessionAdvertisement: Equatable, Sendable {
    let hostGroup: String
    let hostName: String
    let sessionLabel: String
    var availability: MacLoginSessionAvailability

    /// Nil unless the user opted in with a usable label and the Mac has a
    /// local host name to group by.
    init?(hostName: String, localHostName: String?, sessionLabel: String?,
          availability: MacLoginSessionAvailability) {
        guard let label = SenderSessionAdvertisement.normalizedLabel(sessionLabel),
              let localHostName, let group = Self.hostGroup(localHostName: localHostName) else { return nil }
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostGroup = group
        self.hostName = String((host.isEmpty ? "Mac" : host).prefix(SessionDiscoveryTXT.maximumHostNameLength))
        self.sessionLabel = label
        self.availability = availability
    }

    /// The same digest on every session of one Mac, without any session
    /// having to share a file or ask a privileged helper: every login
    /// session reads the same system-wide local host name.
    static func hostGroup(localHostName: String) -> String? {
        let name = localHostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("meowdisplay.hostgroup.v1|\(name)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Trimmed, non-empty, at most `maximumLabelLength` characters.
    static func normalizedLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(SessionDiscoveryTXT.maximumLabelLength))
    }

    var txtFields: [String: String] {
        [
            SessionDiscoveryTXT.hostGroup: hostGroup,
            SessionDiscoveryTXT.hostName: hostName,
            SessionDiscoveryTXT.sessionLabel: sessionLabel,
            SessionDiscoveryTXT.sessionState: availability.rawValue,
        ]
    }

    /// The Bonjour instance name and the name this session pairs under:
    /// distinct per session, so neither mDNS renaming ("Mac (2)") nor a
    /// receiver's paired list mixes two people's sessions up.
    var displayName: String { Self.displayName(hostName: hostName, sessionLabel: sessionLabel) }

    static func displayName(hostName: String, sessionLabel: String) -> String {
        // A DNS-SD instance name is at most 63 UTF-8 bytes.
        var name = "\(hostName) — \(sessionLabel)"
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }
}

/// One Mac sender a receiver discovered, as `NearbyMacDirectory` reads it.
struct NearbyMacSession: Equatable, Sendable, Identifiable {
    /// The advertised install id (`id`), the key pins and policy use; nil
    /// for a sender that advertises none.
    let installID: String?
    /// Bonjour instance name: unique among the results of one browse, so
    /// it maps a row back to the result to pair or connect with.
    let serviceName: String
    /// The opted-in session label, nil for an ordinary sender.
    let sessionLabel: String?
    let availability: MacLoginSessionAvailability
    /// The label to show in a group; disambiguated when two sessions on one
    /// Mac chose the same label.
    var rowTitle: String
    /// The Mac says macOS blocks its outgoing connections to devices (`lnd`, Local Network
    /// privacy), so Connect can't complete until that's allowed on the Mac. Unauthenticated: it
    /// only explains a wait, never hides or trusts a Mac.
    var localNetworkBlocked = false

    var id: String { installID ?? "service:\(serviceName)" }
}

/// One physical Mac (or one ordinary sender) in a receiver's Nearby list.
struct NearbyMacGroup: Equatable, Sendable, Identifiable {
    /// The host group for opted-in sessions, otherwise the session's own id.
    let id: String
    let title: String
    let sessions: [NearbyMacSession]
    /// True when the heading names a Mac with several login sessions.
    var isMultiSession: Bool { sessions.count > 1 }
}

/// Builds the receiver's Nearby list from discovery results. Pure, so every
/// platform (iOS, the Mac receiver, Android) groups the same way.
enum NearbyMacDirectory {
    struct Entry: Equatable, Sendable {
        let serviceName: String
        let txt: [String: String]
    }

    static func groups(from entries: [Entry]) -> [NearbyMacGroup] {
        var seen = Set<String>()
        var grouped: [String: (title: String, sessions: [NearbyMacSession])] = [:]
        var order: [String] = []
        for entry in entries {
            // One row per install: the same sender found on two interfaces
            // (or IPv4 and IPv6) is still one sender. A sender without a
            // usable id (older builds) is listed as before, by its name.
            let installID = entry.txt["id"].flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
            guard seen.insert(installID ?? "service:\(entry.serviceName)").inserted else { continue }
            // Session hints only count next to an install id: grouping
            // without one would have nothing to keep the sessions apart.
            let hint = installID == nil ? nil : SessionHint(txt: entry.txt)
            let session = NearbyMacSession(
                installID: installID, serviceName: entry.serviceName, sessionLabel: hint?.label,
                availability: hint?.availability ?? .available,
                rowTitle: hint?.label ?? entry.serviceName,
                localNetworkBlocked: entry.txt["lnd"]?.trimmingCharacters(in: .whitespaces) == "1")
            // The group is the digest AND the name together: an
            // advertisement (it is unauthenticated) that copies a Mac's
            // digest under another name forms its own row instead of
            // renaming that Mac's heading or slipping under it. One that
            // copies both still only adds an unpaired row there, which pairs
            // only through its own code like any nearby Mac.
            let key = hint.map { "hg:\($0.group)|\($0.hostName.lowercased())" } ?? session.id
            if grouped[key] == nil {
                grouped[key] = (hint?.hostName ?? entry.serviceName, [])
                order.append(key)
            }
            grouped[key]?.sessions.append(session)
        }
        return order.compactMap { key in
            guard let group = grouped[key] else { return nil }
            let sessions = disambiguated(group.sessions.sorted { a, b in
                let order = a.rowTitle.localizedCaseInsensitiveCompare(b.rowTitle)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            })
            // A single opted-in session reads as one Mac row: "Mac — Alex".
            if sessions.count == 1, let only = sessions.first, let label = only.sessionLabel {
                var single = only
                single.rowTitle = SenderSessionAdvertisement.displayName(hostName: group.title, sessionLabel: label)
                return NearbyMacGroup(id: key, title: single.rowTitle, sessions: [single])
            }
            return NearbyMacGroup(id: key, title: group.title, sessions: sessions)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Two people may pick the same label; the rows must still differ.
    private static func disambiguated(_ sessions: [NearbyMacSession]) -> [NearbyMacSession] {
        var counts: [String: Int] = [:]
        return sessions.map { session in
            var session = session
            let key = session.rowTitle.lowercased()
            counts[key, default: 0] += 1
            if let count = counts[key], count > 1 { session.rowTitle += " (\(count))" }
            return session
        }
    }

    /// The four hints, accepted only when well formed. Anything malformed
    /// drops all of them: the sender then appears as an ordinary Mac.
    private struct SessionHint {
        let group: String
        let hostName: String
        let label: String
        let availability: MacLoginSessionAvailability

        init?(txt: [String: String]) {
            guard let group = txt[SessionDiscoveryTXT.hostGroup], group.count == 16,
                  group.allSatisfy({ $0.isASCII && $0.isHexDigit && ($0.isNumber || $0.isLowercase) }),
                  let hostName = txt[SessionDiscoveryTXT.hostName]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hostName.isEmpty, hostName.count <= SessionDiscoveryTXT.maximumHostNameLength,
                  let rawLabel = txt[SessionDiscoveryTXT.sessionLabel],
                  rawLabel.count <= SessionDiscoveryTXT.maximumLabelLength,
                  let label = SenderSessionAdvertisement.normalizedLabel(rawLabel) else { return nil }
            self.group = group
            self.hostName = hostName
            self.label = label
            // An unknown state (a newer sender) is shown as available, like
            // a sender that sends none: the connection itself decides.
            availability = txt[SessionDiscoveryTXT.sessionState].flatMap(MacLoginSessionAvailability.init(rawValue:))
                ?? .available
        }
    }
}
