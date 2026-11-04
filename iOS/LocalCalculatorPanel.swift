import SwiftUI
import UIKit

// MARK: - Model

/// The receiver's local calculator for this app session: the calculation
/// (`LocalCalculator`) and whether its panel is open. Memory only: it
/// survives the panel closing, Home, reconnects and Settings, and is gone
/// when the app quits. Owned by `ReceiverControlStore`, so the demo has its
/// own. Nothing here can reach the Mac.
@MainActor
final class LocalCalculatorModel: ObservableObject {
    @Published private(set) var calculator = LocalCalculator()
    @Published private(set) var isOpen = false
    /// Bumped by each Copy Result, for the button's brief confirmation.
    @Published private(set) var copyCount = 0

    func press(_ key: LocalCalculator.Key) {
        calculator.press(key)
    }

    func toggle() { isOpen.toggle() }

    func close() { isOpen = false }

    /// Writes the result to this device's pasteboard, like any other copy
    /// in the app. Unified Clipboard isn't called or changed: if the person
    /// allowed it, it notices this copy later through its own change
    /// detection (`ClipboardModel.checkLocal`), exactly as it would a copy
    /// made in another app. False while the display shows Error.
    @discardableResult
    func copyResult(locale: Locale = .current, to pasteboard: UIPasteboard = .general) -> Bool {
        guard let text = calculator.copyText(locale: locale) else { return false }
        pasteboard.string = text
        copyCount &+= 1
        return true
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

// MARK: - Layer

/// The entry button and, while open, the panel beside it, in the control
/// overlay's coordinates. Only the button and the panel take touches; the
/// rest of the layer passes them through to the Mac untouched, so there is
/// no tap-catcher and nothing outside dismisses it: Close, the button
/// again, or VoiceOver's escape gesture do.
struct LocalCalculatorLayer<Chip: View>: View {
    @ObservedObject var model: LocalCalculatorModel
    let containerSize: CGSize
    /// nil while the button isn't shown (an open panel then sits in the
    /// top-left of `panelBounds`).
    let buttonFrame: CGRect?
    /// A Strip caption under the button, when Control Hints are on.
    var buttonHint: String?
    /// The safe area (above any keyboard) the panel must stay inside.
    let panelBounds: CGRect
    /// Other controls and reserved regions the panel keeps off when it can.
    var obstacles: [CGRect] = []
    /// Auto-hide fades the button with the other controls, but never while
    /// its panel is open, and never the panel.
    var autoHiding = false
    let haptics: ReceiverHaptics
    @ViewBuilder let chip: (_ selected: Bool) -> Chip

    @ScaledMetric(relativeTo: .body) private var preferredKey: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metrics = LocalCalculatorPanelMetrics.fitting(panelBounds.size, preferredKey: preferredKey)
        let anchor = buttonFrame ?? CGRect(x: panelBounds.minX, y: panelBounds.minY, width: 0, height: 0)
        let panel: CGRect? = model.isOpen
            ? LocalCalculatorPlacement.panelFrame(button: anchor, size: metrics.size, bounds: panelBounds,
                                                  obstacles: obstacles)
            : nil
        let buttonVisible = !autoHiding || model.isOpen
        ZStack(alignment: .topLeading) {
            if let buttonFrame {
                LocalCalculatorEntryButton(open: model.isOpen, diameter: buttonFrame.width, hint: buttonHint,
                                           chip: chip) {
                    model.toggle()
                    haptics.play(.selection)
                }
                .position(x: buttonFrame.midX,
                          y: buttonFrame.minY + (buttonFrame.height + (buttonHint == nil ? 0 : PadControlMetrics.hintHeight + 2)) / 2)
                .opacity(buttonVisible ? 1 : 0)
                .allowsHitTesting(buttonVisible)
            }
            if let panel {
                LocalCalculatorPanel(model: model, metrics: metrics, haptics: haptics)
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.92, anchor: Self.unitPoint(of: anchor, in: panel))
                                    .combined(with: .opacity))
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: model.isOpen)
        .preference(key: LocalCalculatorFramesPreference.self, value: panel.map { [$0] } ?? [])
    }

    /// The button's center relative to the panel, so it grows out of it.
    private static func unitPoint(of anchor: CGRect, in panel: CGRect) -> UnitPoint {
        guard panel.width > 0, panel.height > 0 else { return .topLeading }
        return UnitPoint(x: min(max((anchor.midX - panel.minX) / panel.width, 0), 1),
                         y: min(max((anchor.midY - panel.minY) / panel.height, 0), 1))
    }
}

// MARK: - Entry button

/// The calculator's control: a chip like its neighbours, drawn selected
/// while the panel is open. A tap opens or closes the panel.
struct LocalCalculatorEntryButton<Chip: View>: View {
    let open: Bool
    let diameter: CGFloat
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

// MARK: - Panel

/// The calculator itself: Close and Copy Result, the display, and the
/// familiar 4 × 5 keypad (AC ± % ÷ / 7 8 9 × / 4 5 6 − / 1 2 3 + /
/// ⌫ 0 . =). Every touch inside it stays here.
struct LocalCalculatorPanel: View {
    static let symbolName = "plus.forwardslash.minus"

    @ObservedObject var model: LocalCalculatorModel
    let metrics: LocalCalculatorPanelMetrics
    let haptics: ReceiverHaptics

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var displayFont: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var keyFont: CGFloat = 24
    @State private var showsCopied = false

    static var deviceOnlyHint: Text {
        UIDevice.current.userInterfaceIdiom == .pad
            ? Text("Works on this iPad only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
            : Text("Works on this iPhone only. Nothing is sent to your Mac.",
                   comment: "Accessibility hint for the local calculator.")
    }

    var body: some View {
        let calculator = model.calculator
        VStack(spacing: LocalCalculatorPanelMetrics.gap) {
            header(calculator)
                .frame(height: LocalCalculatorPanelMetrics.headerHeight)
            display(calculator)
                .frame(height: LocalCalculatorPanelMetrics.displayHeight)
            Grid(horizontalSpacing: LocalCalculatorPanelMetrics.gap, verticalSpacing: LocalCalculatorPanelMetrics.gap) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(Self.rows[row], id: \.self) { key in keyButton(key, calculator) }
                    }
                }
            }
        }
        .padding(LocalCalculatorPanelMetrics.padding)
        .background(panelBackground)
        // Gaps between keys belong to the panel too: nothing falls through.
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calculator", comment: "The local calculator's control and panel."))
        .accessibilityAction(.escape) { close() }
        .onChange(of: model.copyCount) { _ in flashCopied() }
    }

    private static let cornerRadius: CGFloat = 22

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    // MARK: Header

    private func header(_ calculator: LocalCalculator) -> some View {
        HStack(spacing: LocalCalculatorPanelMetrics.gap) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: LocalCalculatorPanelMetrics.headerHeight, height: LocalCalculatorPanelMetrics.headerHeight)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .frame(minWidth: 44, minHeight: LocalCalculatorPanelMetrics.headerHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close Calculator", comment: "Closes the local calculator's panel."))
            Spacer(minLength: 0)
            Button(action: copy) {
                Label {
                    Text(showsCopied ? "Copied" : "Copy",
                         comment: "Local calculator: copies the result to this device's clipboard.")
                } icon: {
                    Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                }
                .font(.subheadline.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(calculator.isError ? 0.35 : 0.95))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: LocalCalculatorPanelMetrics.headerHeight)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(calculator.isError)
            .accessibilityLabel(Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard."))
            .accessibilityHint(Text("Copies the number to this device's clipboard.",
                                    comment: "Accessibility hint for the local calculator's Copy Result button."))
        }
    }

    // MARK: Display

    private func display(_ calculator: LocalCalculator) -> some View {
        let shown = calculator.display(locale: locale)
        let text = shown == .error ? String(localized: "Error", comment: "Local calculator display after a division by zero or an overflow.") : shown.text
        return Text(verbatim: text)
            .font(.system(size: min(displayFont, LocalCalculatorPanelMetrics.displayHeight * 0.92), weight: .light))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            // A sideways swipe deletes the last digit, as in Calculator.
            .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                let dx = value.translation.width
                if abs(dx) > 28, abs(dx) > abs(value.translation.height) * 1.5 { press(.delete) }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Result", comment: "Local calculator display, read with its number."))
            .accessibilityValue(Text(verbatim: Self.spoken(shown)))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: Text("Delete", comment: "Local calculator: deletes the last digit typed.")) {
                press(.delete)
            }
            .accessibilityAction(named: Text("Copy Result", comment: "Local calculator: copies the result to this device's clipboard.")) {
                copy()
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

    // MARK: Keys

    private enum KeyID: Hashable {
        case clear, sign, percent, delete, point, equals
        case digit(Int)
        case operation(LocalCalculator.Operation)
    }

    private static let rows: [[KeyID]] = [
        [.clear, .sign, .percent, .operation(.divide)],
        [.digit(7), .digit(8), .digit(9), .operation(.multiply)],
        [.digit(4), .digit(5), .digit(6), .operation(.subtract)],
        [.digit(1), .digit(2), .digit(3), .operation(.add)],
        [.delete, .digit(0), .point, .equals],
    ]

    private func keyButton(_ id: KeyID, _ calculator: LocalCalculator) -> some View {
        let role: KeyRole
        let key: LocalCalculator.Key
        switch id {
        case .clear: role = .function; key = .clear
        case .sign: role = .function; key = .toggleSign
        case .percent: role = .function; key = .percent
        case .delete: role = .function; key = .delete
        case .point: role = .digit; key = .decimalPoint
        case .equals: role = .operation; key = .equals
        case .digit(let digit): role = .digit; key = .digit(digit)
        case .operation(let operation): role = .operation; key = .operation(operation)
        }
        let selected: Bool = {
            if case .operation(let operation) = id { return calculator.highlightedOperation == operation }
            return false
        }()
        let size = metrics.key
        let glyph = min(keyFont, size * 0.5)
        return Button { press(key) } label: {
            keyLabel(id, calculator, glyph: glyph)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(LocalCalculatorKeyStyle(role: role, selected: selected))
        .accessibilityLabel(accessibilityLabel(id, calculator))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func keyLabel(_ id: KeyID, _ calculator: LocalCalculator, glyph: CGFloat) -> some View {
        switch id {
        case .clear:
            Text(verbatim: calculator.showsAllClear ? "AC" : "C")
                .font(.system(size: glyph * 0.85, weight: .medium))
        case .sign: Image(systemName: "plus.forwardslash.minus").font(.system(size: glyph * 0.85, weight: .medium))
        case .percent: Image(systemName: "percent").font(.system(size: glyph * 0.85, weight: .medium))
        case .delete: Image(systemName: "delete.left").font(.system(size: glyph * 0.85, weight: .medium))
        case .equals: Image(systemName: "equal").font(.system(size: glyph, weight: .semibold))
        case .point:
            Text(verbatim: Self.decimalSeparator(locale)).font(.system(size: glyph * 1.1, weight: .regular))
        case .digit(let digit):
            Text(verbatim: Self.digit(digit, locale)).font(.system(size: glyph * 1.1, weight: .regular))
        case .operation(let operation):
            Image(systemName: Self.symbol(operation)).font(.system(size: glyph, weight: .semibold))
        }
    }

    private func accessibilityLabel(_ id: KeyID, _ calculator: LocalCalculator) -> Text {
        switch id {
        case .clear:
            return calculator.showsAllClear
                ? Text("All Clear", comment: "Local calculator key: clears the whole calculation.")
                : Text("Clear", comment: "Local calculator key: clears the number being typed.")
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

    private static func decimalSeparator(_ locale: Locale) -> String {
        locale.decimalSeparator ?? "."
    }

    // MARK: Actions

    private func press(_ key: LocalCalculator.Key) {
        model.press(key)
        if key == .equals, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: Self.spoken(model.calculator.display(locale: locale)))
        }
    }

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
}

/// The keys in the controls' neutral language: quiet discs for digits, a
/// lighter tone for AC ± % ⌫, and operators that invert (white, dark
/// glyph) while they wait for the next number, as Calculator's do.
private struct LocalCalculatorKeyStyle: ButtonStyle {
    let role: KeyRole
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let base: Double = selected ? 0.92 : role.baseOpacity
        configuration.label
            .foregroundStyle(selected ? Color.black : Color.white)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? min(1, base + 0.18) : base)))
            .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.5 : 0.1), lineWidth: 0.75))
    }
}

private enum KeyRole {
    case digit, function, operation

    var baseOpacity: Double {
        switch self {
        case .digit: return 0.14
        case .function: return 0.3
        case .operation: return 0.22
        }
    }
}
