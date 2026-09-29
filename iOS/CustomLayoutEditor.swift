import SwiftUI
import UIKit

// MARK: - Custom layout list (Settings → Controls, iPad only)

/// The user's Custom layouts, plus `Create Custom Layout` until
/// `CustomControlLayout.maximumCount` exist. Nothing is pre-created.
struct CustomLayoutListSection: View {
    @ObservedObject var store: ReceiverControlStore

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
                    CustomLayoutEditor(store: store, layoutID: layout.id)
                } label: {
                    HStack {
                        Text(layout.name)
                        Spacer()
                        if layout.id == store.preferences.activeCustomLayout?.id {
                            Text("Active").font(.footnote).foregroundStyle(.secondary)
                        }
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
        } header: {
            Text("Custom Layouts")
        } footer: {
            Text("Up to \(CustomControlLayout.maximumCount) layouts, each with its own landscape and portrait arrangement. New layouts start from the radial corner template.")
        }
    }
}

// MARK: - Editor

/// A controller-style editor: an iPad-surface preview where controls are
/// dragged, selected, resized and removed, per orientation. Only placement
/// and presentation are edited here — what a control does still comes from
/// the Control Profile and Function Tray.
struct CustomLayoutEditor: View {
    @ObservedObject var store: ReceiverControlStore
    let layoutID: String

    @State private var editingPortrait: Bool
    @State private var selectedID: String?
    @State private var dragPositions: [String: CGPoint] = [:]
    @State private var previewPalette = false
    @State private var confirmingTemplate: ControlCorner?
    @State private var name = ""

    init(store: ReceiverControlStore, layoutID: String) {
        self.store = store
        self.layoutID = layoutID
        let bounds = Self.screenBounds
        _editingPortrait = State(initialValue: bounds.height > bounds.width)
    }

    private var layout: CustomControlLayout? {
        store.preferences.customLayouts.first { $0.id == layoutID }
    }

    private var arrangement: CustomControlArrangement? {
        layout?.arrangement(portrait: editingPortrait)
    }

    private var selected: CustomControlPlacement? {
        arrangement?.placements.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if let layout {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("Orientation", selection: $editingPortrait) {
                            Text("Landscape").tag(false)
                            Text("Portrait").tag(true)
                        }
                        .pickerStyle(.segmented)
                        preview
                        if let selected {
                            inspector(for: selected)
                        } else {
                            Text("Drag a control to move it. Tap one to resize it, change its palette, or remove it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        layoutOptions(layout)
                    }
                    .padding()
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(layout.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
                .onAppear { name = layout.name }
                .onChange(of: editingPortrait) { _ in
                    selectedID = nil
                    previewPalette = false
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
                    Text("Only the \(editingPortrait ? String(localized: "portrait") : String(localized: "landscape")) arrangement changes.")
                }
            } else {
                Text("This layout no longer exists.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Preview

    /// The device's full-screen size in the chosen orientation.
    private static var screenBounds: CGRect {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 1194, height: 834)
    }

    private var deviceSize: CGSize {
        let bounds = Self.screenBounds
        let long = max(bounds.width, bounds.height)
        let short = min(bounds.width, bounds.height)
        return editingPortrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    /// The live window's insets, mapped onto the orientation being edited
    /// (iPad: a thin top inset, and the Home indicator at the bottom).
    private var deviceSafeInsets: ControlSafeInsets {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let insets = window?.safeAreaInsets ?? UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        return ControlSafeInsets(top: insets.top, leading: 0, bottom: max(insets.bottom, 20), trailing: 0)
    }

    private var preview: some View {
        let device = deviceSize
        let metrics = PadControlMetrics(scale: store.preferences.padControlScale)
        let container = CGRect(origin: .zero, size: device)
        let area = CustomLayoutGeometry.layoutArea(container: container, safeInsets: deviceSafeInsets)
        return GeometryReader { proxy in
            let scale = min(proxy.size.width / device.width, proxy.size.height / device.height)
            let frames = placementFrames(area: area, base: metrics.item)
            ZStack(alignment: .topLeading) {
                // The surface: a stand-in Mac desktop, the safe layout area,
                // and alignment guides.
                RoundedRectangle(cornerRadius: 18 / scale, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32),
                                                  Color(red: 0.32, green: 0.22, blue: 0.36)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: device.width, height: device.height)
                alignmentGuides(area: area)
                ForEach(arrangement?.placements ?? []) { placement in
                    if let frame = frames[placement.id] {
                        editorChip(placement, frame: frame, area: area)
                    }
                }
                if previewPalette, let selected, let modifier = selected.kind.modifier,
                   let anchor = frames[selected.id] {
                    palettePreview(modifier: modifier, anchor: anchor, style: selected.palette ?? PalettePresentation(),
                                   area: area, base: metrics.item,
                                   obstacles: frames.filter { $0.key != selected.id }.map(\.value))
                }
            }
            .frame(width: device.width, height: device.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: device.width * scale, height: device.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { selectedID = nil }
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(device.width / device.height, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editingPortrait ? "Portrait layout preview" : "Landscape layout preview")
    }

    private func placementFrames(area: CGRect, base: CGFloat) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for placement in arrangement?.placements ?? [] {
            var frame = CustomLayoutGeometry.frame(for: placement, in: area, baseDiameter: base)
            if let dragged = dragPositions[placement.id] {
                frame = PadEdgeGeometry.clamped(CGRect(x: dragged.x - frame.width / 2, y: dragged.y - frame.height / 2,
                                                       width: frame.width, height: frame.height), into: area)
            }
            result[placement.id] = frame
        }
        return result
    }

    private func alignmentGuides(area: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            // The layout area: controls can't leave it, so nothing ends up
            // under the Home indicator or the screen's rounded corners.
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: area.width, height: area.height)
                .position(x: area.midX, y: area.midY)
            Path { path in
                path.move(to: CGPoint(x: area.midX, y: area.minY))
                path.addLine(to: CGPoint(x: area.midX, y: area.maxY))
                path.move(to: CGPoint(x: area.minX, y: area.midY))
                path.addLine(to: CGPoint(x: area.maxX, y: area.midY))
            }
            .stroke(.white.opacity(0.15), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func editorChip(_ placement: CustomControlPlacement, frame: CGRect, area: CGRect) -> some View {
        let isSelected = placement.id == selectedID
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.5))
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.35),
                                               lineWidth: isSelected ? 3 : 1))
            controlGlyph(placement.kind, diameter: frame.width)
                .foregroundStyle(.white)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                selectedID = placement.id
                dragPositions[placement.id] = value.location
            }
            .onEnded { value in
                dragPositions[placement.id] = nil
                let point = CustomLayoutGeometry.normalizedPoint(for: value.location, in: area)
                updatePlacement(placement.id) {
                    $0.x = CustomLayoutGeometry.snapped(point.x)
                    $0.y = CustomLayoutGeometry.snapped(point.y)
                }
            })
        .onTapGesture { selectedID = isSelected ? nil : placement.id }
        .accessibilityLabel(title(for: placement.kind))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func palettePreview(modifier: ControlModifier, anchor: CGRect, style: PalettePresentation,
                                area: CGRect, base: CGFloat, obstacles: [CGRect]) -> some View {
        let actions = store.activeProfile.actions(for: ModifierChord([modifier]))
        let diameter = CustomLayoutGeometry.paletteKeyDiameter(baseDiameter: base)
        let centers = CustomLayoutGeometry.paletteCenters(count: actions.count, anchor: anchor, style: style,
                                                          area: area, baseDiameter: base, spacing: 8,
                                                          obstacles: obstacles)
        return ForEach(Array(zip(actions, centers)), id: \.0.id) { action, center in
            Text(action.displayKey)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.accentColor.opacity(0.55)))
                .position(center)
                .allowsHitTesting(false)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(for placement: CustomControlPlacement) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(title(for: placement.kind)).font(.headline)
                } icon: {
                    controlGlyph(placement.kind, diameter: 28)
                }
                Spacer()
                Button(role: .destructive) {
                    mutate { $0.placements.removeAll { $0.id == placement.id } }
                    selectedID = nil
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(placement.kind == .tray(.settings))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Size")
                Slider(value: Binding(get: { placement.size },
                                      set: { value in updatePlacement(placement.id) { $0.size = value } }),
                       in: CustomControlPlacement.sizeRange, step: 0.05)
            }
            if placement.kind.modifier != nil {
                let style = placement.palette ?? PalettePresentation()
                Picker("Palette Shape", selection: Binding(
                    get: { style.shape },
                    set: { shape in updatePlacement(placement.id) { $0.palette = paletteStyle($0, shape: shape) } })) {
                    ForEach(PaletteShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Palette Distance")
                    Slider(value: Binding(get: { style.spacing },
                                          set: { value in updatePlacement(placement.id) { $0.palette = paletteStyle($0, spacing: value) } }),
                           in: PalettePresentation.spacingRange, step: 0.1)
                }
                Toggle("Bloom Toward Screen Center", isOn: Binding(
                    get: { style.directionDegrees == nil },
                    set: { automatic in
                        updatePlacement(placement.id) {
                            $0.palette = paletteStyle($0, direction: automatic ? .some(nil) : .some(-90))
                        }
                    }))
                if let degrees = style.directionDegrees {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Direction")
                        Slider(value: Binding(get: { degrees },
                                              set: { value in updatePlacement(placement.id) { $0.palette = paletteStyle($0, direction: .some(value)) } }),
                               in: -180...180, step: 15)
                    }
                }
                Toggle("Preview Palette", isOn: $previewPalette)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func paletteStyle(_ placement: CustomControlPlacement, shape: PaletteShape? = nil,
                              spacing: Double? = nil, direction: Double?? = nil) -> PalettePresentation {
        var style = placement.palette ?? PalettePresentation()
        if let shape { style.shape = shape }
        if let spacing { style.spacing = spacing }
        if let direction { style.directionDegrees = direction }
        return style
    }

    @ViewBuilder
    private func layoutOptions(_ layout: CustomControlLayout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Layout Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.update { $0.renameCustomLayout(layoutID, to: name) } }
            Toggle(isOn: Binding(get: { layout.twoHandAssist },
                                 set: { value in mutateLayout { $0.twoHandAssist = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-Hand Assist")
                    Text("While a modifier is held or latched, modifier keys appear on the opposite side, so your other hand can add to the same chord. Otherwise that side offers Undo, Redo and Zoom.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Menu {
                ForEach(ControlCorner.allCases) { corner in
                    Button(corner.title) { confirmingTemplate = corner }
                }
            } label: {
                Label("Reset to Radial Template…", systemImage: "circle.grid.cross")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { store.update { $0.renameCustomLayout(layoutID, to: name) } }
    }

    // MARK: Adding controls

    private var addMenu: some View {
        Menu {
            let placed = Set(arrangement?.placements.map(\.kind) ?? [])
            Section("Controls") {
                ForEach(ControlTrayItem.allCases) { item in
                    Button(item.title) { add(.tray(item)) }
                        .disabled(placed.contains(.tray(item)))
                }
                Button("Move View") { add(.moveView) }
                    .disabled(placed.contains(.moveView))
            }
            Section("Function Tray") {
                ForEach(store.activeFunctionTrayProfile.items.map(\.item)) { item in
                    Button(item.title) { add(.function(item.id)) }
                        .disabled(placed.contains(.function(item.id)))
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

    @ViewBuilder
    private func controlGlyph(_ kind: CustomControlKind, diameter: CGFloat) -> some View {
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
            let item = store.activeFunctionTrayProfile.items.first { $0.id == id }?.item
            if let symbol = item?.systemImage {
                Image(systemName: symbol).font(.system(size: diameter * 0.4, weight: .semibold))
            } else {
                Text(item?.displayKey ?? "?").font(.system(size: diameter * 0.34, weight: .semibold))
            }
        }
    }

    private func title(for kind: CustomControlKind) -> String {
        switch kind {
        case .tray(let item): return item.title
        case .moveView: return String(localized: "Move View")
        case .function(let id):
            return store.activeFunctionTrayProfile.items.first { $0.id == id }?.item.title ?? id
        }
    }

    private func mutateLayout(_ change: (inout CustomControlLayout) -> Void) {
        guard var layout else { return }
        change(&layout)
        store.update { $0.updateCustomLayout(layout) }
    }

    private func mutate(_ change: (inout CustomControlArrangement) -> Void) {
        let portrait = editingPortrait
        mutateLayout { layout in
            var arrangement = layout.arrangement(portrait: portrait)
            change(&arrangement)
            layout.setArrangement(arrangement, portrait: portrait)
        }
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
