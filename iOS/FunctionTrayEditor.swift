import SwiftUI
import UIKit

// MARK: - Function Tray editor

/// Edits one Function Tray profile: add, remove, reorder, rename, and pick
/// how each button looks. Built-in actions (Undo, Zoom, Menu Bar, …) can be
/// hidden but not deleted; user-made shortcuts and sequences can be edited
/// and deleted. The same profile feeds the Strip, Overlay and — when a
/// Custom layout uses it — Custom controls.
struct FunctionTrayEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let slot: ControlProfileSlot
    @State private var creating: ShortcutEditorRequest?

    private var profile: FunctionTrayProfile { store.preferences.functionTrayProfile(for: slot) }

    var body: some View {
        List {
            Section {
                ForEach(profile.items) { configuration in
                    let item = configuration.resolvedItem
                    NavigationLink {
                        FunctionItemEditor(store: store, slot: slot, itemID: item.id)
                    } label: {
                        HStack(spacing: 12) {
                            ShortcutButtonFaceView(face: item.face, diameter: 30)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(white: 0.22)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                Text(item.keysDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !configuration.isVisible {
                                Text("Hidden").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(configuration.isVisible ? "Hide" : "Show") {
                            update { profile in
                                if let index = profile.items.firstIndex(where: { $0.id == item.id }) {
                                    profile.items[index].isVisible.toggle()
                                }
                            }
                        }
                        .tint(.gray)
                    }
                }
                .onMove { source, destination in update { $0.moveItems(from: source, to: destination) } }
                .onDelete { offsets in
                    let ids = offsets.map { profile.items[$0].id }
                    update { profile in ids.forEach { profile.removeItem(id: $0) } }
                }
            } footer: {
                Text("Swipe left to remove (built-in actions are hidden instead), swipe right to show or hide. Tap an action to rename it or change how it looks.")
            }
        }
        .navigationTitle("Function Tray — \(slot.title)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                addMenu
                EditButton()
            }
        }
        .sheet(item: $creating) { _ in
            ShortcutButtonEditor(initial: nil) { item in update { $0.addCustomItem(item) } }
        }
    }

    private var addMenu: some View {
        Menu {
            Button { creating = ShortcutEditorRequest(placementID: nil, item: nil) } label: {
                Label("Shortcut or Sequence…", systemImage: "keyboard")
            }
            let hidden = profile.items.filter { !$0.isVisible }
            if !hidden.isEmpty {
                Section("Show a Built-in Action") {
                    ForEach(hidden) { configuration in
                        Button(configuration.resolvedItem.title) {
                            update { profile in
                                if let index = profile.items.firstIndex(where: { $0.id == configuration.id }) {
                                    profile.items[index].isVisible = true
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Add Action", systemImage: "plus")
        }
    }

    private func update(_ change: (inout FunctionTrayProfile) -> Void) {
        var profile = self.profile
        change(&profile)
        store.update { $0.updateFunctionTrayProfile(profile) }
    }
}

/// One Function Tray action: its name, its face, and — for your own
/// actions — what it sends.
private struct FunctionItemEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let slot: ControlProfileSlot
    let itemID: String
    @State private var name = ""
    @State private var editing: ShortcutEditorRequest?

    private var configuration: FunctionTrayItemConfiguration? {
        store.preferences.functionTrayProfile(for: slot).items.first { $0.id == itemID }
    }

    var body: some View {
        Form {
            if let configuration {
                let item = configuration.resolvedItem
                Section {
                    HStack {
                        Spacer()
                        ShortcutButtonFaceView(face: item.face, diameter: 56)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color(white: 0.2)))
                        Spacer()
                    }
                    TextField("Name", text: $name)
                        .onSubmit { update { $0.rename(id: itemID, to: name) } }
                    LabeledContent("Sends", value: item.keysDescription)
                }
                Section("Button Face") {
                    ButtonFacePicker(display: Binding(
                        get: { item.display },
                        set: { value in update { $0.setDisplay(id: itemID, value) } }))
                }
                if !FunctionTrayProfile.isBuiltIn(itemID) {
                    Section {
                        Button("Edit Keys or Steps…") {
                            editing = ShortcutEditorRequest(placementID: itemID, item: configuration.item)
                        }
                    }
                }
                Section {
                    Button(FunctionTrayProfile.isBuiltIn(itemID) ? "Hide from Function Tray" : "Delete Action",
                           role: .destructive) {
                        update { $0.removeItem(id: itemID) }
                    }
                }
            }
        }
        .navigationTitle(configuration?.resolvedItem.title ?? "")
        .onAppear { name = configuration?.resolvedItem.title ?? "" }
        .onDisappear { update { $0.rename(id: itemID, to: name) } }
        .sheet(item: $editing) { request in
            ShortcutButtonEditor(initial: request.item) { item in update { $0.updateCustomItem(item) } }
        }
    }

    private func update(_ change: (inout FunctionTrayProfile) -> Void) {
        var profile = store.preferences.functionTrayProfile(for: slot)
        change(&profile)
        store.update { $0.updateFunctionTrayProfile(profile) }
    }
}

// MARK: - Button face

/// Choose how a one-tap button looks: symbol, short text, emoji, its keys,
/// or its default. The action it performs is unaffected.
struct ButtonFacePicker: View {
    @Binding var display: ShortcutButtonDisplay?

    private enum Style: String, CaseIterable, Identifiable {
        case automatic, symbol, text, emoji, keys
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return String(localized: "Default")
            case .symbol: return String(localized: "Symbol")
            case .text: return String(localized: "Text")
            case .emoji: return String(localized: "Emoji")
            case .keys: return String(localized: "Keys")
            }
        }
    }

    static let symbols = ["star", "bolt", "paintbrush", "pencil", "scissors", "textformat", "underline", "bold",
                          "italic", "folder", "magnifyingglass", "play", "arrow.clockwise", "camera",
                          "square.and.arrow.down", "wand.and.stars", "command", "keyboard", "hammer", "sparkles"]

    private var style: Style {
        switch display {
        case .none: return .automatic
        case .symbol: return .symbol
        case .text: return .text
        case .emoji: return .emoji
        case .keys: return .keys
        }
    }

    var body: some View {
        Picker("Style", selection: Binding(get: { style }, set: { newStyle in
            switch newStyle {
            case .automatic: display = nil
            case .symbol: display = .symbol(Self.symbols[0])
            case .text: display = .text("")
            case .emoji: display = .emoji("⭐️")
            case .keys: display = .keys
            }
        })) {
            ForEach(Style.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        switch display {
        case .symbol(let name):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { display = .symbol(symbol) } label: {
                        Image(systemName: symbol)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(symbol == name ? Color.accentColor.opacity(0.25) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                }
            }
        case .text(let text):
            TextField("Up to \(ShortcutButtonDisplay.maximumTextLength) characters", text: Binding(
                get: { text },
                set: { display = .text(String($0.prefix(ShortcutButtonDisplay.maximumTextLength))) }))
        case .emoji(let emoji):
            TextField("Emoji", text: Binding(get: { emoji }, set: { display = .emoji(String($0.prefix(2))) }))
        case .keys, .none:
            EmptyView()
        }
    }
}

// MARK: - Shortcut / sequence editor

struct ShortcutEditorRequest: Identifiable {
    let placementID: String?
    let item: ShortcutItem?
    var id: String { placementID ?? "new" }
}

/// Makes or edits a one-tap button: one keyboard chord (Control+U, ⌘⇧P,
/// K+3) or a short sequence of existing keyboard and system actions, plus
/// its name and face. Only the existing keyboard/semantic actions — never
/// scripts — and at most `ControlAction.maximumSequenceSteps` steps.
struct ShortcutButtonEditor: View {
    let initial: ShortcutItem?
    /// Modifiers a new chord starts with (a palette's own chord).
    var defaultModifiers: Set<ControlModifier> = []
    let onSave: (ShortcutItem) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case shortcut, sequence
        var id: String { rawValue }
    }

    @State private var kind = Kind.shortcut
    @State private var chord = ChordDraft()
    @State private var steps: [StepDraft] = [StepDraft()]
    @State private var title = ""
    @State private var display: ShortcutButtonDisplay?
    @State private var recording = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ShortcutButtonFaceView(face: item.face, diameter: 56)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color(white: 0.2)))
                        Spacer()
                    }
                    LabeledContent("Sends", value: item.keysDescription).font(.body.monospaced())
                    Picker("Type", selection: $kind) {
                        Text("Keyboard Shortcut").tag(Kind.shortcut)
                        Text("Sequence").tag(Kind.sequence)
                    }
                    .pickerStyle(.segmented)
                }
                switch kind {
                case .shortcut:
                    Section {
                        Button {
                            recording.toggle()
                        } label: {
                            Label(recording ? "Press Keys Now…" : "Record from Keyboard", systemImage: "record.circle")
                        }
                        if recording {
                            ShortcutRecorder { modifiers, keys in
                                chord = ChordDraft(modifiers: modifiers, keys: Array(keys.prefix(KeyboardShortcut.maximumKeys)))
                                recording = false
                            }
                            .frame(height: 1)
                            Text("Press the combination on a hardware keyboard.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Or choose the keys below. Keys are pressed together, then released.")
                    }
                    ChordFields(chord: $chord)
                case .sequence:
                    Section {
                        ForEach($steps) { $step in
                            StepRow(step: $step)
                        }
                        .onDelete { offsets in if steps.count > 1 { steps.remove(atOffsets: offsets) } }
                        .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                        if steps.count < ControlAction.maximumSequenceSteps {
                            Button("Add Step") { steps.append(StepDraft()) }
                        }
                    } header: {
                        Text("Steps")
                    } footer: {
                        Text("Steps run in order, each after the pause before it. Up to \(ControlAction.maximumSequenceSteps) steps.")
                    }
                }
                Section("Button") {
                    TextField("Name", text: $title)
                    ButtonFacePicker(display: $display)
                }
            }
            .navigationTitle(initial == nil ? "New Button" : "Edit Button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(item)
                        dismiss()
                    }
                    .disabled(!action.isValid)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var action: ControlAction {
        switch kind {
        case .shortcut: return .keyboardShortcut(chord.shortcut)
        case .sequence: return .sequence(steps.map(\.step))
        }
    }

    private var item: ShortcutItem {
        var item = ShortcutItem(id: initial?.id ?? UUID().uuidString, title: "", displayKey: "", usage: 4,
                                modifiers: ModifierChord())
        item.action = action
        let keys = item.keysDescription
        item.displayKey = kind == .shortcut ? keys : "⋯"
        item.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? keys : title
        item.display = display
        item.systemImage = nil
        return item
    }

    private func load() {
        guard let initial else {
            if !defaultModifiers.isEmpty { chord = ChordDraft(modifiers: defaultModifiers, keys: [6]) }
            return
        }
        title = initial.title
        display = initial.display ?? initial.systemImage.map(ShortcutButtonDisplay.symbol)
        switch initial.action {
        case .keyboardShortcut(let shortcut):
            kind = .shortcut
            chord = ChordDraft(shortcut)
        case .sequence(let existing):
            kind = .sequence
            steps = existing.map(StepDraft.init)
        case .receiverGesture:
            kind = .sequence
            steps = [StepDraft(ControlActionStep(action: initial.action))]
        }
    }
}

private struct ChordDraft: Equatable {
    var modifiers: Set<ControlModifier> = []
    var keys: [Int] = [24]

    init(modifiers: Set<ControlModifier> = [], keys: [Int] = [24]) {
        self.modifiers = modifiers
        self.keys = keys.isEmpty ? [24] : keys
    }

    init(_ shortcut: KeyboardShortcut) {
        self.init(modifiers: shortcut.modifiers.modifiers, keys: shortcut.usages)
    }

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(usage: keys[0], modifiers: ModifierChord(modifiers), additionalUsages: Array(keys.dropFirst()))
    }
}

private struct ChordFields: View {
    @Binding var chord: ChordDraft

    var body: some View {
        Section("Modifiers") {
            ForEach(ControlModifier.allCases) { modifier in
                Toggle("\(modifier.symbol)  \(modifier.title)", isOn: Binding(
                    get: { chord.modifiers.contains(modifier) },
                    set: { on in if on { chord.modifiers.insert(modifier) } else { chord.modifiers.remove(modifier) } }))
            }
        }
        Section {
            ForEach(chord.keys.indices, id: \.self) { index in
                Picker(chord.keys.count > 1 ? "Key \(index + 1)" : "Key", selection: Binding(
                    get: { chord.keys[index] }, set: { chord.keys[index] = $0 })) {
                    ForEach(appGestureCommandEditableKeys, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            .onDelete { offsets in if chord.keys.count > 1 { chord.keys.remove(atOffsets: offsets) } }
            if chord.keys.count < KeyboardShortcut.maximumKeys {
                Button("Add Another Key") {
                    chord.keys.append(appGestureCommandEditableKeys.first { !chord.keys.contains($0.1) }?.1 ?? 4)
                }
            }
        } header: {
            Text("Keys")
        }
    }
}

private struct StepDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case keys, system }
    let id = UUID()
    var kind = Kind.keys
    var chord = ChordDraft(modifiers: [.command], keys: [14])
    var gesture = ReceiverGesture.showDesktop
    var delayMs = ControlActionStep.defaultDelayMs

    init() {}

    init(_ step: ControlActionStep) {
        delayMs = step.delayMs
        switch step.action {
        case .keyboardShortcut(let shortcut):
            kind = .keys
            chord = ChordDraft(shortcut)
        case .receiverGesture(let name):
            kind = .system
            gesture = ReceiverGesture(rawValue: name) ?? .showDesktop
        case .sequence:
            break
        }
    }

    var step: ControlActionStep {
        ControlActionStep(action: kind == .keys ? .keyboardShortcut(chord.shortcut) : .receiverGesture(gesture.rawValue),
                          delayMs: delayMs)
    }
}

private struct StepRow: View {
    @Binding var step: StepDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Step", selection: $step.kind) {
                Text("Keys").tag(StepDraft.Kind.keys)
                Text("System Action").tag(StepDraft.Kind.system)
            }
            .pickerStyle(.segmented)
            if step.kind == .keys {
                HStack(spacing: 6) {
                    ForEach(ControlModifier.allCases) { modifier in
                        Toggle(modifier.symbol, isOn: Binding(
                            get: { step.chord.modifiers.contains(modifier) },
                            set: { on in
                                if on { step.chord.modifiers.insert(modifier) } else { step.chord.modifiers.remove(modifier) }
                            }))
                        .toggleStyle(.button)
                    }
                    Spacer()
                    Picker("Key", selection: Binding(get: { step.chord.keys[0] }, set: { step.chord.keys[0] = $0 })) {
                        ForEach(appGestureCommandEditableKeys, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
            } else {
                Picker("Action", selection: $step.gesture) {
                    ForEach(ReceiverGesture.oneTapActions, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Stepper("Then wait \(step.delayMs) ms", value: $step.delayMs,
                    in: 0...ControlAction.maximumStepDelayMs, step: 50)
                .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}

extension ReceiverGesture {
    /// Semantic actions a button or sequence step may use.
    static let oneTapActions: [ReceiverGesture] = [.menuBar, .showDesktop, .controlCenter, .missionControl,
                                                   .appExpose, .launchpad, .spotlight, .nextSpace, .previousSpace]

    var title: String {
        switch self {
        case .missionControl: return String(localized: "Mission Control")
        case .appExpose: return String(localized: "App Exposé")
        case .nextSpace: return String(localized: "Next Space")
        case .previousSpace: return String(localized: "Previous Space")
        case .showDesktop: return String(localized: "Show Desktop")
        case .launchpad: return String(localized: "Launchpad")
        case .spotlight: return String(localized: "Spotlight")
        case .controlCenter: return String(localized: "Control Center")
        case .menuBar: return String(localized: "Menu Bar")
        }
    }
}

/// Captures one key combination from a hardware keyboard: modifiers held,
/// plus every ordinary key pressed before the first release.
struct ShortcutRecorder: UIViewRepresentable {
    let onRecord: (Set<ControlModifier>, [Int]) -> Void

    func makeUIView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
    }

    final class RecorderView: UIView {
        var onRecord: ((Set<ControlModifier>, [Int]) -> Void)?
        private var keys: [Int] = []
        private var modifiers: Set<ControlModifier> = []

        override var canBecomeFirstResponder: Bool { true }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key else { continue }
                modifiers.formUnion(Self.modifiers(key.modifierFlags))
                let usage = key.keyCode.rawValue
                if KeyboardShortcut.validUsages.contains(usage), !keys.contains(usage) { keys.append(usage) }
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard !keys.isEmpty else { return }
            onRecord?(modifiers, keys)
            keys = []
            modifiers = []
        }

        private static func modifiers(_ flags: UIKeyModifierFlags) -> Set<ControlModifier> {
            var result: Set<ControlModifier> = []
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.alternate) { result.insert(.option) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.shift) { result.insert(.shift) }
            return result
        }
    }
}
