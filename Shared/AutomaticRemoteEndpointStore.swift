import Foundation

/// Tailscale addresses a paired peer reported about itself (`remoteEndpoints`), kept apart from the
/// address a person typed (`RemoteEndpointStore`), which they never replace or change. Android:
/// AutomaticRemoteEndpointStore.kt.
///
/// An entry is bound to the peer's pin when it was learned: once that peer is re-paired with
/// another key, or forgotten, the entry is gone. It also expires, so an address a device stopped
/// reporting long ago is not dialed forever. Routing only; it never creates or changes trust.
struct AutomaticRemoteEndpointStore {
    static let schemaVersion = 1
    /// Refreshed by every session; an entry not refreshed for this long is ignored and dropped.
    static let lifetime: TimeInterval = 30 * 24 * 3600

    struct Entry: Codable, Equatable {
        var version = AutomaticRemoteEndpointStore.schemaVersion
        /// `RemoteEndpointsWire.pinDigest` of the peer's pin when the report arrived.
        var pin: String
        var names: [String]
        var ips: [String]
        var updatedAt: Date
        /// The Mac's record of a receiver: what its hello said it is (`Android`, `iPhone`, ...),
        /// which decides the verified families (`TailnetFamilies.macDialing`). Nil on receivers.
        var device: String?
    }

    let role: RolePreferences
    var defaults: UserDefaults = .standard

    private var key: String { role.key("automaticRemoteEndpoints.v1") }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        // Whatever is stored must still pass the filter unchanged.
        return decoded.filter { _, entry in
            let checked = TailnetEndpointFilter.filter(names: entry.names, addresses: entry.ips)
            return entry.version == Self.schemaVersion && checked.names == entry.names && checked.addresses == entry.ips
        }
    }

    private func save(_ entries: [String: Entry]) {
        if entries.isEmpty { defaults.removeObject(forKey: key); return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// What `peerID` reported, while its pin is still `currentPin` and the entry is fresh.
    func entry(forPeerID peerID: String, currentPin: Data?, now: Date = Date()) -> Entry? {
        guard let currentPin, let entry = load()[peerID],
              entry.pin == RemoteEndpointsWire.pinDigest(currentPin),
              now.timeIntervalSince(entry.updatedAt) < Self.lifetime,
              entry.updatedAt.timeIntervalSince(now) < 3600 else { return nil }
        return entry
    }

    /// Records a report from the authenticated, admitted `peerID` whose pin is `pin`. An empty
    /// report removes the entry.
    func record(_ report: RemoteEndpointsWire.Report, forPeerID peerID: String, pin: Data, device: String? = nil,
                now: Date = Date()) {
        var entries = load()
        if report.isEmpty {
            guard entries.removeValue(forKey: peerID) != nil else { return }
        } else {
            entries[peerID] = Entry(pin: RemoteEndpointsWire.pinDigest(pin), names: report.names,
                                    ips: report.ips, updatedAt: now, device: device.map { String($0.prefix(16)) })
        }
        save(entries)
    }

    func remove(forPeerID peerID: String) {
        var entries = load()
        guard entries.removeValue(forKey: peerID) != nil else { return }
        save(entries)
    }

    func removeAll() { defaults.removeObject(forKey: key) }

    /// Every peer with a stored entry (fresh or not; `entry` decides).
    func peerIDs() -> [String] { Array(load().keys) }

    /// Drops entries for peers no longer paired (forgotten while this app wasn't running) and
    /// expired ones.
    func prune(pairedPeerIDs: Set<String>, now: Date = Date()) {
        let entries = load()
        let kept = entries.filter { pairedPeerIDs.contains($0.key) && now.timeIntervalSince($0.value.updatedAt) < Self.lifetime }
        if kept != entries { save(kept) }
    }
}

/// Automatic Remote Access: report this device's Tailscale addresses to paired peers and keep
/// theirs. On unless the person turned it off (each side has its own switch); turning it off
/// forgets what was learned, and the next session tells the peer to forget this side's.
enum AutomaticRemoteAccessPreference {
    static func key(_ role: RolePreferences) -> String { role.key("automaticRemoteAccess.enabled") }

    static func isEnabled(_ role: RolePreferences, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(role)) as? Bool ?? true
    }

    static func set(_ enabled: Bool, _ role: RolePreferences, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(role))
        if !enabled { AutomaticRemoteEndpointStore(role: role, defaults: defaults).removeAll() }
    }
}
