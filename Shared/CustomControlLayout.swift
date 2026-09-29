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

    private enum CodingKeys: String, CodingKey { case kind, value }

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
        }
    }

    var modifier: ControlModifier? {
        if case .tray(let item) = self { return item.modifier }
        return nil
    }
}

enum PaletteShape: String, Codable, CaseIterable, Identifiable {
    case arc
    case ring
    case row
    case column

    var id: String { rawValue }

    var title: String {
        switch self {
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

    /// The radial corner constellation: Settings in the corner, the four
    /// modifiers on an inner quarter arc, and Escape/Tab/Keyboard/Move View
    /// on an outer one.
    static func radialTemplate(corner: ControlCorner, portrait: Bool) -> CustomControlArrangement {
        let reference = portrait ? referencePortrait : referenceLandscape
        let anchor = CGPoint(x: corner.isLeading ? 30 : reference.width - 30,
                             y: corner.isTop ? 30 : reference.height - 30)
        // Quarter arc from "along the horizontal edge" to "along the
        // vertical edge", pointing into the screen.
        let horizontal: CGFloat = corner.isLeading ? 0 : .pi
        let vertical: CGFloat = corner.isTop ? .pi / 2 : -.pi / 2
        func arcPoints(count: Int, radius: CGFloat) -> [CGPoint] {
            (0..<count).map { index in
                let t = CGFloat(index) / CGFloat(max(count - 1, 1))
                // Interpolate the shorter way between the two edge angles.
                var delta = vertical - horizontal
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                let inset: CGFloat = 0.05
                let angle = horizontal + delta * (inset + t * (1 - 2 * inset))
                return CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
            }
        }
        func normalized(_ point: CGPoint) -> (Double, Double) {
            (Double(point.x / reference.width), Double(point.y / reference.height))
        }
        var placements: [CustomControlPlacement] = []
        let settings = normalized(anchor)
        placements.append(CustomControlPlacement(id: "settings", kind: .tray(.settings),
                                                 x: settings.0, y: settings.1, size: 0.9))
        let modifiers: [ControlTrayItem] = [.command, .option, .control, .shift]
        for (item, point) in zip(modifiers, arcPoints(count: modifiers.count, radius: 100)) {
            let p = normalized(point)
            placements.append(CustomControlPlacement(id: item.rawValue, kind: .tray(item), x: p.0, y: p.1))
        }
        let outer: [CustomControlKind] = [.tray(.escape), .tray(.tab), .tray(.keyboard), .moveView]
        for (kind, point) in zip(outer, arcPoints(count: outer.count, radius: 172)) {
            let p = normalized(point)
            let id: String
            switch kind {
            case .tray(let item): id = item.rawValue
            case .function(let value): id = value
            case .moveView: id = "move-view"
            }
            placements.append(CustomControlPlacement(id: id, kind: kind, x: p.0, y: p.1, size: 0.9))
        }
        return CustomControlArrangement(corner: corner, placements: placements)
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
