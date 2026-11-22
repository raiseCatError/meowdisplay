// Pure edit session behind receiver-side Display Arrangement editing: move the
// Mac's displays, snap them edge to edge, check the result, and produce the
// origins the Mac is asked to apply. The Mac runs the same checks again on its
// own current displays before it asks its owner (Mac/DisplayArrangementService.swift),
// so nothing here is trusted on its own.
//
// Compiled into the iOS/Mac receiver targets, the Mac sender and the hostless
// Mac test target (see MacTests/DisplayArrangementEditTests.swift).
// Foundation + CoreGraphics only, so it stays platform-neutral. No UI here.
//
// World space is the Mac's global point space (y grows down), as in
// Shared/DisplayOverviewModel.swift.

import CoreGraphics
import Foundation

/// Why an arrangement can't be applied. `wireReason` is the `reason` of a
/// `displayArrangeState` `denied` (PROTOCOL.md 6.10, Display arrangement).
enum DisplayArrangementProblem: Error, Equatable, Sendable {
    /// Nothing to change.
    case empty
    /// The id is not one of the displays being arranged.
    case unknownDisplay(UInt32)
    /// A non-finite, fractional or out-of-range origin: macOS takes whole points only.
    case invalidOrigin(UInt32)
    /// A display that mirrors another was moved on its own; the mirror group moves together.
    case mirrorMember(UInt32)
    /// Another session's MeowDisplay screen: that device owns where it goes.
    case notMovable(UInt32)
    /// The two displays overlap.
    case overlap(UInt32, UInt32)
    /// The display shares no edge with the rest of the arrangement.
    case disconnected(UInt32)
    /// No main display among the displays (macOS keeps the main display at 0,0).
    case noMainDisplay

    var wireReason: String {
        switch self {
        case .empty: return "empty"
        case .unknownDisplay: return "unknownDisplay"
        case .invalidOrigin: return "invalidOrigin"
        case .mirrorMember: return "mirrorMember"
        case .notMovable: return "notMovable"
        case .overlap: return "overlap"
        case .disconnected: return "disconnected"
        case .noMainDisplay: return "noMain"
        }
    }
}

/// One drawn display of an arrangement edit (a mirror group counts once, at its primary).
struct ArrangementDisplay: Equatable, Sendable, Identifiable {
    let id: UInt32
    let name: String
    /// Global Mac points; the origin is what an edit changes.
    var frame: CGRect
    /// The main display, or a mirror group containing it.
    let isMain: Bool
    /// Displays mirroring this one: they move with it and are never moved on their own.
    let mirrorMemberIDs: [UInt32]
    /// This session's own virtual display.
    let isOwn: Bool
    /// A MeowDisplay virtual display of any session.
    let isMeow: Bool
    /// False for another session's MeowDisplay screen (or a group containing one).
    let isMovable: Bool
}

/// An edit of the Mac's display arrangement. Moving proposes origins; `validate()` says whether
/// macOS could take them; `changedOrigins` is what would be sent (main display at 0,0, changed
/// displays only).
struct DisplayArrangementEdit: Equatable, Sendable {
    /// Largest coordinate accepted (far beyond any real arrangement, far inside `Int32`, so a
    /// hostile value can never trap a conversion on the Mac).
    static let maxCoordinate: CGFloat = 32_768
    /// The shortest shared edge that keeps two displays connected, in points.
    static let minimumSharedEdge: CGFloat = 1
    /// Default snap distance in world points (the editor passes one scaled to the finger).
    static let defaultSnapDistance: CGFloat = 96

    /// The arrangement the edit started from (drawn displays, reading order).
    private(set) var original: [ArrangementDisplay]
    /// The proposed arrangement (same displays and order as `original`).
    private(set) var displays: [ArrangementDisplay]
    /// Mirror member id -> the drawn display it folds into.
    private let primaryByMember: [UInt32: UInt32]

    init(model: DisplayOverviewModel) {
        let groups = Dictionary(uniqueKeysWithValues: model.mirrorGroups.map { ($0.primaryID, $0.memberIDs) })
        var primaries: [UInt32: UInt32] = [:]
        var drawn: [ArrangementDisplay] = []
        for display in model.drawnDisplays {
            let memberIDs = groups[display.id] ?? []
            let members = memberIDs.compactMap { model.display(withID: $0) }
            for member in memberIDs { primaries[member] = display.id }
            let everyone = [display] + members
            let isMain = everyone.contains(where: { $0.isMain })
            let isMovable = everyone.allSatisfy({ !$0.isMeow || $0.isOwn })
            drawn.append(ArrangementDisplay(
                id: display.id, name: display.name, frame: display.frame, isMain: isMain,
                mirrorMemberIDs: memberIDs, isOwn: display.isOwn, isMeow: display.isMeow, isMovable: isMovable))
        }
        self.original = drawn
        self.displays = drawn
        self.primaryByMember = primaries
    }

    /// Builds the edit from every display (mirror members included), as listed by the Mac.
    init(displays: [OverviewDisplay]) {
        self.init(model: DisplayOverviewModel(displays: displays))
    }

    // MARK: Reading

    func display(withID id: UInt32) -> ArrangementDisplay? {
        displays.first { $0.id == id }
    }

    /// The drawn display a mirror member folds into; nil for a drawn display or an unknown id.
    func primaryID(ofMirrorMember id: UInt32) -> UInt32? { primaryByMember[id] }

    /// Union of the proposed frames; `.zero` when empty.
    var bounds: CGRect { Self.union(displays.map(\.frame)) }

    /// Union of the original frames; `.zero` when empty.
    var originalBounds: CGRect { Self.union(original.map(\.frame)) }

    /// Every drawn display's origin with the main display moved to 0,0 (the whole arrangement
    /// translated with it). Unchanged when there is no main display.
    var normalizedOrigins: [UInt32: CGPoint] { Self.normalized(displays) }

    /// The displays whose normalized origin differs from where they started: what is sent.
    var changedOrigins: [UInt32: CGPoint] {
        let before = Self.normalized(original)
        return normalizedOrigins.filter { entry in before[entry.key] != entry.value }
    }

    var isChanged: Bool { !changedOrigins.isEmpty }

    /// The first reason the proposed arrangement can't be applied, nil when it can.
    func validate() -> DisplayArrangementProblem? {
        Self.problem(in: displays, original: original)
    }

    /// Keep confirms the Mac saved these normalized positions. Start the next edit from them
    /// even when the new catalog arrived while the consent flow was still busy.
    mutating func acceptKeptArrangement() {
        let origins = normalizedOrigins
        for index in displays.indices {
            let id = displays[index].id
            if let origin = origins[id] { displays[index].frame.origin = origin }
        }
        original = displays
    }

    // MARK: Editing

    /// Moves `id` to `proposedOrigin`, snapped (see `snapped`). False (nothing moves) for an
    /// unknown id or a display that may not move. An invalid result is kept: the editor shows
    /// it with its reason, and nothing invalid can be sent.
    @discardableResult
    mutating func move(_ id: UInt32, to proposedOrigin: CGPoint, snapDistance: CGFloat = defaultSnapDistance,
                       alignDistance: CGFloat? = nil) -> Bool {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].isMovable,
              proposedOrigin.x.isFinite, proposedOrigin.y.isFinite else { return false }
        displays[index].frame.origin = snapped(id, to: proposedOrigin, snapDistance: snapDistance,
                                               alignDistance: alignDistance)
        return true
    }

    /// Back to where the edit started.
    mutating func reset() { displays = original }

    /// Where `id` lands when dragged to `proposedOrigin`: the nearest position touching another
    /// display edge to edge (sharing at least `minimumSharedEdge` of that edge, overlapping
    /// nothing) within `snapDistance` world points, with its edges or centre aligned to that
    /// display when within `alignDistance` (default: half the snap distance). Farther than
    /// that, the proposed origin rounded to whole points. Unknown ids answer the rounded origin.
    func snapped(_ id: UInt32, to proposedOrigin: CGPoint, snapDistance: CGFloat = defaultSnapDistance,
                 alignDistance: CGFloat? = nil) -> CGPoint {
        let free = CGPoint(x: Self.clampedCoordinate(proposedOrigin.x), y: Self.clampedCoordinate(proposedOrigin.y))
        guard let moving = display(withID: id) else { return free }
        let reach = snapDistance.isFinite ? max(snapDistance, 0) : 0
        let align: CGFloat
        if let alignDistance { align = alignDistance.isFinite ? max(alignDistance, 0) : 0 } else { align = reach / 2 }
        let size = moving.frame.size
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for other in displays where other.id != id {
            for candidate in Self.adjacentOrigins(size: size, near: free, beside: other.frame, align: align) {
                let rect = CGRect(origin: candidate, size: size)
                guard !displays.contains(where: { $0.id != id && Self.overlaps($0.frame, rect) }) else { continue }
                let distance = hypot(candidate.x - free.x, candidate.y - free.y)
                if distance <= reach, distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
        }
        return best ?? free
    }

    // MARK: Requests (the Mac's check)

    /// Applies a receiver's requested origins to this edit (built from the Mac's CURRENT displays)
    /// and answers the normalized changed origins to configure, or why not. A mirror member may be
    /// listed only at the same origin as its primary (it is then folded into it); every other id
    /// must be a drawn display. The whole result is validated, not just the listed displays.
    func proposal(applying origins: [UInt32: CGPoint]) -> Result<[UInt32: CGPoint], DisplayArrangementProblem> {
        guard !origins.isEmpty else { return .failure(.empty) }
        var next = self
        let ids = origins.keys.sorted()
        for id in ids where primaryByMember[id] == nil {
            guard let index = next.displays.firstIndex(where: { $0.id == id }) else { return .failure(.unknownDisplay(id)) }
            guard let origin = origins[id], Self.isValidOrigin(origin) else { return .failure(.invalidOrigin(id)) }
            guard next.displays[index].isMovable || next.displays[index].frame.origin == origin else {
                return .failure(.notMovable(id))
            }
            next.displays[index].frame.origin = origin
        }
        for id in ids {
            guard let primary = primaryByMember[id], let origin = origins[id] else { continue }
            guard Self.isValidOrigin(origin) else { return .failure(.invalidOrigin(id)) }
            guard next.display(withID: primary)?.frame.origin == origin else { return .failure(.mirrorMember(id)) }
        }
        if let problem = next.validate() { return .failure(problem) }
        let changed = next.changedOrigins
        return changed.isEmpty ? .failure(.empty) : .success(changed)
    }

    // MARK: Geometry

    /// The first problem with `displays` (compared with `original` for displays that may not
    /// move), nil when macOS could take the arrangement.
    static func problem(in displays: [ArrangementDisplay], original: [ArrangementDisplay]) -> DisplayArrangementProblem? {
        guard !displays.isEmpty else { return .empty }
        if let bad = displays.first(where: { !isValidOrigin($0.frame.origin) }) { return .invalidOrigin(bad.id) }
        guard let main = displays.first(where: { $0.isMain }) else { return .noMainDisplay }

        let now = normalized(displays)
        let before = normalized(original)
        if let pinned = displays.first(where: { !$0.isMovable && before[$0.id] != nil && now[$0.id] != before[$0.id] }) {
            return .notMovable(pinned.id)
        }

        for i in displays.indices {
            for j in displays.indices where j > i && overlaps(displays[i].frame, displays[j].frame) {
                return .overlap(min(displays[i].id, displays[j].id), max(displays[i].id, displays[j].id))
            }
        }

        // Every display must reach the main display through shared edges.
        var reached: Set<UInt32> = [main.id]
        var frontier = [main]
        while let current = frontier.popLast() {
            for other in displays where !reached.contains(other.id) && sharesEdge(current.frame, other.frame) {
                reached.insert(other.id)
                frontier.append(other)
            }
        }
        if let lone = displays.first(where: { !reached.contains($0.id) }) { return .disconnected(lone.id) }
        return nil
    }

    /// True when both rectangles cover a common area (touching edges do not overlap).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0 && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0
    }

    /// True when the rectangles touch along an edge for at least `minimumSharedEdge` points
    /// (a corner alone is not a connection).
    static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let sharedX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let sharedY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let sideBySide = (a.maxX == b.minX || b.maxX == a.minX) && sharedY >= minimumSharedEdge
        let stacked = (a.maxY == b.minY || b.maxY == a.minY) && sharedX >= minimumSharedEdge
        return sideBySide || stacked
    }

    /// Whole points within `maxCoordinate`: what `CGConfigureDisplayOrigin` can take as-is.
    static func isValidOrigin(_ origin: CGPoint) -> Bool {
        isValidCoordinate(origin.x) && isValidCoordinate(origin.y)
    }

    private static func isValidCoordinate(_ value: CGFloat) -> Bool {
        value.isFinite && value == value.rounded() && abs(value) <= maxCoordinate
    }

    private static func normalized(_ displays: [ArrangementDisplay]) -> [UInt32: CGPoint] {
        let shift = displays.first(where: { $0.isMain })?.frame.origin ?? .zero
        var out: [UInt32: CGPoint] = [:]
        for display in displays {
            out[display.id] = CGPoint(x: display.frame.minX - shift.x, y: display.frame.minY - shift.y)
        }
        return out
    }

    private static func union(_ frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return .zero }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func clampedCoordinate(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value.rounded(), -maxCoordinate), maxCoordinate)
    }

    /// The four positions touching `other` (left, right, above, below), each placed along that
    /// edge as close to `near` as keeps a shared edge, then aligned when close.
    private static func adjacentOrigins(size: CGSize, near: CGPoint, beside other: CGRect, align: CGFloat) -> [CGPoint] {
        let y = alignedCross(near.y, length: size.height, start: other.minY, end: other.maxY, align: align)
        let x = alignedCross(near.x, length: size.width, start: other.minX, end: other.maxX, align: align)
        return [
            CGPoint(x: other.minX - size.width, y: y),
            CGPoint(x: other.maxX, y: y),
            CGPoint(x: x, y: other.minY - size.height),
            CGPoint(x: x, y: other.maxY),
        ]
    }

    /// Position along a neighbour's edge (`start...end`) for a side `length` long: clamped so at
    /// least `minimumSharedEdge` is shared, then snapped to start-, end- or centre-alignment when
    /// one is within `align`. Whole points.
    private static func alignedCross(_ value: CGFloat, length: CGFloat, start: CGFloat, end: CGFloat,
                                     align: CGFloat) -> CGFloat {
        let lowest = start - length + minimumSharedEdge
        let highest = end - minimumSharedEdge
        var position = lowest <= highest ? min(max(value, lowest), highest) : start
        let options: [CGFloat] = [start, end - length, ((start + end) / 2 - length / 2).rounded()]
        if let nearest = options.min(by: { abs($0 - position) < abs($1 - position) }), abs(nearest - position) <= align {
            position = nearest
        }
        return position.rounded()
    }
}

// MARK: - Wire

/// One `displayArrangeRequest` (PROTOCOL.md 6.10, Display arrangement): the origins to change
/// and the arrangement the receiver edited (`base`), so the Mac can refuse a stale catalog.
struct DisplayArrangeRequestMessage: Equatable, Sendable {
    struct BaseDisplay: Equatable, Sendable {
        let id: UInt32
        let frame: CGRect
    }

    let req: Int
    let origins: [UInt32: CGPoint]
    let base: [BaseDisplay]

    /// The receiver's message for an edit: its changed origins and its original drawn displays.
    init(req: Int, edit: DisplayArrangementEdit) {
        self.init(req: req, origins: edit.changedOrigins,
                  base: edit.original.map { BaseDisplay(id: $0.id, frame: $0.frame) })
    }

    init(req: Int, origins: [UInt32: CGPoint], base: [BaseDisplay]) {
        self.req = req
        self.origins = origins
        self.base = base
    }

    var wire: [String: Any] {
        var originEntries: [[String: Any]] = []
        for id in origins.keys.sorted() {
            guard let origin = origins[id] else { continue }
            originEntries.append(["id": Int(id), "x": Int(origin.x.rounded()), "y": Int(origin.y.rounded())])
        }
        let baseEntries: [[String: Any]] = base.map { b in
            ["id": Int(b.id), "x": Int(b.frame.minX.rounded()), "y": Int(b.frame.minY.rounded()),
             "w": Int(b.frame.width.rounded()), "h": Int(b.frame.height.rounded())]
        }
        return ["type": WireMessage.displayArrangeRequest, "req": req, "origins": originEntries, "base": baseEntries]
    }

    /// Bounded, defensive parsing on the Mac. Nil for a missing `req`, a malformed entry, a repeated
    /// id, more than `DisplayArrangeWire.maxDisplays` entries or a non-number coordinate. Fractional
    /// or huge numbers are kept, so validation names them (`invalidOrigin`).
    static func parse(_ obj: [String: Any]) -> DisplayArrangeRequestMessage? {
        guard let req = obj["req"] as? Int,
              let rawOrigins = obj["origins"] as? [Any], let rawBase = obj["base"] as? [Any],
              rawOrigins.count <= DisplayArrangeWire.maxDisplays, rawBase.count <= DisplayArrangeWire.maxDisplays
        else { return nil }
        var origins: [UInt32: CGPoint] = [:]
        for entry in rawOrigins {
            guard let o = entry as? [String: Any], let id = wireID(o["id"]), origins[id] == nil,
                  let x = wireNumber(o["x"]), let y = wireNumber(o["y"]) else { return nil }
            origins[id] = CGPoint(x: x, y: y)
        }
        var base: [BaseDisplay] = []
        var seen = Set<UInt32>()
        for entry in rawBase {
            guard let b = entry as? [String: Any], let id = wireID(b["id"]), seen.insert(id).inserted,
                  let x = wireNumber(b["x"]), let y = wireNumber(b["y"]),
                  let w = wireNumber(b["w"]), let h = wireNumber(b["h"]),
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
            base.append(BaseDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h)))
        }
        return DisplayArrangeRequestMessage(req: req, origins: origins, base: base)
    }

    /// A JSON number (never a boolean) that is a whole value in `UInt32` range.
    /// (`Double(UInt32.max)` is exact, so the range check is too.)
    private static func wireID(_ value: Any?) -> UInt32? {
        guard let d = wireNumber(value), d.isFinite, d == d.rounded(), d >= 0, d <= Double(UInt32.max) else { return nil }
        return UInt32(d)
    }

    /// A JSON number, never a boolean (`NSNumber` bridges both).
    private static func wireNumber(_ value: Any?) -> Double? {
        // `is Bool` can't tell: a JSON 0 or 1 bridges to Bool too. The boxed type can.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// One `displayArrangeState` as either side builds or reads it.
struct DisplayArrangeStateMessage: Equatable, Sendable {
    let req: Int
    let state: DisplayArrangeState
    let reason: String?
    /// Seconds until the Mac puts the old arrangement back (only with `applied`).
    let revertIn: Int?

    init(req: Int, state: DisplayArrangeState, reason: String? = nil, revertIn: Int? = nil) {
        self.req = req
        self.state = state
        self.reason = reason
        self.revertIn = revertIn
    }

    var wire: [String: Any] {
        var m: [String: Any] = ["type": WireMessage.displayArrangeState, "req": req, "state": state.rawValue]
        if let reason { m["reason"] = reason }
        if let revertIn { m["revertIn"] = revertIn }
        return m
    }

    /// Nil without a `req` or a known `state`. `reason` is cut to 32 characters, `revertIn` kept
    /// only within 1...60.
    static func parse(_ obj: [String: Any]) -> DisplayArrangeStateMessage? {
        guard let req = obj["req"] as? Int, let rawState = obj["state"] as? String,
              let state = DisplayArrangeState(rawValue: String(rawState.prefix(32))) else { return nil }
        let reason = (obj["reason"] as? String).map { String($0.prefix(32)) }
        let revertIn = (obj["revertIn"] as? Int).flatMap { (1...60).contains($0) ? $0 : nil }
        return DisplayArrangeStateMessage(req: req, state: state, reason: reason, revertIn: revertIn)
    }
}
