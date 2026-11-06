import Foundation

// Stage Peek, search and Launchpad on Apple receivers: the Mac's displays and
// apps, fuzzy search over apps and windows, and which stills to ask for next.
// Pure and Sendable; the Kotlin port (core/workspace/WorkspaceBrowse.kt) runs
// the same vectors (fixtures/workspace/search-vectors.json).

struct CatalogDisplayItem: Equatable, Sendable, Identifiable {
    var id: UInt32
    var name: String
    var width: Int
    var height: Int
    var isMain: Bool
    var isVirtual: Bool
}

/// One launchable Mac app (installed or running), from `appCatalog`.
struct MacAppItem: Equatable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var running: Bool
    var windowCount: Int
    var lastUsed: Date?
    var id: String { bundleID }
    static let finderBundle = "com.apple.finder"
    var isFinder: Bool { bundleID == Self.finderBundle }
}

enum WorkspaceSearch {
    /// Lowercased, accents folded, spaces collapsed.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 0 = no match. Exact > prefix > word prefix > initials > substring > in-order letters.
    static func score(_ rawQuery: String, _ rawText: String) -> Int {
        let q = normalize(rawQuery), t = normalize(rawText)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 900 - min(t.count - q.count, 99) }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 800 - min(t.count - q.count, 99) }
        let initials = String(words.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 700 }
        if let r = t.range(of: q) { return 600 - min(t.distance(from: t.startIndex, to: r.lowerBound), 99) }
        // Letters in order (typos aside): "gchr" finds "Google Chrome". Tighter runs score higher.
        // Three letters at least, or two-letter queries match nearly everything.
        guard q.count >= 3 else { return 0 }
        var ti = t.startIndex, gaps = 0, matched = 0
        for c in q where c != " " {
            guard let found = t[ti...].firstIndex(of: c) else { return 0 }
            gaps += t.distance(from: ti, to: found)
            ti = t.index(after: found)
            matched += 1
        }
        guard matched >= 2 else { return 0 }
        return max(1, 300 - gaps * 8)
    }

    struct Results: Equatable, Sendable {
        var apps: [MacAppItem]
        var windows: [CatalogWindowItem]
    }

    /// Apps by name (bundle id counts for less); windows by title and app name.
    static func search(_ query: String, apps: [MacAppItem], windows: [CatalogWindowItem]) -> Results {
        let q = normalize(query)
        guard !q.isEmpty else { return Results(apps: apps, windows: windows) }
        var scoredApps: [(MacAppItem, Int)] = []
        for a in apps {
            let s = max(score(q, a.name), score(q, a.bundleID) * 6 / 10)
            if s > 0 { scoredApps.append((a, s + (a.running ? 15 : 0))) }
        }
        scoredApps.sort { l, r in
            if l.1 != r.1 { return l.1 > r.1 }
            return l.0.name.localizedCaseInsensitiveCompare(r.0.name) == .orderedAscending
        }
        var scoredWindows: [(CatalogWindowItem, Int)] = []
        for w in windows {
            let s = max(score(q, w.title), score(q, w.app) * 9 / 10)
            if s > 0 { scoredWindows.append((w, s)) }
        }
        scoredWindows.sort { l, r in
            if l.1 != r.1 { return l.1 > r.1 }
            return l.0.title.localizedCaseInsensitiveCompare(r.0.title) == .orderedAscending
        }
        let rankedApps = scoredApps.map(\.0)
        let rankedWindows = scoredWindows.map(\.0)
        return Results(apps: rankedApps, windows: rankedWindows)
    }

    /// The carousel/Launchpad order: Finder, running apps (by name), then the rest (by name).
    static func carouselOrder(_ apps: [MacAppItem]) -> [MacAppItem] {
        apps.sorted { a, b in
            if a.isFinder != b.isFinder { return a.isFinder }
            if a.running != b.running { return a.running }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Recently used (last-used date, newest first), at most `limit`.
    static func recents(_ apps: [MacAppItem], limit: Int = 8) -> [MacAppItem] {
        Array(apps.filter { $0.lastUsed != nil && !$0.isFinder }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(limit))
    }
}

/// Which window stills to ask for next. Visible cards first, then the rest;
/// nothing is asked twice within `retryAfter`, failures back off, and a still
/// older than `refreshAfter` is refreshed.
struct ThumbnailRequestPlanner: Equatable, Sendable {
    static let refreshAfter: TimeInterval = 8
    static let retryAfter: TimeInterval = 2.5
    static let failureBackoff: TimeInterval = 12
    static let batch = 24

    private(set) var receivedAt: [UInt32: TimeInterval] = [:]
    private(set) var requestedAt: [UInt32: TimeInterval] = [:]
    private(set) var failedAt: [UInt32: TimeInterval] = [:]

    mutating func plan(priority: [UInt32], all: [UInt32], now: TimeInterval) -> [UInt32] {
        var seen = Set<UInt32>(), out: [UInt32] = []
        for id in priority + all where seen.insert(id).inserted {
            if let r = requestedAt[id], now - r < Self.retryAfter { continue }
            if let f = failedAt[id], now - f < Self.failureBackoff { continue }
            if let got = receivedAt[id], now - got < Self.refreshAfter { continue }
            out.append(id)
            if out.count == Self.batch { break }
        }
        for id in out { requestedAt[id] = now }
        return out
    }

    mutating func received(_ id: UInt32, now: TimeInterval) { receivedAt[id] = now; failedAt[id] = nil; requestedAt[id] = nil }
    mutating func failed(_ id: UInt32, now: TimeInterval) { failedAt[id] = now; requestedAt[id] = nil }
    mutating func forget(_ id: UInt32) { receivedAt[id] = nil; requestedAt[id] = nil; failedAt[id] = nil }
    mutating func reset() { self = ThumbnailRequestPlanner() }
}

/// Which app icons to ask the Mac for. Every app shown anywhere (pane and float titles, Stage
/// Peek, the dock) is asked for once per connection while its icon is missing; an ask still
/// unanswered is repeated with backoff, `maxAttempts` times at most, so a lost or unavailable
/// icon never turns into a loop. At most `batch` per message (the Mac's limit).
struct AppIconRequestPlanner: Equatable, Sendable {
    static let batch = 48
    static let firstRetry: TimeInterval = 4
    static let maxAttempts = 4
    /// Icons kept at most; past that the oldest not shown in a pane or float goes first.
    static let keep = 400

    struct Ask: Equatable, Sendable { var at: TimeInterval; var attempts: Int }
    private(set) var asked: [String: Ask] = [:]

    /// The wait after the `attempts`th ask: 4, 8, 16 s…
    static func retryDelay(after attempts: Int) -> TimeInterval { firstRetry * pow(2, Double(max(attempts - 1, 0))) }

    /// The icons to ask for now, in order: missing (`has` false), never asked or due again.
    mutating func plan(_ wanted: [String], has: (String) -> Bool, now: TimeInterval) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for b in wanted where !b.isEmpty && seen.insert(b).inserted && !has(b) {
            if let a = asked[b], a.attempts >= Self.maxAttempts || now - a.at < Self.retryDelay(after: a.attempts) { continue }
            out.append(b)
            if out.count == Self.batch { break }
        }
        for b in out { asked[b] = Ask(at: now, attempts: (asked[b]?.attempts ?? 0) + 1) }
        return out
    }

    /// Asked, not answered, and allowed another ask (what the retry asks for again).
    func outstanding(has: (String) -> Bool) -> [String] {
        asked.filter { $0.value.attempts < Self.maxAttempts && !has($0.key) }.map(\.key).sorted()
    }

    /// When the next outstanding ask is due (nil: nothing left to repeat).
    func nextRetry(has: (String) -> Bool) -> TimeInterval? {
        outstanding(has: has).compactMap { b in asked[b].map { $0.at + Self.retryDelay(after: $0.attempts) } }.min()
    }

    /// Its icon arrived: asked again only if it's dropped and wanted again later.
    mutating func received(_ bundle: String) { asked[bundle] = nil }
    /// The message never left (not connected): asked again next time.
    mutating func unsent(_ bundles: [String]) {
        for b in bundles { if let a = asked[b], a.attempts > 1 { asked[b]?.attempts -= 1 } else { asked[b] = nil } }
    }
    /// A new connection: everything still missing is asked for again.
    mutating func reset() { self = AppIconRequestPlanner() }

    /// Which icon to drop for a new one when `keep` are held: the oldest (`arrival` order) not
    /// shown in a pane or float. nil: keep them all (the new one isn't stored).
    static func evict(arrival: [String], shown: Set<String>) -> String? { arrival.first { !shown.contains($0) } }

    /// The letter on an app's placeholder icon: its name's first letter or digit. nil: a glyph.
    static func initial(of name: String) -> String? {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() }
    }
}
