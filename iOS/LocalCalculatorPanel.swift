import SwiftUI
import UIKit

// The receiver's local calculator: a floating window that can be moved by
// its title bar and resized freely from its corner. Three views:
// - Basic: a coloured keypad, the expression as typed with a live answer
//   under it, and a history of what was calculated (tap a line to reuse
//   its answer; hold it to copy).
// - Scientific (Expand): adds ( ) sin cos tan ln log √ x² xʸ π e and more.
// - Notes (the keyboard button): a Soulver / Math Notes style sheet. Type
//   (or write with Apple Pencil, which Scribble turns into text) a sum or a
//   plain-English question on a line, and its answer appears under it with
//   a shimmer. Lines can name values ("rent = 1200") that later lines use.
// Everything runs on this device; nothing here can reach the Mac.

// MARK: - Model

/// While a calculator notes line is being edited, a hardware keyboard types
/// into it instead of controlling the Mac (`HardwareKeyboardForwarder`).
@MainActor
enum LocalCalculatorTextFocus {
    static var isEditing = false
}

/// The receiver's local calculator for this app session: what is being
/// typed, the history, the notes, its mode and where its window sits.
/// Memory only: it survives the panel closing, Home, reconnects and
/// Settings, and is gone when the app quits. Owned by
/// `ReceiverControlStore`, so the demo has its own.
@MainActor
final class LocalCalculatorModel: ObservableObject {
    enum Mode: Equatable {
        case basic
        case scientific
        case notes
    }

    struct NoteLine: Identifiable, Equatable {
        let id: UUID
        var text: String
        init(id: UUID = UUID(), text: String = "") {
            self.id = id
            self.text = text
        }
    }

    typealias Key = CalculatorKeypad.Key
    typealias HistoryEntry = CalculatorKeypad.HistoryEntry

    @Published private(set) var isOpen = false
    @Published var mode: Mode = .basic
    @Published private(set) var keypad = CalculatorKeypad()
    @Published var inverse = false
    @Published var notes: [NoteLine] = [NoteLine()]
    @Published var focusedNote: UUID?
    /// The window's frame once moved or resized, in the layer's space.
    @Published var windowFrame: CGRect?
    /// Bumped by each Copy Result, for the button's brief confirmation.
    @Published private(set) var copyCount = 0

    var input: String { keypad.input }
    var showsAnswer: Bool { keypad.showsAnswer }
    var answeredExpression: String { keypad.answeredExpression }
    var failed: Bool { keypad.failed }
    var history: [HistoryEntry] { keypad.history }
    var preview: Decimal? { keypad.preview }
    var currentValue: Decimal? { keypad.currentValue }
    var angle: CalculatorAngleUnit {
        get { keypad.angle }
        set { keypad.angle = newValue }
    }

    func toggle() { isOpen.toggle() }

    func close() {
        isOpen = false
        focusedNote = nil
    }

    func press(_ key: Key) { keypad.press(key) }
    func use(_ value: Decimal) { keypad.use(value) }
    func clearHistory() { keypad.clearHistory() }
    func removeHistory(_ id: HistoryEntry.ID) { keypad.removeHistory(id) }

    static func symbol(_ operation: LocalCalculator.Operation) -> String { CalculatorKeypad.symbol(operation) }

    // MARK: Copy

    /// Writes the result to this device's pasteboard, like any other copy
    /// in the app. Unified Clipboard isn't called or changed: if the person
    /// allowed it, it notices this copy later through its own change
    /// detection (`ClipboardModel.checkLocal`), exactly as it would a copy
    /// made in another app. False while there is no value.
    @discardableResult
    func copyResult(locale: Locale = .current, to pasteboard: UIPasteboard = .general) -> Bool {
        guard let value = currentValue else { return false }
        return copy(value, locale: locale, to: pasteboard)
    }

    @discardableResult
    func copy(_ value: Decimal, locale: Locale = .current, to pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.string = LocalCalculatorFormat.copyText(value, locale: locale)
        copyCount &+= 1
        return true
    }

    // MARK: Notes

    var noteResults: [CalculatorLineResult] {
        CalculatorSheet.evaluate(lines: notes.map(\.text), angle: angle)
    }

    /// Return on a line: a new line after it, focused.
    func insertNote(after id: UUID) {
        let line = NoteLine()
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes.insert(line, at: index + 1)
        } else {
            notes.append(line)
        }
        focusedNote = line.id
    }

    /// Delete on an empty line: it goes, and the line above takes focus.
    func removeEmptyNote(_ id: UUID) {
        guard notes.count > 1, let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].text.isEmpty else { return }
        notes.remove(at: index)
        focusedNote = notes[max(0, index - 1)].id
    }

    func clearNotes() {
        let line = NoteLine()
        notes = [line]
        focusedNote = line.id
    }
}

/// The open panel's frame, so the surface (Stage Peek, the Video Off grid)
/// treats it as occupied like any other control.
struct LocalCalculatorFramesPreference: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

// MARK: - Window geometry

enum LocalCalculatorWindowGeometry {
    static func minimumSize(_ mode: LocalCalculatorModel.Mode) -> CGSize {
        switch mode {
        case .basic: return CGSize(width: 200, height: 280)
        case .scientific: return CGSize(width: 330, height: 280)
        case .notes: return CGSize(width: 240, height: 200)
        }
    }

    /// The size a mode opens at when the window hasn't been resized, from
    /// the fitted basic keypad.
    static func preferredSize(_ mode: LocalCalculatorModel.Mode, basic: CGSize) -> CGSize {
        switch mode {
        case .basic: return CGSize(width: basic.width, height: basic.height + 64)
        case .scientific: return CGSize(width: basic.width * 1.75, height: basic.height + 64)
        case .notes: return CGSize(width: max(basic.width * 1.3, 320), height: basic.height + 64)
        }
    }

    /// `frame` kept inside `bounds`: no smaller than `minimum` (unless the
    /// bounds are), no larger than the bounds, and moved back inside.
    static func clamped(_ frame: CGRect, minimum: CGSize, bounds: CGRect) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else { return frame }
        let width = min(max(frame.width, min(minimum.width, bounds.width)), bounds.width)
        let height = min(max(frame.height, min(minimum.height, bounds.height)), bounds.height)
        let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Layer

/// The entry button and, while open, the floating calculator window, in the
/// control overlay's coordinates. Only the button and the window take
/// touches; the rest of the layer passes them through to the Mac untouched,
/// so there is no tap-catcher and nothing outside dismisses it: Close, the
/// button again, or VoiceOver's escape gesture do.
struct LocalCalculatorLayer<Chip: View>: View {
    @ObservedObject var model: LocalCalculatorModel
    let containerSize: CGSize
    /// nil while the button isn't shown (an open panel then sits in the
    /// top-left of `panelBounds`).
    let buttonFrame: CGRect?
    var buttonFaceDiameter: CGFloat?
    /// A Strip caption under the button, when Control Hints are on.
    var buttonHint: String?
    /// The safe area the window must stay inside.
    let panelBounds: CGRect
    /// Other controls and reserved regions the window keeps off when it can.
    var obstacles: [CGRect] = []
    /// Auto-hide fades the button with the other controls, but never while
    /// its panel is open, and never the panel.
    var autoHiding = false
    let haptics: ReceiverHaptics
    @ViewBuilder let chip: (_ selected: Bool) -> Chip

    @ScaledMetric(relativeTo: .body) private var preferredKey: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var keyboard = LocalCalculatorKeyboardObserver()
    @State private var layerOrigin: CGPoint = .zero
    /// The window's frame when a move or resize began.
    @State private var gestureStart: CGRect?

    /// The bounds above the on-screen keyboard while notes are typed.
    private var usableBounds: CGRect {
        guard let keyboardTop = keyboard.top else { return panelBounds }
        let top = keyboardTop - layerOrigin.y - LocalCalculatorPlacement.margin
        guard top < panelBounds.maxY else { return panelBounds }
        var bounds = panelBounds
        bounds.size.height = max(120, top - bounds.minY)
        return bounds
    }

    var body: some View {
        let bounds = usableBounds
        let metrics = LocalCalculatorPanelMetrics.fitting(panelBounds.size, preferredKey: preferredKey)
        let anchor = buttonFrame ?? CGRect(x: panelBounds.minX, y: panelBounds.minY, width: 0, height: 0)
        let panel: CGRect? = model.isOpen ? windowFrame(metrics: metrics, anchor: anchor, bounds: bounds) : nil
        let buttonVisible = !autoHiding || model.isOpen
        ZStack(alignment: .topLeading) {
            if let buttonFrame {
                LocalCalculatorEntryButton(open: model.isOpen, diameter: buttonFaceDiameter ?? buttonFrame.width,
                                           hitDiameter: buttonFrame.width, hint: buttonHint, chip: chip) {
                    model.toggle()
                    haptics.play(.selection)
                }
                .position(x: buttonFrame.midX,
                          y: buttonFrame.minY + (buttonFrame.height + (buttonHint == nil ? 0 : PadControlMetrics.hintHeight + 2)) / 2)
                .opacity(buttonVisible ? 1 : 0)
                .allowsHitTesting(buttonVisible)
            }
            if let panel {
                LocalCalculatorPanel(model: model, haptics: haptics,
                                     onMove: { move(by: $0, from: panel, bounds: bounds) },
                                     onResize: { resize(by: $0, from: panel, bounds: bounds) },
                                     onGestureEnd: { gestureStart = nil })
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.92, anchor: Self.unitPoint(of: anchor, in: panel))
                                    .combined(with: .opacity))
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { layerOrigin = proxy.frame(in: .global).origin }
                .onChange(of: proxy.frame(in: .global).origin) { layerOrigin = $0 }
        })
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: model.isOpen)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.mode)
        .animation(.easeOut(duration: 0.2), value: keyboard.top)
        .preference(key: LocalCalculatorFramesPreference.self, value: panel.map { [$0] } ?? [])
    }

    private func windowFrame(metrics: LocalCalculatorPanelMetrics, anchor: CGRect, bounds: CGRect) -> CGRect {
        let minimum = LocalCalculatorWindowGeometry.minimumSize(model.mode)
        if let frame = model.windowFrame {
            return LocalCalculatorWindowGeometry.clamped(frame, minimum: minimum, bounds: bounds)
        }
        let preferred = LocalCalculatorWindowGeometry.preferredSize(model.mode, basic: metrics.size)
        let size = CGSize(width: min(preferred.width, bounds.width), height: min(preferred.height, bounds.height))
        let placed = LocalCalculatorPlacement.panelFrame(button: anchor, size: size, bounds: bounds, obstacles: obstacles)
        return LocalCalculatorWindowGeometry.clamped(placed, minimum: minimum, bounds: bounds)
    }

    private func move(by translation: CGSize, from current: CGRect, bounds: CGRect) {
        let start = gestureStart ?? current
        if gestureStart == nil { gestureStart = current }
        let moved = start.offsetBy(dx: translation.width, dy: translation.height)
        model.windowFrame = LocalCalculatorWindowGeometry.clamped(moved, minimum: .zero, bounds: bounds)
    }

    private func resize(by translation: CGSize, from current: CGRect, bounds: CGRect) {
        let start = gestureStart ?? current
        if gestureStart == nil { gestureStart = current }
        let minimum = LocalCalculatorWindowGeometry.minimumSize(model.mode)
        let width = min(max(minimum.width, start.width + translation.width), bounds.maxX - start.minX)
        let height = min(max(minimum.height, start.height + translation.height), bounds.maxY - start.minY)
        model.windowFrame = CGRect(x: start.minX, y: start.minY, width: width, height: height)
    }

    /// The button's center relative to the panel, so it grows out of it.
    private static func unitPoint(of anchor: CGRect, in panel: CGRect) -> UnitPoint {
        guard panel.width > 0, panel.height > 0 else { return .topLeading }
        return UnitPoint(x: min(max((anchor.midX - panel.minX) / panel.width, 0), 1),
                         y: min(max((anchor.midY - panel.minY) / panel.height, 0), 1))
    }
}

/// The on-screen keyboard's top edge in screen coordinates while it shows.
@MainActor
final class LocalCalculatorKeyboardObserver: ObservableObject {
    @Published private(set) var top: CGFloat?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.update(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.top = nil }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func update(_ frame: CGRect?) {
        guard let frame, frame.height > 0, let screen = UIScreen.mainScreenBounds, frame.minY < screen.maxY - 1 else {
            top = nil
            return
        }
        // A floating or undocked keyboard doesn't push the window up.
        top = frame.maxY >= screen.maxY - 1 ? frame.minY : nil
    }
}

private extension UIScreen {
    @MainActor static var mainScreenBounds: CGRect? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen.bounds
    }
}

// MARK: - Entry button

/// The calculator's control: a chip like its neighbours, drawn selected
/// while the panel is open. A tap opens or closes the panel.
struct LocalCalculatorEntryButton<Chip: View>: View {
    let open: Bool
    let diameter: CGFloat
    var hitDiameter: CGFloat?
    var hint: String?
    @ViewBuilder let chip: (_ selected: Bool) -> Chip
    let action: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: LocalCalculatorPanel.symbolName)
                .font(.system(size: (diameter * 0.4).rounded(), weight: .semibold))
                .foregroundStyle(open ? Color.black : Color.white)
                .frame(width: diameter, height: diameter)
                .background(chip(open))
                .frame(width: hitDiameter ?? diameter, height: hitDiameter ?? diameter)
                .contentShape(Circle())
                .onTapGesture(perform: action)
            if let hint {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: diameter + PadControlMetrics.hintWidthAllowance, height: PadControlMetrics.hintHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
        .accessibilityValue(open ? Text("Open", comment: "The local calculator's panel is showing.") : Text(""))
        .accessibilityHint(LocalCalculatorPanel.deviceOnlyHint)
        .accessibilityInputLabels([Text("Calculator", comment: "The local calculator's control and panel.")])
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Palette

enum LocalCalculatorPalette {
    static let digit = Color(white: 0.2)
    static let function = Color(red: 0.29, green: 0.33, blue: 0.42)
    static let clear = Color(red: 0.86, green: 0.3, blue: 0.32)
    static let operation = Color(red: 1.0, green: 0.6, blue: 0.14)
    static let equals = Color(red: 0.16, green: 0.74, blue: 0.5)
    static let scientific = Color(red: 0.35, green: 0.3, blue: 0.62)
    /// Answers, as Math Notes colours them.
    static let answer = Color(red: 1.0, green: 0.78, blue: 0.3)
    static let answerGlow = Color(red: 1.0, green: 0.95, blue: 0.75)
}

// MARK: - Panel

/// The calculator window: a title bar (move it by dragging), the current
/// view and a resize grip in the corner. Every touch inside it stays here.
struct LocalCalculatorPanel: View {
    static let symbolName = "plus.forwardslash.minus"

    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics
    var onMove: (CGSize) -> Void = { _ in }
    var onResize: (CGSize) -> Void = { _ in }
    var onGestureEnd: () -> Void = {}

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false

    static var deviceOnlyHint: Text {
        UIDevice.current.userInterfaceIdiom == .pad
            ? Text("Works on this iPad only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
            : Text("Works on this iPhone only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
    }

    private static let cornerRadius: CGFloat = 22
    private static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: Self.gap) {
            titleBar
            switch model.mode {
            case .basic, .scientific:
                LocalCalculatorKeypadView(model: model, haptics: haptics)
            case .notes:
                LocalCalculatorNotesView(model: model, haptics: haptics)
            }
        }
        .padding(8)
        .background(panelBackground)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // Gaps between keys belong to the panel too: nothing falls through.
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
        .accessibilityAction(.escape) { close() }
        .onChange(of: model.copyCount) { _ in flashCopied() }
        .onDisappear { LocalCalculatorTextFocus.isEditing = false }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.86),
                                              Color.black.opacity(0.78)],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            headerButton("xmark", label: Text("Close Calculator", comment: "Closes the local calculator's panel."),
                         action: close)
            // The middle of the bar moves the window.
            HStack(spacing: 4) {
                Capsule().fill(Color.white.opacity(0.28)).frame(width: 28, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onMove($0.translation) }
                .onEnded { _ in onGestureEnd() })
            .accessibilityHidden(true)
            headerButton(model.mode == .notes ? "keyboard.fill" : "keyboard",
                         label: model.mode == .notes
                            ? Text("Keypad", comment: "Local calculator: back to the keypad from notes.")
                            : Text("Type or Write", comment: "Local calculator: opens notes to type or handwrite calculations."),
                         selected: model.mode == .notes) {
                model.mode = model.mode == .notes ? .basic : .notes
                haptics.play(.selection)
            }
            if model.mode != .notes {
                headerButton(model.mode == .scientific ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             label: model.mode == .scientific
                                ? Text("Basic", comment: "Local calculator: back to the basic keypad.")
                                : Text("Scientific", comment: "Local calculator: expands to the scientific keypad."),
                             selected: model.mode == .scientific) {
                    model.mode = model.mode == .scientific ? .basic : .scientific
                    haptics.play(.selection)
                }
            }
            Button(action: copy) {
                Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showsCopied ? LocalCalculatorPalette.equals : .white.opacity(model.currentValue == nil ? 0.35 : 0.95))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.currentValue == nil)
            .accessibilityLabel(Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard."))
            .accessibilityHint(Text("Copies the number to this device's clipboard.",
                                    comment: "Accessibility hint for the local calculator's Copy Result button."))
        }
    }

    private func headerButton(_ symbol: String, label: Text, selected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? LocalCalculatorPalette.answer : Color.white.opacity(0.12)))
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 30, height: 30, alignment: .bottomTrailing)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { onResize($0.translation) }
                .onEnded { _ in onGestureEnd() })
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private func copy() {
        guard model.copyResult(locale: locale) else { return }
        haptics.play(.confirmation)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: String(localized: "Copied", comment: "Local calculator: copies the result to this device's clipboard."))
        }
    }

    private func close() {
        model.close()
        LocalCalculatorTextFocus.isEditing = false
        haptics.play(.selection)
    }

    private func flashCopied() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showsCopied = true }
        let count = model.copyCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard model.copyCount == count else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsCopied = false }
        }
    }

    /// The display as VoiceOver reads it: scientific values in words.
    static func spoken(_ display: LocalCalculatorDisplay) -> String {
        switch display {
        case .plain(let text): return text
        case .scientific(let mantissa, let exponent):
            return String(localized: "\(mantissa) times ten to the power of \(exponent)",
                          comment: "Local calculator: a number in scientific notation, read aloud.")
        case .error:
            return String(localized: "Error", comment: "Local calculator display after a division by zero or an overflow.")
        }
    }
}

// MARK: - Keypad view

private struct LocalCalculatorKeypadView: View {
    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The keypad takes what it needs; history and the display share
            // the rest.
            let keyRows: CGFloat = 5
            let keyHeight = min(72, max(30, (size.height * 0.62 - Self.gap * (keyRows - 1)) / keyRows))
            let keypadHeight = keyHeight * keyRows + Self.gap * (keyRows - 1)
            let displayHeight = min(96, max(56, size.height - keypadHeight - Self.gap))
            let historyHeight = max(0, size.height - keypadHeight - displayHeight - Self.gap * 2)
            VStack(spacing: Self.gap) {
                if historyHeight >= 24 {
                    historyList.frame(height: historyHeight)
                }
                display.frame(height: displayHeight)
                keypad(keyHeight: keyHeight, width: size.width).frame(height: keypadHeight)
            }
            .frame(width: size.width, height: size.height, alignment: .bottom)
        }
    }

    // MARK: History

    private var historyList: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: 6) {
                    ForEach(model.history) { entry in
                        historyRow(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchorBottom()
            .onChange(of: model.history.count) { _ in
                if let last = model.history.last { withAnimation { reader.scrollTo(last.id, anchor: .bottom) } }
            }
            .overlay {
                if model.history.isEmpty {
                    Text("History appears here", comment: "Local calculator: empty history placeholder.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25)))
    }

    private func historyRow(_ entry: LocalCalculatorModel.HistoryEntry) -> some View {
        let answer = LocalCalculatorFormat.display(entry.value, locale: locale)
        return Button {
            model.use(entry.value)
            haptics.play(.selection)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: entry.expression)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: "= " + answer.text)
                    .foregroundStyle(LocalCalculatorPalette.answer.opacity(0.9))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 14, weight: .regular).monospacedDigit())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.copy(entry.value, locale: locale)
            } label: {
                Label(String(localized: "Copy Answer", comment: "Local calculator history: copies an answer."),
                      systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.expression + " = " + LocalCalculatorFormat.copyText(entry.value, locale: locale)
            } label: {
                Label(String(localized: "Copy Calculation", comment: "Local calculator history: copies the sum and its answer."),
                      systemImage: "text.badge.plus")
            }
            Button(role: .destructive) {
                model.removeHistory(entry.id)
            } label: {
                Label(String(localized: "Delete", comment: "Local calculator history: removes one line."), systemImage: "trash")
            }
            Button(role: .destructive) {
                model.clearHistory()
            } label: {
                Label(String(localized: "Clear History", comment: "Local calculator: removes every history line."),
                      systemImage: "clear")
            }
        }
        .accessibilityLabel(Text(verbatim: entry.expression + " = " + LocalCalculatorPanel.spoken(answer)))
        .accessibilityHint(Text("Uses this answer.", comment: "Local calculator history row hint."))
    }

    // MARK: Display

    private var resultDisplay: LocalCalculatorDisplay {
        if model.failed { return .error }
        guard let value = model.currentValue else { return .error }
        return LocalCalculatorFormat.display(value, locale: locale)
    }

    private var display: some View {
        let big: String
        let small: String
        var smallIsAnswer = false
        if model.failed {
            big = String(localized: "Error", comment: "Local calculator display after a division by zero or an overflow.")
            small = model.keypad.displayInput(locale: locale)
        } else if model.showsAnswer {
            big = resultDisplay.text
            small = model.answeredExpression + " ="
        } else {
            big = model.input.isEmpty ? LocalCalculatorFormat.display(0, locale: locale).text : model.keypad.displayInput(locale: locale)
            if let preview = model.preview {
                small = "= " + LocalCalculatorFormat.display(preview, locale: locale).text
                smallIsAnswer = true
            } else {
                small = ""
            }
        }
        return VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: small)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(smallIsAnswer ? LocalCalculatorPalette.answer.opacity(0.75) : .white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: big)
                .font(.system(size: 40, weight: model.showsAnswer ? .regular : .light).monospacedDigit())
                .foregroundStyle(model.showsAnswer ? LocalCalculatorPalette.answer : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .modifier(LocalCalculatorShimmer(trigger: model.showsAnswer ? model.history.last?.id : nil))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        // A sideways swipe deletes the last character, as in Calculator.
        .gesture(DragGesture(minimumDistance: 16).onEnded { value in
            let dx = value.translation.width
            if abs(dx) > 28, abs(dx) > abs(value.translation.height) * 1.5 { press(.delete) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Result", comment: "Local calculator display, read with its number."))
        .accessibilityValue(Text(verbatim: model.showsAnswer || model.input.isEmpty || model.failed
                                    ? LocalCalculatorPanel.spoken(resultDisplay)
                                    : model.keypad.displayInput(locale: locale) + (model.preview.map { ", = " + LocalCalculatorFormat.display($0, locale: locale).text } ?? "")))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Delete", comment: "Local calculator: deletes the last digit typed.")) {
            press(.delete)
        }
        .accessibilityAction(named: Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard.")) {
            model.copyResult(locale: locale)
        }
    }

    // MARK: Keys

    private enum KeyID: Hashable {
        case clear, sign, percent, delete, point, equals
        case digit(Int)
        case operation(LocalCalculator.Operation)
        case open, close, angle, inverse
        case sin, cos, tan, ln, log, sqrt, square, power, cbrt, reciprocal, factorial, abs, pi, e, answer
    }

    private static let basicRows: [[KeyID]] = [
        [.clear, .sign, .percent, .operation(.divide)],
        [.digit(7), .digit(8), .digit(9), .operation(.multiply)],
        [.digit(4), .digit(5), .digit(6), .operation(.subtract)],
        [.digit(1), .digit(2), .digit(3), .operation(.add)],
        [.delete, .digit(0), .point, .equals],
    ]

    private static let scientificRows: [[KeyID]] = [
        [.open, .close, .inverse, .angle],
        [.sin, .cos, .tan, .pi],
        [.ln, .log, .sqrt, .e],
        [.square, .power, .cbrt, .reciprocal],
        [.factorial, .abs, .answer, .percent],
    ]

    private func keypad(keyHeight: CGFloat, width: CGFloat) -> some View {
        let scientific = model.mode == .scientific
        let columns: CGFloat = scientific ? 8 : 4
        let keyWidth = max(24, (width - Self.gap * (columns - 1)) / columns)
        return HStack(spacing: Self.gap) {
            if scientific {
                grid(Self.scientificRows, keyWidth: keyWidth, keyHeight: keyHeight)
            }
            grid(Self.basicRows, keyWidth: keyWidth, keyHeight: keyHeight)
        }
    }

    private func grid(_ rows: [[KeyID]], keyWidth: CGFloat, keyHeight: CGFloat) -> some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { id in keyButton(id, width: keyWidth, height: keyHeight) }
                }
            }
        }
    }

    private func role(_ id: KeyID) -> LocalCalculatorKeyRole {
        switch id {
        case .digit, .point: return .digit
        case .clear: return .clear
        case .sign, .percent, .delete: return .function
        case .operation: return .operation
        case .equals: return .equals
        default: return .scientific
        }
    }

    private func key(for id: KeyID) -> LocalCalculatorModel.Key? {
        switch id {
        case .clear: return .clear
        case .sign: return .toggleSign
        case .percent: return .percent
        case .delete: return .delete
        case .point: return .decimalPoint
        case .equals: return .equals
        case .digit(let digit): return .digit(digit)
        case .operation(let operation): return .operation(operation)
        case .open: return .open
        case .close: return .close
        case .angle, .inverse: return nil
        case .sin: return .function(model.inverse ? "asin" : "sin")
        case .cos: return .function(model.inverse ? "acos" : "cos")
        case .tan: return .function(model.inverse ? "atan" : "tan")
        case .ln: return .function(model.inverse ? "exp" : "ln")
        case .log: return model.inverse ? .constant("10^") : .function("log")
        case .sqrt: return .function("sqrt")
        case .square: return .square
        case .power: return .power
        case .cbrt: return .function("cbrt")
        case .reciprocal: return .reciprocal
        case .factorial: return .factorial
        case .abs: return .function("abs")
        case .pi: return .constant("π")
        case .e: return .constant("e")
        case .answer: return .answer
        }
    }

    private func keyButton(_ id: KeyID, width: CGFloat, height: CGFloat) -> some View {
        let selected: Bool = {
            switch id {
            case .inverse: return model.inverse
            case .operation(let operation):
                return !model.showsAnswer
                    && model.input.trimmingCharacters(in: .whitespaces).hasSuffix(LocalCalculatorModel.symbol(operation))
            default: return false
            }
        }()
        let glyph = min(26, max(13, min(width, height) * 0.42))
        return Button {
            switch id {
            case .angle:
                model.angle = model.angle == .degrees ? .radians : .degrees
            case .inverse:
                model.inverse.toggle()
            default:
                if let key = key(for: id) { press(key) }
            }
            haptics.play(.selection)
        } label: {
            keyLabel(id, glyph: glyph)
                .frame(width: width, height: height)
                .contentShape(RoundedRectangle(cornerRadius: min(width, height) * 0.32, style: .continuous))
        }
        .buttonStyle(LocalCalculatorKeyStyle(role: role(id), selected: selected,
                                             radius: min(width, height) * 0.32))
        .accessibilityLabel(accessibilityLabel(id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func keyLabel(_ id: KeyID, glyph: CGFloat) -> some View {
        let small = glyph * 0.72
        switch id {
        case .clear: Text(verbatim: "AC").font(.system(size: glyph * 0.8, weight: .semibold))
        case .sign: Image(systemName: "plus.forwardslash.minus").font(.system(size: glyph * 0.8, weight: .medium))
        case .percent: Image(systemName: "percent").font(.system(size: glyph * 0.8, weight: .medium))
        case .delete: Image(systemName: "delete.left").font(.system(size: glyph * 0.8, weight: .medium))
        case .equals: Image(systemName: "equal").font(.system(size: glyph, weight: .bold))
        case .point: Text(verbatim: locale.decimalSeparator ?? ".").font(.system(size: glyph * 1.1))
        case .digit(let digit): Text(verbatim: Self.digit(digit, locale)).font(.system(size: glyph * 1.05))
        case .operation(let operation):
            Image(systemName: Self.symbol(operation)).font(.system(size: glyph * 0.95, weight: .bold))
        case .open: Text(verbatim: "(").font(.system(size: glyph))
        case .close: Text(verbatim: ")").font(.system(size: glyph))
        case .angle: Text(verbatim: model.angle == .degrees ? "Deg" : "Rad").font(.system(size: small, weight: .semibold))
        case .inverse: Text(verbatim: "Inv").font(.system(size: small, weight: .semibold))
        case .sin: Text(verbatim: model.inverse ? "sin⁻¹" : "sin").font(.system(size: small, weight: .medium))
        case .cos: Text(verbatim: model.inverse ? "cos⁻¹" : "cos").font(.system(size: small, weight: .medium))
        case .tan: Text(verbatim: model.inverse ? "tan⁻¹" : "tan").font(.system(size: small, weight: .medium))
        case .ln: Text(verbatim: model.inverse ? "eˣ" : "ln").font(.system(size: small, weight: .medium))
        case .log: Text(verbatim: model.inverse ? "10ˣ" : "log").font(.system(size: small, weight: .medium))
        case .sqrt: Text(verbatim: "√x").font(.system(size: small, weight: .medium))
        case .square: Text(verbatim: "x²").font(.system(size: small, weight: .medium))
        case .power: Text(verbatim: "xʸ").font(.system(size: small, weight: .medium))
        case .cbrt: Text(verbatim: "∛x").font(.system(size: small, weight: .medium))
        case .reciprocal: Text(verbatim: "1/x").font(.system(size: small, weight: .medium))
        case .factorial: Text(verbatim: "x!").font(.system(size: small, weight: .medium))
        case .abs: Text(verbatim: "|x|").font(.system(size: small, weight: .medium))
        case .pi: Text(verbatim: "π").font(.system(size: glyph * 0.9))
        case .e: Text(verbatim: "e").font(.system(size: glyph * 0.9))
        case .answer: Text(verbatim: "Ans").font(.system(size: small, weight: .semibold))
        }
    }

    private func accessibilityLabel(_ id: KeyID) -> Text {
        switch id {
        case .clear: return Text("All Clear", comment: "Local calculator key: clears the whole calculation.")
        case .sign: return Text("Plus or Minus", comment: "Local calculator key: changes the sign.")
        case .percent: return Text("Percent", comment: "Local calculator key.")
        case .delete: return Text("Delete", comment: "Local calculator: deletes the last digit typed.")
        case .point: return Text("Decimal Point", comment: "Local calculator key.")
        case .equals: return Text("Equals", comment: "Local calculator key.")
        case .digit(let digit): return Text(verbatim: Self.digit(digit, locale))
        case .operation(.add): return Text("Plus", comment: "Local calculator key: addition.")
        case .operation(.subtract): return Text("Minus", comment: "Local calculator key: subtraction.")
        case .operation(.multiply): return Text("Multiply", comment: "Local calculator key.")
        case .operation(.divide): return Text("Divide", comment: "Local calculator key.")
        case .open: return Text("Open Parenthesis", comment: "Local calculator key.")
        case .close: return Text("Close Parenthesis", comment: "Local calculator key.")
        case .angle:
            return model.angle == .degrees
                ? Text("Degrees", comment: "Local calculator: angles in degrees; tap for radians.")
                : Text("Radians", comment: "Local calculator: angles in radians; tap for degrees.")
        case .inverse: return Text("Inverse Functions", comment: "Local calculator key: switches to inverse functions.")
        case .sin: return model.inverse ? Text(verbatim: "arcsine") : Text(verbatim: "sine")
        case .cos: return model.inverse ? Text(verbatim: "arccosine") : Text(verbatim: "cosine")
        case .tan: return model.inverse ? Text(verbatim: "arctangent") : Text(verbatim: "tangent")
        case .ln: return model.inverse ? Text("e to the power of x", comment: "Local calculator key.")
                                       : Text("Natural Logarithm", comment: "Local calculator key.")
        case .log: return model.inverse ? Text("10 to the power of x", comment: "Local calculator key.")
                                        : Text("Logarithm", comment: "Local calculator key.")
        case .sqrt: return Text("Square Root", comment: "Local calculator key.")
        case .square: return Text("Squared", comment: "Local calculator key.")
        case .power: return Text("To the Power of", comment: "Local calculator key.")
        case .cbrt: return Text("Cube Root", comment: "Local calculator key.")
        case .reciprocal: return Text("Reciprocal", comment: "Local calculator key.")
        case .factorial: return Text("Factorial", comment: "Local calculator key.")
        case .abs: return Text("Absolute Value", comment: "Local calculator key.")
        case .pi: return Text(verbatim: "pi")
        case .e: return Text(verbatim: "e")
        case .answer: return Text("Last Answer", comment: "Local calculator key.")
        }
    }

    private static func symbol(_ operation: LocalCalculator.Operation) -> String {
        switch operation {
        case .add: return "plus"
        case .subtract: return "minus"
        case .multiply: return "multiply"
        case .divide: return "divide"
        }
    }

    /// The region's own digits, matching the display.
    private static func digit(_ digit: Int, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: digit)) ?? String(digit)
    }

    private func press(_ key: LocalCalculatorModel.Key) {
        model.press(key)
        if key == .equals, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: LocalCalculatorPanel.spoken(resultDisplay))
        }
    }
}

// MARK: - Notes view

/// Soulver / Math Notes: one calculation per line, typed or handwritten
/// (Scribble turns Apple Pencil writing into text), with each line's answer
/// under it in colour.
private struct LocalCalculatorNotesView: View {
    @ObservedObject var model: LocalCalculatorModel
    let haptics: ReceiverHaptics
    @Environment(\.locale) private var locale

    var body: some View {
        let results = model.noteResults
        VStack(spacing: 6) {
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.notes.enumerated()), id: \.element.id) { index, line in
                            noteRow(line, result: index < results.count ? results[index] : CalculatorLineResult())
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.focusedNote) { id in
                    if let id { withAnimation { reader.scrollTo(id, anchor: .center) } }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 8) {
                Text("Type or write: 20% of 150, 5 plus 3, rent = 1200",
                     comment: "Local calculator notes: what can be typed.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button {
                    model.angle = model.angle == .degrees ? .radians : .degrees
                } label: {
                    Text(verbatim: model.angle == .degrees ? "Deg" : "Rad")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(LocalCalculatorPalette.scientific))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.angle == .degrees
                                    ? Text("Degrees", comment: "Local calculator: angles in degrees; tap for radians.")
                                    : Text("Radians", comment: "Local calculator: angles in radians; tap for degrees."))
                Button {
                    model.clearNotes()
                    haptics.play(.selection)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Notes", comment: "Local calculator: clears every notes line."))
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            if model.focusedNote == nil { model.focusedNote = model.notes.last?.id }
        }
    }

    private func noteRow(_ line: LocalCalculatorModel.NoteLine, result: CalculatorLineResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LocalCalculatorNoteField(
                text: Binding(get: { model.notes.first(where: { $0.id == line.id })?.text ?? "" },
                              set: { text in
                                  if let index = model.notes.firstIndex(where: { $0.id == line.id }) {
                                      model.notes[index].text = text
                                  }
                              }),
                focused: model.focusedNote == line.id,
                onFocus: { model.focusedNote = line.id },
                onReturn: { model.insertNote(after: line.id) },
                onDeleteEmpty: { model.removeEmptyNote(line.id) })
                .frame(height: 30)
            if let value = result.value {
                let shown = LocalCalculatorFormat.display(value, locale: locale).text
                Button {
                    model.copy(value, locale: locale)
                    haptics.play(.confirmation)
                } label: {
                    Text(verbatim: (result.assigns.map { $0 + " = " } ?? "= ") + shown)
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LocalCalculatorPalette.answer)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .modifier(LocalCalculatorShimmer(trigger: shown))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel(Text(verbatim: "= " + shown))
                .accessibilityHint(Text("Copies this answer.", comment: "Local calculator notes: an answer's hint."))
                .padding(.bottom, 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: result.value)
    }
}

/// One notes line: a plain text field (so Apple Pencil Scribble, dictation
/// and a hardware keyboard all work) that reports Return and Delete on an
/// empty line.
private struct LocalCalculatorNoteField: UIViewRepresentable {
    @Binding var text: String
    let focused: Bool
    let onFocus: () -> Void
    let onReturn: () -> Void
    let onDeleteEmpty: () -> Void

    func makeUIView(context: Context) -> NoteTextField {
        let field = NoteTextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .regular)
        field.textColor = .white
        field.tintColor = UIColor(LocalCalculatorPalette.answer)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .next
        field.keyboardAppearance = .dark
        field.attributedPlaceholder = NSAttributedString(
            string: String(localized: "e.g. 80 × 5 or what is 15% of 80",
                           comment: "Local calculator notes: an empty line's placeholder."),
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.25)])
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: NoteTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.onDeleteEmpty = onDeleteEmpty
        if focused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ field: NoteTextField, coordinator: Coordinator) {
        if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LocalCalculatorNoteField

        init(parent: LocalCalculatorNoteField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            MainActor.assumeIsolated { LocalCalculatorTextFocus.isEditing = true }
            parent.onFocus()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            MainActor.assumeIsolated { LocalCalculatorTextFocus.isEditing = false }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }

    final class NoteTextField: UITextField {
        var onDeleteEmpty: (() -> Void)?

        override func deleteBackward() {
            if (text ?? "").isEmpty {
                onDeleteEmpty?()
                return
            }
            super.deleteBackward()
        }
    }
}

// MARK: - Shimmer

/// A bright band that sweeps across an answer once when it appears or
/// changes, as Math Notes does. Nothing moves with Reduce Motion.
private struct LocalCalculatorShimmer<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @State private var phase: CGFloat = 1.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, LocalCalculatorPalette.answerGlow.opacity(0.95), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(40, proxy.size.width * 0.45))
                        .offset(x: phase * proxy.size.width)
                        .blendMode(.sourceAtop)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onChange(of: trigger) { _ in run() }
            .onAppear { run() }
    }

    private func run() {
        guard !reduceMotion else { return }
        phase = -0.5
        withAnimation(.easeInOut(duration: 0.9)) { phase = 1.4 }
    }
}

// MARK: - Key style

private enum LocalCalculatorKeyRole {
    case digit, function, clear, operation, equals, scientific

    var fill: Color {
        switch self {
        case .digit: return LocalCalculatorPalette.digit
        case .function: return LocalCalculatorPalette.function
        case .clear: return LocalCalculatorPalette.clear
        case .operation: return LocalCalculatorPalette.operation
        case .equals: return LocalCalculatorPalette.equals
        case .scientific: return LocalCalculatorPalette.scientific
        }
    }
}

/// Coloured keys: dark digits, slate functions, a red AC, orange operators
/// (white while they wait for the next number), a green =, and violet
/// scientific keys.
private struct LocalCalculatorKeyStyle: ButtonStyle {
    let role: LocalCalculatorKeyRole
    let selected: Bool
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .foregroundStyle(selected ? role.fill : Color.white)
            .background(shape.fill(selected ? Color.white : role.fill))
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func defaultScrollAnchorBottom() -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }
}
