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
    /// The expression the shown answer came from, as shown.
    private(set) var answeredExpression = ""
    /// The same, evaluable later (the answer token replaced by the exact
    /// previous answer), for repeated =.
    private(set) var answeredSource = ""
    /// What = again repeats, resolved when the answer was committed: the
    /// operator and its operand, a contextual percentage as its amount
    /// (50 + 10% = = adds 5 again, not 10% of 55).
    private(set) var repeatOperation: String?
    private(set) var repeatOperand: String?
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
        if failed {
            // After Error a new number starts a new calculation; ⌫ still
            // edits the failed one and an operator continues it.
            switch key {
            case .digit, .decimalPoint, .open, .function, .constant, .answer: input = ""
            default: break
            }
        }
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
        case .answer:
            startOperandIfNeeded()
            // After a number, Ans multiplies it, written out so it reads (and repeats) that way.
            if let last = input.last, Self.isDigitCharacter(last) || last == ")" || last == "%" || last.isLetter || last == "π" {
                append(" × ")
            }
            append("ans")
        case .toggleSign: toggleSign()
        case .delete: delete()
        case .clear: clear()
        case .equals: equals()
        }
    }

    // MARK: Keypad editing

    /// The token that stands for the last answer, exactly (not a rounded
    /// copy), so 3 ÷ 7 = × 7 = is 3 and a committed −2 squares to 4.
    static let answerToken = "ans"

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

    /// An operator after an answer continues from it, exactly.
    private mutating func continueFromAnswer() {
        guard showsAnswer else { return }
        input = lastAnswer == nil ? "" : Self.answerToken
        showsAnswer = false
    }

    private mutating func appendOperator(_ symbol: String) {
        continueFromAnswer()
        if input.isEmpty {
            // "− 5" starts a negative number; others start from 0. After
            // AC the last answer is only reachable through Ans.
            if symbol == "−" { input = "−"; return }
            input = "0"
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
        if showsAnswer {
            continueFromAnswer()
            input = "−" + input
            return
        }
        // The answer token and a parenthesised group flip as a whole.
        if input.hasSuffix("(−\(Self.answerToken))") {
            input.removeLast(Self.answerToken.count + 3)
            input += Self.answerToken
            return
        }
        if input.hasSuffix(Self.answerToken) {
            input.removeLast(Self.answerToken.count)
            input += "(−\(Self.answerToken))"
            return
        }
        guard let range = Self.lastOperandRange(in: input) else {
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
        if input.hasSuffix(Self.answerToken) { input.removeLast(Self.answerToken.count); return }
        if !input.isEmpty { input.removeLast() }
    }

    /// AC: a fresh calculation. The history and Ans stay.
    private mutating func clear() {
        input = ""
        showsAnswer = false
        failed = false
    }

    private mutating func equals() {
        if showsAnswer, lastAnswer != nil {
            // = again repeats the last step: 2 + 3 = = → 8, 5 − −3 = = → 11. With no step
            // (2 = Ans² =) the answer stays as it is.
            if let operation = repeatOperation, let operand = repeatOperand {
                commit(Self.answerToken + " " + operation + " " + operand)
            }
            return
        }
        var expression = input.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty else { return }
        // = straight after an operator reuses the term before it, sign and
        // all (5 + = → 10, −5 × = → 25).
        for symbol in ["+", "−", "×", "÷"] where expression.hasSuffix(symbol) && expression != "−" {
            let left = String(expression.dropLast()).trimmingCharacters(in: .whitespaces)
            let operand = Self.lastStep(in: left)?.operand ?? left
            if !operand.isEmpty { expression += " " + operand }
            break
        }
        commit(expression)
    }

    private mutating func commit(_ expression: String) {
        switch CalculatorExpression.evaluate(expression, context: context) {
        case .success(let value):
            answeredSource = expanded(expression)
            let step = Self.splitLastStep(in: answeredSource)
            repeatOperation = step?.operation
            repeatOperand = step.map { step in
                guard ["+", "−"].contains(step.operation), step.operand.hasSuffix("%"),
                      let left = CalculatorExpression.value(step.left, context: context),
                      let percent = CalculatorExpression.value(step.operand, context: context) else { return step.operand }
                let amount = left * percent
                return amount < 0 ? "(" + amount.description + ")" : amount.description
            }
            answeredExpression = displayed(expression, locale: Locale.current)
            lastAnswer = value
            showsAnswer = true
            failed = false
            history.append(HistoryEntry(expression: answeredExpression, value: value))
            if history.count > Self.maximumHistory { history.removeFirst(history.count - Self.maximumHistory) }
        case .failure:
            failed = true
        }
    }

    /// The last binary operator at the top level of `expression` and the
    /// term after it, as typed ("2 + 3 × −4" → "×", "−4").
    static func lastStep(in expression: String) -> (operation: String, operand: String)? {
        splitLastStep(in: expression).map { ($0.operation, $0.operand) }
    }

    /// `lastStep`, with what comes before the operator.
    static func splitLastStep(in expression: String) -> (left: String, operation: String, operand: String)? {
        var depth = 0
        var best: (operation: String, range: Range<String.Index>)?
        var index = expression.startIndex
        while index < expression.endIndex {
            let c = expression[index]
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if depth == 0 {
                for op in [" + ", " − ", " × ", " ÷ ", " mod "] where expression[index...].hasPrefix(op) {
                    let end = expression.index(index, offsetBy: op.count)
                    best = (op.trimmingCharacters(in: .whitespaces), index..<end)
                }
            }
            index = expression.index(after: index)
        }
        guard let best else { return nil }
        let operand = expression[best.range.upperBound...].trimmingCharacters(in: .whitespaces)
        let left = expression[..<best.range.lowerBound].trimmingCharacters(in: .whitespaces)
        return operand.isEmpty ? nil : (left, best.operation, operand)
    }

    /// `expression` with the answer token replaced by the exact answer, so
    /// it means the same after the next answer replaces this one.
    private func expanded(_ expression: String) -> String {
        guard let answer = lastAnswer else { return expression }
        return Self.replacingAnswerToken(in: expression, with: "(" + answer.description + ")")
    }

    /// `expression` as shown: the answer token as its number.
    func displayed(_ expression: String, locale: Locale) -> String {
        guard let answer = lastAnswer, expression.contains(Self.answerToken) else { return expression }
        let text = LocalCalculatorFormat.display(answer, locale: locale).text
        return Self.replacingAnswerToken(in: expression, with: answer < 0 ? "(" + text + ")" : text)
    }

    /// The input as shown.
    func displayInput(locale: Locale) -> String { displayed(input, locale: locale) }

    static func replacingAnswerToken(in expression: String, with replacement: String) -> String {
        expression.replacingOccurrences(of: #"(?<![A-Za-z_])ans(?![A-Za-z0-9_])"#, with: NSRegularExpression.escapedTemplate(for: replacement),
                                        options: .regularExpression)
    }

    /// Puts a history answer (or any value) into the calculation: it
    /// replaces an empty input or an answer, or follows an operator. A
    /// negative value goes in parentheses, so squaring it squares it.
    mutating func use(_ value: Decimal) {
        // Always the exact value: the display rounds, the calculation doesn't.
        let digits = value.magnitude.description
        let text = value < 0 ? "(−" + digits + ")" : digits
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

    /// The operand the calculation ends with: a number, a constant or
    /// name, or a whole bracketed group with its function ("sin(30)"), so ±
    /// flips it instead of starting a subtraction.
    static func lastOperandRange(in text: String) -> Range<String.Index>? {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == " " { end = text.index(before: end) }
        // Postfix operators stay with their operand: ± on 5² makes −5².
        while end > text.startIndex, "%²³!".contains(text[text.index(before: end)]) { end = text.index(before: end) }
        let operandEnd = text.endIndex
        guard end > text.startIndex else { return nil }
        let last = text[text.index(before: end)]
        var start = end
        func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c == "π" || c == "τ" }
        if last == ")" {
            var depth = 0
            while start > text.startIndex {
                start = text.index(before: start)
                if text[start] == ")" { depth += 1 } else if text[start] == "(" { depth -= 1 }
                if depth == 0 { break }
            }
            guard depth == 0, text[start] == "(" else { return nil }
            while start > text.startIndex, isNameCharacter(text[text.index(before: start)]) { start = text.index(before: start) }
            return start..<operandEnd
        }
        if isNameCharacter(last) {
            while start > text.startIndex, isNameCharacter(text[text.index(before: start)]) { start = text.index(before: start) }
            return start..<operandEnd
        }
        while start > text.startIndex, isDigitCharacter(text[text.index(before: start)]) || text[text.index(before: start)] == "." {
            start = text.index(before: start)
        }
        return start < end ? start..<operandEnd : nil
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
