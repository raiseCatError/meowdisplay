import Foundation

/// Which saved pairings are old copies. Reinstalling an app, a new test build or a renamed
/// device pairs again under a new id, so the Known Devices / Paired Macs list fills with
/// entries of the same name that can never connect again. Per name (ignoring case and spaces),
/// the newest pairing stays, and so does anything connected or nearby; the rest are old copies.
/// Nothing is removed without the owner confirming the exact list.
enum KnownDeviceCleanup {
    struct Entry: Equatable {
        var id: String
        var name: String
        var paired: Date?
        /// Connected now, or found nearby: never an old copy.
        var inUse: Bool
    }

    static func superseded(_ entries: [Entry]) -> [Entry] {
        let groups = Dictionary(grouping: entries) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var out: [Entry] = []
        for (_, group) in groups where group.count > 1 {
            let keep: Set<String>
            if group.contains(where: \.inUse) {
                keep = Set(group.filter(\.inUse).map(\.id))
            } else {
                let newest = group.max { ($0.paired ?? .distantPast, $0.id) < ($1.paired ?? .distantPast, $1.id) }
                keep = newest.map { [$0.id] } ?? []
            }
            out += group.filter { !keep.contains($0.id) && !$0.inUse }
        }
        return out.sorted { ($0.name, $0.paired ?? .distantPast) < ($1.name, $1.paired ?? .distantPast) }
    }
}
