import Foundation

// Remote Finder permissions per paired device (PROTOCOL.md 6.12). Three separate things:
// how long a grant lasts (this session, or always for this device), where it reaches (the
// approved folders, or every file this Mac user and macOS let MeowDisplay read) and what it
// allows (browse, download, upload, modify, delete). Keyed by the device's authenticated
// install ID (the same identity `TrustStore` pins), never by name or address. Forget removes
// it. Like Input's Always Allow, nothing here can be widened while any session has control of
// this Mac: a remote device could otherwise click its own grant.

enum FilesCapability: String, Codable, CaseIterable, Comparable, Sendable {
    /// List, search, thumbnails and in-app previews (streamed into the receiver's private cache).
    case browse
    /// Save a copy on the receiver, share it, or copy it to the receiver's clipboard.
    case download
    /// Upload files and folders, create folders.
    case upload
    /// Rename, move, copy, duplicate, compress, expand, put back from the Trash.
    case modify
    /// Move to the Trash.
    case delete

    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// What a read-only grant gives (the prompt's default).
    static let readOnly: Set<FilesCapability> = [.browse, .download]
}

enum FilesScope: String, Codable, Sendable {
    /// The folders the owner approved in Settings.
    case selectedFolders
    /// The home folder and mounted volumes: only what this Mac user and macOS privacy allow
    /// MeowDisplay to read. Never other users, ~/Library or protected locations.
    case allAccessible
}

enum FilesAccess: String, Codable, Sendable {
    /// Each session asks the owner.
    case ask
    /// This device needs no prompt: the stored scope and capabilities apply.
    case always
    /// Never: requests are refused without a prompt.
    case block
}

struct FilesDevicePolicy: Codable, Equatable, Sendable {
    var access: FilesAccess = .ask
    var scope: FilesScope = .selectedFolders
    var capabilities: Set<FilesCapability> = FilesCapability.readOnly
    /// Hidden files (dot-files) are listed. Protected locations stay out of reach.
    var showHidden = false

    static let `default` = FilesDevicePolicy()

    /// Would going from `old` to `self` give the device anything it didn't have?
    func widens(_ old: FilesDevicePolicy) -> Bool {
        if access == .always && old.access != .always { return true }
        if access == .always || old.access == .always {
            if scope == .allAccessible && old.scope != .allAccessible { return true }
            if !capabilities.isSubset(of: old.capabilities) { return true }
            if showHidden && !old.showHidden { return true }
        }
        return false
    }
}

/// What one session may do right now.
struct FilesGrant: Equatable, Sendable {
    enum Duration: String, Sendable { case session, always }
    var duration: Duration
    var scope: FilesScope
    var capabilities: Set<FilesCapability>
    var showHidden = false

    func allows(_ c: FilesCapability) -> Bool { capabilities.contains(c) }

    /// The owner's answer to a prompt, as a grant.
    static func session(_ caps: Set<FilesCapability> = FilesCapability.readOnly) -> FilesGrant {
        FilesGrant(duration: .session, scope: .selectedFolders, capabilities: caps)
    }

    static func always(_ p: FilesDevicePolicy) -> FilesGrant {
        FilesGrant(duration: .always, scope: p.scope, capabilities: p.capabilities, showHidden: p.showHidden)
    }

    /// Wire form for the receiver's indicator (`state.grant`).
    var wire: [String: Any] {
        ["duration": duration.rawValue, "scope": scope.rawValue, "caps": capabilities.sorted().map(\.rawValue), "hidden": showHidden]
    }
}

/// The owner's answer to a Files prompt.
enum FilesConsentDecision: Equatable, Sendable {
    case deny
    case session
    case alwaysSelectedFolders
    case alwaysAllAccessible
}

/// Per-device policies, in UserDefaults keyed by peer install ID.
enum FilesDevicePolicyStore {
    private static let defaultsKey = "remoteFilesDevicePolicy.v1"

    private static func load(_ d: UserDefaults) -> [String: Data] { d.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }

    static func policy(peerID: String, defaults: UserDefaults = .standard) -> FilesDevicePolicy {
        load(defaults)[peerID].flatMap { try? JSONDecoder().decode(FilesDevicePolicy.self, from: $0) } ?? .default
    }

    /// False (nothing stored) when the change widens the device's access while any session has
    /// control of this Mac. Narrowing is always allowed.
    @discardableResult
    static func setPolicy(_ policy: FilesDevicePolicy, peerID: String, anySessionHasEffectiveInput: Bool,
                          defaults: UserDefaults = .standard) -> Bool {
        let old = self.policy(peerID: peerID, defaults: defaults)
        guard !policy.widens(old) || !anySessionHasEffectiveInput else { return false }
        var all = load(defaults)
        if policy == .default {
            all.removeValue(forKey: peerID)
        } else {
            all[peerID] = try? JSONEncoder().encode(policy)
        }
        defaults.set(all, forKey: defaultsKey)
        return true
    }

    static func removePolicy(peerID: String, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        all.removeValue(forKey: peerID)
        defaults.set(all, forKey: defaultsKey)
    }

    static func allPolicies(defaults: UserDefaults = .standard) -> [String: FilesDevicePolicy] {
        load(defaults).compactMapValues { try? JSONDecoder().decode(FilesDevicePolicy.self, from: $0) }
    }

    /// The policy after the owner answered a prompt with `decision` (nil: nothing to store).
    static func policy(after decision: FilesConsentDecision, from old: FilesDevicePolicy) -> FilesDevicePolicy? {
        switch decision {
        case .deny, .session: return nil
        case .alwaysSelectedFolders:
            var p = old; p.access = .always; p.scope = .selectedFolders
            p.capabilities.formUnion(FilesCapability.readOnly)
            return p
        case .alwaysAllAccessible:
            var p = old; p.access = .always; p.scope = .allAccessible
            p.capabilities.formUnion(FilesCapability.readOnly)
            return p
        }
    }
}
