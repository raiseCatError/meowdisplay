import Foundation
import Combine

/// The unified Settings sidebar taxonomy for Mac Sender. Same concept/name
/// used across Mac Receiver and iOS where it applies — see their own
/// category types for the (smaller) sets that make sense there.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case overview, displays, streaming, input, devices, remoteAccess, system
    #if DEBUG
    case developer
    #endif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .displays: return "Displays"
        case .streaming: return "Streaming"
        case .input: return "Input"
        case .devices: return "Devices"
        case .remoteAccess: return "Remote Access"
        case .system: return "System"
        #if DEBUG
        case .developer: return "Developer"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.dashed"
        case .displays: return "display"
        case .streaming: return "antenna.radiowaves.left.and.right"
        case .input: return "hand.tap"
        case .devices: return "list.bullet.rectangle"
        case .remoteAccess: return "network"
        case .system: return "gearshape"
        #if DEBUG
        case .developer: return "wrench.and.screwdriver"
        #endif
        }
    }
}

/// A searchable setting or sub-setting entry for the sidebar search index.
struct SettingsSearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let category: SettingsCategory
    let subtitle: String?
    let keywords: [String]
    let systemImage: String

    init(
        id: String,
        title: String,
        category: SettingsCategory,
        subtitle: String? = nil,
        keywords: [String] = [],
        systemImage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.subtitle = subtitle
        self.keywords = keywords
        self.systemImage = systemImage ?? category.systemImage
    }
}

/// Pre-indexed catalog of all top-level settings categories and real sub-settings.
struct SettingsSearchIndex {
    static let shared = SettingsSearchIndex()

    let allItems: [SettingsSearchItem]

    init() {
        var items: [SettingsSearchItem] = []

        // Top-level categories
        for category in SettingsCategory.allCases {
            let keywords: [String]
            switch category {
            case .overview:
                keywords = ["overview", "status", "ready to connect", "active display", "summary", "quick view"]
            case .displays:
                keywords = ["display", "displays", "screen", "monitor", "mode", "mirror", "extend", "resolution", "arrange"]
            case .streaming:
                keywords = ["streaming", "stream", "video", "audio", "transmission", "codec", "bitrate", "fps"]
            case .input:
                keywords = ["input", "touch", "control", "mouse", "keyboard", "gesture", "accessibility", "allow input"]
            case .devices:
                keywords = ["devices", "device", "ipad", "iphone", "connected", "known devices", "pair"]
            case .remoteAccess:
                keywords = ["remote", "remote access", "tailscale", "magicdns", "endpoint", "private network"]
            case .system:
                keywords = ["system", "preferences", "settings", "meowdisplay", "app", "permissions", "available"]
            #if DEBUG
            case .developer:
                keywords = ["developer", "debug", "diagnostics", "route overrides", "routes", "wake"]
            #endif
            }
            items.append(SettingsSearchItem(
                id: "category.\(category.id)",
                title: category.label,
                category: category,
                subtitle: nil,
                keywords: keywords,
                systemImage: category.systemImage
            ))
        }

        // Sub-settings for Displays
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "displays.mode",
                title: "Display Mode",
                category: .displays,
                subtitle: "Displays",
                keywords: ["mirror", "mirroring", "clone", "mode", "display mode"],
                systemImage: "rectangle.on.rectangle"
            ),
            SettingsSearchItem(
                id: "displays.mirror",
                title: "Mirror",
                category: .displays,
                subtitle: "Displays",
                keywords: ["mirror", "mirroring", "clone", "physical display"],
                systemImage: "rectangle.on.rectangle"
            ),
            SettingsSearchItem(
                id: "displays.extend",
                title: "Extend Display",
                category: .displays,
                subtitle: "Displays",
                keywords: ["extend", "extended display", "shape", "aspect ratio", "use full display"],
                systemImage: "rectangle.badge.plus"
            ),
            SettingsSearchItem(
                id: "displays.resolution",
                title: "Resolution",
                category: .displays,
                subtitle: "Displays",
                keywords: ["resolution", "pixels", "size", "dimensions", "scaling"],
                systemImage: "aspectratio"
            ),
            SettingsSearchItem(
                id: "displays.arrange",
                title: "Arrange Displays",
                category: .displays,
                subtitle: "Displays",
                keywords: ["arrange", "layout", "arrange displays", "position"],
                systemImage: "macwindow.on.rectangle"
            )
        ])

        // Sub-settings for Streaming
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "streaming.codec",
                title: "Codec",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["codec", "hevc", "h.264", "h264", "encoding", "compression", "video codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.hevc",
                title: "HEVC",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["hevc", "h.265", "h265", "codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.h264",
                title: "H.264",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["h.264", "h264", "avc", "codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.fps",
                title: "Frame Rate",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["frame rate", "fps", "refresh rate", "60fps", "120fps", "hz"],
                systemImage: "speedometer"
            ),
            SettingsSearchItem(
                id: "streaming.quality",
                title: "Quality & Bitrate",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["quality", "bitrate", "mbps", "bandwidth", "video bitrate"],
                systemImage: "slider.horizontal.3"
            ),
            SettingsSearchItem(
                id: "streaming.mode",
                title: "Streaming Mode",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["streaming mode", "profile", "latency", "performance", "custom"],
                systemImage: "gearshape.2"
            ),
            SettingsSearchItem(
                id: "streaming.audio",
                title: "Audio Streaming",
                category: .streaming,
                subtitle: "Streaming",
                keywords: ["audio", "sound", "volume", "sync", "a/v sync"],
                systemImage: "speaker.wave.2"
            )
        ])

        // Sub-settings for Input
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "input.allow",
                title: "Allow Input",
                category: .input,
                subtitle: "Input",
                keywords: ["allow input", "remote control", "touch control", "master switch", "enable input"],
                systemImage: "hand.tap"
            ),
            SettingsSearchItem(
                id: "input.requests",
                title: "Input Requests",
                category: .input,
                subtitle: "Input",
                keywords: ["input requests", "input policy", "always allow", "ask", "permission"],
                systemImage: "questionmark.circle"
            )
        ])

        // Sub-settings for Devices
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "devices.known",
                title: "Known Devices",
                category: .devices,
                subtitle: "Devices",
                keywords: ["known devices", "paired devices", "paired", "forget device", "nearby"],
                systemImage: "list.bullet.rectangle"
            ),
            SettingsSearchItem(
                id: "devices.remotePairing",
                title: "Remote Pairing",
                category: .devices,
                subtitle: "Devices",
                keywords: ["remote pairing", "pair over remote", "pairing code", "tailscale pairing"],
                systemImage: "qrcode"
            ),
            SettingsSearchItem(
                id: "devices.activeDisplay",
                title: "Active Display",
                category: .devices,
                subtitle: "Devices",
                keywords: ["active display", "session", "connected display", "disconnect"],
                systemImage: "display"
            )
        ])

        // Sub-settings for Remote Access
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "remoteAccess.endpoint",
                title: "Remote Endpoint",
                category: .remoteAccess,
                subtitle: "Remote Access",
                keywords: ["remote endpoint", "endpoint", "tailscale", "magicdns", "ip address", "port", "saved address"],
                systemImage: "network"
            )
        ])

        // Sub-settings for System
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "system.keepAvailable",
                title: "Keep Mac Available",
                category: .system,
                subtitle: "System",
                keywords: ["available", "keep mac available", "sleep", "prevent sleep", "caffeinate", "power", "wake"],
                systemImage: "powersleep"
            ),
            SettingsSearchItem(
                id: "system.permissions",
                title: "Permissions",
                category: .system,
                subtitle: "System",
                keywords: ["permissions", "screen recording", "accessibility", "local network"],
                systemImage: "lock.shield"
            ),
            SettingsSearchItem(
                id: "system.behavior",
                title: "App Behavior",
                category: .system,
                subtitle: "System",
                keywords: ["app behavior", "start at login", "menu bar", "dock", "presentation"],
                systemImage: "app.badge"
            ),
            SettingsSearchItem(
                id: "system.autoReconnect",
                title: "Auto-Reconnect",
                category: .system,
                subtitle: "System",
                keywords: ["auto-reconnect", "reconnect", "automatic connection"],
                systemImage: "arrow.triangle.2.circlepath"
            ),
            SettingsSearchItem(
                id: "system.updates",
                title: "Software Updates",
                category: .system,
                subtitle: "System",
                keywords: ["updates", "sparkle", "check for updates", "version", "software update"],
                systemImage: "arrow.down.circle"
            )
        ])

        #if DEBUG
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "developer.routes",
                title: "Route Overrides",
                category: .developer,
                subtitle: "Developer",
                keywords: ["route overrides", "routes", "transport override"],
                systemImage: "arrow.triangle.branch"
            ),
            SettingsSearchItem(
                id: "developer.wake",
                title: "Wake Testing",
                category: .developer,
                subtitle: "Developer",
                keywords: ["wake testing", "wake", "sleep test"],
                systemImage: "bolt.badge.clock"
            ),
            SettingsSearchItem(
                id: "developer.diagnostics",
                title: "Device Diagnostics",
                category: .developer,
                subtitle: "Developer",
                keywords: ["device diagnostics", "peer diagnostics", "debug info"],
                systemImage: "stethoscope"
            )
        ])
        #endif

        self.allItems = items
    }

    /// Searches indexed settings matching the given query.
    ///
    /// Matches against item titles, category names, and relevant keywords.
    /// Results are ranked so exact/prefix matches on titles and top-level categories
    /// appear before keyword-only matches.
    func search(query: String) -> [SettingsSearchItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }

        struct RankedItem {
            let item: SettingsSearchItem
            let score: Int
        }

        var ranked: [RankedItem] = []

        for item in allItems {
            let title = item.title.lowercased()
            let catLabel = item.category.label.lowercased()
            let isTopLevel = item.subtitle == nil

            var score = 0
            if title == clean {
                score = isTopLevel ? 100 : 90
            } else if title.hasPrefix(clean) {
                score = isTopLevel ? 80 : 70
            } else if title.contains(clean) {
                score = isTopLevel ? 60 : 50
            } else if catLabel == clean {
                score = 45
            } else if catLabel.hasPrefix(clean) {
                score = 40
            } else if catLabel.contains(clean) {
                score = 35
            } else if item.keywords.contains(where: { $0.lowercased() == clean }) {
                score = 30
            } else if item.keywords.contains(where: { $0.lowercased().hasPrefix(clean) }) {
                score = 25
            } else if item.keywords.contains(where: { $0.lowercased().contains(clean) || clean.contains($0.lowercased()) }) {
                score = 20
            }

            if score > 0 {
                ranked.append(RankedItem(item: item, score: score))
            }
        }

        ranked.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.item.title < $1.item.title
        }

        return ranked.map(\.item)
    }
}

/// Drives the Back/Forward navigation history for the macOS Settings window.
///
/// Semantics:
/// - Maintains chronological back and forward history stacks.
/// - Selecting a new destination (sidebar, search result, or programmatic button)
///   pushes the current destination onto the back stack and clears the forward stack.
/// - Duplicate consecutive navigation to the currently active pane is ignored.
/// - Back and Forward step through history without appending duplicate entries.
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published private(set) var current: SettingsCategory
    @Published private(set) var backStack: [SettingsCategory]
    @Published private(set) var forwardStack: [SettingsCategory]

    init(initialCategory: SettingsCategory = .overview) {
        self.current = initialCategory
        self.backStack = []
        self.forwardStack = []
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    /// Navigates to a new category.
    ///
    /// If `category == current`, the request is a no-op to prevent duplicate history.
    /// Pushes the previous category onto `backStack` and discards `forwardStack` (divergent history).
    func navigateTo(_ category: SettingsCategory) {
        guard category != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = category
    }

    /// Steps back one entry in navigation history.
    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    /// Steps forward one entry in navigation history.
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}

/// Represents either a top-level category row or a search result row in the sidebar list.
enum SidebarItem: Hashable, Identifiable {
    case category(SettingsCategory)
    case searchResult(SettingsSearchItem)

    var id: String {
        switch self {
        case .category(let cat): return "cat:\(cat.id)"
        case .searchResult(let item): return "search:\(item.id)"
        }
    }
}
