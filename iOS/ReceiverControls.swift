import SwiftUI
import UIKit

@MainActor
final class ReceiverControlStore: ObservableObject {
    @Published private(set) var preferences: ReceiverControlPreferences
    private let repository: ReceiverControlPreferencesRepository
    var onInputResetRequested: (() -> Void)?

    init(repository: ReceiverControlPreferencesRepository = ReceiverControlPreferencesRepository()) {
        self.repository = repository
        preferences = repository.load()
    }

    var activeProfile: ControlProfile {
        preferences.profile(for: preferences.activeControlProfile)
    }

    func update(_ change: (inout ReceiverControlPreferences) -> Void) {
        let previous = preferences
        let previousActiveProfile = activeProfile
        change(&preferences)
        repository.save(preferences)
        let activeProfileChanged = previous.activeControlProfile != preferences.activeControlProfile
            || previousActiveProfile != activeProfile
        if (previous.trayEnabled && !preferences.trayEnabled) || activeProfileChanged {
            onInputResetRequested?()
        }
    }

    func updateActiveProfile(_ change: (inout ControlProfile) -> Void) {
        var profile = activeProfile
        change(&profile)
        update { $0.updateProfile(profile) }
    }

    func applyRemote(trayEnabled: Bool?, keyboardButtonEnabled: Bool?) {
        update {
            if let trayEnabled { $0.trayEnabled = trayEnabled }
            if let keyboardButtonEnabled { $0.keyboardButtonEnabled = keyboardButtonEnabled }
        }
    }
}

@MainActor
final class ReceiverHaptics {
    private let enabled: () -> Bool

    init(enabled: @escaping () -> Bool) { self.enabled = enabled }

    func play(_ event: ControlHapticEvent) {
        guard ControlHapticPolicy.shouldPlay(event, enabled: enabled()) else { return }
        switch event {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .latch, .expandCollapse, .profileChange, .settings:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .confirmation, .reset:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

private struct ControlFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReceiverControlOverlay: View {
    @ObservedObject var store: ReceiverControlStore
    @ObservedObject var receiver: StreamReceiver
    @Binding var keyboardActive: Bool
    @Binding var showSettings: Bool
    let keyboardAvailable: Bool
    let keyboardVisibleRect: CGRect?
    let containerSize: CGSize
    let safeInsets: EdgeInsets
    let haptics: ReceiverHaptics

    @State private var interaction = ControlInteractionState()
    @State private var frames: [String: CGRect] = [:]
    @State private var holdTask: Task<Void, Never>?
    @State private var initiatingModifier: ControlModifier?
    @State private var initiatingItem: ControlTrayItem?
    @State private var gestureActive = false
    @State private var lastHoveredModifier: ControlModifier?

    /// Every control is its own free-floating circle: there is no tray card
    /// and no palette card, so nothing blurs the stream except the chips
    /// themselves. The geometry below has to agree with the chip sizes — the
    /// tray/palette frames it produces are what the gesture region hit-tests.
    private enum Metrics {
        static let trayItem: CGFloat = 40
        static let trayGap: CGFloat = 4
        static let collapsed: CGFloat = 46
        static let paletteKey: CGFloat = 38
        static let paletteGap: CGFloat = 5
        /// Slack around the chips so a slightly-off finger still lands inside
        /// the gesture region.
        static let touchSlack: CGFloat = 4
    }

    private var profile: ControlProfile { store.activeProfile }
    private var controls: [ControlTrayItem] {
        // Collapsed means the tray is gone — a single gear remains so
        // Settings (where it is un-collapsed) stays reachable without a
        // shake. It ignores per-profile visibility for that reason.
        guard !store.preferences.trayCollapsed else { return [.settings] }
        return profile.visibleTrayItems.filter {
            if $0.modifier != nil {
                return receiver.macProtocolVersion >= WireProtocol.receiverControlsWireVersion
            }
            return $0 != .keyboard || (store.preferences.keyboardButtonEnabled && keyboardAvailable)
        }
    }

    var body: some View {
        if store.preferences.trayEnabled {
            let portrait = containerSize.height > containerSize.width
            let collapsed = store.preferences.trayCollapsed
            let count = max(controls.count, 1)
            let traySize = calculatedTraySize(collapsed: collapsed, portrait: portrait, count: count)
            let paletteChord = interaction.paletteChord
            let actions = paletteChord.map(profile.actions(for:)) ?? []
            let paletteSize = calculatedPaletteSize(actions: actions, portrait: portrait)
            let layout = ControlTrayGeometry.layout(
                container: CGRect(origin: .zero, size: containerSize),
                safeInsets: ControlSafeInsets(top: safeInsets.top, leading: safeInsets.leading,
                                              bottom: safeInsets.bottom, trailing: safeInsets.trailing),
                keyboardVisibleRect: keyboardVisibleRect,
                portrait: portrait,
                side: store.preferences.preferredLandscapeSide,
                traySize: traySize,
                paletteSize: paletteSize)

            ZStack(alignment: .topLeading) {
                if let paletteChord {
                    shortcutPalette(actions, portrait: portrait, chord: paletteChord)
                        .frame(width: layout.paletteFrame.width, height: layout.paletteFrame.height)
                        .position(x: layout.paletteFrame.midX, y: layout.paletteFrame.midY)
                        .transition(.scale(scale: 0.75).combined(with: .opacity))
                }

                if collapsed {
                    Image(systemName: ControlTrayItem.settings.displayLabel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Metrics.collapsed, height: Metrics.collapsed)
                        .background(frameReader("tray:more"))
                        .background(chip(selected: false))
                        .accessibilityLabel(ControlTrayItem.settings.title)
                        .position(x: layout.trayFrame.midX, y: layout.trayFrame.midY)
                } else {
                    controlsRow(axis: layout.axis == .horizontal ? .horizontal : .vertical)
                        .frame(width: layout.trayFrame.width, height: layout.trayFrame.height)
                        .position(x: layout.trayFrame.midX, y: layout.trayFrame.midY)
                }

                if let selected = selectedAction(in: actions) {
                    shortcutHUD(selected)
                        .position(x: containerSize.width / 2,
                                  y: max(safeInsets.top + 48, layout.paletteFrame.minY - 34))
                        .transition(.opacity.combined(with: .scale))
                }

                Color.clear
                    .frame(width: containerSize.width, height: containerSize.height)
                    .contentShape(ControlRegionShape(tray: layout.trayFrame,
                                                     palette: paletteChord == nil ? nil : layout.paletteFrame))
                    .gesture(controlGesture())
            }
            .coordinateSpace(name: "receiverControls")
            .frame(width: containerSize.width, height: containerSize.height,
                   alignment: .topLeading)
            .onPreferenceChange(ControlFramePreference.self) { frames = $0 }
            .onAppear {
                if !interaction.latchedModifiers.isEmpty || !interaction.temporaryModifiers.isEmpty {
                    apply(interaction.resetAll())
                }
            }
            .animation(.snappy(duration: 0.24), value: store.preferences.trayCollapsed)
            .animation(.snappy(duration: 0.2), value: interaction.phase)
            .onChange(of: receiver.connected) { connected in
                if !connected { apply(interaction.resetAll()) }
            }
            .onChange(of: receiver.displayState) { state in
                if state != .running { apply(interaction.resetAll()) }
            }
            .onChange(of: store.preferences.activeControlProfile) { _ in
                apply(interaction.resetAll())
            }
            // The Mac released its synthetic input state; drop the matching
            // local latch silently. A Mac-originated refresh is not a
            // receiver-confirmed action and must not buzz.
            .onChange(of: receiver.inputResetGeneration) { _ in
                apply(interaction.resetAll())
            }
            .onChange(of: receiver.controlResetGeneration) { _ in
                apply(interaction.resetAll())
            }
        }
    }

    private func calculatedTraySize(collapsed: Bool, portrait: Bool, count: Int) -> CGSize {
        let thickness = Metrics.trayItem + Metrics.touchSlack
        guard !collapsed else {
            return CGSize(width: Metrics.collapsed + Metrics.touchSlack,
                          height: Metrics.collapsed + Metrics.touchSlack)
        }
        let length = CGFloat(count) * Metrics.trayItem
            + CGFloat(Swift.max(0, count - 1)) * Metrics.trayGap + Metrics.touchSlack
        return portrait
            ? CGSize(width: length, height: thickness)
            : CGSize(width: thickness, height: length)
    }

    private func calculatedPaletteSize(actions: [ShortcutItem], portrait: Bool) -> CGSize {
        let count = max(actions.count, 1)
        func span(_ n: Int) -> CGFloat {
            CGFloat(n) * Metrics.paletteKey
                + CGFloat(Swift.max(0, n - 1)) * Metrics.paletteGap + Metrics.touchSlack
        }
        guard portrait else { return CGSize(width: span(1), height: span(count)) }
        let rows = actions.count > 8 ? 2 : 1
        let columns = max(1, Int(ceil(Double(count) / Double(rows))))
        return CGSize(width: span(columns), height: span(rows))
    }

    /// The one visual primitive: a translucent circle. Deliberately lighter
    /// than a system material card — it has to read over live video without
    /// frosting the desktop behind it.
    private func chip(selected: Bool) -> some View {
        Circle()
            .fill(.ultraThinMaterial)
            .opacity(selected ? 0.9 : 0.45)
            .overlay(Circle().fill(selected ? Color.white.opacity(0.82)
                                            : Color.white.opacity(0.07)))
            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.55 : 0.28),
                                           lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
    }

    @ViewBuilder
    private func controlsRow(axis: Axis) -> some View {
        let stack = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: Metrics.trayGap))
            : AnyLayout(VStackLayout(spacing: Metrics.trayGap))
        stack {
            ForEach(controls) { item in
                if let modifier = item.modifier {
                    modifierButton(modifier)
                } else {
                    actionButton(item)
                }
            }
        }
    }

    private func modifierButton(_ modifier: ControlModifier) -> some View {
        let selected = interaction.latchedModifiers.contains(modifier)
            || interaction.temporaryModifiers.contains(modifier)
        return Text(modifier.symbol)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: Metrics.trayItem, height: Metrics.trayItem)
            .background(frameReader("modifier:\(modifier.rawValue)"))
            .background(chip(selected: selected))
            .accessibilityLabel(modifier.title)
            .accessibilityValue(selected ? "On" : "Off")
    }

    private func actionButton(_ item: ControlTrayItem) -> some View {
        Group {
            if item == .escape || item == .tab {
                Text(item.displayLabel).font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: item.displayLabel)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: Metrics.trayItem, height: Metrics.trayItem)
        .background(frameReader("tray:\(item.rawValue)"))
        .background(chip(selected: false))
        .accessibilityLabel(item.title)
    }

    private func shortcutPalette(_ actions: [ShortcutItem], portrait: Bool,
                                 chord: ModifierChord) -> some View {
        Group {
            if actions.isEmpty {
                Text("No shortcuts for \(chord.displayName)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial).opacity(0.45))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
            } else {
                let rows = portrait ? (actions.count > 8 ? 2 : 1) : actions.count
                Grid(horizontalSpacing: Metrics.paletteGap, verticalSpacing: Metrics.paletteGap) {
                    ForEach(0..<rows, id: \.self) { row in
                        GridRow {
                            ForEach(Array(actions.enumerated()).filter { $0.offset % rows == row },
                                    id: \.element.id) { _, action in
                                shortcutButton(action, portrait: portrait)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shortcutButton(_ action: ShortcutItem, portrait: Bool) -> some View {
        let selected = interaction.selectedActionID == action.id
        return Text(action.displayKey)
        .font(.system(size: action.displayKey.count > 2 ? 11 : 15, weight: .semibold))
        .minimumScaleFactor(0.7)
        .lineLimit(1)
        .foregroundStyle(selected ? Color.black : Color.white)
        .frame(width: Metrics.paletteKey, height: Metrics.paletteKey)
        .background(frameReader("action:\(action.id)"))
        .background(chip(selected: selected))
        .scaleEffect(selected ? 1.12 : 1)
        .animation(.snappy(duration: 0.14), value: selected)
        .accessibilityLabel(action.title)
    }

    /// Shows the combination the finger is currently on — the live chord,
    /// not the shortcut's stored one, so a latched modifier reads correctly.
    private func shortcutHUD(_ action: ShortcutItem) -> some View {
        Text(interaction.activeChord.hudText(for: action.displayKey))
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.5))
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
    }

    private func frameReader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ControlFramePreference.self,
                                   value: [id: proxy.frame(in: .named("receiverControls"))])
        }
    }

    private func controlGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("receiverControls"))
            .onChanged { value in
                if !gestureActive {
                    gestureActive = true
                    initiatingItem = trayItem(at: value.startLocation)
                    if let modifier = initiatingItem?.modifier {
                        initiatingModifier = modifier
                        interaction.press(modifier)
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled, interaction.phase == .pressed(modifier) else { return }
                            apply(interaction.beginPalette(with: modifier))
                        }
                    } else if let actionID = action(at: value.startLocation)?.id {
                        apply(interaction.selectAction(actionID))
                    }
                }

                // Sliding onto another modifier only builds a chord during a
                // hold; a latched palette is browsed, not rebuilt.
                if case .palette = interaction.phase {
                    let hovered = modifier(at: value.location)
                    if hovered != lastHoveredModifier {
                        lastHoveredModifier = hovered
                        if let hovered { apply(interaction.addTemporaryModifier(hovered)) }
                    }
                }
                // Highlight tracking runs for any visible palette — including
                // the persistent one a latched modifier leaves on screen —
                // except when the gesture began on a plain tray button.
                if interaction.paletteChord != nil, initiatingItem?.modifier != nil || initiatingItem == nil {
                    apply(interaction.selectAction(action(at: value.location)?.id))
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                let finishedOn = selectedAction(under: value.location)
                if let modifier = initiatingModifier {
                    // A press that never became a hold is a latch toggle;
                    // otherwise the hold ends on whatever key it is over.
                    if interaction.phase == .pressed(modifier) {
                        apply(interaction.tap(modifier))
                    } else {
                        apply(interaction.finish(with: finishedOn))
                    }
                } else if let finishedOn {
                    // Tap on a latched chord's palette: fire it and keep the
                    // latch, so ⌘ then C then V is two shortcuts, not one.
                    apply(interaction.finish(with: finishedOn))
                } else if let item = initiatingItem,
                          frames["tray:\(item.rawValue)"]?.contains(value.location) == true {
                    perform(item)
                } else if interaction.paletteChord != nil {
                    apply(interaction.finish(with: nil))
                }
                initiatingModifier = nil
                initiatingItem = nil
                lastHoveredModifier = nil
                gestureActive = false
            }
    }

    private func trayItem(at point: CGPoint) -> ControlTrayItem? {
        controls.first { item in
            if let modifier = item.modifier {
                return frames["modifier:\(modifier.rawValue)"]?.contains(point) == true
            }
            return frames["tray:\(item.rawValue)"]?.contains(point) == true
        }
    }

    private func modifier(at point: CGPoint) -> ControlModifier? {
        ControlModifier.allCases.first { frames["modifier:\($0.rawValue)"]?.contains(point) == true }
    }

    private func action(at point: CGPoint) -> ShortcutItem? {
        profile.actions(for: interaction.activeChord).first {
            frames["action:\($0.id)"]?.contains(point) == true
        }
    }

    private func selectedAction(in actions: [ShortcutItem]) -> ShortcutItem? {
        actions.first { $0.id == interaction.selectedActionID }
    }

    /// The highlighted shortcut, but only if the finger actually lifted on it
    /// — sliding off a key must cancel it, not fire it.
    private func selectedAction(under point: CGPoint) -> ShortcutItem? {
        profile.actions(for: interaction.activeChord).first {
            $0.id == interaction.selectedActionID
                && frames["action:\($0.id)"]?.contains(point) == true
        }
    }

    private func perform(_ item: ControlTrayItem) {
        switch item {
        case .escape:
            receiver.sendKeyboardPress(usage: 41)
            haptics.play(.confirmation)
        case .tab:
            receiver.sendKeyboardPress(usage: 43)
            haptics.play(.confirmation)
        case .keyboard:
            keyboardActive.toggle()
            haptics.play(.selection)
        case .settings:
            apply(interaction.resetAll())
            showSettings = true
            haptics.play(.settings)
        default: break
        }
    }

    private func apply(_ effects: [ControlInteractionEffect]) {
        for effect in effects {
            switch effect {
            case .modifierDown(let modifier): receiver.sendModifier(modifier, down: true)
            case .modifierUp(let modifier): receiver.sendModifier(modifier, down: false)
            case .execute(let item):
                if case .keyboardShortcut(let shortcut) = item.action {
                    receiver.sendKeyboardPress(usage: shortcut.usage,
                                               modifiers: shortcut.modifiers.modifiers.map(\.rawValue))
                }
            case .haptic(let event): haptics.play(event)
            }
        }
    }
}

private struct ControlRegionShape: Shape {
    var tray: CGRect
    var palette: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(tray)
        if let palette { path.addRect(palette) }
        return path
    }
}

struct ControlProfileEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics

    var body: some View {
        List {
            Section("Main Tray") {
                ForEach(store.activeProfile.trayItems) { configuration in
                    Toggle(configuration.item.title, isOn: Binding(
                        get: { store.activeProfile.trayItems.first(where: { $0.item == configuration.item })?.isVisible ?? false },
                        set: { visible in
                            store.updateActiveProfile { profile in
                                if let index = profile.trayItems.firstIndex(where: { $0.item == configuration.item }) {
                                    profile.trayItems[index].isVisible = visible
                                }
                            }
                        }))
                }
                .onMove { source, destination in
                    store.updateActiveProfile { $0.moveTrayItems(from: source, to: destination) }
                }
            }

            Section("Shortcut Palettes") {
                ForEach(Self.supportedChords) { chord in
                    NavigationLink {
                        ChordPaletteEditor(store: store, chord: chord, haptics: haptics)
                    } label: {
                        LabeledContent(chord.displayName,
                                       value: "\(store.activeProfile.actions(for: chord).count)")
                    }
                }
            }
        }
        .navigationTitle("Edit \(store.preferences.activeControlProfile.title)")
        .toolbar { EditButton() }
    }

    static let supportedChords: [ModifierChord] = (1..<16).map { mask in
        ModifierChord(Set(ControlModifier.allCases.enumerated().compactMap { index, modifier in
            mask & (1 << index) == 0 ? nil : modifier
        }))
    }
}

struct ChordPaletteEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    let haptics: ReceiverHaptics
    @State private var adding = false

    var body: some View {
        List {
            ForEach(store.activeProfile.actions(for: chord)) { action in
                NavigationLink {
                    ShortcutItemEditor(store: store, chord: chord, itemID: action.id)
                } label: {
                    LabeledContent(action.title, value: action.displayKey)
                }
            }
            .onMove { source, destination in
                store.updateActiveProfile { $0.moveActions(for: chord, from: source, to: destination) }
            }
            .onDelete { offsets in
                store.updateActiveProfile { profile in
                    var actions = profile.actions(for: chord)
                    actions.remove(atOffsets: offsets)
                    profile.setActions(actions, for: chord)
                }
            }
        }
        .navigationTitle(chord.displayName)
        .toolbar {
            EditButton()
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                NewShortcutEditor(store: store, chord: chord, isPresented: $adding)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Restore This Palette") {
                let defaults = ControlProfile.canonical().actions(for: chord)
                store.updateActiveProfile { $0.setActions(defaults, for: chord) }
                haptics.play(.reset)
            }
            .buttonStyle(.bordered).padding(8)
        }
    }
}

private let editableShortcutKeys: [(String, Int)] = {
    let letters = zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4...29).map { (String($0), $1) }
    return letters + [("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34),
                      ("Esc", 41), ("Space", 44), ("Return", 40), ("Tab", 43)]
}()

struct ShortcutItemEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    let itemID: String

    private var item: ShortcutItem? {
        store.activeProfile.actions(for: chord).first(where: { $0.id == itemID })
    }

    var body: some View {
        Form {
            if let item {
                TextField("Name", text: itemBinding(item, keyPath: \.title))
                Picker("Key", selection: usageBinding(item)) {
                    ForEach(editableShortcutKeys, id: \.1) { Text($0.0).tag($0.1) }
                }
                Section("Modifiers") {
                    ForEach(ControlModifier.allCases) { modifier in
                        Toggle(modifier.title, isOn: modifierBinding(item, modifier))
                    }
                }
            }
        }
        .navigationTitle("Shortcut")
    }

    private func update(_ transform: (inout ShortcutItem) -> Void) {
        store.updateActiveProfile { profile in
            var actions = profile.actions(for: chord)
            guard let index = actions.firstIndex(where: { $0.id == itemID }) else { return }
            transform(&actions[index])
            profile.setActions(actions, for: chord)
        }
    }

    private func itemBinding(_ item: ShortcutItem, keyPath: WritableKeyPath<ShortcutItem, String>) -> Binding<String> {
        Binding(get: { self.item?[keyPath: keyPath] ?? item[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func usageBinding(_ item: ShortcutItem) -> Binding<Int> {
        Binding(get: {
            guard let current = self.item, case .keyboardShortcut(let shortcut) = current.action else { return 4 }
            return shortcut.usage
        }, set: { usage in
            update {
                let key = editableShortcutKeys.first(where: { $0.1 == usage })?.0 ?? "Key"
                $0.displayKey = key
                $0.action = .keyboardShortcut(KeyboardShortcut(usage: usage, modifiers: chord))
            }
        })
    }

    private func modifierBinding(_ item: ShortcutItem, _ modifier: ControlModifier) -> Binding<Bool> {
        Binding(get: {
            let current = self.item ?? item
            guard case .keyboardShortcut(let shortcut) = current.action else { return false }
            return shortcut.modifiers.contains(modifier)
        }, set: { enabled in
            update {
                guard case .keyboardShortcut(var shortcut) = $0.action else { return }
                var values = shortcut.modifiers.modifiers
                if enabled { values.insert(modifier) } else { values.remove(modifier) }
                shortcut.modifiers = ModifierChord(values)
                $0.action = .keyboardShortcut(shortcut)
            }
        })
    }
}

struct NewShortcutEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let chord: ModifierChord
    @Binding var isPresented: Bool
    @State private var title = "Shortcut"
    @State private var usage = 4

    var body: some View {
        Form {
            TextField("Name", text: $title)
            Picker("Key", selection: $usage) {
                ForEach(editableShortcutKeys, id: \.1) { Text($0.0).tag($0.1) }
            }
        }
        .navigationTitle("Add Shortcut")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let key = editableShortcutKeys.first(where: { $0.1 == usage })?.0 ?? "Key"
                    store.updateActiveProfile { profile in
                        var actions = profile.actions(for: chord)
                        actions.append(ShortcutItem(title: title, displayKey: key,
                                                    usage: usage, modifiers: chord))
                        profile.setActions(actions, for: chord)
                    }
                    isPresented = false
                }
            }
        }
    }
}
