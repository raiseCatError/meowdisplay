import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Window mode's views for the Apple receivers (iPhone, iPad, Mac Receiver),
// drawn over the live picture. Same design and wording as Android
// (AndroidReceiver/.../workspace/WorkspaceOverlay.kt). Only pills, menus and
// (in Arrange) divider grips take touches; the rest of a tile goes to the Mac.

private let workspaceAccent = Color(red: 0.50, green: 0.70, blue: 1.0)
private let workspaceChip = Color(white: 0.11, opacity: 0.8)

private extension WorkspaceRect {
    func onScreen(_ picture: CGRect) -> CGRect {
        CGRect(x: picture.minX + x * picture.width, y: picture.minY + y * picture.height,
               width: width * picture.width, height: height * picture.height)
    }
}

extension WorkspaceRect {
    /// Points to points (the layering helpers work in picture points).
    init(_ r: CGRect) { self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// An alpha mask: opaque over `size`, with `holes` (in the masked view's own coordinates) cut out.
/// Lets an outline step aside where a float covers it without changing its shape elsewhere.
struct WorkspaceHoleMask: View {
    var size: CGSize
    var holes: [CGRect]
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black).frame(width: size.width, height: size.height)
            ForEach(holes.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.black)
                    .frame(width: max(holes[i].width, 0), height: max(holes[i].height, 0))
                    .offset(x: holes[i].minX, y: holes[i].minY)
                    .blendMode(.destinationOut)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .compositingGroup()
    }
}

/// Several rectangles as one shape (a touch area with holes cut out of it).
struct WorkspaceRectsShape: Shape {
    var rects: [CGRect]
    func path(in rect: CGRect) -> Path { Path { $0.addRects(rects) } }
}

/// Tile borders, state badges, title pills with the tile menu, drag-to-move
/// with a drop preview, and divider grips while arranging. `picture` is where
/// the Mac's picture is drawn, in this view's coordinates.
struct WorkspaceChromeView: View {
    @ObservedObject var model: WorkspaceModel
    let picture: CGRect
    /// The picture's normal fit, when it differs from where it's drawn: the
    /// on-screen keyboard can slide or zoom the picture (`picture` follows,
    /// so outlines stay on their windows), but the workspace size and hinge
    /// sent to the Mac come from this, so typing never relayouts the panes
    /// (issue #92). nil: `picture`.
    var layoutPicture: CGRect? = nil
    let inputAllowed: Bool
    /// Separating folds/hinges in this view's coordinates: nothing interactive is placed inside them.
    var divisions: [CGRect] = []
    /// The screen's safe area (clear of a notch, Dynamic Island and the home indicator) in
    /// this view's coordinates. The picture may run under them; labels and buttons don't.
    var safeArea: CGRect?
    /// The receiver's own controls (the tray or its gear, the Function Tray, the arrow keypad, the
    /// keyboard and its bar) in this view's coordinates: the drop bar and Arrange's bar sit above them.
    var controls: [CGRect] = []
    /// Opens the receiver's settings (the fullscreen strip's Settings button).
    var onSettings: (() -> Void)?
    /// "View Full Screen" on a desktop pane: back to the full-screen desktop mode.
    var onViewFullScreen: (() -> Void)?
    @State private var confirmClose: String?
    @State private var confirmStageManagerOff = false
    @State private var lastDividerTranslation: CGSize = .zero
    /// Outside Arrange: the divider held (long press) and being dragged, by index.
    @State private var heldDivider: Int?
    @State private var savingLayout = false
    @State private var layoutName = ""
    /// The floating label menu: which pane (and tab) it is for.
    @State private var menu: PaneMenuTarget?
    @State private var menuHeight: CGFloat = 340
    /// A label is held (long press recognized); drags and the menu start from it.
    @State private var heldLabel: PaneMenuTarget?
    /// While a label is held: its pane and whether its titles were folded then. They keep that
    /// form until the finger lifts (see `PaneLabelInteraction.folded`).
    @State private var heldForm: (tile: String, folded: Bool)?
    /// A label's hold is in progress (reset by SwiftUI when it ends or is cancelled).
    @GestureState private var labelPress: PaneMenuTarget?
    /// The last label tap, for telling a double tap (fullscreen toggle) from two single taps.
    @State private var lastLabelTap: PaneLabelInteraction.Tap?
    @State private var stripVisible = true
    @State private var stripHideTask: Task<Void, Never>?
    /// The pane whose tabs are all shown while the menu bar shares their row; the others show
    /// only the shown tab and "+N" (see `labelStrip`).
    @State private var tabsExpanded: String?
    @State private var tabsCollapseTask: Task<Void, Never>?
    /// Where each pane's label strip ends (workspace coordinates): the menu bar starts there.
    @State private var labelStripEnd: [String: CGFloat] = [:]
    /// Where the drag's placement chip was last drawn: the first-use tip keeps clear of it.
    @State private var placementChip: CGRect?
    @State private var arrangeBarSize: CGSize?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    typealias PaneMenuTarget = PaneLabelInteraction.Target
    /// Matches UIKit's default double-tap timing.
    static let doubleTapInterval = PaneLabelInteraction.doubleTapInterval

    private var layoutRect: CGRect { layoutPicture ?? picture }
    private var size: WorkspaceSize { WorkspaceSize(width: layoutRect.width, height: layoutRect.height) }

    private func normalized(_ p: CGPoint) -> WorkspacePoint {
        WorkspacePoint(x: (p.x - picture.minX) / max(picture.width, 1), y: (p.y - picture.minY) / max(picture.height, 1))
    }

    /// The first division that crosses the picture, as a hinge in canvas coordinates.
    private var hinge: WorkspaceHinge? {
        let picture = layoutRect
        guard picture.width > 0, picture.height > 0, let d = divisions.first?.intersection(picture), !d.isNull else { return nil }
        let r = WorkspaceRect(x: (d.minX - picture.minX) / picture.width, y: (d.minY - picture.minY) / picture.height,
                              width: d.width / picture.width, height: d.height / picture.height)
        let vertical = d.height >= d.width
        if vertical, r.x <= 0.05 || r.maxX >= 0.95 { return nil }
        if !vertical, r.y <= 0.05 || r.maxY >= 0.95 { return nil }
        return vertical ? WorkspaceHinge(rect: WorkspaceRect(x: r.x, y: 0, width: r.width, height: 1), orientation: .vertical)
                        : WorkspaceHinge(rect: WorkspaceRect(x: 0, y: r.y, width: 1, height: r.height), orientation: .horizontal)
    }

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .onAppear { model.updateSpace(size, hinge: hinge) }
                .onChange(of: layoutRect) { _ in model.updateSpace(size, hinge: hinge) }
                .onChange(of: divisions) { _ in model.updateSpace(size, hinge: hinge) }
            chrome
        }
    }

    @ViewBuilder
    private var chrome: some View {
        if model.windowMode, picture.width > 0 {
            let frames = model.frames
            let multi = model.layout.tiles.count > 1
            ZStack(alignment: .topLeading) {
                // Where the picture is on screen, for drags that start in Stage Peek.
                Color.clear
                    .frame(width: picture.width, height: picture.height)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { model.pictureGlobal = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { model.pictureGlobal = $0 }
                    })
                    .position(x: picture.midX, y: picture.midY)
                    .allowsHitTesting(false)
                ForEach(Array(frames.tiles.keys).filter { !frames.isFloat($0) }.sorted(), id: \.self) { id in
                    if let rect = frames.tiles[id], let tile = model.layout.tiles[id] {
                        tileView(id: id, tile: tile, rect: rect.onScreen(picture), multi: multi, frames: frames)
                    }
                }
                if let id = model.active, !frames.isFloat(id), let rect = frames.tiles[id]?.onScreen(picture), !model.arranging, model.drag == nil,
                   multi || model.localFullscreen == id, !coveredByFloat(titleRow(rect, width: rect.width), frames) {
                    // The focused pane's app menus (control only), in its label row right after the labels.
                    // While all its tabs are shown and leave too little room, the bar steps aside.
                    let e = unsafeInsets(of: rect)
                    let pane = CGRect(x: rect.minX + e.leading, y: rect.minY + e.top,
                                      width: rect.width - e.leading - e.trailing, height: rect.height - e.top - e.bottom)
                    if let end = labelStripEnd[id], end > pane.minX, end < pane.maxX {
                        PaneMenuBar(menus: model.menus, pane: CGRect(x: end - 2, y: pane.minY, width: pane.maxX - end + 2, height: pane.height),
                                    top: pane.minY + 5, bounds: picture)
                    } else {
                        PaneMenuBar(menus: model.menus, pane: pane, top: pane.minY + 6 + 26 + 4, bounds: picture)
                    }
                }
                let titles = titleZones(frames)
                #if os(iOS)
                // Floating panes over the arrangement, back to front, and tucked floats' edge handles.
                if !model.arranging {
                    WorkspaceFloatLayer(model: model, picture: picture, safeArea: safeArea, inputAllowed: inputAllowed,
                                        onClose: { confirmClose = $0 }, tipAvoiding: titles, placementChip: placementChip)
                }
                #endif
                WorkspaceDropOverlay(model: model, picture: picture, safeArea: safeArea, controls: controls + divisions,
                                     titles: titles, onChipFrame: { placementChip = $0 })
                if model.arranging {
                    arrangeControls(frames)
                } else if model.localFullscreen == nil, !voiceOver {
                    dividerHolds(frames)
                }
                #if os(iOS)
                // Mission Control: the notices of the floats it pauses, each on its own window.
                if !model.arranging, model.drag == nil { floatMissionControlNotices(frames) }
                #endif
                if let m = menu, let tile = model.layout.tiles[m.tile], let rect = frames.tiles[m.tile]?.onScreen(picture) {
                    // Tap anywhere else to close; nothing reaches the Mac while the menu is open.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { menu = nil } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Every item reachable: placed by its measured height inside the safe area (below the
                    // label when it fits, moved up when not), scrolling when taller than the screen.
                    let room = (safeArea.map { $0.intersection(picture) } ?? picture).insetBy(dx: 8, dy: 8)
                    let height = min(menuHeight, room.height)
                    let top = min(max(rect.minY + 40, room.minY), room.maxY - height)
                    paneMenu(m, tile: tile, maxHeight: room.height)
                        .position(x: min(max(rect.minX + 132, room.minX + 126), room.maxX - 126),
                                  y: top + height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                }
                if model.localFullscreen != nil { fullscreenStrip }
            }
            .coordinateSpace(name: "workspace")
            .alert(closeTitle, isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } })) {
                Button("Close Window", role: .destructive) { if let id = confirmClose { model.closeRemoteWindow(id) }; confirmClose = nil }
                Button("Cancel", role: .cancel) { confirmClose = nil }
            } message: {
                Text("The window closes on the Mac itself, as if you clicked its close button. The app keeps running, and unsaved work asks to be saved there first.")
            }
            .alert("Turn off Stage Manager on the Mac?", isPresented: $confirmStageManagerOff) {
                Button("Turn Off") { model.turnOffStageManager() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Windows in its side strip then show live here. MeowDisplay turns Stage Manager back on when Window mode ends.")
            }
            .onChange(of: model.localFullscreen) { full in if full != nil { revealStrip() } }
            .onAppear { syncMenus() }
            .onChange(of: menuKey) { _ in syncMenus() }
            .onChange(of: model.touchPulse) { _ in if model.localFullscreen != nil { revealStrip() } }
            .onChange(of: labelPress) { press in if press == nil { DispatchQueue.main.async { finishCancelledHold() } } }
        }
    }

    /// A label's hold ended without `onEnded` (the system took the touch): nothing stays marked
    /// held, and a drag it began is cancelled, never dropped where the finger happened to be.
    private func finishCancelledHold() {
        guard labelPress == nil, let held = heldLabel else { return }
        let dragging: Bool
        if case .pane(let tile, _)? = model.drag?.item, tile == held.tile { dragging = true } else { dragging = false }
        if PaneLabelInteraction.holdEnded(cancelled: true, dragging: dragging, heldHere: true, folded: false) == .cancelDrag {
            model.cancelDrag()
        }
        heldLabel = nil
        heldForm = nil
    }

    /// What decides whose menus the bar shows: the focused pane, its app, and control.
    private var menuKey: String {
        let source = model.active.flatMap { model.layout.tiles[$0]?.source }
        // `available` too: after a reconnect the same pane and app need their menus asked for again.
        return "\(model.active ?? "")|\(source?.isDisplay == false ? source?.bundleID ?? "" : "")|\(inputAllowed)|\(model.windowMode)|\(model.menus.available)"
    }

    private func syncMenus() {
        let source = model.active.flatMap { model.layout.tiles[$0]?.source }
        let appName = source.flatMap { s in model.catalog?.windows.first { $0.id == s.windowID }?.app }
        model.menus.sync(tile: model.active, bundle: source?.isDisplay == false ? source?.bundleID : nil,
                         appName: appName, enabled: inputAllowed && model.windowMode)
    }

    private var closeTitle: String {
        let name = confirmClose.flatMap { model.tileState($0)?.app }.flatMap { $0.isEmpty ? nil : $0 } ?? "this window"
        return "Close \(name) on the Mac?"
    }

    /// Mission Control holds this window's picture: what's happening and the one thing this device
    /// can do about it (that button is the only way out: never an Escape on its own). The × folds
    /// it to a small status that brings it back; Mission Control stays open, nothing is sent.
    @ViewBuilder
    private func missionControlNotice(_ id: String, compact: Bool, width: CGFloat) -> some View {
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.18)
        if model.missionControlNotice(id) == .folded {
            Button { withAnimation(animation) { model.unfoldMissionControlNotice(id) } } label: {
                Label("Paused · Mission Control", systemImage: "pause.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(workspaceChip, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Paused while Mission Control is open"))
            .accessibilityHint(Text("Shows the notice again."))
            .modifier(MissionControlAccess(model: model, id: id, saysState: false))
            .accessibilityIdentifier("missionControlStatus")
        } else {
            let action = model.missionControlAction
            let font = (compact ? Font.footnote : .callout).weight(.semibold)
            VStack(spacing: compact ? 6 : 8) {
                HStack(alignment: .top, spacing: 4) {
                    Label("Paused while Mission Control is open", systemImage: "rectangle.3.group")
                        .font(font).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { withAnimation(animation) { model.foldMissionControlNotice(id) } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                            .frame(width: 22, height: 22).background(Color.white.opacity(0.16), in: Circle())
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -7).padding(.trailing, -9)
                    .accessibilityLabel(Text("Hide Notice"))
                    .accessibilityHint(Text("Mission Control stays open on the Mac. A small status stays on this window."))
                    .accessibilityIdentifier("missionControlNoticeHide")
                }
                switch action {
                case .closeOnMac?:
                    Text("Press Esc on the Mac to close it.").font(compact ? .caption : .footnote)
                        .foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                default:
                    Button { model.performMissionControlAction() } label: {
                        Label(action == .exit ? String(localized: "Exit Mission Control")
                              : action == .awaitingApproval ? String(localized: "Awaiting Approval on the Mac…")
                              : String(localized: "Request Control to Exit"),
                              systemImage: action == .exit ? "xmark.rectangle" : "hand.raised")
                            .font(font).foregroundStyle(.black).lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 7 : 9)
                            .background(.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(action == .awaitingApproval)
                    .accessibilityIdentifier("exitMissionControl")
                }
            }
            .padding(.horizontal, compact ? 12 : 14).padding(.vertical, compact ? 9 : 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.08, opacity: 0.9)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: max(min(width - (compact ? 12 : 24), compact ? 300 : 380), 140))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("missionControlNotice")
        }
    }

    #if os(iOS)
    /// The floats Mission Control pauses: each one's notice, compact, on its own window (drawn
    /// here, above the floats). Not while a finger moves that float, and not where a float in
    /// front covers the notice's spot: that float hides it as it hides the window.
    @ViewBuilder
    private func floatMissionControlNotices(_ frames: WorkspaceFrames) -> some View {
        let ids = frames.floats
        let bounds = safeArea.map { $0.intersection(picture) } ?? picture
        ForEach(ids, id: \.self) { id in
            if let notice = model.missionControlNotice(id), model.floatGesture != id,
               let i = ids.firstIndex(of: id), let rect = frames.tiles[id]?.onScreen(picture),
               let spot = WorkspaceModel.missionControlNoticeSpot(on: rect, folded: notice == .folded, within: bounds,
                                                                  inFront: ids[(i + 1)...].compactMap { frames.tiles[$0]?.onScreen(picture) }) {
                missionControlNotice(id, compact: true, width: rect.width)
                    .position(x: spot.midX, y: spot.midY)
            }
        }
    }
    #endif

    /// On a window Mission Control pauses: its state as the accessibility value (`saysState`) and
    /// Exit Mission Control (or Request Control to exit it) as an action. Nothing on any other.
    private struct MissionControlAccess: ViewModifier {
        @ObservedObject var model: WorkspaceModel
        let id: String
        var saysState = true

        @ViewBuilder
        func body(content: Content) -> some View {
            if model.missionControlPaused(id) {
                let action = model.missionControlAction
                let stated = content.accessibilityValue(saysState ? Text("Paused while Mission Control is open") : Text(verbatim: ""))
                if action == .exit || action == .requestControl {
                    stated.accessibilityAction(named: action == .exit ? Text("Exit Mission Control") : Text("Request Control to Exit Mission Control")) {
                        model.performMissionControlAction()
                    }
                } else {
                    stated
                }
            } else {
                content
            }
        }
    }

    private func status(for id: String, tile: WorkspaceTile) -> String? {
        // The Mac is drawing this pane's window: never a stale "choose a window" over a live picture
        // (the window list can lag behind a window that just appeared).
        if let remote = model.tileState(id), remote.status == .live, let source = tile.source, remote.windowID == source.windowID { return nil }
        if tile.source?.isDisplay == true, model.missing.contains(id) { return "This display isn't connected to the Mac now" }
        if model.missing.contains(id) || tile.source == nil { return "Choose a window for this tile" }
        // Refused by the Mac (e.g. that window already shows in another tile).
        if model.remote?.rejected[id] != nil { return "Tap to choose a window for this tile" }
        guard let remote = model.tileState(id) else { return nil }
        let app = remote.app.isEmpty ? "This window" : remote.app
        switch remote.status {
        case .live: return nil
        case .waiting: return "Waiting for \(remote.app.isEmpty ? "the window" : remote.app)…"
        case .offscreen: return "\(app) is minimized or hidden on the Mac"
        case .closed: return "Closed on Mac. Tap to choose another window."
        case .failed: return "The Mac stopped sending \(remote.app.isEmpty ? "this window" : remote.app). Tap Retry."
        case .limit: return "Paused: too many windows at once"
        case .paused:
            return remote.inStageStrip
                ? "\(app) is in Stage Manager's side strip, so macOS pauses its picture. Show it on the Mac, or turn Stage Manager off, to see it live."
                : "macOS paused \(app)'s picture. It comes back when the window is shown on the Mac."
        case .retrying: return "Reconnecting to \(remote.app.isEmpty ? "the window" : remote.app)… (try \(remote.attempt))"
        }
    }

    /// How far each edge of [rect] reaches outside the safe area.
    private func unsafeInsets(of rect: CGRect) -> EdgeInsets {
        guard let safe = safeArea else { return EdgeInsets() }
        return EdgeInsets(top: max(0, safe.minY - rect.minY), leading: max(0, safe.minX - rect.minX),
                          bottom: max(0, rect.maxY - safe.maxY), trailing: max(0, rect.maxX - safe.maxX))
    }

    @ViewBuilder
    private func tileView(id: String, tile: WorkspaceTile, rect: CGRect, multi: Bool, frames: WorkspaceFrames) -> some View {
        let active = model.active == id
        let hovered = model.hovered == id && !active
        let corners = outerCorners(rect)
        ZStack(alignment: .topLeading) {
            PaneOutlineShape(topLeading: corners.0, topTrailing: corners.1, bottomTrailing: corners.2, bottomLeading: corners.3)
                .strokeBorder(active && multi ? workspaceAccent : Color.white.opacity(hovered ? 0.35 : (multi ? 0.12 : 0)),
                              lineWidth: active && multi ? 2 : (hovered ? 1 : 0.5))
                // A float's window is in the video, under this outline: the outline steps aside
                // where a float (or its title) is, instead of showing through it.
                .mask(WorkspaceHoleMask(size: rect.size, holes: floatOccluders(frames).map { $0.offsetBy(dx: -rect.minX, dy: -rect.minY) }))
                .allowsHitTesting(false)
                // The pane itself for VoiceOver (and UI tests): its activation selects the pane,
                // never a tap through to the Mac.
                .accessibilityElement()
                .accessibilityLabel(String(localized: "\(tile.source.map { labelText($0, in: tile, id: id) } ?? String(localized: "Empty")) pane"))
                .accessibilityIdentifier("workspacePane")
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityAction { model.focus(id) }
                // Paused by Mission Control: said here and the way out, even under a float or folded.
                .modifier(MissionControlAccess(model: model, id: id))
            // Where a floating pane covers this pane's titles, they step aside: touches there go to the float.
            let covered = coveredByFloat(titleRow(rect, width: 260), frames)
            tileLabels(id: id, tile: tile, rect: rect, active: active, multi: multi)
                .padding(unsafeInsets(of: rect))
                .opacity(covered ? 0 : 1)
                .allowsHitTesting(!covered)
                // A container, not an element: an accessibility modifier on this pane-sized layer
                // otherwise makes it one element that takes its title's label and button trait.
                .accessibilityElement(children: .contain)
                .accessibilityHidden(covered)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    /// Whether a shown floating pane (its window or its title pill) overlaps `r` (on screen).
    private func coveredByFloat(_ r: CGRect, _ frames: WorkspaceFrames) -> Bool {
        WorkspaceFloatLayering.isCovered(WorkspaceRect(r), by: floatOccluders(frames).map(WorkspaceRect.init))
    }

    /// What the shown floats cover on screen: each one's window and title pill (where it rests).
    private func floatOccluders(_ frames: WorkspaceFrames) -> [CGRect] {
        frames.floats.compactMap { frames.tiles[$0]?.onScreen(picture) }.flatMap { r -> [CGRect] in
            [r, floatPill(r)]
        }
    }

    /// A float's title pill where it rests: on its top edge, moved into the safe area when that
    /// edge is under the notch, the Dynamic Island or the status bar.
    private func floatPill(_ content: CGRect) -> CGRect {
        WorkspaceOverlayPlacement.floatPill(content: content, size: WorkspaceFloatLayering.pillBounds(WorkspaceRect(content)).cgRect.size,
                                            safe: safeArea, picture: picture)
    }

    /// The panes' label strips and the floats' title pills on screen: the drag's chip and the
    /// first-use tip keep clear of them.
    private func titleZones(_ frames: WorkspaceFrames) -> [CGRect] {
        let panes = frames.tiles.compactMap { id, r -> CGRect? in
            guard !frames.isFloat(id), let end = labelStripEnd[id] else { return nil }
            let rect = r.onScreen(picture), e = unsafeInsets(of: rect)
            let x = rect.minX + e.leading
            return end > x ? CGRect(x: x, y: rect.minY + e.top, width: end - x, height: WorkspaceOverlayPlacement.paneTitleHeight) : nil
        }
        // A float being docked is drawn only as its card under the finger: no pill to avoid.
        var docked: String?
        if case .float(let id)? = model.drag?.item { docked = id }
        return panes + frames.floats.filter { $0 != docked }.compactMap { frames.tiles[$0]?.onScreen(picture) }.map(floatPill)
    }

    /// Where a pane's label strip starts: its top-left corner inside the safe area.
    private func titleRow(_ rect: CGRect, width: CGFloat) -> CGRect {
        let e = unsafeInsets(of: rect)
        return CGRect(x: rect.minX + e.leading, y: rect.minY + e.top, width: min(rect.width - e.leading, width), height: 44)
    }

    /// A pane corner that sits in a corner of the phone's screen follows the screen's rounding;
    /// every other corner stays square. (topLeading, topTrailing, bottomTrailing, bottomLeading)
    private func outerCorners(_ rect: CGRect) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let radius = PaneOutlineShape.screenCornerRadius
        guard radius > 0, let screen = PaneOutlineShape.screenBounds, model.pictureGlobal.width > 0 else { return (0, 0, 0, 0) }
        let g = rect.offsetBy(dx: model.pictureGlobal.minX - picture.minX, dy: model.pictureGlobal.minY - picture.minY)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 2 }
        let left = near(g.minX, screen.minX), right = near(g.maxX, screen.maxX)
        let top = near(g.minY, screen.minY), bottom = near(g.maxY, screen.maxY)
        return (left && top ? radius : 0, right && top ? radius : 0, right && bottom ? radius : 0, left && bottom ? radius : 0)
    }

    @ViewBuilder
    private func tileLabels(id: String, tile: WorkspaceTile, rect: CGRect, active: Bool, multi: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if model.missionControlNotice(id) != nil {
                // Mission Control holds this window's picture: its notice (folded: a small status).
                missionControlNotice(id, compact: rect.width < 320, width: rect.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = status(for: id, tile: tile) {
                VStack(spacing: 8) {
                    Button { model.openOverview(replacing: id) } label: {
                        HStack(spacing: 8) {
                            // Still working: a live spinner (a still hourglass with Reduce Motion).
                            if let s = model.tileState(id)?.status, s == .waiting || s == .retrying {
                                if reduceMotion { Image(systemName: "hourglass").foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true) }
                                else { ProgressView().progressViewStyle(.circular).tint(.white).controlSize(.small) }
                            }
                            Text(text).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    if let s = model.tileState(id)?.status, s == .failed || s == .retrying {
                        Button { model.retryTile(id) } label: {
                            Label("Retry", systemImage: "arrow.clockwise").font(.callout.weight(.semibold))
                                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(workspaceChip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.tileState(id)?.status == .paused, model.tileState(id)?.inStageStrip == true, inputAllowed, !model.missionControlOpen {
                        HStack(spacing: 8) {
                            if model.remote?.stageAddAvailable == true {
                                // Explicit only: Stage Manager's own Add to Stage on this exact window's strip item.
                                Button { model.addToStage(id) } label: {
                                    Label("Add to Current Stage", systemImage: "rectangle.stack.badge.plus").font(.callout.weight(.semibold))
                                        .foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(.white, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("addToCurrentStage")
                            }
                            // Explicit only: switches the Mac to that window's stage (brings its app forward).
                            Button { model.showOnMac(id) } label: {
                                Label("Show on Mac", systemImage: "macwindow").font(.callout.weight(.semibold))
                                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(workspaceChip, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("showOnMac")
                            // Every strip window live: Stage Manager off while Window mode is used (confirmed).
                            // Offered only when the Mac can actually do it (the owner's shortcuts exist).
                            if ["ready", "failed"].contains(model.remote?.stageManagerControl ?? "") {
                                // Without control: ask for it here (this pane stays), then Turn Off again.
                                let granted = model.controlState() == .allowed
                                Button { if granted { confirmStageManagerOff = true } else { model.requestControl() } } label: {
                                    Label(granted ? String(localized: "Turn Off Stage Manager")
                                          : model.controlState() == .requesting ? String(localized: "Awaiting Approval on the Mac…")
                                          : String(localized: "Request Control to Turn Off Stage Manager"),
                                          systemImage: granted ? "rectangle.stack.badge.minus" : "hand.raised").font(.callout.weight(.semibold))
                                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(workspaceChip, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled([.requesting, .requestsDisabled].contains(model.controlState()))
                                .accessibilityIdentifier("paneStageManagerOff")
                            }
                        }
                        if model.remote?.stageManagerControl == "setup" {
                            Label("Turn Off Stage Manager: Setup Required", systemImage: "gearshape").font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        if let problem = model.stageAddProblem(id) {
                            Text(problem).font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        }
                        if model.remote?.stageManagerControl == "failed" {
                            Text("macOS didn't turn Stage Manager off. Try again, or turn it off on the Mac.")
                                .font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        } else if model.remote?.stageManagerControl == "setup" {
                            Text("On the Mac, open MeowDisplay Settings ▸ System ▸ Stage Manager and click Set Up Automatically.")
                                .font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        }
                    }
                    if let s = model.tileState(id)?.status, s == .offscreen || (s == .paused && model.tileState(id)?.inStageStrip != true),
                       inputAllowed, !model.missionControlOpen {
                        // Explicit only: un-minimizes or unhides the window on the Mac and brings it forward.
                        Button { model.showOnMac(id) } label: {
                            Label("Show on Mac", systemImage: "macwindow").font(.callout.weight(.semibold))
                                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(workspaceChip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("showOnMac")
                    }
                    #if os(iOS)
                    // Showing it on the Mac (or reopening a closed window) needs control: ask in place.
                    if !inputAllowed, let s = model.tileState(id)?.status,
                       s == .closed || (!model.missionControlOpen && (s == .paused || s == .offscreen)) {
                        RequestControlInline()
                    }
                    #endif
                    if model.tileState(id)?.status == .closed, inputAllowed, let bundle = tile.source?.bundleID {
                        // The app may reopen a window (needs control; never automatic).
                        Button { model.launch(bundle) } label: {
                            Label("Open on Mac", systemImage: "arrow.up.forward.app").font(.callout.weight(.semibold))
                                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(workspaceChip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if multi || model.arranging || tile.tabs.count > 1 || model.localFullscreen == id {
                AppMenuObserver(menus: model.menus) { menus in
                    // The menu bar shares this row (see `chrome`): its tabs fold to the shown one and "+N".
                    let barHere = active && menus.barShown && menus.tile == id && !model.arranging && model.drag == nil
                        && (multi || model.localFullscreen == id)
                    labelStrip(id: id, tile: tile, rect: rect, active: active, sharesRow: barHere)
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { labelStripEnd[id] = g.frame(in: .named("workspace")).maxX }
                        .onChange(of: g.frame(in: .named("workspace"))) { labelStripEnd[id] = $0.maxX }
                })
                .onDisappear { labelStripEnd[id] = nil }
            }
            VStack(spacing: 6) {
                windowFrameStatus(id)
                if active, model.remote?.hostFocus.isMismatch == true {
                    Button { model.focus(id) } label: {
                        Text(model.remote?.hostFocus == .otherWindowFocused
                             ? "Typing paused: another window is in front on the Mac. Tap to resume."
                             : "Typing paused: another app is in front on the Mac. Tap to resume.")
                            .font(.caption).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(8)
        }
    }

    private func windowFrameStatus(_ id: String) -> some View { WorkspaceWindowFrameStatus(model: model, id: id) }


    // MARK: Labels (one per window in the pane; tabs side by side)

    private func windowItem(_ s: WorkspaceSource) -> CatalogWindowItem? { model.windowItem(s) }

    /// A label's text: the app's name; when a pane holds several windows of one app, their
    /// titles (shortened to fit).
    private func labelText(_ s: WorkspaceSource, in tile: WorkspaceTile, id: String) -> String {
        let w = windowItem(s)
        if s.isDisplay { return w?.title ?? String(localized: "Desktop") }   // "Full Desktop", or the display's name
        let app = w?.app ?? (s == tile.source ? model.tileState(id)?.app : nil) ?? "Window"
        guard tile.windows.count > 1 else { return app.isEmpty ? "Window" : app }
        let apps = tile.windows.map { windowItem($0)?.app ?? "" }
        if apps.filter({ $0 == app }).count > 1, let title = w?.title, !title.isEmpty { return title }
        return app.isEmpty ? (w?.title ?? "Window") : app
    }

    /// `sharesRow`: the menu bar sits in this row, so the tabs shrink to the shown tab's app icon
    /// and "+N" until the person taps, holds or scrolls them (`expandTabs`): then full names,
    /// scrolling when they don't fit. A held label keeps the form it was held in until the finger
    /// lifts, so one hold on the icon opens the options (with the titles shown in full).
    @ViewBuilder
    private func labelStrip(id: String, tile: WorkspaceTile, rect: CGRect, active: Bool, sharesRow: Bool) -> some View {
        let windows = tile.windows
        let available = max(rect.width - 12, 60)
        // Shorter labels when the pane holds several windows; the strip scrolls (by finger only) past that.
        let each = windows.count <= 1 ? min(180, available) : max(76, min(150, available / CGFloat(windows.count) - 6))
        let compact = PaneLabelInteraction.folded(sharesRow: sharesRow, hasWindows: !windows.isEmpty, expanded: tabsExpanded == id,
                                                  held: heldLabel?.tile == id, dragging: model.drag != nil,
                                                  heldFolded: heldForm?.tile == id ? heldForm?.folded : nil)
        if compact {
            let shownIndex = windows.firstIndex { $0 == tile.source } ?? 0
            let visible = [shownIndex]
            let hidden = windows.count - 1
            HStack(spacing: 4) {
                ForEach(visible, id: \.self) { i in
                    label(id: id, tab: windows.count > 1 ? i : nil, text: labelText(windows[i], in: tile, id: id),
                          app: labelApp(windows[i]), shown: i == shownIndex, active: active,
                          width: 64, iconOnly: true)
                }
                if hidden > 0 {
                    Button { expandTabs(id) } label: {
                        Text("+\(hidden)").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color(white: 0.2, opacity: 0.6), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(hidden == 1 ? "1 more tab" : "\(hidden) more tabs"))
                    .accessibilityHint(Text("Shows every tab in this pane."))
                }
            }
            .padding(6)
            .fixedSize()
        } else {
            let row = HStack(spacing: 4) {
                if windows.isEmpty {
                    label(id: id, tab: nil, text: String(localized: "Empty"), app: nil, shown: true, active: active, width: each)
                }
                ForEach(Array(windows.enumerated()), id: \.offset) { i, s in
                    label(id: id, tab: windows.count > 1 ? i : nil, text: labelText(s, in: tile, id: id),
                          app: labelApp(s), shown: s == tile.source, active: active, width: each)
                }
            }
            .padding(6)
            if #available(macOS 13.0, iOS 16.0, *) {
                ViewThatFits(in: .horizontal) {
                    row.fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) { row }
                        .scrollDisabled(heldLabel != nil || model.drag != nil)
                        .frame(width: available + 12)
                        // Scrolling the tabs keeps them all shown while the menu bar waits.
                        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in if sharesRow { expandTabs(id) } })
                }
            } else {
                // macOS 12 receiver: always a scrolling strip.
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .frame(width: available + 12)
            }
        }
    }

    /// The app a label names: its icon, or the placeholder until the Mac sends one. nil for a desktop.
    private func labelApp(_ s: WorkspaceSource) -> (bundleID: String, name: String)? {
        guard !s.isDisplay, let bundle = s.bundleID ?? windowItem(s)?.bundleID, !bundle.isEmpty else { return nil }
        return (bundle, windowItem(s)?.app ?? "")
    }

    /// `iconOnly`: just the app's icon (the placeholder until it arrives; a desktop's name), beside the menu bar.
    private func label(id: String, tab: Int?, text: String, app: (bundleID: String, name: String)?, shown: Bool, active: Bool,
                       width: CGFloat, iconOnly: Bool = false) -> some View {
        let highlighted = shown && active
        let target = PaneMenuTarget(tile: id, tab: tab)
        return HStack(spacing: 5) {
            if let app {
                WorkspaceAppIcon(icon: model.icons[app.bundleID], name: app.name.isEmpty ? text : app.name,
                                 bundleID: app.bundleID, size: 15, tint: highlighted ? .black : .white)
            }
            if !iconOnly || app == nil {
                Text(text).font(.caption.weight(shown ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(maxWidth: width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(GeometryReader { g in
            // Where this tab's label is, for putting a dragged tab back between two others.
            Color.clear
                .onAppear { if let tab { model.tabLabelFrames[id, default: [:]][tab] = g.frame(in: .global) } }
                .onChange(of: g.frame(in: .global)) { f in if let tab { model.tabLabelFrames[id, default: [:]][tab] = f } }
        })
        .foregroundStyle(highlighted ? Color.black : Color.white.opacity(shown ? 1 : 0.8))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(highlighted ? workspaceAccent.opacity(0.9) : (shown ? workspaceChip : Color(white: 0.2, opacity: 0.6)), in: Capsule())
        .overlay(Capsule().stroke(heldLabel == target ? workspaceAccent : .clear, lineWidth: 2))
        .scaleEffect(heldLabel == target && !reduceMotion ? 1.08 : 1)
        .contentShape(Capsule())
        .onTapGesture {
            // A tap selects the pane (typing goes there) or shows that tab. Never a click on the Mac.
            let now = Date().timeIntervalSinceReferenceDate
            switch PaneLabelInteraction.tap(target, shown: shown, highlighted: highlighted, folded: iconOnly,
                                            last: lastLabelTap, now: now, held: heldLabel != nil) {
            case .toggleFullscreen?:
                // A second tap: this pane fills the device, or the layout comes back.
                lastLabelTap = nil
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.toggleLocalFullscreen(id) }
                Self.haptic(.drop)
            case .showTab(let t, let expand)?:
                lastLabelTap = .init(target: target, at: now, folded: iconOnly)
                model.switchTab(id, to: t)
                if expand { expandTabs(id) }
            case .select(let expand)?:
                lastLabelTap = .init(target: target, at: now, folded: iconOnly)
                model.focus(id)
                // Tabs, or the selected pane's folded icon: every title in full for a while.
                if expand { expandTabs(id) }
            case nil:
                // A label is held. With no hold in flight (the system cancelled it), it's let go of
                // once any ending hold has run, so the next tap acts.
                if labelPress == nil { DispatchQueue.main.async { finishCancelledHold() } }
            }
        }
        // Hold: lift the label. Move = drag it to another pane (merge as a tab, split, swap);
        // release without moving = the label's menu. The strip keeps its form until the finger
        // lifts, so the view carrying this gesture stays (see `labelStrip`).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($labelPress) { value, state, _ in
                    if case .second(true, _) = value { state = target }
                }
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if heldLabel == nil { heldLabel = target; heldForm = (id, iconOnly); Self.haptic(.lift) }
                    guard let drag else { return }
                    let moved = hypot(drag.translation.width, drag.translation.height)
                    if model.drag == nil, moved > 10 { model.beginDrag(.pane(id, tab: tab), at: drag.location) }
                    else if model.drag != nil { model.moveDrag(to: drag.location) }
                }
                .onEnded { _ in
                    switch PaneLabelInteraction.holdEnded(cancelled: false, dragging: model.drag != nil,
                                                          heldHere: heldLabel == target, folded: heldForm?.folded == true) {
                    case .drop:
                        if model.endDrag() { Self.haptic(.drop) }
                    case .menu(let expand):
                        // One hold on the folded icon: its titles in full and its options together.
                        if expand { expandTabs(id) }
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { menu = target }
                    case .cancelDrag, .nothing:
                        break
                    }
                    heldLabel = nil
                    heldForm = nil
                })
        // One element with the label's own frame. Without it, the label and traits below also
        // land on an element that reports the whole pane's frame: VoiceOver outlines the pane,
        // and a UI test's press on it lands mid-pane, on the Mac picture in a live session.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text + (shown ? "" : ", tab"))
        .accessibilityHint(shown ? "Selects this pane for typing. Fullscreen and other options are in Actions." : "Shows this tab.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Options") { menu = target }
        .accessibilityAction(named: model.localFullscreen == id ? "Exit Fullscreen" : "Fullscreen on This Device") {
            model.toggleLocalFullscreen(id)
        }
        #if os(iOS)
        .accessibilityAction(named: tab == nil ? "Float This Pane" : "Float This Tab") {
            if model.canFloat(pane: id, tab: tab) { model.floatPane(id, tab: tab) }
        }
        #endif
    }

    // MARK: The label menu

    private func paneMenu(_ m: PaneMenuTarget, tile: WorkspaceTile, maxHeight: CGFloat) -> some View {
        // The rows' natural height is measured inside the scroll view; the menu is exactly that tall,
        // or the room's height (scrolling) when taller.
        ScrollView(.vertical, showsIndicators: menuHeight > maxHeight) {
            paneMenuRows(m, tile: tile)
                .background(GeometryReader { g in Color.clear.preference(key: PaneMenuHeightKey.self, value: g.size.height) })
        }
        .frame(width: 252, height: min(menuHeight, maxHeight))
        .onPreferenceChange(PaneMenuHeightKey.self) { menuHeight = $0 }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
        .onAppear { Self.haptic(.lift) }
    }

    private func paneMenuRows(_ m: PaneMenuTarget, tile: WorkspaceTile) -> some View {
        let full = model.localFullscreen == m.tile
        let isDesktop = tile.source?.isDisplay == true
        let isWindow = tile.source != nil && !isDesktop
        return VStack(alignment: .leading, spacing: 0) {
            if model.missionControlPaused(m.tile), let action = model.missionControlAction {
                // Mission Control holds this window's picture: the way out, notice folded or not.
                menuRow(action == .exit ? "Exit Mission Control" : action == .requestControl ? "Request Control to Exit Mission Control"
                        : action == .awaitingApproval ? "Awaiting Approval on the Mac…" : "Press Esc on the Mac to Close Mission Control",
                        action == .exit ? "xmark.rectangle" : action == .closeOnMac ? "escape" : "hand.raised",
                        enabled: action == .exit || action == .requestControl) { model.performMissionControlAction() }
                Divider().overlay(Color.white.opacity(0.25)).padding(.vertical, 4)
            }
            menuRow(full ? "Exit Fullscreen" : "Fullscreen on This Device",
                    full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    hint: full ? "Brings back the other panes." : "Shows only this pane on this device. The Mac is unchanged. Double-tap the pane title to toggle.") {
                full ? model.exitLocalFullscreen() : model.enterLocalFullscreen(m.tile)
            }
            if isDesktop, let onViewFullScreen {
                // The only way from a desktop pane back to the plain full-screen desktop (Mirror/Extend).
                menuRow("View Full Screen", "display") { onViewFullScreen() }
            }
            menuRow(model.effectiveFit(m.tile) == .fill ? (isDesktop ? "Show Whole Desktop" : "Show Whole Window") : "Fill Pane",
                    model.effectiveFit(m.tile) == .fill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward") {
                model.toggleFit(m.tile)
            }
            if tile.zoom != nil || tile.rotation != .none || tile.fit == .fill {
                menuRow("Reset View", "arrow.counterclockwise") { model.resetView(m.tile) }
            }
            menuRow("Rotate", "rotate.right") { model.rotate(m.tile) }
            menuRow(isDesktop ? "Show a Window Here…" : "Change Window…", "macwindow.on.rectangle") { model.openOverview(replacing: m.tile) }
            #if os(iOS)
            if model.canFloat(pane: m.tile, tab: m.tab) {
                menuRow(m.tab == nil ? "Float This Pane" : "Float This Tab", "macwindow.on.rectangle",
                        hint: "Shows it as a floating window over the others. Drag its title to move it.") {
                    model.floatPane(m.tile, tab: m.tab)
                }
            }
            #endif
            menuRow("Arrange Panes", "rectangle.3.group") { model.arranging = true }
            if let tab = m.tab {
                menuRow("Remove This Tab", "xmark.rectangle") { model.removeTab(m.tile, at: tab) }
            }
            if model.canRemoveFromLayout(m.tile) {
                menuRow("Remove from Layout", "rectangle.badge.minus",
                        hint: "Takes this pane off this device's layout. The window stays open on the Mac.") { model.removeTile(m.tile) }
            }
            if isWindow, model.menus.available, inputAllowed {
                menuRow(model.menus.barShown ? "Hide Menu Bar" : "Show Menu Bar", "menubar.rectangle") { model.menus.barShown.toggle() }
            }
            if isWindow {
                Divider().overlay(Color.white.opacity(0.25)).padding(.vertical, 4)
                if model.offersWindowFrameOnMac(m.tile) {
                    // The real Mac window, not this pane's picture: only from these items, never a gesture.
                    let ready = model.canControlMac && !model.isResizingOnMac(m.tile)
                    menuRow("Fill Window on Mac", "arrow.up.and.down.and.arrow.left.and.right",
                            hint: "Resizes the window on the Mac to fill its screen, below the menu bar and clear of the Dock. Not full screen.",
                            enabled: ready) { model.fillWindowOnMac(m.tile) }
                    if model.canRestoreOnMac(m.tile) {
                        menuRow("Restore Previous Size on Mac", "arrow.uturn.backward",
                                hint: "Puts the window on the Mac back to the size and place it had before Fill Window on Mac.",
                                enabled: ready) { model.restoreWindowOnMac(m.tile) }
                    }
                }
                menuRow("Minimize on Mac", "minus.rectangle", enabled: inputAllowed) { model.minimizeRemoteWindow(m.tile) }
                menuRow("Close Window on Mac…", "xmark.square", destructive: true, enabled: inputAllowed) { confirmClose = m.tile }
                if !inputAllowed {
                    Text(model.menus.available ? String(localized: "Request Control for more actions, like Minimize, Close and the Mac's menu bar.")
                         : String(localized: "Request Control for more actions, like Minimize and Close."))
                        .font(.caption2).foregroundStyle(.white.opacity(0.65)).padding(.horizontal, 14).padding(.bottom, 4)
                    #if os(iOS)
                    RequestControlInline(compact: true).padding(.horizontal, 14).padding(.bottom, 6)
                    #endif
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 252, alignment: .leading)
    }

    private func menuRow(_ title: LocalizedStringKey, _ symbol: String, hint: LocalizedStringKey? = nil,
                         destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { menu = nil }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(destructive ? Color.red : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
    }

    // MARK: Fullscreen on This Device

    /// Exit, Fit/Fill, Reset View and Settings. Shown on entering and on any touch, then fades after 3 s
    /// (kept visible with VoiceOver). Its buttons never reach the Mac; the rest of the screen still does.
    @ViewBuilder
    private var fullscreenStrip: some View {
        if let id = model.localFullscreen, stripVisible || voiceOver {
            HStack(spacing: 4) {
                stripButton("Exit Fullscreen", "arrow.down.right.and.arrow.up.left") { model.exitLocalFullscreen() }
                stripButton(model.effectiveFit(id) == .fill ? "Show Whole Window" : "Fill Pane",
                            model.effectiveFit(id) == .fill ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward") {
                    model.toggleFit(id)
                }
                stripButton("Reset View", "arrow.counterclockwise") { model.resetView(id) }
                if let onSettings { stripButton("Settings", "gearshape") { onSettings() } }
            }
            .padding(5)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Color.black.opacity(0.3)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
            .position(x: picture.midX, y: max(picture.minY, safeArea?.minY ?? 0) + 34)
            .transition(.opacity)
            .accessibilityIdentifier("fullscreenStrip")
        }
    }

    private func stripButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            revealStrip()
        } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    /// Shows every tab of the pane for a while (tapping, holding or scrolling its labels), then
    /// back to the shown tab and "+N" so the menu bar keeps the row.
    private func expandTabs(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { tabsExpanded = id }
        tabsCollapseTask?.cancel()
        tabsCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if heldLabel?.tile == id || model.drag != nil || menu?.tile == id { expandTabs(id); return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { if tabsExpanded == id { tabsExpanded = nil } }
        }
    }

    private func revealStrip() {
        withAnimation(.easeOut(duration: 0.2)) { stripVisible = true }
        stripHideTask?.cancel()
        stripHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { stripVisible = false }
        }
    }

    // MARK: Haptics

    private enum Haptic { case lift, selection, drop }

    private static func haptic(_ h: Haptic) {
        #if canImport(UIKit)
        switch h {
        case .lift: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .drop: UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7)
        }
        #endif
    }

    @ViewBuilder
    private func arrangeControls(_ frames: WorkspaceFrames) -> some View {
        ForEach(Array(frames.dividers.enumerated()), id: \.offset) { _, divider in
            let r = divider.hitRect.onScreen(picture)
            let horizontal = divider.axis == .horizontal
            Capsule().fill(Color.white.opacity(0.85))
                .frame(width: horizontal ? 6 : 44, height: horizontal ? 44 : 6)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .position(x: r.midX, y: r.midY)
                // Measured in the workspace, not the grip: the grip moves with each step.
                .gesture(DragGesture(coordinateSpace: .named("workspace"))
                    .onChanged { v in
                        // The change since the last event, as a share of the picture.
                        let dx = v.translation.width - lastDividerTranslation.width
                        let dy = v.translation.height - lastDividerTranslation.height
                        lastDividerTranslation = v.translation
                        model.resize(divider, delta: horizontal ? dx / max(picture.width, 1) : dy / max(picture.height, 1))
                    }
                    .onEnded { _ in
                        lastDividerTranslation = .zero
                        model.endResize()
                    })
                .accessibilityLabel("Resize tiles")
                .accessibilityHint("Swipe up or down to move the divider.")
                .accessibilityAdjustableAction { direction in
                    // VoiceOver can't drag: one step is 5% of the picture.
                    switch direction {
                    case .increment: model.resize(divider, delta: 0.05); model.endResize()
                    case .decrement: model.resize(divider, delta: -0.05); model.endResize()
                    @unknown default: break
                    }
                }
        }
        HStack(spacing: 14) {
            if model.canUndo { Button("Undo") { model.undo() } }
            if model.canRedo { Button("Redo") { model.redo() } }
            Menu("Layouts") {
                Button { layoutName = ""; savingLayout = true } label: { Label("Save This Layout…", systemImage: "square.and.arrow.down") }
                if !model.savedLayouts.isEmpty {
                    Section("Saved") {
                        ForEach(model.savedLayouts) { s in Button(s.name) { model.applySaved(s.id) } }
                    }
                    Menu("Delete a Saved Layout") {
                        ForEach(model.savedLayouts) { s in Button(s.name, role: .destructive) { model.deleteSavedLayout(s.id) } }
                    }
                }
                Section("Arrangements") {
                    ForEach(WorkspacePreset.available(capacity: model.capacity), id: \.self) { p in
                        Button(p.title) { model.apply(p) }
                    }
                }
            }
            Button { model.arranging = false } label: { Text("Done").fontWeight(.semibold) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(workspaceChip, in: Capsule())
        .background(GeometryReader { g in
            Color.clear.onAppear { arrangeBarSize = g.size }.onChange(of: g.size) { arrangeBarSize = $0 }
        })
        // Where it was, unless that is on the tray or its gear: then just above them.
        .position(arrangeBarCentre)
        .alert("Save Layout", isPresented: $savingLayout) {
            TextField("Name", text: $layoutName)
            Button("Save") { model.saveLayout(named: layoutName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved layouts are kept for this Mac. Their windows are matched again when you use one.")
        }
    }

    private var arrangeBarCentre: CGPoint {
        let bar = WorkspaceOverlayPlacement.bottomBar(
            size: arrangeBarSize ?? CGSize(width: 260, height: 36),
            preferredMidY: min(picture.maxY, safeArea?.maxY ?? .infinity) - 44,
            picture: picture, safe: safeArea, avoiding: controls + divisions)
        return CGPoint(x: bar.midX, y: bar.midY)
    }

    /// Outside Arrange: press and hold a divider, then drag it. The strip is narrow so the
    /// windows' own edges still get their touches; a short tap there does nothing.
    @ViewBuilder
    private func dividerHolds(_ frames: WorkspaceFrames) -> some View {
        // A divider takes touches only where no float covers it: a touch on a float drawn over a
        // divider goes to that float's window, never to the divider under it. One view per divider
        // (its identity never changes while it's held), its touch shape cut around the floats, and
        // around tucked floats' strips where it meets an edge (a tap on a strip brings its window back).
        let covers = (floatOccluders(frames) + stripTouchAreas).map(WorkspaceRect.init)
        ForEach(Array(frames.dividers.enumerated()), id: \.offset) { i, divider in
            let r = divider.hitRect.onScreen(picture)
            let horizontal = divider.axis == .horizontal
            let held = heldDivider == i
            let size = CGSize(width: horizontal ? min(r.width, 14) : r.width, height: horizontal ? r.height : min(r.height, 14))
            let strip = CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
            let parts = WorkspaceFloatLayering.uncovered(WorkspaceRect(strip), alongX: !horizontal, by: covers)
                .map { $0.cgRect.offsetBy(dx: -strip.minX, dy: -strip.minY) }
            ZStack {
                Color.white.opacity(0.001)
                if held {
                    Capsule().fill(workspaceAccent)
                        .frame(width: horizontal ? 6 : 44, height: horizontal ? 44 : 6)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(held ? WorkspaceRectsShape(rects: [CGRect(origin: .zero, size: size)]) : WorkspaceRectsShape(rects: parts))
            .position(x: r.midX, y: r.midY)
            .gesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace")))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if heldDivider != i {
                        heldDivider = i
                        lastDividerTranslation = .zero
                        Self.haptic(.lift)
                    }
                    guard let drag else { return }
                    let dx = drag.translation.width - lastDividerTranslation.width
                    let dy = drag.translation.height - lastDividerTranslation.height
                    lastDividerTranslation = drag.translation
                    model.resize(divider, delta: horizontal ? dx / max(picture.width, 1) : dy / max(picture.height, 1))
                }
                .onEnded { _ in
                    if heldDivider == i { model.endResize(); Self.haptic(.drop) }
                    heldDivider = nil
                    lastDividerTranslation = .zero
                })
            .accessibilityHidden(true)   // VoiceOver uses Arrange Panes
        }
    }

    /// Where tucked floats' strips take touches (this view's coordinates).
    private var stripTouchAreas: [CGRect] {
        let dx = picture.minX - model.pictureGlobal.minX, dy = picture.minY - model.pictureGlobal.minY
        return model.floatHandlesGlobal.map { $0.offsetBy(dx: dx, dy: dy) }
    }
}

private extension WorkspaceDropTarget {
    var previewRect: WorkspaceRect {
        switch self {
        case .slot(_, let p): return p
        case .split(_, _, let p): return p
        }
    }
    var isSlot: Bool { if case .slot = self { return true }; return false }
}

/// The collapsible rail: a thin handle at rest, a strip of windows when open.
struct WindowRailView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if model.available {
            let vertical = model.railEdge == .left || model.railEdge == .right
            let alignment: Alignment = switch model.railEdge {
            case .top: .top
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            }
            ZStack(alignment: alignment) {
                Color.clear.allowsHitTesting(false)
                if model.railExpanded { expanded(vertical: vertical) } else { handle(vertical: vertical) }
            }
        }
    }

    private func handle(vertical: Bool) -> some View {
        let current = model.active.flatMap { model.tileState($0)?.app }.flatMap { $0.isEmpty ? nil : $0 }
        return Button { model.railExpanded = true } label: {
            Group {
                if let current, !vertical {
                    Text(current).font(.caption2).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 3)
                        .background(workspaceChip, in: Capsule())
                } else {
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: vertical ? 5 : 36, height: vertical ? 36 : 5)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show windows" + (current.map { ", now \($0)" } ?? ""))
    }

    private func expanded(vertical: Bool) -> some View {
        let windows = model.catalog?.windows ?? []
        let controls = Group {
            Button("All Windows") { model.openOverview() }
            Button("Arrange") { model.arranging = true; model.railExpanded = false }
            Menu("Move Rail") { ForEach(WorkspaceRailEdge.allCases, id: \.self) { e in Button(e.rawValue.capitalized) { model.railEdge = e } } }
            Button("Hide") { model.railExpanded = false }
        }
        let cards = ForEach(windows.prefix(30)) { w in
            RailCard(window: w, thumbnail: model.thumbnails[w.id],
                     current: model.layout.tiles.values.contains { $0.source?.windowID == w.id },
                     onPick: { model.choose(w, asNewTile: false) },
                     onAdd: model.layout.tiles.count < model.capacity ? { model.choose(w, asNewTile: true) } : nil)
        }
        return Group {
            if vertical {
                ScrollView { VStack(alignment: .leading, spacing: 6) { controls; cards } .padding(6) }
                    .frame(width: 168)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { controls } }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { cards } }
                    if windows.isEmpty { Text("Looking for windows…").font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(white: 0.11, opacity: 0.95), in: RoundedRectangle(cornerRadius: 16))
        .padding(6)
    }
}

private struct RailCard: View {
    let window: CatalogWindowItem
    let thumbnail: CGImage?
    let current: Bool
    let onPick: () -> Void
    let onAdd: (() -> Void)?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(Color(white: 0.18))
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                    if let onAdd {
                        Button(action: onAdd) { Text("+").padding(.horizontal, 8).padding(.vertical, 2).background(workspaceChip, in: Circle()) }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .accessibilityLabel("Add \(window.app) as a new tile")
                    }
                }
                .frame(width: 132, height: 64)
                Text(window.app).font(.caption2).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(current ? workspaceAccent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.app): \(window.title.isEmpty ? "window" : window.title)")
        .accessibilityValue(current ? "Showing" : "")
        .addAsTileAction(window.app, onAdd)
    }
}

private extension View {
    /// The small Add button sits inside the card's own button, which VoiceOver treats as one
    /// element: offer Add as an action on the card instead.
    @ViewBuilder
    func addAsTileAction(_ app: String, _ onAdd: (() -> Void)?) -> some View {
        if let onAdd {
            accessibilityAction(named: Text("Add \(app) as a new tile"), onAdd)
        } else {
            self
        }
    }
}

/// Mission Control-style overview: every shareable window grouped by app, plus layouts and whole-display modes.
/// Its search also finds Mac apps with no window to show (any app on the Mac, from its app list):
/// opening one is confirmed first, needs control, and the app's new window goes in the tile the
/// picker was opened for (`WorkspaceAppOpening`); several new windows: the person picks one.
struct WindowOverviewView: View {
    @ObservedObject var model: WorkspaceModel
    let macName: String
    let inputAllowed: Bool
    let onMirror: () -> Void
    let onExtend: () -> Void
    /// Insets that keep the content clear of a notch and the home indicator; the backdrop fills the screen.
    var safeInsets = EdgeInsets()
    @State private var query = ""
    /// The app tapped under Apps to Open, until the person confirms or cancels opening it.
    @State private var confirmApp: WorkspacePickerSearch.AppToOpen?

    /// Apps can be opened from here now (control, and input reaching the Mac).
    private var canOpenApps: Bool { inputAllowed && model.canControlMac }

    var body: some View {
        if model.overviewOpen {
            let catalog = model.catalog
            let results = WorkspacePickerSearch.results(query, windows: catalog?.windows ?? [], running: catalog?.apps ?? [],
                                                        installed: model.apps)
            let windows = results.windows
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            let iconBundles = results.apps.prefix(24).map(\.bundleID)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.replacingTile != nil ? "Choose a window for this tile" : "Windows on \(macName)")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { model.closeOverview() }.keyboardShortcut(.cancelAction)
                }
                .modifier(OpenedWindowChoice(model: model))
                TextField("Search windows and apps", text: $query).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Text("Full Desktop:").foregroundStyle(.white.opacity(0.7))
                    Button("Mirror") { model.closeOverview(); onMirror() }.buttonStyle(.bordered)
                    Button("Extend") { model.closeOverview(); onExtend() }.buttonStyle(.bordered)
                }
                if model.windowMode { WorkspacePresetsView(capacity: model.capacity, tileCount: model.layout.tiles.count) { model.apply($0) } }
                if !model.stacked.isEmpty {
                    Text("Hidden on this screen").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal) {
                        HStack { ForEach(model.stacked, id: \.self) { id in
                            Button(model.tileState(id)?.app.isEmpty == false ? model.tileState(id)!.app : "Window") { model.bringBack(id); model.closeOverview() }
                                .buttonStyle(.bordered)
                        } }
                    }
                }
                if let opening = model.appOpening, opening.isWaiting { openingStatus(opening) }
                if catalog == nil {
                    Text("Asking \(macName) for its windows…").foregroundStyle(.white.opacity(0.7))
                } else if catalog?.unavailable == true {
                    Text("\(macName) can't list its windows right now. Check that MeowDisplay has Screen Recording permission on the Mac.")
                        .foregroundStyle(.white.opacity(0.8))
                } else if windows.isEmpty, searching {
                    Text(results.apps.isEmpty ? "Nothing on \(macName) matches \"\(query)\"." : "No open windows match \"\(query)\".")
                        .foregroundStyle(.white.opacity(0.7))
                }
                ScrollView {
                    if !windows.isEmpty, !results.apps.isEmpty { sectionHeader("Open Windows") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(windows) { w in
                            OverviewCard(window: w, thumbnail: model.thumbnails[w.id], icon: model.icons[w.bundleID],
                                         current: model.layout.tiles.values.contains { $0.source?.windowID == w.id },
                                         onPick: { model.choose(w, asNewTile: false) },
                                         onAdd: model.replacingTile == nil && (1..<max(model.capacity, 1)).contains(model.layout.tiles.count)
                                             ? { model.choose(w, asNewTile: true) } : nil)
                        }
                    }
                    appSection(results, searching: searching)
                }
                .confirmationDialog(confirmApp.map(openTitle) ?? "", isPresented: Binding(get: { confirmApp != nil }, set: { if !$0 { confirmApp = nil } }),
                                    titleVisibility: .visible, presenting: confirmApp) { app in
                    if canOpenApps {
                        Button(String(localized: "Open \(app.name)")) { model.openAppFromPicker(app) }
                    } else if model.controlState() != .requestsDisabled {
                        Button("Request Control and Open") { model.openAppFromPicker(app, requestingControl: true) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { app in
                    Text(openMessage(app))
                }
            }
            .padding(16)
            .padding(safeInsets)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.06, opacity: 0.97).ignoresSafeArea())
            .modifier(AppOpeningFailureAlert(model: model, macName: macName) { name in query = name })
            .onAppear { model.requestIcons(iconBundles) }
            .onChange(of: iconBundles) { model.requestIcons($0) }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// Apps with no window to show, apart from the windows: tapping one asks before opening it.
    @ViewBuilder
    private func appSection(_ results: WorkspacePickerSearch.Results, searching: Bool) -> some View {
        if !results.apps.isEmpty || results.moreApps {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Apps to Open")
                Text(canOpenApps ? "Not open, or open with no window to show. An app opens on the Mac without coming to the front."
                                 : "Opening an app needs control of the Mac.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                ForEach(results.apps) { app in appRow(app) }
                if results.moreApps {
                    Text(searching ? "More apps match. Type more of the name." : "Search to find any app on \(macName).")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.top, 2)
                }
            }
        }
    }

    private func appRow(_ app: WorkspacePickerSearch.AppToOpen) -> some View {
        Button { confirmApp = app } label: {
            HStack(spacing: 10) {
                WorkspaceAppIcon(icon: model.icons[app.bundleID], name: app.name, bundleID: app.bundleID, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).foregroundStyle(.white).lineLimit(1)
                    if app.running { Text("Open, with no window to show").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                }
                Spacer()
                Text("Open…").font(.callout.weight(.semibold)).foregroundStyle(workspaceAccent)
            }
            .padding(8)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.appOpening?.bundleID == app.bundleID && model.appOpening?.isWaiting == true)
        .accessibilityLabel(app.running ? String(localized: "\(app.name), open with no window to show") : app.name)
        .accessibilityHint("Asks before opening it on the Mac")
        .accessibilityInputLabels(["Open \(app.name)", app.name])
    }

    private func openTitle(_ app: WorkspacePickerSearch.AppToOpen) -> String {
        app.running ? String(localized: "\(app.name) has no window you can show. Open a new one on \(macName)?")
                    : String(localized: "Open \(app.name) on \(macName)?")
    }

    private func openMessage(_ app: WorkspacePickerSearch.AppToOpen) -> String {
        if !canOpenApps {
            if model.controlState() == .requestsDisabled {
                return String(localized: "\(macName) doesn’t accept control requests from this device, so apps can’t be opened from here.")
            }
            return model.replacingTile != nil
                ? String(localized: "Opening apps needs control of the Mac. Once the Mac allows it, \(app.name) opens and its window goes in this tile.")
                : String(localized: "Opening apps needs control of the Mac. Once the Mac allows it, \(app.name) opens and its window shows here.")
        }
        return model.replacingTile != nil
            ? String(localized: "Its window goes in this tile; nothing else in your layout changes. It opens without coming to the front on the Mac.")
            : String(localized: "Its window shows here when it opens. It opens without coming to the front on the Mac.")
    }

    /// The app opening now: what it's waiting for, and Cancel.
    private func openingStatus(_ o: WorkspaceAppOpening) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText(o)).foregroundStyle(.white)
                Text(o.tile != nil ? "Its window goes in this tile." : "Its window shows here when it opens.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Cancel") { model.dismissAppOpening() }.buttonStyle(.bordered)
                .accessibilityLabel(String(localized: "Stop opening \(o.name)"))
        }
        .padding(10)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func statusText(_ o: WorkspaceAppOpening) -> String {
        if o.phase == .awaitingControl {
            return model.controlState() == .requesting
                ? String(localized: "Waiting for \(macName) to allow control. \(o.name) opens then.")
                : String(localized: "Requesting control to open \(o.name)…")
        }
        return model.appOpeningSlow ? String(localized: "\(o.name) is taking a while to open…")
                                    : String(localized: "Opening \(o.name) on \(macName)…")
    }
}

/// Several new windows after opening an app from the picker: which one goes in the tile. Never
/// chosen for the person; Cancel leaves the tile as it was.
private struct OpenedWindowChoice: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        let windows: [CatalogWindowItem]? = { if case .choosing(let ws) = model.appOpening?.phase { return ws }; return nil }()
        let round = model.appOpeningRound
        content.confirmationDialog(model.appOpening.map { String(localized: "Which \($0.name) window?") } ?? "",
                                   isPresented: Binding(get: { windows != nil },
                                                        // Dismissed without a choice (a tap outside): stop, after any pick.
                                                        set: { if !$0 { DispatchQueue.main.async { model.dismissAppOpening(round: round) } } }),
                                   titleVisibility: .visible, presenting: windows) { ws in
            ForEach(ws) { w in
                Button(w.title.isEmpty ? String(localized: "Untitled Window") : w.title) { model.pickOpenedWindow(w) }
            }
            Button("Cancel", role: .cancel) { model.dismissAppOpening() }
        } message: { _ in
            Text(model.appOpening?.pickWasStale == true ? "That window closed. Choose another."
                 : "It opened more than one window. Choose the one to show.")
        }
    }
}

/// An app opening from the picker that didn't end with its window in the tile: what happened,
/// Try Again (or Request Control), Choose a Window (searches for the app), or Cancel.
private struct AppOpeningFailureAlert: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    let macName: String
    let onChooseWindow: (String) -> Void

    func body(content: Content) -> some View {
        let opening = model.appOpening
        let failure: WorkspaceAppOpening.Failure? = { if case .failed(let f) = opening?.phase { return f }; return nil }()
        let round = model.appOpeningRound
        let name = opening?.name ?? ""
        content.alert(failure.map { title($0, name) } ?? "",
                      isPresented: Binding(get: { failure != nil },
                                           set: { if !$0 { DispatchQueue.main.async { model.dismissAppOpening(round: round) } } }),
                      presenting: failure) { f in
            if f.retryable, model.controlState() != .requestsDisabled {
                Button([.controlDenied, .controlEnded].contains(f) ? String(localized: "Request Control Again") : String(localized: "Try Again")) {
                    model.retryAppOpening()
                }
            }
            Button("Choose a Window") { model.dismissAppOpening(); onChooseWindow(name) }
            Button("Cancel", role: .cancel) { model.dismissAppOpening() }
        } message: { f in
            Text(message(f, name))
        }
    }

    private func title(_ f: WorkspaceAppOpening.Failure, _ name: String) -> String {
        switch f {
        case .launchFailed: return String(localized: "Couldn’t Open \(name)")
        case .noAnswer: return String(localized: "\(name) Didn’t Open")
        case .noWindow: return String(localized: "No \(name) Window to Show")
        case .controlDenied: return String(localized: "Control Wasn’t Allowed")
        case .controlEnded: return String(localized: "Control Ended")
        case .tileChanged: return String(localized: "The Tile Changed")
        case .disconnected: return String(localized: "Disconnected")
        }
    }

    private func message(_ f: WorkspaceAppOpening.Failure, _ name: String) -> String {
        switch f {
        case .launchFailed:
            return String(localized: "\(macName) couldn’t open \(name). Try again, or choose a window instead.")
        case .noAnswer:
            return String(localized: "\(macName) didn’t answer. Check that this device still has control, then try again.")
        case .noWindow:
            return String(localized: "\(name) is open on \(macName), but no window you can show here appeared. Try again to ask it for a window, or choose a window instead.")
        case .controlDenied:
            return model.controlState() == .requestsDisabled
                ? String(localized: "\(macName) doesn’t accept control requests from this device, so \(name) wasn’t opened.")
                : String(localized: "\(name) wasn’t opened: opening apps needs control of the Mac.")
        case .controlEnded:
            return String(localized: "Control of \(macName) ended before \(name) opened, so it may not have opened.")
        case .tileChanged:
            return String(localized: "That tile changed or was removed while \(name) was opening, so nothing was put there. If \(name) opened, you can choose its window.")
        case .disconnected:
            return String(localized: "The connection to \(macName) ended while \(name) was opening.")
        }
    }
}

private struct OverviewCard: View {
    let window: CatalogWindowItem
    let thumbnail: CGImage?
    let icon: CGImage?
    let current: Bool
    let onPick: () -> Void
    let onAdd: (() -> Void)?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(Color(white: 0.17))
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                    else if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 40, height: 40) }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let paused = window.pausedBadge {
                        Text(paused).font(.caption2).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(workspaceChip, in: RoundedRectangle(cornerRadius: 6)).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let onAdd {
                        Button("Add", action: onAdd).font(.caption).buttonStyle(.borderedProminent).padding(6)
                            .accessibilityLabel("Add \(window.app) as a new tile")
                    }
                }
                HStack(spacing: 6) {
                    if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 18, height: 18) }
                    VStack(alignment: .leading) {
                        Text(window.title.isEmpty ? window.app : window.title).font(.callout).foregroundStyle(.white).lineLimit(1)
                        if !window.title.isEmpty { Text(window.app).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    }
                }
                .padding(8)
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? workspaceAccent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.app): \(window.title.isEmpty ? "untitled window" : window.title)" + (window.pausedSpoken.map { ", \($0)" } ?? ""))
        .accessibilityValue(current ? "Showing" : "")
        .addAsTileAction(window.app, onAdd)
    }
}

/// Layout choices that fit this screen, drawn as their shapes.
struct WorkspacePresetsView: View {
    let capacity: Int
    let tileCount: Int
    let onPick: (WorkspacePreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(WorkspacePreset.available(capacity: capacity), id: \.self) { preset in
                    let ids = (0..<preset.slotCount).map { "s\($0)" }
                    let layout = WorkspaceLayout(root: preset.node(tiles: ids), tiles: Dictionary(uniqueKeysWithValues: ids.map { ($0, WorkspaceTile(id: $0)) }))
                    let slots = WorkspaceGeometry.frames(for: layout, in: WorkspaceSize(width: 160, height: 100)).slots
                    Button { onPick(preset) } label: {
                        Canvas { ctx, size in
                            for r in slots {
                                let rect = CGRect(x: r.x * size.width + 2, y: r.y * size.height + 2, width: r.width * size.width - 4, height: r.height * size.height - 4)
                                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(preset.slotCount == tileCount ? workspaceAccent : .white.opacity(0.75)), lineWidth: 1.5)
                            }
                        }
                        .frame(width: 52, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Layout: \(preset.title)")
                    .accessibilityAddTraits(preset.slotCount == tileCount ? .isSelected : [])
                }
            }
        }
    }
}

/// After an app is dropped on a pane: which of its windows (several), or open it on the Mac
/// (none; needs control). Nothing opens or moves until the person picks.
struct WorkspaceAppDropDialogs: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    var onRequestControl: () -> Void

    func body(content: Content) -> some View {
        let d = model.appDrop
        content.confirmationDialog(title(d), isPresented: Binding(get: { model.appDrop != nil }, set: { if !$0 { model.cancelAppDrop() } }),
                                   titleVisibility: .visible, presenting: d) { d in
            if !d.windows.isEmpty {
                ForEach(d.windows) { w in
                    Button(w.title.isEmpty ? String(localized: "Untitled Window") : w.title) { model.completeAppDrop(d, with: w) }
                }
            } else if model.inputAllowed() {
                Button("Open on Mac") { model.launchForAppDrop(d) }
            } else {
                Button("Request Control") { model.cancelAppDrop(); onRequestControl() }
            }
            Button("Cancel", role: .cancel) { model.cancelAppDrop() }
        } message: { d in
            if d.windows.isEmpty {
                Text(model.inputAllowed() ? "Its first new window goes where you dropped it." : "Opening apps needs control of the Mac.")
            }
        }
    }

    private func title(_ d: WorkspaceModel.AppDrop?) -> String {
        guard let d else { return "" }
        if !d.windows.isEmpty { return String(localized: "Which \(d.app.name) window?") }
        return d.app.running ? String(localized: "\(d.app.name) has no windows you can show. Open a new one on the Mac?")
                             : String(localized: "Open \(d.app.name) on the Mac?")
    }
}

/// From Extend, a tap, pick or drop that would start Window view asks first, and says what
/// happens: this device's extended display goes away and macOS moves the windows on it.
struct WorkspaceLeaveExtendConfirmation: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        content.alert("Switch to Window View?",
                      isPresented: Binding(get: { model.leaveExtendRequest != nil }, set: { if !$0 { model.cancelLeavingExtend() } })) {
            Button("Switch to Window View") { model.confirmLeavingExtend() }
            Button("Stay in Extend", role: .cancel) { model.cancelLeavingExtend() }
        } message: {
            Text("This device stops extending your Mac. The extended display goes away, and macOS moves the windows on it to your Mac's other displays.")
        }
    }
}

/// While a window or a pane label is dragged: the highlighted landing area with what will
/// happen there, and a Cancel zone (drop on it and nothing changes). Window mode shows it over
/// the panes; Mirror/Extend over the desktop (a window dropped there joins it in Window mode).
/// Moving a whole pane that is already in the layout also offers Remove from Layout beside Cancel.
struct WorkspaceDropOverlay: View {
    @ObservedObject var model: WorkspaceModel
    /// The picture, in this view's coordinates.
    let picture: CGRect
    /// The screen's safe area in this view's coordinates (nil: all of it). The chip and the drop
    /// bar stay inside it: clear of the notch, the Dynamic Island and the Home indicator.
    var safeArea: CGRect? = nil
    /// The receiver's controls (and the keyboard) in this view's coordinates: the drop bar sits
    /// above any it would cover (`WorkspaceOverlayPlacement.bottomBar`).
    var controls: [CGRect] = []
    /// Pane titles and floats' title pills: the chip slides or steps aside from them.
    var titles: [CGRect] = []
    /// Where the chip is drawn, for the first-use tip to keep clear of it.
    var onChipFrame: ((CGRect) -> Void)? = nil
    @State private var lastKey = ""
    @State private var chipSize: CGSize?
    @State private var barSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let d = model.drag {
                let target = model.dropTarget(forGlobal: d.location)
                if let target { preview(target, item: d.item) }
                if d.placement == .float, let f = model.floatDropPreview(forGlobal: d.location) { floatPreview(f) }
                // A float being docked shows it too: circling again turns it back into the float.
                if model.canPlace(d.item, .float) || d.placement == .float || d.isFloat { placementChip(d) }
                // Circling toward the other placement: a ring that fills just above the finger.
                if model.placementSwitchProgress > 0, model.pictureGlobal.width > 0 {
                    WorkspacePlacementRing(progress: model.placementSwitchProgress, toFloating: d.placement == .pane)
                        .position(x: d.location.x - model.pictureGlobal.minX + picture.minX,
                                  y: d.location.y - model.pictureGlobal.minY + picture.minY - WorkspacePlacementRing.lift)
                }
                let removable = model.canDropToRemove
                let floatable = model.canDropToFloat
                // Inside the safe area and above the receiver's controls (the Settings gear sat on
                // Float, iPhone QA 2026-11-06). The zones report where they are drawn, so what a
                // release does follows the bar wherever it sits.
                let bar = dropBarFrame
                HStack(spacing: 12) {
                    cancelZone(over: model.overCancelZone(d.location), short: removable || floatable)
                    if floatable { floatZone(over: model.overFloatZone(d.location)) }
                    if removable { removeZone(over: model.overRemoveZone(d.location), float: d.isFloat) }
                }
                .padding(.horizontal, 12)
                .background(GeometryReader { g in
                    Color.clear.onAppear { barSize = g.size }.onChange(of: g.size) { barSize = $0 }
                })
                .frame(maxWidth: WorkspaceOverlayPlacement.usable(picture: picture, safe: safeArea).width)
                .position(x: bar.midX, y: bar.midY)
                #if DEBUG
                .onChange(of: bar) { b in
                    Log.info("notchTrace: dragHUD picture=\(picture) safe=\(safeArea.map { "\($0)" } ?? "none") "
                             + "bar=\(b) controls=\(controls)")
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: key) { k in
            if !k.isEmpty, k != lastKey { Self.tick() }
            lastKey = k
        }
        .onChange(of: model.drag == nil) { ended in
            if ended { model.cancelZoneGlobal = .zero; model.removeZoneGlobal = .zero; model.floatZoneGlobal = .zero }
        }
    }

    /// Changes whenever the landing under the finger changes (one haptic tick each).
    private var key: String {
        guard let d = model.drag else { return "" }
        if model.overCancelZone(d.location) { return "cancel" }
        if model.overRemoveZone(d.location) { return "remove" }
        if model.overFloatZone(d.location) { return "float" }
        if d.placement == .float { return "floating" }
        return model.dropTarget(forGlobal: d.location).map { "\($0)" } ?? ""
    }

    private func preview(_ target: WorkspaceWindowDrop, item: WorkspaceDrag.Item) -> some View {
        let r = target.preview.onScreen(picture)
        let text: String = {
            switch target {
            case .replace:
                if case .pane = item { return String(localized: "Swap") }
                if model.windowMode { return String(localized: "Replace") }
                if case .replace(let tile, _) = target, tile == WorkspaceModel.noDesktop { return String(localized: "Show in Window Mode") }
                return String(localized: "Show Instead of Desktop")
            case .tab(let t, _):
                if case .pane(let p, let tab?) = item, p == t, tab >= 0 { return String(localized: "Move Tab Here") }
                return String(localized: "Add as Tab")
            case .split: return String(localized: "New Pane")
            case .emptySlot: return String(localized: "Show Here")
            }
        }()
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(workspaceAccent.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(workspaceAccent, lineWidth: 2))
            .overlay(Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(workspaceChip, in: Capsule()))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: r)
            .accessibilityHidden(true)
    }

    /// Floating placement: where the window will float, at its own shape. Dashed, unfilled, so it
    /// never looks like a pane drop (a filled blue area).
    private func floatPreview(_ f: WorkspaceRect) -> some View {
        let r = f.onScreen(picture)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.18)))
            .overlay(Text("Float Here").font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(workspaceChip, in: Capsule()))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: r)
            .accessibilityHidden(true)
    }

    /// Where the drop bar sits: centred at the bottom as before, kept above the Home indicator and
    /// the controls. Until it is measured, a phone-wide guess, so it never flashes under the gear.
    private var dropBarFrame: CGRect {
        let usable = WorkspaceOverlayPlacement.usable(picture: picture, safe: safeArea)
        return WorkspaceOverlayPlacement.bottomBar(
            size: barSize ?? CGSize(width: min(usable.width, 420), height: 44),
            preferredMidY: picture.maxY - WorkspaceOverlayPlacement.dropBarLift,
            picture: picture, safe: safeArea, avoiding: controls)
    }

    /// Pane or Floating: what a release does now. Circling while holding switches it. Below the
    /// notch, the Dynamic Island and the status bar, beside or below the titles at the top.
    private func placementChip(_ d: WorkspaceDrag) -> some View {
        let floating = d.placement == .float
        let frame = WorkspaceOverlayPlacement.chip(size: chipSize ?? CGSize(width: 240, height: 30),
                                                   picture: picture, safe: safeArea, avoiding: titles)
        return HStack(spacing: 6) {
            Image(systemName: floating ? "macwindow.on.rectangle" : "rectangle.split.2x1").accessibilityHidden(true)
            Text(floating ? "Floating" : "Pane").fontWeight(.semibold)
            Text("· Circle to switch").foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(floating ? Color(white: 0.16, opacity: 0.92) : workspaceChip))
        .overlay(Capsule().stroke(Color.white.opacity(floating ? 0.7 : 0.3), lineWidth: 1))
        .background(GeometryReader { g in
            Color.clear.onAppear { chipSize = g.size }.onChange(of: g.size) { chipSize = $0 }
        })
        .position(x: frame.midX, y: frame.midY)
        .onAppear { onChipFrame?(frame) }
        .onChange(of: frame) { onChipFrame?($0) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: floating)
        .accessibilityHidden(true)
    }

    /// Release here to float the window instead (no circling needed).
    private func floatZone(over: Bool) -> some View {
        dropZone(over ? String(localized: "Release to Float") : String(localized: "Float"),
                 symbol: "macwindow.on.rectangle", over: over,
                 fill: over ? Color(white: 0.42, opacity: 0.92) : Color.black.opacity(0.62)) {
            model.floatZoneGlobal = $0
        }
    }

    /// `short`: beside Remove from Layout, so both fit a narrow phone.
    private func cancelZone(over: Bool, short: Bool) -> some View {
        let text = over ? String(localized: "Release to Cancel")
            : (short ? String(localized: "Cancel") : String(localized: "Drop Here to Cancel"))
        // Beside Remove, Cancel lights neutral so the two never look alike.
        return dropZone(text, symbol: "xmark.circle.fill", over: over,
                        fill: over ? (short ? Color(white: 0.42, opacity: 0.92) : Color.red.opacity(0.85)) : Color.black.opacity(0.62)) {
            model.cancelZoneGlobal = $0
        }
    }

    /// Takes the pane out of this device's layout, or a float being docked off this device (the
    /// float menu's own Remove from This Device). Never closes, minimizes or quits the Mac window.
    private func removeZone(over: Bool, float: Bool) -> some View {
        dropZone(over ? String(localized: "Release to Remove")
                      : (float ? String(localized: "Remove from This Device") : String(localized: "Remove from Layout")),
                 symbol: "rectangle.badge.minus", over: over,
                 fill: over ? Color.red.opacity(0.85) : Color(red: 0.35, green: 0.06, blue: 0.06, opacity: 0.72)) {
            model.removeZoneGlobal = $0
        }
    }

    private func dropZone(_ text: String, symbol: String, over: Bool, fill: Color,
                          frame report: @escaping (CGRect) -> Void) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.85)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(Color.white.opacity(over ? 0.9 : 0.35), lineWidth: 1))
            .scaleEffect(over && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: over)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { report(g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { report($0) }
            })
            .accessibilityHidden(true)
    }

    private static func tick() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// A rectangle with its own radius per corner (outer screen corners round, inner ones square).
struct PaneOutlineShape: InsettableShape {
    var topLeading: CGFloat = 0
    var topTrailing: CGFloat = 0
    var bottomTrailing: CGFloat = 0
    var bottomLeading: CGFloat = 0
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let cap = min(r.width, r.height) / 2
        func radius(_ v: CGFloat) -> CGFloat { min(max(v - inset, 0), cap) }
        let tl = radius(topLeading), tr = radius(topTrailing), br = radius(bottomTrailing), bl = radius(bottomLeading)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> PaneOutlineShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    /// The screen in global coordinates (nil off iOS).
    static var screenBounds: CGRect? {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds
        #else
        return nil
        #endif
    }

    /// The phone's screen-corner radius. There is no public API for it: Face ID iPhones (a home
    /// indicator inset) are close to an eighth of the short side; home-button phones are square.
    static var screenCornerRadius: CGFloat {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first, window.safeAreaInsets.bottom > 0 else { return 0 }
        if UIDevice.current.userInterfaceIdiom == .pad { return 18 }
        let short = min(scene.screen.bounds.width, scene.screen.bounds.height)
        return min(max(short * 0.125, 39), 62)
        #else
        return 0
        #endif
    }
}

// MARK: - Pane menu bar (PROTOCOL.md 6.13)

/// Redraws `content` when the menu bar's own state changes (`WorkspaceModel` doesn't republish it).
struct AppMenuObserver<Content: View>: View {
    @ObservedObject var menus: AppMenuModel
    let content: (AppMenuModel) -> Content

    init(menus: AppMenuModel, @ViewBuilder content: @escaping (AppMenuModel) -> Content) {
        self.menus = menus
        self.content = content
    }

    var body: some View { content(menus) }
}

/// The focused pane's app menus (File, Edit, …) as a slim bar in the pane's top row, after its
/// labels; a title opens its menu as a drop-down here. Pressing an item presses it on the Mac.
struct PaneMenuBar: View {
    @ObservedObject var menus: AppMenuModel
    /// The pane, clear of the screen's unsafe edges.
    let pane: CGRect
    let top: CGFloat
    let bounds: CGRect
    @State private var titleFrames: [Int: CGRect] = [:]

    private static let height: CGFloat = 28

    var body: some View {
        if menus.barShown, menus.tile != nil, pane.width >= 120 {
            ZStack(alignment: .topLeading) {
                if !menus.open.isEmpty {
                    // Tap anywhere else to close; nothing reaches the Mac while a menu is open.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { menus.close() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                bar
                    .frame(width: pane.width - 12, height: Self.height)
                    .offset(x: pane.minX + 6, y: top)
                if let level = menus.open.last {
                    let anchor = titleFrames[level.path.first ?? -1]?.minX ?? pane.minX + 6
                    let width: CGFloat = 270
                    let y = top + Self.height + 4
                    dropDown(level)
                        .frame(width: width)
                        .frame(maxHeight: max(120, min(460, bounds.maxY - y - 8)), alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: min(max(anchor, bounds.minX + 6), bounds.maxX - width - 6), y: y)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        }
    }

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // The app's own menu comes first and is bold, as on a Mac; its name alone while loading or unavailable.
                if !menus.app.isEmpty, menus.top.isEmpty {
                    Text(menus.app).font(.caption.weight(.bold)).padding(.horizontal, 8)
                }
                if let error = menus.topError {
                    Text(Self.message(error)).font(.caption).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 8)
                } else if menus.top.isEmpty {
                    ProgressView().scaleEffect(0.6).padding(.horizontal, 8)
                }
                ForEach(menus.top) { item in
                    Button { menus.openMenu(item) } label: {
                        Text(item.title).font(item.id == menus.top.first?.id ? .caption.weight(.bold) : .caption)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(menus.open.first?.path == [item.index] ? workspaceAccent.opacity(0.85) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { titleFrames[item.index] = g.frame(in: .named("workspace")) }
                            .onChange(of: g.frame(in: .named("workspace"))) { titleFrames[item.index] = $0 }
                    })
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 2)
        }
        .background(workspaceChip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(menus.app) menus"))
    }

    private func dropDown(_ level: AppMenuModel.Level) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if menus.open.count > 1 {
                Button { menus.back() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold)).accessibilityHidden(true)
                        Text(level.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back from \(level.title)"))
                .accessibilityInputLabels([Text("Back")])
                Divider().overlay(Color.white.opacity(0.2))
            }
            if level.loading {
                ProgressView().frame(maxWidth: .infinity).padding(16)
            } else if let error = level.error {
                Text(Self.message(error)).font(.footnote).foregroundStyle(.white.opacity(0.75)).padding(14)
            } else if level.items.isEmpty {
                Text("No items").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(level.items) { item in row(item) }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let failed = menus.failed {
                Text(Self.message(failed)).font(.caption2).foregroundStyle(.orange).padding(10)
            }
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    @ViewBuilder
    private func row(_ item: AppMenuEntry) -> some View {
        if item.separator {
            Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 4)
        } else {
            Button { item.hasSubmenu ? menus.openSubmenu(item) : menus.press(item) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).opacity(item.checked ? 1 : 0).frame(width: 14)
                        .accessibilityHidden(true)
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let key = item.shortcut { Text(key).font(.caption).foregroundStyle(.white.opacity(0.55)) }
                    if item.hasSubmenu { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
                .opacity(item.enabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!item.enabled)
            .accessibilityAddTraits(item.checked ? .isSelected : [])
            .accessibilityHint(item.hasSubmenu ? Text("Opens a submenu.") : Text(""))
        }
    }

    static func message(_ error: String) -> String {
        switch error {
        case "accessibility": return String(localized: "Allow Accessibility for MeowDisplay on the Mac to use menus.")
        case "control": return String(localized: "Menus need control of the Mac.")
        case "changed": return String(localized: "That menu changed on the Mac. Try again.")
        default: return String(localized: "This app's menus aren't available.")
        }
    }
}

/// The pane menu's measured height, so it is placed fully on screen.
private struct PaneMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Circling while holding a drag switches it between Pane and Floating: this ring, just above the
/// finger (where the finger doesn't hide it), fills as the loops add up and shows what it will
/// switch to. Decoration only: the placement chip and its haptic say what happened.
struct WorkspacePlacementRing: View {
    var progress: Double
    /// What it switches to: Floating (true) or Pane.
    var toFloating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let lift: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 4)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: toFloating ? "macwindow.on.rectangle" : "rectangle.split.2x1")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 46, height: 46)
        .shadow(color: .black.opacity(0.45), radius: 2)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fill Window on Mac / Restore Previous Size on Mac: waiting for the Mac, then what it did (8 s).
/// Shown at the bottom of the pane or float the item was chosen on.
struct WorkspaceWindowFrameStatus: View {
    @ObservedObject var model: WorkspaceModel
    let id: String

    var body: some View {
        if model.isResizingOnMac(id) {
            HStack(spacing: 6) {
                ProgressView().progressViewStyle(.circular).tint(.white).controlSize(.small)
                Text("Resizing the window on the Mac…").font(.caption).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
        } else if let notice = model.windowFrameNotice, notice.tile == id {
            Button { model.clearWindowFrameNotice() } label: {
                Label(notice.message, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.white).multilineTextAlignment(.leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Dismisses this message."))
            .accessibilityIdentifier("windowFrameNotice")
        }
    }
}
