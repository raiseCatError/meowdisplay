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
        case .menuBar: return "Menu Bar"
        case .dock: return "Dock"
        case .dockAndMenuBar: return "Dock & Menu Bar"
        }
    }

    var showsDockIcon: Bool { self == .dock || self == .dockAndMenuBar }
    var showsMenuBarIcon: Bool { self == .menuBar || self == .dockAndMenuBar }
}
