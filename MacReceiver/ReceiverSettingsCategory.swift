import Foundation
import Combine

/// The Mac Receiver's Settings sidebar taxonomy. Same names and SF Symbols
/// as Mac Sender's `SettingsCategory` wherever the concept is shared, but
/// only the pages that hold real receiver functionality — there is no Input
/// page because this Mac only displays the stream (its keyboard and
/// trackpad are not forwarded to the sending Mac).
enum ReceiverSettingsCategory: String, CaseIterable, Identifiable {
    case overview, displays, streaming, devices, remoteAccess, system
    #if DEBUG
    case developer
    #endif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return String(localized: "Overview", comment: "Settings sidebar category.")
        case .displays: return String(localized: "Displays", comment: "Settings sidebar category.")
        case .streaming: return String(localized: "Streaming", comment: "Settings sidebar category.")
        case .devices: return String(localized: "Devices", comment: "Settings sidebar category.")
        case .remoteAccess: return String(localized: "Remote Access", comment: "Settings sidebar category.")
        case .system: return String(localized: "System", comment: "Settings sidebar category.")
        #if DEBUG
        case .developer: return String(localized: "Developer", comment: "Settings sidebar category.")
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.dashed"
        case .displays: return "display"
        case .streaming: return "antenna.radiowaves.left.and.right"
        case .devices: return "list.bullet.rectangle"
        case .remoteAccess: return "network"
        case .system: return "gearshape"
        #if DEBUG
        case .developer: return "wrench.and.screwdriver"
        #endif
        }
    }
}

/// A searchable Receiver setting or action for the sidebar search.
struct ReceiverSettingsSearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let category: ReceiverSettingsCategory
    let subtitle: String?
    let keywords: [String]
    let systemImage: String

    init(id: String, title: String, category: ReceiverSettingsCategory,
         keywords: [String] = [], systemImage: String? = nil, isCategory: Bool = false) {
        self.id = id
        self.title = title
        self.category = category
        self.subtitle = isCategory ? nil : category.label
        self.keywords = keywords
        self.systemImage = systemImage ?? category.systemImage
    }
}

/// Every setting and action the Receiver Settings window actually exposes —
/// nothing from the sender-only pages, so a result always opens a page that
/// has it. Ranking matches Mac Sender's `SettingsSearchIndex.search`.
struct ReceiverSettingsSearchIndex {
    static let shared = ReceiverSettingsSearchIndex()

    let allItems: [ReceiverSettingsSearchItem]

    init() {
        var items: [ReceiverSettingsSearchItem] = ReceiverSettingsCategory.allCases.map { category in
            let keywords: [String]
            switch category {
            case .overview:
                keywords = ["overview", "status", "waiting", "connected", "summary", "stream", "show window", "reconnect", "disconnect"]
            case .displays:
                keywords = ["display", "displays", "screen", "mode", "mirror", "extend", "video", "full screen", "window"]
            case .streaming:
                keywords = ["streaming", "stream", "profile", "fps", "frame rate", "codec", "audio", "sound", "sync"]
            case .devices:
                keywords = ["devices", "device", "mac", "paired", "pair", "forget", "nearby", "connect", "wake"]
            case .remoteAccess:
                keywords = ["remote", "remote access", "tailscale", "magicdns", "endpoint", "private network"]
            case .system:
                keywords = ["system", "preferences", "settings", "name", "reconnect", "overlay", "updates", "logs", "version"]
            #if DEBUG
            case .developer:
                keywords = ["developer", "debug", "wake", "diagnostics"]
            #endif
            }
            return ReceiverSettingsSearchItem(id: "category.\(category.id)", title: category.label,
                                              category: category, keywords: keywords, isCategory: true)
        }

        items += [
            ReceiverSettingsSearchItem(
                id: "displays.video", title: String(localized: "Video"), category: .displays,
                keywords: ["video", "turn off video", "stream video"], systemImage: "video"),
            ReceiverSettingsSearchItem(
                id: "displays.mode", title: String(localized: "Display Mode"), category: .displays,
                keywords: ["mode", "display mode", "mirror", "extend"], systemImage: "rectangle.on.rectangle"),
            ReceiverSettingsSearchItem(
                id: "displays.mirror", title: String(localized: "Mirror Display"), category: .displays,
                keywords: ["mirror", "mirroring", "clone", "physical display", "source"], systemImage: "rectangle.on.rectangle"),
            ReceiverSettingsSearchItem(
                id: "displays.extend", title: String(localized: "Extend Shape"), category: .displays,
                keywords: ["extend", "shape", "aspect ratio", "use full display"], systemImage: "rectangle.badge.plus"),
            ReceiverSettingsSearchItem(
                id: "displays.fullScreen", title: String(localized: "Open in Full Screen"), category: .displays,
                keywords: ["full screen", "fullscreen", "window", "green button"],
                systemImage: "arrow.up.left.and.arrow.down.right"),

            ReceiverSettingsSearchItem(
                id: "streaming.profile", title: String(localized: "Streaming Profile"), category: .streaming,
                keywords: ["profile", "performance", "quality", "custom", "frame rate", "fps"], systemImage: "gearshape.2"),
            ReceiverSettingsSearchItem(
                id: "streaming.priority", title: String(localized: "Streaming Priority"), category: .streaming,
                keywords: ["priority", "latency", "smoothness"], systemImage: "slider.horizontal.3"),
            ReceiverSettingsSearchItem(
                id: "streaming.maxFPS", title: String(localized: "Maximum FPS"), category: .streaming,
                keywords: ["maximum fps", "max fps", "frame rate", "cap", "limit", "enforce"], systemImage: "speedometer"),
            ReceiverSettingsSearchItem(
                id: "streaming.codec", title: String(localized: "Codec"), category: .streaming,
                keywords: ["codec", "hevc", "h.264", "h264", "h.265"], systemImage: "film"),
            ReceiverSettingsSearchItem(
                id: "streaming.audio", title: String(localized: "Audio"), category: .streaming,
                keywords: ["audio", "sound", "speaker", "volume"], systemImage: "speaker.wave.2"),
            ReceiverSettingsSearchItem(
                id: "streaming.avSync", title: String(localized: "A/V Sync"), category: .streaming,
                keywords: ["a/v sync", "av sync", "lip sync", "delay", "offset", "latency", "resync"], systemImage: "waveform"),

            ReceiverSettingsSearchItem(
                id: "devices.paired", title: String(localized: "Paired Macs"), category: .devices,
                keywords: ["paired", "known devices", "forget", "forget device", "connect", "wake & connect"],
                systemImage: "list.bullet.rectangle"),
            ReceiverSettingsSearchItem(
                id: "devices.nearby", title: String(localized: "Nearby Macs"), category: .devices,
                keywords: ["nearby", "pair", "pairing", "discover"], systemImage: "wifi"),

            ReceiverSettingsSearchItem(
                id: "remoteAccess.endpoint", title: String(localized: "Remote Endpoint"), category: .remoteAccess,
                keywords: ["remote endpoint", "endpoint", "tailscale", "magicdns", "ip address", "port"], systemImage: "network"),

            ReceiverSettingsSearchItem(
                id: "system.name", title: String(localized: "Receiver Name"), category: .system,
                keywords: ["name", "receiver name", "advertised name", "bonjour"], systemImage: "character.cursor.ibeam"),
            ReceiverSettingsSearchItem(
                id: "system.autoReconnect", title: String(localized: "Auto-Reconnect"), category: .system,
                keywords: ["auto-reconnect", "reconnect", "automatic connection"], systemImage: "arrow.triangle.2.circlepath"),
            ReceiverSettingsSearchItem(
                id: "system.overlay", title: String(localized: "Performance Overlay"), category: .system,
                keywords: ["performance overlay", "hud", "analytics", "stats", "graphs"], systemImage: "chart.xyaxis.line"),
            ReceiverSettingsSearchItem(
                id: "system.updates", title: String(localized: "Software Updates"), category: .system,
                keywords: ["updates", "sparkle", "check for updates", "software update"], systemImage: "arrow.down.circle"),
            ReceiverSettingsSearchItem(
                id: "system.logs", title: String(localized: "Logs"), category: .system,
                keywords: ["logs", "log files", "support", "diagnostics", "finder"], systemImage: "doc.text.magnifyingglass"),
        ]

        #if DEBUG
        items += [
            ReceiverSettingsSearchItem(
                id: "developer.wake", title: String(localized: "Wake Testing"), category: .developer,
                keywords: ["wake testing", "wake", "wake-on-lan"], systemImage: "bolt.badge.clock"),
            ReceiverSettingsSearchItem(
                id: "developer.promote", title: String(localized: "Promote Interactive Wake"), category: .developer,
                keywords: ["promote", "interactive wake", "dark wake"], systemImage: "bolt.badge.clock"),
        ]
        #endif

        allItems = items
    }

    /// Same scoring as Mac Sender: exact/prefix/substring matches on titles
    /// (top-level categories first), then the category name, then keywords.
    func search(query: String) -> [ReceiverSettingsSearchItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }

        let ranked: [(item: ReceiverSettingsSearchItem, score: Int)] = allItems.compactMap { item in
            let title = item.title.lowercased()
            let categoryLabel = item.category.label.lowercased()
            let isTopLevel = item.subtitle == nil
            let keywords = item.keywords.map { $0.lowercased() }

            let score: Int
            if title == clean {
                score = isTopLevel ? 100 : 90
            } else if title.hasPrefix(clean) {
                score = isTopLevel ? 80 : 70
            } else if title.contains(clean) {
                score = isTopLevel ? 60 : 50
            } else if categoryLabel == clean {
                score = 45
            } else if categoryLabel.hasPrefix(clean) {
                score = 40
            } else if categoryLabel.contains(clean) {
                score = 35
            } else if keywords.contains(clean) {
                score = 30
            } else if keywords.contains(where: { $0.hasPrefix(clean) }) {
                score = 25
            } else if keywords.contains(where: { $0.contains(clean) || clean.contains($0) }) {
                score = 20
            } else {
                return nil
            }
            return (item, score)
        }

        return ranked
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.title < $1.item.title }
            .map(\.item)
    }
}

/// Back/Forward history for the Receiver Settings window — the same
/// semantics as Mac Sender's `SettingsNavigationModel`: a new destination
/// pushes the current one and clears Forward; re-selecting the current page
/// is a no-op.
@MainActor
final class ReceiverSettingsNavigationModel: ObservableObject {
    @Published private(set) var current: ReceiverSettingsCategory
    @Published private(set) var backStack: [ReceiverSettingsCategory] = []
    @Published private(set) var forwardStack: [ReceiverSettingsCategory] = []

    init(initialCategory: ReceiverSettingsCategory = .overview) {
        current = initialCategory
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigateTo(_ category: ReceiverSettingsCategory) {
        guard category != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = category
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}

/// A sidebar row: a category, or a search result while searching.
enum ReceiverSidebarItem: Hashable {
    case category(ReceiverSettingsCategory)
    case searchResult(ReceiverSettingsSearchItem)
}

/// Receiver twin of Mac Sender's `SidebarSelection`: the sidebar binds
/// `List(selection:)` to view-owned `@State`, never to a Binding whose setter
/// mutates `ReceiverSettingsNavigationModel` — AppKit's list can write
/// selection back while SwiftUI is still applying an update, and publishing
/// navigation state there is illegal. The model is updated from `onChange`.
enum ReceiverSidebarSelection {
    static func derived(current: ReceiverSettingsCategory, isSearching: Bool,
                        results: [ReceiverSettingsSearchItem], selectedSearchItemID: String?) -> ReceiverSidebarItem? {
        guard isSearching else { return .category(current) }
        if let selectedSearchItemID, let match = results.first(where: { $0.id == selectedSearchItemID }) {
            return .searchResult(match)
        }
        return results.first { $0.category == current }.map(ReceiverSidebarItem.searchResult)
    }

    /// A cleared selection never navigates.
    static func destination(of item: ReceiverSidebarItem?) -> ReceiverSettingsCategory? {
        switch item {
        case .category(let category): return category
        case .searchResult(let result): return result.category
        case nil: return nil
        }
    }
}
