import SwiftUI
#if os(iOS)
import QuartzCore
import UIKit

// Floating panes' chrome on iPhone and iPad (PROTOCOL.md 6.10, WINDOW_MODE.md): the outline,
// the title pill on the top edge, the bottom grabber, the curved corner grips, edge handles for
// tucked floats and the first-use circling tip. The Mac draws the floats' windows into the picture;
// everything here is the receiver's own: moving, flinging, tucking and resizing never send
// pointer input or a window action, only the arrangement (`workspaceRequest`).

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

/// Glides a released float to where it settles (or off to the edge it was flung at) with a
/// critically damped spring that starts at the finger's velocity. A new touch catches it.
@MainActor
final class WorkspaceFloatMotionDriver: NSObject, ObservableObject {
    private struct Glide {
        var from: WorkspaceRect
        var to: WorkspaceRect
        /// Picture shares per second.
        var vx: Double
        var vy: Double
        var start: CFTimeInterval
        var tucking: Bool
    }

    /// Where a float is drawn while a finger or a glide moves it (picture shares, unclamped).
    @Published private(set) var frames: [String: WorkspaceRect] = [:]
    /// Floats sliding into an edge: already tucked in the model, drawn as a picture only.
    @Published private(set) var leaving: Set<String> = []
    weak var model: WorkspaceModel?
    private var glides: [String: Glide] = [:]
    private var link: CADisplayLink?
    static let duration: CFTimeInterval = 0.7

    func drag(_ id: String, _ frame: WorkspaceRect) { frames[id] = frame }
    func drop(_ id: String) { frames[id] = nil; leaving.remove(id); glides[id] = nil; stopIfIdle() }
    func isGliding(_ id: String) -> Bool { glides[id] != nil }

    /// Stops a settling glide under a new touch and returns where it was (nil: nothing to catch).
    func catchFloat(_ id: String) -> WorkspaceRect? {
        guard let g = glides[id], !g.tucking else { return nil }
        glides[id] = nil
        let f = current(g, at: CACurrentMediaTime())
        frames[id] = f
        stopIfIdle()
        return f
    }

    func glide(_ id: String, from: WorkspaceRect, to: WorkspaceRect, velocity: (x: Double, y: Double), tucking: Bool) {
        glides[id] = Glide(from: from, to: to, vx: velocity.x, vy: velocity.y, start: CACurrentMediaTime(), tucking: tucking)
        frames[id] = from
        if tucking { leaving.insert(id) }
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
                leaving.remove(id)
                if !g.tucking { model?.endFloatGesture(id, frame: g.to) }
            } else {
                let f = current(g, at: now)
                frames[id] = f
                if !g.tucking { model?.updateFloatFrame(id, f) }   // the Mac follows (throttled)
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

/// The floats over the tiled panes, back to front, and the edge handles of tucked ones.
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
    @State private var handleDrag: [String: CGSize] = [:]
    @State private var tipHide: Task<Void, Never>?
    @GestureState private var pressing: Set<String> = []

    private struct Sample { var point: CGPoint; var time: TimeInterval }
    private struct Ring { var at: CGPoint; var progress: Double; var toFloating: Bool }
    private struct DockCard { var id: String; var from: CGRect; var collapsed: Bool }

    private var highContrast: Bool { contrast == .increased }
    private var pictureSize: WorkspaceSize { WorkspaceSize(width: max(picture.width, 1), height: max(picture.height, 1)) }
    /// Local workspace coordinates to global (drags share global coordinates with Stage Peek).
    private var toGlobal: CGPoint {
        CGPoint(x: model.pictureGlobal.minX - picture.minX, y: model.pictureGlobal.minY - picture.minY)
    }

    var body: some View {
        let frames = model.frames
        let handles = model.localFullscreen == nil ? tuckTabs() : []
        // Where each float is drawn now, and what the floats in front of it cover: its chrome
        // steps aside there (the front float's window is in the video, under all the chrome).
        // A float being docked is drawn only as its card under the finger. Its chrome stays,
        // drawing nothing (its move lives on its title or grabber), so it covers nothing.
        let docking = model.dockingFloat
        let shown = frames.floats.compactMap { id in (motion.frames[id] ?? frames.tiles[id]).map { (id: id, rect: $0.screen(in: picture)) } }
        let covers = WorkspaceFloatLayering.covers(backToFront: shown.map { WorkspaceRect($0.id == docking ? .zero : $0.rect) })
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(motion.leaving).sorted(), id: \.self) { id in
                if let f = motion.frames[id] { leavingGhost(id, f.screen(in: picture)) }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
                floatChrome(f.id, rect: f.rect, front: i == shown.count - 1, covers: covers[i].map(\.cgRect))
            }
            ForEach(handles, id: \.key) { h in handle(h.tab, edge: h.edge) }
            if let c = card, model.dockingFloat == c.id { dockCard(c) }
            if let r = ring, r.progress > 0 {
                WorkspacePlacementRing(progress: r.progress, toFloating: r.toFloating)
                    .position(x: r.at.x, y: r.at.y - WorkspacePlacementRing.lift)
            }
            if model.placementTipVisible { placementTip }
        }
        .onAppear { motion.model = model; publishHandles(handles) }
        .onChange(of: handles.map(\.tab.rect)) { _ in publishHandles(handles) }
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
        // drawing it a moment behind, so the still goes with the finger as before.
        let drawnHere = model.drawsFloatHere(id) || (moved && !model.canLiftFloats)
        ZStack {
            if !docked {
                Group {
                    if drawnHere, let image = model.backdrop(id)?.image,
                       let view = model.floatContentTransform(id, width: rect.width, height: rect.height) {
                        FloatStill(image: image, view: view, size: rect.size, corner: floatCorner)
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
        .modifier(FloatAccessibilityActions(model: model, id: id, front: front))
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
            .accessibilityHint(Text("Drag to move. Fling toward the left or right edge to tuck it away."))
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

    private func leavingGhost(_ id: String, _ rect: CGRect) -> some View {
        ZStack {
            if let image = model.backdrop(id)?.image,
               let view = model.floatContentTransform(id, width: rect.width, height: rect.height) {
                FloatStill(image: image, view: view, size: rect.size, corner: floatCorner)
            }
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                // Up and down it stays reachable; sideways it may be pulled past an edge (to tuck it).
                let bar = WorkspaceFloatGeometry.barHeight / max(picture.height, 1)
                f.y = min(max(f.y, bar), 1 - min(f.height, 1) * 0.25)
                motion.drag(id, f)
                model.updateFloatFrame(id, f)
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
                release(id, frame: motion.frames[id] ?? model.layout.float(id)?.frame ?? .unit, velocity: velocity(list))
            }
    }

    /// Picture points per second over the last ~80 ms of the drag.
    private func velocity(_ list: [Sample]) -> (x: Double, y: Double) {
        guard let last = list.last, let first = list.first(where: { last.time - $0.time <= 0.08 }) else { return (0, 0) }
        let dt = last.time - first.time
        guard dt > 0.008 else { return (0, 0) }
        return ((last.point.x - first.point.x) / dt, (last.point.y - first.point.y) / dt)
    }

    /// Stays, glides on, or tucks into the edge it was flung at (`WorkspaceFloatMotion.decide`).
    private func release(_ id: String, frame: WorkspaceRect, velocity: (x: Double, y: Double)) {
        let size = pictureSize
        let shares = (x: velocity.x / size.width, y: velocity.y / size.height)
        switch WorkspaceFloatMotion.decide(release: frame, velocity: velocity, in: size) {
        case .settle(let target, let glide):
            if glide, !reduceMotion {
                motion.glide(id, from: frame, to: target, velocity: shares, tucking: false)
            } else {
                motion.drop(id)
                model.endFloatGesture(id, frame: target)
            }
        case .tuck(let edge, let offset):
            model.endFloatGesture(id)
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : nil) { model.tuckFloat(id, edge: edge, offset: offset) }
            if reduceMotion { motion.drop(id) }
            else { motion.glide(id, from: frame, to: WorkspaceFloatMotion.hiddenFrame(frame, edge: edge), velocity: shares, tucking: true) }
            Self.haptic(.drop)
            UIAccessibility.post(notification: .announcement, argument: String(localized: "\(title(id)) tucked at the \(edge == .left ? String(localized: "left") : String(localized: "right")) edge"))
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
        let offset = model.layout.float(id)?.frame.midY ?? 0.5
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.25)) { model.tuckFloat(id, edge: edge, offset: offset) }
    }

    // MARK: Tucked floats

    private struct Handle { var key: String; var tab: WorkspaceFloatGeometry.TuckTab; var edge: WorkspaceEdge }

    private func tuckTabs() -> [Handle] {
        let area = (safeArea.map { $0.intersection(picture) } ?? picture)
        guard area.width > 0, area.height > 0 else { return [] }
        let rect = WorkspaceRect(x: area.minX, y: area.minY, width: area.width, height: area.height)
        var out: [Handle] = []
        for edge in [WorkspaceEdge.left, .right] {
            let items = model.layout.floats.compactMap { f -> (id: String, offset: Double)? in
                guard let t = f.tuck, t.edge == edge else { return nil }
                return (f.tile, t.offset)
            }
            guard !items.isEmpty else { continue }
            for t in WorkspaceFloatGeometry.tuckTabs(items, edge: edge, area: rect) {
                out.append(Handle(key: "\(edge)-" + t.ids.joined(separator: ","), tab: t, edge: edge))
            }
        }
        return out
    }

    private func publishHandles(_ handles: [Handle]) {
        let o = toGlobal
        let rects = handles.map { CGRect(x: $0.tab.rect.x + o.x, y: $0.tab.rect.y + o.y, width: $0.tab.rect.width, height: $0.tab.rect.height) }
        if model.floatHandlesGlobal != rects { model.floatHandlesGlobal = rects }
    }

    /// A tab on the edge: tap (or pull inward) to bring the float back; slide it along the edge.
    /// Several on one edge that don't fit collapse into one stack with a menu.
    @ViewBuilder
    private func handle(_ tab: WorkspaceFloatGeometry.TuckTab, edge: WorkspaceEdge) -> some View {
        let r = CGRect(x: tab.rect.x, y: tab.rect.y, width: tab.rect.width, height: tab.rect.height)
        let left = edge == .left
        let drag = tab.ids.count == 1 ? handleDrag[tab.ids[0]] ?? .zero : .zero
        let face = ZStack {
            UnevenRoundedShape(left: left)
                .fill(floatChip)
                .overlay(UnevenRoundedShape(left: left).stroke(Color.white.opacity(highContrast ? 0.7 : 0.3), lineWidth: 1))
            VStack(spacing: 4) {
                if tab.isStack {
                    Text("\(tab.ids.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                } else if let icon = tab.ids.first.flatMap(icon) {
                    Image(decorative: icon, scale: 1).resizable().frame(width: 18, height: 18)
                }
                Image(systemName: left ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: r.width, height: r.height)
        .frame(width: 44, height: max(r.height, 44), alignment: left ? .leading : .trailing)
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)

        Group {
            if tab.isStack {
                face
                    .accessibilityHidden(true)
                    .overlay(WorkspaceStableMenuButton(symbol: nil, accessibilityLabel: String(localized: "\(tab.ids.count) tucked floating windows"),
                                                       accessibilityIdentifier: "floatTuckHandle") {
                        tab.ids.map { id in UIAction(title: title(id)) { _ in untuck(id) } }
                    })
            } else if let id = tab.ids.first {
                face
                    .offset(x: left ? max(0, min(drag.width, 40)) : min(0, max(drag.width, -40)), y: drag.height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
                        .onChanged { v in handleDrag[id] = v.translation }
                        .onEnded { v in
                            handleDrag[id] = nil
                            let inward = left ? v.translation.width : -v.translation.width
                            if hypot(v.translation.width, v.translation.height) < 8 || inward > 36 { untuck(id); return }
                            let area = (safeArea.map { $0.intersection(picture) } ?? picture)
                            model.moveTuckTab(id, offset: (r.midY + v.translation.height - area.minY) / max(area.height, 1))
                        })
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(title(id)), tucked at the \(left ? String(localized: "left") : String(localized: "right")) edge"))
                    .accessibilityHint(Text("Shows the floating window again."))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { untuck(id) }
                    .accessibilityAction(named: Text("Remove from This Device")) { model.removeFloat(id) }
            }
        }
        .accessibilityIdentifier("floatTuckHandle")
        .position(x: left ? r.minX + 22 : r.maxX - 22, y: r.midY)
    }

    private func untuck(_ id: String) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.86)) { model.untuckFloat(id) }
        Self.haptic(.drop)
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

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Bring to Front")) { model.raiseFloat(id); model.focus(id, raise: false) }
            .accessibilityAction(named: Text("Move Left")) { model.nudgeFloat(id, dx: -0.1, dy: 0) }
            .accessibilityAction(named: Text("Move Right")) { model.nudgeFloat(id, dx: 0.1, dy: 0) }
            .accessibilityAction(named: Text("Move Up")) { model.nudgeFloat(id, dx: 0, dy: -0.1) }
            .accessibilityAction(named: Text("Move Down")) { model.nudgeFloat(id, dx: 0, dy: 0.1) }
            .accessibilityAction(named: Text("Make Larger")) { model.scaleFloat(id, by: 1.15) }
            .accessibilityAction(named: Text("Make Smaller")) { model.scaleFloat(id, by: 0.87) }
            .accessibilityAction(named: Text("Tuck to Left Edge")) { model.tuckFloat(id, edge: .left, offset: model.layout.float(id)?.frame.midY ?? 0.5) }
            .accessibilityAction(named: Text("Tuck to Right Edge")) { model.tuckFloat(id, edge: .right, offset: model.layout.float(id)?.frame.midY ?? 0.5) }
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

/// A tab rounded on the side facing the picture, square against the screen edge.
private struct UnevenRoundedShape: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 10
        var p = Path()
        if left {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
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
