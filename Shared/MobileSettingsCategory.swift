import Foundation

/// The iPhone/iPad receiver's Settings categories. One model drives both
/// presentations: a `NavigationSplitView` sidebar in regular width and a
/// plain category list with pushed pages in compact width.
enum MobileSettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case display
    case input
    case gestures
    case controls
    case audio
    case connections
    case pairedMacs
    case remoteAccess
    case permissions
    case diagnostics
    case about
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .display: return String(localized: "Display")
        case .input: return String(localized: "Input")
        case .gestures: return String(localized: "Gestures")
        case .controls: return String(localized: "Controls")
        case .audio: return String(localized: "Audio")
        case .connections: return String(localized: "Connections")
        case .pairedMacs: return String(localized: "Paired Macs")
        case .remoteAccess: return String(localized: "Remote Access")
        case .permissions: return String(localized: "Permissions")
        case .diagnostics: return String(localized: "Diagnostics")
        case .about: return String(localized: "About")
        case .developer: return String(localized: "Developer")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "display"
        case .input: return "hand.point.up.left"
        case .gestures: return "hand.draw"
        case .controls: return "command"
        case .audio: return "speaker.wave.2"
        case .connections: return "cable.connector"
        case .pairedMacs: return "laptopcomputer"
        case .remoteAccess: return "network"
        case .permissions: return "lock.shield"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        case .developer: return "hammer"
        }
    }

    /// Sidebar sections, in order.
    enum Group: CaseIterable {
        case receiver
        case connection
        case support
    }

    var group: Group {
        switch self {
        case .general, .display, .input, .gestures, .controls, .audio: return .receiver
        case .connections, .pairedMacs, .remoteAccess, .permissions: return .connection
        case .diagnostics, .about, .developer: return .support
        }
    }

    /// Categories offered on this build. Developer exists only in DEBUG.
    static func visible(debug: Bool) -> [MobileSettingsCategory] {
        allCases.filter { $0 != .developer || debug }
    }

    static var visibleInThisBuild: [MobileSettingsCategory] {
        #if DEBUG
        visible(debug: true)
        #else
        visible(debug: false)
        #endif
    }

    /// Regular width always shows a page beside the sidebar; compact width
    /// starts on the category list.
    static func initialSelection(regularWidth: Bool) -> MobileSettingsCategory? {
        regularWidth ? .general : nil
    }
}

/// Which iPad-only control settings a device shows. The iPhone keeps its
/// compact tray, so none of these appear there.
struct PadControlSettingsVisibility: Equatable {
    let isPad: Bool
    let layout: PadControlLayoutMode

    var showsLayoutPicker: Bool { isPad }
    var showsControlSize: Bool { isPad }
    var showsEdgePickers: Bool { isPad && layout != .custom }
    var showsControlHints: Bool { isPad && layout == .strip }
    var showsCustomLayouts: Bool { isPad && layout == .custom }
    /// The iPhone's landscape side / Same–Opposite Side pickers.
    var showsPhoneTrayPlacement: Bool { !isPad }
}
