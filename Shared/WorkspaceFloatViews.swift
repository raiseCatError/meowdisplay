import SwiftUI
#if os(iOS)
import QuartzCore
import UIKit

// Floating panes' chrome on iPhone and iPad (PROTOCOL.md 6.10, WINDOW_MODE.md): the outline,
// the title pill on the top edge, the bottom grabber, the curved corner grips, the strips of
// tucked floats at the edges and the first-use circling tip. The Mac draws the floats' windows into
// the picture; everything here is the receiver's own: moving, flinging, tucking, peeking,
// restoring and resizing never send pointer input or a window action, only the arrangement
// (`workspaceRequest`).

/// Selected float: a deeper blue than the pane-drop highlight (a translucent fill), stroke only.
private let floatAccent = Color(red: 0.26, green: 0.56, blue: 1.0)
private let floatChip = Color(white: 0.1, opacity: 0.88)
private let floatCorner: CGFloat = 10

private extension WorkspaceRect {
    func screen(in picture: CGRect) -> CGRect {
        CGRect(x: picture.minX + x * picture.width, y: picture.minY + y * picture.height,
               width: width * picture.width, height: height * picture.height)
    }
}

/// A native menu built when it opens and never rebuilt while it is open. A SwiftUI `Menu` in the
/// workspace chrome is re-evaluated every time the workspace model publishes (many times a second
/// while a stream runs); an open menu rebuilt mid-scroll jumps back to its top and cross-fades two
/// copies of itself, so its lower items can't be reached. `symbol` nil: an invisible button laid
/// over a SwiftUI face, which then is only the picture.
struct WorkspaceStableMenuButton: UIViewRepresentable {
    var symbol: String?
    var accessibilityLabel: String
    var accessibilityIdentifier: String
    var items: @MainActor () -> [UIMenuElement]

    @MainActor final class Coordinator {
        var items: @MainActor () -> [UIMenuElement] = { [] }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        if let symbol {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
            button.tintColor = .white
        }
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.isPointerInteractionEnabled = true
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in completion(coordinator.items()) }])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Only what the next opening reads: the open menu itself is never touched.
        context.coordinator.items = items
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
    }
}

/// Glides a released float to where it settles, and moves a tucked float along its way out of
/// its edge or back in (`WorkspaceFloatGeometry.EdgePath`): into its edge when it's tucked, under
/// a finger pulling it out, back in after a pull that fell short, and out to where it comes back
/// to. Each with a critically damped spring that starts at the finger's velocity. A new touch
/// catches a float that is settling.
@MainActor
final class WorkspaceFloatMotionDriver: NSObject, ObservableObject {
    private struct Glide {
        var from: WorkspaceRect
        var to: WorkspaceRect
        /// Picture shares per second.
        var vx: Double
        var vy: Double
        var start: CFTimeInterval
    }

    /// What a tucked float's way along its edge path is for.
    enum EdgeKind: Equatable {
        /// Just tucked: from where it was let go into its edge (it's tucked already).
        case tucking
        /// A pull let go short of the restore point: back into its edge.
        case returning
        /// Coming back out: shown again (lifted where the Mac can), drawn here until it's out.
        case restoring
    }

    /// A tucked float drawn along its edge path: `p` of the way (0 `from`, 1 `to`). `kind` nil:
    /// a finger holds it.
    struct EdgeState: Equatable {
        var path: WorkspaceFloatGeometry.EdgePath
        var p: Double
        var kind: EdgeKind?
    }

    private struct EdgeGlide {
        var from: Double
        var to: Double
        /// Path per second.
        var v: Double
        var start: CFTimeInterval
        var done: (@MainActor () -> Void)?
    }

    /// Where a float is drawn while a finger or a glide moves it (picture shares, unclamped).
    @Published private(set) var frames: [String: WorkspaceRect] = [:]
    /// Tucked floats on their way along their edge path (points), by float.
    @Published private(set) var edges: [String: EdgeState] = [:]
    weak var model: WorkspaceModel?
    private var glides: [String: Glide] = [:]
    private var edgeGlides: [String: EdgeGlide] = [:]
    private var link: CADisplayLink?
    static let duration: CFTimeInterval = 0.7

    func drag(_ id: String, _ frame: WorkspaceRect) { frames[id] = frame }
    func drop(_ id: String) { frames[id] = nil; glides[id] = nil; stopIfIdle() }
    func isGliding(_ id: String) -> Bool { glides[id] != nil }

    /// Stops a settling glide under a new touch and returns where it was (nil: nothing to catch).
    func catchFloat(_ id: String) -> WorkspaceRect? {
        guard let g = glides[id] else { return nil }
        glides[id] = nil
        let f = current(g, at: CACurrentMediaTime())
        frames[id] = f
        stopIfIdle()
        return f
    }

    func glide(_ id: String, from: WorkspaceRect, to: WorkspaceRect, velocity: (x: Double, y: Double)) {
        glides[id] = Glide(from: from, to: to, vx: velocity.x, vy: velocity.y, start: CACurrentMediaTime())
        frames[id] = from
        startLink()
    }

    /// A finger holds a tucked float `p` of the way along `path`.
    func holdEdge(_ id: String, path: WorkspaceFloatGeometry.EdgePath, p: Double) {
        edgeGlides[id] = nil
        edges[id] = EdgeState(path: path, p: p, kind: nil)
        stopIfIdle()
    }

    /// Moves a tucked float along `path` from `from` to `to` (0 or 1), starting at `velocity`
    /// (path per second); `done` runs when it gets there.
    func glideEdge(_ id: String, path: WorkspaceFloatGeometry.EdgePath, from: Double, to: Double, velocity: Double,
                   kind: EdgeKind, done: (@MainActor () -> Void)? = nil) {
        edges[id] = EdgeState(path: path, p: from, kind: kind)
        edgeGlides[id] = EdgeGlide(from: from, to: to, v: velocity.isFinite ? velocity : 0, start: CACurrentMediaTime(), done: done)
        startLink()
    }

    /// Back to its strip at rest (or gone, once it's out).
    func dropEdge(_ id: String) { edges[id] = nil; edgeGlides[id] = nil; stopIfIdle() }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func current(_ g: Glide, at now: CFTimeInterval) -> WorkspaceRect {
        let t = now - g.start
        var f = g.to
        f.x = WorkspaceFloatMotion.spring(from: g.from.x, to: g.to.x, velocity: g.vx, t: t).value
        f.y = WorkspaceFloatMotion.spring(from: g.from.y, to: g.to.y, velocity: g.vy, t: t).value
        return f
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        for (id, g) in glides {
            if now - g.start >= Self.duration {
                glides[id] = nil
                frames[id] = nil
                model?.endFloatGesture(id, frame: g.to)
            } else {
                let f = current(g, at: now)
                frames[id] = f
                model?.updateFloatFrame(id, f)   // the Mac follows (throttled)
            }
        }
        for (id, g) in edgeGlides {
            if now - g.start >= Self.duration {
                edgeGlides[id] = nil
                edges[id] = nil
                g.done?()
            } else {
                edges[id]?.p = WorkspaceFloatMotion.spring(from: g.from, to: g.to, velocity: g.v, t: now - g.start).value
            }
        }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard glides.isEmpty, edgeGlides.isEmpty else { return }
        link?.invalidate()
        link = nil
    }
}

/// The floats over the tiled panes, back to front, and the strips of tucked ones at the edges.
struct WorkspaceFloatLayer: View {
    @ObservedObject var model: WorkspaceModel
    /// Where the picture is drawn, in the workspace coordinate space.
    let picture: CGRect
    var safeArea: CGRect?
    let inputAllowed: Bool
    /// Close Window on Mac… (asks first, in the chrome).
    var onClose: (String) -> Void
    @StateObject private var motion = WorkspaceFloatMotionDriver()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var start: [String: WorkspaceRect] = [:]
    /// Where the finger holds each moving float (picture shares, past any edge).
    @State private var held: [String: WorkspaceRect] = [:]
    @State private var moving: Set<String> = []
    @State private var samples: [String: [Sample]] = [:]
    @State private var lastTap: (id: String, at: Date)?
    /// Circling toward the other placement: where the finger is and how far along.
    @State private var ring: Ring?
    /// The float folded into a card while it's being docked (`model.dockingFloat`, circled while
    /// moving it: the pane drop targets show).
    @State private var card: DockCard?
    @State private var finger: CGPoint = .zero
    @State private var ringFade: Task<Void, Never>?
    @State private var resizeStart: [String: WorkspaceRect] = [:]
    /// Fingers on tucked floats' strips, by float.
    @State private var handleTouches: [String: HandleTouch] = [:]
    @GestureState private var handlesHeld: Set<String> = []
    /// The strip under the pointer (it brightens).
    @State private var hoveredStrip: String?
    @State private var tipHide: Task<Void, Never>?
    @GestureState private var pressing: Set<String> = []

    private struct Sample { var point: CGPoint; var time: TimeInterval }
    private struct Ring { var at: CGPoint; var progress: Double; var toFloating: Bool }
    private struct DockCard { var id: String; var from: CGRect; var collapsed: Bool }

    /// A finger on a strip: peeking until it moves, then pulling the float out (inward), sliding
    /// the strip along its edge, or pushing it back (outward: nothing happens).
    private struct HandleTouch {
        enum Mode { case peek, pull, slide, away }
        var mode = Mode.peek
        var translation = CGSize.zero
        var samples: [Sample] = []
        /// How far out (along its edge path) the float was when the finger came down.
        var start = 0.0
    }

    private var highContrast: Bool { contrast == .increased }
    private var pictureSize: WorkspaceSize { WorkspaceSize(width: max(picture.width, 1), height: max(picture.height, 1)) }
    /// Local workspace coordinates to global (drags share global coordinates with Stage Peek).
    private var toGlobal: CGPoint {
        CGPoint(x: model.pictureGlobal.minX - picture.minX, y: model.pictureGlobal.minY - picture.minY)
    }

    var body: some View {
        let frames = model.frames
        let handles = model.localFullscreen == nil ? tuckHandles() : []
        // Where each float is drawn now, and what the floats in front of it cover: its chrome
        // steps aside there (the front float's window is in the video, under all the chrome).
        // A float being docked is drawn only as its card under the finger. Its chrome stays,
        // drawing nothing (its move lives on its title or grabber), so it covers nothing.
        let docking = model.dockingFloat
        let shown = frames.floats.compactMap { id in (motion.frames[id] ?? frames.tiles[id]).map { (id: id, rect: $0.screen(in: picture)) } }
        let covers = WorkspaceFloatLayering.covers(backToFront: shown.map { WorkspaceRect($0.id == docking ? .zero : $0.rect) })
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
                // Coming back out of its edge: drawn as its edge picture until it's out.
                if motion.edges[f.id]?.kind != .restoring {
                    floatChrome(f.id, rect: f.rect, front: i == shown.count - 1, covers: coverRects(covers, shown.map(\.id), i))
                }
            }
            .accessibilityElement(children: .contain)
            if let c = card, model.dockingFloat == c.id { dockCard(c) }
            if let r = ring, r.progress > 0 {
                WorkspacePlacementRing(progress: r.progress, toFloating: r.toFloating)
                    .position(x: r.at.x, y: r.at.y - WorkspacePlacementRing.lift)
            }
            if model.placementTipVisible { placementTip }
        }
        .onAppear { motion.model = model; publishHandles(handles) }
        .onChange(of: handles.map(\.tab.rect)) { _ in publishHandles(handles) }
        .onChange(of: handlesHeld) { _ in
            // A touch on a strip the system cancelled (no end event): a peek or a pull goes back
            // in. Looked at a moment later, once a touch that ended has been handled.
            Task { @MainActor in
                for id in handleTouches.keys where !handlesHeld.contains(id) {
                    guard let t = handleTouches.removeValue(forKey: id) else { continue }
                    if t.mode == .pull { pullFellShort(id) }
                    else if t.mode == .peek, motion.edges[id]?.kind == nil {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.86)) { motion.dropEdge(id) }
                    }
                }
            }
        }
        .onChange(of: model.drag == nil) { ended in if ended, model.placementTipVisible { hideTipSoon() } }
        .onChange(of: pressing) { held in
            // A move the system cancelled (no end event): settle where it is.
            for id in start.keys where !held.contains(id) {
                let f = motion.frames[id]
                start[id] = nil; moving.remove(id); samples[id] = nil
                ring = nil
                // Docking: put back as it was (frame, view, place among the floats), drawn by the Mac.
                if model.dockingFloat == id { card = nil; motion.drop(id); model.cancelDockingFloat(id); continue }
                if !motion.isGliding(id) { motion.drop(id); model.endFloatGesture(id, frame: f) }
            }
        }
    }

    /// What the floats in front of float `i` (of `ids`, back to front) cover, but for one coming
    /// back out of its edge: it isn't there until it's out.
    private func coverRects(_ covers: [[WorkspaceRect]], _ ids: [String], _ i: Int) -> [CGRect] {
        zip(ids[(i + 1)...], covers[i]).filter { motion.edges[$0.0]?.kind != .restoring }.map { $0.1.cgRect }
    }

    // MARK: A float

    private func title(_ id: String) -> String {
        if let s = model.tileState(id) { return s.title.isEmpty ? s.app : s.title }
        if let w = model.layout.tiles[id]?.source?.windowID, let item = model.catalog?.windows.first(where: { $0.id == w }) {
            return item.title.isEmpty ? item.app : item.title
        }
        return String(localized: "Window")
    }

    private func icon(_ id: String) -> CGImage? {
        model.layout.tiles[id]?.source?.bundleID.flatMap { model.icons[$0] }
    }

    /// One float's chrome. `covers`: what the floats in front of it cover (picture points). Its
    /// outline steps aside there, and its title pill, grips, grabber and notices aren't drawn (nor
    /// touchable) where they'd sit over a float in front: they would show through that float and
    /// take its touches.
    @ViewBuilder
    private func floatChrome(_ id: String, rect: CGRect, front: Bool, covers: [CGRect]) -> some View {
        let active = model.active == id
        // Being docked: only its card is drawn. Its title pill and grabber stay, empty and taking
        // no new touch: the move that docks it lives on one of them, and SwiftUI cancels a
        // gesture whose view goes away (the card and the drop targets would vanish with it).
        let docked = model.dockingFloat == id
        let moved = docked || motion.frames[id] != nil || resizeStart[id] != nil
        let outline = active ? floatAccent : Color.white.opacity(highContrast ? 0.75 : 0.3)
        let coverRects = covers.map(WorkspaceRect.init)
        let covered: (CGRect) -> Bool = { WorkspaceFloatLayering.isCovered(WorkspaceRect($0), by: coverRects) }
        let handles = WorkspaceFloatLayering.showsHandles(selected: active, hovered: model.hovered == id, manipulating: moved)
        // While a finger moves or resizes it the Mac leaves it out (`floatLift`) and it's drawn
        // here, from its last still, in its own view at this size. A Mac without lift keeps
        // drawing it (inside the picture): only its picture shows then, never a second copy.
        let drawnHere = model.drawsFloatHere(id)
        ZStack {
            if !docked {
                Group {
                    if drawnHere, let image = model.backdrop(id)?.image,
                       let view = model.floatContentTransform(id, width: rect.width, height: rect.height) {
                        FloatStill(image: image, view: view, size: rect.size, corner: floatCorner)
                    } else if drawnHere {
                        // Coming back out of its edge without a still of its own (the Mac leaves it out
                        // meanwhile): Stage Peek's still of the window, else its icon.
                        floatPicture(id, size: rect.size, corner: floatCorner)
                    }
                    RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                        .strokeBorder(Color.black.opacity(highContrast ? 0.8 : 0.45), lineWidth: active ? 3.5 : 2.5)
                    RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                        .strokeBorder(outline, lineWidth: active ? 2 : 1)
                }
                // Circled back: the card opens into the float under the finger (the title).
                .transition(.scale(scale: 0.3, anchor: .top).combined(with: .opacity))
            }
        }
        // Only opening animates: folding, the float goes at once and the card takes its place.
        .animation(docked || reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: docked)
        .frame(width: rect.width, height: rect.height)
        .mask(WorkspaceHoleMask(size: rect.size, holes: covers.map { $0.offsetBy(dx: -rect.minX, dy: -rect.minY) }))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("\(title(id)), floating window"))
        .accessibilityIdentifier("workspaceFloat")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction { model.raiseFloat(id); model.focus(id, raise: false) }   // selects it here only
        .modifier(FloatAccessibilityActions(model: model, id: id, front: front, tuck: { tuck(id, $0) }))
        .accessibilityHidden(docked)

        if docked || !covered(WorkspaceFloatLayering.pillBounds(WorkspaceRect(rect)).cgRect) {
            titlePill(id, rect: rect, active: active, outline: outline, docked: docked)
        }
        if handles {
            if docked || !covered(CGRect(x: rect.midX - 38, y: rect.maxY - 4, width: 76, height: 28)) { grabber(id, rect: rect, active: active, docked: docked) }
            if !docked, !covered(CGRect(x: rect.minX - 28, y: rect.maxY - 16, width: 44, height: 44)) { grip(id, rect: rect, corner: .bottomLeading, active: active) }
            if !docked, !covered(CGRect(x: rect.maxX - 16, y: rect.maxY - 16, width: 44, height: 44)) { grip(id, rect: rect, corner: .bottomTrailing, active: active) }
        }
        let middle = CGRect(x: rect.midX - 60, y: rect.midY - 24, width: 120, height: 48)
        if model.tileState(id)?.status == .offscreen, !moved, !covered(middle) { offscreenNotice(id, rect: rect) }
        else if active, model.remote?.hostFocus.isMismatch == true, !moved,
                !covered(CGRect(x: rect.midX - 60, y: rect.maxY - 54, width: 120, height: 40)) { typingPaused(id, rect: rect) }
        if (model.isResizingOnMac(id) || model.windowFrameNotice?.tile == id), !moved,
           !covered(CGRect(x: rect.midX - 60, y: rect.minY + 8, width: 120, height: 40)) {
            WorkspaceWindowFrameStatus(model: model, id: id)
                .frame(maxWidth: max(rect.width - 24, 120))
                .position(x: rect.midX, y: rect.minY + 34)
        }
    }

    /// Typing to this float paused: the Mac's focus moved to another app or window after its
    /// window came forward. Only this explicit tap brings the window forward again; arranging
    /// the float never does (keys meanwhile go nowhere, never into another window).
    private func typingPaused(_ id: String, rect: CGRect) -> some View {
        Button { model.focus(id) } label: {
            Text(model.remote?.hostFocus == .otherWindowFocused
                 ? "Typing paused: another window is in front on the Mac. Tap to resume."
                 : "Typing paused: another app is in front on the Mac. Tap to resume.")
                .font(.caption).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: max(rect.width - 24, 120))
        .position(x: rect.midX, y: rect.maxY - 34)
        .accessibilityIdentifier("floatTypingPaused")
    }

    /// The float's window isn't on screen on the Mac (minimized, hidden or in another Space).
    /// Nothing brings it back by itself (Minimize on Mac sticks); Show on Mac does, with control.
    @ViewBuilder
    private func offscreenNotice(_ id: String, rect: CGRect) -> some View {
        let app = model.tileState(id)?.app ?? ""
        VStack(spacing: 8) {
            Text("\(app.isEmpty ? "This window" : app) is minimized, hidden or in another Space on the Mac")
                .font(.callout.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            if inputAllowed, !model.missionControlOpen {
                Button { model.showOnMac(id) } label: {
                    Label("Show on Mac", systemImage: "macwindow").font(.callout.weight(.semibold))
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("floatShowOnMac")
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: max(rect.width - 24, 120))
        .position(x: rect.midX, y: rect.midY)
    }

    /// The title in a pill on the top edge, part of the outline. Drag it to move (fling to glide,
    /// at an edge to tuck); tap to select, double-tap for Fullscreen on This Device; ⋯ for options.
    /// `docked`: the float is being docked (only its card shows): the pill draws nothing and takes
    /// no new touch, but stays, because the move that docks it lives here.
    private func titlePill(_ id: String, rect: CGRect, active: Bool, outline: Color, docked: Bool) -> some View {
        let maxWidth = max(min(rect.width - 28, 280), 90)
        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                if let icon = icon(id) { Image(decorative: icon, scale: 1).resizable().frame(width: 14, height: 14) }
                Text(title(id)).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Color.white.opacity(active ? 1 : 0.8))
                    .frame(maxWidth: max(maxWidth - 64, 40))
            }
            .opacity(docked ? 0 : 1)
            .padding(.leading, 10)
            .frame(minHeight: 26)
            .contentShape(FloatTouchArea(on: !docked))
            .gesture(moveGesture(id))
            // Taps counted like a pane title's (a double tap: Fullscreen on This Device). A tap
            // recognizer, so a system double-tap recognizer that cancels the drag can't swallow it.
            .simultaneousGesture(TapGesture().onEnded { tapped(id) })
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(title(id)))
            .accessibilityHint(Text("Drag to move. Throw it toward an edge to tuck it away."))
            .accessibilityAddTraits(.isButton)
            .hoverEffect(.highlight)
            WorkspaceStableMenuButton(symbol: "ellipsis", accessibilityLabel: String(localized: "Options for \(title(id))"),
                                      accessibilityIdentifier: "floatOptions") { floatMenu(id) }
                .frame(width: 34, height: 28)
                .opacity(docked ? 0 : 1)
                .allowsHitTesting(!docked)
        }
        .fixedSize()
        .background(Capsule().fill(floatChip).opacity(docked ? 0 : 1).allowsHitTesting(!docked))
        .overlay(Capsule().strokeBorder(outline, lineWidth: active ? 2 : 1).opacity(docked ? 0 : 1).allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(docked)
        .position(x: rect.midX, y: rect.minY)
    }

    /// A short bar under the window: the same move as the title (and, like it, empty but kept
    /// while the float is being docked).
    private func grabber(_ id: String, rect: CGRect, active: Bool, docked: Bool) -> some View {
        let below = rect.maxY + 12 <= picture.maxY - 4
        return Capsule().fill(Color.white.opacity(active ? 0.9 : 0.55))
            .overlay(Capsule().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
            .frame(width: 40, height: 5)
            .opacity(docked ? 0 : 1)
            .frame(width: 76, height: 28)
            .contentShape(FloatTouchArea(on: !docked))
            .position(x: rect.midX, y: below ? rect.maxY + 10 : rect.maxY - 10)
            .gesture(moveGesture(id))
            .hoverEffect(.highlight)
            .accessibilityHidden(true)   // the float's own actions move it
    }

    /// A curved grip around a lower corner (visionOS-style). Drag to resize; the window keeps its shape.
    private func grip(_ id: String, rect: CGRect, corner: WorkspaceFloatGeometry.Corner, active: Bool) -> some View {
        let leading = corner == .bottomLeading
        let x = leading ? rect.minX - 6 : rect.maxX + 6
        return FloatGripArc(leading: leading)
            .stroke(Color.white.opacity(active ? 0.92 : 0.5), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .shadow(color: .black.opacity(0.55), radius: 1.5)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: x, y: rect.maxY + 6)
            .gesture(resizeGesture(id, corner: corner))
            .modifier(FloatResizePointer(leading: leading))
            .accessibilityHidden(true)   // Make Larger / Make Smaller in the float's actions
    }

    /// The window's last still (its own, else Stage Peek's), if this device has one.
    private func stillImage(_ id: String) -> CGImage? {
        if let b = model.backdrop(id)?.image { return b }
        return model.layout.tiles[id]?.source.flatMap { model.thumbnails[$0.windowID] }
    }

    /// Float `id`'s window at `size`, in its own view (Fit, Fill, zoom, rotation), from its last
    /// still; without one, a dark card with its app's icon.
    @ViewBuilder
    private func floatPicture(_ id: String, size: CGSize, corner: CGFloat) -> some View {
        if let image = stillImage(id), let view = model.floatContentTransform(id, width: size.width, height: size.height) {
            FloatStill(image: image, view: view, size: size, corner: corner)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                if let icon = icon(id) {
                    let side = min(max(min(size.width, size.height) * 0.3, 14), 48)
                    Image(decorative: icon, scale: 1).resizable().frame(width: side, height: side)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: Moving and flinging

    private func moveGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .updating($pressing) { _, held, _ in held.insert(id) }
            .onChanged { v in
                if start[id] == nil {
                    start[id] = motion.catchFloat(id) ?? model.layout.float(id)?.frame
                    model.beginFloatGesture(id)   // and a new `model.floatMove` (circling from scratch)
                    samples[id] = []
                    ring = nil
                }
                guard let s = start[id] else { return }
                var list = samples[id] ?? []
                list.append(Sample(point: v.location, time: v.time.timeIntervalSinceReferenceDate))
                if list.count > 10 { list.removeFirst(list.count - 10) }
                samples[id] = list
                if !moving.contains(id) {
                    if hypot(v.translation.width, v.translation.height) < 4 { return }
                    moving.insert(id)
                    model.liftFloat(id)   // drawn here from now; a tap never lifts
                }
                let global = CGPoint(x: v.location.x + toGlobal.x, y: v.location.y + toGlobal.y)
                finger = v.location
                // Circling while held (a circle and a bit, about a second): switch between moving it
                // and docking it into the layout (`WorkspaceFloatMove`; while docking this moves the
                // drag). A ring above the finger fills as it goes.
                let here = (motion.frames[id] ?? model.layout.float(id)?.frame)?.screen(in: picture)
                let switched = model.moveFloatFinger(id, to: global, at: v.time.timeIntervalSinceReferenceDate)
                let progress = model.floatMove?.circling.progress ?? 0
                ring = progress > 0 ? Ring(at: v.location, progress: progress, toFloating: model.dockingFloat == id) : nil
                if ring != nil { fadeRingWhenQuiet() }
                switch switched {
                case .dock?:
                    // The float folds into a card under the finger: it's drawn nowhere else, here or
                    // on the Mac, until it's dropped (Cancel puts it back as it was) or circled back.
                    motion.drop(id)
                    card = DockCard(id: id, from: here ?? CGRect(x: v.location.x - 80, y: v.location.y - 50, width: 160, height: 100), collapsed: false)
                    // Drawn once where the float was, then folded (the next update, so it animates).
                    Task { @MainActor in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                            if card?.id == id { card?.collapsed = true }
                        }
                    }
                case .float?:
                    // Back to moving it: the card opens into the float under the finger (below).
                    card = nil
                case nil:
                    break
                }
                if switched != nil { ring = nil; Self.haptic(.toggle) }
                if model.dockingFloat == id { return }
                var f = s
                f.x += v.translation.width / max(picture.width, 1)
                f.y += v.translation.height / max(picture.height, 1)
                // It follows the finger past any edge (a corner too), clipped by the screen; where
                // it comes to rest is decided when it's let go. What's sent is kept inside the
                // picture. Lifted, this device draws it where the finger holds it; otherwise the
                // Mac draws it (inside), and its outline stays with that one picture.
                held[id] = f
                model.updateFloatFrame(id, f)
                motion.drag(id, model.drawsFloatHere(id) ? f : (model.layout.float(id)?.frame ?? f))
            }
            .onEnded { v in
                let wasMoving = moving.contains(id)
                let s = start[id]
                let list = samples[id] ?? []
                start[id] = nil; moving.remove(id); samples[id] = nil
                ring = nil
                if model.dockingFloat == id {
                    // On a pane target: docked there. On Remove: removed here only. Else put back.
                    card = nil
                    motion.drop(id)
                    if model.endDockingFloat(id) { Self.haptic(.drop) }
                    return
                }
                guard s != nil else { return }
                guard wasMoving else {
                    motion.drop(id)
                    model.endFloatGesture(id)
                    return
                }
                release(id, frame: held[id] ?? motion.frames[id] ?? model.layout.float(id)?.frame ?? .unit, velocity: velocity(list))
            }
    }

    /// Picture points per second over the last ~80 ms of the drag.
    private func velocity(_ list: [Sample]) -> (x: Double, y: Double) {
        guard let last = list.last, let first = list.first(where: { last.time - $0.time <= 0.08 }) else { return (0, 0) }
        let dt = last.time - first.time
        guard dt > 0.008 else { return (0, 0) }
        return ((last.point.x - first.point.x) / dt, (last.point.y - first.point.y) / dt)
    }

    /// Stays, glides on, or tucks into the edge its throw reaches (`WorkspaceFloatMotion.decide`).
    /// `frame`: where the finger let go of it, past any edge. Let go short of a tuck it comes to
    /// rest where its title pill is reachable, gliding from where it's drawn.
    private func release(_ id: String, frame: WorkspaceRect, velocity: (x: Double, y: Double)) {
        let size = pictureSize
        let shares = (x: velocity.x / size.width, y: velocity.y / size.height)
        let drawn = motion.frames[id] ?? model.layout.float(id)?.frame ?? frame
        held[id] = nil
        switch WorkspaceFloatMotion.decide(release: frame, velocity: velocity, in: size, edges: tuckEdges, safe: restArea) {
        case .settle(let target, let glide):
            if glide, !reduceMotion {
                motion.glide(id, from: drawn, to: target, velocity: shares)
            } else {
                motion.drop(id)
                model.endFloatGesture(id, frame: target)
            }
        case .tuck(let edge, let offset):
            // On along its throw into the edge where its path crossed it, tucked before it lands so
            // the Mac never draws it there again.
            tuckAway(id, edge: edge, along: offset, from: drawn.screen(in: picture), velocity: velocity)
            model.endFloatGesture(id)
        }
    }

    /// Feedback for a tuck, however it happened: one haptic and what VoiceOver says.
    private func tucked(_ id: String, _ edge: WorkspaceEdge) {
        Self.haptic(.drop)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "\(title(id)) tucked at the \(edgeName(edge)) edge"))
    }

    private func edgeName(_ edge: WorkspaceEdge) -> String {
        switch edge {
        case .left: return String(localized: "left")
        case .right: return String(localized: "right")
        case .top: return String(localized: "top")
        case .bottom: return String(localized: "bottom")
        }
    }

    private func tapped(_ id: String) {
        let now = Date()
        if let last = lastTap, last.id == id, now.timeIntervalSince(last.at) < 0.35 {
            lastTap = nil
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.toggleLocalFullscreen(id) }
            Self.haptic(.drop)
            return
        }
        lastTap = (id, now)
    }

    private func resizeGesture(_ id: String, corner: WorkspaceFloatGeometry.Corner) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .onChanged { v in
                if resizeStart[id] == nil {
                    guard let f = model.layout.float(id)?.frame else { return }
                    resizeStart[id] = f
                    model.beginFloatGesture(id)
                }
                guard let s = resizeStart[id] else { return }
                if hypot(v.translation.width, v.translation.height) > 2 { model.liftFloat(id) }
                // Width and height follow the finger freely: the window keeps its view (Fit with
                // bars, Fill, zoom) at the new size, never stretched.
                let r = WorkspaceFloatGeometry.resized(s, corner: corner, translation: (v.translation.width, v.translation.height),
                                                       aspect: nil, in: pictureSize)
                model.updateFloatFrame(id, r)
            }
            .onEnded { _ in
                guard resizeStart.removeValue(forKey: id) != nil else { return }
                model.endFloatGesture(id)
            }
    }

    // MARK: Options

    /// The ⋯ menu, built each time it opens (`WorkspaceStableMenuButton`). Short enough for a phone
    /// in portrait: the frequent local actions as two rows of three, then the rest of what happens
    /// on this device, and everything that changes the real Mac window in its own "On Your Mac"
    /// submenu, so the two are never mixed up.
    private func floatMenu(_ id: String) -> [UIMenuElement] {
        let front = model.layout.visibleFloatIDs.last == id
        let filled = model.effectiveFit(id) == .fill
        let narrow = picture.width < 600
        func act(_ title: String, _ symbol: String, _ attributes: UIMenuElement.Attributes = [],
                 _ run: @escaping @MainActor () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in run() }
        }
        // On this device only. The first two rows are palettes (three items side by side).
        let placement = UIMenu(title: String(localized: "On This Device"), options: .displayInline, preferredElementSize: .medium, children: [
            act(String(localized: "Fullscreen"), "arrow.up.left.and.arrow.down.right") { model.toggleLocalFullscreen(id) },
            act(String(localized: "Tuck Left"), "sidebar.left") { tuck(id, .left) },
            act(String(localized: "Tuck Right"), "sidebar.right") { tuck(id, .right) },
        ])
        let view = UIMenu(title: "", options: .displayInline, preferredElementSize: .medium, children: [
            filled ? act(String(localized: "Whole Window"), "rectangle.arrowtriangle.2.inward") { model.toggleFit(id) }
                   : act(String(localized: "Fill Viewport"), "rectangle.arrowtriangle.2.outward") { model.toggleFit(id) },
            act(String(localized: "Rotate"), "rotate.right") { model.rotate(id) },
            act(String(localized: "Reset View"), "arrow.counterclockwise") { model.resetView(id) },
        ])
        var local: [UIMenuElement] = []
        if !front {
            local.append(act(String(localized: "Bring to Front"), "square.3.layers.3d.top.filled") { model.raiseFloat(id); model.focus(id, raise: false) })
        }
        local.append(act(String(localized: "Add to Layout"), "rectangle.split.2x1") { model.addFloatToLayout(id) })
        local.append(UIMenu(title: String(localized: "Size"), image: UIImage(systemName: "arrow.up.left.and.down.right.magnifyingglass"), children: [
            act(String(localized: "Small"), "rectangle.inset.filled") { model.sizeFloat(id, widthShare: narrow ? 0.45 : 0.3) },
            act(String(localized: "Medium"), "rectangle.inset.filled") { model.sizeFloat(id, widthShare: narrow ? 0.65 : 0.45) },
            act(String(localized: "Large"), "rectangle.inset.filled") { model.sizeFloat(id, widthShare: narrow ? 0.9 : 0.65) },
            act(String(localized: "Match Window"), "aspectratio") { model.matchWindowShape(id) },
        ]))
        local.append(act(String(localized: "Change Window…"), "macwindow.on.rectangle") { model.openOverview(replacing: id) })
        local.append(act(String(localized: "Remove from This Device"), "rectangle.badge.minus") { model.removeFloat(id) })

        // The real window on the Mac: needs control, and says so.
        let off: UIMenuElement.Attributes = inputAllowed ? [] : [.disabled]
        var mac: [UIMenuElement] = []
        if model.tileState(id)?.status == .offscreen {
            mac.append(act(String(localized: "Show on Mac"), "macwindow", off) { model.showOnMac(id) })
        }
        if model.offersWindowFrameOnMac(id) {
            // The real Mac window, not this float's view: only from these items, never a gesture.
            let ready: UIMenuElement.Attributes = model.canControlMac && !model.isResizingOnMac(id) ? [] : [.disabled]
            mac.append(act(String(localized: "Fill Window on Mac"), "arrow.up.and.down.and.arrow.left.and.right", ready) { model.fillWindowOnMac(id) })
            if model.canRestoreOnMac(id) {
                mac.append(act(String(localized: "Restore Previous Size on Mac"), "arrow.uturn.backward", ready) { model.restoreWindowOnMac(id) })
            }
        }
        mac.append(act(String(localized: "Minimize on Mac"), "minus.rectangle", off) { model.minimizeRemoteWindow(id) })
        mac.append(act(String(localized: "Close Window on Mac…"), "xmark.square", off.union(.destructive)) { onClose(id) })
        let onMac = UIMenu(title: String(localized: "On Your Mac"), image: UIImage(systemName: "desktopcomputer"), children: mac)
        onMac.subtitle = inputAllowed ? String(localized: "Changes the real window") : String(localized: "Needs control of the Mac")

        return [placement, view, UIMenu(title: "", options: .displayInline, children: local),
                UIMenu(title: "", options: .displayInline, children: [onMac])]
    }

    private func tuck(_ id: String, _ edge: WorkspaceEdge) {
        guard let f = model.layout.float(id), f.tuck == nil else { return }
        tuckAway(id, edge: edge, along: WorkspaceFloatMotion.along(f.frame, edge), from: (motion.frames[id] ?? f.frame).screen(in: picture))
    }

    /// Tucks float `id` into `edge` at `along` (a share of that edge). It waits flush with that
    /// edge, at its own size, where its strip is, so it comes straight back out there; meanwhile
    /// the same picture slides from `from` (where it's drawn, picture points) into its strip,
    /// carrying `velocity` (points/s). A fade with Reduce Motion.
    private func tuckAway(_ id: String, edge: WorkspaceEdge, along: Double, from: CGRect, velocity: (x: Double, y: Double) = (0, 0)) {
        guard let f = model.layout.float(id) else { return }
        let waiting = WorkspaceFloatGeometry.tuckedFrame(f.frame, edge: edge, along: along, in: pictureSize, area: restArea, safe: restArea)
        motion.drop(id)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : nil) { model.tuckFloat(id, edge: edge, offset: along, frame: waiting) }
        if !reduceMotion, let w = waitingPlace(id) {
            let open = WorkspaceRect(picture.union(from).insetBy(dx: -1, dy: -1))
            let path = WorkspaceFloatGeometry.EdgePath(edge: w.edge, from: WorkspaceRect(from), to: w.float, clipFrom: open, clipTo: w.clip)
            // The throw's speed along the way in, as a share of the way per second.
            let dx = path.to.x - path.from.x, dy = path.to.y - path.from.y, d2 = dx * dx + dy * dy
            let v = d2 > 1 ? (velocity.x * dx + velocity.y * dy) / d2 : 0
            motion.glideEdge(id, path: path, from: 0, to: 1, velocity: v, kind: .tucking)
        }
        tucked(id, edge)
    }

    // MARK: Tucked floats

    private struct Handle { var key: String; var tab: WorkspaceFloatGeometry.TuckTab }

    /// Where tucked floats wait (workspace points): the picture in the safe area, clear of the
    /// system's edge bands at the screen's top and bottom. Its edges are where they go behind.
    private var handleArea: WorkspaceRect? {
        let screen = model.edgeReservationsGlobal.screen
        let o = toGlobal
        return WorkspaceFloatGeometry.handleArea(
            picture: WorkspaceRect(picture), safe: safeArea.map { WorkspaceRect($0) },
            screen: screen.width > 0 && screen.height > 0 ? WorkspaceRect(screen.offsetBy(dx: -o.x, dy: -o.y)) : nil)
    }

    /// The fixed controls and Stage Peek's handle (workspace points): strips give way to them.
    private var reservedHere: [WorkspaceRect] {
        let o = toGlobal
        return model.edgeReservationsGlobal.controls.map { WorkspaceRect($0.offsetBy(dx: -o.x, dy: -o.y)) }
    }

    /// The edges a float may be thrown into now (those with room for a strip).
    private var tuckEdges: Set<WorkspaceEdge> { WorkspaceFloatGeometry.tuckEdges(area: handleArea) }

    /// Picture points as shares of the picture.
    private func shares(_ r: WorkspaceRect) -> WorkspaceRect {
        let w = max(Double(picture.width), 1), h = max(Double(picture.height), 1)
        return WorkspaceRect(x: (r.x - Double(picture.minX)) / w, y: (r.y - Double(picture.minY)) / h, width: r.width / w, height: r.height / h)
    }

    /// `handleArea` as shares of the picture: where a float's title pill must be when it comes to
    /// rest (in the safe area, clear of the system's edge bands), and the edges tucked floats wait
    /// flush with. nil: the whole picture.
    private var restArea: WorkspaceRect? { handleArea.map(shares) }

    /// Every tucked float's strip (or stack), in reading order around the edges (left, top, right, bottom).
    private func tuckHandles() -> [Handle] {
        guard let area = handleArea else { return [] }
        return WorkspaceFloatGeometry.tuckHandles(model.layout.floats, picture: WorkspaceRect(picture), area: area, reserved: reservedHere)
            .map { Handle(key: "\($0.edge.rawValue)-" + $0.ids.joined(separator: ","), tab: $0) }
    }

    private func publishHandles(_ handles: [Handle]) {
        let o = toGlobal
        let rects = handles.map { CGRect(x: $0.tab.rect.x + o.x, y: $0.tab.rect.y + o.y, width: $0.tab.rect.width, height: $0.tab.rect.height) }
        if model.floatHandlesGlobal != rects { model.floatHandlesGlobal = rects }
    }

    /// Where tucked float `id` waits (points): the float behind its strip and the strip that shows,
    /// or, in a stack, all of it behind the edge at the stack's handle with nothing showing.
    private func waitingPlace(_ id: String) -> (edge: WorkspaceEdge, float: WorkspaceRect, clip: WorkspaceRect)? {
        guard let f = model.layout.float(id), f.tuck != nil, let area = handleArea,
              let tab = tuckHandles().first(where: { $0.tab.ids.contains(id) })?.tab else { return nil }
        guard tab.isStack else { return (tab.edge, tab.float, tab.rect) }
        let size = WorkspaceSize(width: f.frame.width * Double(picture.width), height: f.frame.height * Double(picture.height))
        let h = WorkspaceFloatGeometry.hidden(size, edge: tab.edge, area: area, along: tab.edge.axis == .horizontal ? tab.rect.midY : tab.rect.midX)
        return (tab.edge, h.float, h.line)
    }

    /// The way tucked float `id` comes out of its edge: straight out from where it waits (behind
    /// its strip, wherever that slid along the edge to) to its frame there, kept reachable.
    private func pullPath(_ id: String) -> WorkspaceFloatGeometry.EdgePath? {
        guard let f = model.layout.float(id), let w = waitingPlace(id) else { return nil }
        let back = WorkspaceFloatGeometry.comingBack(f.frame, waiting: shares(w.float), edge: w.edge, in: pictureSize, safe: restArea)
        return WorkspaceFloatGeometry.EdgePath(edge: w.edge, from: w.float, to: WorkspaceRect(back.screen(in: picture)),
                                               clipFrom: w.clip, clipTo: WorkspaceRect(picture))
    }

    /// Brings a tucked float back: the same picture comes on out of its edge (from where a peek or
    /// a pull left it, carrying the finger's speed, `velocity`: share of the way per second) to
    /// where it comes back to, and the Mac's live window takes over where it lands (lifted on the
    /// way where the Mac can, so it's never on screen twice). It fades in there with Reduce Motion.
    /// One haptic.
    private func restore(_ id: String, velocity: Double = 0) {
        if motion.edges[id]?.kind == .restoring { return }   // on its way out already
        let held = motion.edges[id].flatMap { $0.kind == .tucking ? nil : $0 }
        guard model.layout.float(id)?.tuck != nil, let path = held?.path ?? pullPath(id) else { motion.dropEdge(id); return }
        let back = shares(path.to)
        Self.haptic(.drop)
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                motion.dropEdge(id)
                model.beginRestoringFloat(id, frame: back)
                model.endFloatGesture(id)   // its still until the Mac's picture of it is in
            }
            return
        }
        let start = held?.p ?? 0
        if model.canLiftFloats {
            // Shown again now, so its capture starts on the way, but left out by the Mac until it lands.
            model.beginRestoringFloat(id, frame: back)
            motion.glideEdge(id, path: path, from: start, to: 1, velocity: velocity, kind: .restoring) { [model] in model.endFloatGesture(id) }
        } else {
            // A Mac without lift draws it as soon as it's shown: shown once it's out.
            motion.glideEdge(id, path: path, from: start, to: 1, velocity: velocity, kind: .restoring) { [model] in model.untuckFloat(id, frame: back) }
        }
    }

    /// A pull let go short of the restore point (or cancelled): the same picture slides back into
    /// its edge, carrying the finger's speed (share of the way per second).
    private func pullFellShort(_ id: String, velocity: Double = 0) {
        guard let s = motion.edges[id], s.kind == nil else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { motion.dropEdge(id) }
            return
        }
        motion.glideEdge(id, path: s.path, from: s.p, to: 0, velocity: velocity, kind: .returning)
    }

    /// While a float is dragged more than halfway past an edge (letting go would tuck it there),
    /// that edge glows where its strip would go, as long as the strip.
    @ViewBuilder
    private var armedEdges: some View {
        let edges = tuckEdges
        ForEach(Array(moving).sorted(), id: \.self) { id in
            if model.dockingFloat != id, let f = held[id] ?? motion.frames[id], let edge = WorkspaceFloatMotion.pulledEdge(f, edges: edges),
               let area = handleArea {
                let mark = armedMark(f, edge: edge, area: area)
                Capsule()
                    .fill(floatAccent)
                    .frame(width: mark.width, height: mark.height)
                    .shadow(color: floatAccent.opacity(0.7), radius: 6)
                    .position(x: mark.midX, y: mark.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
    }

    /// The glow for a float at `f` armed to tuck into `edge`: along that edge, where it is, as long
    /// as the float (within the edge).
    private func armedMark(_ f: WorkspaceRect, edge: WorkspaceEdge, area: WorkspaceRect) -> CGRect {
        let thick = 5.0
        let along = WorkspaceFloatMotion.along(f, edge)
        let r: WorkspaceRect
        switch edge {
        case .left, .right:
            let length = min(max(f.height * Double(picture.height), WorkspaceFloatGeometry.minimumStripLength), area.height)
            let c = min(max(Double(picture.minY) + along * Double(picture.height), area.y + length / 2), area.maxY - length / 2)
            r = WorkspaceRect(x: edge == .left ? area.x + 1 : area.maxX - 1 - thick, y: c - length / 2, width: thick, height: length)
        case .top, .bottom:
            let length = min(max(f.width * Double(picture.width), WorkspaceFloatGeometry.minimumStripLength), area.width)
            let c = min(max(Double(picture.minX) + along * Double(picture.width), area.x + length / 2), area.maxX - length / 2)
            r = WorkspaceRect(x: c - length / 2, y: edge == .top ? area.y + 1 : area.maxY - 1 - thick, width: length, height: thick)
        }
        return r.cgRect
    }

    // MARK: Strips

    /// A tucked float drawn at its edge: at rest as its strip (`tab`), or on its way out or in
    /// (`motion.edges`; `tab` nil once it's no longer tucked or while it's in a stack).
    private struct EdgeItem: Identifiable {
        var id: String
        var tab: WorkspaceFloatGeometry.TuckTab?
    }

    private func edgeItems(_ handles: [Handle]) -> [EdgeItem] {
        var items = handles.compactMap { h in h.tab.isStack ? nil : h.tab.ids.first.map { EdgeItem(id: $0, tab: h.tab) } }
        let have = Set(items.map(\.id))
        items += motion.edges.keys.sorted().filter { !have.contains($0) }.map { EdgeItem(id: $0, tab: nil) }
        return items
    }

    /// How far a strip being slid along its edge has moved.
    private func slide(_ id: String, _ edge: WorkspaceEdge) -> CGSize {
        guard let t = handleTouches[id], t.mode == .slide else { return .zero }
        return edge.axis == .horizontal ? CGSize(width: 0, height: t.translation.height) : CGSize(width: t.translation.width, height: 0)
    }

    /// Where an edge item is drawn: on its way along its edge path, else at rest at its strip.
    private func edgePlace(_ item: EdgeItem) -> (rect: CGRect, clip: CGRect, edge: WorkspaceEdge, lit: Bool)? {
        if let s = motion.edges[item.id] {
            return (s.path.rect(s.p).cgRect, s.path.clip(s.p).cgRect, s.path.edge, s.kind == nil)
        }
        guard let tab = item.tab else { return nil }
        let d = slide(item.id, tab.edge)
        return (tab.float.cgRect.offsetBy(dx: d.width, dy: d.height), tab.rect.cgRect.offsetBy(dx: d.width, dy: d.height), tab.edge,
                handleTouches[item.id] != nil || hoveredStrip == item.id)
    }

    /// One view per tucked float, at rest or moving, so a peek, a pull and a slide back move the
    /// same picture (animated where they're animated) instead of swapping one for another.
    @ViewBuilder
    private func edgeItem(_ item: EdgeItem) -> some View {
        if let place = edgePlace(item) {
            edgePicture(item.id, rect: place.rect, clip: place.clip, edge: place.edge, lit: place.lit)
        }
    }

    /// A tucked float as one picture, from the moment it's tucked until it's back: its own window
    /// (its last still in its own view: Fit or Fill, zoom, rotation; without one, its dark card
    /// and icon) at its own size at `rect`, only the part inside `clip` showing. At rest that is
    /// a thin slice of its inner side at the edge, with a quiet grip saying it can be pulled out
    /// (brighter while touched or under the pointer; it fades as the window comes further out
    /// than a peek).
    private func edgePicture(_ id: String, rect: CGRect, clip: CGRect, edge: WorkspaceEdge, lit: Bool) -> some View {
        let alongY = edge.axis == .horizontal
        let visible = rect.intersection(clip)
        let d = CGFloat(WorkspaceFloatGeometry.stripDepth)
        let grip: CGPoint = {
            switch edge {
            case .left: return CGPoint(x: rect.maxX - d / 2, y: visible.midY)
            case .right: return CGPoint(x: rect.minX + d / 2, y: visible.midY)
            case .top: return CGPoint(x: visible.midX, y: rect.maxY - d / 2)
            case .bottom: return CGPoint(x: visible.midX, y: rect.minY + d / 2)
            }
        }()
        let gripLength = min(36, max((alongY ? visible.height : visible.width) * 0.3, 16))
        // How far it shows past the edge: the grip stays through a peek, gone 24 pt further out.
        let shownDepth = visible.isNull ? 0 : Double(alongY ? visible.width : visible.height)
        let gripShown = min(max(1 - (shownDepth - WorkspaceFloatGeometry.peekDepth) / 24, 0), 1)
        let badge = stillImage(id) == nil ? icon(id) : nil
        return ZStack {
            ZStack {
                floatPicture(id, size: rect.size, corner: floatCorner)
                RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(highContrast ? 0.75 : 0.35), lineWidth: 1)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            if !visible.isNull, !visible.isEmpty, gripShown > 0 {
                Capsule().fill(Color.white.opacity(lit ? 0.95 : 0.5))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                    .frame(width: alongY ? 4 : gripLength, height: alongY ? gripLength : 4)
                    .shadow(color: .black.opacity(0.45), radius: 1.5)
                    .opacity(gripShown)
                    .position(grip)
                if let badge {
                    // No still yet: its app's icon beside the grip, so the slice says whose it is.
                    Image(decorative: badge, scale: 1).resizable().frame(width: 14, height: 14)
                        .opacity(gripShown)
                        .position(x: alongY ? grip.x : grip.x - gripLength / 2 - 12, y: alongY ? grip.y - gripLength / 2 - 12 : grip.y)
                }
            }
        }
        .mask(Rectangle().frame(width: max(clip.width, 0), height: max(clip.height, 0)).position(x: clip.midX, y: clip.midY))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// Where a strip takes touches: its visible slice, `touchDepth` in from its edge (at least 44 pt long).
    private func touchFrame(_ r: CGRect, _ edge: WorkspaceEdge) -> CGRect {
        let d = CGFloat(WorkspaceFloatGeometry.touchDepth)
        switch edge {
        case .left: return CGRect(x: r.minX, y: r.midY - max(r.height, 44) / 2, width: d, height: max(r.height, 44))
        case .right: return CGRect(x: r.maxX - d, y: r.midY - max(r.height, 44) / 2, width: d, height: max(r.height, 44))
        case .top: return CGRect(x: r.midX - max(r.width, 44) / 2, y: r.minY, width: max(r.width, 44), height: d)
        case .bottom: return CGRect(x: r.midX - max(r.width, 44) / 2, y: r.maxY - d, width: max(r.width, 44), height: d)
        }
    }

    /// Against its edge inside a larger frame.
    private func edgeAlignment(_ edge: WorkspaceEdge) -> Alignment {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    /// The centre of a frame of `size` set against `edge` at the handle `r`.
    private func anchored(_ size: CGSize, at r: CGRect, _ edge: WorkspaceEdge) -> CGPoint {
        switch edge {
        case .left: return CGPoint(x: r.minX + size.width / 2, y: r.midY)
        case .right: return CGPoint(x: r.maxX - size.width / 2, y: r.midY)
        case .top: return CGPoint(x: r.midX, y: r.minY + size.height / 2)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY - size.height / 2)
        }
    }

    @ViewBuilder
    private func handle(_ tab: WorkspaceFloatGeometry.TuckTab) -> some View {
        if tab.isStack {
            stackHandle(tab)
        } else if let id = tab.ids.first {
            stripTouch(id, tab: tab)
        }
    }

    /// Where a tucked float's strip takes touches, and its one VoiceOver element. Touch it and the
    /// float peeks out a little more; pull it inward and it comes out under the finger (let go
    /// past `WorkspaceFloatMotion.restoreProgress`, or flicked, it comes on out; short of it, it
    /// slides back in); tap it and it slides out; slide it along the edge to move it. The picture
    /// is drawn by `edgePicture`; this takes no more room than the slice and a 44 pt target.
    private func stripTouch(_ id: String, tab: WorkspaceFloatGeometry.TuckTab) -> some View {
        let target = touchFrame(tab.rect.cgRect, tab.edge)
        return Color.clear
            .frame(width: target.width, height: target.height)
            .contentShape(Rectangle())
            .gesture(stripGesture(id, tab: tab))
            .onHover { inside in
                if inside { hoveredStrip = id } else if hoveredStrip == id { hoveredStrip = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Restore \(title(id))"))
            .accessibilityValue(Text("Tucked at the \(edgeName(tab.edge)) edge"))
            .accessibilityHint(Text("Brings the floating window back where it was."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { restore(id) }
            .accessibilityAction(named: Text("Restore")) { restore(id) }
            .accessibilityAction(named: Text("Remove from This Device")) { model.removeFloat(id) }
            .accessibilityIdentifier("floatTuckHandle")
            .position(x: target.midX, y: target.midY)
            .transition(.opacity)
    }

    /// Points into the picture, the way the float comes back.
    private func chevronName(_ edge: WorkspaceEdge) -> String {
        switch edge {
        case .left: return "chevron.compact.right"
        case .right: return "chevron.compact.left"
        case .top: return "chevron.compact.down"
        case .bottom: return "chevron.compact.up"
        }
    }

    /// Several tucked floats on an edge with no room for each: one handle with a menu of them.
    private func stackHandle(_ tab: WorkspaceFloatGeometry.TuckTab) -> some View {
        let r = tab.rect.cgRect
        let edge = tab.edge
        let target = touchFrame(r, edge)
        let centre = anchored(target.size, at: r, edge)
        let marks = Group {
            Text("\(tab.ids.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
            Image(systemName: chevronName(edge)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.85))
        }
        return ZStack {
            EdgeTabShape(edge: edge).fill(floatChip)
                .overlay(EdgeTabShape(edge: edge).stroke(Color.white.opacity(highContrast ? 0.75 : 0.35), lineWidth: 1))
            if edge.axis == .horizontal { VStack(spacing: 4) { marks } } else { HStack(spacing: 4) { marks } }
        }
        .frame(width: r.width, height: r.height)
        .frame(width: target.width, height: target.height, alignment: edgeAlignment(edge))
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
        .overlay(WorkspaceStableMenuButton(symbol: nil, accessibilityLabel: String(localized: "\(tab.ids.count) tucked floating windows"),
                                           accessibilityIdentifier: "floatTuckHandle") {
            tab.ids.map { id in UIAction(title: String(localized: "Restore \(title(id))")) { _ in restore(id) } }
        })
        .position(x: centre.x, y: centre.y)
        .transition(.opacity)
    }

    // MARK: Peek, pull and restore

    /// Movement (points) past which a touch on a strip is a pull, a slide or a push back.
    private static let decideDistance: CGFloat = 8

    private func stripGesture(_ id: String, tab: WorkspaceFloatGeometry.TuckTab) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .updating($handlesHeld) { _, held, _ in held.insert(id) }
            .onChanged { v in stripChanged(id, tab: tab, v) }
            .onEnded { v in stripEnded(id, tab: tab, v) }
    }

    /// The part of a movement away from `edge` (into the picture) and the part along it.
    private func split(_ t: CGSize, _ edge: WorkspaceEdge) -> (inward: CGFloat, along: CGFloat) {
        switch edge {
        case .left: return (t.width, t.height)
        case .right: return (-t.width, t.height)
        case .top: return (t.height, t.width)
        case .bottom: return (-t.height, t.width)
        }
    }

    private func stripChanged(_ id: String, tab: WorkspaceFloatGeometry.TuckTab, _ v: DragGesture.Value) {
        let first = handleTouches[id] == nil
        var t = handleTouches[id] ?? HandleTouch()
        t.translation = v.translation
        t.samples.append(Sample(point: v.location, time: v.time.timeIntervalSinceReferenceDate))
        if t.samples.count > 10 { t.samples.removeFirst(t.samples.count - 10) }
        if first {
            if let s = motion.edges[id], s.kind == .tucking || s.kind == .restoring {
                // Still sliding in or out: the touch is taken (it never reaches the window below)
                // and does nothing. A pull that fell short can be caught again.
                t.mode = .away
            } else if let s = motion.edges[id], s.kind == .returning {
                // Caught on its way back in: from where it is.
                t.start = s.p
                motion.holdEdge(id, path: s.path, p: s.p)
            } else if let path = pullPath(id) {
                // Touched: it comes out a little more (a peek).
                t.start = path.progress(inward: WorkspaceFloatGeometry.peekDepth - WorkspaceFloatGeometry.stripDepth)
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.78)) {
                    motion.holdEdge(id, path: path, p: t.start)
                }
            }
        }
        if t.mode == .peek, hypot(v.translation.width, v.translation.height) >= Self.decideDistance {
            let (inward, along) = split(v.translation, tab.edge)
            t.mode = abs(along) > abs(inward) ? .slide : (inward > 0 ? .pull : .away)
            if t.mode != .pull {
                // Slid along its edge or pushed back in: the peek goes back in.
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.86)) { motion.dropEdge(id) }
            }
        }
        handleTouches[id] = t
        // Pulled: the same picture follows the finger out of its edge (and back in), point for
        // point, the part that shows growing as it comes.
        guard t.mode == .pull, let s = motion.edges[id], s.kind == nil else { return }
        let inward = Double(split(v.translation, tab.edge).inward - Self.decideDistance)
        motion.holdEdge(id, path: s.path, p: s.path.progress(inward: inward, from: t.start))
    }

    private func stripEnded(_ id: String, tab: WorkspaceFloatGeometry.TuckTab, _ v: DragGesture.Value) {
        guard let t = handleTouches[id] else { return }
        switch t.mode {
        case .peek:
            handleTouches[id] = nil
            restore(id)   // a tap, or a touch that only peeked: it comes out
        case .away:
            handleTouches[id] = nil   // pushed back into its edge: it stays tucked
        case .slide:
            let alongY = tab.edge.axis == .horizontal
            let centre = alongY ? tab.float.midY + Double(v.translation.height) : tab.float.midX + Double(v.translation.width)
            let offset = alongY ? (centre - Double(picture.minY)) / max(Double(picture.height), 1)
                                : (centre - Double(picture.minX)) / max(Double(picture.width), 1)
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.86)) {
                handleTouches[id] = nil
                model.moveTuckTab(id, offset: offset)
            }
        case .pull:
            handleTouches[id] = nil
            guard let s = motion.edges[id], s.kind == nil else { return }
            let speed = velocity(t.samples)
            let inward = Double(split(CGSize(width: speed.x, height: speed.y), tab.edge).inward)
            let travel = s.path.travel
            let rate = travel > 1 ? inward / travel : 0
            if WorkspaceFloatMotion.pullRestores(progress: s.p, inwardVelocity: inward, travel: travel) {
                restore(id, velocity: rate)
            } else {
                pullFellShort(id, velocity: rate)
            }
        }
    }

    // MARK: First-use tip

    private var placementTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(floatAccent).accessibilityHidden(true)
            Text("Tip: while you drag a window, draw a circle with it (about a second) to switch between a pane and a floating window. A ring shows how close it is.")
                .font(.footnote).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Button { model.dismissPlacementTip() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Dismiss Tip"))
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(floatChip))
        .frame(maxWidth: min(picture.width - 32, 440))
        .position(x: picture.midX, y: max(picture.minY, safeArea?.minY ?? 0) + 44)
        .transition(.opacity)
        .accessibilityIdentifier("placementTip")
    }

    private func hideTipSoon() {
        tipHide?.cancel()
        tipHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { model.dismissPlacementTip() }
        }
    }

    /// No samples come while the finger rests: the ring goes once the circling has gone quiet.
    private func fadeRingWhenQuiet() {
        ringFade?.cancel()
        let wait = (model.floatMove?.circling.quiet ?? 0) + 0.05
        ringFade = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, model.floatMove?.circling.isQuiet(at: Date().timeIntervalSinceReferenceDate) ?? true else { return }
            ring = nil
        }
    }

    /// The float being docked, folded into a card above the finger: its last picture shrinks
    /// into the card as it folds, then its icon and title. Drawn only here; the Mac leaves the
    /// float out while it's lifted.
    private func dockCard(_ c: DockCard) -> some View {
        let w = min(max(picture.width * 0.42, 150), 230), h: CGFloat = 46
        let target = CGRect(x: finger.x - w / 2, y: finger.y - h - 22, width: w, height: h)
        let r = c.collapsed ? target : c.from
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.13, opacity: 0.95))
            if let image = model.backdrop(c.id)?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: r.width, height: r.height).clipped()
                    .opacity(c.collapsed ? 0 : 1)
            }
            HStack(spacing: 8) {
                if let icon = icon(c.id) {
                    Image(decorative: icon, scale: 1).resizable().interpolation(.high).frame(width: 24, height: 24)
                } else {
                    Image(systemName: "macwindow").foregroundStyle(.white)
                }
                Text(title(c.id)).font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .opacity(c.collapsed ? 1 : 0)
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Haptics

    private enum Haptic { case toggle, drop }

    private static func haptic(_ h: Haptic) {
        switch h {
        case .toggle: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        case .drop: UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
        }
    }
}

/// VoiceOver and Switch Control: everything the gestures do, as actions.
private struct FloatAccessibilityActions: ViewModifier {
    let model: WorkspaceModel
    let id: String
    let front: Bool
    /// Tucks it into that edge as the menu does (its strip, the slide in, the announcement).
    let tuck: (WorkspaceEdge) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Bring to Front")) { model.raiseFloat(id); model.focus(id, raise: false) }
            .accessibilityAction(named: Text("Move Left")) { model.nudgeFloat(id, dx: -0.1, dy: 0) }
            .accessibilityAction(named: Text("Move Right")) { model.nudgeFloat(id, dx: 0.1, dy: 0) }
            .accessibilityAction(named: Text("Move Up")) { model.nudgeFloat(id, dx: 0, dy: -0.1) }
            .accessibilityAction(named: Text("Move Down")) { model.nudgeFloat(id, dx: 0, dy: 0.1) }
            .accessibilityAction(named: Text("Make Larger")) { model.scaleFloat(id, by: 1.15) }
            .accessibilityAction(named: Text("Make Smaller")) { model.scaleFloat(id, by: 0.87) }
            .accessibilityAction(named: Text("Tuck to Left Edge")) { tuck(.left) }
            .accessibilityAction(named: Text("Tuck to Right Edge")) { tuck(.right) }
            .accessibilityAction(named: Text("Tuck to Top Edge")) { tuck(.top) }
            .accessibilityAction(named: Text("Tuck to Bottom Edge")) { tuck(.bottom) }
            .accessibilityAction(named: Text("Add to Layout")) { model.addFloatToLayout(id) }
            .accessibilityAction(named: Text("Fullscreen on This Device")) { model.toggleLocalFullscreen(id) }
            .accessibilityAction(named: Text("Remove from This Device")) { model.removeFloat(id) }
    }
}

/// A float handle's touch area, or none (`on` false) while the float is being docked: the handle
/// stays so the move on it goes on, but a new touch there reaches what's under it.
private struct FloatTouchArea: Shape {
    var on: Bool
    func path(in rect: CGRect) -> Path { on ? Path(rect) : Path() }
}

/// A quarter arc just outside a lower corner of the float.
private struct FloatGripArc: Shape {
    let leading: Bool
    func path(in rect: CGRect) -> Path {
        // The float's corner is 6 pt in from this frame's centre, up and toward the window.
        let corner = CGPoint(x: rect.midX + (leading ? 6 : -6), y: rect.midY - 6)
        let centre = CGPoint(x: corner.x + (leading ? floatCorner : -floatCorner), y: corner.y - floatCorner)
        let radius = floatCorner + 8
        var p = Path()
        if leading {
            p.addArc(center: centre, radius: radius, startAngle: .degrees(98), endAngle: .degrees(172), clockwise: false)
        } else {
            p.addArc(center: centre, radius: radius, startAngle: .degrees(8), endAngle: .degrees(82), clockwise: false)
        }
        return p
    }
}

/// A handle rounded on the side facing the picture, square against its edge.
private struct EdgeTabShape: Shape {
    let edge: WorkspaceEdge
    func path(in rect: CGRect) -> Path {
        let r = min(10, rect.width / 2, rect.height / 2)
        let corners: (tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat)
        switch edge {
        case .left: corners = (0, r, r, 0)
        case .right: corners = (r, 0, 0, r)
        case .top: corners = (0, 0, r, r)
        case .bottom: corners = (r, r, 0, 0)
        }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + corners.tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - corners.tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - corners.tr, y: rect.minY + corners.tr), radius: corners.tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corners.br))
        p.addArc(center: CGPoint(x: rect.maxX - corners.br, y: rect.maxY - corners.br), radius: corners.br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + corners.bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + corners.bl, y: rect.maxY - corners.bl), radius: corners.bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corners.tl))
        p.addArc(center: CGPoint(x: rect.minX + corners.tl, y: rect.minY + corners.tl), radius: corners.tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The pointer over a corner grip: lifts it (iPadOS has no public resize pointer shape for SwiftUI).
private struct FloatResizePointer: ViewModifier {
    let leading: Bool
    func body(content: Content) -> some View {
        content.hoverEffect(.lift)
    }
}
#endif

/// A float drawn on this device from its whole-window still, in the float's own view (Fit with
/// bars, Fill, zoom, any rotation) exactly as the Mac composes it at this size: while a finger
/// moves or resizes it the Mac leaves it out (`floatLift`), so this is the only copy on screen.
private struct FloatStill: View {
    var image: CGImage
    var view: TileContentTransform
    var size: CGSize
    var corner: CGFloat

    var body: some View {
        let box = view.contentRect, s = view.scale
        ZStack(alignment: .topLeading) {
            // The Mac's letterbox colour (WorkspaceCompositor).
            Color(red: 0.07, green: 0.07, blue: 0.08)
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                .frame(width: max(view.source.width * s, 1), height: max(view.source.height * s, 1))
                .rotationEffect(.degrees(Double(view.rotation.rawValue)))
                .position(x: box.midX, y: box.midY)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
