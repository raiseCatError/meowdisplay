import SwiftUI
import UIKit

// MARK: - Custom layout list (Settings → Controls, iPad only)

/// The user's Custom layouts, plus `Create Custom Layout` until
/// `CustomControlLayout.maximumCount` exist, and Import. Nothing is
/// pre-created. Spatial editing happens in `CustomLayoutEditorScreen`;
/// Settings only manages the layouts.
struct CustomLayoutListSection: View {
    @ObservedObject var store: ReceiverControlStore
    /// Presented by the page that owns the Form (`CustomLayoutPresentations`)
    /// — a presentation attached to a List section can be torn down when
    /// the list re-renders.
    @Binding var editorRequest: CustomLayoutEditorRequest?
    @Binding var deleting: CustomControlLayout?

    var body: some View {
        Section {
            if store.preferences.customLayouts.count > 1 {
                Picker("Active Layout", selection: Binding(
                    get: { store.preferences.activeCustomLayout?.id ?? "" },
                    set: { id in store.update { $0.activeCustomLayoutID = id } })) {
                    ForEach(store.preferences.customLayouts) { Text($0.name).tag($0.id) }
                }
            }
            ForEach(store.preferences.customLayouts) { layout in
                NavigationLink {
                    CustomLayoutDetailPage(store: store, layoutID: layout.id)
                } label: {
                    HStack {
                        Text(layout.name)
                        Spacer()
                        if layout.id == store.preferences.activeCustomLayout?.id {
                            Text("Active").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button { editorRequest = .init(layoutID: layout.id, preview: false) } label: {
                        Label("Edit Layout", systemImage: "square.and.pencil")
                    }
                    Button { editorRequest = .init(layoutID: layout.id, preview: true) } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                    if let code = try? CustomLayoutShareCode.encode(layout, functionItems: store.functionItems(for: layout)) {
                        ShareLink(item: code, subject: Text(layout.name)) {
                            Label("Share Layout", systemImage: "square.and.arrow.up")
                        }
                        Button { UIPasteboard.general.string = code } label: {
                            Label("Copy Share Code", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { deleting = layout } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { store.preferences.customLayouts[$0].id }
                store.update { preferences in ids.forEach { preferences.deleteCustomLayout($0) } }
            }
            if store.preferences.canCreateCustomLayout {
                Button {
                    store.update { $0.createCustomLayout() }
                } label: {
                    Label("Create Custom Layout", systemImage: "plus")
                }
            }
            NavigationLink {
                CustomLayoutImportPage(store: store)
            } label: {
                Label("Import Layout…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Custom Layouts")
        } footer: {
            Text("Up to \(CustomControlLayout.maximumCount) layouts, each with its own landscape and portrait arrangement. New layouts start from the radial corner template. Touch and hold a layout to edit, preview or share it.")
        }
    }
}

/// The Custom layout list's editor cover and delete confirmation, attached
/// to the page's Form rather than to the list section itself.
struct CustomLayoutPresentations: ViewModifier {
    @ObservedObject var store: ReceiverControlStore
    @Binding var editorRequest: CustomLayoutEditorRequest?
    @Binding var deleting: CustomControlLayout?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $editorRequest) { request in
                CustomLayoutEditorScreen(store: store, layoutID: request.layoutID, startsInPreview: request.preview)
            }
            .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Layout", role: .destructive) {
                    if let id = deleting?.id { store.update { $0.deleteCustomLayout(id) } }
                    deleting = nil
                }
            }
    }
}

extension ReceiverControlStore {
    /// The Function actions a Custom layout draws from: its chosen profile,
    /// or the active one.
    func functionItems(for layout: CustomControlLayout?) -> [ShortcutItem] {
        preferences.functionTrayProfile(for: layout?.functionProfile ?? preferences.activeFunctionTrayProfile).allItems
    }
}

struct CustomLayoutEditorRequest: Identifiable {
    let layoutID: String
    let preview: Bool
    var id: String { layoutID + (preview ? ".preview" : ".edit") }
}

// MARK: - Layout detail (Settings)

/// One layout's page: name, the editor, preview, sharing and deletion.
private struct CustomLayoutDetailPage: View {
    @ObservedObject var store: ReceiverControlStore
    let layoutID: String
    @State private var name = ""
    @State private var editorRequest: CustomLayoutEditorRequest?
    @State private var confirmingDelete = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    private var layout: CustomControlLayout? { store.preferences.customLayouts.first { $0.id == layoutID } }

    var body: some View {
        Form {
            if let layout {
                Section {
                    TextField("Layout Name", text: $name)
                        .onSubmit { store.update { $0.renameCustomLayout(layoutID, to: name) } }
                    if store.preferences.activeCustomLayout?.id != layoutID {
                        Button("Use This Layout") { store.update { $0.activeCustomLayoutID = layoutID } }
                    } else {
                        LabeledContent("Status", value: String(localized: "Active"))
                    }
                }
                Section {
                    Button { editorRequest = .init(layoutID: layoutID, preview: false) } label: {
                        Label("Edit Layout", systemImage: "square.and.pencil")
                    }
                    Button { editorRequest = .init(layoutID: layoutID, preview: true) } label: {
                        Label("Preview", systemImage: "play.rectangle")
                    }
                } footer: {
                    Text("The editor opens full screen, with separate landscape and portrait arrangements. Preview lets you try the layout without sending anything to your Mac.")
                }
                Section {
                    Toggle(isOn: Binding(get: { layout.twoHandAssist },
                                         set: { value in
                                             var updated = layout
                                             updated.twoHandAssist = value
                                             store.update { $0.updateCustomLayout(updated) }
                                         })) {
                        HStack(spacing: 6) {
                            Text("Two-Hand Assist")
                            InfoButton(title: "Two-Hand Assist", text: HelpText.twoHandAssist)
                        }
                    }
                }
                if let code = try? CustomLayoutShareCode.encode(layout, functionItems: store.functionItems(for: layout)) {
                    Section {
                        ShareLink(item: code, subject: Text(layout.name),
                                  message: Text("A MeowDisplay Custom layout. Import it in Settings → Controls → Custom Layouts.")) {
                            Label("Share Layout", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy Share Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    } footer: {
                        Text("A share code contains only this layout — positions, sizes, palettes, shortcut buttons and Two-Hand Assist. Never pairing, devices or permissions.")
                    }
                }
                Section {
                    Button("Delete Layout", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(layout?.name ?? "")
        .onAppear { name = layout?.name ?? "" }
        .onDisappear { store.update { $0.renameCustomLayout(layoutID, to: name) } }
        .fullScreenCover(item: $editorRequest) { request in
            CustomLayoutEditorScreen(store: store, layoutID: request.layoutID, startsInPreview: request.preview)
        }
        .confirmationDialog("Delete this layout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Layout", role: .destructive) {
                store.update { $0.deleteCustomLayout(layoutID) }
                dismiss()
            }
        }
    }
}

// MARK: - Import

/// Import Layout → paste (field or Paste from Clipboard) → Validate →
/// review → Import. A pushed page in Settings' own navigation, so nothing
/// can dismiss it early: it closes only after a successful import, or when
/// the user navigates back. Importing only adds a layout; it never runs
/// anything, and a bad code changes nothing. See `CustomLayoutImportFlow`.
struct CustomLayoutImportPage: View {
    @ObservedObject var store: ReceiverControlStore
    @Environment(\.dismiss) private var dismiss
    @State private var flow = CustomLayoutImportFlow()

    var body: some View {
        Form {
            Section {
                TextField("MDL1-…", text: Binding(get: { flow.code }, set: { flow.edit($0) }), axis: .vertical)
                    .lineLimit(3...8)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    flow.paste(UIPasteboard.general.string)
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                Button("Validate") { flow.validate() }
                    .disabled(!flow.canValidate)
            } header: {
                Text("Share Code")
            } footer: {
                Text("Paste a code someone shared with you. It starts with MDL1-.")
            }
            switch flow.stage {
            case .entering:
                EmptyView()
            case .reviewing(let summary), .limitReached(let summary):
                Section("Layout") {
                    LabeledContent("Name", value: summary.layout.name)
                    LabeledContent("Landscape", value: controlCount(summary.landscapeControls))
                    LabeledContent("Portrait", value: controlCount(summary.portraitControls))
                    LabeledContent("Shortcut Buttons", value: "\(summary.shortcutCount)")
                    LabeledContent("Two-Hand Assist", value: summary.twoHandAssist ? String(localized: "On") : String(localized: "Off"))
                    ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warningText(warning), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
                Section {
                    if case .limitReached = flow.stage {
                        Text("You already have \(CustomControlLayout.maximumCount) Custom layouts. Delete one first, then import this one.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Import Layout") {
                            store.update { flow.importLayout(into: &$0) }
                        }
                    }
                } footer: {
                    Text("Importing adds a new layout. Its shortcut buttons do nothing until you tap them.")
                }
            case .failed(let error):
                Section {
                    Label(errorText(error), systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            case .imported:
                EmptyView()
            }
        }
        .navigationTitle("Import Layout")
        .onChange(of: flow.isFinished) { finished in if finished { dismiss() } }
    }

    private func controlCount(_ count: Int) -> String {
        String(localized: "\(count) controls")
    }

    private func warningText(_ warning: CustomLayoutShareCode.ImportSummary.Warning) -> String {
        switch warning {
        case .skippedControls(let count):
            return String(localized: "\(count) controls from a newer MeowDisplay were skipped.")
        case .unknownActions(let count):
            return String(localized: "\(count) Function actions aren’t available in this version and won’t appear.")
        }
    }

    private func errorText(_ error: CustomLayoutShareCode.ShareCodeError) -> String {
        switch error {
        case .notAShareCode: return String(localized: "This isn’t a MeowDisplay layout share code.")
        case .unsupportedVersion: return String(localized: "This layout was shared from a newer MeowDisplay. Update to import it.")
        case .corrupted: return String(localized: "This share code is damaged or incomplete. Copy it again.")
        case .tooLarge: return String(localized: "This share code is too large.")
        }
    }
}

// MARK: - Help

private enum HelpText {
    static let alignmentGuides = String(localized: "Dots or grid lines for lining controls up while you edit. They aren’t part of your Mac’s screen and never appear during normal use.")
    static let snapToEdges = String(localized: "A control dropped near the edge of the usable area, or near its center lines, settles exactly against it.")
    static let snapToGuides = String(localized: "A control dropped near a guide line settles exactly on it. Needs Alignment Guides on.")
    static let paletteStyle = String(localized: "How a modifier’s shortcuts appear while you hold or latch it. Wheel surrounds it with wedge-shaped segments; Arc fans them along the next ring out; Ring circles it; Row and Column line them up.")
    static let paletteDistance = String(localized: "How far the shortcuts sit from the modifier.")
    static let paletteDirection = String(localized: "Which way the shortcuts open. Toward Screen Center keeps them clear of the edges.")
    static let twoHandAssist = String(localized: "While a modifier is held or latched, modifier keys appear on the opposite side, so your other hand can add to the same chord. Otherwise that side offers actions like Undo, Redo and Zoom.")
    static let orientations = String(localized: "Landscape and portrait are arranged separately — MeowDisplay uses whichever matches how you hold your iPad.")
    static let systemArea = String(localized: "The shaded strips are the system’s areas (status bar and Home indicator). Controls always stay inside the dashed outline.")
}

/// A small ⓘ that explains one concept in a popover.
private struct InfoButton: View {
    let title: LocalizedStringKey
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("About \(Text(title))"))
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300)
        }
    }
}

private struct CustomLayoutHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Place utility controls", "Keyboard, Escape and Tab sit on the inner arc around Settings. Drag any control where your thumb can reach it.")
                    step(2, "Place modifier controls", "⌘ ⌥ ⌃ ⇧ form the next arc out. Hold or tap a modifier to use it.")
                    step(3, "Configure shortcut palettes", "Select a modifier to choose how its shortcuts appear. By default they bloom on the arc just outside the modifiers.")
                    step(4, "Optionally configure Two-Hand Assist", "Your other hand gets modifier keys on the opposite side while a chord is in progress.")
                    step(5, "Preview", "Try the layout exactly as it will look. Preview never sends anything to your Mac.")
                    step(6, "Done", "Your layout is saved. Choose it under Settings → Controls → Control Layout → Custom.")
                } header: {
                    Text("How Custom Layouts Work")
                }
                Section("Guides") {
                    LabeledContent("Alignment Guides") { Text(HelpText.alignmentGuides).foregroundStyle(.secondary) }
                    LabeledContent("Snap to Edges") { Text(HelpText.snapToEdges).foregroundStyle(.secondary) }
                    LabeledContent("Snap to Guides") { Text(HelpText.snapToGuides).foregroundStyle(.secondary) }
                    LabeledContent("System Areas") { Text(HelpText.systemArea).foregroundStyle(.secondary) }
                    LabeledContent("Landscape & Portrait") { Text(HelpText.orientations).foregroundStyle(.secondary) }
                }
                Section {
                    Text("Add Control → Keyboard Shortcut makes a button that sends any key combination once, like ⌃U or ⌘⇧P.")
                } header: {
                    Text("Shortcut Buttons")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "\(number).circle.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

/// The full-screen Custom layout editor. Edits a draft, so Edit ↔ Preview
/// is instant and nothing is saved until Done.
struct CustomLayoutEditorScreen: View {
    @ObservedObject var store: ReceiverControlStore
    let layoutID: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomControlLayout?
    @State private var previewing: Bool
    @State private var editingPortrait: Bool
    @State private var selectedID: String?
    @State private var dragPositions: [String: CGPoint] = [:]
    @State private var session = CustomLayoutPreviewSession()
    @State private var previewAnchor: ControlModifier?
    @State private var showingHelp = false
    @State private var confirmingTemplate: ControlCorner?
    @State private var confirmingDiscard = false
    @State private var editingShortcut: ShortcutEditorRequest?
    @State private var showingAssistPreview = false
    @AppStorage("customLayoutEditor.guideStyle") private var guideStyle = AlignmentGuideStyle.dots
    @AppStorage("customLayoutEditor.snapToEdges") private var snapsToEdges = true
    @AppStorage("customLayoutEditor.snapToGuides") private var snapsToGuides = false
    @AppStorage("customLayoutEditor.tipSeen") private var tipSeen = false

    init(store: ReceiverControlStore, layoutID: String, startsInPreview: Bool = false) {
        self.store = store
        self.layoutID = layoutID
        _previewing = State(initialValue: startsInPreview)
        let bounds = EditorDevice.screenBounds
        _editingPortrait = State(initialValue: bounds.height > bounds.width)
    }

    private var arrangement: CustomControlArrangement? { draft?.arrangement(portrait: editingPortrait) }
    private var selected: CustomControlPlacement? { arrangement?.placements.first { $0.id == selectedID } }
    private var stored: CustomControlLayout? { store.preferences.customLayouts.first { $0.id == layoutID } }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let wide = proxy.size.width > proxy.size.height
                Group {
                    if previewing {
                        canvas
                    } else if wide {
                        HStack(spacing: 0) {
                            canvas
                            inspectorPanel.frame(width: 340)
                        }
                    } else {
                        VStack(spacing: 0) {
                            canvas
                            inspectorPanel.frame(maxHeight: 320)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(draft?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .statusBarHidden(false)
        }
        .onAppear { if draft == nil { draft = stored } }
        .onChange(of: editingPortrait) { _ in
            selectedID = nil
            session.reset()
        }
        .onChange(of: previewing) { _ in
            session.reset()
            previewAnchor = nil
            selectedID = nil
        }
        .sheet(isPresented: $showingHelp) { CustomLayoutHelpSheet() }
        .sheet(item: $editingShortcut) { request in
            ShortcutButtonEditor(initial: request.item) { item in
                if let placementID = request.placementID {
                    updatePlacement(placementID) { $0.kind = .shortcut(item) }
                } else {
                    let placement = CustomControlPlacement(kind: .shortcut(item), x: 0.5, y: 0.5)
                    mutate { $0.placements.append(placement) }
                    selectedID = placement.id
                }
            }
        }
        .confirmationDialog("Replace this orientation with the radial template?",
                            isPresented: Binding(get: { confirmingTemplate != nil },
                                                 set: { if !$0 { confirmingTemplate = nil } }),
                            titleVisibility: .visible) {
            Button("Use Template", role: .destructive) {
                if let corner = confirmingTemplate {
                    mutate { $0 = .radialTemplate(corner: corner, portrait: editingPortrait) }
                }
                confirmingTemplate = nil
                selectedID = nil
            }
        } message: {
            Text("Only the \(editingPortrait ? String(localized: "portrait") : String(localized: "landscape")) arrangement changes. Shortcut buttons you added are removed from it.")
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if draft != stored { confirmingDiscard = true } else { dismiss() }
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $previewing) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Picker("Orientation", selection: $editingPortrait) {
                    Label("Landscape", systemImage: "rectangle").tag(false)
                    Label("Portrait", systemImage: "rectangle.portrait").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                InfoButton(title: "Landscape & Portrait", text: HelpText.orientations)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !previewing {
                addMenu
                Menu {
                    Picker("Alignment Guides", selection: $guideStyle) {
                        ForEach(AlignmentGuideStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Snap to Edges", isOn: $snapsToEdges)
                    Toggle("Snap to Guides", isOn: $snapsToGuides)
                } label: {
                    Label("Guides", systemImage: "grid")
                }
                Menu {
                    Section("Radial Template") {
                        ForEach(ControlCorner.allCases) { corner in
                            Button(corner.title) { confirmingTemplate = corner }
                        }
                    }
                } label: {
                    Label("Template", systemImage: "circle.grid.cross")
                }
            }
            Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            Button("Done") {
                if let draft { store.update { $0.updateCustomLayout(draft) } }
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        CustomLayoutCanvas(
            arrangement: arrangement ?? CustomControlArrangement(corner: .bottomTrailing, placements: []),
            portrait: editingPortrait,
            previewing: previewing,
            guideStyle: previewing ? .off : guideStyle,
            twoHandAssist: EditorTwoHandPresentation.state(previewing: previewing,
                                                          showingAssistPreview: showingAssistPreview,
                                                          enabled: draft?.twoHandAssist ?? false,
                                                          interaction: session.interaction),
            assistItems: (draft?.assistActionIDs ?? []).compactMap { id in functionItems.first { $0.id == id } },
            metrics: PadControlMetrics(scale: store.preferences.padControlScale),
            selectedID: selectedID,
            dragPositions: dragPositions,
            session: session,
            previewAnchor: previewAnchor,
            functionItems: functionItems,
            paletteActions: { store.activeProfile.actions(for: $0) },
            onSelect: { selectedID = $0 },
            onDrag: { id, point in dragPositions[id] = point },
            onDrop: { id, point, area, diameter in
                dragPositions[id] = nil
                let position = CustomLayoutGeometry.droppedPosition(for: point, in: area, diameter: diameter,
                                                                    snapToEdges: snapsToEdges,
                                                                    snapToGuides: snapsToGuides && guideStyle != .off)
                updatePlacement(id) { $0.x = position.x; $0.y = position.y }
            },
            onPreviewModifier: { modifier in
                previewAnchor = modifier
                session.tapModifier(modifier)
            },
            onPreviewAssist: { session.tapAssistModifier($0) },
            onPreviewPalette: { session.tapPaletteAction($0) },
            onPreviewAction: { session.tapAction($0) })
        .overlay(alignment: .top) {
            if !tipSeen && !previewing {
                firstRunTip.padding(12)
            }
        }
    }

    private var firstRunTip: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.draw").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Arrange your controls").font(.headline)
                Text("Drag a control to move it, and tap it to change its size or shortcut palette. Use Preview to try the layout — it never sends anything to your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Got It") { withAnimation { tipSeen = true } }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    // MARK: Panels

    @ViewBuilder
    private var inspectorPanel: some View {
        if let selected {
            Form { inspector(for: selected) }
        } else {
            layoutPanel
        }
    }

    private var layoutPanel: some View {
        Form {
            if let draft {
                Section {
                    Text("Tap a control on the canvas to edit it, or drag it to move it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Use Two-Hand Assist", isOn: Binding(get: { draft.twoHandAssist },
                                                                 set: { value in self.draft?.twoHandAssist = value }))
                    Toggle("Preview Two-Hand Assist", isOn: $showingAssistPreview)
                        .disabled(!draft.twoHandAssist)
                } header: {
                    HStack(spacing: 6) {
                        Text("Two-Hand Assist")
                        InfoButton(title: "Two-Hand Assist", text: HelpText.twoHandAssist)
                    }
                } footer: {
                    Text("While you arrange controls, Two-Hand Assist stays still. Turn on Preview Two-Hand Assist to see where its helper keys appear, or use Preview to try it for real.")
                }
                Section {
                    Picker("Actions From", selection: Binding(
                        get: { draft.functionProfile },
                        set: { value in self.draft?.functionProfile = value })) {
                        Text("Active Function Profile").tag(ControlProfileSlot?.none)
                        ForEach(ControlProfileSlot.allCases) { Text($0.title).tag(ControlProfileSlot?.some($0)) }
                    }
                    NavigationLink("Edit Function Tray…") {
                        FunctionTrayEditor(store: store,
                                           slot: draft.functionProfile ?? store.preferences.activeFunctionTrayProfile)
                    }
                } header: {
                    Text("Function Tray")
                } footer: {
                    Text("This layout decides where Function controls go; the Function Tray profile decides what they do. Add them with Add Control → Actions.")
                }
                Section {
                    Picker(selection: $guideStyle) {
                        ForEach(AlignmentGuideStyle.allCases) { Text($0.title).tag($0) }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Alignment Guides")
                            InfoButton(title: "Alignment Guides", text: HelpText.alignmentGuides)
                        }
                    }
                    Toggle(isOn: $snapsToEdges) {
                        HStack(spacing: 6) {
                            Text("Snap to Edges")
                            InfoButton(title: "Snap to Edges", text: HelpText.snapToEdges)
                        }
                    }
                    Toggle(isOn: $snapsToGuides) {
                        HStack(spacing: 6) {
                            Text("Snap to Guides")
                            InfoButton(title: "Snap to Guides", text: HelpText.snapToGuides)
                        }
                    }
                    .disabled(guideStyle == .off)
                } header: {
                    Text("Guides")
                } footer: {
                    Text(HelpText.systemArea)
                }
            }
        }
    }

    @ViewBuilder
    private func inspector(for placement: CustomControlPlacement) -> some View {
        Section {
            HStack {
                CustomControlGlyph(kind: placement.kind, diameter: 30, functionItems: functionItems)
                    .frame(width: 36, height: 36)
                    .background(PadChip(selected: false, onRail: false))
                Text(title(for: placement.kind)).font(.headline)
                Spacer()
                Button("Done") { selectedID = nil }
                    .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Size")
                Slider(value: Binding(get: { placement.size },
                                      set: { value in updatePlacement(placement.id) { $0.size = value } }),
                       in: CustomControlPlacement.sizeRange, step: 0.05) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 8)).accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 16)).accessibilityHidden(true)
                }
            }
            if case .shortcut(let item) = placement.kind {
                Button {
                    editingShortcut = ShortcutEditorRequest(placementID: placement.id, item: item)
                } label: {
                    Label("Edit Shortcut…", systemImage: "keyboard")
                }
            }
        }
        if placement.kind.modifier != nil {
            paletteSection(for: placement)
        }
        Section {
            Button(role: .destructive) {
                mutate { $0.placements.removeAll { $0.id == placement.id } }
                selectedID = nil
            } label: {
                Label("Remove from Layout", systemImage: "trash")
            }
            .disabled(placement.kind == .tray(.settings))
        } footer: {
            if placement.kind == .tray(.settings) {
                Text("Settings always stays in the layout, so it can never become unreachable.")
            }
        }
    }

    @ViewBuilder
    private func paletteSection(for placement: CustomControlPlacement) -> some View {
        let style = placement.palette ?? PalettePresentation()
        Section {
            HStack(spacing: 8) {
                ForEach(PaletteShape.allCases) { shape in
                    Button {
                        updatePlacement(placement.id) { $0.palette = restyled($0, shape: shape) }
                    } label: {
                        VStack(spacing: 4) {
                            PaletteShapeThumbnail(shape: shape)
                                .frame(width: 44, height: 44)
                            Text(shape.title).font(.caption)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(style.shape == shape ? Color.accentColor.opacity(0.18) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style.shape == shape ? Color.accentColor : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(style.shape == shape ? .isSelected : [])
                }
            }
            Text(shapeDescription(style.shape)).font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Palette Distance")
                    InfoButton(title: "Palette Distance", text: HelpText.paletteDistance)
                }
                Slider(value: Binding(get: { style.spacing },
                                      set: { value in updatePlacement(placement.id) { $0.palette = restyled($0, spacing: value) } }),
                       in: PalettePresentation.spacingRange, step: 0.1) {
                    Text("Palette Distance")
                } minimumValueLabel: { Text("Close") } maximumValueLabel: { Text("Far") }
                    .font(.footnote)
            }
            Toggle(isOn: Binding(
                get: { style.directionDegrees == nil },
                set: { automatic in
                    updatePlacement(placement.id) { $0.palette = restyled($0, direction: automatic ? .some(nil) : .some(-90)) }
                })) {
                HStack(spacing: 6) {
                    Text("Toward Screen Center")
                    InfoButton(title: "Palette Direction", text: HelpText.paletteDirection)
                }
            }
            if let degrees = style.directionDegrees {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Palette Direction")
                    Slider(value: Binding(get: { degrees },
                                          set: { value in updatePlacement(placement.id) { $0.palette = restyled($0, direction: .some(value)) } }),
                           in: -180...180, step: 15) {
                        Text("Palette Direction")
                    } minimumValueLabel: { Image(systemName: "arrow.counterclockwise") } maximumValueLabel: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            if let modifier = placement.kind.modifier {
                NavigationLink {
                    ChordPaletteEditor(store: store, chord: ModifierChord([modifier]), haptics: ReceiverHaptics { false })
                } label: {
                    Label("Edit Palette Actions", systemImage: "square.grid.3x3.topleft.filled")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Shortcut Palette")
                InfoButton(title: "Palette Style", text: HelpText.paletteStyle)
            }
        } footer: {
            Text("The canvas shows this modifier’s palette while it’s selected. Its actions come from your Control Profile, so the same palette appears everywhere you use this modifier.")
        }
    }

    private func shapeDescription(_ shape: PaletteShape) -> String {
        switch shape {
        case .wheel: return String(localized: "Wheel — a ring of wedge-shaped segments around the modifier.")
        case .arc: return String(localized: "Arc — shortcuts fan outward along part of a circle.")
        case .ring: return String(localized: "Ring — shortcuts surround the modifier.")
        case .row: return String(localized: "Row — shortcuts appear in a horizontal line.")
        case .column: return String(localized: "Column — shortcuts appear in a vertical line.")
        }
    }

    private func restyled(_ placement: CustomControlPlacement, shape: PaletteShape? = nil,
                          spacing: Double? = nil, direction: Double?? = nil) -> PalettePresentation {
        var style = placement.palette ?? PalettePresentation()
        if let shape { style.shape = shape }
        if let spacing { style.spacing = spacing }
        if let direction { style.directionDegrees = direction }
        return style
    }

    // MARK: Adding controls

    private var addMenu: some View {
        Menu {
            let placed = Set(arrangement?.placements.map(\.kind) ?? [])
            Button {
                editingShortcut = ShortcutEditorRequest(placementID: nil, item: nil)
            } label: {
                Label("Keyboard Shortcut…", systemImage: "keyboard")
            }
            Section("Modifiers") {
                ForEach([ControlTrayItem.command, .option, .control, .shift]) { item in
                    Button(item.title) { add(.tray(item)) }.disabled(placed.contains(.tray(item)))
                }
            }
            Section("System") {
                ForEach(CustomControlArrangement.templateSystem, id: \.self) { kind in
                    Button(title(for: kind)) { add(kind) }.disabled(placed.contains(kind))
                }
            }
            Section("Keys & Utilities") {
                ForEach([ControlTrayItem.escape, .tab, .keyboard, .dock]) { item in
                    Button(item.title) { add(.tray(item)) }.disabled(placed.contains(.tray(item)))
                }
                Button("Move View") { add(.moveView) }.disabled(placed.contains(.moveView))
            }
            Section("Actions") {
                ForEach(functionItems) { item in
                    Button(item.title) { add(.function(item.id)) }.disabled(placed.contains(.function(item.id)))
                }
            }
        } label: {
            Label("Add Control", systemImage: "plus")
        }
    }

    private func add(_ kind: CustomControlKind) {
        let placement = CustomControlPlacement(kind: kind, x: 0.5, y: 0.5)
        mutate { $0.placements.append(placement) }
        selectedID = placement.id
    }

    // MARK: Helpers

    private var functionItems: [ShortcutItem] { store.functionItems(for: draft) }

    private func title(for kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item): return item.title
        case .moveView: return String(localized: "Move View")
        case .function(let id): return functionItems.first { $0.id == id }?.title ?? id
        case .shortcut(let item): return item.title
        }
    }

    private func mutate(_ change: (inout CustomControlArrangement) -> Void) {
        guard var layout = draft else { return }
        var arrangement = layout.arrangement(portrait: editingPortrait)
        change(&arrangement)
        layout.setArrangement(arrangement, portrait: editingPortrait)
        draft = layout
    }

    private func updatePlacement(_ id: String, _ change: (inout CustomControlPlacement) -> Void) {
        mutate { arrangement in
            guard let index = arrangement.placements.firstIndex(where: { $0.id == id }) else { return }
            change(&arrangement.placements[index])
            let placement = arrangement.placements[index]
            // Re-normalize through the initializer's clamps.
            arrangement.placements[index] = CustomControlPlacement(id: placement.id, kind: placement.kind,
                                                                   x: placement.x, y: placement.y,
                                                                   size: placement.size, palette: placement.palette)
        }
    }
}

/// The device's full-screen size and safe insets, for the editor canvas.
private enum EditorDevice {
    @MainActor static var screenBounds: CGRect {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 1194, height: 834)
    }

    @MainActor static func size(portrait: Bool) -> CGSize {
        let bounds = screenBounds
        let long = max(bounds.width, bounds.height)
        let short = min(bounds.width, bounds.height)
        return portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    /// The system areas the receiver surface keeps controls out of: a thin
    /// top inset and the Home indicator (iPad has no side insets).
    @MainActor static var safeInsets: ControlSafeInsets {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let insets = window?.safeAreaInsets ?? UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        return ControlSafeInsets(top: insets.top, leading: 0, bottom: max(insets.bottom, 20), trailing: 0)
    }
}

// MARK: - Canvas

/// The iPad surface at scale: the same geometry as the live overlay
/// (`CustomLayoutGeometry.frames`, `palettePoints`, `TwoHandAssist`),
/// drawn with editor guides in Edit and exactly as at runtime in Preview.
private struct CustomLayoutCanvas: View {
    let arrangement: CustomControlArrangement
    let portrait: Bool
    let previewing: Bool
    let guideStyle: AlignmentGuideStyle
    /// Already resolved for Edit vs Preview — see `EditorTwoHandPresentation`.
    let twoHandAssist: TwoHandAssistState
    let assistItems: [ShortcutItem]
    let metrics: PadControlMetrics
    let selectedID: String?
    let dragPositions: [String: CGPoint]
    let session: CustomLayoutPreviewSession
    let previewAnchor: ControlModifier?
    let functionItems: [ShortcutItem]
    let paletteActions: (ModifierChord) -> [ShortcutItem]
    let onSelect: (String?) -> Void
    let onDrag: (String, CGPoint) -> Void
    let onDrop: (String, CGPoint, CGRect, CGFloat) -> Void
    let onPreviewModifier: (ControlModifier) -> Void
    let onPreviewAssist: (ControlModifier) -> Void
    let onPreviewPalette: (ShortcutItem) -> Void
    let onPreviewAction: (ShortcutItem) -> Void

    var body: some View {
        let device = EditorDevice.size(portrait: portrait)
        let container = CGRect(origin: .zero, size: device)
        let safe = EditorDevice.safeInsets
        let area = CustomLayoutGeometry.layoutArea(container: container, safeInsets: safe)
        GeometryReader { proxy in
            let scale = min((proxy.size.width - 32) / device.width, (proxy.size.height - 32) / device.height)
            let origin = CGPoint(x: (proxy.size.width - device.width * scale) / 2,
                                 y: (proxy.size.height - device.height * scale) / 2)
            let frames = liveFrames(area: area)
            ZStack(alignment: .topLeading) {
                surface(device: device, safe: safe, area: area, scale: scale)
                    .contentShape(Rectangle())
                    .onTapGesture { if !previewing { onSelect(nil) } }
                if previewing {
                    previewLayer(frames: frames, area: area, scale: scale)
                } else {
                    editLayer(frames: frames, area: area, scale: scale)
                }
            }
            .frame(width: device.width * scale, height: device.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22 * scale + 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22 * scale + 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .offset(x: origin.x, y: origin.y)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(previewing ? Text("Layout preview") : Text("Layout editor canvas"))
    }

    private func liveFrames(area: CGRect) -> [String: CGRect] {
        var frames = CustomLayoutGeometry.frames(for: arrangement, in: area, baseDiameter: metrics.item)
        for (id, point) in dragPositions {
            guard let frame = frames[id] else { continue }
            frames[id] = PadEdgeGeometry.clamped(CGRect(x: point.x - frame.width / 2, y: point.y - frame.height / 2,
                                                        width: frame.width, height: frame.height), into: area)
        }
        return frames
    }

    // MARK: Surface

    private func surface(device: CGSize, safe: ControlSafeInsets, area: CGRect, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // A calm neutral surface, like the trackpad's — the iPad screen,
            // not any particular Mac content.
            Color(white: 0.17)
            if !previewing {
                // System areas the layout keeps out of.
                Rectangle().fill(Color.black.opacity(0.28))
                    .frame(width: device.width * scale, height: safe.top * scale)
                Rectangle().fill(Color.black.opacity(0.28))
                    .frame(width: device.width * scale, height: safe.bottom * scale)
                    .offset(y: (device.height - safe.bottom) * scale)
                if guideStyle != .off {
                    AlignmentGuides(style: guideStyle, area: area, scale: scale)
                }
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: area.width * scale, height: area.height * scale)
                    .offset(x: area.minX * scale, y: area.minY * scale)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Edit

    @ViewBuilder
    private func editLayer(frames: [String: CGRect], area: CGRect, scale: CGFloat) -> some View {
        // The selected modifier's palette, on the same arc it will use live.
        if let selectedID, let placement = arrangement.placements.first(where: { $0.id == selectedID }),
           let modifier = placement.kind.modifier, placement.palette?.shape == .wheel, let frame = frames[selectedID] {
            let actions = paletteActions(ModifierChord([modifier]))
            if let wheel = scaledWheel(count: actions.count, anchor: frame, area: area, scale: scale) {
                WheelPaletteView(layout: wheel, actions: actions, selectedID: nil, centerLabel: modifier.symbol)
                    .opacity(0.85)
            }
        } else if let selectedID, let placement = arrangement.placements.first(where: { $0.id == selectedID }),
           let modifier = placement.kind.modifier {
            let actions = paletteActions(ModifierChord([modifier]))
            let points = CustomLayoutGeometry.palettePoints(count: actions.count, anchorID: selectedID,
                                                            arrangement: arrangement, frames: frames, area: area,
                                                            baseDiameter: metrics.item, spacing: metrics.gap)
            let key = CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: metrics.item)
            ForEach(Array(zip(actions, points)), id: \.0.id) { action, point in
                Text(action.displayKey)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: key * scale, height: key * scale)
                    .background(Circle().fill(Color.accentColor.opacity(0.7)))
                    .position(x: point.x * scale, y: point.y * scale)
                    .allowsHitTesting(false)
            }
        }
        // Two-Hand Assist: dormant while editing; its helper arc shows only
        // when "Preview Two-Hand Assist" is on, never while dragging.
        if case .helper(let active) = twoHandAssist {
            let helpers = TwoHandAssist.helperPoints(count: TwoHandAssist.helperModifiers.count, arrangement: arrangement,
                                                     frames: frames, area: area, itemDiameter: metrics.item,
                                                     spacing: metrics.gap)
            ForEach(Array(zip(TwoHandAssist.helperModifiers, helpers)), id: \.0) { modifier, point in
                Text(modifier.symbol)
                    .font(.system(size: metrics.item * 0.46 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(active.contains(modifier) ? 1 : 0.75))
                    .frame(width: metrics.item * scale, height: metrics.item * scale)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(0.7)))
                    .position(x: point.x * scale, y: point.y * scale)
                    .allowsHitTesting(false)
            }
        }
        ForEach(arrangement.placements) { placement in
            if let frame = frames[placement.id] {
                let isSelected = placement.id == selectedID
                CustomControlGlyph(kind: placement.kind, diameter: frame.width * scale, functionItems: functionItems)
                    .foregroundStyle(.white)
                    .frame(width: frame.width * scale, height: frame.height * scale)
                    .background(PadChip(selected: false, onRail: false))
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0))
                    .position(x: frame.midX * scale, y: frame.midY * scale)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            onSelect(placement.id)
                            onDrag(placement.id, CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                        }
                        .onEnded { value in
                            onDrop(placement.id, CGPoint(x: value.location.x / scale, y: value.location.y / scale), area,
                                   frame.width)
                        })
                    .onTapGesture { onSelect(isSelected ? nil : placement.id) }
                    .accessibilityLabel(Text(accessibilityTitle(placement.kind)))
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewLayer(frames: [String: CGRect], area: CGRect, scale: CGFloat) -> some View {
        let interaction = session.interaction
        let chord = interaction.paletteChord
        let actions = chord.map(paletteActions) ?? []
        let anchor = (previewAnchor.flatMap { interaction.activeChord.contains($0) ? $0 : nil }
            ?? ControlModifier.allCases.first(where: interaction.activeChord.contains))
            .flatMap { arrangement.placement(for: $0) }
        let points = anchor.map {
            CustomLayoutGeometry.palettePoints(count: actions.count, anchorID: $0.id, arrangement: arrangement,
                                               frames: frames, area: area, baseDiameter: metrics.item,
                                               spacing: metrics.gap)
        } ?? []
        let key = CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: metrics.item)
        let assistState = twoHandAssist
        let wheelActions = anchor.flatMap { placement -> WheelPaletteLayout? in
            guard placement.palette?.shape == .wheel, let frame = frames[placement.id] else { return nil }
            return scaledWheel(count: actions.count, anchor: frame, area: area, scale: scale)
        }
        let assistCount: Int = {
            switch assistState {
            case .hidden: return 0
            case .idle: return assistItems.count
            case .helper: return TwoHandAssist.helperModifiers.count
            }
        }()
        let assistPoints = TwoHandAssist.helperPoints(count: assistCount, arrangement: arrangement, frames: frames,
                                                      area: area, itemDiameter: metrics.item, spacing: metrics.gap)
        ForEach(arrangement.placements) { placement in
            if let frame = frames[placement.id] {
                previewControl(placement.kind, frame: frame, scale: scale, active: interaction.activeChord)
            }
        }
        if let wheel = wheelActions, let chord {
            WheelPaletteView(layout: wheel, actions: actions, selectedID: nil, centerLabel: chord.symbols)
            Color.clear
                .frame(width: wheel.frame.width, height: wheel.frame.height)
                .contentShape(Circle())
                .position(wheel.center)
                .gesture(SpatialTapGesture().onEnded { value in
                    let point = CGPoint(x: wheel.frame.minX + value.location.x, y: wheel.frame.minY + value.location.y)
                    if let index = wheel.segmentIndex(at: point), index < actions.count { onPreviewPalette(actions[index]) }
                })
        }
        ForEach(Array(zip(actions, wheelActions == nil ? points : [])), id: \.0.id) { action, point in
            Text(action.displayKey)
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: key * scale, height: key * scale)
                .background(PadChip(selected: false, onRail: false))
                .position(x: point.x * scale, y: point.y * scale)
                .onTapGesture { onPreviewPalette(action) }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        switch assistState {
        case .hidden:
            EmptyView()
        case .idle:
            ForEach(Array(zip(assistItems, assistPoints)), id: \.0.id) { item, point in
                previewDisc(scale: scale, selected: false) {
                    CustomControlGlyph(kind: .function(item.id), diameter: metrics.item * scale, functionItems: functionItems)
                }
                .position(x: point.x * scale, y: point.y * scale)
                .onTapGesture { onPreviewAction(item) }
                .transition(.opacity)
            }
        case .helper(let active):
            ForEach(Array(zip(TwoHandAssist.helperModifiers, assistPoints)), id: \.0) { modifier, point in
                previewDisc(scale: scale, selected: active.contains(modifier)) {
                    Text(modifier.symbol).font(.system(size: metrics.item * 0.46 * scale, weight: .semibold))
                }
                .position(x: point.x * scale, y: point.y * scale)
                .onTapGesture { onPreviewAssist(modifier) }
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        if let feedback = session.feedback {
            Text(feedbackText(feedback))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: area.midX * scale, y: (area.minY + 30) * scale)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func previewControl(_ kind: CustomControlKind, frame: CGRect, scale: CGFloat,
                                active: ModifierChord) -> some View {
        let selected = kind.modifier.map(active.contains) ?? false
        previewDisc(scale: scale, diameter: frame.width, selected: selected) {
            CustomControlGlyph(kind: kind, diameter: frame.width * scale, functionItems: functionItems)
        }
        .position(x: frame.midX * scale, y: frame.midY * scale)
        .onTapGesture {
            switch kind {
            case .tray(let item):
                if let modifier = item.modifier { onPreviewModifier(modifier) }
            case .function(let id):
                if let item = functionItems.first(where: { $0.id == id }) { onPreviewAction(item) }
            case .shortcut(let item):
                onPreviewAction(item)
            case .moveView:
                break
            }
        }
    }

    /// A control exactly as it looks live.
    private func previewDisc<Content: View>(scale: CGFloat, diameter: CGFloat? = nil, selected: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        let size = (diameter ?? metrics.item) * scale
        return content()
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(PadChip(selected: selected, onRail: false))
    }

    /// The Wheel as it will appear live, in the canvas's scaled space.
    private func scaledWheel(count: Int, anchor: CGRect, area: CGRect, scale: CGFloat) -> WheelPaletteLayout? {
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        return WheelPaletteGeometry.layout(count: count, anchor: scaled(anchor),
                                           keyDiameter: CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: metrics.item) * scale,
                                           spacing: metrics.gap * scale, bounds: scaled(area))
    }

    private func feedbackText(_ feedback: CustomLayoutPreviewSession.Feedback) -> String {
        switch feedback {
        case .wouldSend(let keys): return String(localized: "Preview · \(keys)")
        case .wouldPerform(let action): return String(localized: "Preview · \(action)")
        }
    }

    private func accessibilityTitle(_ kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item): return item.title
        case .moveView: return String(localized: "Move View")
        case .function(let id): return functionItems.first { $0.id == id }?.title ?? id
        case .shortcut(let item): return item.title
        }
    }
}

/// Editor-only alignment guides: never part of the layout, never shown at
/// runtime.
enum AlignmentGuideStyle: String, CaseIterable, Identifiable {
    case off
    case dots
    case lines

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .dots: return String(localized: "Dots")
        case .lines: return String(localized: "Grid Lines")
        }
    }
}

private struct AlignmentGuides: View {
    let style: AlignmentGuideStyle
    let area: CGRect
    let scale: CGFloat
    private let divisions = 24

    var body: some View {
        ZStack {
            switch style {
            case .off:
                EmptyView()
            case .dots:
                Path { path in
                    for column in 0...divisions {
                        for row in 0...divisions {
                            let x = (area.minX + CGFloat(column) / CGFloat(divisions) * area.width) * scale
                            let y = (area.minY + CGFloat(row) / CGFloat(divisions) * area.height) * scale
                            path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        }
                    }
                }
                .fill(Color.white.opacity(0.28))
            case .lines:
                Path { path in
                    for index in 0...divisions {
                        let t = CGFloat(index) / CGFloat(divisions)
                        let x = (area.minX + t * area.width) * scale
                        let y = (area.minY + t * area.height) * scale
                        path.move(to: CGPoint(x: x, y: area.minY * scale))
                        path.addLine(to: CGPoint(x: x, y: area.maxY * scale))
                        path.move(to: CGPoint(x: area.minX * scale, y: y))
                        path.addLine(to: CGPoint(x: area.maxX * scale, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            // Center lines — also where Snap to Edges settles.
            Path { path in
                path.move(to: CGPoint(x: area.midX * scale, y: area.minY * scale))
                path.addLine(to: CGPoint(x: area.midX * scale, y: area.maxY * scale))
                path.move(to: CGPoint(x: area.minX * scale, y: area.midY * scale))
                path.addLine(to: CGPoint(x: area.maxX * scale, y: area.midY * scale))
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A tiny drawing of a palette shape: a modifier and its shortcuts.
private struct PaletteShapeThumbnail: View {
    let shape: PaletteShape

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let dot: CGFloat = 7
            let points: [CGPoint]
            switch shape {
            case .arc:
                points = (0..<4).map { index in
                    let angle = -CGFloat.pi * 0.85 + CGFloat(index) * 0.45
                    return CGPoint(x: center.x + 16 * cos(angle), y: center.y + 6 + 16 * sin(angle))
                }
            case .ring:
                points = (0..<6).map { index in
                    let angle = CGFloat(index) * .pi / 3
                    return CGPoint(x: center.x + 15 * cos(angle), y: center.y + 15 * sin(angle))
                }
            case .row:
                points = (0..<4).map { CGPoint(x: center.x - 15 + CGFloat($0) * 10, y: center.y - 12) }
            case .column:
                points = (0..<4).map { CGPoint(x: center.x + 12, y: center.y - 15 + CGFloat($0) * 10) }
            case .wheel:
                for index in 0..<6 {
                    let start = CGFloat(index) * .pi / 3 + 0.08
                    var wedge = Path()
                    wedge.addArc(center: center, radius: 18, startAngle: .radians(start),
                                 endAngle: .radians(start + .pi / 3 - 0.16), clockwise: false)
                    wedge.addArc(center: center, radius: 9, startAngle: .radians(start + .pi / 3 - 0.16),
                                 endAngle: .radians(start), clockwise: true)
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(.accentColor))
                }
                points = []
            }
            let anchor = shape == .arc ? CGPoint(x: center.x, y: center.y + 6) : center
            context.fill(Path(ellipseIn: CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10)),
                         with: .color(.primary))
            for point in points {
                context.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                             with: .color(.accentColor))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A Custom control's symbol, the same way the live overlay draws it.
struct CustomControlGlyph: View {
    let kind: CustomControlKind
    let diameter: CGFloat
    let functionItems: [ShortcutItem]

    var body: some View {
        switch kind {
        case .tray(let item):
            if let modifier = item.modifier {
                Text(modifier.symbol).font(.system(size: diameter * 0.46, weight: .semibold))
            } else if item == .escape || item == .tab {
                Text(item.displayLabel).font(.system(size: diameter * 0.3, weight: .semibold))
            } else {
                Image(systemName: item.displayLabel).font(.system(size: diameter * 0.4, weight: .semibold))
            }
        case .moveView:
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: diameter * 0.38, weight: .semibold))
        case .function(let id):
            itemGlyph(functionItems.first { $0.id == id })
        case .shortcut(let item):
            itemGlyph(item)
        }
    }

    @ViewBuilder
    private func itemGlyph(_ item: ShortcutItem?) -> some View {
        ShortcutButtonFaceView(face: item?.face ?? .text("?"), diameter: diameter)
    }
}
