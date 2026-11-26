// The receiver calculator's keypad: what has been typed, the answer and the
// history. Pure and Foundation-only (`CalculatorKeypadTests`); the view's
// `LocalCalculatorModel` owns one. It builds an expression as typed
// ("80 × 5"), shows the answer under it live, and = keeps the calculation
// on screen above its answer and in the history.

import Foundation

struct CalculatorKeypad: Equatable {
    struct HistoryEntry: Identifiable, Equatable {
        let id = UUID()
        var expression: String
        var value: Decimal
    }

    enum Key: Equatable, Hashable {
        case digit(Int)
        case decimalPoint
        case operation(LocalCalculator.Operation)
        case equals
        case clear
        case delete
        case toggleSign
        case percent
        case open
        case close
        case power
        case square
        case reciprocal
        case factorial
        case function(String)
        case constant(String)
        case answer
        case modulo
    }

    static let maximumHistory = 100
    static let maximumInputLength = 200

    /// The expression, as shown ("80 × 5").
    private(set) var input = ""
    /// True straight after =: the answer is on screen and the next digit
    /// starts a new calculation while an operator continues from it.
    private(set) var showsAnswer = false
    private(set) var lastAnswer: Decimal?
    /// The expression the shown answer came from.
    private(set) var answeredExpression = ""
    private(set) var failed = false
    private(set) var history: [HistoryEntry] = []
    var angle: CalculatorAngleUnit = .degrees

    var context: CalculatorContext {
        CalculatorContext(angle: angle, answer: lastAnswer)
    }

    /// The live answer while typing, when the input is a calculation (not
    /// just a number).
    var preview: Decimal? {
        guard !showsAnswer, !input.isEmpty, Self.isCalculation(input) else { return nil }
        return CalculatorExpression.value(input, context: context)
    }

    /// The number the Result line shows and Copy copies.
    var currentValue: Decimal? {
        if failed { return nil }
        if showsAnswer { return lastAnswer }
        if input.isEmpty { return 0 }
        return CalculatorExpression.value(input, context: context)
    }

    mutating func press(_ key: Key) {
        if key != .equals { failed = false }
        switch key {
        case .digit(let digit): startOperandIfNeeded(); append(String(digit))
        case .decimalPoint:
            startOperandIfNeeded()
            if Self.lastNumber(in: input)?.contains(".") == true { return }
            if input.isEmpty || !(input.last.map(Self.isDigitCharacter) ?? false) { append("0") }
            append(".")
        case .operation(let operation): appendOperator(Self.symbol(operation))
        case .modulo: appendOperator("mod")
        case .power: continueFromAnswer(); append("^")
        case .percent: continueFromAnswer(); append("%")
        case .square: continueFromAnswer(); append("²")
        case .factorial: continueFromAnswer(); append("!")
        case .reciprocal:
            continueFromAnswer()
            input = input.isEmpty ? "1 ÷ " : "1 ÷ (" + input + ")"
        case .open: startOperandIfNeeded(); append("(")
        case .close:
            let opens = input.filter { $0 == "(" }.count
            let closes = input.filter { $0 == ")" }.count
            if opens > closes { append(")") }
        case .function(let name): startOperandIfNeeded(); append(name + "(")
        case .constant(let name): startOperandIfNeeded(); append(name)
        case .answer: startOperandIfNeeded(); append("ans")
        case .toggleSign: toggleSign()
        case .delete: delete()
        case .clear: clear()
        case .equals: equals()
        }
    }

    // MARK: Keypad editing

    private mutating func append(_ text: String) {
        guard input.count + text.count <= Self.maximumInputLength else { return }
        input += text
    }

    /// A digit, function or ( after an answer starts a new calculation.
    private mutating func startOperandIfNeeded() {
        if showsAnswer {
            input = ""
            showsAnswer = false
        }
    }

    /// An operator after an answer continues from it.
    private mutating func continueFromAnswer() {
        guard showsAnswer else { return }
        input = lastAnswer.map { LocalCalculatorFormat.copyText($0, locale: LocalCalculatorFormat.posix) } ?? ""
        showsAnswer = false
    }

    private mutating func appendOperator(_ symbol: String) {
        continueFromAnswer()
        if input.isEmpty {
            // "− 5" starts a negative number; others start from 0 (or the
            // last answer, like a calculator's display).
            if symbol == "−" { input = "−"; return }
            input = lastAnswer.map { LocalCalculatorFormat.copyText($0, locale: LocalCalculatorFormat.posix) } ?? "0"
        }
        // Another operator straight after one replaces it.
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        for existing in ["+", "−", "×", "÷", "mod"] where trimmed.hasSuffix(existing) {
            if trimmed == "−" { return }
            input = String(trimmed.dropLast(existing.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if input.hasSuffix("(") || input.hasSuffix("^") {
            // "(−" and "^−" start a negative operand; nothing else fits.
            if symbol == "−" { append("−") }
            return
        }
        append(" \(symbol) ")
    }

    private mutating func toggleSign() {
        if showsAnswer, let answer = lastAnswer {
            lastAnswer = -answer
            answeredExpression = "−(" + answeredExpression + ")"
            return
        }
        guard let range = Self.lastNumberRange(in: input) else {
            append("−")
            return
        }
        let before = input[..<range.lowerBound]
        if before.hasSuffix("−"), Self.isUnaryPosition(before.dropLast()) {
            input.remove(at: input.index(before: range.lowerBound))
        } else {
            input.insert("−", at: range.lowerBound)
        }
    }

    private mutating func delete() {
        if showsAnswer {
            showsAnswer = false
            input = ""
            return
        }
        if input.hasSuffix(" ") {
            // An operator with its spaces goes in one press.
            input = String(input.trimmingCharacters(in: .whitespaces))
            for symbol in ["mod", "+", "−", "×", "÷"] where input.hasSuffix(symbol) {
                input = String(input.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
                return
            }
            return
        }
        // A function name goes with its (.
        for name in CalculatorLexer.functions.sorted(by: { $0.count > $1.count }) where input.hasSuffix(name + "(") {
            input.removeLast(name.count + 1)
            return
        }
        if input.hasSuffix("ans") { input.removeLast(3); return }
        if !input.isEmpty { input.removeLast() }
    }

    private mutating func clear() {
        input = ""
        showsAnswer = false
        failed = false
    }

    private mutating func equals() {
        if showsAnswer, let step = repeatStep(), let answer = lastAnswer {
            // = again repeats the last step: 2 + 3 = = → 8.
            let expression = LocalCalculatorFormat.copyText(answer, locale: LocalCalculatorFormat.posix) + step
            commit(expression)
            return
        }
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // = straight after an operator reuses the number before it (5 + = → 10).
        var expression = input.trimmingCharacters(in: .whitespaces)
        for symbol in ["+", "−", "×", "÷"] where expression.hasSuffix(symbol) {
            let left = String(expression.dropLast()).trimmingCharacters(in: .whitespaces)
            if let operand = Self.lastNumber(in: left) { expression += " " + operand }
            break
        }
        commit(expression)
    }

    private mutating func commit(_ expression: String) {
        switch CalculatorExpression.evaluate(expression, context: context) {
        case .success(let value):
            lastAnswer = value
            answeredExpression = expression
            showsAnswer = true
            failed = false
            history.append(HistoryEntry(expression: expression, value: value))
            if history.count > Self.maximumHistory { history.removeFirst(history.count - Self.maximumHistory) }
        case .failure:
            failed = true
        }
    }

    /// The last "op operand" of the expression just answered, when it is a
    /// simple chain (2 + 3 → " + 3").
    private func repeatStep() -> String? {
        let expression = answeredExpression
        guard let number = Self.lastNumberRange(in: expression) else { return nil }
        let before = expression[..<number.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let op = ["+", "−", "×", "÷"].first(where: { before.hasSuffix($0) }), before.count > 1,
              expression[number.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return " \(op) " + expression[number]
    }

    /// Puts a history answer (or any value) into the calculation: it
    /// replaces an empty input or an answer, or follows an operator.
    mutating func use(_ value: Decimal) {
        let text = LocalCalculatorFormat.copyText(value, locale: LocalCalculatorFormat.posix)
        if showsAnswer || input.isEmpty {
            input = text
            showsAnswer = false
        } else if let last = input.trimmingCharacters(in: .whitespaces).last, "+−×÷(^".contains(last) {
            append(text)
        } else {
            input = text
        }
        failed = false
    }

    mutating func clearHistory() { history = [] }

    mutating func removeHistory(_ id: HistoryEntry.ID) { history.removeAll { $0.id == id } }

    // MARK: Helpers

    static func symbol(_ operation: LocalCalculator.Operation) -> String {
        switch operation {
        case .add: return "+"
        case .subtract: return "−"
        case .multiply: return "×"
        case .divide: return "÷"
        }
    }

    static func isDigitCharacter(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// A calculation, not a lone number: it has an operator, function,
    /// constant or %.
    static func isCalculation(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespaces)
        let start = body.hasPrefix("−") ? body.dropFirst() : Substring(body)
        return start.contains { !isDigitCharacter($0) && $0 != "." }
    }

    static func lastNumberRange(in text: String) -> Range<String.Index>? {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == " " { end = text.index(before: end) }
        var start = end
        while start > text.startIndex {
            let c = text[text.index(before: start)]
            guard isDigitCharacter(c) || c == "." else { break }
            start = text.index(before: start)
        }
        return start < end ? start..<end : nil
    }

    static func lastNumber(in text: String) -> String? {
        lastNumberRange(in: text).map { String(text[$0]) }
    }

    /// Whether a − after `prefix` is a sign rather than a subtraction.
    static func isUnaryPosition(_ prefix: Substring) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        return "+−×÷(^".contains(last) || trimmed.hasSuffix("mod")
    }
}
