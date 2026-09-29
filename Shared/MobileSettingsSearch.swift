import Foundation

/// One searchable receiver setting (or a whole category). `id` doubles as
/// the setting's anchor on its page, so a result can scroll to and briefly
/// highlight it.
struct MobileSettingsSearchItem: Identifiable, Hashable {
    enum Availability: Hashable {
        case everywhere
        case padOnly
        case phoneOnly
    }

    let id: String
    let title: String
    let category: MobileSettingsCategory
    let keywords: [String]
    let availability: Availability
    /// A category row rather than a single setting.
    let isCategory: Bool

    init(_ id: String, _ title: String, _ category: MobileSettingsCategory, keywords: [String] = [],
         availability: Availability = .everywhere, isCategory: Bool = false) {
        self.id = id
        self.title = title
        self.category = category
        self.keywords = keywords
        self.availability = availability
        self.isCategory = isCategory
    }
}

/// The one Settings search model for both size classes: the iPad sidebar
/// and the iPhone category list search the same index.
enum MobileSettingsSearchIndex {
    static func items(isPad: Bool, debug: Bool) -> [MobileSettingsSearchItem] {
        let visible = Set(MobileSettingsCategory.visible(debug: debug))
        let categories = MobileSettingsCategory.visible(debug: debug).map {
            MobileSettingsSearchItem("category.\($0.rawValue)", $0.title, $0, isCategory: true)
        }
        return categories + settings.filter { item in
            guard visible.contains(item.category) else { return false }
            switch item.availability {
            case .everywhere: return true
            case .padOnly: return isPad
            case .phoneOnly: return !isPad
            }
        }
    }

    /// Ranked matches. Every query word must match: a prefix of any word of
    /// the title, keywords or category name, or a substring of the title.
    static func search(_ query: String, isPad: Bool, debug: Bool) -> [MobileSettingsSearchItem] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: MobileSettingsCategory.allCases.enumerated().map { ($1, $0) })
        return items(isPad: isPad, debug: debug)
            .compactMap { item -> (MobileSettingsSearchItem, Int)? in
                score(item, words: words, phrase: normalized(query)).map { (item, $0) }
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.category != $1.0.category { return order[$0.0.category, default: 0] < order[$1.0.category, default: 0] }
                return $0.0.title < $1.0.title
            }
            .map(\.0)
    }

    private static func score(_ item: MobileSettingsSearchItem, words: [String], phrase: String) -> Int? {
        let title = normalized(item.title)
        let titleWords = tokens(item.title)
        let keywordWords = item.keywords.flatMap(tokens)
        let categoryWords = tokens(item.category.title)
        var total = 0
        for word in words {
            if titleWords.contains(where: { $0.hasPrefix(word) }) {
                total += 30
            } else if title.contains(word) {
                total += 20
            } else if keywordWords.contains(where: { $0.hasPrefix(word) }) {
                total += 15
            } else if categoryWords.contains(where: { $0.hasPrefix(word) }) {
                total += 5
            } else {
                return nil
            }
        }
        if title == phrase { total += 100 } else if title.hasPrefix(phrase) { total += 50 }
        if item.isCategory, title.hasPrefix(phrase) { total += 40 }
        return total
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ text: String) -> [String] {
        normalized(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // swiftlint:disable line_length
    private static let settings: [MobileSettingsSearchItem] = [
        // General
        .init("deviceName", String(localized: "Name"), .general, keywords: ["device name", "rename", "bonjour"]),
        .init("autoReconnect", String(localized: "Auto-Reconnect"), .general, keywords: ["reconnect", "automatic"]),
        .init("haptics", String(localized: "Haptics"), .general, keywords: ["vibration", "feedback"]),
        // Display
        .init("video", String(localized: "Video"), .display, keywords: ["picture", "stream off"]),
        .init("displayMode", String(localized: "Display Mode"), .display, keywords: ["mirror", "extend", "second screen"]),
        .init("surfaceGrid", String(localized: "Show Surface Grid"), .display, keywords: ["video off", "dots"]),
        .init("pictureInPicture", String(localized: "Picture in Picture"), .display, keywords: ["pip", "floating window"]),
        .init("streamingProfile", String(localized: "Streaming Profile"), .display, keywords: ["quality", "frame rate", "bitrate", "priority", "fps"]),
        .init("maxFPS", String(localized: "Enforce Maximum FPS"), .display, keywords: ["frame rate", "fps", "limit"]),
        // Input
        .init("control", String(localized: "Control"), .input, keywords: ["request control", "allow input", "permission"]),
        .init("inputMode", String(localized: "Input Mode"), .input, keywords: ["direct touch", "trackpad", "pointer", "mouse"]),
        .init("smartTouch", "Smart Touch", .input, keywords: ["scroll", "one finger", "title bar", "window"]),
        .init("smartTouchHaptics", String(localized: "Smart Touch Haptics"), .input, keywords: ["vibration"]),
        .init("trackpadSensitivity", String(localized: "Trackpad Sensitivity"), .input, keywords: ["speed", "pointer"]),
        .init("scrollDirection", String(localized: "Invert Vertical Scrolling"), .input, keywords: ["invert horizontal scrolling", "natural scrolling", "scroll direction", "reverse"]),
        .init("zoomWhileTyping", String(localized: "Zoom While Typing"), .input, keywords: ["keyboard"]),
        // Gestures
        .init("pinch", String(localized: "Pinch / Zoom"), .gestures, keywords: ["magnify", "zoom"]),
        .init("rotation", String(localized: "Rotation"), .gestures, keywords: ["rotate", "snap"]),
        .init("preferGestures", String(localized: "Prefer MeowDisplay Gestures"), .gestures, keywords: ["edge", "three finger", "system gestures", "undo"]),
        .init("localViewNavigation", String(localized: "Allow Local View Navigation"), .gestures, keywords: ["pan", "zoom", "move", "view", "viewport", "inspect"]),
        .init("moveView", String(localized: "Move View"), .gestures, keywords: ["pan", "viewport"], availability: .padOnly),
        .init("resetView", String(localized: "Reset View"), .gestures, keywords: ["viewport", "double tap"]),
        // Controls
        .init("controlLayout", String(localized: "Control Layout"), .controls, keywords: ["strip", "overlay", "custom", "sidecar", "rail"], availability: .padOnly),
        .init("controlEdges", String(localized: "Main Controls"), .controls, keywords: ["function controls", "edge", "left", "right", "top", "bottom", "position"], availability: .padOnly),
        .init("standardControls", String(localized: "Standard Controls"), .controls, keywords: ["menu bar", "dock", "show desktop", "control center", "escape", "tab", "keyboard", "move view"], availability: .padOnly),
        .init("controlHints", String(localized: "Show Control Hints"), .controls, keywords: ["labels", "captions"], availability: .padOnly),
        .init("controlSize", String(localized: "Control Size"), .controls, keywords: ["scale", "bigger", "smaller", "button size"], availability: .padOnly),
        .init("customLayouts", String(localized: "Custom Layouts"), .controls, keywords: ["two hand assist", "radial", "share", "import", "editor", "shortcut button"], availability: .padOnly),
        .init("showTray", String(localized: "Show Control Tray"), .controls, keywords: ["controls", "hide"]),
        .init("autoHide", String(localized: "Auto-hide Control Trays"), .controls, keywords: ["auto hide", "fade"]),
        .init("trayPlacement", String(localized: "Landscape Tray Side"), .controls, keywords: ["left", "right", "function tray position", "avoid notch"], availability: .phoneOnly),
        .init("controlProfile", String(localized: "Active Profile"), .controls, keywords: ["control profile", "shortcuts", "palette", "modifier"]),
        .init("functionTray", String(localized: "Show Function Tray"), .controls, keywords: ["undo", "redo", "zoom in", "zoom out", "launchpad", "edit function tray", "macro", "sequence", "shortcut button", "emoji"]),
        .init("paletteStyle", String(localized: "Palette Style"), .controls, keywords: ["wheel", "chord", "keys"], availability: .padOnly),
        // Audio
        .init("audio", String(localized: "Audio"), .audio, keywords: ["sound"]),
        .init("avSync", String(localized: "A/V Sync"), .audio, keywords: ["lip sync", "delay", "latency", "resync"]),
        // Connections
        .init("connectionStatus", String(localized: "Connection"), .connections, keywords: ["status", "disconnect", "quic", "tcp", "usb", "wifi", "transport"]),
        // Paired Macs
        .init("pairedMacs", String(localized: "Paired Macs"), .pairedMacs, keywords: ["forget", "trust", "automatically allow connections", "block"]),
        // Remote Access
        .init("remoteAccess", String(localized: "Remote Access"), .remoteAccess, keywords: ["tailscale", "internet", "remote"]),
        // Permissions
        .init("localNetwork", String(localized: "Open iOS Settings for MeowDisplay"), .permissions, keywords: ["local network", "privacy"]),
        // Diagnostics
        .init("connectionLog", String(localized: "Connection log"), .diagnostics, keywords: ["logs", "debug"]),
        .init("performanceOverlay", String(localized: "Performance overlay"), .diagnostics, keywords: ["fps", "latency", "analytics"]),
        .init("metalRenderer", String(localized: "Metal renderer (experimental)"), .diagnostics, keywords: ["rendering"]),
        // About
        .init("version", String(localized: "Version"), .about, keywords: ["about", "github", "mac app"]),
        // Developer (DEBUG builds only — filtered with its category)
        .init("notchDebug", String(localized: "Notch Debug Overlay"), .developer, keywords: ["debug"]),
        .init("audioDiagnostics", String(localized: "Audio Diagnostics"), .developer, keywords: ["aac", "pcm"]),
    ]
    // swiftlint:enable line_length
}
