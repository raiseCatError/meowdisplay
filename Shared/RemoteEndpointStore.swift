import Foundation

/// Connection hints for reaching an already-paired peer over Tailscale (the
/// Remote route). This is a network *hint* only — never identity. A stored
/// host/port lets the Mac skip re-typing a Tailscale address every launch,
/// but `TLSConfigurator`'s SPKI pin check remains the sole authority over
/// whether a connection is trusted. A changed or attacker-supplied address
/// cannot promote itself to a trusted peer; it can only be dialed, and the
/// pinned mutual-TLS handshake either accepts or terminates it.
///
/// Hints are per role (`RolePreferences`): in the unified Mac app the
/// sender's hints point at receivers and the receiver role's at sending
/// Macs, and neither role dials, lists or forgets the other's.
enum RemoteEndpointStore {
    private static func defaultsKey(_ role: RolePreferences) -> String { role.key("remoteEndpointHints.v1") }

    /// Bump if the persisted shape changes; `load()` discards anything from
    /// an older/newer version rather than guessing at a migration, mirroring
    /// `ReceiverControlPreferences.schemaVersion` in `Shared/ControlProfile.swift`.
    private static let schemaVersion = 1

    private struct Hint: Codable, Equatable {
        var version: Int = RemoteEndpointStore.schemaVersion
        var host: String
        var port: UInt16
    }

    private static func load(_ role: RolePreferences) -> [String: Hint] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(role)),
              let decoded = try? JSONDecoder().decode([String: Hint].self, from: data)
        else { return [:] }
        return decoded.filter { $0.value.version == schemaVersion }
    }

    private static func save(_ hints: [String: Hint], _ role: RolePreferences) {
        guard let data = try? JSONEncoder().encode(hints) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(role))
    }

    /// The last known Tailscale (or other Remote-route) address for a paired
    /// peer, keyed by its stable install ID — never by anything derived from
    /// the network address itself.
    static func endpoint(forPeerID peerID: String, role: RolePreferences) -> (host: String, port: UInt16)? {
        guard let hint = load(role)[peerID] else { return nil }
        return (hint.host, hint.port)
    }

    /// The saved port is the media connection port. Remote Wake & Connect
    /// knocks use the Mac's separate authenticated request listener instead.
    /// Keep the host hint, but never reuse the media port for the knock.
    static func connectRequestEndpoint(forPeerID peerID: String,
                                       role: RolePreferences) -> (host: String, port: UInt16)? {
        guard let hint = endpoint(forPeerID: peerID, role: role) else { return nil }
        return (hint.host, WireCrypto.remoteRequestPort)
    }

    static func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String, role: RolePreferences) {
        var hints = load(role)
        hints[peerID] = Hint(host: host, port: port)
        save(hints, role)
    }

    static func removeEndpoint(forPeerID peerID: String, role: RolePreferences) {
        var hints = load(role)
        hints.removeValue(forKey: peerID)
        save(hints, role)
    }

    static func allPeerIDs(role: RolePreferences) -> [String] {
        Array(load(role).keys)
    }
}
