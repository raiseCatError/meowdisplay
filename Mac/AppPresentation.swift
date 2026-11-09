import Foundation

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy plus `MenuBarPresenceController` — like Raycast/
/// Hammerspoon style background agents. String-backed and additive only:
/// `menuBar`/`dock` keep their original raw values so previously-persisted
/// choices decode unchanged.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, dockAndMenuBar

    var label: String {
        switch self {
        case .menuBar: return String(localized: "Menu Bar")
        case .dock: return String(localized: "Dock")
        case .dockAndMenuBar: return String(localized: "Dock & Menu Bar")
        }
    }

    var showsDockIcon: Bool { self == .dock || self == .dockAndMenuBar }
    var showsMenuBarIcon: Bool { self == .menuBar || self == .dockAndMenuBar }
}

/// The presentation a launch uses, persisted under `presentation`.
///
/// From 2.1.0 a new install starts as Dock & Menu Bar. Earlier versions stored
/// nothing until the user changed the setting and ran as Menu Bar only, so an
/// unsaved choice on a Mac that ran MeowDisplay before still means Menu Bar
/// only. A saved choice (Menu Bar, Dock or Dock & Menu Bar) is always kept.
/// The first launch saves what it decided, so later launches never guess.
enum AppPresentationStore {
    static let key = "presentation"
    static let newInstallDefault: AppPresentation = .dockAndMenuBar
    static let earlierDefault: AppPresentation = .menuBar

    /// Written only by an earlier launch: Sparkle's first-launch flag (set as
    /// the updater starts, so `resolve` must run before it), and the device
    /// bookkeeping MeowDisplay keeps.
    static let previousLaunchMarkers = ["SUHasLaunchedBefore", "knownReceiverIdentifiers", "installIDByUDID"]

    /// The saved presentation, or the default for this Mac (saved). Idempotent.
    static func resolve(defaults: UserDefaults = .standard) -> AppPresentation {
        if let raw = defaults.string(forKey: key) {
            // A value a newer version saved is left as it is.
            return AppPresentation(rawValue: raw) ?? earlierDefault
        }
        let usedBefore = previousLaunchMarkers.contains { defaults.object(forKey: $0) != nil }
        let presentation = usedBefore ? earlierDefault : newInstallDefault
        defaults.set(presentation.rawValue, forKey: key)
        return presentation
    }
}
