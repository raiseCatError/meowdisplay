// The receiver's built-in calculator: a pure, Foundation-only engine that
// behaves like the iPhone's basic Calculator. It runs entirely on this
// device: nothing here can reach the Mac, the wire or the clipboard (the
// view copies `copyText` to the local pasteboard itself). Hostless-testable.
//
// Semantics (unit-tested in `LocalCalculatorTests`):
// - Arithmetic is `Decimal`, never `Double`, so 0.1 + 0.2 is exactly 0.3.
// - Standard precedence, as on the iOS basic calculator: × and ÷ before
//   + and −, so 2 + 3 × 4 = 14. The display shows the value just reduced
//   (2 × 3 + shows 6; 2 + 3 × still shows 3).
// - Pressing another operator straight after one replaces it.
// - % is "percent of" after + or −: 50 + 10 % → 5, = → 55. Otherwise it
//   divides by 100: 10 % → 0.1, 50 × 10 % = 5.
// - = straight after an operator reuses the shown value (5 + = → 10).
// - Repeated = repeats the last operator with its last operand
//   (2 + 3 = = → 8; 2 + 3 × 4 = = → 14, 56). A new number typed after =
//   takes the same step (2 + 3 = 7 = → 10). A new operator or AC ends it.
// - ± flips the number being typed (on 0 it shows −0, ready for digits) or
//   the value on screen; straight after an operator it starts −0.
// - Input stops at 9 digits (the 0 before the point in a number below one
//   isn't counted) and takes one decimal point.
// - Division by zero, or a result of 1e100 or more, shows Error. The next
//   digit or point starts over; C/AC clears; every other key is ignored.
// - C clears the number being typed and keeps the calculation; the key then
//   reads AC, which clears everything.
// - Delete (⌫, or a swipe on the display) removes the last typed character;
//   it never edits a result.

import Foundation

struct LocalCalculator: Equatable {
    enum Operation: String, CaseIterable, Equatable, Hashable {
        case add
        case subtract
        case multiply
        case divide

        /// × and ÷ bind tighter than + and −.
        var precedence: Int { self == .add || self == .subtract ? 1 : 2 }
    }

    enum Key: Equatable, Hashable {
        case digit(Int)
        case decimalPoint
        case operation(Operation)
        case equals
        /// C or AC, whichever the key currently reads (`showsAllClear`).
        case clear
        case toggleSign
        case percent
        case delete
    }

    /// iPhone's input cap.
    static let maximumInputDigits = 9
    /// Results show at most this many significant digits.
    static let displaySignificantDigits = 9
    /// Significant digits of a scientific display's mantissa (1.234568e11).
    static let scientificSignificantDigits = 7
    /// Copy Result's precision: what a spreadsheet keeps (Numbers and Excel
    /// hold 15 significant digits), so a pasted value means the same there.
    static let copySignificantDigits = 15
    /// Results at or beyond this magnitude are an Error, like an overflow.
    static let overflowLimit = LocalCalculatorFormat.power(100)
    /// Results smaller than this are treated as zero.
    static let underflowLimit = LocalCalculatorFormat.power(-100)

    /// The number being typed, kept as typed so 1.50 and a trailing point
    /// show as they were entered.
    struct Entry: Equatable {
        var negative = false
        /// "0", or the integer digits without leading zeros.
        var integerDigits = "0"
        /// nil: no decimal point yet; "": a point with nothing after it.
        var fractionDigits: String?

        /// Digits that count toward the cap: a lone 0 before the point
        /// doesn't.
        var countedDigits: Int {
            (integerDigits == "0" ? 0 : integerDigits.count) + (fractionDigits?.count ?? 0)
        }

        var isPlainZero: Bool { !negative && integerDigits == "0" && fractionDigits == nil }

        var value: Decimal {
            let text = (negative ? "-" : "") + integerDigits + "." + (fractionDigits.flatMap { $0.isEmpty ? nil : $0 } ?? "0")
            return Decimal(string: text, locale: LocalCalculatorFormat.posix) ?? 0
        }
    }

    private struct Pending: Equatable {
        var value: Decimal
        var operation: Operation
    }

    private enum Phase: Equatable {
        /// A number is being typed.
        case entering(Entry)
        /// An operator was just chosen; `shown` is the value it applies to.
        case operatorChosen
        /// A value on screen (a result, or a % or ± of one) that the next
        /// operator uses and the next digit replaces.
        case showingValue
        case error
    }

    private var phase = Phase.entering(Entry())
    private var shown: Decimal = 0
    private var pending: [Pending] = []
    /// For repeated =: the last operator and its operand.
    private var repeatStep: Pending?

    init() {}

    // MARK: State for the view

    var isError: Bool { phase == .error }

    /// The clear key reads AC unless a number has been typed (then C).
    var showsAllClear: Bool {
        guard case .entering(let entry) = phase else { return true }
        return entry.isPlainZero
    }

    /// The operator waiting for its operand, which iOS highlights.
    var highlightedOperation: Operation? {
        guard phase == .operatorChosen else { return nil }
        return pending.last?.operation
    }

    /// Delete only edits a number being typed.
    var canDelete: Bool {
        guard case .entering(let entry) = phase else { return false }
        return !entry.isPlainZero
    }

    /// The value on screen; nil while showing Error.
    var currentValue: Decimal? {
        switch phase {
        case .entering(let entry): return entry.value
        case .operatorChosen, .showingValue: return shown
        case .error: return nil
        }
    }

    // MARK: Keys

    mutating func press(_ key: Key) {
        switch key {
        case .digit(let digit): type(digit: digit)
        case .decimalPoint: typeDecimalPoint()
        case .operation(let operation): choose(operation)
        case .equals: equals()
        case .clear: clear()
        case .toggleSign: toggleSign()
        case .percent: percent()
        case .delete: delete()
        }
    }

    private mutating func type(digit: Int) {
        guard (0...9).contains(digit) else { return }
        var entry = startEntryIfNeeded()
        if entry.fractionDigits == nil {
            if entry.integerDigits == "0" {
                entry.integerDigits = String(digit)
            } else if entry.countedDigits < Self.maximumInputDigits {
                entry.integerDigits += String(digit)
            }
        } else if entry.countedDigits < Self.maximumInputDigits {
            entry.fractionDigits = (entry.fractionDigits ?? "") + String(digit)
        }
        phase = .entering(entry)
    }

    private mutating func typeDecimalPoint() {
        var entry = startEntryIfNeeded()
        if entry.fractionDigits == nil, entry.countedDigits < Self.maximumInputDigits {
            entry.fractionDigits = ""
        }
        phase = .entering(entry)
    }

    /// The number being typed, or a fresh one: after an operator or a value
    /// it starts the next operand, and after Error it starts over.
    private mutating func startEntryIfNeeded() -> Entry {
        switch phase {
        case .entering(let entry): return entry
        case .operatorChosen, .showingValue: return Entry()
        case .error:
            resetAll()
            return Entry()
        }
    }

    private mutating func choose(_ operation: Operation) {
        var operand: Decimal
        switch phase {
        case .error: return
        case .entering(let entry): operand = entry.value
        case .showingValue: operand = shown
        case .operatorChosen:
            // Replace the operator just chosen: take its operand back and
            // apply the new one as if it had been pressed instead.
            guard let replaced = pending.popLast() else { operand = shown; break }
            operand = replaced.value
        }
        while let top = pending.last, top.operation.precedence >= operation.precedence {
            pending.removeLast()
            guard let result = Self.apply(top.operation, top.value, operand) else { return fail() }
            operand = result
        }
        pending.append(Pending(value: operand, operation: operation))
        shown = operand
        phase = .operatorChosen
    }

    private mutating func equals() {
        switch phase {
        case .error: return
        case .entering, .showingValue, .operatorChosen: break
        }
        guard let last = pending.last else {
            // Nothing pending: repeat the last step, or just settle the
            // number being typed.
            let value = currentValue ?? 0
            if let step = repeatStep {
                guard let result = Self.apply(step.operation, value, step.value) else { return fail() }
                show(result)
            } else {
                show(value)
            }
            return
        }
        // = straight after an operator reuses the shown value (5 + = → 10).
        var operand = currentValue ?? 0
        repeatStep = Pending(value: operand, operation: last.operation)
        while let top = pending.popLast() {
            guard let result = Self.apply(top.operation, top.value, operand) else { return fail() }
            operand = result
        }
        show(operand)
    }

    private mutating func clear() {
        if case .entering(let entry) = phase, !entry.isPlainZero {
            // C: only the number being typed; the calculation stays.
            phase = .entering(Entry())
        } else {
            resetAll()
        }
    }

    private mutating func toggleSign() {
        switch phase {
        case .error: return
        case .entering(var entry):
            entry.negative.toggle()
            phase = .entering(entry)
        case .operatorChosen:
            phase = .entering(Entry(negative: true))
        case .showingValue:
            if shown == 0 {
                phase = .entering(Entry(negative: true))
            } else {
                shown = -shown
            }
        }
    }

    private mutating func percent() {
        guard let value = currentValue else { return }
        let result: Decimal
        if let top = pending.last, top.operation.precedence == Operation.add.precedence {
            result = top.value * value / 100
        } else {
            result = value / 100
        }
        guard let checked = Self.checked(result) else { return fail() }
        show(checked)
    }

    private mutating func delete() {
        guard case .entering(var entry) = phase else { return }
        if let fraction = entry.fractionDigits {
            entry.fractionDigits = fraction.isEmpty ? nil : String(fraction.dropLast())
        } else {
            entry.integerDigits = String(entry.integerDigits.dropLast())
            if entry.integerDigits.isEmpty { entry.integerDigits = "0" }
        }
        if entry.integerDigits == "0", entry.fractionDigits == nil { entry.negative = false }
        phase = .entering(entry)
    }

    private mutating func show(_ value: Decimal) {
        shown = value
        phase = .showingValue
    }

    private mutating func fail() {
        pending = []
        repeatStep = nil
        shown = 0
        phase = .error
    }

    private mutating func resetAll() {
        self = LocalCalculator()
    }

    /// nil for division by zero or an overflow.
    static func apply(_ operation: Operation, _ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        switch operation {
        case .add: return checked(lhs + rhs)
        case .subtract: return checked(lhs - rhs)
        case .multiply: return checked(lhs * rhs)
        case .divide:
            guard rhs != 0 else { return nil }
            return checked(lhs / rhs)
        }
    }

    private static func checked(_ value: Decimal) -> Decimal? {
        guard !value.isNaN, value.magnitude < overflowLimit else { return nil }
        return value.magnitude < underflowLimit ? 0 : value
    }

    // MARK: Text

    /// What the display shows, formatted for `locale`.
    func display(locale: Locale = .current) -> LocalCalculatorDisplay {
        switch phase {
        case .error: return .error
        case .entering(let entry): return LocalCalculatorFormat.display(entry, locale: locale)
        case .operatorChosen, .showingValue: return LocalCalculatorFormat.display(shown, locale: locale)
        }
    }

    /// The plain number Copy Result writes; nil while showing Error.
    func copyText(locale: Locale = .current) -> String? {
        currentValue.map { LocalCalculatorFormat.copyText($0, locale: locale) }
    }
}

/// The display's content: plain text, a scientific value, or Error.
enum LocalCalculatorDisplay: Equatable {
    case plain(String)
    /// `mantissa` × 10^`exponent`, drawn as "1.234568e11" like iOS.
    case scientific(mantissa: String, exponent: String)
    case error

    /// The text drawn on the display. Error's word comes from the view.
    var text: String {
        switch self {
        case .plain(let text): return text
        case .scientific(let mantissa, let exponent): return mantissa + "e" + exponent
        case .error: return "Error"
        }
    }
}

enum LocalCalculatorFormat {
    static let posix = Locale(identifier: "en_US_POSIX")

    /// 10^exponent, exactly.
    static func power(_ exponent: Int) -> Decimal {
        Decimal(sign: .plus, exponent: exponent, significand: 1)
    }

    /// floor(log10(|value|)) for a nonzero value.
    static func magnitude(of value: Decimal) -> Int {
        let absolute = value.magnitude
        var exponent = 0
        if absolute >= 1 {
            while absolute >= power(exponent + 1) { exponent += 1 }
        } else {
            while absolute < power(exponent), exponent > -400 { exponent -= 1 }
        }
        return exponent
    }

    /// `value` rounded half away from zero to `scale` decimal places (a
    /// negative scale rounds to tens, hundreds, …).
    static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    static func rounded(_ value: Decimal, significantDigits: Int) -> Decimal {
        guard value != 0 else { return 0 }
        return rounded(value, scale: significantDigits - 1 - magnitude(of: value))
    }

    private static func formatter(locale: Locale, fractionDigits: ClosedRange<Int>, grouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = fractionDigits.lowerBound
        formatter.maximumFractionDigits = fractionDigits.upperBound
        formatter.roundingMode = .halfUp
        return formatter
    }

    private static func string(_ value: Decimal, _ formatter: NumberFormatter) -> String {
        formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    /// A result: at most 9 significant digits with the locale's grouping
    /// and decimal separator; 1e9 or more, or too small to show any digit
    /// within 9 decimals, switches to scientific (1.234568e11, 1.5e-10).
    static func display(_ value: Decimal, locale: Locale) -> LocalCalculatorDisplay {
        guard value != 0 else { return .plain(string(0, formatter(locale: locale, fractionDigits: 0...0, grouping: true))) }
        let rounded = rounded(value, significantDigits: LocalCalculator.displaySignificantDigits)
        // Scientific rounds the original value once, never a rounded one again.
        guard rounded.magnitude < power(LocalCalculator.displaySignificantDigits) else {
            return scientific(value, locale: locale)
        }
        let integerDigits = rounded.magnitude >= 1 ? magnitude(of: rounded) + 1 : 0
        let fractionLimit = max(0, LocalCalculator.displaySignificantDigits - integerDigits)
        let plain = self.rounded(value, scale: fractionLimit)
        guard plain != 0 else { return scientific(value, locale: locale) }
        return .plain(string(plain, formatter(locale: locale, fractionDigits: 0...fractionLimit, grouping: true)))
    }

    private static func scientific(_ value: Decimal, locale: Locale) -> LocalCalculatorDisplay {
        var exponent = magnitude(of: value)
        let digits = LocalCalculator.scientificSignificantDigits - 1
        var mantissa = rounded(value / power(exponent), scale: digits)
        if mantissa.magnitude >= 10 {
            mantissa /= 10
            exponent += 1
        }
        let mantissaText = string(mantissa, formatter(locale: locale, fractionDigits: 0...digits, grouping: false))
        let exponentText = string(Decimal(exponent), formatter(locale: locale, fractionDigits: 0...0, grouping: false))
        return .scientific(mantissa: mantissaText, exponent: exponentText)
    }

    /// The number being typed, exactly as typed (1.50, a trailing point,
    /// −0), in the locale's digits and separators.
    static func display(_ entry: LocalCalculator.Entry, locale: Locale) -> LocalCalculatorDisplay {
        let fraction = entry.fractionDigits ?? ""
        let digits = fraction.count
        let unsigned = Decimal(string: entry.integerDigits + (fraction.isEmpty ? "" : "." + fraction), locale: posix) ?? 0
        let formatter = formatter(locale: locale, fractionDigits: digits...digits, grouping: true)
        var text = string(unsigned, formatter)
        if entry.fractionDigits == "" { text += formatter.decimalSeparator ?? "." }
        if entry.negative { text = (formatter.minusSign ?? "-") + text }
        return .plain(text)
    }

    /// Copy Result's text: the value to 15 significant digits in ASCII
    /// digits, with no grouping separators (they mean different things in
    /// different regions and break parsers) and the region's decimal
    /// separator ("," or ".", so Numbers and Excel read it as a number in
    /// the same region on the Mac). Beyond 1e21, or below 1e-9, it uses E
    /// notation (1.5E-30), which every spreadsheet and language reads.
    static func copyText(_ value: Decimal, locale: Locale) -> String {
        let separator = locale.decimalSeparator == "," ? "," : "."
        guard value != 0 else { return "0" }
        let rounded = rounded(value, significantDigits: LocalCalculator.copySignificantDigits)
        let exponent = magnitude(of: rounded)
        if exponent >= 21 || exponent < -9 {
            let mantissa = Self.rounded(rounded / power(exponent), scale: LocalCalculator.copySignificantDigits - 1)
            return plainDigits(mantissa, separator: separator) + "E" + String(exponent)
        }
        return plainDigits(rounded, separator: separator)
    }

    /// Positional digits, no grouping, no trailing fractional zeros.
    private static func plainDigits(_ value: Decimal, separator: String) -> String {
        // `Decimal.description` is positional, with "." whatever the region.
        var text = value.description
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.replacingOccurrences(of: ".", with: separator)
    }
}
