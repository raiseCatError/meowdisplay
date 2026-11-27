// The receiver calculator's expression engine: it reads what the keypad
// builds ("80×5", "2+3×4", "50+10%") and what a person types or writes
// with Apple Pencil in plain English ("what is 20% of 150", "five plus
// three", "square root of 81", "15% off 80"). Foundation only and
// hostless-testable (`CalculatorExpressionTests`). Nothing here can reach
// the Mac.
//
// Semantics:
// - + − × ÷ with the usual precedence; ^ (right associative) above them;
//   unary minus; parentheses (an unclosed one closes at the end, so a
//   half-typed "2×(3+4" already has a value).
// - Implicit multiplication: 2(3+4), 2π, 3sin(30), (1+1)(2+2).
// - % : after + or −, "percent of" the left side (50+10% = 55, 80−25% = 60),
//   elsewhere ÷100 (10% = 0.1, 50×10% = 5). "x% of y", "x% off y" and
//   "x% on y" read as in Soulver.
// - Functions: sin cos tan asin acos atan (degrees or radians), sqrt/√,
//   cbrt, ln, log (base 10), log2, exp, abs, round, floor, ceil, and
//   postfix ! (factorial) and ² ³.
// - Constants π/pi, e, and `ans` (the last result), plus variables a line
//   assigned earlier ("rent = 1200"), and `sum`/`total` (every result
//   since the last blank line), as in Soulver.
// - + − × ÷ ^ ( ) % and plain numbers are exact (`Decimal`, so 0.1+0.2 is
//   0.3); functions and non-integer powers go through `Double`.
// - A trailing "=" or "?" and a leading "what is"/"calculate" are ignored.

import Foundation

enum CalculatorAngleUnit: String, Equatable, Codable, CaseIterable {
    case degrees
    case radians
}

enum CalculatorError: Error, Equatable {
    case empty
    case syntax
    case divisionByZero
    case domain
    case overflow
    case unknownWord(String)
}

struct CalculatorContext: Equatable {
    var angle: CalculatorAngleUnit = .degrees
    /// The last committed result, read by `ans`.
    var answer: Decimal?
    var variables: [String: Decimal] = [:]
    /// Results of the lines above since the last blank one (`sum`, `total`).
    var runningTotal: Decimal?
}

enum CalculatorExpression {
    /// The value of `text`, or why it has none.
    static func evaluate(_ text: String, context: CalculatorContext = CalculatorContext()) -> Result<Decimal, CalculatorError> {
        let names = Set(context.variables.keys)
        let prepared = CalculatorLanguage.normalize(text, variables: names)
        guard !prepared.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.empty) }
        let first = parse(prepared, context: context)
        guard case .failure(.unknownWord) = first, let stripped = withoutLabels(prepared, context: context) else {
            return first
        }
        // Soulver-style labels: "lunch 12 + coffee 4" is 12 + 4.
        let second = parse(stripped, context: context)
        if case .success = second { return second }
        return first
    }

    private static func parse(_ text: String, context: CalculatorContext) -> Result<Decimal, CalculatorError> {
        do {
            let tokens = try CalculatorLexer.tokens(text, variables: Set(context.variables.keys))
            guard !tokens.isEmpty else { return .failure(.empty) }
            var parser = CalculatorParser(tokens: tokens, context: context)
            let value = try parser.parse()
            return .success(try CalculatorNumber.checked(value))
        } catch let error as CalculatorError {
            return .failure(error)
        } catch {
            return .failure(.syntax)
        }
    }

    /// `text` without the words that aren't functions, constants or
    /// variables; nil when that would leave no calculation, or would join
    /// two numbers that a label kept apart ("lunch 12 coffee 4").
    private static func withoutLabels(_ text: String, context: CalculatorContext) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[a-z_][a-z0-9_]*"#) else { return nil }
        let known = CalculatorLexer.functions.union(CalculatorLexer.constants).union(["mod", "x"])
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            if known.contains(word) || context.variables[word] != nil { continue }
            if let before = text[..<range.lowerBound].last, CalculatorLexer.isDigit(before) { continue }
            result.replaceSubrange(range, with: " ")
        }
        guard result != text, result.contains(where: CalculatorLexer.isDigit),
              result.range(of: #"[\d.)]\s+[\d.(]"#, options: .regularExpression) == nil else { return nil }
        return result
    }

    /// The value, or nil when `text` has none (yet).
    static func value(_ text: String, context: CalculatorContext = CalculatorContext()) -> Decimal? {
        try? evaluate(text, context: context).get()
    }

    /// "name = expression", "let name = expression" or "name := expression" (a Soulver-style
    /// variable), when `text` is one. Any name that isn't a function or constant works, x and
    /// single letters included; once x is a variable, multiply with × or * ("2 * x", "2x").
    static func assignment(in text: String) -> (name: String, expression: String)? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.lowercased().hasPrefix("let ") { body = String(body.dropFirst(4)) }
        guard let equals = body.firstIndex(of: "=") else { return nil }
        var name = body[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(":") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
        let rest = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.hasPrefix("="),
              let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !CalculatorLexer.functions.contains(name), !CalculatorLexer.constants.contains(name),
              name != "mod" else { return nil }
        return (name, rest)
    }
}

// MARK: - Numbers

enum CalculatorNumber {
    static let overflowLimit = LocalCalculatorFormat.power(100)
    static let underflowLimit = LocalCalculatorFormat.power(-100)

    static func checked(_ value: Decimal) throws -> Decimal {
        guard !value.isNaN else { throw CalculatorError.domain }
        guard value.magnitude < overflowLimit else { throw CalculatorError.overflow }
        return value.magnitude < underflowLimit ? 0 : value
    }

    static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    /// A `Double` result as a `Decimal`, rounded to 15 significant digits
    /// so sin(30°) is 0.5, not 0.49999999999999994.
    static func decimal(_ value: Double) throws -> Decimal {
        guard value.isFinite else { throw value.isNaN ? CalculatorError.domain : CalculatorError.overflow }
        guard value != 0 else { return 0 }
        let text = String(format: "%.15g", value)
        guard let decimal = Decimal(string: text, locale: LocalCalculatorFormat.posix) else { throw CalculatorError.domain }
        return try checked(decimal)
    }

    static func isInteger(_ value: Decimal) -> Bool {
        LocalCalculatorFormat.rounded(value, scale: 0) == value
    }
}

// MARK: - Natural language

/// Turns plain English into the symbols the parser reads. Word numbers
/// ("twenty five", "a dozen") become digits; phrases become operators.
enum CalculatorLanguage {
    static func normalize(_ text: String, variables: Set<String> = []) -> String {
        var s = " " + text.lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{00D7}", with: "*")
            .replacingOccurrences(of: "\u{00F7}", with: "/")
            .replacingOccurrences(of: "\u{2215}", with: "/")
            .replacingOccurrences(of: "\u{2217}", with: "*")
            .replacingOccurrences(of: "\u{22C5}", with: "*")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\n", with: " ") + " "
        // A defined name means itself: "one = 5" then "one + 1" is 6, so
        // names sit out the word rewriting below behind placeholders.
        let protected = variables.sorted { $0.count > $1.count }
        for (index, name) in protected.enumerated() {
            s = s.replacingOccurrences(of: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: name)
                                        + #"(?![\p{L}\p{N}_])"#,
                                       with: " " + placeholder(index) + " ", options: .regularExpression)
        }
        // Thousands separators inside numbers ("1,200" → 1200); a comma
        // elsewhere is a pause, like "and".
        while let grouped = s.range(of: #"(?<![\d.])\d{1,3}(?:,\d{3})+(?![\d,])"#, options: .regularExpression) {
            s.replaceSubrange(grouped, with: s[grouped].replacingOccurrences(of: ",", with: ""))
        }
        // Any other comma is a pause between words ("five, plus three").
        s = s.replacingOccurrences(of: ",", with: " , ")
        s = s.replacingOccurrences(of: "$", with: " ")
        s = s.replacingOccurrences(of: "€", with: " ")
        s = s.replacingOccurrences(of: "£", with: " ")
        // A trailing "=", "?" or "." asks for the answer.
        while let last = s.trimmingCharacters(in: .whitespaces).last, "=?.!".contains(last) {
            // Keep a factorial "!" after a digit or ")".
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if last == "!", let before = trimmed.dropLast().last, before.isNumber || ")%²³!".contains(before) { break }
            // …and after a constant or a defined name ("ans!", "n!", "π!", which the parser rejects).
            let head = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
            if last == "!", let word = head.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last,
               isProtectedPlaceholder(String(word)) || ["ans", "pi", "π", "e", "tau", "τ"].contains(String(word)),
               head.hasSuffix(word) { break }
            if last == ".", let before = trimmed.dropLast().last, before.isNumber { break }
            s = " " + String(trimmed.dropLast()) + " "
        }
        s = replaceNumberWords(s)
        for (pattern, replacement) in phrases {
            // x is a variable here: it no longer means times.
            if variables.contains("x"), pattern.contains(#"\s*x\s*"#) { continue }
            s = s.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression])
        }
        for (index, name) in protected.enumerated() {
            s = s.replacingOccurrences(of: placeholder(index), with: " \(name) ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func isProtectedPlaceholder(_ word: String) -> Bool {
        word.hasPrefix("qzqv") && word.hasSuffix("qzq") && word.count > 7
    }

    /// Letters no phrase or number word matches, unique per index.
    private static func placeholder(_ index: Int) -> String {
        var n = index, letters = ""
        repeat {
            letters.append(Character(UnicodeScalar(UInt8(97 + n % 26))))
            n /= 26
        } while n > 0
        return "qzqv" + letters + "qzq"
    }

    /// Ordered: longer phrases first. Patterns are matched on the
    /// lowercased text, padded with spaces.
    private static let phrases: [(String, String)] = [
        (#"\b(what is|what's|whats|how much is|how much|calculate|compute|evaluate|work out|tell me|please|equals|is equal to|is|are|about|approximately)\b"#, " "),
        // Percentages.
        (#"(\d+(?:\.\d+)?)\s*(?:%|percent|per cent|pc)\s+off\s+"#, " (100-$1)% of "),
        (#"(\d+(?:\.\d+)?)\s*(?:%|percent|per cent|pc)\s+(?:on|on top of|plus)\s+([\d.]+)"#, " $2+$1% "),
        (#"\b(percent|per cent)\s+of\b"#, " % of "),
        (#"\b(percent|per cent)\b"#, " % "),
        (#"%\s*of\b"#, " %* "),
        // Words that take an argument.
        (#"\b(square root|sqrt)\s+of\b"#, " sqrt "),
        (#"\bsquare root\b"#, " sqrt "),
        (#"\bcube root\s+of\b"#, " cbrt "),
        (#"\bcube root\b"#, " cbrt "),
        (#"\babsolute value\s+of\b"#, " abs "),
        (#"\b(natural log|natural logarithm)\s+of\b"#, " ln "),
        (#"\b(log|logarithm)\s+of\b"#, " log "),
        (#"\b(sine|sin)\s+of\b"#, " sin "),
        (#"\b(cosine|cos)\s+of\b"#, " cos "),
        (#"\b(tangent|tan)\s+of\b"#, " tan "),
        (#"\bsine\b"#, " sin "),
        (#"\bcosine\b"#, " cos "),
        (#"\btangent\b"#, " tan "),
        (#"\bfactorial\s+of\b"#, " fact "),
        (#"\bhalf\s+of\b"#, " 0.5* "),
        (#"\b(a\s+)?quarter\s+of\b"#, " 0.25* "),
        (#"\b(a\s+)?third\s+of\b"#, " (1/3)* "),
        (#"\b(double|twice)\b"#, " 2* "),
        (#"\btriple\b"#, " 3* "),
        (#"\bhalf\b"#, " 0.5 "),
        // Binary phrases.
        (#"\bsum\s+of\s+(.+?)\s+and\s+"#, " $1 + "),
        (#"\bproduct\s+of\s+(.+?)\s+and\s+"#, " ($1) * "),
        (#"\bdifference\s+between\s+(.+?)\s+and\s+"#, " $1 - "),
        (#"\bquotient\s+of\s+(.+?)\s+and\s+"#, " ($1) / "),
        (#"\b(raised\s+)?to\s+the\s+power\s+of\b"#, " ^ "),
        (#"\b(raised\s+)?to\s+the\s+(\d+)(st|nd|rd|th)(\s+power)?\b"#, " ^ $2 "),
        (#"\bto\s+the\s+power\b"#, " ^ "),
        (#"\bpower\s+of\b"#, " ^ "),
        (#"\bsquared\b"#, " ^2 "),
        (#"\bcubed\b"#, " ^3 "),
        (#"\b(multiplied\s+by|times|multiply\s+by|multiply)\b"#, " * "),
        (#"\b(divided\s+by|divide\s+by|over|divided)\b"#, " / "),
        (#"\b(plus|add|added\s+to|and)\b"#, " + "),
        (#"\b(minus|subtract|less|take\s+away|take)\b"#, " - "),
        (#"\bmod(ulo)?\b"#, " mod "),
        (#"\bpi\b"#, " π "),
        (#"(\d)\s*x\s*(?=[\d(.π])"#, "$1*"),
        (#"\bthe\b"#, " "),
        (#"\bby\b"#, " "),
        (#"\bof\b"#, " * "),
    ]

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90, "dozen": 12,
    ]
    /// Spelled-out numbers stop here; larger ones are an overflow.
    static let wordNumberLimit = 1_000_000_000_000_000

    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000,
                                                "billion": 1_000_000_000]

    /// "two hundred and five" → 205, "3 million" → 3000000, "a dozen" → 12.
    static func replaceNumberWords(_ text: String) -> String {
        // "twenty-five": a hyphen between words; "2e-3" and "10-3" keep theirs.
        let words = text.replacingOccurrences(of: #"([a-z])-([a-z])"#, with: "$1 - $2", options: .regularExpression)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var output: [String] = []
        var index = 0
        while index < words.count {
            var total = 0
            var current = 0
            var consumed = 0
            var sawNumber = false
            var articled = false
            var tooBig = false
            var cursor = index
            while cursor < words.count {
                let word = words[cursor]
                if word == "a", !sawNumber, cursor + 1 < words.count,
                   words[cursor + 1] == "dozen" || scales[words[cursor + 1]] != nil {
                    // "a dozen", "a hundred"
                    articled = true
                    cursor += 1
                    continue
                }
                if let value = units[word] {
                    current += value
                    sawNumber = true
                } else if let scale = scales[word], sawNumber || articled {
                    // Checked: "hundred hundred hundred …" must not overflow Int.
                    let (product, overflow) = max(current, 1).multipliedReportingOverflow(by: scale)
                    guard !overflow, product < Self.wordNumberLimit, total < Self.wordNumberLimit else {
                        tooBig = true
                        cursor = words.count
                        break
                    }
                    current = product
                    sawNumber = true
                    if scale >= 1_000 { total += current; current = 0 }
                } else if word == "and", sawNumber, cursor + 1 < words.count, units[words[cursor + 1]] != nil,
                          current >= 100 || total > 0 {
                    // "two hundred and five": "and" joins the number.
                } else if word == "-", sawNumber, cursor + 1 < words.count, let next = units[words[cursor + 1]],
                          next < 10, current % 10 == 0, current >= 20 {
                    // "twenty-five"
                } else {
                    break
                }
                cursor += 1
                consumed = cursor - index
            }
            if tooBig {
                // Out of range: an overflow, like any too-large result.
                output.append("10^400")
                index = words.count
                continue
            }
            if sawNumber, consumed > 0 {
                output.append(String(total + current))
                index += consumed
                continue
            }
            // A digit number followed by a scale word: "3 million", "1.5 thousand".
            if Decimal(string: words[index], locale: LocalCalculatorFormat.posix) != nil,
               words[index].allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
               index + 1 < words.count, let scale = scales[words[index + 1]] {
                output.append("(" + words[index] + "*" + String(scale) + ")")
                index += 2
                continue
            }
            output.append(words[index])
            index += 1
        }
        return " " + output.joined(separator: " ").replacingOccurrences(of: " - ", with: " -") + " "
    }
}

// MARK: - Lexer

enum CalculatorToken: Equatable {
    case number(Decimal)
    case identifier(String)
    case plus, minus, times, divide, power, percent, factorial, modulo
    /// ² and ³: postfix, so 2²^3 is (2²)^3 and 3²! is (3²)!.
    case square, cube
    case open, close
    case comma
}

enum CalculatorLexer {
    static let functions: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan",
                                         "sqrt", "cbrt", "ln", "log", "log2", "log10", "exp", "abs", "round",
                                         "floor", "ceil", "fact", "sinh", "cosh", "tanh"]
    static let constants: Set<String> = ["pi", "π", "e", "ans", "sum", "total", "tau", "τ"]
    static var reservedWords: Set<String> { functions.union(constants).union(["mod", "x"]) }

    static func tokens(_ text: String, variables: Set<String> = []) throws -> [CalculatorToken] {
        var tokens: [CalculatorToken] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { index += 1; continue }
            if Self.isDigit(c) || (c == "." && index + 1 < characters.count && Self.isDigit(characters[index + 1])) {
                var end = index
                var sawPoint = false
                while end < characters.count, Self.isDigit(characters[end]) || (characters[end] == "." && !sawPoint) {
                    if characters[end] == "." { sawPoint = true }
                    end += 1
                }
                // Scientific notation: 1.5e10, 2E-3.
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var look = end + 1
                    if look < characters.count, characters[look] == "-" || characters[look] == "+" { look += 1 }
                    if look < characters.count, Self.isDigit(characters[look]) {
                        end = look
                        while end < characters.count, Self.isDigit(characters[end]) { end += 1 }
                    }
                }
                let literal = String(characters[index..<end]).replacingOccurrences(of: "E", with: "e")
                guard let value = Decimal(string: literal.hasSuffix(".") ? literal + "0" : literal,
                                          locale: LocalCalculatorFormat.posix) else { throw CalculatorError.syntax }
                tokens.append(.number(value))
                index = end
                continue
            }
            if c == "²" || c == "³" {
                tokens.append(c == "²" ? .square : .cube)
                index += 1
                continue
            }
            if c.isLetter || c == "π" || c == "τ" || c == "√" || c == "∛" {
                if c == "√" { tokens.append(.identifier("sqrt")); index += 1; continue }
                if c == "∛" { tokens.append(.identifier("cbrt")); index += 1; continue }
                if c == "π" || c == "τ" { tokens.append(.identifier(String(c))); index += 1; continue }
                var end = index
                while end < characters.count,
                      characters[end].isLetter || Self.isDigit(characters[end]) || characters[end] == "_" {
                    end += 1
                }
                var word = String(characters[index..<end])
                // A defined name is itself, whatever it looks like ("x2", "ans1").
                if variables.contains(word) {
                    tokens.append(.identifier(word))
                    index = end
                    continue
                }
                // "log2" is a function; "x2" is multiply by 2.
                if !variables.contains("x"),
                   word == "x" || (word.hasPrefix("x") && word.dropFirst().allSatisfy(\.isNumber)) {
                    tokens.append(.times)
                    index += 1
                    continue
                }
                // A known word glued to digits or another known word:
                // "sin30", "pie" stays unknown.
                let known = functions.union(constants)
                if !known.contains(word), word != "mod" {
                    if let prefix = known.sorted(by: { $0.count > $1.count }).first(where: { prefix in
                        guard word.hasPrefix(prefix), word.count > prefix.count else { return false }
                        let rest = String(word.dropFirst(prefix.count))
                        return rest.allSatisfy(Self.isDigit) || known.contains(rest)
                    }) {
                        word = prefix
                        end = index + prefix.count
                    }
                }
                if word == "mod" {
                    tokens.append(.modulo)
                } else {
                    tokens.append(.identifier(word))
                }
                index = end
                continue
            }
            switch c {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*", "·": tokens.append(.times)
            case "/": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "%": tokens.append(.percent)
            case "!": tokens.append(.factorial)
            case "(", "[", "{": tokens.append(.open)
            case ")", "]", "}": tokens.append(.close)
            case ",": tokens.append(.comma)
            case "'", "\"", ":", ";": break
            default: throw CalculatorError.syntax
            }
            index += 1
        }
        // Commas left over from prose ("5, plus 3") are pauses.
        return tokens.filter { $0 != .comma }
    }

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}

// MARK: - Parser

/// Precedence climbing over the tokens, evaluating as it goes.
struct CalculatorParser {
    private let tokens: [CalculatorToken]
    private let context: CalculatorContext
    private var index = 0
    /// Nesting so far: pasted notes can hold anything, and each group,
    /// sign and exponent recurses.
    private var depth = 0
    static let maximumDepth = 120
    /// Whether the term just parsed multiplied, divided or took a modulo,
    /// written or implied (2π%), so a trailing % is that term's own.
    private var termCombined = false
    /// Whether the factor just parsed ended in its own % ("10%"), not one
    /// inside an exponent ("2^10%") or a group ("(10%)").
    private var factorEndedWithPercent = false

    init(tokens: [CalculatorToken], context: CalculatorContext) {
        self.tokens = tokens
        self.context = context
    }

    mutating func parse() throws -> Decimal {
        let value = try expression()
        // Unclosed parentheses close at the end; anything else left over
        // is an error.
        while index < tokens.count, tokens[index] == .close { index += 1 }
        guard index == tokens.count else { throw CalculatorError.syntax }
        return value
    }

    private var current: CalculatorToken? { index < tokens.count ? tokens[index] : nil }

    /// + and −, with "percent of the left side" for a trailing %.
    private mutating func nest() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw CalculatorError.syntax }
    }

    private mutating func expression() throws -> Decimal {
        try nest()
        defer { depth -= 1 }
        var value = try term()
        while let token = current, token == .plus || token == .minus {
            index += 1
            let (rhs, isPercent) = try termNotingPercent()
            let operand = isPercent ? value * rhs / 100 : rhs
            value = try CalculatorNumber.checked(token == .plus ? value + operand : value - operand)
        }
        return value
    }

    /// A term, and whether it was just "n%" (so + and − take a percent of
    /// their left side).
    private mutating func termNotingPercent() throws -> (Decimal, Bool) {
        let start = index
        let value = try term()
        let consumed = Array(tokens[start..<index])
        if consumed.last == .percent, factorEndedWithPercent, !termCombined {
            // Undo the ÷100 the factor applied; the caller scales instead.
            return (value * 100, true)
        }
        return (value, false)
    }

    /// × ÷ mod, and implicit multiplication.
    private mutating func term() throws -> Decimal {
        var value = try unary()
        var combined = false
        defer { termCombined = combined }
        while let token = current {
            switch token {
            case .times, .divide, .modulo, .identifier, .open: combined = true
            default: break
            }
            switch token {
            case .times:
                index += 1
                value = try CalculatorNumber.checked(value * (try unary()))
            case .divide:
                index += 1
                let rhs = try unary()
                guard rhs != 0 else { throw CalculatorError.divisionByZero }
                value = try CalculatorNumber.checked(value / rhs)
            case .modulo:
                index += 1
                let rhs = try unary()
                guard rhs != 0 else { throw CalculatorError.divisionByZero }
                let quotient = LocalCalculatorFormat.rounded(value / rhs, scale: 0, mode: .down)
                value = try CalculatorNumber.checked(value - quotient * rhs)
            case .identifier, .open:
                // 2(3), 2π, (1)(2), 3 sin 30
                value = try CalculatorNumber.checked(value * (try power()))
            case .number:
                // Two numbers side by side ("2.3.4", "12 4") are a typo,
                // not a product.
                throw CalculatorError.syntax
            default:
                return value
            }
        }
        return value
    }

    private mutating func unary() throws -> Decimal {
        try nest()
        defer { depth -= 1 }
        if current == .minus { index += 1; return -(try unary()) }
        if current == .plus { index += 1; return try unary() }
        return try power()
    }

    /// ^ is right associative and binds tighter than unary minus on its
    /// left (−2^2 = −4) but takes a signed exponent (2^−1 = 0.5).
    private mutating func power() throws -> Decimal {
        let base = try postfix()
        guard current == .power else { return base }
        index += 1
        let exponent = try unary()
        factorEndedWithPercent = false
        return try Self.raise(base, exponent)
    }

    private mutating func postfix() throws -> Decimal {
        var value = try primary()
        var percent = false
        defer { factorEndedWithPercent = percent }
        while let token = current {
            if token == .percent {
                index += 1
                value /= 100
                percent = true
            } else if token == .factorial {
                index += 1
                value = try Self.factorial(value)
                percent = false
            } else if token == .square || token == .cube {
                index += 1
                value = try Self.raise(value, token == .square ? 2 : 3)
                percent = false
            } else {
                break
            }
        }
        return value
    }

    private mutating func primary() throws -> Decimal {
        guard let token = current else { throw CalculatorError.syntax }
        switch token {
        case .number(let value):
            index += 1
            return value
        case .open:
            index += 1
            let value = try expression()
            if current == .close { index += 1 } else if current != nil { throw CalculatorError.syntax }
            return value
        case .identifier(let name):
            index += 1
            if CalculatorLexer.functions.contains(name) {
                // A function takes a parenthesised argument or the next
                // factor ("sqrt 81", "sin 30", "√2").
                let argument: Decimal
                if current == .open {
                    index += 1
                    argument = try expression()
                    if current == .close { index += 1 }
                } else {
                    argument = try unaryArgument()
                }
                return try apply(name, argument)
            }
            return try constant(name)
        default:
            throw CalculatorError.syntax
        }
    }

    /// The argument of "sqrt 2^2" is 2^2; of "sin −30", −30.
    private mutating func unaryArgument() throws -> Decimal {
        try nest()
        defer { depth -= 1 }
        if current == .minus { index += 1; return -(try unaryArgument()) }
        return try power()
    }

    private func constant(_ name: String) throws -> Decimal {
        switch name {
        case "pi", "π": return Self.pi
        case "tau", "τ": return Self.pi * 2
        case "e": return Self.e
        case "ans": return context.answer ?? 0
        case "sum", "total": return context.runningTotal ?? 0
        default:
            if let value = context.variables[name] { return value }
            throw CalculatorError.unknownWord(name)
        }
    }

    static let pi = Decimal(string: "3.14159265358979323846264338327950288", locale: LocalCalculatorFormat.posix)!
    static let e = Decimal(string: "2.71828182845904523536028747135266250", locale: LocalCalculatorFormat.posix)!

    private func apply(_ name: String, _ argument: Decimal) throws -> Decimal {
        let x = CalculatorNumber.double(argument)
        let toRadians = context.angle == .degrees ? Double.pi / 180 : 1
        let fromRadians = context.angle == .degrees ? 180 / Double.pi : 1
        switch name {
        case "sin":
            // Exact zeros at multiples of 180° (sin 180 is 0, not 1.2e-16).
            if context.angle == .degrees, CalculatorNumber.isInteger(argument / 180) { return 0 }
            return try CalculatorNumber.decimal(sin(x * toRadians))
        case "cos":
            if context.angle == .degrees, CalculatorNumber.isInteger((argument - 90) / 180) { return 0 }
            return try CalculatorNumber.decimal(cos(x * toRadians))
        case "tan":
            if context.angle == .degrees, CalculatorNumber.isInteger((argument - 90) / 180) { throw CalculatorError.domain }
            if context.angle == .degrees, CalculatorNumber.isInteger(argument / 180) { return 0 }
            return try CalculatorNumber.decimal(tan(x * toRadians))
        case "asin", "arcsin":
            guard abs(x) <= 1 else { throw CalculatorError.domain }
            return try CalculatorNumber.decimal(asin(x) * fromRadians)
        case "acos", "arccos":
            guard abs(x) <= 1 else { throw CalculatorError.domain }
            return try CalculatorNumber.decimal(acos(x) * fromRadians)
        case "atan", "arctan": return try CalculatorNumber.decimal(atan(x) * fromRadians)
        case "sinh": return try CalculatorNumber.decimal(sinh(x))
        case "cosh": return try CalculatorNumber.decimal(cosh(x))
        case "tanh": return try CalculatorNumber.decimal(tanh(x))
        case "sqrt":
            guard argument >= 0 else { throw CalculatorError.domain }
            return try Self.squareRoot(argument)
        case "cbrt": return try CalculatorNumber.decimal(cbrt(x))
        case "ln":
            guard argument > 0 else { throw CalculatorError.domain }
            return try CalculatorNumber.decimal(log(x))
        case "log", "log10":
            guard argument > 0 else { throw CalculatorError.domain }
            return try CalculatorNumber.decimal(log10(x))
        case "log2":
            guard argument > 0 else { throw CalculatorError.domain }
            return try CalculatorNumber.decimal(log2(x))
        case "exp": return try CalculatorNumber.decimal(exp(x))
        case "abs": return argument.magnitude
        case "round": return LocalCalculatorFormat.rounded(argument, scale: 0)
        case "floor": return LocalCalculatorFormat.rounded(argument, scale: 0, mode: .down)
        case "ceil": return LocalCalculatorFormat.rounded(argument, scale: 0, mode: .up)
        case "fact": return try Self.factorial(argument)
        default: throw CalculatorError.unknownWord(name)
        }
    }

    /// Exact when the root is (√81 = 9, √2.25 = 1.5), otherwise 15 digits.
    private static func squareRoot(_ value: Decimal) throws -> Decimal {
        let approximate = try CalculatorNumber.decimal(sqrt(CalculatorNumber.double(value)))
        for scale in 0...8 {
            let candidate = LocalCalculatorFormat.rounded(approximate, scale: scale)
            if candidate * candidate == value { return candidate }
        }
        return approximate
    }

    static func raise(_ base: Decimal, _ exponent: Decimal) throws -> Decimal {
        if CalculatorNumber.isInteger(exponent), exponent.magnitude <= 400 {
            let count = NSDecimalNumber(decimal: exponent.magnitude).intValue
            if exponent < 0, base == 0 { throw CalculatorError.divisionByZero }
            var result: Decimal = 1
            var overflowed = false
            for _ in 0..<count {
                result *= base
                if result.magnitude >= CalculatorNumber.overflowLimit { overflowed = true; break }
            }
            if exponent < 0 {
                if overflowed {
                    // 10^−100: the positive power is out of range but its
                    // reciprocal isn't, so multiply the reciprocal instead.
                    let reciprocal = 1 / base
                    result = 1
                    for _ in 0..<count { result *= reciprocal }
                } else {
                    result = 1 / result
                }
            } else if overflowed {
                throw CalculatorError.overflow
            }
            return try CalculatorNumber.checked(result)
        }
        let x = CalculatorNumber.double(base)
        guard x >= 0 else { throw CalculatorError.domain }
        return try CalculatorNumber.decimal(pow(x, CalculatorNumber.double(exponent)))
    }

    static func factorial(_ value: Decimal) throws -> Decimal {
        guard value >= 0, CalculatorNumber.isInteger(value) else { throw CalculatorError.domain }
        // Compared as a Decimal first: a huge operand would wrap as an Int.
        guard value <= 69 else { throw CalculatorError.overflow }
        let n = NSDecimalNumber(decimal: value).intValue
        var result: Decimal = 1
        if n > 1 { for k in 2...n { result *= Decimal(k) } }
        return result
    }
}

extension LocalCalculatorFormat {
    static func rounded(_ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }
}

// MARK: - Notes (Soulver-style lines)

/// One line of the calculator's notes and its answer.
struct CalculatorLineResult: Equatable {
    /// nil for a blank line, a heading, or text with no calculation.
    var value: Decimal?
    /// The variable this line assigns, if any.
    var assigns: String?
    /// An answer that isn't just a number ("8:00 PM BST", "3.1 mi"), drawn as is.
    var text: String?

    var hasAnswer: Bool { value != nil || text != nil }
}

enum CalculatorSheet {
    /// Every line's answer, in order. Lines see the variables assigned
    /// above them, `ans` is the line above's answer, and `sum`/`total` add
    /// up the answers since the last blank line. Everyday questions (time
    /// zones, dates, units, bases) are answered first (`CalculatorSmartAnswers`).
    static func evaluate(lines: [String], angle: CalculatorAngleUnit,
                         smart: CalculatorSmartContext = CalculatorSmartContext()) -> [CalculatorLineResult] {
        var context = CalculatorContext(angle: angle)
        var results: [CalculatorLineResult] = []
        var running: Decimal?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                running = nil
                results.append(CalculatorLineResult(value: nil))
                continue
            }
            context.runningTotal = running
            var assigns: String?
            var source = trimmed
            if let assignment = CalculatorExpression.assignment(in: trimmed) {
                assigns = assignment.name
                source = assignment.expression
            }
            func record(_ value: Decimal) {
                if let assigns { context.variables[assigns] = value }
                context.answer = value
                // A line that reads the running total isn't added to it;
                // "subtotal" and other names that merely contain the word are.
                if source.lowercased().range(of: #"\b(sum|total)\b"#, options: .regularExpression) == nil {
                    running = (running ?? 0) + value
                }
            }
            if let answer = CalculatorSmartAnswers.answer(source, context: smart) {
                if let value = answer.value { record(value) }
                results.append(CalculatorLineResult(value: answer.value, assigns: assigns, text: answer.text))
                continue
            }
            if let value = CalculatorExpression.value(source, context: context), assigns != nil || !isPlainLabel(source) {
                record(value)
                results.append(CalculatorLineResult(value: value, assigns: assigns))
            } else {
                results.append(CalculatorLineResult(value: nil, assigns: nil))
            }
        }
        return results
    }

    /// A line that is just a number ("2026", "42") reads as a note, not a
    /// calculation worth answering, unless it's assigned.
    static func isPlainLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return Decimal(string: trimmed, locale: LocalCalculatorFormat.posix) != nil
            && trimmed.allSatisfy { $0.isNumber || $0 == "." }
    }
}
