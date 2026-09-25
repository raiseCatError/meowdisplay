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
        case .overview: return String(localized: "Overview")
        case .displays: return String(localized: "Displays")
        case .streaming: return String(localized: "Streaming")
        case .input: return String(localized: "Input")
        case .devices: return String(localized: "Devices")
        case .remoteAccess: return String(localized: "Remote Access")
        case .system: return String(localized: "System")
        #if DEBUG
        case .developer: return String(localized: "Developer")
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
                title: String(localized: "Display Mode"),
                category: .displays,
                subtitle: String(localized: "Displays"),
                keywords: ["mirror", "mirroring", "clone", "mode", "display mode"],
                systemImage: "rectangle.on.rectangle"
            ),
            SettingsSearchItem(
                id: "displays.mirror",
                title: String(localized: "Mirror"),
                category: .displays,
                subtitle: String(localized: "Displays"),
                keywords: ["mirror", "mirroring", "clone", "physical display"],
                systemImage: "rectangle.on.rectangle"
            ),
            SettingsSearchItem(
                id: "displays.extend",
                title: String(localized: "Extend Display"),
                category: .displays,
                subtitle: String(localized: "Displays"),
                keywords: ["extend", "extended display", "shape", "aspect ratio", "use full display"],
                systemImage: "rectangle.badge.plus"
            ),
            SettingsSearchItem(
                id: "displays.resolution",
                title: String(localized: "Resolution"),
                category: .displays,
                subtitle: String(localized: "Displays"),
                keywords: ["resolution", "pixels", "size", "dimensions", "scaling"],
                systemImage: "aspectratio"
            ),
            SettingsSearchItem(
                id: "displays.arrange",
                title: String(localized: "Arrange Displays"),
                category: .displays,
                subtitle: String(localized: "Displays"),
                keywords: ["arrange", "layout", "arrange displays", "position"],
                systemImage: "macwindow.on.rectangle"
            )
        ])

        // Sub-settings for Streaming
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "streaming.codec",
                title: String(localized: "Codec"),
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["codec", "hevc", "h.264", "h264", "encoding", "compression", "video codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.hevc",
                title: "HEVC",
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["hevc", "h.265", "h265", "codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.h264",
                title: "H.264",
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["h.264", "h264", "avc", "codec"],
                systemImage: "film"
            ),
            SettingsSearchItem(
                id: "streaming.fps",
                title: String(localized: "Frame Rate"),
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["frame rate", "fps", "refresh rate", "60fps", "120fps", "hz"],
                systemImage: "speedometer"
            ),
            SettingsSearchItem(
                id: "streaming.quality",
                title: String(localized: "Quality & Bitrate"),
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["quality", "bitrate", "mbps", "bandwidth", "video bitrate"],
                systemImage: "slider.horizontal.3"
            ),
            SettingsSearchItem(
                id: "streaming.mode",
                title: String(localized: "Streaming Mode"),
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["streaming mode", "profile", "latency", "performance", "custom"],
                systemImage: "gearshape.2"
            ),
            SettingsSearchItem(
                id: "streaming.audio",
                title: String(localized: "Audio Streaming"),
                category: .streaming,
                subtitle: String(localized: "Streaming"),
                keywords: ["audio", "sound", "volume", "sync", "a/v sync"],
                systemImage: "speaker.wave.2"
            )
        ])

        // Sub-settings for Input
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "input.allow",
                title: String(localized: "Allow Input"),
                category: .input,
                subtitle: String(localized: "Input"),
                keywords: ["allow input", "remote control", "touch control", "master switch", "enable input"],
                systemImage: "hand.tap"
            ),
            SettingsSearchItem(
                id: "input.requests",
                title: String(localized: "Input Requests"),
                category: .input,
                subtitle: String(localized: "Input"),
                keywords: ["input requests", "input policy", "always allow", "ask", "permission"],
                systemImage: "questionmark.circle"
            )
        ])

        // Sub-settings for Devices
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "devices.known",
                title: String(localized: "Known Devices"),
                category: .devices,
                subtitle: String(localized: "Devices"),
                keywords: ["known devices", "paired devices", "paired", "forget device", "nearby"],
                systemImage: "list.bullet.rectangle"
            ),
            SettingsSearchItem(
                id: "devices.remotePairing",
                title: String(localized: "Remote Pairing"),
                category: .devices,
                subtitle: String(localized: "Devices"),
                keywords: ["remote pairing", "pair over remote", "pairing code", "tailscale pairing"],
                systemImage: "qrcode"
            ),
            SettingsSearchItem(
                id: "devices.activeDisplay",
                title: String(localized: "Active Display"),
                category: .devices,
                subtitle: String(localized: "Devices"),
                keywords: ["active display", "session", "connected display", "disconnect"],
                systemImage: "display"
            )
        ])

        // Sub-settings for Remote Access
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "remoteAccess.endpoint",
                title: String(localized: "Remote Endpoint"),
                category: .remoteAccess,
                subtitle: String(localized: "Remote Access"),
                keywords: ["remote endpoint", "endpoint", "tailscale", "magicdns", "ip address", "port", "saved address"],
                systemImage: "network"
            )
        ])

        // Sub-settings for System
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "system.keepAvailable",
                title: String(localized: "Keep Mac Available"),
                category: .system,
                subtitle: String(localized: "System"),
                keywords: ["available", "keep mac available", "sleep", "prevent sleep", "caffeinate", "power", "wake"],
                systemImage: "powersleep"
            ),
            SettingsSearchItem(
                id: "system.permissions",
                title: String(localized: "Permissions"),
                category: .system,
                subtitle: String(localized: "System"),
                keywords: ["permissions", "screen recording", "accessibility", "local network"],
                systemImage: "lock.shield"
            ),
            SettingsSearchItem(
                id: "system.behavior",
                title: String(localized: "App Behavior"),
                category: .system,
                subtitle: String(localized: "System"),
                keywords: ["app behavior", "start at login", "menu bar", "dock", "presentation"],
                systemImage: "app.badge"
            ),
            SettingsSearchItem(
                id: "system.autoReconnect",
                title: String(localized: "Auto-Reconnect"),
                category: .system,
                subtitle: String(localized: "System"),
                keywords: ["auto-reconnect", "reconnect", "automatic connection"],
                systemImage: "arrow.triangle.2.circlepath"
            ),
            SettingsSearchItem(
                id: "system.updates",
                title: String(localized: "Software Updates"),
                category: .system,
                subtitle: String(localized: "System"),
                keywords: ["updates", "sparkle", "check for updates", "version", "software update"],
                systemImage: "arrow.down.circle"
            )
        ])

        #if DEBUG
        items.append(contentsOf: [
            SettingsSearchItem(
                id: "developer.routes",
                title: String(localized: "Route Overrides"),
                category: .developer,
                subtitle: String(localized: "Developer"),
                keywords: ["route overrides", "routes", "transport override"],
                systemImage: "arrow.triangle.branch"
            ),
            SettingsSearchItem(
                id: "developer.wake",
                title: String(localized: "Wake Testing"),
                category: .developer,
                subtitle: String(localized: "Developer"),
                keywords: ["wake testing", "wake", "sleep test"],
                systemImage: "bolt.badge.clock"
            ),
            SettingsSearchItem(
                id: "developer.diagnostics",
                title: String(localized: "Device Diagnostics"),
                category: .developer,
                subtitle: String(localized: "Developer"),
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

/// Pure mapping between the sidebar's view-owned `List` selection and
/// `SettingsNavigationModel`. The sidebar binds `List(selection:)` to local
/// `@State`, never to a Binding whose setter mutates the model: AppKit's list
/// can write selection back while SwiftUI is still applying an update (rows
/// changing under a search), and publishing navigation state from there is
/// illegal. The model is updated from `onChange` instead, after the update.
enum SidebarSelection {
    /// What the sidebar should highlight for the current navigation state.
    static func derived(current: SettingsCategory, isSearching: Bool,
                        results: [SettingsSearchItem], selectedSearchItemID: String?) -> SidebarItem? {
        guard isSearching else { return .category(current) }
        if let selectedSearchItemID, let match = results.first(where: { $0.id == selectedSearchItemID }) {
            return .searchResult(match)
        }
        return results.first { $0.category == current }.map(SidebarItem.searchResult)
    }

    /// The category a selection navigates to; nil (a cleared selection)
    /// never navigates.
    static func destination(of item: SidebarItem?) -> SettingsCategory? {
        switch item {
        case .category(let category): return category
        case .searchResult(let result): return result.category
        case nil: return nil
        }
    }
}
