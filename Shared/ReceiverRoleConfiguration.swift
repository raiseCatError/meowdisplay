import Foundation

/// How the receiver role is isolated inside the app that hosts it. The iPhone
/// and iPad app and the standalone Mac Receiver are receivers only: their
/// receiver role IS the app, so it keeps the original Keychain names and
/// settings keys. The unified Mac app hosts both roles in one bundle and
/// declares `MeowDisplayReceiverRoleTrust` = `separate` in its Info.plist, so
/// its receiver role gets its own identity, pins and the few settings whose
/// names the sender role also uses.
enum ReceiverRoleConfiguration {
    static let infoKey = "MeowDisplayReceiverRoleTrust"

    static let separateTrust = separateTrust(infoDictionary: Bundle.main.infoDictionary)

    static func separateTrust(infoDictionary: [String: Any]?) -> Bool {
        infoDictionary?[infoKey] as? String == "separate"
    }

    /// A receiver-role settings key. Unchanged in a receiver-only app;
    /// prefixed in the unified app, where the sender role owns the plain name.
    static func defaultsKey(_ key: String) -> String {
        defaultsKey(key, separate: separateTrust)
    }

    static func defaultsKey(_ key: String, separate: Bool) -> String {
        separate ? "receiver.\(key)" : key
    }
}

/// The unified app's two roles advertise on the same network under
/// different install ids. Neither may discover, list, pair with or dial the
/// other: the sender would otherwise see "this Mac" as a nearby display and
/// the receiver would see it as a Mac to pair with.
enum SameAppPeerFilter {
    /// Whether a discovered service (its TXT `id`) is this app's other role.
    static func isSameApp(txtID: String?, ownIDs: Set<String>) -> Bool {
        guard let txtID else { return false }
        return ownIDs.contains(txtID)
    }

    static func excludingSameApp<T>(_ results: [T], ownIDs: Set<String>, txtID: (T) -> String?) -> [T] {
        guard !ownIDs.isEmpty else { return results }
        return results.filter { !isSameApp(txtID: txtID($0), ownIDs: ownIDs) }
    }

    /// The receiver role's advertised id in this app, if it ever created
    /// one (it is created on the receiver's first start, never by reading).
    static func receiverRoleInstallID(defaults: UserDefaults = .standard) -> String? {
        ReceiverRoleConfiguration.separateTrust ? defaults.string(forKey: "installID") : nil
    }
}
