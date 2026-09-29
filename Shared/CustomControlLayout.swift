// iPad Custom control layouts: where controls APPEAR, never what they DO.
// Every placement points at an existing control — a Main tray item
// (`ControlTrayItem`, whose modifiers drive the one `ControlInteractionState`
// chord machine), a Function Tray item by its stable `ShortcutItem` id, or
// Move View — so shortcuts, chords and wire messages stay exactly where they
// already live. CoreGraphics + Foundation only (hostless-testable).

import CoreGraphics
import Foundation

/// Decodes an array while dropping elements that fail to decode, so one
/// entry written by a newer build can't make the whole blob unreadable.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(_ elements: [Element] = []) { self.elements = elements }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedElement.self)
            }
        }
        self.elements = elements
    }

    private struct DiscardedElement: Decodable {}
}

enum ControlCorner: String, Codable, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: return String(localized: "Top Left")
        case .topTrailing: return String(localized: "Top Right")
        case .bottomLeading: return String(localized: "Bottom Left")
        case .bottomTrailing: return String(localized: "Bottom Right")
        }
    }

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }

    /// The corner as a normalized point (0 or 1 on each axis).
    var unitPoint: CGPoint { CGPoint(x: isLeading ? 0 : 1, y: isTop ? 0 : 1) }
}

/// What a Custom placement shows. Resolves against existing models only.
enum CustomControlKind: Hashable, Codable {
    /// A Main tray item: a modifier, Escape, Tab, Toggle Dock, Keyboard or
    /// Settings.
    case tray(ControlTrayItem)
    /// A Function Tray item, by its stable `ShortcutItem.id`.
    case function(String)
    /// The receiver-local Move View mode toggle.
    case moveView
    /// A user-made one-tap keyboard shortcut, owned by this placement. Uses
    /// the same `ShortcutItem`/`KeyboardShortcut` model as every palette.
    case shortcut(ShortcutItem)

    private enum CodingKeys: String, CodingKey { case kind, value, shortcut }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "tray":
            let raw = try container.decode(String.self, forKey: .value)
            guard let item = ControlTrayItem(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container,
                                                       debugDescription: "Unknown tray item \(raw)")
            }
            self = .tray(item)
        case "function":
            self = .function(try container.decode(String.self, forKey: .value))
        case "moveView":
            self = .moveView
        case "shortcut":
            let item = try container.decode(ShortcutItem.self, forKey: .shortcut)
            guard case .keyboardShortcut(let shortcut) = item.action, shortcut.isValid else {
                throw DecodingError.dataCorruptedError(forKey: .shortcut, in: container,
                                                       debugDescription: "Invalid shortcut")
            }
            self = .shortcut(item)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "Unknown control kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tray(let item):
            try container.encode("tray", forKey: .kind)
            try container.encode(item.rawValue, forKey: .value)
        case .function(let id):
            try container.encode("function", forKey: .kind)
            try container.encode(id, forKey: .value)
        case .moveView:
            try container.encode("moveView", forKey: .kind)
        case .shortcut(let item):
            try container.encode("shortcut", forKey: .kind)
            try container.encode(item, forKey: .shortcut)
        }
    }

    var modifier: ControlModifier? {
        if case .tray(let item) = self { return item.modifier }
        return nil
    }

    /// Fires once on tap (a Function action or a one-tap shortcut), rather
    /// than joining the chord gesture.
    var isOneTapAction: Bool {
        switch self {
        case .function, .shortcut: return true
        case .tray, .moveView: return false
        }
    }
}

enum PaletteShape: String, Codable, CaseIterable, Identifiable {
    case arc
    case ring
    case row
    case column
    /// A ring of wedge-shaped segments around the modifier — see
    /// `WheelPaletteGeometry`.
    case wheel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wheel: return String(localized: "Wheel", comment: "Chord palette shape.")
        case .arc: return String(localized: "Arc", comment: "Chord palette shape.")
        case .ring: return String(localized: "Ring", comment: "Chord palette shape.")
        case .row: return String(localized: "Row", comment: "Chord palette shape.")
        case .column: return String(localized: "Column", comment: "Chord palette shape.")
        }
    }
}

/// How a modifier's chord palette blooms around it.
struct PalettePresentation: Codable, Equatable {
    static let spacingRange: ClosedRange<Double> = 0.8...2
    var shape = PaletteShape.arc
    /// Multiplier on the automatic bloom radius.
    var spacing = 1.0
    /// Bloom direction in degrees (0 = right, 90 = down); `nil` blooms
    /// toward the middle of the screen.
    var directionDegrees: Double?
}

struct CustomControlPlacement: Codable, Equatable, Identifiable {
    static let sizeRange: ClosedRange<Double> = 0.8...1.6

    var id: String
    var kind: CustomControlKind
    /// Center, normalized to the safe layout area (0...1 on each axis) so a
    /// layout reads the same on every iPad size.
    var x: Double
    var y: Double
    /// Per-control size multiplier on top of the global Control Size.
    var size: Double
    /// Modifiers only.
    var palette: PalettePresentation?

    init(id: String = UUID().uuidString, kind: CustomControlKind, x: Double, y: Double,
         size: Double = 1, palette: PalettePresentation? = nil) {
        self.id = id
        self.kind = kind
        self.x = Self.unit(x)
        self.y = Self.unit(y)
        self.size = Self.clampedSize(size)
        self.palette = palette ?? (kind.modifier != nil ? PalettePresentation() : nil)
    }

    static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    static func clampedSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, sizeRange.lowerBound), sizeRange.upperBound) : 1
    }
}

/// One orientation's layout.
struct CustomControlArrangement: Codable, Equatable {
    /// The corner the permanent cluster was built around — drives Two-Hand
    /// Assist's opposite side and the palette's bloom direction.
    var corner: ControlCorner
    var placements: [CustomControlPlacement]

    init(corner: ControlCorner, placements: [CustomControlPlacement]) {
        self.corner = corner
        self.placements = placements
    }

    private enum CodingKeys: String, CodingKey { case corner, placements }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        corner = try container.decodeIfPresent(ControlCorner.self, forKey: .corner) ?? .bottomTrailing
        placements = (try container.decodeIfPresent(LossyDecodableArray<CustomControlPlacement>.self,
                                                    forKey: .placements))?.elements ?? []
    }

    func placement(for modifier: ControlModifier) -> CustomControlPlacement? {
        placements.first { $0.kind.modifier == modifier }
    }

    /// Mean normalized center of the modifier anchors (or of everything,
    /// when there are none) — which side of the screen the permanent
    /// cluster lives on.
    var clusterCentroid: CGPoint {
        let anchors = placements.filter { $0.kind.modifier != nil }
        let points = (anchors.isEmpty ? placements : anchors).map { CGPoint(x: $0.x, y: $0.y) }
        guard !points.isEmpty else { return corner.unitPoint }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

struct CustomControlLayout: Codable, Equatable, Identifiable {
    static let maximumCount = 5
    static let defaultAssistActionIDs = ["undo", "redo", "zoom-in", "zoom-out"]

    var id: String
    var name: String
    var landscape: CustomControlArrangement
    var portrait: CustomControlArrangement
    var twoHandAssist: Bool
    /// Function Tray item ids shown on the opposite side while idle.
    var assistActionIDs: [String]
    /// Which Function Tray profile this layout's Function controls come
    /// from; `nil` follows the active one. The layout owns where; the
    /// profile owns what.
    var functionProfile: ControlProfileSlot?

    func arrangement(portrait isPortrait: Bool) -> CustomControlArrangement {
        isPortrait ? portrait : landscape
    }

    mutating func setArrangement(_ arrangement: CustomControlArrangement, portrait isPortrait: Bool) {
        if isPortrait { portrait = arrangement } else { landscape = arrangement }
    }

    /// The radial starter: both orientations built around `corner`, with
    /// Two-Hand Assist on.
    static func radialTemplate(id: String = UUID().uuidString, name: String,
                               corner: ControlCorner = .bottomTrailing) -> CustomControlLayout {
        CustomControlLayout(id: id, name: name,
                            landscape: .radialTemplate(corner: corner, portrait: false),
                            portrait: .radialTemplate(corner: corner, portrait: true),
                            twoHandAssist: true,
                            assistActionIDs: defaultAssistActionIDs)
    }
}

extension CustomControlArrangement {
    /// Reference safe-area sizes the template is authored against (an 11"
    /// iPad). Positions are stored normalized, so other sizes scale.
    static let referenceLandscape = CGSize(width: 1150, height: 780)
    static let referencePortrait = CGSize(width: 780, height: 1150)

    /// Where the template's Settings anchor sits, from each corner edge.
    static let templateAnchorInset: CGFloat = 34
    static let templateBaseDiameter: CGFloat = PadControlMetrics.baseItem
    static let templateSpacing: CGFloat = 8
    static let templateUtilities: [CustomControlKind] = [.tray(.keyboard), .tray(.escape), .tray(.tab), .moveView]
    static let templateModifiers: [ControlTrayItem] = [.command, .option, .control, .shift]
    /// Menu Bar, Dock, Show Desktop, Control Center — the Strip's system group.
    static let templateSystem: [CustomControlKind] = [.function("menu-bar"), .tray(.dock),
                                                     .function("show-desktop"), .function("control-center")]
    static let utilitySize = 0.9
    static let settingsSize = 0.9

    /// The radial corner template, as true concentric arcs around Settings:
    /// Settings (the anchor) → a utility arc (Keyboard, Escape, Tab, Move
    /// View) → the modifier arc (⌘ ⌥ ⌃ ⇧). A held chord's palette blooms on
    /// the next arc out (`CustomLayoutGeometry.palettePoints`).
    static func radialTemplate(corner: ControlCorner, portrait: Bool) -> CustomControlArrangement {
        let reference = portrait ? referencePortrait : referenceLandscape
        let inset = templateAnchorInset
        let origin = CGPoint(x: corner.isLeading ? inset : reference.width - inset,
                             y: corner.isTop ? inset : reference.height - inset)
        let edges = CGSize(width: inset, height: inset)
        let base = templateBaseDiameter
        let utilityDiameter = base * CGFloat(utilitySize)
        let radii = CornerArcGeometry.layerRadii(
            counts: [templateUtilities.count, templateModifiers.count],
            diameters: [utilityDiameter, base],
            innerDiameter: base * CGFloat(settingsSize), spacing: templateSpacing,
            corner: corner, edgeDistances: edges)
        func normalized(_ point: CGPoint) -> (Double, Double) {
            (Double(point.x / reference.width), Double(point.y / reference.height))
        }
        var placements: [CustomControlPlacement] = []
        let settings = normalized(origin)
        placements.append(CustomControlPlacement(id: "settings", kind: .tray(.settings),
                                                 x: settings.0, y: settings.1, size: settingsSize))
        let utilityPoints = CornerArcGeometry.points(count: templateUtilities.count, radius: radii[0],
                                                     origin: origin, corner: corner,
                                                     diameter: utilityDiameter, edgeDistances: edges)
        for (kind, point) in zip(templateUtilities, utilityPoints) {
            let p = normalized(point)
            placements.append(CustomControlPlacement(id: kind.stableID, kind: kind, x: p.0, y: p.1, size: utilitySize))
        }
        let modifierPoints = CornerArcGeometry.points(count: templateModifiers.count, radius: radii[1],
                                                      origin: origin, corner: corner,
                                                      diameter: base, edgeDistances: edges)
        for (item, point) in zip(templateModifiers, modifierPoints) {
            let p = normalized(point)
            placements.append(CustomControlPlacement(id: item.rawValue, kind: .tray(item), x: p.0, y: p.1))
        }
        // System actions on the opposite corner's inner arc — inside the
        // arc Two-Hand Assist uses there, so the two never collide.
        let mirrored = CornerArcGeometry.mirroredHorizontally(corner)
        let mirroredOrigin = CGPoint(x: reference.width - origin.x, y: origin.y)
        let systemPoints = CornerArcGeometry.points(count: templateSystem.count, radius: radii[0],
                                                    origin: mirroredOrigin, corner: mirrored,
                                                    diameter: utilityDiameter, edgeDistances: edges)
        for (kind, point) in zip(templateSystem, systemPoints) {
            let p = normalized(point)
            placements.append(CustomControlPlacement(id: kind.stableID, kind: kind, x: p.0, y: p.1, size: utilitySize))
        }
        return CustomControlArrangement(corner: corner, placements: placements)
    }
}

extension CustomControlKind {
    /// A readable id for a template placement.
    var stableID: String {
        switch self {
        case .tray(let item): return item.rawValue
        case .function(let id): return id
        case .moveView: return "move-view"
        case .shortcut(let item): return item.id
        }
    }
}

/// Polar geometry for controls arranged on concentric quarter arcs around a
/// corner origin. Angles are in radians in a y-down space (0 = right,
/// π/2 = down). Each arc spans from the corner's horizontal edge to its
/// vertical edge, trimmed so every control stays clear of both edges, with
/// controls evenly spaced by angle.
enum CornerArcGeometry {
    /// Direction along the corner's horizontal edge, into the screen.
    static func horizontalEdgeAngle(_ corner: ControlCorner) -> CGFloat { corner.isLeading ? 0 : .pi }

    /// Signed sweep from the horizontal edge toward the vertical edge (±π/2).
    static func sweep(_ corner: ControlCorner) -> CGFloat {
        // leading+top: 0 → π/2 (+); trailing+top: π → π/2 (−);
        // leading+bottom: 0 → −π/2 (−); trailing+bottom: π → 3π/2 (+).
        (corner.isLeading == corner.isTop) ? .pi / 2 : -.pi / 2
    }

    /// Offsets from the horizontal edge (0...π/2) that keep a control of
    /// `diameter` on an arc of `radius` inside both edges. `edgeDistances`
    /// is the origin's distance to the vertical edge (width) and to the
    /// horizontal edge (height).
    static func usableOffsets(radius: CGFloat, diameter: CGFloat,
                              edgeDistances: CGSize) -> ClosedRange<CGFloat> {
        guard radius > 0 else { return (.pi / 4)...(.pi / 4) }
        func clearance(_ distance: CGFloat) -> CGFloat {
            asin(min(1, max(0, (diameter / 2 - distance) / radius)))
        }
        let lower = clearance(edgeDistances.height)
        let upper = .pi / 2 - clearance(edgeDistances.width)
        return lower <= upper ? lower...upper : ((lower + upper) / 2)...((lower + upper) / 2)
    }

    /// Evenly spaced angles for `count` controls on the arc of `radius`.
    static func angles(count: Int, radius: CGFloat, corner: ControlCorner, diameter: CGFloat,
                       edgeDistances: CGSize) -> [CGFloat] {
        guard count > 0 else { return [] }
        let usable = usableOffsets(radius: radius, diameter: diameter, edgeDistances: edgeDistances)
        let direction: CGFloat = sweep(corner) > 0 ? 1 : -1
        return (0..<count).map { index in
            let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let offset = usable.lowerBound + t * (usable.upperBound - usable.lowerBound)
            return horizontalEdgeAngle(corner) + direction * offset
        }
    }

    static func points(count: Int, radius: CGFloat, origin: CGPoint, corner: ControlCorner,
                       diameter: CGFloat, edgeDistances: CGSize) -> [CGPoint] {
        angles(count: count, radius: radius, corner: corner, diameter: diameter, edgeDistances: edgeDistances)
            .map { CGPoint(x: origin.x + radius * cos($0), y: origin.y + radius * sin($0)) }
    }

    /// Neighbors' center distance on an arc: the chord between angles.
    static func chord(radius: CGFloat, angle: CGFloat) -> CGFloat { 2 * radius * sin(abs(angle) / 2) }

    /// The smallest radius ≥ `minimum` whose arc holds `count` controls at
    /// least `pitch` apart (center to center).
    static func radius(count: Int, pitch: CGFloat, minimum: CGFloat, diameter: CGFloat,
                       corner: ControlCorner, edgeDistances: CGSize) -> CGFloat {
        guard count > 1 else { return minimum }
        var radius = max(minimum, 1)
        for _ in 0..<2000 {
            let usable = usableOffsets(radius: radius, diameter: diameter, edgeDistances: edgeDistances)
            let step = (usable.upperBound - usable.lowerBound) / CGFloat(count - 1)
            if chord(radius: radius, angle: step) >= pitch - 0.01 { return radius }
            radius += 1
        }
        return radius
    }

    /// How many controls fit on the arc of `radius` at least `pitch` apart.
    static func capacity(radius: CGFloat, pitch: CGFloat, diameter: CGFloat, edgeDistances: CGSize) -> Int {
        guard radius > 0, pitch > 0 else { return 1 }
        let usable = usableOffsets(radius: radius, diameter: diameter, edgeDistances: edgeDistances)
        let step = 2 * asin(min(1, pitch / (2 * radius)))
        guard step > 0 else { return 1 }
        return max(1, Int((usable.upperBound - usable.lowerBound) / step + 0.0001) + 1)
    }

    /// Radii for successive layers around an inner control of
    /// `innerDiameter`: each layer sits one `spacing` clear of the previous
    /// one, and is widened only as much as its own count requires.
    static func layerRadii(counts: [Int], diameters: [CGFloat], innerDiameter: CGFloat, spacing: CGFloat,
                           corner: ControlCorner, edgeDistances: CGSize) -> [CGFloat] {
        var radii: [CGFloat] = []
        var previousRadius: CGFloat = 0
        var previousDiameter = innerDiameter
        for (count, diameter) in zip(counts, diameters) {
            let minimum = previousRadius + previousDiameter / 2 + diameter / 2 + spacing
            let radius = self.radius(count: count, pitch: diameter + spacing, minimum: minimum,
                                     diameter: diameter, corner: corner, edgeDistances: edgeDistances)
            radii.append(radius)
            previousRadius = radius
            previousDiameter = diameter
        }
        return radii
    }

    static func mirroredHorizontally(_ corner: ControlCorner) -> ControlCorner {
        switch corner {
        case .topLeading: return .topTrailing
        case .topTrailing: return .topLeading
        case .bottomLeading: return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        }
    }
}

/// A Custom arrangement read as a corner cluster: the Settings anchor as
/// origin, and every modifier on the screen side of it, near its corner.
/// When an arrangement isn't one (controls dragged elsewhere), palettes and
/// Two-Hand Assist fall back to local geometry.
struct CornerCluster: Equatable {
    var origin: CGPoint
    var corner: ControlCorner
    /// The outermost modifier arc's radius.
    var modifierRadius: CGFloat
    /// The largest modifier diameter.
    var modifierDiameter: CGFloat
    /// The origin's distances to its vertical and horizontal area edges.
    var edgeDistances: CGSize

    static func resolve(arrangement: CustomControlArrangement, frames: [String: CGRect],
                        area: CGRect) -> CornerCluster? {
        guard let settings = arrangement.placements.first(where: { $0.kind == .tray(.settings) }),
              let settingsFrame = frames[settings.id] else { return nil }
        let origin = CGPoint(x: settingsFrame.midX, y: settingsFrame.midY)
        // The corner the anchor actually sits in — the stored corner can be
        // stale once the cluster has been dragged elsewhere.
        let corner: ControlCorner = origin.y < area.midY
            ? (origin.x < area.midX ? .topLeading : .topTrailing)
            : (origin.x < area.midX ? .bottomLeading : .bottomTrailing)
        let modifierFrames = arrangement.placements.filter { $0.kind.modifier != nil }.compactMap { frames[$0.id] }
        guard !modifierFrames.isEmpty else { return nil }
        let reach = min(area.width, area.height) * 0.5
        let inward = CGPoint(x: corner.isLeading ? 1 : -1, y: corner.isTop ? 1 : -1)
        var radius: CGFloat = 0
        for frame in modifierFrames {
            let dx = frame.midX - origin.x
            let dy = frame.midY - origin.y
            // On the screen side of the anchor (a little slack for edges).
            guard dx * inward.x >= -frame.width / 2, dy * inward.y >= -frame.height / 2 else { return nil }
            let distance = hypot(dx, dy)
            guard distance <= reach else { return nil }
            radius = max(radius, distance)
        }
        let edges = CGSize(width: corner.isLeading ? origin.x - area.minX : area.maxX - origin.x,
                           height: corner.isTop ? origin.y - area.minY : area.maxY - origin.y)
        return CornerCluster(origin: origin, corner: corner, modifierRadius: radius,
                             modifierDiameter: modifierFrames.map(\.width).max() ?? 0,
                             edgeDistances: CGSize(width: max(0, edges.width), height: max(0, edges.height)))
    }

    /// The same cluster mirrored across the area's vertical center line —
    /// Two-Hand Assist's opposite side.
    func mirrored(in area: CGRect) -> CornerCluster {
        CornerCluster(origin: CGPoint(x: area.minX + area.maxX - origin.x, y: origin.y),
                      corner: CornerArcGeometry.mirroredHorizontally(corner),
                      modifierRadius: modifierRadius, modifierDiameter: modifierDiameter,
                      edgeDistances: edgeDistances)
    }

    /// Palette keys on the arc(s) directly outside the modifier arc: the
    /// first ring one `spacing` beyond it; more keys than fit continue on
    /// the next ring out. Each ring's keys are spread evenly by angle.
    func palettePoints(count: Int, keyDiameter: CGFloat, spacing: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        let pitch = keyDiameter + spacing
        var radius = modifierRadius + modifierDiameter / 2 + keyDiameter / 2 + spacing
        var remaining = count
        var result: [CGPoint] = []
        while remaining > 0 {
            let fits = CornerArcGeometry.capacity(radius: radius, pitch: pitch, diameter: keyDiameter,
                                                  edgeDistances: edgeDistances)
            let ring = min(fits, remaining)
            result += CornerArcGeometry.points(count: ring, radius: radius, origin: origin, corner: corner,
                                               diameter: keyDiameter, edgeDistances: edgeDistances)
            remaining -= ring
            radius += pitch
        }
        return result
    }

    /// Controls on the modifier arc itself (Two-Hand Assist helpers and idle
    /// actions use the mirrored cluster's modifier arc).
    func modifierArcPoints(count: Int, diameter: CGFloat) -> [CGPoint] {
        CornerArcGeometry.points(count: count, radius: modifierRadius, origin: origin, corner: corner,
                                 diameter: diameter, edgeDistances: edgeDistances)
    }
}

// MARK: - Library (create / rename / delete / select)

extension ReceiverControlPreferences {
    var canCreateCustomLayout: Bool { customLayouts.count < CustomControlLayout.maximumCount }

    /// The selected Custom layout, falling back to the first one.
    var activeCustomLayout: CustomControlLayout? {
        customLayouts.first { $0.id == activeCustomLayoutID } ?? customLayouts.first
    }

    /// Creates a radial starter layout and selects it. `nil` once
    /// `CustomControlLayout.maximumCount` exist.
    @discardableResult
    mutating func createCustomLayout(corner: ControlCorner = .bottomTrailing,
                                     id: String = UUID().uuidString) -> String? {
        guard canCreateCustomLayout else { return nil }
        let layout = CustomControlLayout.radialTemplate(id: id, name: nextCustomLayoutName(), corner: corner)
        customLayouts.append(layout)
        activeCustomLayoutID = layout.id
        return layout.id
    }

    mutating func renameCustomLayout(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = customLayouts.firstIndex(where: { $0.id == id }) else { return }
        customLayouts[index].name = String(trimmed.prefix(40))
    }

    /// Deleting the active layout selects the first remaining one; deleting
    /// the last one leaves Custom mode with nothing to show, so the layout
    /// mode falls back to Overlay.
    mutating func deleteCustomLayout(_ id: String) {
        customLayouts.removeAll { $0.id == id }
        if activeCustomLayoutID == id { activeCustomLayoutID = customLayouts.first?.id }
        if customLayouts.isEmpty, padControlLayout == .custom { padControlLayout = .overlay }
    }

    mutating func updateCustomLayout(_ layout: CustomControlLayout) {
        guard let index = customLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        customLayouts[index] = layout
    }

    private func nextCustomLayoutName() -> String {
        let names = Set(customLayouts.map(\.name))
        var number = customLayouts.count + 1
        while names.contains(String(localized: "Custom Layout \(number)")) { number += 1 }
        return String(localized: "Custom Layout \(number)")
    }
}

// MARK: - Geometry

enum CustomLayoutGeometry {
    static let margin: CGFloat = 12

    /// The area normalized placements map into: the safe area, less a
    /// small margin, so nothing lands under the Home indicator or a
    /// rounded corner.
    static func layoutArea(container: CGRect, safeInsets: ControlSafeInsets) -> CGRect {
        let horizontalInset: CGFloat = safeInsets.leading + safeInsets.trailing + margin * 2
        let verticalInset: CGFloat = safeInsets.top + safeInsets.bottom + margin * 2
        let width: CGFloat = max(0, container.width - horizontalInset)
        let height: CGFloat = max(0, container.height - verticalInset)
        return CGRect(x: container.minX + safeInsets.leading + margin,
                      y: container.minY + safeInsets.top + margin,
                      width: width, height: height)
    }

    /// A placement's circle, clamped so all of it stays inside `area`.
    static func frame(for placement: CustomControlPlacement, in area: CGRect, baseDiameter: CGFloat) -> CGRect {
        let diameter = baseDiameter * CGFloat(CustomControlPlacement.clampedSize(placement.size))
        let center = CGPoint(x: area.minX + CGFloat(CustomControlPlacement.unit(placement.x)) * area.width,
                             y: area.minY + CGFloat(CustomControlPlacement.unit(placement.y)) * area.height)
        return PadEdgeGeometry.clamped(CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                              width: diameter, height: diameter), into: area)
    }

    /// The normalized position for a view point (the editor's drag), clamped
    /// to the area.
    static func normalizedPoint(for point: CGPoint, in area: CGRect) -> (x: Double, y: Double) {
        guard area.width > 0, area.height > 0 else { return (0.5, 0.5) }
        return (CustomControlPlacement.unit(Double((point.x - area.minX) / area.width)),
                CustomControlPlacement.unit(Double((point.y - area.minY) / area.height)))
    }

    /// Palette keys are a touch smaller than the controls they bloom from.
    static func paletteKeyDiameter(baseDiameter: CGFloat) -> CGFloat {
        baseDiameter * 0.92
    }

    /// Where a modifier's palette keys go: around `anchor`, shaped and
    /// spaced by `style`, blooming toward the middle of `area` unless
    /// `style` fixes a direction, and clear of the other controls. The one
    /// source for both the live overlay and the editor's preview.
    static func paletteCenters(count: Int, anchor: CGRect, style: PalettePresentation, area: CGRect,
                               baseDiameter: CGFloat, spacing: CGFloat, obstacles: [CGRect]) -> [CGPoint] {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let direction = style.directionDegrees.map { CGFloat($0) * .pi / 180 }
            ?? RadialPaletteLayout.direction(from: center, toward: CGPoint(x: area.midX, y: area.midY))
        let spread = CGFloat(min(max(style.spacing, PalettePresentation.spacingRange.lowerBound),
                                 PalettePresentation.spacingRange.upperBound))
        return RadialPaletteLayout.points(count: count, center: center, shape: style.shape,
                                          itemDiameter: paletteKeyDiameter(baseDiameter: baseDiameter),
                                          spacing: spacing, minimumRadius: baseDiameter * 1.5 * spread,
                                          direction: direction, bounds: area, obstacles: obstacles)
    }

    /// Every placement's resolved circle, by placement id.
    static func frames(for arrangement: CustomControlArrangement, in area: CGRect,
                       baseDiameter: CGFloat) -> [String: CGRect] {
        Dictionary(arrangement.placements.map { ($0.id, frame(for: $0, in: area, baseDiameter: baseDiameter)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Where the palette of the modifier placed at `anchorID` goes — the one
    /// source for the live overlay, the editor and Preview. A default
    /// (automatic arc) palette on a corner cluster blooms on the arc right
    /// outside the modifier arc; any other style blooms around its own
    /// modifier, clear of the other controls.
    static func palettePoints(count: Int, anchorID: String, arrangement: CustomControlArrangement,
                              frames: [String: CGRect], area: CGRect, baseDiameter: CGFloat,
                              spacing: CGFloat) -> [CGPoint] {
        guard count > 0, let anchor = frames[anchorID],
              let placement = arrangement.placements.first(where: { $0.id == anchorID }) else { return [] }
        let style = placement.palette ?? PalettePresentation()
        let keyDiameter = paletteKeyDiameter(baseDiameter: baseDiameter)
        if style.shape == .arc, style.directionDegrees == nil,
           let cluster = CornerCluster.resolve(arrangement: arrangement, frames: frames, area: area) {
            let inner = area.insetBy(dx: keyDiameter / 2, dy: keyDiameter / 2)
            return cluster.palettePoints(count: count, keyDiameter: keyDiameter, spacing: spacing * CGFloat(style.spacing))
                .map { CGPoint(x: min(max($0.x, inner.minX), inner.maxX), y: min(max($0.y, inner.minY), inner.maxY)) }
        }
        return paletteCenters(count: count, anchor: anchor, style: style, area: area, baseDiameter: baseDiameter,
                              spacing: spacing, obstacles: frames.filter { $0.key != anchorID }.map(\.value))
    }

    static let edgeSnapTolerance: CGFloat = 12

    /// Where a control of `diameter` dropped at `point` is stored.
    /// - Snap to Edges pulls it flush against the layout area's edges, or
    ///   onto its center lines, when it lands within `edgeSnapTolerance`.
    /// - Snap to Guides pulls it onto the nearest alignment-guide line.
    /// Guide display (Dots / Grid Lines) is editor chrome and never reaches
    /// the layout; only these stored positions do.
    static func droppedPosition(for point: CGPoint, in area: CGRect, diameter: CGFloat,
                                snapToEdges: Bool, snapToGuides: Bool) -> (x: Double, y: Double) {
        func edgeSnap(_ value: CGFloat, lower: CGFloat, upper: CGFloat, middle: CGFloat) -> CGFloat? {
            let tolerance = edgeSnapTolerance
            if abs(value - diameter / 2 - lower) <= tolerance { return lower + diameter / 2 }
            if abs(upper - value - diameter / 2) <= tolerance { return upper - diameter / 2 }
            if abs(value - middle) <= tolerance { return middle }
            return nil
        }
        var x = point.x
        var y = point.y
        var snappedX = false
        var snappedY = false
        if snapToEdges {
            if let edge = edgeSnap(x, lower: area.minX, upper: area.maxX, middle: area.midX) { x = edge; snappedX = true }
            if let edge = edgeSnap(y, lower: area.minY, upper: area.maxY, middle: area.midY) { y = edge; snappedY = true }
        }
        var position = normalizedPoint(for: CGPoint(x: x, y: y), in: area)
        if snapToGuides {
            if !snappedX { position.x = snapped(position.x) }
            if !snappedY { position.y = snapped(position.y) }
        }
        return position
    }

    /// Snaps a normalized coordinate to a 1/`divisions` grid when within
    /// `tolerance` of a line — the editor's alignment assist.
    static func snapped(_ value: Double, divisions: Int = 24, tolerance: Double = 0.012) -> Double {
        guard divisions > 0 else { return value }
        let step = 1 / Double(divisions)
        let nearest = (value / step).rounded() * step
        return abs(nearest - value) <= tolerance ? nearest : value
    }
}

/// Structured palette geometry: arc/fan, ring, row, or column around a
/// center, with collision avoidance against the other controls.
enum RadialPaletteLayout {
    /// The widest an arc fans before starting another, larger arc.
    static let maximumArcSpan: CGFloat = 150 * .pi / 180

    /// - Parameters:
    ///   - minimumRadius: distance from `center` to the first ring/line.
    ///   - direction: bloom direction in radians (y-down, 0 = right).
    ///   - obstacles: frames the keys must not overlap (other controls);
    ///     the radius grows until they're clear, a bounded number of times.
    static func points(count: Int, center: CGPoint, shape: PaletteShape,
                       itemDiameter: CGFloat, spacing: CGFloat,
                       minimumRadius: CGFloat, direction: CGFloat,
                       bounds: CGRect, obstacles: [CGRect] = []) -> [CGPoint] {
        guard count > 0, itemDiameter > 0, direction.isFinite, minimumRadius.isFinite else { return [] }
        if shape == .arc {
            return fan(count: count, center: center, itemDiameter: itemDiameter, spacing: spacing,
                       minimumRadius: max(minimumRadius, itemDiameter), direction: direction,
                       bounds: bounds, obstacles: obstacles)
        }
        if shape == .wheel {
            return WheelPaletteGeometry.layout(count: count, anchor: CGRect(x: center.x, y: center.y, width: 0, height: 0),
                                               keyDiameter: itemDiameter, spacing: spacing, bounds: bounds)?
                .segments.map(\.labelPoint) ?? []
        }
        var radius = max(minimumRadius, itemDiameter)
        var result = raw(count: count, center: center, shape: shape, diameter: itemDiameter,
                         spacing: spacing, radius: radius, direction: direction)
        for _ in 0..<10 where collides(result, diameter: itemDiameter, spacing: spacing, obstacles: obstacles) {
            radius += (itemDiameter + spacing) / 2
            result = raw(count: count, center: center, shape: shape, diameter: itemDiameter,
                         spacing: spacing, radius: radius, direction: direction)
        }
        let inner = bounds.insetBy(dx: itemDiameter / 2, dy: itemDiameter / 2)
        guard inner.width >= 0, inner.height >= 0 else { return result }
        return result.map { CGPoint(x: min(max($0.x, inner.minX), inner.maxX),
                                    y: min(max($0.y, inner.minY), inner.maxY)) }
    }

    /// An arc of evenly spaced keys at one radius around `center`, fanned
    /// into free space: the angular window closest to `direction` in which
    /// every key stays inside `bounds` and clear of `obstacles`. When no
    /// window is wide enough, the radius grows; more keys than one arc
    /// holds (≤ `maximumArcSpan`) continue on the next arc out.
    static func fan(count: Int, center: CGPoint, itemDiameter: CGFloat, spacing: CGFloat,
                    minimumRadius: CGFloat, direction: CGFloat, bounds: CGRect,
                    obstacles: [CGRect] = []) -> [CGPoint] {
        let pitch = itemDiameter + spacing
        let inner = bounds.insetBy(dx: itemDiameter / 2, dy: itemDiameter / 2)
        let reach = itemDiameter / 2 + spacing / 2
        func valid(_ angle: CGFloat, _ radius: CGFloat) -> Bool {
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            return inner.contains(point) && !obstacles.contains { $0.insetBy(dx: -reach, dy: -reach).contains(point) }
        }
        var result: [CGPoint] = []
        var radius = minimumRadius
        var remaining = count
        var attempts = 0
        while remaining > 0, attempts < 40 {
            attempts += 1
            let step = angularStep(pitch: pitch, radius: radius)
            let capacity = max(1, Int(maximumArcSpan / step + 0.0001) + 1)
            let inArc = min(capacity, remaining)
            let needed = step * CGFloat(inArc - 1)
            if let middle = window(needed: needed, preferred: direction, radius: radius, valid: valid) {
                for index in 0..<inArc {
                    let angle = middle + (CGFloat(index) - CGFloat(inArc - 1) / 2) * step
                    result.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
                }
                remaining -= inArc
                radius += pitch
            } else {
                radius += pitch / 2
            }
        }
        if remaining > 0 {
            // Nowhere fits (a tiny screen): fall back to the plain arc, clamped.
            let rest = raw(count: remaining, center: center, shape: .ring, diameter: itemDiameter,
                           spacing: spacing, radius: radius, direction: direction)
            result += rest.map { CGPoint(x: min(max($0.x, inner.minX), inner.maxX),
                                         y: min(max($0.y, inner.minY), inner.maxY)) }
        }
        return result
    }

    /// The center angle of a valid window `needed` radians wide, as close to
    /// `preferred` as the free arcs at `radius` allow; `nil` if none fits.
    private static func window(needed: CGFloat, preferred: CGFloat, radius: CGFloat,
                               valid: (CGFloat, CGFloat) -> Bool) -> CGFloat? {
        let samples = 720
        let sample = 2 * CGFloat.pi / CGFloat(samples)
        let flags = (0..<samples).map { valid(CGFloat($0) * sample, radius) }
        if flags.allSatisfy({ $0 }) { return preferred }
        guard let firstInvalid = flags.firstIndex(of: false) else { return preferred }
        // Walk once around, starting just after an invalid sample, collecting
        // the free arcs as [start, end] angles.
        var arcs: [(start: CGFloat, end: CGFloat)] = []
        var runStart: Int?
        for offset in 1...samples {
            let index = (firstInvalid + offset) % samples
            if flags[index] {
                if runStart == nil { runStart = firstInvalid + offset }
            } else if let start = runStart {
                arcs.append((CGFloat(start) * sample, CGFloat(firstInvalid + offset - 1) * sample))
                runStart = nil
            }
        }
        var best: (angle: CGFloat, distance: CGFloat)?
        for arc in arcs where arc.end - arc.start >= needed {
            // Closest angle to `preferred` (mod 2π) the window's middle may take.
            let lower = arc.start + needed / 2
            let upper = arc.end - needed / 2
            var candidate = preferred
            while candidate < lower - .pi { candidate += 2 * .pi }
            while candidate > upper + .pi { candidate -= 2 * .pi }
            let clamped = min(max(candidate, lower), upper)
            let distance = abs(ManualViewportState.normalizedAngle(clamped - preferred))
            if best == nil || distance < best!.distance { best = (clamped, distance) }
        }
        return best?.angle
    }

    /// Radians from `point` toward `target` (y-down).
    static func direction(from point: CGPoint, toward target: CGPoint) -> CGFloat {
        let dx = target.x - point.x
        let dy = target.y - point.y
        guard dx != 0 || dy != 0 else { return -.pi / 2 }
        return atan2(dy, dx)
    }

    private static func raw(count: Int, center: CGPoint, shape: PaletteShape, diameter: CGFloat,
                            spacing: CGFloat, radius: CGFloat, direction: CGFloat) -> [CGPoint] {
        let pitch = diameter + spacing
        switch shape {
        case .arc:
            var points: [CGPoint] = []
            var ringRadius = radius
            while points.count < count {
                let step = angularStep(pitch: pitch, radius: ringRadius)
                let capacity = max(1, Int(maximumArcSpan / step) + 1)
                let inRing = min(capacity, count - points.count)
                for index in 0..<inRing {
                    let angle = direction + (CGFloat(index) - CGFloat(inRing - 1) / 2) * step
                    points.append(CGPoint(x: center.x + ringRadius * cos(angle),
                                          y: center.y + ringRadius * sin(angle)))
                }
                ringRadius += pitch
            }
            return points
        case .ring:
            // One ring, widened until neighbors are a full pitch apart.
            let needed = count > 1 ? pitch / (2 * sin(.pi / CGFloat(count))) : radius
            let ringRadius = max(radius, needed)
            return (0..<count).map { index in
                let angle = direction + CGFloat(index) * 2 * .pi / CGFloat(count)
                return CGPoint(x: center.x + ringRadius * cos(angle), y: center.y + ringRadius * sin(angle))
            }
        case .wheel:
            return WheelPaletteGeometry.layout(count: count, anchor: CGRect(x: center.x, y: center.y, width: 0, height: 0),
                                               keyDiameter: diameter, spacing: spacing,
                                               bounds: .infinite)?.segments.map(\.labelPoint) ?? []
        case .row, .column:
            let origin = CGPoint(x: center.x + radius * cos(direction), y: center.y + radius * sin(direction))
            return (0..<count).map { index in
                let offset = (CGFloat(index) - CGFloat(count - 1) / 2) * pitch
                return shape == .row
                    ? CGPoint(x: origin.x + offset, y: origin.y)
                    : CGPoint(x: origin.x, y: origin.y + offset)
            }
        }
    }

    /// The angle between neighbors a full `pitch` apart on a circle.
    private static func angularStep(pitch: CGFloat, radius: CGFloat) -> CGFloat {
        2 * asin(min(1, pitch / (2 * radius)))
    }

    private static func collides(_ points: [CGPoint], diameter: CGFloat, spacing: CGFloat,
                                 obstacles: [CGRect]) -> Bool {
        let reach = diameter / 2 + spacing / 2
        return points.contains { point in
            obstacles.contains { $0.insetBy(dx: -reach, dy: -reach).contains(point) }
        }
    }
}

// MARK: - Two-Hand Assist

/// What the opposite side shows. A projection of the one shared
/// `ControlInteractionState` — never a chord state of its own.
enum TwoHandAssistState: Equatable {
    /// Assist off, or the layout has no Two-Hand Assist.
    case hidden
    /// No chord in progress: the idle Function actions show.
    case idle
    /// A modifier is pressed, held or latched: the helper modifiers show,
    /// with `active` highlighted exactly as on the primary side.
    case helper(active: Set<ControlModifier>)
}

enum TwoHandAssist {
    static func state(enabled: Bool, interaction: ControlInteractionState) -> TwoHandAssistState {
        guard enabled else { return .hidden }
        let active = interaction.latchedModifiers.union(interaction.temporaryModifiers)
        switch interaction.phase {
        case .idle, .cancelled, .executing:
            return active.isEmpty ? .idle : .helper(active: active)
        case .pressed(let modifier):
            return .helper(active: active.union([modifier]))
        case .latched, .palette:
            return .helper(active: active)
        }
    }

    /// The helper's anchor: the permanent cluster mirrored across the
    /// screen. A cluster on the left/right mirrors horizontally (bottom-
    /// right → bottom-left); one centered along the top or bottom mirrors
    /// vertically instead.
    static func helperAnchor(clusterCentroid c: CGPoint) -> CGPoint {
        let horizontalBias = abs(c.x - 0.5)
        let verticalBias = abs(c.y - 0.5)
        return horizontalBias >= verticalBias
            ? CGPoint(x: 1 - c.x, y: c.y)
            : CGPoint(x: c.x, y: 1 - c.y)
    }

    /// Centers for `count` helper (or idle) controls: a compact arc around
    /// the mirrored anchor, fanning toward the middle of `area`.
    static func helperPoints(count: Int, clusterCentroid: CGPoint, area: CGRect,
                             itemDiameter: CGFloat, spacing: CGFloat) -> [CGPoint] {
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        let anchorUnit = helperAnchor(clusterCentroid: clusterCentroid)
        let inner = area.insetBy(dx: itemDiameter / 2, dy: itemDiameter / 2)
        let anchor = CGPoint(x: min(max(area.minX + anchorUnit.x * area.width, inner.minX), inner.maxX),
                             y: min(max(area.minY + anchorUnit.y * area.height, inner.minY), inner.maxY))
        let direction = RadialPaletteLayout.direction(from: anchor, toward: CGPoint(x: area.midX, y: area.midY))
        return RadialPaletteLayout.points(count: count, center: anchor, shape: .arc,
                                          itemDiameter: itemDiameter, spacing: spacing,
                                          minimumRadius: itemDiameter * 1.1, direction: direction,
                                          bounds: area)
    }

    /// Two-Hand Assist positions for a Custom arrangement: on a corner
    /// cluster, the modifier arc mirrored to the opposite side (same radius,
    /// same angular spread); otherwise the compact arc of `helperPoints`.
    static func helperPoints(count: Int, arrangement: CustomControlArrangement, frames: [String: CGRect],
                             area: CGRect, itemDiameter: CGFloat, spacing: CGFloat) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard let cluster = CornerCluster.resolve(arrangement: arrangement, frames: frames, area: area) else {
            return helperPoints(count: count, clusterCentroid: arrangement.clusterCentroid, area: area,
                                itemDiameter: itemDiameter, spacing: spacing)
        }
        var mirrored = cluster.mirrored(in: area)
        // More controls than the modifier arc holds widen the arc, never
        // crowd it.
        mirrored.modifierRadius = CornerArcGeometry.radius(
            count: count, pitch: itemDiameter + spacing, minimum: mirrored.modifierRadius,
            diameter: itemDiameter, corner: mirrored.corner, edgeDistances: mirrored.edgeDistances)
        return mirrored.modifierArcPoints(count: count, diameter: itemDiameter)
    }

    /// The modifiers the helper offers, in canonical order.
    static let helperModifiers: [ControlModifier] = ControlModifier.allCases
}

extension ControlInteractionState {
    /// A tap on a Two-Hand Assist helper modifier, applied to this same
    /// chord state:
    /// - during a primary-side hold (pressed or palette), toggles the
    ///   modifier as a temporary member of the held chord, so the palette
    ///   updates at once and everything releases with the hold;
    /// - otherwise (a latched chord, or nothing yet), it's an ordinary
    ///   latch toggle — exactly a tap on that modifier's own button.
    mutating func toggleAssistModifier(_ modifier: ControlModifier) -> [ControlInteractionEffect] {
        switch phase {
        case .pressed(let held):
            var effects = beginPalette(with: held)
            if modifier != held { effects += addTemporaryModifier(modifier) }
            return effects
        case .palette:
            if temporaryModifiers.contains(modifier) {
                return updateTemporaryChord(temporaryModifiers.subtracting([modifier]))
            }
            return addTemporaryModifier(modifier)
        case .idle, .latched, .executing, .cancelled:
            return tap(modifier)
        }
    }
}

// MARK: - Wheel palette

/// A ring of wedge-shaped segments around a center disc — the Wheel palette
/// style. Pure geometry: the renderer draws the wedges and the chord
/// gesture hit-tests them with `segmentIndex(at:)`.
struct WheelPaletteLayout: Equatable {
    struct Segment: Equatable {
        var startAngle: CGFloat
        var endAngle: CGFloat
        /// Where the segment's key label sits.
        var labelPoint: CGPoint
    }

    var center: CGPoint
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var segments: [Segment]

    var frame: CGRect {
        CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2)
    }

    /// The segment under `point`, including a small slack outside the ring.
    func segmentIndex(at point: CGPoint, slack: CGFloat = 14) -> Int? {
        guard !segments.isEmpty else { return nil }
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance >= innerRadius - slack, distance <= outerRadius + slack else { return nil }
        let first = segments[0].startAngle
        var angle = atan2(point.y - center.y, point.x - center.x) - first
        while angle < 0 { angle += 2 * .pi }
        while angle >= 2 * .pi { angle -= 2 * .pi }
        return min(segments.count - 1, Int(angle / (2 * .pi / CGFloat(segments.count))))
    }
}

enum WheelPaletteGeometry {
    /// The wheel for `count` actions around `anchor` (a modifier, or a
    /// rail): a ring just clear of the anchor, wide enough for a key per
    /// segment, with the first segment centered at the top. The center
    /// moves inward when the whole wheel wouldn't fit inside `bounds`.
    static func layout(count: Int, anchor: CGRect, keyDiameter: CGFloat, spacing: CGFloat,
                       bounds: CGRect) -> WheelPaletteLayout? {
        guard count > 0, keyDiameter > 0 else { return nil }
        // Generous wedges: deeper than a key, and at least a key and a bit
        // wide at mid-ring, so a thumb hits them reliably.
        let thickness = keyDiameter * 1.5
        var inner = max(anchor.width, anchor.height) / 2 + spacing
        let minimumMid = CGFloat(count) * keyDiameter * 1.15 / (2 * .pi)
        inner = max(inner, minimumMid - thickness / 2, keyDiameter * 0.6)
        let outer = inner + thickness
        var center = CGPoint(x: anchor.midX, y: anchor.midY)
        if !bounds.isInfinite, bounds.width >= outer * 2, bounds.height >= outer * 2 {
            center.x = min(max(center.x, bounds.minX + outer), bounds.maxX - outer)
            center.y = min(max(center.y, bounds.minY + outer), bounds.maxY - outer)
        }
        let sweep = 2 * CGFloat.pi / CGFloat(count)
        let first = -CGFloat.pi / 2 - sweep / 2
        let middle = (inner + outer) / 2
        let segments = (0..<count).map { index -> WheelPaletteLayout.Segment in
            let start = first + CGFloat(index) * sweep
            let mid = start + sweep / 2
            return .init(startAngle: start, endAngle: start + sweep,
                         labelPoint: CGPoint(x: center.x + middle * cos(mid), y: center.y + middle * sin(mid)))
        }
        return WheelPaletteLayout(center: center, innerRadius: inner, outerRadius: outer, segments: segments)
    }
}

// MARK: - Editor Two-Hand Assist

/// Two-Hand Assist in the editor stays dormant while arranging: moving or
/// selecting a modifier never triggers it. Only Preview runs the real
/// projection; "Preview Two-Hand Assist" in Edit shows its helper arc
/// statically.
enum EditorTwoHandPresentation {
    static func state(previewing: Bool, showingAssistPreview: Bool, enabled: Bool,
                      interaction: ControlInteractionState) -> TwoHandAssistState {
        guard enabled else { return .hidden }
        if previewing { return TwoHandAssist.state(enabled: true, interaction: interaction) }
        return showingAssistPreview ? .helper(active: [.command]) : .hidden
    }
}
