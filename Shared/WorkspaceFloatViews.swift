import SwiftUI
#if os(iOS)
import QuartzCore
import UIKit

// Floating panes' chrome on iPhone and iPad (PROTOCOL.md 6.10, WINDOW_MODE.md): the outline,
// the title pill on the top edge, the bottom grabber, the curved corner grips, the slivers of
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

/// Glides a released float to where it settles, off into the edge it was thrown at, back into its
/// edge after a pull that fell short, or back out of its edge when it's restored, with a
/// critically damped spring that starts at the finger's velocity. A new touch catches a float
/// that is settling or coming back.
@MainActor
final class WorkspaceFloatMotionDriver: NSObject, ObservableObject {
    /// What a glide is for.
    enum Kind: Equatable {
        /// A shown float settling where it was let go (the Mac follows; it lands at the end).
        case settle
        /// A float just tucked, sliding into its edge: a picture only (it's tucked already).
        case tucking
        /// A tucked float pulled part way out and let go: a picture sliding back into its edge.
        case returning
        /// A float coming back out of its edge: shown again (lifted where the Mac can), drawn
        /// here while it slides; it lands at the end.
        case restoring
    }

    private struct Glide {
        var from: WorkspaceRect
        var to: WorkspaceRect
        /// Picture shares per second.
        var vx: Double
        var vy: Double
        var start: CFTimeInterval
        var kind: Kind
    }

    /// Where a float is drawn while a finger or a glide moves it (picture shares, unclamped).
    @Published private(set) var frames: [String: WorkspaceRect] = [:]
    /// Tucked floats drawn as a picture only: sliding into an edge, pulled out of it by a finger,
    /// or sliding back in.
    @Published private(set) var ghosts: Set<String> = []
    weak var model: WorkspaceModel?
    private var glides: [String: Glide] = [:]
    private var link: CADisplayLink?
    static let duration: CFTimeInterval = 0.7

    func drag(_ id: String, _ frame: WorkspaceRect) { frames[id] = frame }
    /// A tucked float pulled out of its edge under a finger (a picture, until it's let go).
    func pull(_ id: String, _ frame: WorkspaceRect) {
        glides[id] = nil
        frames[id] = frame
        ghosts.insert(id)
        stopIfIdle()
    }
    func drop(_ id: String) { frames[id] = nil; ghosts.remove(id); glides[id] = nil; stopIfIdle() }
    func isGliding(_ id: String) -> Bool { glides[id] != nil }

    /// Stops a settling (or restoring) glide under a new touch and returns where it was (nil:
    /// nothing to catch). A float sliding into its edge is tucked already: it isn't caught.
    func catchFloat(_ id: String) -> WorkspaceRect? {
        guard let g = glides[id], g.kind == .settle || g.kind == .restoring else { return nil }
        glides[id] = nil
        let f = current(g, at: CACurrentMediaTime())
        frames[id] = f
        stopIfIdle()
        return f
    }

    func glide(_ id: String, from: WorkspaceRect, to: WorkspaceRect, velocity: (x: Double, y: Double), kind: Kind) {
        glides[id] = Glide(from: from, to: to, vx: velocity.x, vy: velocity.y, start: CACurrentMediaTime(), kind: kind)
        frames[id] = from
        if kind == .tucking || kind == .returning { ghosts.insert(id) } else { ghosts.remove(id) }
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
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
                ghosts.remove(id)
                switch g.kind {
                case .settle: model?.endFloatGesture(id, frame: g.to)
                case .restoring: model?.endFloatGesture(id)   // back where it was: lands
                case .tucking, .returning: break
                }
            } else {
                let f = current(g, at: now)
                frames[id] = f
                if g.kind == .settle { model?.updateFloatFrame(id, f) }   // the Mac follows (throttled)
            }
        }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard glides.isEmpty else { return }
        link?.invalidate()
        link = nil
    }
}

/// The floats over the tiled panes, back to front, and the slivers of tucked ones at the edges.
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
    /// A float's title circled during a move: now docking it (the pane drop targets show, and the
    /// float is drawn as a card under the finger).
    @State private var docking: String?
    @State private var circling = WorkspaceCircleGesture()
    /// Circling toward the other placement: where the finger is and how far along.
    @State private var ring: Ring?
    /// The float folded into a card while it's being docked.
    @State private var card: DockCard?
    @State private var finger: CGPoint = .zero
    @State private var ringFade: Task<Void, Never>?
    @State private var resizeStart: [String: WorkspaceRect] = [:]
    /// Fingers on tucked floats' slivers, by float.
    @State private var handleTouches: [String: HandleTouch] = [:]
    @GestureState private var handlesHeld: Set<String> = []
    @State private var tipHide: Task<Void, Never>?
    @GestureState private var pressing: Set<String> = []

    private struct Sample { var point: CGPoint; var time: TimeInterval }
    private struct Ring { var at: CGPoint; var progress: Double; var toFloating: Bool }
    private struct DockCard { var id: String; var from: CGRect; var collapsed: Bool }

    /// A finger on a sliver: peeking until it moves, then pulling the float out (inward), sliding
    /// the handle along its edge, or pushing it back (outward: nothing happens).
    private struct HandleTouch {
        enum Mode { case peek, pull, slide, away }
        var mode = Mode.peek
        var translation = CGSize.zero
        var samples: [Sample] = []
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
        // A float being docked is drawn only as its card under the finger.
        let shown = frames.floats.filter { $0 != docking }.compactMap { id in (motion.frames[id] ?? frames.tiles[id]).map { (id: id, rect: $0.screen(in: picture)) } }
        let covers = WorkspaceFloatLayering.covers(backToFront: shown.map { WorkspaceRect($0.rect) })
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(motion.ghosts).sorted(), id: \.self) { id in
                if let f = motion.frames[id] { ghost(id, f.screen(in: picture)) }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
                floatChrome(f.id, rect: f.rect, front: i == shown.count - 1, covers: covers[i].map(\.cgRect))
            }
            armedEdges
            // Tucked floats' slivers, together for VoiceOver, in reading order around the edges.
            ZStack(alignment: .topLeading) {
                ForEach(Array(handles.enumerated()), id: \.element.key) { i, h in
                    handle(h.tab).accessibilitySortPriority(Double(handles.count - i))
                }
            }
            .accessibilityElement(children: .contain)
            if let c = card, docking == c.id { dockCard(c) }
            if let r = ring, r.progress > 0 {
                WorkspacePlacementRing(progress: r.progress, toFloating: r.toFloating)
                    .position(x: r.at.x, y: r.at.y - WorkspacePlacementRing.lift)
            }
            if model.placementTipVisible { placementTip }
        }
        .onAppear { motion.model = model; publishHandles(handles) }
        .onChange(of: handles.map(\.tab.rect)) { _ in publishHandles(handles) }
        .onChange(of: handlesHeld) { held in
            // A touch on a sliver the system cancelled (no end event): a pull goes back in.
            for id in handleTouches.keys where !held.contains(id) {
                guard let t = handleTouches.removeValue(forKey: id), t.mode == .pull else { continue }
                pullFellShort(id, velocity: (0, 0))
            }
        }
        .onChange(of: model.drag == nil) { ended in if ended, model.placementTipVisible { hideTipSoon() } }
        .onChange(of: pressing) { held in
            // A move the system cancelled (no end event): settle where it is.
            for id in start.keys where !held.contains(id) {
                let f = motion.frames[id]
                start[id] = nil; moving.remove(id); samples[id] = nil
                if docking == id { docking = nil; card = nil; model.cancelDrag() }
                ring = nil
                if !motion.isGliding(id) { motion.drop(id); model.endFloatGesture(id, frame: f) }
            }
        }
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
        let moved = motion.frames[id] != nil || resizeStart[id] != nil
        let outline = active ? floatAccent : Color.white.opacity(highContrast ? 0.75 : 0.3)
        let coverRects = covers.map(WorkspaceRect.init)
        let covered: (CGRect) -> Bool = { WorkspaceFloatLayering.isCovered(WorkspaceRect($0), by: coverRects) }
        let handles = WorkspaceFloatLayering.showsHandles(selected: active, hovered: model.hovered == id, manipulating: moved)
        // While a finger moves or resizes it the Mac leaves it out (`floatLift`) and it's drawn
        // here, from its last still, in its own view at this size. A Mac without lift keeps
        // drawing it (inside the picture): only its picture shows then, never a second copy.
        let drawnHere = model.drawsFloatHere(id)
        ZStack {
            if drawnHere, let image = model.backdrop(id)?.image,
               let view = model.floatContentTransform(id, width: rect.width, height: rect.height) {
                FloatStill(image: image, view: view, size: rect.size, corner: floatCorner)
            } else if model.drawsFloatHere(id) {
                // Coming back out of its edge without a still of its own (the Mac leaves it out
                // meanwhile): Stage Peek's still of the window, else its icon.
                floatPicture(id, size: rect.size, corner: floatCorner)
            }
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                .strokeBorder(Color.black.opacity(highContrast ? 0.8 : 0.45), lineWidth: active ? 3.5 : 2.5)
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                .strokeBorder(outline, lineWidth: active ? 2 : 1)
        }
        .frame(width: rect.width, height: rect.height)
        .mask(WorkspaceHoleMask(size: rect.size, holes: covers.map { $0.offsetBy(dx: -rect.minX, dy: -rect.minY) }))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("\(title(id)), floating window"))
        .accessibilityIdentifier("workspaceFloat")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction { model.raiseFloat(id); model.focus(id, raise: false) }   // selects it here only
        .modifier(FloatAccessibilityActions(model: model, id: id, front: front))

        if !covered(WorkspaceFloatLayering.pillBounds(WorkspaceRect(rect)).cgRect) {
            titlePill(id, rect: rect, active: active, outline: outline)
        }
        if handles {
            if !covered(CGRect(x: rect.midX - 38, y: rect.maxY - 4, width: 76, height: 28)) { grabber(id, rect: rect, active: active) }
            if !covered(CGRect(x: rect.minX - 28, y: rect.maxY - 16, width: 44, height: 44)) { grip(id, rect: rect, corner: .bottomLeading, active: active) }
            if !covered(CGRect(x: rect.maxX - 16, y: rect.maxY - 16, width: 44, height: 44)) { grip(id, rect: rect, corner: .bottomTrailing, active: active) }
        }
        let middle = CGRect(x: rect.midX - 60, y: rect.midY - 24, width: 120, height: 48)
        if model.tileState(id)?.status == .offscreen, !moved, !covered(middle) { offscreenNotice(id, rect: rect) }
        else if active, model.remote?.hostFocus.isMismatch == true, !moved,
                !covered(CGRect(x: rect.midX - 60, y: rect.maxY - 54, width: 120, height: 40)) { typingPaused(id, rect: rect) }
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
    private func titlePill(_ id: String, rect: CGRect, active: Bool, outline: Color) -> some View {
        let maxWidth = max(min(rect.width - 28, 280), 90)
        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                if let icon = icon(id) { Image(decorative: icon, scale: 1).resizable().frame(width: 14, height: 14) }
                Text(title(id)).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Color.white.opacity(active ? 1 : 0.8))
                    .frame(maxWidth: max(maxWidth - 64, 40))
            }
            .padding(.leading, 10)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
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
        }
        .fixedSize()
        .background(Capsule().fill(floatChip))
        .overlay(Capsule().strokeBorder(outline, lineWidth: active ? 2 : 1).allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .position(x: rect.midX, y: rect.minY)
    }

    /// A short bar under the window: the same move as the title.
    private func grabber(_ id: String, rect: CGRect, active: Bool) -> some View {
        let below = rect.maxY + 12 <= picture.maxY - 4
        return Capsule().fill(Color.white.opacity(active ? 0.9 : 0.55))
            .overlay(Capsule().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
            .frame(width: 40, height: 5)
            .frame(width: 76, height: 28)
            .contentShape(Rectangle())
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

    /// A tucked float as a picture only: sliding into its edge, pulled out of it, sliding back.
    private func ghost(_ id: String, _ rect: CGRect) -> some View {
        ZStack {
            floatPicture(id, size: rect.size, corner: floatCorner)
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
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
                    model.beginFloatGesture(id)
                    samples[id] = []
                    circling.reset()
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
                // About two seconds of circling while held: switch between moving it and docking
                // it into the layout. A ring above the finger fills as it goes.
                let switched = circling.add(x: v.location.x, y: v.location.y, at: v.time.timeIntervalSinceReferenceDate)
                ring = circling.progress > 0 ? Ring(at: v.location, progress: circling.progress, toFloating: docking == id) : nil
                if ring != nil { fadeRingWhenQuiet() }
                if switched {
                    if docking == id {
                        // Back to moving it: the card opens into the float under the finger.
                        docking = nil
                        card = nil
                        model.cancelDrag()
                        model.liftFloat(id)
                    } else {
                        // Docking: the float folds into a card under the finger. It stays lifted (the
                        // Mac doesn't draw it), so it's on screen once, as the card; a cancelled drop
                        // puts it back where the move began.
                        let from = (motion.frames[id] ?? model.layout.float(id)?.frame)?.screen(in: picture)
                        docking = id
                        motion.drop(id)
                        model.updateFloatFrame(id, s)
                        model.liftFloat(id)
                        model.beginDrag(.float(id), at: global)
                        card = DockCard(id: id, from: from ?? CGRect(x: v.location.x - 80, y: v.location.y - 50, width: 160, height: 100), collapsed: false)
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { card?.collapsed = true }
                    }
                    ring = nil
                    Self.haptic(.toggle)
                }
                if docking == id { model.moveDrag(to: global); return }
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
                if docking == id {
                    docking = nil
                    card = nil
                    motion.drop(id)
                    model.endFloatGesture(id)
                    if model.endDrag() { Self.haptic(.drop) }
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
                motion.glide(id, from: drawn, to: target, velocity: shares, kind: .settle)
            } else {
                motion.drop(id)
                model.endFloatGesture(id, frame: target)
            }
        case .tuck(let edge, let offset):
            model.endFloatGesture(id)
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : nil) { model.tuckFloat(id, edge: edge, offset: offset) }
            // On along its throw, into the edge where its path crossed it.
            if reduceMotion { motion.drop(id) }
            else { motion.glide(id, from: drawn, to: WorkspaceFloatMotion.hiddenFrame(drawn, edge: edge, along: offset), velocity: shares, kind: .tucking) }
            tucked(id, edge)
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
        mac.append(act(String(localized: "Minimize on Mac"), "minus.rectangle", off) { model.minimizeRemoteWindow(id) })
        mac.append(act(String(localized: "Close Window on Mac…"), "xmark.square", off.union(.destructive)) { onClose(id) })
        let onMac = UIMenu(title: String(localized: "On Your Mac"), image: UIImage(systemName: "desktopcomputer"), children: mac)
        onMac.subtitle = inputAllowed ? String(localized: "Changes the real window") : String(localized: "Needs control of the Mac")

        return [placement, view, UIMenu(title: "", options: .displayInline, children: local),
                UIMenu(title: "", options: .displayInline, children: [onMac])]
    }

    private func tuck(_ id: String, _ edge: WorkspaceEdge) {
        guard let f = model.layout.float(id), f.tuck == nil else { return }
        let offset = WorkspaceFloatMotion.along(f.frame, edge)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.25)) { model.tuckFloat(id, edge: edge, offset: offset) }
        // It slides into that edge, as when it's thrown there (a fade with Reduce Motion).
        if !reduceMotion {
            motion.glide(id, from: f.frame, to: WorkspaceFloatMotion.hiddenFrame(f.frame, edge: edge), velocity: (0, 0), kind: .tucking)
        }
        tucked(id, edge)
    }

    // MARK: Tucked floats

    private struct Handle { var key: String; var tab: WorkspaceFloatGeometry.TuckTab }

    /// Where handles may sit (workspace points): the picture in the safe area, clear of the
    /// system's edge bands at the screen's top and bottom.
    private var handleArea: WorkspaceRect? {
        let screen = model.edgeReservationsGlobal.screen
        let o = toGlobal
        return WorkspaceFloatGeometry.handleArea(
            picture: WorkspaceRect(picture), safe: safeArea.map { WorkspaceRect($0) },
            screen: screen.width > 0 && screen.height > 0 ? WorkspaceRect(screen.offsetBy(dx: -o.x, dy: -o.y)) : nil)
    }

    /// The fixed controls and Stage Peek's handle (workspace points): handles give way to them.
    private var reservedHere: [WorkspaceRect] {
        let o = toGlobal
        return model.edgeReservationsGlobal.controls.map { WorkspaceRect($0.offsetBy(dx: -o.x, dy: -o.y)) }
    }

    /// The edges a float may be thrown into now (those with room for a handle).
    private var tuckEdges: Set<WorkspaceEdge> { WorkspaceFloatGeometry.tuckEdges(area: handleArea) }

    /// `handleArea` as shares of the picture: where a float's title pill must be when it comes to
    /// rest (in the safe area, clear of the system's edge bands). nil: the whole picture.
    private var restArea: WorkspaceRect? {
        guard let a = handleArea, picture.width > 0, picture.height > 0 else { return nil }
        return WorkspaceRect(x: (a.x - Double(picture.minX)) / Double(picture.width), y: (a.y - Double(picture.minY)) / Double(picture.height),
                             width: a.width / Double(picture.width), height: a.height / Double(picture.height))
    }

    /// Every handle, in reading order around the edges (left, top, right, bottom).
    private func tuckHandles() -> [Handle] {
        guard let area = handleArea else { return [] }
        return WorkspaceFloatGeometry.tuckHandles(model.layout.floats, area: area, reserved: reservedHere)
            .map { Handle(key: "\($0.edge.rawValue)-" + $0.ids.joined(separator: ","), tab: $0) }
    }

    private func publishHandles(_ handles: [Handle]) {
        let o = toGlobal
        let rects = handles.map { CGRect(x: $0.tab.rect.x + o.x, y: $0.tab.rect.y + o.y, width: $0.tab.rect.width, height: $0.tab.rect.height) }
        if model.floatHandlesGlobal != rects { model.floatHandlesGlobal = rects }
    }

    /// Where a handle is along its edge, as a share of the picture.
    private func share(_ tab: WorkspaceFloatGeometry.TuckTab) -> Double {
        tab.edge.axis == .horizontal ? (tab.rect.midY - Double(picture.minY)) / max(Double(picture.height), 1)
                                     : (tab.rect.midX - Double(picture.minX)) / max(Double(picture.width), 1)
    }

    /// Where float `id`'s handle (or the stack it's in) is along its edge, nil if it has none.
    private func handleShare(_ id: String) -> Double? {
        tuckHandles().first { $0.tab.ids.contains(id) }.map { share($0.tab) }
    }

    /// The finger's place across `edge` (a share of the picture's width for the side edges, of its
    /// height for the top and bottom).
    private func across(_ p: CGPoint, _ edge: WorkspaceEdge) -> Double {
        Double(edge.axis == .horizontal ? (p.x - picture.minX) / max(picture.width, 1) : (p.y - picture.minY) / max(picture.height, 1))
    }

    /// Brings a tucked float back where it was: it slides out of its handle (from where a pull
    /// left it, carrying the finger's speed; caught by a new touch on its title like any glide),
    /// or fades in with Reduce Motion. One haptic.
    private func restore(_ id: String, from start: WorkspaceRect? = nil, velocity: (x: Double, y: Double) = (0, 0)) {
        guard let tuck = model.layout.float(id)?.tuck else { motion.drop(id); return }
        let along = handleShare(id) ?? tuck.offset
        Self.haptic(.drop)
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                motion.drop(id)
                model.untuckFloat(id)
            }
            return
        }
        model.beginRestoringFloat(id)
        guard let target = model.layout.float(id), target.tuck == nil else { motion.drop(id); return }
        let from = start ?? WorkspaceFloatMotion.hiddenFrame(target.frame, edge: tuck.edge, along: along)
        motion.glide(id, from: from, to: target.frame,
                     velocity: (velocity.x / pictureSize.width, velocity.y / pictureSize.height), kind: .restoring)
    }

    /// A pull let go short of the restore point (or cancelled): the float slides back into its edge.
    private func pullFellShort(_ id: String, velocity: (x: Double, y: Double)) {
        guard let f = model.layout.float(id), let tuck = f.tuck, let at = motion.frames[id] else { motion.drop(id); return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { motion.drop(id) }
            return
        }
        let home = WorkspaceFloatMotion.hiddenFrame(f.frame, edge: tuck.edge, along: handleShare(id) ?? tuck.offset)
        motion.glide(id, from: at, to: home, velocity: (velocity.x / pictureSize.width, velocity.y / pictureSize.height), kind: .returning)
    }

    /// While a float is dragged more than halfway past an edge (letting go would tuck it there),
    /// that edge glows where its handle would go.
    @ViewBuilder
    private var armedEdges: some View {
        let edges = tuckEdges
        ForEach(Array(moving).sorted(), id: \.self) { id in
            if docking != id, let f = held[id] ?? motion.frames[id], let edge = WorkspaceFloatMotion.pulledEdge(f, edges: edges),
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

    /// The glow for a float at `f` armed to tuck into `edge`: along that edge, where it is.
    private func armedMark(_ f: WorkspaceRect, edge: WorkspaceEdge, area: WorkspaceRect) -> CGRect {
        let length = WorkspaceFloatGeometry.tabSize.height + 24, thick = 5.0
        let along = WorkspaceFloatMotion.along(f, edge)
        let r: WorkspaceRect
        switch edge {
        case .left, .right:
            let c = min(max(Double(picture.minY) + along * Double(picture.height), area.y + length / 2), area.maxY - length / 2)
            r = WorkspaceRect(x: edge == .left ? area.x + 1 : area.maxX - 1 - thick, y: c - length / 2, width: thick, height: length)
        case .top, .bottom:
            let c = min(max(Double(picture.minX) + along * Double(picture.width), area.x + length / 2), area.maxX - length / 2)
            r = WorkspaceRect(x: c - length / 2, y: edge == .top ? area.y + 1 : area.maxY - 1 - thick, width: length, height: thick)
        }
        return r.cgRect
    }

    // MARK: Slivers

    /// Depth of a sliver while a finger rests on it (peek): it stretches out to show more.
    private static let peekDepth: CGFloat = 60

    /// Where a handle takes touches: `touchDepth` in from its edge, at least 44 pt long.
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

    /// The side of the hidden window that still shows at its edge (the side facing the picture).
    private func innerAlignment(_ edge: WorkspaceEdge) -> Alignment {
        switch edge {
        case .left: return .trailing
        case .right: return .leading
        case .top: return .bottom
        case .bottom: return .top
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
            sliver(id, tab: tab)
        }
    }

    /// A tucked float at its edge: a slim sliver of its window (its last still, shrunk to the
    /// sliver's length, the side facing the picture showing), else its icon. Touch it and it
    /// stretches out a little (peek); pull it inward and the float comes out under the finger
    /// (let go past `WorkspaceFloatMotion.restoreProgress` and it comes back, else it slides
    /// back); tap it and the float slides back out; slide it along the edge to move it.
    private func sliver(_ id: String, tab: WorkspaceFloatGeometry.TuckTab) -> some View {
        let r = tab.rect.cgRect
        let edge = tab.edge
        let alongY = edge.axis == .horizontal
        let touch = handleTouches[id]
        let sliding = touch?.mode == .slide
        let length = alongY ? r.height : r.width
        let depth = touch != nil && !sliding ? Self.peekDepth : (alongY ? r.width : r.height)
        let size = alongY ? CGSize(width: depth, height: length) : CGSize(width: length, height: depth)
        let target = touchFrame(r, edge)
        let box = CGSize(width: alongY ? max(target.width, depth) : target.width, height: alongY ? target.height : max(target.height, depth))
        let slide = sliding ? (alongY ? CGSize(width: 0, height: touch?.translation.height ?? 0) : CGSize(width: touch?.translation.width ?? 0, height: 0)) : .zero
        let centre = anchored(box, at: r, edge)
        return sliverFace(id, edge: edge, size: size, length: length)
            .frame(width: box.width, height: box.height, alignment: edgeAlignment(edge))
            .contentShape(Rectangle())
            // While it's pulled out the float itself is under the finger: the sliver steps back.
            .opacity(touch?.mode == .pull ? 0.02 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.78), value: depth)
            .offset(slide)
            .gesture(sliverGesture(id, tab: tab))
            .hoverEffect(.highlight)
            .accessibilityElement()
            .accessibilityLabel(Text("Restore \(title(id))"))
            .accessibilityValue(Text("Tucked at the \(edgeName(edge)) edge"))
            .accessibilityHint(Text("Brings the floating window back where it was."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { restore(id) }
            .accessibilityAction(named: Text("Restore")) { restore(id) }
            .accessibilityAction(named: Text("Remove from This Device")) { model.removeFloat(id) }
            .accessibilityIdentifier("floatTuckHandle")
            .position(x: centre.x, y: centre.y)
            .transition(.opacity)
    }

    /// The sliver itself: the window's slice under a light wash, its app icon on top.
    private func sliverFace(_ id: String, edge: WorkspaceEdge, size: CGSize, length: CGFloat) -> some View {
        let alongY = edge.axis == .horizontal
        let still = stillImage(id) != nil
        // The window shrunk to the sliver's length, at its own shape.
        let aspect: CGFloat = {
            guard let f = model.layout.float(id)?.frame, f.height > 0, picture.height > 0 else { return 1.5 }
            return min(max(CGFloat(f.width) * picture.width / (CGFloat(f.height) * picture.height), 0.4), 3)
        }()
        let mini = alongY ? CGSize(width: length * aspect, height: length) : CGSize(width: length, height: length / aspect)
        return ZStack {
            EdgeTabShape(edge: edge).fill(floatChip)
            if still {
                floatPicture(id, size: mini, corner: 3)
                    .frame(width: size.width, height: size.height, alignment: innerAlignment(edge))
                    .clipShape(EdgeTabShape(edge: edge))
                EdgeTabShape(edge: edge).fill(Color.black.opacity(highContrast ? 0.4 : 0.18))
            }
            Group {
                if alongY {
                    VStack(spacing: 4) { sliverMarks(id, edge: edge, chevron: !still) }
                } else {
                    HStack(spacing: 4) { sliverMarks(id, edge: edge, chevron: !still) }
                }
            }
            EdgeTabShape(edge: edge).stroke(Color.white.opacity(highContrast ? 0.75 : 0.35), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func sliverMarks(_ id: String, edge: WorkspaceEdge, chevron: Bool) -> some View {
        if let icon = icon(id) {
            Image(decorative: icon, scale: 1).resizable().frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
        }
        if chevron {
            Image(systemName: chevronName(edge))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.85))
        }
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

    private func sliverGesture(_ id: String, tab: WorkspaceFloatGeometry.TuckTab) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
            .updating($handlesHeld) { _, held, _ in held.insert(id) }
            .onChanged { v in sliverChanged(id, tab: tab, v) }
            .onEnded { v in sliverEnded(id, tab: tab, v) }
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

    private func sliverChanged(_ id: String, tab: WorkspaceFloatGeometry.TuckTab, _ v: DragGesture.Value) {
        var t = handleTouches[id] ?? HandleTouch()
        t.translation = v.translation
        t.samples.append(Sample(point: v.location, time: v.time.timeIntervalSinceReferenceDate))
        if t.samples.count > 10 { t.samples.removeFirst(t.samples.count - 10) }
        if t.mode == .peek, hypot(v.translation.width, v.translation.height) >= 8 {
            let (inward, along) = split(v.translation, tab.edge)
            t.mode = abs(along) > abs(inward) ? .slide : (inward > 0 ? .pull : .away)
        }
        handleTouches[id] = t
        // Pulled: the float comes out of its edge with its inner side under the finger.
        guard t.mode == .pull, let f = model.layout.float(id), f.tuck != nil else { return }
        let p = WorkspaceFloatMotion.pullProgress(finger: across(v.location, tab.edge), frame: f.frame, edge: tab.edge)
        motion.pull(id, WorkspaceFloatMotion.pulledFrame(f.frame, edge: tab.edge, handle: share(tab), progress: p))
    }

    private func sliverEnded(_ id: String, tab: WorkspaceFloatGeometry.TuckTab, _ v: DragGesture.Value) {
        guard let t = handleTouches.removeValue(forKey: id) else { return }
        switch t.mode {
        case .peek:
            restore(id)   // a tap, or a touch that only peeked: it comes back
        case .away:
            break         // pushed back into its edge: it stays tucked
        case .slide:
            guard let area = handleArea else { return }
            let alongY = tab.edge.axis == .horizontal
            let centre = alongY ? tab.rect.midY + Double(v.translation.height) : tab.rect.midX + Double(v.translation.width)
            let offset = alongY ? (centre - area.y) / max(area.height, 1) : (centre - area.x) / max(area.width, 1)
            model.moveTuckTab(id, offset: offset)
        case .pull:
            guard let f = model.layout.float(id), f.tuck != nil else { motion.drop(id); return }
            let speed = velocity(t.samples)
            let inward = split(CGSize(width: speed.x, height: speed.y), tab.edge).inward
            let p = WorkspaceFloatMotion.pullProgress(finger: across(v.location, tab.edge), frame: f.frame, edge: tab.edge)
            if WorkspaceFloatMotion.pullRestores(progress: p, inwardVelocity: Double(inward),
                                                 travel: WorkspaceFloatMotion.pullTravel(f.frame, edge: tab.edge, in: pictureSize)) {
                restore(id, from: motion.frames[id], velocity: speed)
            } else {
                pullFellShort(id, velocity: speed)
            }
        }
    }

    // MARK: First-use tip

    private var placementTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(floatAccent).accessibilityHidden(true)
            Text("Tip: while you drag a window, draw circles for about two seconds to switch between a pane and a floating window. A ring shows how close it is.")
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
        let wait = circling.quiet + 0.05
        ringFade = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, circling.isQuiet(at: Date().timeIntervalSinceReferenceDate) else { return }
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

    private func tuck(_ edge: WorkspaceEdge) {
        let offset = model.layout.float(id).map { WorkspaceFloatMotion.along($0.frame, edge) } ?? 0.5
        model.tuckFloat(id, edge: edge, offset: offset)
    }
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
