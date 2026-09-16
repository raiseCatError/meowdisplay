import Foundation

/// Connection hints for reaching an already-paired peer over Tailscale (the
/// Remote route). This is a network *hint* only — never identity. A stored
/// host/port lets the Mac skip re-typing a Tailscale address every launch,
/// but `TLSConfigurator`'s SPKI pin check remains the sole authority over
/// whether a connection is trusted. A changed or attacker-supplied address
/// cannot promote itself to a trusted peer; it can only be dialed, and the
/// pinned mutual-TLS handshake either accepts or terminates it.
enum RemoteEndpointStore {
    private static let defaultsKey = "remoteEndpointHints.v1"

    /// Bump if the persisted shape changes; `load()` discards anything from
    /// an older/newer version rather than guessing at a migration, mirroring
    /// `ReceiverControlPreferences.schemaVersion` in `Shared/ControlProfile.swift`.
    private static let schemaVersion = 1

    private struct Hint: Codable, Equatable {
        var version: Int = RemoteEndpointStore.schemaVersion
        var host: String
        var port: UInt16
    }

    private static func load() -> [String: Hint] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Hint].self, from: data)
        else { return [:] }
        return decoded.filter { $0.value.version == schemaVersion }
    }

    private static func save(_ hints: [String: Hint]) {
        guard let data = try? JSONEncoder().encode(hints) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// The last known Tailscale (or other Remote-route) address for a paired
    /// peer, keyed by its stable install ID — never by anything derived from
    /// the network address itself.
    static func endpoint(forPeerID peerID: String) -> (host: String, port: UInt16)? {
        guard let hint = load()[peerID] else { return nil }
        return (hint.host, hint.port)
    }

    static func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String) {
        var hints = load()
        hints[peerID] = Hint(host: host, port: port)
        save(hints)
    }

    static func removeEndpoint(forPeerID peerID: String) {
        var hints = load()
        hints.removeValue(forKey: peerID)
        save(hints)
    }

    static func allPeerIDs() -> [String] {
        Array(load().keys)
    }
}
