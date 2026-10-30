import SwiftUI
import UIKit

/// MeowDisplay blue: the Stage Peek focus ring.
private let stagePeekAccent = meowAccent

/// Card ids for displays: the main display is `fullDesktopID`; others sit at the
/// top of the UInt32 range, where WindowServer window ids never reach.
enum StagePeekIDs {
    static func display(_ index: Int) -> UInt32 { index == 0 ? StagePeekMachine.fullDesktopID : 0xFFFF_FF00 + UInt32(index) }
    static func displayIndex(_ id: UInt32) -> Int? {
        if id == StagePeekMachine.fullDesktopID { return 0 }
        return id >= 0xFFFF_FF01 ? Int(id - 0xFFFF_FF00) : nil
    }
}

/// Stage Peek: hold the configured screen edge, scrub the floating window
/// stack, lift (nothing changes), tap a card to switch. Drawn above the video
/// and the controls; the picture underneath never moves or resizes.
///
/// Touch ownership: while closed only the edge strip takes touches; while
/// open the whole overlay does. SwiftUI hit testing keeps all of them away
/// from the video view, so nothing Stage Peek handles reaches the Mac. The
/// rules live in `StagePeekMachine` (unit tested).
struct StagePeekOverlay: View {
    @ObservedObject var model: WorkspaceModel
    let edge: StagePeekEdge
    /// The picture area in the parent's coordinates.
    let frame: CGRect
    /// The safe part of `frame`, in overlay coordinates.
    let safe: CGRect
    /// Controls and hinges the strip must stay clear of, in overlay coordinates.
    let avoiding: [CGRect]
    let hapticsEnabled: Bool
    var naturalScrolling = true
    /// Compact: the stack stays in a fading band between the controls above and below.
    var dock: StagePeekDockStyle = .compact
    /// Whether this session may change the Mac ("Open on Mac", Close Window).
    var inputAllowed = false
    /// A display card was tapped (Full Desktop or another Mac display).
    let onDisplay: (CatalogDisplayItem?) -> Void

    @State private var machine = StagePeekMachine()
    @State private var query = ""
    @Environment(\.controlRequest) private var controlRequest
    @State private var appFilter: String?
    @State private var launchpad = false
    /// The apps bar: widened by a scroll, rows added by pulling it down (reset when the peek closes).
    @State private var dockWide = false
    @State private var dockRows = 1
    @State private var hint = false
    @State private var overlayOrigin: CGPoint = .zero
    @FocusState private var searchFocused: Bool
    @State private var stripDown = false
    @State private var openDown = false
    @State private var openTouch = 0
    /// Compact peek: holding a card still lifts it so it can be dragged onto a pane.
    @State private var holdTask: Task<Void, Never>?
    @State private var cardDragging = false
    @State private var openStart: CGPoint = .zero
    @GestureState private var stripPressing = false
    @GestureState private var openPressing = false
    @State private var pollTask: Task<Void, Never>?
    @State private var haptics = StagePeekHaptics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The compact stack's windows: the chosen app's, matching the search.
    private var windows: [CatalogWindowItem] {
        let all = (model.catalog?.windows ?? []).filter { appFilter == nil || $0.bundleID == appFilter }
        return query.isEmpty ? all : WorkspaceSearch.search(query, apps: [], windows: all).windows
    }
    private var displays: [CatalogDisplayItem] { model.catalog?.displays ?? [] }
    /// Finder first, running apps next, then every installed app. Falls back to the running
    /// apps from the window catalog until the Mac's app list arrives.
    private var dockApps: [MacAppItem] {
        if !model.apps.isEmpty { return model.apps }
        let running = (model.catalog?.apps ?? []).map { a in
            MacAppItem(bundleID: a.bundleID, name: a.name, running: true,
                       windowCount: model.catalog?.windows.filter { $0.bundleID == a.bundleID }.count ?? 0, lastUsed: nil)
        }
        return WorkspaceSearch.carouselOrder(running)
    }
    private var filterApp: MacAppItem? { appFilter.flatMap { b in dockApps.first { $0.bundleID == b } } }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Roomier chrome when the window is regular in both directions (a full iPad, an unfolded
    /// iPhone Duo), whatever the device; a phone in landscape stays compact.
    private var roomy: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }

    var body: some View {
        let cards = revealShifted(layout())
        ZStack(alignment: .topLeading) {
            if machine.isVisible {
                backdrop
                    .contentShape(Rectangle())
                    .gesture(openGesture(cards: cards))
                    // Barely there (not 0) while dragging, so the finger's gesture keeps its view.
                    .opacity(model.drag != nil ? 0.001 : 1)
                    .transition(.opacity)
                if machine.expansion < 0.999 {
                    ZStack(alignment: .topLeading) {
                        ForEach(cards, id: \.index) { card in
                            cardView(card)
                                .opacity(model.drag != nil ? 0 : 1 - machine.expansion)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: edge == .left ? -48 : 48)))
                        }
                    }
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    // Compact Dock: cards fade and clip at the band's edges, never under the controls.
                    .mask(alignment: .topLeading) { dockMask }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: machine.closeRevealed)
                    if machine.expansion < 0.5, model.drag == nil, let focus = cards.first(where: \.highlighted) {
                        title(for: focus)
                    }
                    if machine.expansion < 0.5, model.drag == nil, let id = machine.closeRevealed,
                       let i = machine.ids.firstIndex(of: id), let card = cards.first(where: { $0.index == i }),
                       let w = windows.first(where: { $0.id == id }) {
                        compactCloseButton(w, card: card)
                    }
                }
                if machine.expansion > 0.001 {
                    gallery
                        .opacity(model.drag != nil ? 0 : machine.expansion)
                        .allowsHitTesting(machine.expanded)
                }
                toolbar(cards: cards)
                    .opacity(model.drag != nil ? 0 : 1)
                    .transition(.opacity)
                if let notice = model.closeNotice {
                    closeToast(notice)
                }
                topControls
                    .opacity(model.drag != nil ? 0 : 1)
                    .transition(.opacity)
            }
            if launchpad {
                launchpadView.transition(.opacity)
            }
            RemoteFinderHost(files: model.files, workspace: model, inputAllowed: inputAllowed,
                             safe: safe, onFinderWindows: { showFinderWindows() })
                .zIndex(45)
            if model.drag != nil, !model.windowMode {
                // Mirror/Extend: the desktop is one pane; landing areas and Cancel show over it.
                // (Window mode: the pane view draws them. Drawing them here too showed two
                // "Drop Here to Cancel" zones, owner report 2026-10-31.)
                WorkspaceDropOverlay(model: model, picture: CGRect(origin: .zero, size: frame.size)).zIndex(55)
            }
            if let d = model.drag, case .window(let w) = d.item {
                // The card under the finger while the peek steps aside to show the panes.
                dragPreview(w)
                    .position(x: d.location.x - overlayOrigin.x, y: d.location.y - overlayOrigin.y)
                    .allowsHitTesting(false)
                    .zIndex(60)
            } else if let d = model.drag, case .app(let a) = d.item {
                MacAppIcon(model: model, bundleID: a.bundleID, name: a.name, size: 56)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                    .position(x: d.location.x - overlayOrigin.x, y: d.location.y - overlayOrigin.y)
                    .allowsHitTesting(false)
                    .zIndex(60)
            }
            if !machine.ids.isEmpty, !model.overviewOpen, !launchpad,
               let strip = StagePeekLayout.strip(edge: edge, safe: safe, avoiding: avoiding) {
                stripView(strip, cards: cards)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { overlayOrigin = g.frame(in: .global).origin; model.desktopPictureGlobal = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { overlayOrigin = $0.origin; model.desktopPictureGlobal = $0 }
        })
        .coordinateSpace(name: "stagePeek")
        .accessibilityAction(.escape) { finish(machine.dismiss()) }
        .position(x: frame.midX, y: frame.midY)
        .ignoresSafeArea(.keyboard)   // the search keyboard never resizes (or closes) the peek
        .onAppear { machine.naturalScrolling = naturalScrolling; syncItems(); playHint() }
        .onChange(of: naturalScrolling) { machine.naturalScrolling = $0 }
        // Every new opening starts unfiltered: all windows, no app selected, no search; the
        // Compact/Normal and layout preferences are kept. Dismissal clears them too.
        .onChange(of: model.stagePeekOpen) { _ in query = ""; appFilter = nil; launchpad = false }
        .onChange(of: windows) { _ in syncItems() }
        .onChange(of: displays) { _ in syncItems() }
        .onChange(of: model.currentWindowID) { _ in syncItems() }
        .onChange(of: model.available) { available in if !available { cancelAll() } }
        .onChange(of: model.overviewOpen) { open in if open { cancelAll() } }
        // Searching needs room: typing opens the gallery instead of closing anything.
        .onChange(of: searchFocused) { focused in if focused, machine.isVisible, !machine.expanded { animate { machine.expand() } } }
        .onChange(of: query) { q in if !q.isEmpty, machine.isVisible, !machine.expanded { animate { machine.expand() } } }
        .onChange(of: machine.isVisible) { visible in if !visible { searchFocused = false; model.thumbnailPriority = [] } }
        .onChange(of: launchpad) { open in model.launchpadOpen = open }
        // Rotation, fold, Split View, Stage Manager resize: a width change. A keyboard only changes the height.
        .onChange(of: frame.size.width) { _ in if !searchFocused { cancelAll() } }
        .onChange(of: edge) { _ in cancelAll() }
        .onChange(of: stripPressing) { pressing in if !pressing { detectCancel(strip: true) } }
        .onChange(of: openPressing) { pressing in if !pressing { detectCancel(strip: false) } }
        .onDisappear { cancelAll() }
    }

    // MARK: Geometry

    private func layout() -> [StagePeekCard] {
        let aspects = machine.ids.map { id -> Double in
            if id == StagePeekMachine.fullDesktopID { return 1.6 }
            guard let w = windows.first(where: { $0.id == id }), w.width > 0, w.height > 0 else { return 1.5 }
            return Double(w.width) / Double(w.height)
        }
        return StagePeekLayout.cards(aspects: aspects, position: machine.position, expansion: machine.expansion,
                                     edge: edge, safe: safe, isPad: roomy, reduceMotion: reduceMotion, region: dockRegion)
    }

    /// The Compact Dock's band: under the search and app carousel, above the buttons.
    private var dockRegion: CGRect? {
        guard dock == .compact else { return nil }
        let compactWidth = min(max(safe.width * (roomy ? 0.24 : 0.36), 110), roomy ? 300 : 210)
        let column = edge == .left ? safe.minX + 16 + compactWidth / 2 : safe.maxX - 16 - compactWidth / 2
        return StagePeekLayout.dockRegion(safe: safe, controlsAbove: safe.minY + Self.topControlsBottom,
                                          controlsBelow: toolbarY(column) - Self.toolbarHalfHeight)
    }

    /// Hit testing for the compact stack: only inside the Compact Dock's band.
    private var hitRegion: CGRect? { machine.expansion < 0.5 ? dockRegion : nil }

    private static let topControlsBottom: CGFloat = 12 + 42 + 10 + 64
    private static let toolbarHalfHeight: CGFloat = 20

    /// Opaque inside the band, fading over its top and bottom edges (Normal: everything shows).
    @ViewBuilder private var dockMask: some View {
        if let r = dockRegion, machine.expansion < 0.999 {
            let e = CGFloat(machine.expansion)
            // Expanding releases the band smoothly.
            let top = r.minY * (1 - e), bottom = r.maxY + (frame.height - r.maxY) * e
            let height = max(bottom - top, 1)
            let f = min(StagePeekConfig.dockFade / height, 0.4) * (1 - e)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: f),
                                   .init(color: .black, location: 1 - f), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: frame.width, height: height)
                .offset(y: top)
        } else {
            Color.black.frame(width: frame.width, height: frame.height)
        }
    }

    /// The card whose Close Window shows slides aside to make room for the button.
    private func revealShifted(_ cards: [StagePeekCard]) -> [StagePeekCard] {
        guard let id = machine.closeRevealed, let i = machine.ids.firstIndex(of: id) else { return cards }
        return cards.map { c in
            guard c.index == i else { return c }
            var moved = c
            moved.center.x -= Self.compactRevealWidth
            return moved
        }
    }

    private static let compactRevealWidth: CGFloat = 92

    /// Close Window beside a swiped compact card. Without control it says so instead.
    private func compactCloseButton(_ w: CatalogWindowItem, card: StagePeekCard) -> some View {
        let height = max(min(card.size.height, 96), 48)
        return Button {
            animate { machine.hideClose() }
            if inputAllowed { model.closeWindow(w) } else { controlRequest?.request() }   // never closes after a grant by itself
        } label: {
            VStack(spacing: 3) {
                Image(systemName: inputAllowed ? "xmark.square" : "lock").font(.system(size: 17, weight: .semibold))
                Text(inputAllowed ? String(localized: "Close Window") : (controlRequest?.gatedLabel ?? String(localized: "Needs Control")))
                    .font(.caption2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(width: Self.compactRevealWidth - 8, height: height)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(inputAllowed ? Color.red : Color.gray))
        }
        .buttonStyle(.plain)
        .position(x: card.center.x + card.size.width / 2 + Self.compactRevealWidth / 2, y: card.center.y)
        .transition(.opacity)
        .zIndex(9)
        .accessibilityLabel(inputAllowed ? String(localized: "Close Window \(w.title.isEmpty ? w.app : w.title)")
                                         : String(localized: "Close Window needs control. Request Control"))
    }

    /// What happened to the last Close Window, for a few seconds.
    private func closeToast(_ notice: WindowCloseNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            Text(notice.message).font(.footnote).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: min(460, safe.width - 32))
        .position(x: safe.midX, y: max(toolbarY(safe.midX) - 64, safe.minY + 160))
        .transition(.opacity)
        .zIndex(35)
        .accessibilityElement(children: .combine)
        .task(id: notice) {
            UIAccessibility.post(notification: .announcement, argument: notice.message)
            try? await Task.sleep(nanoseconds: notice.isError ? 6_000_000_000 : 3_000_000_000)
            if model.closeNotice == notice { withAnimation(.easeOut(duration: 0.2)) { model.closeNotice = nil } }
        }
        .onTapGesture { model.closeNotice = nil }
    }

    private func window(at index: Int) -> CatalogWindowItem? {
        guard machine.ids.indices.contains(index) else { return nil }
        let id = machine.ids[index]
        return windows.first { $0.id == id }
    }

    // MARK: Pieces

    /// Translucent depth behind the stack, strongest at the edge; the Mac
    /// stays visible. The expanded browser adds a light frost. Never opaque.
    private var backdrop: some View {
        let e = machine.expansion
        return ZStack {
            LinearGradient(colors: [Color.black.opacity(reduceTransparency ? 0.5 : 0.30), Color.black.opacity(0)],
                           startPoint: edge == .left ? .leading : .trailing,
                           endPoint: edge == .left ? .trailing : .leading)
                .frame(width: min(frame.width, (roomy ? 520 : 380) + e * frame.width))
                .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
            if e > 0 {
                // Expanded: a light blur of the Mac picture behind the gallery (the cards stay
                // sharp above it), plus a soft dim for legibility. Reduce Transparency: dim only.
                if reduceTransparency {
                    Color.black.opacity(0.66 * e)
                } else {
                    Rectangle().fill(.thinMaterial).environment(\.colorScheme, .dark).opacity(0.9 * e)
                    Color.black.opacity(0.18 * e)
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .accessibilityHidden(true)
    }

    private func cardView(_ card: StagePeekCard) -> some View {
        let window = window(at: card.index)
        let thumbnail = window.flatMap { model.thumbnails[$0.id] }
        let icon = window.flatMap { model.icons[$0.bundleID] }
        let shape = RoundedRectangle(cornerRadius: roomy ? 14 : 11, style: .continuous)
        let displayIndex = machine.ids.indices.contains(card.index) ? StagePeekIDs.displayIndex(machine.ids[card.index]) : nil
        let fullDesktop = displayIndex != nil
        let display = displayIndex.flatMap { displays.indices.contains($0) ? displays[$0] : nil }
        return ZStack {
            shape.fill(Color(white: 0.17))
            if fullDesktop, let still = display.flatMap({ model.displayThumbnails[$0.id] }) {
                Image(decorative: still, scale: 1).resizable().scaledToFill()
                Label(display?.isMain == false ? display?.name ?? "" : String(localized: "Full Desktop"), systemImage: "display")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
            } else if fullDesktop {
                VStack(spacing: 6) {
                    Image(systemName: "display").font(.title)
                    Text(display?.isMain == false ? display?.name ?? "" : String(localized: "Full Desktop")).font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
            } else if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
            } else if let icon {
                Image(decorative: icon, scale: 1).resizable().frame(width: 44, height: 44)
            } else {
                Image(systemName: "macwindow").font(.title2).foregroundStyle(Color.white.opacity(0.6))
            }
            if let icon, thumbnail != nil {
                // The app's icon at the card's bottom-left, like Stage Manager.
                Image(decorative: icon, scale: 1).resizable()
                    .frame(width: roomy ? 30 : 24, height: roomy ? 30 : 24)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
            }
            if let paused = window?.pausedBadge {
                Text(paused).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
            }
        }
        .frame(width: card.size.width, height: card.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(card.highlighted ? stagePeekAccent : Color.white.opacity(0.16),
                                    lineWidth: card.highlighted ? 2.5 : 1))
        .shadow(color: .black.opacity(card.highlighted ? 0.5 : 0.32), radius: card.highlighted ? 18 : 8, y: 6)
        // Same projection as StagePeekLayout.corners, so a tap lands on what is drawn.
        .rotation3DEffect(.degrees(card.tilt), axis: (x: 1, y: 0, z: 0), anchor: .center,
                          perspective: max(card.size.width, card.size.height) / StagePeekConfig.perspective)
        .opacity(card.opacity)
        .position(card.center)
        .zIndex(card.z)
        .allowsHitTesting(false)   // the backdrop hit-tests cards itself, tilt-aware
        .accessibilityElement()
        .accessibilityLabel(fullDesktop ? String(localized: "Full Desktop")
                            : window.map { w in w.title.isEmpty ? w.app : "\(w.app), \(w.title)" } ?? "")
        .accessibilityValue(window?.pausedSpoken ?? "")
        .accessibilityAddTraits(card.highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { finish(machine.select(index: card.index)) }
    }

    /// The floating search pill and the Dock-like app carousel: independent glass pieces,
    /// pinned at the top of the peek's column (compact) or centred over the gallery (expanded).
    private var topControls: some View {
        let e = machine.expansion
        let compactWidth = min(roomy ? 380 : 320, safe.width - 24)
        let wideWidth = min(roomy ? 620 : 560, safe.width - 32)
        let width = compactWidth + (wideWidth - compactWidth) * e
        let compactX = edge == .left ? safe.minX + 12 + compactWidth / 2 : safe.maxX - 12 - compactWidth / 2
        let x = compactX + (safe.midX - compactX) * e
        let barWidth = dockWide ? safe.width - 24 : width
        let barX = dockWide ? safe.midX : x
        // The grown bar stops above the Expand and Close buttons, so they stay visible and nobody
        // has to swipe up from the screen's bottom edge, where the Dock or Home bar takes it
        // (owner, 2026-10-31).
        let room = max(toolbarY(safe.midX) - Self.toolbarHalfHeight - 10 - (safe.minY + 12), 140)
        // Searching filters the apps bar too, at every size (owner, 2026-10-31).
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let barApps = searching ? WorkspaceSearch.search(query, apps: dockApps, windows: []).apps : dockApps
        return VStack(spacing: 10) {
            StagePeekSearchPill(query: $query, focused: $searchFocused)
                .frame(width: width)
            StagePeekDock(model: model, apps: barApps, selected: appFilter,
                          onApp: { a in if searching { query = ""; searchFocused = false }; tapApp(a) },
                          onDragEnded: { dropped in if dropped { animate { machine.cancelAll() }; model.stagePeekOpen = false } },
                          onLaunchpad: { searchFocused = false; withAnimation(.easeOut(duration: 0.2)) { launchpad = true } },
                          wide: $dockWide, rows: $dockRows, width: barWidth, maxHeight: room - 52,
                          noMatch: searching && barApps.isEmpty ? String(localized: "No apps match “\(query)”.") : nil)
                .frame(width: barWidth)
        }
        .frame(width: max(barWidth, width), height: room, alignment: .top)
        .position(x: dockWide ? barX : x, y: safe.minY + 12 + room / 2)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: dockWide)
        .onChange(of: machine.isVisible) { visible in if !visible { dockWide = false; dockRows = 1 } }
        .environment(\.colorScheme, .dark)
        .zIndex(30)
    }

    /// Expanded Stage Peek: every window (and display) as a vertical gallery, as many columns as
    /// fit. It sits between the search and app carousel and the buttons, fading at both edges, so
    /// no card ever passes under (or intercepts touches meant for) those controls.
    private var gallery: some View {
        let top = safe.minY + Self.topControlsBottom + 6
        let bottom = toolbarY(safe.midX) - Self.toolbarHalfHeight - 6
        let height = max(bottom - top, 140)
        return StagePeekGallery(model: model, query: query, appFilter: filterApp, inputAllowed: inputAllowed,
                         width: safe.width, topInset: 12,
                         onWindow: { w in pick(w) },
                         onDisplay: { d in pickDisplay(d) },
                         onApp: { a in query = ""; searchFocused = false; tapApp(a, forceFilter: true) },
                         onAddTile: { w in
                             haptics.play(.select, enabled: hapticsEnabled)
                             animate { machine.cancelAll() }
                             model.stagePeekOpen = false
                             model.choose(w, asNewTile: true)
                         },
                         onDragEnded: { dropped in
                             // Dropped on a pane: done. Dropped nowhere: the peek comes back as it was.
                             if dropped { animate { machine.cancelAll() }; model.stagePeekOpen = false }
                         },
                         onSearchFiles: model.files.available ? { q in searchFocused = false; model.files.open(query: q) } : nil,
                         // A flick toward the edge (off the cards) compacts the gallery again.
                         edge: edge, onCompact: { animate { machine.compact() } },
                         onEmptyTap: { searchFocused = false; finish(machine.dismiss()) }, height: height)
            .frame(width: safe.width, height: height)
            .mask {
                let f = min(18 / height, 0.3)
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: f),
                                       .init(color: .black, location: 1 - f), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .position(x: safe.midX, y: top + height / 2)
            .environment(\.colorScheme, .dark)
            .zIndex(5)
    }

    private var launchpadView: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.7 : 0.5).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { launchpad = false } }
            StagePeekLaunchpad(model: model, inputAllowed: inputAllowed,
                               onPick: { app in
                                   withAnimation(.easeOut(duration: 0.2)) { launchpad = false }
                                   if !machine.isVisible { finish(machine.openDirectly()) }
                                   tapApp(app, forceFilter: true)
                               },
                               onClose: { withAnimation(.easeOut(duration: 0.2)) { launchpad = false } })
                .frame(width: safe.width, height: safe.height)
            // Swipe up from the bottom edge: back to the peek (owner, 2026-10-31).
            VStack {
                Spacer()
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 120, height: 5)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { launchpad = false } }
                    .gesture(DragGesture(minimumDistance: 10).onEnded { d in
                        if d.translation.height < -30 || d.predictedEndTranslation.height < -80 {
                            withAnimation(.easeOut(duration: 0.2)) { launchpad = false }
                        }
                    })
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Close All Apps"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { withAnimation(.easeOut(duration: 0.2)) { launchpad = false } }
            }
            .frame(width: safe.width, height: safe.height)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.width / 2, y: frame.height / 2)
        .environment(\.colorScheme, .dark)
        .zIndex(40)
    }

    /// A carousel app: shows just its windows (tap again for all). An app with no window opens the
    /// gallery on its empty state ("Open on Mac" there). Browsing never opens or activates anything.
    private func tapApp(_ app: MacAppItem, forceFilter: Bool = false) {
        haptics.play(.tick, enabled: hapticsEnabled)
        // Finder opens a Finder-like browser here, backed by the Mac (its windows stay one tap away).
        if app.bundleID == Self.finderBundleID, model.files.available, !forceFilter {
            searchFocused = false
            model.files.open()
            return
        }
        let clearing = appFilter == app.bundleID && !forceFilter
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { appFilter = clearing ? nil : app.bundleID }
        let hasWindows = (model.catalog?.windows ?? []).contains { $0.bundleID == app.bundleID }
        if !clearing, !hasWindows || forceFilter, machine.isVisible, !machine.expanded { animate { machine.expand() } }
    }

    static let finderBundleID = "com.apple.finder"

    /// From Remote Finder's menu: Finder's own windows, in the gallery.
    private func showFinderWindows() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { appFilter = Self.finderBundleID }
        if !machine.isVisible { finish(machine.openDirectly()) }
        if !machine.expanded { animate { machine.expand() } }
    }

    private func pick(_ w: CatalogWindowItem) {
        haptics.play(.select, enabled: hapticsEnabled)
        searchFocused = false
        animate { machine.cancelAll() }
        model.stagePeekOpen = false
        model.switchTo(w)
    }

    /// A display card: in Window mode the desktop goes into the pane (Full Desktop is a tile
    /// source, never a mode switch); in Mirror/Extend it already shows.
    private func pickDisplay(_ d: CatalogDisplayItem?) {
        haptics.play(.select, enabled: hapticsEnabled)
        searchFocused = false
        animate { machine.cancelAll() }
        model.stagePeekOpen = false
        showDisplay(d)
    }

    private func showDisplay(_ d: CatalogDisplayItem?) {
        if model.windowMode, let d = d ?? model.mainDisplay {
            model.switchTo(model.displayWindow(d))
        } else {
            onDisplay(d)
        }
    }

    private func dragPreview(_ w: CatalogWindowItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.15))
            if let cg = model.still(for: w) {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(4)
            }
            MacAppIcon(model: model, bundleID: w.bundleID, name: w.app, size: 24).offset(x: -4, y: 4)
        }
        .frame(width: 150, height: 94)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(meowAccent, lineWidth: 2))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
        .scaleEffect(1.04)
        .opacity(0.95)
    }

    /// The edge bar nudges inward a few times after it appears, so people know it's there.
    private func playHint() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !machine.isVisible else { continue }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { hint = true }
                try? await Task.sleep(nanoseconds: 260_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hint = false }
            }
        }
    }

    private static func titleFits(focus: StagePeekCard, width: CGFloat, safe: CGRect, edge: StagePeekEdge) -> Bool {
        edge == .left ? focus.center.x + focus.size.width / 2 + 12 + width <= safe.maxX
                      : focus.center.x - focus.size.width / 2 - 12 - width >= safe.minX
    }

    private static func titleX(focus: StagePeekCard, width: CGFloat, safe: CGRect, edge: StagePeekEdge) -> CGFloat {
        guard titleFits(focus: focus, width: width, safe: safe, edge: edge) else {
            return min(max(focus.center.x, safe.minX + width / 2), safe.maxX - width / 2)
        }
        return edge == .left ? focus.center.x + focus.size.width / 2 + 12 + width / 2
                             : focus.center.x - focus.size.width / 2 - 12 - width / 2
    }

    private func title(for focus: StagePeekCard) -> some View {
        let window = window(at: focus.index)
        let icon = window.flatMap { model.icons[$0.bundleID] }
        let width = min(200, safe.width - 24)
        return HStack(spacing: 8) {
            if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 22, height: 22) }
            VStack(alignment: .leading, spacing: 1) {
                Text(window?.app ?? String(localized: "Full Desktop")).font(.footnote.weight(.semibold)).lineLimit(1)
                if window == nil {
                    Text("Show the whole Mac screen").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize()
                }
                if let t = window?.title, !t.isEmpty, t != window?.app {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(reduceTransparency ? AnyShapeStyle(Color(white: 0.12).opacity(0.92)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: width)
        .fixedSize(horizontal: false, vertical: true)
        // Beside the selected card (never over the next card below); under it only when there's no room.
        .position(x: Self.titleX(focus: focus, width: width, safe: safe, edge: edge),
                  y: Self.titleFits(focus: focus, width: width, safe: safe, edge: edge)
                      ? focus.center.y : min(focus.center.y + focus.size.height / 2 + 30, safe.maxY - 72))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(10)
    }

    /// Expand/Compact, Add as Tile (expanded, room for another tile), Close.
    /// Fixed at the bottom centre: it used to follow the highlighted card, so it slid and jumped
    /// while the compact peek scrolled (owner report 2026-10-31).
    private func toolbar(cards: [StagePeekCard]) -> some View {
        let column = safe.midX
        let chosen = machine.highlightedID.flatMap { id in windows.first { $0.id == id } }
        return HStack(spacing: 6) {
            // While the apps bar is grown, Compact puts it back to one row first.
            let compacting = machine.expanded || dockRows > 1
            Button {
                if dockRows > 1 {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { dockRows = 1; dockWide = false }
                } else {
                    animate { machine.expanded ? machine.compact() : machine.expand() }
                }
            } label: {
                Label(compacting ? String(localized: "Compact") : String(localized: "Expand"),
                      systemImage: compacting ? "arrow.down.right.and.arrow.up.left"
                                              : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("stagePeekExpand")
            if machine.expanded, model.canAddTile, let chosen {
                Button {
                    animate { machine.cancelAll() }
                    haptics.play(.select, enabled: hapticsEnabled)
                    model.stagePeekOpen = false
                    model.choose(chosen, asNewTile: true)
                } label: { Label("Add as Tile", systemImage: "plus.rectangle.on.rectangle") }
                .accessibilityIdentifier("stagePeekAddTile")
            }
            Button { finish(machine.dismiss()) } label: { Label("Close", systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("stagePeekClose")
        }
        .font(.footnote.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .position(x: toolbarX(column), y: toolbarY(column))
        .zIndex(11)
    }

    private func toolbarX(_ column: CGFloat) -> CGFloat { min(max(column, safe.minX + 130), safe.maxX - 130) }

    /// Bottom of the stack's column, lifted above any control under it (the
    /// settings button, a tray): found on iPhone, where they collided.
    private func toolbarY(_ column: CGFloat) -> CGFloat {
        let x = toolbarX(column)
        var y = safe.maxY - 30
        for r in avoiding.sorted(by: { $0.minY > $1.minY })
        where r.maxX > x - 140 && r.minX < x + 140 && r.maxY > y - 22 && r.minY < y + 22 {
            y = r.minY - 30
        }
        return max(y, safe.minY + 30)
    }

    private func stripView(_ strip: CGRect, cards: [StagePeekCard]) -> some View {
        ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.white.opacity(machine.phase == .arming ? 0.9 : (machine.isVisible ? 0 : 0.42)))
                .frame(width: 4, height: min(machine.phase == .arming ? 56 : 40, strip.height * 0.4))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .offset(x: hint ? (edge == .left ? 5 : -5) : 0)
                .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
                .padding(.horizontal, 3)
                .animation(.easeOut(duration: 0.2), value: machine.phase)
        }
        .frame(width: strip.width, height: strip.height)
        .contentShape(Rectangle())
        .position(x: strip.midX, y: strip.midY)
        .gesture(stripGesture(cards: cards))
        .accessibilityElement()
        .accessibilityLabel("Stage Peek")
        .accessibilityHint("Shows your Mac windows. Swipe up or down to choose, double-tap a window to switch.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish(machine.isVisible ? machine.selectHighlighted() : machine.openDirectly()) }
        .accessibilityAdjustableAction { direction in
            if !machine.isVisible { finish(machine.openDirectly()) }
            finish(machine.step(direction == .increment ? 1 : -1))
        }
        .accessibilityIdentifier("stagePeekStrip")
        .zIndex(20)
    }

    // MARK: Gestures

    private static func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    private func stripGesture(cards: [StagePeekCard]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stagePeek"))
            .updating($stripPressing) { _, pressing, _ in pressing = true }
            .onChanged { v in
                let t = v.time.timeIntervalSinceReferenceDate
                if !stripDown {
                    stripDown = true
                    if !machine.isVisible { haptics.play(.tick, enabled: hapticsEnabled) }   // the bar answers the finger at once
                    _ = machine.touchBegan(id: "strip", at: v.startLocation, time: t, onStrip: true)
                    if machine.phase == .arming {
                        model.stagePeekOpen = true   // fresh catalog and thumbnails while the hold completes
                        schedulePoll()
                    }
                }
                move("strip", v.location, t)
            }
            .onEnded { v in
                stripDown = false
                end("strip", v.location, v.time.timeIntervalSinceReferenceDate, cards: cards)
            }
    }

    private func openGesture(cards: [StagePeekCard]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stagePeek"))
            .updating($openPressing) { _, pressing, _ in pressing = true }
            .onChanged { v in
                let t = v.time.timeIntervalSinceReferenceDate
                if cardDragging {
                    model.moveDrag(to: global(v.location))
                    return
                }
                if !openDown {
                    openDown = true
                    openTouch += 1
                    openStart = v.startLocation
                    let wasOpen = machine.phase == .open
                    _ = machine.touchBegan(id: "open\(openTouch)", at: v.startLocation, time: t, onStrip: false,
                                           closableCard: closableCard(at: v.startLocation, cards: cards))
                    if wasOpen, machine.expansion < 0.5 { armCardHold(at: v.startLocation, cards: cards) }
                }
                if hypot(v.location.x - openStart.x, v.location.y - openStart.y) > StagePeekConfig.tapSlop { holdTask?.cancel() }
                move("open\(openTouch)", v.location, t)
            }
            .onEnded { v in
                openDown = false
                holdTask?.cancel()
                if cardDragging {
                    cardDragging = false
                    model.moveDrag(to: global(v.location))
                    // Dropped on a pane: done. On Cancel or nowhere: the peek comes back as it was.
                    if model.endDrag() {
                        haptics.play(.select, enabled: hapticsEnabled)
                        animate { machine.cancelAll() }
                        model.stagePeekOpen = false
                    }
                    return
                }
                end("open\(openTouch)", v.location, v.time.timeIntervalSinceReferenceDate, cards: cards)
            }
    }

    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + overlayOrigin.x, y: p.y + overlayOrigin.y) }

    /// The compact card under `p` when it's a Mac window this Mac can close (not a display).
    private func closableCard(at p: CGPoint, cards: [StagePeekCard]) -> Int? {
        guard model.canCloseWindows, machine.expansion < 0.5,
              let i = StagePeekLayout.hit(p, cards: cards, region: hitRegion), machine.ids.indices.contains(i),
              StagePeekIDs.displayIndex(machine.ids[i]) == nil else { return nil }
        return i
    }

    /// A still finger on a compact card for a moment lifts it: from then on the finger drags it
    /// over the panes (or the desktop), and lifting drops it. Scrubbing or a tap never lifts.
    private func armCardHold(at p: CGPoint, cards: [StagePeekCard]) {
        holdTask?.cancel()
        guard let index = StagePeekLayout.hit(p, cards: cards, region: hitRegion), machine.ids.indices.contains(index) else { return }
        let id = machine.ids[index]
        let item: CatalogWindowItem? = {
            if let d = StagePeekIDs.displayIndex(id) {
                let display = displays.indices.contains(d) ? displays[d] : model.mainDisplay
                return display.map(model.displayWindow)
            }
            return windows.first { $0.id == id }
        }()
        guard let item else { return }
        let touch = openTouch
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled, openDown, openTouch == touch, !cardDragging else { return }
            // The touch now belongs to the drag: the peek never selects or scrubs with it.
            machine.touchCancelled(id: "open\(touch)")
            cardDragging = true
            searchFocused = false
            haptics.play(.activate, enabled: hapticsEnabled)
            model.beginDrag(.window(item), at: global(p))
        }
    }

    private func move(_ id: String, _ p: CGPoint, _ t: TimeInterval) {
        let wasArming = machine.phase == .arming
        let effects = machine.touchMoved(id: id, to: p, time: t, edge: edge)
        if wasArming, machine.phase == .closed {
            // A swipe from the edge: nothing opens.
            pollTask?.cancel()
            model.stagePeekOpen = false
        }
        perform(effects)
    }

    private func end(_ id: String, _ p: CGPoint, _ t: TimeInterval, cards: [StagePeekCard]) {
        pollTask?.cancel()
        var effects: [StagePeekEffect] = []
        animate { effects = machine.touchEnded(id: id, at: p, time: t, cardAt: { StagePeekLayout.hit($0, cards: cards, region: hitRegion) }) }
        finish(effects)
    }

    /// The system took a touch (incoming call, Control Centre, multitasking):
    /// SwiftUI resets the gesture state without calling onEnded.
    private func detectCancel(strip: Bool) {
        DispatchQueue.main.async {
            if strip, stripDown {
                stripDown = false
                animate { machine.touchCancelled(id: "strip") }
            } else if !strip, openDown {
                openDown = false
                holdTask?.cancel()
                if cardDragging { cardDragging = false; model.cancelDrag() }
                animate { machine.touchCancelled(id: "open\(openTouch)") }
            } else {
                return
            }
            pollTask?.cancel()
            finish([])
        }
    }

    private func schedulePoll() {
        pollTask?.cancel()
        guard let delay = machine.pollDelay(now: Self.now()) else { return }
        pollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.004) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            var effects: [StagePeekEffect] = []
            animate { effects = machine.poll(now: Self.now()) }
            if machine.phase == .arming { schedulePoll() }   // woke a hair early
            perform(effects)
        }
    }

    // MARK: Effects

    private func perform(_ effects: [StagePeekEffect]) {
        for effect in effects {
            switch effect {
            case .opened:
                model.stagePeekOpen = true
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            case .haptic(let h):
                haptics.play(h, enabled: hapticsEnabled)
            case .select(let id):
                model.stagePeekOpen = false
                searchFocused = false
                if let index = StagePeekIDs.displayIndex(id) {
                    showDisplay(displays.indices.contains(index) ? displays[index] : nil)
                } else if let w = windows.first(where: { $0.id == id }) {
                    model.switchTo(w)
                }
            case .dismissed:
                model.stagePeekOpen = false
            case .revealClose(let id):
                if let id, let w = windows.first(where: { $0.id == id }) {
                    UIAccessibility.post(notification: .announcement,
                                         argument: String(localized: "Close Window for \(w.title.isEmpty ? w.app : w.title)"))
                }
            }
        }
    }

    /// Performs effects, then drops the catalog refresh once nothing shows.
    private func finish(_ effects: [StagePeekEffect]) {
        perform(effects)
        if machine.phase == .closed, model.stagePeekOpen { model.stagePeekOpen = false }
    }

    private func syncItems() {
        // Displays first (Full Desktop at the top of the stack), then the Mac's windows. Always at
        // least Full Desktop, so the edge bar works before the first listing (it asks for one).
        let displayIDs = displays.isEmpty ? [StagePeekMachine.fullDesktopID] : displays.indices.map { StagePeekIDs.display($0) }
        machine.setItems(displayIDs + windows.map(\.id), current: model.windowMode ? model.currentWindowID : StagePeekMachine.fullDesktopID)
        if machine.isVisible, !machine.expanded {
            let near = machine.ids.indices.filter { abs(Double($0) - machine.position) <= 4 }.map { machine.ids[$0] }
            model.thumbnailPriority = near.filter { StagePeekIDs.displayIndex($0) == nil }
        }
    }

    private func cancelAll() {
        pollTask?.cancel()
        stripDown = false
        openDown = false
        machine.cancelAll()
        if model.stagePeekOpen { model.stagePeekOpen = false }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86), change)
    }
}

/// Stage Peek haptics: discrete events only, never continuous. Respects the
/// Haptics setting; the system's own haptics switch applies on top.
@MainActor
final class StagePeekHaptics {
    private let selection = UISelectionFeedbackGenerator()
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    func play(_ haptic: StagePeekHaptic, enabled: Bool) {
        guard enabled else { return }
        switch haptic {
        case .activate:
            soft.impactOccurred(intensity: 0.8)
            selection.prepare()
        case .tick:
            selection.selectionChanged()
            selection.prepare()
        case .boundary:
            rigid.impactOccurred(intensity: 0.35)
        case .select:
            medium.impactOccurred()
        }
    }
}

/// Shows Remote Finder while it is open (observes the files model, which the peek doesn't).
private struct RemoteFinderHost: View {
    @ObservedObject var files: RemoteFilesModel
    let workspace: WorkspaceModel
    let inputAllowed: Bool
    let safe: CGRect
    let onFinderWindows: () -> Void

    var body: some View {
        ZStack {
            if files.isOpen {
                RemoteFinderView(files: files, workspace: workspace, inputAllowed: inputAllowed, safe: safe,
                                 onFinderWindows: onFinderWindows)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: files.isOpen)
    }
}
