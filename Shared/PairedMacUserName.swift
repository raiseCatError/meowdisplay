import Foundation

/// The name of the person signed in on a paired Mac ("Jai Sukka"), shown next to the Mac's name and
/// short ID so same-named Macs are told apart. Only a paired Mac sends it, in its `welcome`, inside
/// the mutually authenticated session; never in Bonjour or anything sent before pairing. The Mac's
/// owner can turn it off (MeowDisplay Settings ▸ General); a `welcome` without it removes it here.
enum PairedMacUserName {
    /// Mac side: the setting, on unless turned off.
    static let showKey = "pairedDevices.showUserName"
    static let maxLength = 64
    private static let storeKey = "pairedMacUserNames"

    /// What the Mac sends: its user's full name, or nothing when turned off or empty.
    static func outgoing(defaults: UserDefaults = .standard, fullName: String = NSFullUserName()) -> String? {
        guard defaults.object(forKey: showKey) as? Bool ?? true else { return nil }
        return clean(fullName)
    }

    /// Printable, single line, at most `maxLength` characters; nil when nothing is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Controls and format characters (Cc, Cf: bidi overrides too), separators and private use:
        // a name can't disguise itself as another Mac's ID. Same rule on Android.
        let printable = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && !CharacterSet.illegalCharacters.contains($0) && !(0xE000...0xF8FF).contains($0.value)
        }
        let text = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(maxLength))
    }

    /// Receiver side: what the authenticated Mac `peerID` said in its welcome (nil removes it).
    static func record(_ raw: String?, peerID: String?, defaults: UserDefaults = .standard) {
        guard let peerID, !peerID.isEmpty else { return }
        var all = defaults.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        let name = clean(raw)
        guard all[peerID] != name else { return }
        all[peerID] = name
        defaults.set(all, forKey: storeKey)
    }

    static func name(peerID: String?, defaults: UserDefaults = .standard) -> String? {
        guard let peerID else { return nil }
        return (defaults.dictionary(forKey: storeKey) as? [String: String])?[peerID]
    }

    /// A Mac was forgotten: its name goes too.
    static func forget(peerID: String, defaults: UserDefaults = .standard) { record(nil, peerID: peerID, defaults: defaults) }
}
