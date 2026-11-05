import SwiftUI
#if os(iOS)
import QuartzCore
import UIKit

// Floating panes' chrome on iPhone and iPad (PROTOCOL.md 6.10, WINDOW_MODE.md): the outline,
// the title pill on the top edge, the bottom grabber, the curved corner grips, edge handles for
// tucked floats and the first-use shake tip. The Mac draws the floats' windows into the picture;
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
    /// A float's title shaken during a move: now docking it (the pane drop targets show).
    @State private var docking: String?
    @State private var shake = WorkspaceShakeDetector()
    @State private var resizeStart: [String: WorkspaceRect] = [:]
    @State private var handleDrag: [String: CGSize] = [:]
    @State private var tipHide: Task<Void, Never>?
    @GestureState private var pressing: Set<String> = []

    private struct Sample { var point: CGPoint; var time: TimeInterval }

    private var highContrast: Bool { contrast == .increased }
    private var pictureSize: WorkspaceSize { WorkspaceSize(width: max(picture.width, 1), height: max(picture.height, 1)) }
    /// Local workspace coordinates to global (drags share global coordinates with Stage Peek).
    private var toGlobal: CGPoint {
        CGPoint(x: model.pictureGlobal.minX - picture.minX, y: model.pictureGlobal.minY - picture.minY)
    }

    var body: some View {
        let frames = model.frames
        let handles = model.localFullscreen == nil ? tuckTabs() : []
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(motion.leaving).sorted(), id: \.self) { id in
                if let f = motion.frames[id] { leavingGhost(id, f.screen(in: picture)) }
            }
            ForEach(frames.floats, id: \.self) { id in
                if let f = motion.frames[id] ?? frames.tiles[id] {
                    floatChrome(id, rect: f.screen(in: picture), front: frames.floats.last == id)
                }
            }
            ForEach(handles, id: \.key) { h in handle(h.tab, edge: h.edge) }
            if model.shakeTipVisible { shakeTip }
        }
        .onAppear { motion.model = model; publishHandles(handles) }
        .onChange(of: handles.map(\.tab.rect)) { _ in publishHandles(handles) }
        .onChange(of: model.drag == nil) { ended in if ended, model.shakeTipVisible { hideTipSoon() } }
        .onChange(of: pressing) { held in
            // A move the system cancelled (no end event): settle where it is.
            for id in start.keys where !held.contains(id) {
                let f = motion.frames[id]
                start[id] = nil; moving.remove(id); samples[id] = nil
                if docking == id { docking = nil; model.cancelDrag() }
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

    @ViewBuilder
    private func floatChrome(_ id: String, rect: CGRect, front: Bool) -> some View {
        let active = model.active == id
        let moved = motion.frames[id] != nil || resizeStart[id] != nil
        let outline = active ? floatAccent : Color.white.opacity(highContrast ? 0.75 : 0.4)
        ZStack {
            // While it moves, the window's last picture goes with the finger (the Mac follows).
            if moved, let image = model.backdrops[id]?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: floatCorner, style: .continuous))
            }
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                .strokeBorder(Color.black.opacity(highContrast ? 0.8 : 0.45), lineWidth: active ? 3.5 : 2.5)
            RoundedRectangle(cornerRadius: floatCorner, style: .continuous)
                .strokeBorder(outline, lineWidth: active ? 2 : 1)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("\(title(id)), floating window"))
        .accessibilityIdentifier("workspaceFloat")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityAction { model.raiseFloat(id); model.focus(id) }
        .modifier(FloatAccessibilityActions(model: model, id: id, front: front))

        titlePill(id, rect: rect, active: active, outline: outline)
        grabber(id, rect: rect, active: active)
        grip(id, rect: rect, corner: .bottomLeading, active: active)
        grip(id, rect: rect, corner: .bottomTrailing, active: active)
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
            .accessibilityHint(Text("Drag to move. Fling toward the left or right edge to tuck it away."))
            .accessibilityAddTraits(.isButton)
            .hoverEffect(.highlight)
            Menu { floatMenu(id) } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Options for \(title(id))"))
            .accessibilityIdentifier("floatOptions")
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

    private func leavingGhost(_ id: String, _ rect: CGRect) -> some View {
        ZStack {
            if let image = model.backdrops[id]?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: floatCorner, style: .continuous))
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
                    model.beginFloatGesture(id)
                    samples[id] = []
                    shake.reset()
                }
                guard let s = start[id] else { return }
                var list = samples[id] ?? []
                list.append(Sample(point: v.location, time: v.time.timeIntervalSinceReferenceDate))
                if list.count > 10 { list.removeFirst(list.count - 10) }
                samples[id] = list
                if !moving.contains(id), hypot(v.translation.width, v.translation.height) < 4 { return }
                moving.insert(id)
                let global = CGPoint(x: v.location.x + toGlobal.x, y: v.location.y + toGlobal.y)
                // Shaken while held: switch between moving it and docking it into the layout.
                if shake.add(x: v.location.x, y: v.location.y, at: v.time.timeIntervalSinceReferenceDate) {
                    if docking == id {
                        docking = nil
                        model.cancelDrag()
                    } else {
                        docking = id
                        motion.drop(id)
                        model.updateFloatFrame(id, s)
                        model.beginDrag(.float(id), at: global)
                    }
                    Self.haptic(.toggle)
                }
                if docking == id { model.moveDrag(to: global); return }
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
                if docking == id {
                    docking = nil
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
                let aspect = model.windowAspect(id) ?? (s.width * picture.width) / max(s.height * picture.height, 1)
                let r = WorkspaceFloatGeometry.resized(s, corner: corner, translation: (v.translation.width, v.translation.height),
                                                       aspect: aspect, in: pictureSize)
                model.updateFloatFrame(id, r)
            }
            .onEnded { _ in
                guard resizeStart.removeValue(forKey: id) != nil else { return }
                model.endFloatGesture(id)
            }
    }

    // MARK: Options

    @ViewBuilder
    private func floatMenu(_ id: String) -> some View {
        let front = model.layout.visibleFloatIDs.last == id
        Section {
            if !front {
                Button { model.raiseFloat(id); model.focus(id) } label: { Label("Bring to Front", systemImage: "square.3.layers.3d.top.filled") }
            }
            Button { model.toggleLocalFullscreen(id) } label: {
                Label("Fullscreen on This Device", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button { model.addFloatToLayout(id) } label: { Label("Add to Layout", systemImage: "rectangle.split.2x1") }
            Button { tuck(id, .left) } label: { Label("Tuck to Left Edge", systemImage: "sidebar.left") }
            Button { tuck(id, .right) } label: { Label("Tuck to Right Edge", systemImage: "sidebar.right") }
            Menu {
                Button("Small") { model.sizeFloat(id, widthShare: picture.width < 600 ? 0.6 : 0.3) }
                Button("Medium") { model.sizeFloat(id, widthShare: picture.width < 600 ? 0.8 : 0.45) }
                Button("Large") { model.sizeFloat(id, widthShare: picture.width < 600 ? 0.95 : 0.65) }
            } label: { Label("Size", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
        }
        Section {
            Button { model.toggleFit(id) } label: {
                model.effectiveFit(id) == .fill ? Label("Show Whole Window", systemImage: "rectangle.arrowtriangle.2.inward")
                    : Label("Fill Window", systemImage: "rectangle.arrowtriangle.2.outward")
            }
            Button { model.rotate(id) } label: { Label("Rotate", systemImage: "rotate.right") }
            Button { model.resetView(id) } label: { Label("Reset View", systemImage: "arrow.counterclockwise") }
            Button { model.openOverview(replacing: id) } label: { Label("Change Window…", systemImage: "macwindow.on.rectangle") }
            Button { model.removeFloat(id) } label: { Label("Remove from This Device", systemImage: "rectangle.badge.minus") }
        }
        Section {
            Button { model.minimizeRemoteWindow(id) } label: { Label("Minimize on Mac", systemImage: "minus.rectangle") }
                .disabled(!inputAllowed)
            Button(role: .destructive) { onClose(id) } label: { Label("Close Window on Mac…", systemImage: "xmark.square") }
                .disabled(!inputAllowed)
        }
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
                Menu {
                    ForEach(tab.ids, id: \.self) { id in Button(title(id)) { untuck(id) } }
                } label: { face }
                .accessibilityLabel(Text("\(tab.ids.count) tucked floating windows"))
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

    private var shakeTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw").foregroundStyle(floatAccent).accessibilityHidden(true)
            Text("Tip: shake a window while you drag it to switch between a pane and a floating window.")
                .font(.footnote).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Button { model.dismissShakeTip() } label: {
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
        .accessibilityIdentifier("shakeTip")
    }

    private func hideTipSoon() {
        tipHide?.cancel()
        tipHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { model.dismissShakeTip() }
        }
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
            .accessibilityAction(named: Text("Bring to Front")) { model.raiseFloat(id); model.focus(id) }
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
