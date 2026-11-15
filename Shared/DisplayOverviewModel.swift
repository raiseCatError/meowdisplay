// Pure model behind the receiver-side Multi-Display Overview: every display
// of the connected Mac in its real macOS arrangement.
//
// Compiled into the iOS/Mac receiver targets (presentation) and the hostless
// Mac test target (see MacTests/DisplayOverviewModelTests.swift).
// Foundation + CoreGraphics only, so it stays platform-neutral. No UI here.
//
// World space is the Mac's global point space: y grows DOWN (as in the
// `windowCatalog` `displays` entries, PROTOCOL.md), the origin may be
// negative, and units are points, not pixels.

import CoreGraphics
import Foundation

/// One display of the Mac, parsed from a `windowCatalog` `displays` entry
/// (`DisplayCatalogEntry.wire` on the Mac side).
struct OverviewDisplay: Equatable, Sendable, Identifiable {
    /// Largest accepted display name, matching what the Mac sends.
    static let maxNameLength = 80

    let id: UInt32
    var name: String
    /// Frame in global Mac points. When `hasArrangement` is false the origin
    /// is a placeholder until `DisplayOverviewModel` lays the entry out.
    var frame: CGRect
    /// Pixels per point; nil when the Mac did not report it.
    var scale: Double?
    /// Refresh rate in Hz; nil when unknown.
    var hz: Int?
    var isMain: Bool
    var isVirtual: Bool
    /// A MeowDisplay virtual display of any session (never live-previewed).
    var isMeow: Bool
    /// A virtual display owned by this session (implies `isMeow`).
    var isOwn: Bool
    /// The display this one mirrors, when the Mac reported it.
    var mirrorOf: UInt32?
    /// False for entries from older Macs that carry no `x`/`y`.
    var hasArrangement: Bool

    init(id: UInt32, name: String = "", frame: CGRect, scale: Double? = nil, hz: Int? = nil,
         isMain: Bool = false, isVirtual: Bool = false, isMeow: Bool = false, isOwn: Bool = false,
         mirrorOf: UInt32? = nil, hasArrangement: Bool = true) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
        self.hz = hz
        self.isMain = isMain
        self.isVirtual = isVirtual
        self.isMeow = isMeow || isOwn
        self.isOwn = isOwn
        self.mirrorOf = mirrorOf
        self.hasArrangement = hasArrangement
    }

    /// Parses one catalog entry; nil when it is malformed (missing/invalid id,
    /// or a non-finite or non-positive size). Optional keys that are invalid
    /// are treated as absent. Entries lacking either `x` or `y` get
    /// `hasArrangement == false` and a zero origin.
    init?(wire: [String: Any]) {
        guard let rawID = OverviewWire.integer(wire["id"]), rawID >= 0, rawID <= Int(UInt32.max),
              let w = OverviewWire.number(wire["w"]), let h = OverviewWire.number(wire["h"]),
              w.isFinite, h.isFinite, w > 0, h > 0
        else { return nil }
        let id = UInt32(rawID)

        var origin = CGPoint.zero
        var arranged = false
        if let x = OverviewWire.number(wire["x"]), let y = OverviewWire.number(wire["y"]),
           x.isFinite, y.isFinite {
            origin = CGPoint(x: x, y: y)
            arranged = true
        }

        var scale: Double?
        if let s = OverviewWire.number(wire["scale"]), s.isFinite, s > 0 { scale = s }
        var hz: Int?
        if let r = OverviewWire.integer(wire["hz"]), r > 0 { hz = r }
        var mirrorOf: UInt32?
        if let m = OverviewWire.integer(wire["mirrorOf"]), m >= 0, m <= Int(UInt32.max), UInt32(m) != id {
            mirrorOf = UInt32(m)
        }
        let name = (wire["name"] as? String).map { String($0.prefix(Self.maxNameLength)) } ?? ""

        self.init(id: id, name: name, frame: CGRect(x: origin.x, y: origin.y, width: w, height: h),
                  scale: scale, hz: hz,
                  isMain: OverviewWire.bool(wire["main"]), isVirtual: OverviewWire.bool(wire["virtual"]),
                  isMeow: OverviewWire.bool(wire["meow"]), isOwn: OverviewWire.bool(wire["own"]),
                  mirrorOf: mirrorOf, hasArrangement: arranged)
    }
}

/// A set of mirrored displays, drawn once at the primary's frame.
struct OverviewMirrorGroup: Equatable, Sendable {
    /// The display at the end of the `mirrorOf` chain; the one that is drawn.
    let primaryID: UInt32
    /// The displays mirroring the primary, in catalog order.
    let memberIDs: [UInt32]
    /// The primary's frame (global Mac points).
    let frame: CGRect
}

/// The Mac's displays in their arrangement, with hit-testing, placeholder
/// classification and reading-order selection.
struct DisplayOverviewModel: Equatable, Sendable {
    /// Most displays kept from one catalog.
    static let maxDisplays = 16

    enum SelectionStep: Sendable { case next, previous }

    /// Every accepted display (mirror members included), in catalog order,
    /// with fallback-laid-out frames where the Mac sent none.
    let displays: [OverviewDisplay]
    /// The displays that are actually drawn: mirror members are folded into
    /// their primary. Sorted in reading order.
    let drawnDisplays: [OverviewDisplay]
    /// Groups of mirrored displays (only groups with at least one member).
    let mirrorGroups: [OverviewMirrorGroup]
    /// The selected drawn display (never a mirror member), or nil when empty.
    private(set) var selected: UInt32?

    private let primaryByID: [UInt32: UInt32]

    /// Parses the catalog's `displays` array. Malformed entries and repeated
    /// ids are dropped; at most `maxDisplays` valid entries are kept.
    init(catalog: [[String: Any]]) {
        self.init(displays: catalog.compactMap { OverviewDisplay(wire: $0) })
    }

    /// Same as `init(catalog:)` for an untyped JSON value; anything that is
    /// not an array of dictionaries yields an empty model.
    init(catalogValue: Any?) {
        let entries = (catalogValue as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        self.init(catalog: entries)
    }

    /// Builds the model from the receiver's parsed catalog. Items carrying no arrangement data (older
    /// Macs, or when `overview` is nil) are built from their id, name, size and main/virtual flags, so
    /// the model lays them out in its fallback row with `hasArrangement == false`. Items without a
    /// positive size are dropped.
    init(catalog items: [CatalogDisplayItem]) {
        self.init(displays: items.compactMap { item in
            if let overview = item.overview { return overview }
            guard item.width > 0, item.height > 0 else { return nil }
            return OverviewDisplay(id: item.id, name: String(item.name.prefix(OverviewDisplay.maxNameLength)),
                                   frame: CGRect(x: 0, y: 0, width: CGFloat(item.width), height: CGFloat(item.height)),
                                   isMain: item.isMain, isVirtual: item.isVirtual, hasArrangement: false)
        })
    }

    init(displays input: [OverviewDisplay]) {
        var seen = Set<UInt32>()
        var kept: [OverviewDisplay] = []
        for display in input where seen.insert(display.id).inserted {
            kept.append(display)
            if kept.count == Self.maxDisplays { break }
        }

        // Mirror resolution only needs ids, so it precedes layout.
        var mirrorTargets: [UInt32: UInt32] = [:]
        for display in kept { mirrorTargets[display.id] = display.mirrorOf }
        var primaries: [UInt32: UInt32] = [:]
        for display in kept {
            primaries[display.id] = Self.primaryID(of: display.id, mirrorTargets: mirrorTargets, listed: seen)
        }

        let laidOut = Self.applyFallbackLayout(kept, primaryByID: primaries)
        let drawn = laidOut.filter { primaries[$0.id] == $0.id }.sorted(by: Self.readingOrder)

        var groups: [OverviewMirrorGroup] = []
        for primary in drawn {
            let members = laidOut.filter { $0.id != primary.id && primaries[$0.id] == primary.id }.map { $0.id }
            if !members.isEmpty {
                groups.append(OverviewMirrorGroup(primaryID: primary.id, memberIDs: members, frame: primary.frame))
            }
        }

        self.displays = laidOut
        self.drawnDisplays = drawn
        self.mirrorGroups = groups
        self.primaryByID = primaries
        self.selected = (drawn.first(where: { $0.isMain }) ?? drawn.first)?.id
    }

    // MARK: Geometry

    /// False when any display came without `x`/`y` (an older Mac), so the
    /// layout is a guess rather than the real arrangement.
    var hasArrangement: Bool { displays.allSatisfy { $0.hasArrangement } }

    /// Union of the drawn frames (a mirror group counts once, at its
    /// primary). `.zero` for an empty model.
    var arrangementBounds: CGRect {
        guard let first = drawnDisplays.first else { return .zero }
        return drawnDisplays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    func display(withID id: UInt32) -> OverviewDisplay? {
        displays.first { $0.id == id }
    }

    /// The drawn display containing `worldPoint` (global Mac points), or nil
    /// in the gaps between displays. A mirror group answers with its primary.
    func display(at worldPoint: CGPoint) -> OverviewDisplay? {
        drawnDisplays.first { $0.frame.contains(worldPoint) }
    }

    /// The id of the drawn display `id` is folded into (itself unless it is a
    /// mirror member); nil for an unknown id.
    func drawnID(for id: UInt32) -> UInt32? { primaryByID[id] }

    /// True for MeowDisplay virtual displays (`own` or `meow`): these must
    /// never be live-captured for the overview, or a preview would show
    /// itself recursively. False for unknown ids.
    func isPlaceholder(_ id: UInt32) -> Bool {
        guard let display = display(withID: id) else { return false }
        return display.isOwn || display.isMeow
    }

    // MARK: Selection

    /// Selects `id` (a mirror member selects its primary). False and no
    /// change for an unknown id.
    @discardableResult
    mutating func select(id: UInt32) -> Bool {
        guard let drawn = primaryByID[id] else { return false }
        selected = drawn
        return true
    }

    /// Moves the selection to the next/previous drawn display in reading
    /// order, wrapping around.
    mutating func select(_ step: SelectionStep) {
        guard !drawnDisplays.isEmpty else { selected = nil; return }
        guard let current = selected, let index = drawnDisplays.firstIndex(where: { $0.id == current }) else {
            selected = drawnDisplays.first?.id
            return
        }
        let count = drawnDisplays.count
        let target = step == .next ? (index + 1) % count : (index + count - 1) % count
        selected = drawnDisplays[target].id
    }

    // MARK: Internals

    /// Top-to-bottom, then left-to-right by frame origin; id breaks ties.
    private static func readingOrder(_ a: OverviewDisplay, _ b: OverviewDisplay) -> Bool {
        if a.frame.origin.y != b.frame.origin.y { return a.frame.origin.y < b.frame.origin.y }
        if a.frame.origin.x != b.frame.origin.x { return a.frame.origin.x < b.frame.origin.x }
        return a.id < b.id
    }

    /// Follows `mirrorOf` through listed displays to the one that is drawn.
    /// A cycle (never produced by macOS) resolves to its lowest id, so every
    /// member of it agrees on one primary.
    private static func primaryID(of id: UInt32, mirrorTargets: [UInt32: UInt32],
                                  listed: Set<UInt32>) -> UInt32 {
        var path: [UInt32] = [id]
        var current = id
        while let next = mirrorTargets[current], listed.contains(next) {
            if let loopStart = path.firstIndex(of: next) {
                return path[loopStart...].min() ?? current
            }
            path.append(next)
            current = next
        }
        return current
    }

    /// Entries without `x`/`y` are placed left to right after the positioned
    /// ones (top-aligned with them); mirror members without a position share
    /// their primary's origin.
    private static func applyFallbackLayout(_ input: [OverviewDisplay],
                                            primaryByID: [UInt32: UInt32]) -> [OverviewDisplay] {
        var result = input
        let positioned = input.filter { primaryByID[$0.id] == $0.id && $0.hasArrangement }
        var cursorX = positioned.map { $0.frame.maxX }.max() ?? 0
        let rowY = positioned.map { $0.frame.minY }.min() ?? 0

        for index in result.indices where primaryByID[result[index].id] == result[index].id
            && !result[index].hasArrangement {
            result[index].frame.origin = CGPoint(x: cursorX, y: rowY)
            cursorX = result[index].frame.maxX
        }
        var originByID: [UInt32: CGPoint] = [:]
        for display in result { originByID[display.id] = display.frame.origin }
        for index in result.indices where primaryByID[result[index].id] != result[index].id
            && !result[index].hasArrangement {
            if let primary = primaryByID[result[index].id], let origin = originByID[primary] {
                result[index].frame.origin = origin
            }
        }
        return result
    }
}

/// Tolerant readers for JSON-shaped catalog values (Int, Double or NSNumber).
private enum OverviewWire {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Int: return Double(v)
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as CGFloat: return Double(v)
        case let v as Int64: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    /// A whole number within exact `Double` range, else nil.
    static func integer(_ value: Any?) -> Int? {
        guard let d = number(value), d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }

    static func bool(_ value: Any?) -> Bool {
        switch value {
        case let v as Bool: return v
        case let v as NSNumber: return v.boolValue
        default: return false
        }
    }
}
