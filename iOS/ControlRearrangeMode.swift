import SwiftUI
import UIKit

// Rearrange Controls: Home Screen style edit mode for the live control trays.
// Chosen from Session Actions; `ReceiverControlOverlay` mounts
// `ControlRearrangeLayer` over its controls with the slots the buttons
// already occupy, and hides the live buttons and their touch layer. The
// layer takes every touch on screen, so nothing reaches the Mac (ReceiverScreen
// also closes the input surface while `ReceiverControlStore.rearrangingControls`
// is on). Order changes are written through the store as each drag lands.

/// One button being rearranged.
struct ControlRearrangeItem: Identifiable, Equatable {
    enum Face: Equatable {
        case tray(ControlTrayItem)
        case shortcut(ShortcutButtonFace)
    }

    let id: String
    let title: String
    let face: Face
    /// A tap opens this palette for rearranging (the modifier's shortcuts).
    var palette: ModifierChord? = nil

    static func tray(_ item: ControlTrayItem, palette: ModifierChord? = nil) -> ControlRearrangeItem {
        ControlRearrangeItem(id: "tray:\(item.rawValue)", title: item.title, face: .tray(item), palette: palette)
    }

    static func shortcut(_ item: ShortcutItem) -> ControlRearrangeItem {
        ControlRearrangeItem(id: "shortcut:\(item.id)", title: item.title, face: .shortcut(item.face))
    }
}

/// One run of buttons that reorder among themselves: the Main Tray, the
/// Function Tray, or an open palette.
struct ControlRearrangeRun: Identifiable {
    enum Kind: Hashable {
        case main
        case function
        case palette(ModifierChord)
    }

    let kind: Kind
    let items: [ControlRearrangeItem]
    /// Each button's circle in the overlay's coordinates, in order.
    let slots: [CGRect]
    var id: Kind { kind }
}

/// An open palette in edit mode: its keys where the live palette draws
/// them, and the palette's own frame (its backdrop, and where an empty
/// palette's hint sits).
struct ControlRearrangePalette {
    let items: [ControlRearrangeItem]
    let slots: [CGRect]
    let frame: CGRect
}

/// Edit mode over the controls: a faint scrim that takes every touch, the
/// wiggling runs inside dashed outlines of where buttons can go, the open
/// palette (if any) in its usual place, and Done.
struct ControlRearrangeLayer: View {
    let containerSize: CGSize
    let safeInsets: ControlSafeInsets
    let isPad: Bool
    let runs: [ControlRearrangeRun]
    /// A palette laid out as the live tray opens it, after taps on modifiers.
    let palette: (ModifierChord) -> ControlRearrangePalette
    let onMove: (ControlRearrangeRun.Kind, Int, Int) -> Void
    let onHaptic: (ControlHapticEvent) -> Void
    let onDone: () -> Void

    @State private var openPalette: ModifierChord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let container = CGRect(origin: .zero, size: containerSize)
        let open = openPalette.map { (chord: $0, layout: palette($0)) }
        ZStack(alignment: .topLeading) {
            // Takes every touch outside the buttons: none reach the Mac or
            // the controls underneath. Lifting on it closes an open palette.
            Color.black.opacity(0.22)
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in closePalette() })
                .accessibilityHidden(true)

            ForEach(runs) { run in
                ControlRearrangeBounds(slots: run.slots)
            }

            ForEach(runs) { run in
                ControlRearrangeRunView(run: run, isPad: isPad, coordinateSpace: Self.space,
                                        selected: openPalette?.modifiers ?? [],
                                        onMove: onMove, onHaptic: onHaptic,
                                        onTap: { item in tapped(item) })
            }

            if let open {
                paletteBackdrop(open.layout, chord: open.chord)
                ControlRearrangeRunView(run: ControlRearrangeRun(kind: .palette(open.chord), items: open.layout.items,
                                                                 slots: open.layout.slots),
                                        isPad: isPad, coordinateSpace: Self.space, selected: [],
                                        onMove: onMove, onHaptic: onHaptic, onTap: { _ in })
                    .id(open.chord)
                    .transition(.opacity)
            }

            hint(container: container)
            doneButton(container: container)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("controlRearrangeLayer")
        .accessibilityAction(.escape) {
            if openPalette != nil { closePalette() } else { onDone() }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: openPalette)
    }

    static let space = "controlRearrange"

    private func tapped(_ item: ControlRearrangeItem) {
        guard let chord = item.palette, let modifier = chord.modifiers.first, chord.modifiers.count == 1 else { return }
        onHaptic(.expandCollapse)
        openPalette = ControlRearrangePolicy.palette(after: openPalette, tapping: modifier)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func closePalette() {
        guard openPalette != nil else { return }
        openPalette = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The palette's tray where it normally opens, outlined like the
    /// others; an empty one says so in place.
    @ViewBuilder
    private func paletteBackdrop(_ layout: ControlRearrangePalette, chord: ModifierChord) -> some View {
        if layout.items.isEmpty {
            Text("No \(chord.symbols) shortcuts yet. Add them in Settings.",
                 comment: "Rearrange Controls: an open palette with no shortcuts.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial).opacity(0.6))
                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(0.5)))
                .fixedSize()
                .position(x: layout.frame.midX, y: layout.frame.midY)
                .allowsHitTesting(false)
                .accessibilityIdentifier("controlRearrangeEmptyPalette")
        } else {
            let frame = layout.slots.dropFirst().reduce(layout.slots[0]) { $0.union($1) }.insetBy(dx: -6, dy: -6)
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) / 2, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.5)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0))
                .accessibilityHidden(true)
            ControlRearrangeBounds(slots: layout.slots)
        }
    }

    private func hint(container: CGRect) -> some View {
        Text(openPalette == nil
             ? String(localized: "Drag to rearrange. Tap a modifier for its shortcuts.",
                      comment: "Rearrange Controls: hint under Done.")
             : String(localized: "\(openPalette?.symbols ?? "") shortcuts. Tap another modifier to add it.",
                      comment: "Rearrange Controls: hint under Done while a palette is open."))
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .frame(maxWidth: min(container.width - 48, 420))
            .fixedSize(horizontal: false, vertical: true)
            .position(x: container.midX, y: safeInsets.top + (isPad ? 34 : 30) + 34)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func doneButton(container: CGRect) -> some View {
        Button(action: onDone) {
            Text("Done", comment: "Ends Rearrange Controls.")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.white.opacity(0.9))
        .foregroundStyle(.black)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(Text("Keeps the new order.", comment: "Rearrange Controls: hint on Done."))
        .accessibilityIdentifier("controlRearrangeDone")
        .position(x: container.midX, y: safeInsets.top + (isPad ? 34 : 30))
    }
}

/// Dashed outlines of where a run's buttons can go: one capsule per
/// cluster of neighbouring slots.
private struct ControlRearrangeBounds: View {
    let slots: [CGRect]

    var body: some View {
        ForEach(Array(ControlRearrangement.clusters(slots).enumerated()), id: \.offset) { _, cluster in
            let frame = cluster.insetBy(dx: -5, dy: -5)
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) / 2, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// One run: its buttons sit in `run.slots`, wiggle, and are dragged among
/// them. Others slide aside with a spring as the dragged one passes, and it
/// settles into the nearest slot on release. The drag lives in gesture
/// state, so a cancelled touch (a system gesture, an alert) puts the button
/// back instead of leaving it lifted.
private struct ControlRearrangeRunView: View {
    let run: ControlRearrangeRun
    let isPad: Bool
    let coordinateSpace: String
    /// Modifiers in the open palette's chord, drawn selected.
    let selected: Set<ControlModifier>
    let onMove: (ControlRearrangeRun.Kind, Int, Int) -> Void
    let onHaptic: (ControlHapticEvent) -> Void
    let onTap: (ControlRearrangeItem) -> Void

    private struct Drag: Equatable {
        let id: String
        var translation: CGSize
    }

    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.32, dampingFraction: 0.78)))
    private var drag: Drag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ids: [String] { run.items.map(\.id) }
    private var count: Int { min(run.items.count, run.slots.count) }
    private var slots: [CGRect] { Array(run.slots.prefix(count)) }

    private var dragStart: Int? {
        drag.flatMap { drag in ids.prefix(count).firstIndex(of: drag.id) }
    }

    /// The slot the dragged button is over.
    private var dragTarget: Int? {
        guard let drag, let start = dragStart else { return nil }
        let home = slots[start]
        let point = CGPoint(x: home.midX + drag.translation.width, y: home.midY + drag.translation.height)
        return ControlRearrangement.nearestSlot(to: point, in: slots) ?? start
    }

    /// The order on screen: the dragged button already counted in the slot
    /// it hovers over.
    private var liveOrder: [String] {
        guard let start = dragStart, let target = dragTarget else { return Array(ids.prefix(count)) }
        return ControlRearrangement.moving(Array(ids.prefix(count)), from: start, to: target)
    }

    private var settle: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.78)
    }

    var body: some View {
        let order = liveOrder
        let start = dragStart
        let horizontal = ControlRearrangement.runsHorizontally(slots)
        ZStack(alignment: .topLeading) {
            ForEach(run.items.prefix(count)) { item in
                let index = order.firstIndex(of: item.id) ?? 0
                let dragging = start != nil && drag?.id == item.id
                let slot = dragging ? slots[start!] : slots[index]
                let offset = dragging ? drag!.translation : .zero
                let chosen = item.palette.map { !$0.modifiers.isDisjoint(with: selected) } ?? false
                ControlRearrangeChip(item: item, diameter: slot.width, isPad: isPad, lifted: dragging || chosen)
                    .modifier(ControlJiggle(id: item.id, active: !dragging))
                    .scaleEffect(dragging && !reduceMotion ? 1.1 : 1)
                    .shadow(color: .black.opacity(dragging ? 0.4 : 0), radius: dragging ? 10 : 0, y: dragging ? 4 : 0)
                    .frame(width: slot.width + 8, height: slot.height + 8)
                    .contentShape(Rectangle())
                    .position(x: slot.midX + offset.width, y: slot.midY + offset.height)
                    .animation(dragging ? nil : settle, value: order)
                    .zIndex(dragging ? 1 : 0)
                    .onTapGesture { onTap(item) }
                    .gesture(dragGesture(for: item))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(Text("\(index + 1) of \(count)",
                                             comment: "Rearrange Controls: a button's position in its row."))
                    .accessibilityHint(item.palette == nil
                        ? Text("Use the Move actions to change its place.",
                               comment: "Rearrange Controls: hint on a button.")
                        : Text("Opens its shortcuts to rearrange. Use the Move actions to change its place.",
                               comment: "Rearrange Controls: hint on a modifier with shortcuts."))
                    .accessibilityAction(named: horizontal
                                         ? Text("Move Left", comment: "Rearrange Controls: accessibility action.")
                                         : Text("Move Up", comment: "Rearrange Controls: accessibility action.")) {
                        step(item, by: -1)
                    }
                    .accessibilityAction(named: horizontal
                                         ? Text("Move Right", comment: "Rearrange Controls: accessibility action.")
                                         : Text("Move Down", comment: "Rearrange Controls: accessibility action.")) {
                        step(item, by: 1)
                    }
                    .opensPaletteAccessibility(item.palette == nil ? nil : { onTap(item) })
                    .accessibilityIdentifier("rearrange.\(item.id)")
            }
        }
        .onChange(of: drag?.id) { id in
            if id != nil { onHaptic(.latch) }
        }
        .onChange(of: dragTarget) { target in
            if target != nil, target != dragStart { onHaptic(.selection) }
        }
    }

    private func dragGesture(for item: ControlRearrangeItem) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .updating($drag) { value, state, _ in
                guard state == nil || state?.id == item.id else { return }
                state = Drag(id: item.id, translation: value.translation)
            }
            .onEnded { value in
                guard let from = ids.prefix(count).firstIndex(of: item.id) else { return }
                let home = slots[from]
                let point = CGPoint(x: home.midX + value.translation.width, y: home.midY + value.translation.height)
                let to = ControlRearrangement.nearestSlot(to: point, in: slots) ?? from
                guard to != from else { return }
                withAnimation(settle) { onMove(run.kind, from, to) }
            }
    }

    private func step(_ item: ControlRearrangeItem, by delta: Int) {
        guard let index = ids.firstIndex(of: item.id),
              let target = ControlRearrangement.step(from: index, by: delta, count: count) else { return }
        withAnimation(settle) { onMove(run.kind, index, target) }
        onHaptic(.selection)
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Position \(target + 1) of \(count)",
                                              comment: "Rearrange Controls: spoken after a Move action."))
    }
}

/// A button's face as the trays draw it, without its action.
private struct ControlRearrangeChip: View {
    let item: ControlRearrangeItem
    let diameter: CGFloat
    let isPad: Bool
    let lifted: Bool

    var body: some View {
        face
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(chip)
    }

    @ViewBuilder
    private var face: some View {
        switch item.face {
        case .tray(let tray):
            if let modifier = tray.modifier {
                Text(modifier.symbol).font(.system(size: (diameter * 0.52).rounded(), weight: .semibold))
            } else if tray == .escape || tray == .tab {
                Text(tray.displayLabel).font(.system(size: (diameter * 0.32).rounded(), weight: .semibold))
            } else {
                Image(systemName: tray.displayLabel).font(.system(size: (diameter * 0.45).rounded(), weight: .semibold))
            }
        case .shortcut(let face):
            ShortcutButtonFaceView(face: face, diameter: diameter)
        }
    }

    @ViewBuilder
    private var chip: some View {
        if isPad {
            PadChip(selected: false, onRail: !lifted)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(lifted ? 0.85 : 0.6)
                .overlay(Circle().fill(Color.white.opacity(lifted ? 0.18 : 0.09)))
                .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
        }
    }
}

/// Home Screen jiggle: rotation of about ±1.5–2° and a bob under a point, each
/// icon on its own rhythm (`ControlJiggleMotion`). Reduce Motion: no
/// movement, a dashed ring that slowly brightens and dims instead.
struct ControlJiggle: ViewModifier {
    let id: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(2 * .pi * t / 1.8)
                content.overlay(
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(0.45 + 0.4 * pulse))
                        .padding(-3))
            }
        } else {
            let motion = ControlJiggleMotion(id: id)
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content
                    .rotationEffect(.degrees(motion.angle(at: t)))
                    .offset(y: motion.offset(at: t))
            }
        }
    }
}

private extension View {
    /// Opening a palette as the element's default action, only for a button
    /// that has one.
    @ViewBuilder
    func opensPaletteAccessibility(_ open: (() -> Void)?) -> some View {
        if let open {
            accessibilityAddTraits(.isButton).accessibilityAction { open() }
        } else {
            self
        }
    }
}
