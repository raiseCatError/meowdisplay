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

/// Edit mode over the controls: a faint scrim that takes every touch, the
/// wiggling runs, the open palette (if any) and Done.
struct ControlRearrangeLayer: View {
    let containerSize: CGSize
    let safeInsets: ControlSafeInsets
    let isPad: Bool
    let runs: [ControlRearrangeRun]
    /// The keys of a palette, for rearranging after a tap on its modifier.
    let paletteItems: (ModifierChord) -> [ControlRearrangeItem]
    let onMove: (ControlRearrangeRun.Kind, Int, Int) -> Void
    let onHaptic: (ControlHapticEvent) -> Void
    let onDone: () -> Void

    @State private var openPalette: ModifierChord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var paletteKey: CGFloat { isPad ? 44 : 38 }
    private var paletteGap: CGFloat { isPad ? 10 : 8 }

    var body: some View {
        let container = CGRect(origin: .zero, size: containerSize)
        let paletteRun = openPalette.map(paletteRun(for:))
        ZStack(alignment: .topLeading) {
            // Takes every touch outside the buttons: none reach the Mac or
            // the controls underneath. Lifting on it closes an open palette.
            Color.black.opacity(0.22)
                .frame(width: containerSize.width, height: containerSize.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in closePalette() })
                .accessibilityHidden(true)

            ForEach(runs) { run in
                ControlRearrangeRunView(run: run, isPad: isPad, coordinateSpace: Self.space,
                                        onMove: onMove, onHaptic: onHaptic,
                                        onTap: { item in tapped(item) })
            }

            if let paletteRun, let card = paletteCard(paletteRun) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: card.width, height: card.height)
                    .position(x: card.midX, y: card.midY)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0))
                    .accessibilityHidden(true)
                paletteHeader(paletteRun, card: card)
                ControlRearrangeRunView(run: paletteRun, isPad: isPad, coordinateSpace: Self.space,
                                        onMove: onMove, onHaptic: onHaptic, onTap: { _ in })
                    .transition(.opacity)
            }

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
        guard let chord = item.palette else { return }
        onHaptic(.expandCollapse)
        openPalette = openPalette == chord ? nil : chord
        if openPalette != nil {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    private func closePalette() {
        guard openPalette != nil else { return }
        openPalette = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// The palette's keys as a grid in the middle of the safe area.
    private func paletteRun(for chord: ModifierChord) -> ControlRearrangeRun {
        let items = paletteItems(chord)
        let safe = safeInsets.safeRect(in: containerSize).insetBy(dx: 32, dy: 0)
        let slots = ControlRearrangement.gridSlots(
            count: items.count, key: paletteKey, gap: paletteGap, maximumColumns: isPad ? 8 : 5,
            center: CGPoint(x: safe.midX, y: safe.midY + 12), bounds: safe)
        return ControlRearrangeRun(kind: .palette(chord), items: items, slots: slots)
    }

    private func paletteCard(_ run: ControlRearrangeRun) -> CGRect? {
        guard let first = run.slots.first else { return nil }
        let keys = run.slots.dropFirst().reduce(first) { $0.union($1) }
        // Room for the heading above the keys, and for the heading's width.
        let width = max(keys.width + 32, 180)
        return CGRect(x: keys.midX - width / 2, y: keys.minY - 52, width: width, height: keys.height + 68)
    }

    private func paletteHeader(_ run: ControlRearrangeRun, card: CGRect) -> some View {
        let chord: ModifierChord? = {
            if case .palette(let chord) = run.kind { return chord }
            return nil
        }()
        return HStack(spacing: 8) {
            Text(chord?.symbols ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel(Text("\(chord?.displayName ?? "") Shortcuts",
                                         comment: "Rearrange Controls: heading of an open shortcut palette."))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { closePalette() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Close Shortcuts", comment: "Rearrange Controls: closes the open shortcut palette."))
            .accessibilityIdentifier("controlRearrangeClosePalette")
        }
        .padding(.horizontal, 10)
        .frame(width: card.width)
        .position(x: card.midX, y: card.minY + 22)
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

/// One run: its buttons sit in `run.slots`, wiggle, and are dragged among
/// them. Others slide aside with a spring as the dragged one passes, and it
/// settles into the nearest slot on release.
private struct ControlRearrangeRunView: View {
    let run: ControlRearrangeRun
    let isPad: Bool
    let coordinateSpace: String
    let onMove: (ControlRearrangeRun.Kind, Int, Int) -> Void
    let onHaptic: (ControlHapticEvent) -> Void
    let onTap: (ControlRearrangeItem) -> Void

    private struct Drag: Equatable {
        let id: String
        let start: Int
        var target: Int
        var translation: CGSize
    }

    @State private var drag: Drag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ids: [String] { run.items.map(\.id) }
    private var count: Int { min(run.items.count, run.slots.count) }

    /// The order on screen: the dragged button already counted in the slot
    /// it hovers over.
    private var liveOrder: [String] {
        guard let drag else { return Array(ids.prefix(count)) }
        return ControlRearrangement.moving(Array(ids.prefix(count)), from: drag.start, to: drag.target)
    }

    private var settle: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.78)
    }

    var body: some View {
        let order = liveOrder
        let horizontal = ControlRearrangement.runsHorizontally(Array(run.slots.prefix(count)))
        ZStack(alignment: .topLeading) {
            ForEach(run.items.prefix(count)) { item in
                let index = order.firstIndex(of: item.id) ?? 0
                let dragging = drag?.id == item.id
                let slot = dragging ? run.slots[drag!.start] : run.slots[index]
                let offset = dragging ? drag!.translation : .zero
                ControlRearrangeChip(item: item, diameter: slot.width, isPad: isPad, lifted: dragging)
                    .modifier(ControlJiggle(id: item.id, active: !dragging))
                    .scaleEffect(dragging && !reduceMotion ? 1.1 : 1)
                    .shadow(color: .black.opacity(dragging ? 0.4 : 0), radius: dragging ? 10 : 0, y: dragging ? 4 : 0)
                    .frame(width: slot.width + 8, height: slot.height + 8)
                    .contentShape(Rectangle())
                    .position(x: slot.midX + offset.width, y: slot.midY + offset.height)
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
        // The store changed the run under a drag (a profile switch, say):
        // drop the drag rather than move the wrong button.
        .onChange(of: ids) { _ in drag = nil }
    }

    private func dragGesture(for item: ControlRearrangeItem) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                if drag == nil {
                    guard let start = ids.firstIndex(of: item.id), start < count else { return }
                    onHaptic(.latch)
                    withAnimation(.snappy(duration: 0.18)) {
                        drag = Drag(id: item.id, start: start, target: start, translation: .zero)
                    }
                }
                guard var current = drag, current.id == item.id else { return }
                current.translation = value.translation
                let home = run.slots[current.start]
                let point = CGPoint(x: home.midX + value.translation.width, y: home.midY + value.translation.height)
                let target = ControlRearrangement.nearestSlot(to: point, in: Array(run.slots.prefix(count)))
                    ?? current.start
                if target != current.target {
                    current.target = target
                    onHaptic(.selection)
                    withAnimation(settle) { drag = current }
                } else {
                    drag = current
                }
            }
            .onEnded { _ in
                guard let finished = drag, finished.id == item.id else { return }
                withAnimation(settle) {
                    if finished.target != finished.start { onMove(run.kind, finished.start, finished.target) }
                    drag = nil
                }
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
