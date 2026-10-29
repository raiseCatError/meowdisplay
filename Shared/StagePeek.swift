// Stage Peek: the floating window switcher. Pure state machine and geometry,
// shared by the iOS view and the Mac test target (Android ports it, checked
// against fixtures/stage-peek/vectors.json). CoreGraphics + Foundation only.

import CoreGraphics
import Foundation

/// Which window switcher Window mode shows. Persisted as `windowSwitcher` in
/// `ReceiverControlPreferences`; stable raw values.
enum WindowSwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case stagePeek
    case rail

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stagePeek: return String(localized: "Stage Peek", comment: "Window switcher: floating window stack from the screen edge.")
        case .rail: return String(localized: "Rail", comment: "Window switcher: compact window strip.")
        }
    }
    var explanation: String {
        switch self {
        case .stagePeek: return String(localized: "Touch and hold the screen edge to see your windows. Tap one to switch.")
        case .rail: return String(localized: "A compact strip of windows along one edge.")
        }
    }
}

/// The screen edge Stage Peek opens from. Persisted as `stagePeekEdge`.
enum StagePeekEdge: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return String(localized: "Left", comment: "Screen edge.")
        case .right: return String(localized: "Right", comment: "Screen edge.")
        }
    }
}

/// Thresholds, in points and seconds. Tests and both apps share them.
enum StagePeekConfig {
    /// The hold strip: this wide, just inside the safe area.
    static let edgeStripWidth: CGFloat = 20
    /// The strip covers this share of the height, centred, capped (Android
    /// excludes at most 200 dp per edge from system back gestures).
    static let edgeStripHeightFraction: CGFloat = 0.7
    static let edgeStripMaxHeight: CGFloat = 200
    /// A still finger on the strip opens Stage Peek after this long.
    static let holdDelay: TimeInterval = 0.3
    /// Moving farther than this before the hold completes cancels it.
    static let holdSlop: CGFloat = 10
    /// Vertical finger travel per window while scrubbing.
    static let scrubPitch: CGFloat = 52
    /// Sideways travel that counts as a flick between compact and expanded.
    static let flickDistance: CGFloat = 44
    /// Inward travel before the expanded browser starts to grow, and the
    /// travel at which it is fully expanded.
    static let expandStart: CGFloat = 56
    static let expandFull: CGFloat = 156
    /// Expansion kept on lift at or past this share; less springs back.
    static let expandKeep: Double = 0.6
    /// Scrub ticks closer together than this are skipped (the highlight
    /// still changes), so fast scrubs don't buzz.
    static let tickSpacing: TimeInterval = 0.035
    /// A tap while open: shorter than this and within `tapSlop`.
    static let tapMaxDuration: TimeInterval = 0.35
    static let tapSlop: CGFloat = 10
    /// Scrubbing past either end rubber-bands at most this many windows.
    static let maxOverrun: Double = 0.45
    /// Overrun that plays the end-of-list haptic, once per excursion.
    static let boundaryOverrun: Double = 0.25
    /// Camera distance (points) for the card tilt: renderers and hit testing.
    static let perspective: CGFloat = 900
}

enum StagePeekHaptic: String, Equatable { case activate, tick, boundary, select }

enum StagePeekEffect: Equatable {
    case opened
    case haptic(StagePeekHaptic)
    /// A tap chose this window. Stage Peek is closed.
    case select(UInt32)
    /// Closed without choosing anything.
    case dismissed
}

/// The gesture and selection state. Browsing (hold, scrub, expand, lift)
/// never selects; only a separate tap on a card does.
struct StagePeekMachine: Equatable {
    enum Phase: String, Equatable { case closed, arming, scrubbing, open }

    /// The first card in Window mode: back to the whole Mac screen. Never a
    /// window ID (CGWindowIDs start at 1).
    static let fullDesktopID: UInt32 = 0

    /// Swipe up moves the stack up, revealing the windows below (the default).
    var naturalScrolling = true

    private(set) var phase = Phase.closed
    private(set) var ids: [UInt32] = []
    /// Fractional index the stack is centred on; follows the finger.
    private(set) var position: Double = 0
    /// 0 compact … 1 expanded browser.
    private(set) var expansion: Double = 0
    private(set) var expanded = false
    private var currentIndex = 0

    private var touchID: AnyHashable?
    private var start: (point: CGPoint, time: TimeInterval)?
    private var anchor: (point: CGPoint, position: Double)?
    /// Open phase: the touch that may still be a tap.
    private var tapCandidate = false
    /// A touch Stage Peek owns but ignores until it lifts.
    private var consumed: Set<AnyHashable> = []
    private var lastTickTime: TimeInterval = -.infinity
    private var lastHighlighted = 0
    private var overrunSignalled = false

    static func == (a: Self, b: Self) -> Bool {
        a.phase == b.phase && a.ids == b.ids && a.position == b.position && a.expansion == b.expansion
            && a.expanded == b.expanded && a.touchID == b.touchID
    }

    var isVisible: Bool { phase == .scrubbing || phase == .open }
    var highlighted: Int { ids.isEmpty ? 0 : min(max(Int(position.rounded()), 0), ids.count - 1) }
    var highlightedID: UInt32? { ids.isEmpty ? nil : ids[highlighted] }

    // MARK: Catalog

    /// New window list. While visible the highlighted window keeps its
    /// highlight if it is still listed, so a reorder never jumps to another
    /// window; `current` (the active tile's window) is where the next open
    /// starts.
    mutating func setItems(_ new: [UInt32], current: UInt32?) {
        let keep = isVisible ? highlightedID : nil
        let fraction = position - position.rounded()
        ids = new
        currentIndex = current.flatMap { new.firstIndex(of: $0) } ?? 0
        if let keep, let i = new.firstIndex(of: keep) {
            position = Double(i) + fraction
        } else {
            position = clampPosition(isVisible ? position : Double(currentIndex))
        }
        lastHighlighted = highlighted
        if isVisible && ids.isEmpty { closeAll() }
    }

    // MARK: Touches

    /// Returns whether Stage Peek owns this touch. Owned touches never reach
    /// the Mac: anything starting on the edge strip, and everything while open.
    mutating func touchBegan(id: AnyHashable, at point: CGPoint, time: TimeInterval, onStrip: Bool) -> Bool {
        switch phase {
        case .closed:
            guard onStrip, !ids.isEmpty else { return false }
            phase = .arming
            touchID = id
            start = (point, time)
            return true
        case .arming, .scrubbing:
            if id != touchID { consumed.insert(id) }
            return true
        case .open:
            guard touchID == nil else { consumed.insert(id); return true }
            touchID = id
            start = (point, time)
            anchor = (point, position)
            tapCandidate = true
            return true
        }
    }

    mutating func touchMoved(id: AnyHashable, to point: CGPoint, time: TimeInterval, edge: StagePeekEdge) -> [StagePeekEffect] {
        guard id == touchID, let start else { return [] }
        switch phase {
        case .arming:
            let dx = point.x - start.point.x, dy = point.y - start.point.y
            if hypot(dx, dy) > StagePeekConfig.holdSlop {
                // The touch stays Stage Peek's until it lifts either way.
                consumed.insert(id)
                resetTouch()
                phase = .closed
                // A flick inward from the edge opens the peek (it stays open; nothing is chosen).
                let inward = edge == .left ? dx : -dx
                if inward > abs(dy) { return openDirectly() }
            }
            return []
        case .open:
            guard tapCandidate else { return [] }
            // A sideways flick while open: inward expands, outward compacts (or closes when compact).
            let dx = point.x - start.point.x, dy = point.y - start.point.y
            if abs(dx) > StagePeekConfig.flickDistance, abs(dx) > abs(dy) * 1.5 {
                consumed.insert(id)
                resetTouch()
                let inward = edge == .left ? dx : -dx
                if inward > 0 { expand(); return [.haptic(.select)] }
                if expanded { compact(); return [.haptic(.select)] }
                closeAll()
                return [.dismissed]
            }
            guard hypot(point.x - start.point.x, point.y - start.point.y) > StagePeekConfig.tapSlop else { return [] }
            tapCandidate = false
            phase = .scrubbing
            return scrub(to: point, time: time, edge: edge)
        case .scrubbing:
            return scrub(to: point, time: time, edge: edge)
        case .closed:
            return []
        }
    }

    /// `cardAt` answers which card is frontmost under a point (a tap target).
    mutating func touchEnded(id: AnyHashable, at point: CGPoint, time: TimeInterval,
                             cardAt: (CGPoint) -> Int?) -> [StagePeekEffect] {
        if consumed.remove(id) != nil { return [] }
        guard id == touchID else { return [] }
        switch phase {
        case .arming:
            // A quick tap on the edge bar opens the peek (accessible entry); a longer
            // press that lifts before the hold completes opens nothing.
            let wasTap = start.map { time - $0.time <= StagePeekConfig.tapMaxDuration } ?? false
            resetTouch()
            phase = .closed
            return wasTap ? openDirectly() : []
        case .scrubbing:
            settleAfterLift()
            resetTouch()   // the next touch is a fresh tap candidate
            return []
        case .open:
            let wasTap = tapCandidate && (start.map { time - $0.time <= StagePeekConfig.tapMaxDuration } ?? false)
            resetTouch()
            guard wasTap else { return [] }
            if let i = cardAt(point), ids.indices.contains(i) {
                let chosen = ids[i]
                closeAll()
                return [.haptic(.select), .select(chosen)]
            }
            closeAll()
            return [.dismissed]
        case .closed:
            resetTouch()
            return []
        }
    }

    /// The system took the touch (rotation, fold, app switch): never selects.
    mutating func touchCancelled(id: AnyHashable) {
        if consumed.remove(id) != nil { return }
        guard id == touchID else { return }
        switch phase {
        case .arming: phase = .closed
        case .scrubbing: settleAfterLift()
        case .open, .closed: break
        }
        resetTouch()
    }

    // MARK: Time

    mutating func poll(now: TimeInterval) -> [StagePeekEffect] {
        guard phase == .arming, let start, now - start.time >= StagePeekConfig.holdDelay else { return [] }
        phase = .scrubbing
        expansion = 0
        expanded = false
        position = Double(currentIndex)
        anchor = (start.point, position)
        lastHighlighted = highlighted
        overrunSignalled = false
        return [.opened, .haptic(.activate)]
    }

    func pollDelay(now: TimeInterval) -> TimeInterval? {
        guard phase == .arming, let start else { return nil }
        return max(0, start.time + StagePeekConfig.holdDelay - now)
    }

    // MARK: Buttons and outside events

    /// Opens without a hold (VoiceOver's activate action, a keyboard
    /// shortcut): same stack, nothing selected.
    mutating func openDirectly() -> [StagePeekEffect] {
        guard phase == .closed, !ids.isEmpty else { return [] }
        resetTouch()
        phase = .open
        expansion = 0
        expanded = false
        position = Double(currentIndex)
        lastHighlighted = highlighted
        return [.opened, .haptic(.activate)]
    }

    /// VoiceOver adjustable action / arrow keys: move the highlight by one.
    mutating func step(_ delta: Int) -> [StagePeekEffect] {
        guard isVisible, !ids.isEmpty else { return [] }
        let next = min(max(highlighted + delta, 0), ids.count - 1)
        guard next != highlighted else { return [.haptic(.boundary)] }
        position = Double(next)
        lastHighlighted = next
        return [.haptic(.tick)]
    }

    /// Chooses the highlighted window (VoiceOver activate, Return key).
    mutating func selectHighlighted() -> [StagePeekEffect] {
        guard isVisible, let chosen = highlightedID else { return [] }
        closeAll()
        return [.haptic(.select), .select(chosen)]
    }

    /// Chooses the window at `index` (VoiceOver activate on a card).
    mutating func select(index: Int) -> [StagePeekEffect] {
        guard isVisible, ids.indices.contains(index) else { return [] }
        let chosen = ids[index]
        closeAll()
        return [.haptic(.select), .select(chosen)]
    }

    mutating func expand() { guard isVisible else { return }; expanded = true; expansion = 1 }
    mutating func compact() { guard isVisible else { return }; expanded = false; expansion = 0 }

    /// Dismiss without choosing (Escape, back, tap outside handled above).
    mutating func dismiss() -> [StagePeekEffect] {
        guard phase != .closed else { return [] }
        let wasVisible = isVisible
        closeAll()
        return wasVisible ? [.dismissed] : []
    }

    /// Fold, resize, disconnect, revocation, leaving Window mode: closes
    /// silently and never selects.
    mutating func cancelAll() { closeAll() }

    // MARK: Internals

    private mutating func scrub(to point: CGPoint, time: TimeInterval, edge: StagePeekEdge) -> [StagePeekEffect] {
        guard let anchor, !ids.isEmpty else { return [] }
        var out: [StagePeekEffect] = []
        let travel = Double(point.y - anchor.point.y) / Double(StagePeekConfig.scrubPitch)
        let raw = anchor.position + (naturalScrolling ? -travel : travel)
        let maxIndex = Double(ids.count - 1)
        let overrun = raw < 0 ? -raw : (raw > maxIndex ? raw - maxIndex : 0)
        position = clampPosition(raw)
        if overrun >= StagePeekConfig.boundaryOverrun {
            if !overrunSignalled { overrunSignalled = true; out.append(.haptic(.boundary)) }
        } else if overrun == 0 {
            overrunSignalled = false
        }
        if highlighted != lastHighlighted {
            lastHighlighted = highlighted
            if time - lastTickTime >= StagePeekConfig.tickSpacing {
                lastTickTime = time
                out.append(.haptic(.tick))
            }
        }
        if !expanded {
            let inward = edge == .left ? point.x - anchor.point.x : anchor.point.x - point.x
            let span = StagePeekConfig.expandFull - StagePeekConfig.expandStart
            expansion = min(max(Double((inward - StagePeekConfig.expandStart) / span), 0), 1)
        }
        return out
    }

    /// Rubber band past the ends, at most `maxOverrun`.
    private func clampPosition(_ raw: Double) -> Double {
        guard !ids.isEmpty else { return 0 }
        let maxIndex = Double(ids.count - 1)
        let m = StagePeekConfig.maxOverrun
        func band(_ x: Double) -> Double { m * (1 - exp(-x / m)) }
        if raw < 0 { return -band(-raw) }
        if raw > maxIndex { return maxIndex + band(raw - maxIndex) }
        return raw
    }

    private mutating func settleAfterLift() {
        phase = .open
        position = Double(highlighted)
        if !expanded {
            expanded = expansion >= StagePeekConfig.expandKeep
            expansion = expanded ? 1 : 0
        }
        overrunSignalled = false
    }

    private mutating func resetTouch() {
        touchID = nil
        start = nil
        anchor = nil
        tapCandidate = false
    }

    private mutating func closeAll() {
        phase = .closed
        expansion = 0
        expanded = false
        resetTouch()
        position = Double(currentIndex)
        lastHighlighted = highlighted
        overrunSignalled = false
    }
}

// MARK: - Geometry

/// One card on screen. `tilt` is degrees around the card's horizontal axis:
/// positive tips its top edge away from the viewer (cards above the
/// highlighted one), negative its bottom edge (cards below). `scale` is
/// already applied to `size`.
struct StagePeekCard: Equatable {
    var index: Int
    var center: CGPoint
    var size: CGSize
    var tilt: Double
    var z: Double
    var opacity: Double
    var highlighted: Bool
}

enum StagePeekLayout {
    /// The hold strip for an edge inside `safe` (the safe-area rect),
    /// clear of `avoiding` (on-screen controls, hinges): the free run of the
    /// edge closest to its middle, nil when none is tall enough to hold.
    static func strip(edge: StagePeekEdge, safe: CGRect, avoiding: [CGRect] = []) -> CGRect? {
        let width = StagePeekConfig.edgeStripWidth
        let x = edge == .left ? safe.minX : safe.maxX - width
        let column = CGRect(x: x, y: safe.minY, width: width, height: safe.height)
        let maxHeight = min(safe.height * StagePeekConfig.edgeStripHeightFraction, StagePeekConfig.edgeStripMaxHeight)
        // Free vertical runs of the column.
        var runs = [(safe.minY, safe.maxY)]
        for r in avoiding where r.intersects(column) {
            runs = runs.flatMap { run -> [(CGFloat, CGFloat)] in
                guard r.minY < run.1, r.maxY > run.0 else { return [run] }
                return [(run.0, r.minY), (r.maxY, run.1)].filter { $0.1 - $0.0 > 0 }
            }
        }
        let minimum: CGFloat = 60
        let mid = safe.midY
        let best = runs.filter { $0.1 - $0.0 >= minimum }
            .min { abs(($0.0 + $0.1) / 2 - mid) < abs(($1.0 + $1.1) / 2 - mid) }
        guard let best else { return nil }
        let height = min(maxHeight, best.1 - best.0)
        let center = min(max(mid, best.0 + height / 2), best.1 - height / 2)
        return CGRect(x: x, y: center - height / 2, width: width, height: height)
    }

    /// Visible cards, back to front. `aspects` are width / height per window.
    static func cards(aspects: [Double], position: Double, expansion: Double, edge: StagePeekEdge,
                      safe: CGRect, isPad: Bool, reduceMotion: Bool) -> [StagePeekCard] {
        guard !aspects.isEmpty, safe.width > 0, safe.height > 0 else { return [] }
        let e = CGFloat(min(max(expansion, 0), 1))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        let compactWidth = min(max(safe.width * (isPad ? 0.24 : 0.36), 110), isPad ? 300 : 210)
        let expandedWidth = min(max(safe.width * 0.6, compactWidth), isPad ? 640 : 420)
        let maxWidth = lerp(compactWidth, expandedWidth)
        let maxHeight = safe.height * lerp(0.26, 0.42)
        let focus = min(max(Int(position.rounded()), 0), aspects.count - 1)
        func cardSize(_ i: Int) -> CGSize {
            let aspect = CGFloat(min(max(aspects[i], 0.5), 2.2))
            var w = maxWidth, h = w / aspect
            if h > maxHeight { h = maxHeight; w = h * aspect }
            return CGSize(width: w, height: h)
        }
        let focusSize = cardSize(focus)
        let margin: CGFloat = 16
        let compactX = edge == .left ? safe.minX + margin + compactWidth / 2 : safe.maxX - margin - compactWidth / 2
        let centerX = lerp(compactX, safe.midX)
        // Room for the title under the highlighted card.
        let centerY = safe.midY - 18
        // Compact (e = 0) is Dock magnification: the highlighted card full size and popped out,
        // the rest shrinking smoothly with distance, upright, edge-aligned and not overlapping.
        // Expanded (e = 1) is the layered Cover Flow stack. Positions blend between the two.
        let gap: CGFloat = 8
        func dockScale(_ u: Double) -> CGFloat { CGFloat(0.56 + 0.44 * exp(-u * u / 0.7)) }
        func dockHeight(_ i: Int) -> CGFloat { cardSize(i).height * dockScale(abs(Double(i) - position)) }
        // Dock centres: stack outward from the (continuous) position so scrubbing glides.
        var dockY = [CGFloat](repeating: 0, count: aspects.count)
        let base = min(max(Int(position.rounded(.down)), 0), aspects.count - 1)
        let frac = CGFloat(position - Double(base))
        dockY[base] = 0
        if base + 1 < aspects.count { dockY[base + 1] = dockHeight(base) / 2 + gap + dockHeight(base + 1) / 2 }
        if base + 2 <= aspects.count - 1 {
            for i in (base + 2)..<aspects.count { dockY[i] = dockY[i - 1] + dockHeight(i - 1) / 2 + gap + dockHeight(i) / 2 }
        }
        if base > 0 { for i in stride(from: base - 1, through: 0, by: -1) { dockY[i] = dockY[i + 1] - dockHeight(i + 1) / 2 - gap - dockHeight(i) / 2 } }
        let shift = base + 1 < aspects.count ? frac * (dockY[base + 1] - dockY[base]) : 0
        var out: [StagePeekCard] = []
        for i in aspects.indices {
            let k = Double(i) - position
            let u = abs(k)
            guard u <= (e > 0.5 ? 4.5 : 6.5) else { continue }
            let near = min(u, 1), far = max(0, min(u, 3) - 1)
            let size = cardSize(i)
            // Cover Flow (expanded).
            let flowScale = CGFloat(1 - 0.16 * near - 0.07 * far)
            let step = CGFloat(u <= 1 ? u * 0.58 : 0.58 + (u - 1) * 0.30)
            let flowY = centerY + (k < 0 ? -1 : 1) * step * focusSize.height
            let flowTilt = reduceMotion ? 0 : min(16 * near + 3 * far, 22)
            // Dock (compact).
            let ds = dockScale(u)
            let dw = size.width * ds
            let pop = CGFloat(10 * pow(max(0, 1 - u), 2))   // only the highlighted card pops out
            let dockX = edge == .left ? safe.minX + margin + dw / 2 + pop : safe.maxX - margin - dw / 2 - pop
            let dy = centerY + dockY[i] - shift
            let scale = lerp(ds, flowScale)
            out.append(StagePeekCard(
                index: i,
                center: CGPoint(x: lerp(dockX, safe.midX), y: lerp(dy, flowY)),
                size: CGSize(width: size.width * scale, height: size.height * scale),
                tilt: Double(e) * (k < 0 ? flowTilt : -flowTilt),
                z: -u,
                opacity: u > 3.5 && e > 0.5 ? max(0, 1 - (u - 3.5)) : 1,
                highlighted: i == focus && u < 0.5))
        }
        return out.sorted { $0.z < $1.z }
    }

    /// The four on-screen corners of a tilted card (top-left, top-right,
    /// bottom-right, bottom-left), with the renderers' perspective.
    static func corners(_ c: StagePeekCard) -> [CGPoint] {
        let theta = c.tilt * .pi / 180
        let d = Double(StagePeekConfig.perspective)
        let hw = Double(c.size.width) / 2, hh = Double(c.size.height) / 2
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { x, y in
            // Rotate about the horizontal axis; positive tilt sends the top (y < 0) away.
            let yr = y * cos(theta)
            let z = -y * sin(theta)
            let f = d / (d + z)
            return CGPoint(x: Double(c.center.x) + x * f, y: Double(c.center.y) + yr * f)
        }
    }

    /// The frontmost card containing `p` (cards fully faded out are ignored).
    static func hit(_ p: CGPoint, cards: [StagePeekCard]) -> Int? {
        for c in cards.sorted(by: { $0.z > $1.z }) where c.opacity > 0.05 {
            if contains(corners(c), p) { return c.index }
        }
        return nil
    }

    private static func contains(_ quad: [CGPoint], _ p: CGPoint) -> Bool {
        var sign: Double = 0
        for i in 0..<quad.count {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let cross = Double((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x))
            if cross == 0 { continue }
            if sign == 0 { sign = cross } else if (sign > 0) != (cross > 0) { return false }
        }
        return true
    }
}
