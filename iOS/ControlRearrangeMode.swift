import SwiftUI
import UIKit

// Rearrange Controls: chosen from Session Actions (touch and hold the gear).
// A standard sheet over the session, in the style of Settings: one page per
// run of buttons (the Control Tray, the Function Tray, each modifier's and
// chord's shortcuts), each a list whose rows reorder by their handles. A
// back button always leads out of a page and Done (or a swipe down) ends it.
//
// It replaced an in-place, Home Screen style edit mode (owner QA, 2.2 round
// 4): its wiggling buttons sat where the live trays draw them, so palettes
// and chords opened over the trays, the hint and Done; small, edge-hugging
// targets made drags unreliable next to the system's edge gestures; and a
// palette had no visible way back. Lists give large targets, the system's own
// reordering, VoiceOver support and navigation that can't overlap.
//
// Nothing here reaches the Mac: ReceiverScreen closes the input surface while
// `ReceiverControlStore.rearrangingControls` is on, and the sheet is modal.
// Orders are written through the store as each row lands, in the same
// profile fields as before (`ControlRearrangement`), so portrait and
// landscape keep their own tray orders.

/// What can be rearranged in one orientation: the buttons as the trays draw
/// them there, in order.
struct ControlRearrangeContent: Equatable {
    var tray: [ControlTrayItem]
    var function: [ShortcutItem]
}

struct ControlRearrangeSheet: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics
    /// The orientation the person is holding the device in when it opened.
    let landscapeNow: Bool
    /// The trays as drawn in an orientation (true: landscape).
    let content: (Bool) -> ControlRearrangeContent
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let now = content(landscapeNow)
                    if !now.tray.isEmpty {
                        NavigationLink {
                            ControlRearrangeTrayPage(store: store, haptics: haptics, landscapeNow: landscapeNow,
                                                     content: content)
                        } label: {
                            ControlRearrangeRunLabel(title: Text("Control Tray", comment: "Rearrange Controls: page."),
                                                     faces: now.tray.map(ControlRearrangeFace.tray))
                        }
                        .accessibilityIdentifier("rearrange.page.tray")
                    }
                    if !now.function.isEmpty {
                        NavigationLink {
                            ControlRearrangeFunctionPage(store: store, haptics: haptics, landscapeNow: landscapeNow,
                                                         content: content)
                        } label: {
                            ControlRearrangeRunLabel(title: Text("Function Tray", comment: "Rearrange Controls: page."),
                                                     faces: now.function.map { .shortcut($0.face) })
                        }
                        .accessibilityIdentifier("rearrange.page.function")
                    }
                } header: {
                    Text("Trays", comment: "Rearrange Controls: section.")
                } footer: {
                    Text("Portrait and landscape keep their own order.",
                         comment: "Rearrange Controls: footer under the trays.")
                }

                Section {
                    ForEach(ControlModifier.allCases, id: \.self) { modifier in
                        paletteLink(ModifierChord([modifier]))
                    }
                    NavigationLink {
                        ControlRearrangeChordsPage(store: store, haptics: haptics)
                    } label: {
                        LabeledContent {
                            Text(verbatim: "\(Self.chords.reduce(0) { $0 + store.activeProfile.actions(for: $1).count })")
                        } label: {
                            Text("Chords", comment: "Rearrange Controls: page listing palettes for modifier combinations.")
                        }
                    }
                    .accessibilityIdentifier("rearrange.page.chords")
                } header: {
                    Text("Shortcuts", comment: "Rearrange Controls: section.")
                } footer: {
                    Text("A modifier's shortcuts open when you hold or latch it in the tray.",
                         comment: "Rearrange Controls: footer under the shortcut palettes.")
                }
            }
            .navigationTitle(Text("Rearrange Controls", comment: "Rearrange Controls: title."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ControlRearrangeDoneButton(onDone: onDone) }
        }
        .accessibilityIdentifier("controlRearrangeSheet")
    }

    static let chords: [ModifierChord] = ControlProfileEditor.supportedChords.filter { $0.modifiers.count > 1 }

    private func paletteLink(_ chord: ModifierChord) -> some View {
        NavigationLink {
            ControlRearrangePalettePage(store: store, haptics: haptics, chord: chord)
        } label: {
            LabeledContent {
                Text(verbatim: "\(store.activeProfile.actions(for: chord).count)")
            } label: {
                Text(verbatim: "\(chord.symbols)  \(chord.displayName)")
            }
        }
        .accessibilityIdentifier("rearrange.page.\(chord.symbols)")
    }
}

/// Done, on every page: it ends Rearrange Controls from wherever the person is.
private struct ControlRearrangeDoneButton: ToolbarContent {
    let onDone: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(action: onDone) {
                Text("Done", comment: "Ends Rearrange Controls.")
            }
            .accessibilityHint(Text("Keeps the new order.", comment: "Rearrange Controls: hint on Done."))
            .accessibilityIdentifier("controlRearrangeDone")
        }
    }
}

// MARK: - Pages

/// The Main Tray in one orientation, the one being held first.
private struct ControlRearrangeTrayPage: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics
    let landscapeNow: Bool
    let content: (Bool) -> ControlRearrangeContent
    @State private var landscape: Bool

    init(store: ReceiverControlStore, haptics: ReceiverHaptics, landscapeNow: Bool,
         content: @escaping (Bool) -> ControlRearrangeContent) {
        self.store = store
        self.haptics = haptics
        self.landscapeNow = landscapeNow
        self.content = content
        _landscape = State(initialValue: landscapeNow)
    }

    var body: some View {
        let items = content(landscape).tray
        ControlRearrangeList(
            landscape: $landscape, landscapeNow: landscapeNow,
            rows: items.map { ControlRearrangeRow(id: $0.rawValue, title: $0.title, face: .tray($0)) },
            footer: store.isPad
                ? Text("On iPad the modifiers reorder here; the rail keeps its other buttons in place.",
                       comment: "Rearrange Controls: footer on iPad's Control Tray page.")
                : Text("Hidden buttons keep their place. Show or hide them in Settings.",
                       comment: "Rearrange Controls: footer on the Control Tray page."),
            onMove: { from, to in
                store.updateActiveProfile { $0.moveShownTrayItem(shown: items, from: from, to: to, landscape: landscape) }
                haptics.play(.selection)
            })
            .navigationTitle(Text("Control Tray", comment: "Rearrange Controls: page."))
            .toolbar { ControlRearrangeDoneButton(onDone: { store.setRearrangingControls(false) }) }
    }
}

/// The Function Tray in one orientation. Its clusters keep their sizes; a
/// button moving past a gap joins the cluster it lands in.
private struct ControlRearrangeFunctionPage: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics
    let landscapeNow: Bool
    let content: (Bool) -> ControlRearrangeContent
    @State private var landscape: Bool

    init(store: ReceiverControlStore, haptics: ReceiverHaptics, landscapeNow: Bool,
         content: @escaping (Bool) -> ControlRearrangeContent) {
        self.store = store
        self.haptics = haptics
        self.landscapeNow = landscapeNow
        self.content = content
        _landscape = State(initialValue: landscapeNow)
    }

    var body: some View {
        let items = content(landscape).function
        let ids = items.map(\.id)
        ControlRearrangeList(
            landscape: $landscape, landscapeNow: landscapeNow,
            rows: items.map { ControlRearrangeRow(id: $0.id, title: $0.title, face: .shortcut($0.face)) },
            footer: Text("Groups keep their sizes: a button moved into another group joins it.",
                         comment: "Rearrange Controls: footer on the Function Tray page."),
            onMove: { from, to in
                store.updateActiveFunctionTrayProfile { $0.moveShownItem(shown: ids, from: from, to: to, landscape: landscape) }
                haptics.play(.selection)
            })
            .navigationTitle(Text("Function Tray", comment: "Rearrange Controls: page."))
            .toolbar { ControlRearrangeDoneButton(onDone: { store.setRearrangingControls(false) }) }
    }
}

/// Every palette for two or more modifiers held together.
private struct ControlRearrangeChordsPage: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics

    var body: some View {
        List {
            Section {
                ForEach(ControlRearrangeSheet.chords) { chord in
                    NavigationLink {
                        ControlRearrangePalettePage(store: store, haptics: haptics, chord: chord)
                    } label: {
                        LabeledContent {
                            Text(verbatim: "\(store.activeProfile.actions(for: chord).count)")
                        } label: {
                            Text(verbatim: "\(chord.symbols)  \(chord.displayName)")
                        }
                    }
                    .accessibilityIdentifier("rearrange.page.\(chord.symbols)")
                }
            } footer: {
                Text("These open when you hold or latch the modifiers together.",
                     comment: "Rearrange Controls: footer on the Chords page.")
            }
        }
        .navigationTitle(Text("Chords", comment: "Rearrange Controls: page listing palettes for modifier combinations."))
        .toolbar { ControlRearrangeDoneButton(onDone: { store.setRearrangingControls(false) }) }
    }
}

/// One modifier's (or chord's) shortcuts. Adding and changing them stays in
/// the full editor, one tap away.
private struct ControlRearrangePalettePage: View {
    @ObservedObject var store: ReceiverControlStore
    let haptics: ReceiverHaptics
    let chord: ModifierChord

    var body: some View {
        let actions = store.activeProfile.actions(for: chord)
        ControlRearrangeList(
            landscape: nil, landscapeNow: false,
            rows: actions.map { ControlRearrangeRow(id: $0.id, title: $0.title, face: .shortcut($0.face)) },
            footer: actions.isEmpty
                ? Text("No \(chord.symbols) shortcuts yet.", comment: "Rearrange Controls: an empty palette.")
                : Text("The same order shows in every layout.", comment: "Rearrange Controls: footer on a palette page."),
            onMove: { from, to in
                store.updateActiveProfile { $0.moveAction(for: chord, from: from, to: to) }
                haptics.play(.selection)
            },
            trailing: {
                Section {
                    NavigationLink {
                        ChordPaletteEditor(store: store, chord: chord, haptics: haptics)
                    } label: {
                        Text("Add or Change Shortcuts…", comment: "Rearrange Controls: opens the palette's full editor.")
                    }
                }
            })
            .navigationTitle(Text(verbatim: "\(chord.symbols) \(chord.displayName)"))
            .toolbar { ControlRearrangeDoneButton(onDone: { store.setRearrangingControls(false) }) }
    }
}

// MARK: - The reorder list

private struct ControlRearrangeRow: Identifiable {
    let id: String
    let title: String
    let face: ControlRearrangeFace
}

/// A list whose rows reorder by their handles (always shown), with a preview
/// of the run as the tray draws it, and, for the trays, which orientation's
/// order is being changed.
private struct ControlRearrangeList<Trailing: View>: View {
    /// nil: the order is the same in both orientations.
    var landscape: Binding<Bool>?
    let landscapeNow: Bool
    let rows: [ControlRearrangeRow]
    let footer: Text
    let onMove: (Int, Int) -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(landscape: Binding<Bool>?, landscapeNow: Bool, rows: [ControlRearrangeRow], footer: Text,
         onMove: @escaping (Int, Int) -> Void, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.landscape = landscape
        self.landscapeNow = landscapeNow
        self.rows = rows
        self.footer = footer
        self.onMove = onMove
        self.trailing = trailing
    }

    var body: some View {
        List {
            if let landscape {
                Section {
                    Picker(selection: landscape) {
                        Text("Portrait", comment: "Rearrange Controls: orientation whose order is shown.").tag(false)
                        Text("Landscape", comment: "Rearrange Controls: orientation whose order is shown.").tag(true)
                    } label: {
                        Text("Orientation", comment: "Rearrange Controls: orientation picker.")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("rearrange.orientation")
                } footer: {
                    Text(landscape.wrappedValue == landscapeNow
                         ? String(localized: "The order for how you're holding it now.",
                                  comment: "Rearrange Controls: the shown orientation is the current one.")
                         : String(localized: "Shows when you turn to this orientation.",
                                  comment: "Rearrange Controls: the shown orientation isn't the current one."))
                }
            }
            if !rows.isEmpty {
                Section {
                    ControlRearrangePreview(faces: rows.map(\.face))
                        .moveDisabled(true)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                    .onMove { source, destination in
                        guard let move = ControlRearrangement.listMove(from: source, to: destination,
                                                                       count: rows.count) else { return }
                        withAnimation { onMove(move.from, move.to) }
                    }
                } footer: {
                    footer
                }
            } else {
                Section { } footer: { footer }
            }
            trailing()
        }
        .environment(\.editMode, .constant(.active))
    }

    private func rowView(_ row: ControlRearrangeRow, index: Int) -> some View {
        HStack(spacing: 12) {
            ControlRearrangeFaceView(face: row.face, diameter: 30)
            Text(row.title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(index + 1) of \(rows.count)",
                                 comment: "Rearrange Controls: a button's position in its row."))
        .accessibilityAction(named: Text("Move Up", comment: "Rearrange Controls: accessibility action.")) {
            if let target = ControlRearrangement.step(from: index, by: -1, count: rows.count) { onMove(index, target) }
        }
        .accessibilityAction(named: Text("Move Down", comment: "Rearrange Controls: accessibility action.")) {
            if let target = ControlRearrangement.step(from: index, by: 1, count: rows.count) { onMove(index, target) }
        }
        .accessibilityIdentifier("rearrange.row.\(row.id)")
    }
}

// MARK: - Faces

enum ControlRearrangeFace: Equatable {
    case tray(ControlTrayItem)
    case shortcut(ShortcutButtonFace)
}

/// A button's face as the trays draw it, on a dark chip, without its action.
struct ControlRearrangeFaceView: View {
    let face: ControlRearrangeFace
    let diameter: CGFloat

    var body: some View {
        glyph
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(white: 0.22)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch face {
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
}

/// The run's faces in order, as a strip: what the tray will look like.
private struct ControlRearrangePreview: View {
    let faces: [ControlRearrangeFace]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    ControlRearrangeFaceView(face: face, diameter: 34)
                }
            }
            .padding(.vertical, 4)
            .animation(.snappy(duration: 0.25), value: faces)
        }
        .accessibilityHidden(true)
    }
}

/// A tray's page link: its name and its first few faces.
private struct ControlRearrangeRunLabel: View {
    let title: Text
    let faces: [ControlRearrangeFace]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            HStack(spacing: 4) {
                ForEach(Array(faces.prefix(8).enumerated()), id: \.offset) { _, face in
                    ControlRearrangeFaceView(face: face, diameter: 24)
                }
                if faces.count > 8 {
                    Text(verbatim: "+\(faces.count - 8)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
