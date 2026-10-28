import SwiftUI
import UIKit

/// MeowDisplay blue: the Stage Peek focus ring.
private let stagePeekAccent = Color(red: 0.33, green: 0.60, blue: 1.0)

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

    @State private var machine = StagePeekMachine()
    @State private var stripDown = false
    @State private var openDown = false
    @State private var openTouch = 0
    @GestureState private var stripPressing = false
    @GestureState private var openPressing = false
    @State private var pollTask: Task<Void, Never>?
    @State private var haptics = StagePeekHaptics()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var windows: [CatalogWindowItem] { model.catalog?.windows ?? [] }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        let cards = layout()
        ZStack(alignment: .topLeading) {
            if machine.isVisible {
                backdrop
                    .contentShape(Rectangle())
                    .gesture(openGesture(cards: cards))
                    .transition(.opacity)
                ForEach(cards, id: \.index) { card in
                    cardView(card)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: edge == .left ? -48 : 48)))
                }
                if let focus = cards.first(where: \.highlighted) {
                    title(for: focus)
                }
                toolbar(cards: cards)
                    .transition(.opacity)
            }
            if !machine.ids.isEmpty, !model.overviewOpen,
               let strip = StagePeekLayout.strip(edge: edge, safe: safe, avoiding: avoiding) {
                stripView(strip, cards: cards)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .coordinateSpace(name: "stagePeek")
        .accessibilityAction(.escape) { finish(machine.dismiss()) }
        .position(x: frame.midX, y: frame.midY)
        .onAppear { syncItems() }
        .onChange(of: windows) { _ in syncItems() }
        .onChange(of: model.currentWindowID) { _ in syncItems() }
        .onChange(of: model.available) { available in if !available { cancelAll() } }
        .onChange(of: model.windowMode) { window in if !window { cancelAll() } }
        .onChange(of: model.overviewOpen) { open in if open { cancelAll() } }
        .onChange(of: frame.size) { _ in cancelAll() }   // rotation, fold, Split View, Stage Manager resize
        .onChange(of: edge) { _ in cancelAll() }
        .onChange(of: stripPressing) { pressing in if !pressing { detectCancel(strip: true) } }
        .onChange(of: openPressing) { pressing in if !pressing { detectCancel(strip: false) } }
        .onDisappear { cancelAll() }
    }

    // MARK: Geometry

    private func layout() -> [StagePeekCard] {
        let aspects = machine.ids.map { id -> Double in
            guard let w = windows.first(where: { $0.id == id }), w.width > 0, w.height > 0 else { return 1.5 }
            return Double(w.width) / Double(w.height)
        }
        return StagePeekLayout.cards(aspects: aspects, position: machine.position, expansion: machine.expansion,
                                     edge: edge, safe: safe, isPad: isPad, reduceMotion: reduceMotion)
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
            LinearGradient(colors: [Color.black.opacity(reduceTransparency ? 0.6 : 0.42), Color.black.opacity(0)],
                           startPoint: edge == .left ? .leading : .trailing,
                           endPoint: edge == .left ? .trailing : .leading)
                .frame(width: min(frame.width, (isPad ? 520 : 380) + e * frame.width))
                .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
            if e > 0 {
                if reduceTransparency {
                    Color(white: 0.08).opacity(0.6 * e)
                } else {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.85 * e)
                    Color.black.opacity(0.2 * e)
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
        let shape = RoundedRectangle(cornerRadius: isPad ? 14 : 11, style: .continuous)
        return ZStack {
            shape.fill(Color(white: 0.17))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
            } else if let icon {
                Image(decorative: icon, scale: 1).resizable().frame(width: 44, height: 44)
            } else {
                Image(systemName: "macwindow").font(.title2).foregroundStyle(Color.white.opacity(0.6))
            }
            if window?.minimized == true {
                Text("Minimized").font(.caption2.weight(.semibold))
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
        .accessibilityLabel(window.map { w in w.title.isEmpty ? w.app : "\(w.app), \(w.title)" } ?? "")
        .accessibilityAddTraits(card.highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { finish(machine.select(index: card.index)) }
    }

    private func title(for focus: StagePeekCard) -> some View {
        let window = window(at: focus.index)
        let icon = window.flatMap { model.icons[$0.bundleID] }
        let width = min(max(focus.size.width + 48, 200), safe.width - 24)
        return HStack(spacing: 8) {
            if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 22, height: 22) }
            VStack(alignment: .leading, spacing: 1) {
                Text(window?.app ?? "").font(.footnote.weight(.semibold)).lineLimit(1)
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
        .position(x: min(max(focus.center.x, safe.minX + width / 2), safe.maxX - width / 2),
                  y: min(focus.center.y + focus.size.height / 2 + 24, safe.maxY - 72))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(10)
    }

    /// Expand/Compact, Add as Tile (expanded, room for another tile), Close.
    /// Kept at the bottom of the stack's column, away from the cards' centre.
    private func toolbar(cards: [StagePeekCard]) -> some View {
        let column = cards.first(where: \.highlighted)?.center.x ?? safe.midX
        let chosen = machine.highlightedID.flatMap { id in windows.first { $0.id == id } }
        return HStack(spacing: 6) {
            Button {
                animate { machine.expanded ? machine.compact() : machine.expand() }
            } label: {
                Label(machine.expanded ? String(localized: "Compact") : String(localized: "Expand"),
                      systemImage: machine.expanded ? "arrow.down.right.and.arrow.up.left"
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
        .position(x: min(max(column, safe.minX + 130), safe.maxX - 130), y: safe.maxY - 30)
        .zIndex(11)
    }

    private func stripView(_ strip: CGRect, cards: [StagePeekCard]) -> some View {
        ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.white.opacity(machine.phase == .arming ? 0.9 : (machine.isVisible ? 0 : 0.42)))
                .frame(width: 4, height: min(machine.phase == .arming ? 56 : 40, strip.height * 0.4))
                .shadow(color: .black.opacity(0.35), radius: 2)
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
                if !openDown {
                    openDown = true
                    openTouch += 1
                    _ = machine.touchBegan(id: "open\(openTouch)", at: v.startLocation, time: t, onStrip: false)
                }
                move("open\(openTouch)", v.location, t)
            }
            .onEnded { v in
                openDown = false
                end("open\(openTouch)", v.location, v.time.timeIntervalSinceReferenceDate, cards: cards)
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
        animate { effects = machine.touchEnded(id: id, at: p, time: t, cardAt: { StagePeekLayout.hit($0, cards: cards) }) }
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
                if let w = windows.first(where: { $0.id == id }) { model.choose(w, asNewTile: false) }
            case .dismissed:
                model.stagePeekOpen = false
            }
        }
    }

    /// Performs effects, then drops the catalog refresh once nothing shows.
    private func finish(_ effects: [StagePeekEffect]) {
        perform(effects)
        if machine.phase == .closed, model.stagePeekOpen { model.stagePeekOpen = false }
    }

    private func syncItems() {
        machine.setItems(windows.map(\.id), current: model.currentWindowID)
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
