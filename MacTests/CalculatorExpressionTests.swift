import XCTest

/// The receiver calculator's expression engine, its plain-English reading,
/// the notes sheet and the keypad (`CalculatorExpression`,
/// `CalculatorSheet`, `CalculatorKeypad`).
final class CalculatorExpressionTests: XCTestCase {
    private func value(_ text: String, angle: CalculatorAngleUnit = .degrees, answer: Decimal? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> Decimal? {
        CalculatorExpression.value(text, context: CalculatorContext(angle: angle, answer: answer))
    }

    private func assertValue(_ text: String, _ expected: String, angle: CalculatorAngleUnit = .degrees,
                             file: StaticString = #filePath, line: UInt = #line) {
        let got = value(text, angle: angle)
        XCTAssertEqual(got, Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")),
                       "\(text) → \(String(describing: got))", file: file, line: line)
    }

    // MARK: Arithmetic

    func testArithmeticIsExactWithPrecedence() {
        assertValue("80×5", "400")
        assertValue("80 x 5", "400")
        assertValue("80x5", "400")
        assertValue("0.1 + 0.2", "0.3")
        assertValue("2 + 3 × 4", "14")
        assertValue("(2 + 3) × 4", "20")
        assertValue("10 ÷ 4", "2.5")
        assertValue("10 − 4 − 3", "3")
        assertValue("−2^2", "-4")
        assertValue("2^−1", "0.5")
        assertValue("2^3^2", "512")
        assertValue("5²", "25")
        assertValue("5!", "120")
        assertValue("17 mod 5", "2")
    }

    func testUnclosedParenthesesAndImplicitMultiplication() {
        assertValue("2×(3+4", "14")
        assertValue("2(3+4)", "14")
        assertValue("(1+1)(2+2)", "8")
        assertValue("2π", value("2*pi").map { "\($0)" } ?? "x")
    }

    func testPercent() {
        assertValue("50 + 10%", "55")
        assertValue("80 − 25%", "60")
        assertValue("10%", "0.1")
        assertValue("50 × 10%", "5")
    }

    func testErrors() {
        XCTAssertEqual(CalculatorExpression.evaluate("1 ÷ 0"), .failure(.divisionByZero))
        XCTAssertEqual(CalculatorExpression.evaluate(""), .failure(.empty))
        XCTAssertEqual(CalculatorExpression.evaluate("sqrt(−4)"), .failure(.domain))
        XCTAssertEqual(CalculatorExpression.evaluate("10^200"), .failure(.overflow))
        XCTAssertNil(value("2 + * 3"))
    }

    // MARK: Functions

    func testScientificFunctions() {
        assertValue("sin(30)", "0.5")
        assertValue("sin 180", "0")
        assertValue("cos(90)", "0")
        assertValue("tan(45)", "1")
        assertValue("asin(1)", "90")
        assertValue("sqrt(81)", "9")
        assertValue("√2.25", "1.5")
        assertValue("log(1000)", "3")
        assertValue("ln(e)", "1")
        assertValue("abs(−3)", "3")
        assertValue("cbrt(27)", "3")
        XCTAssertEqual(value("sin(π/2)", angle: .radians), 1)
        XCTAssertNil(value("tan(90)"))
    }

    func testAnswerConstant() {
        XCTAssertEqual(value("ans × 2", answer: 21), 42)
    }

    // MARK: Plain English

    func testPlainEnglish() {
        assertValue("what is 5 plus 3", "8")
        assertValue("five plus three", "8")
        assertValue("twenty-five times four", "100")
        assertValue("two hundred and five minus five", "200")
        assertValue("a dozen times 3", "36")
        assertValue("20% of 150", "30")
        assertValue("what's 20 percent of 150?", "30")
        assertValue("15% off 80", "68")
        assertValue("10% on 200", "220")
        assertValue("square root of 81", "9")
        assertValue("half of 10", "5")
        assertValue("double 21", "42")
        assertValue("3 squared", "9")
        assertValue("2 to the power of 10", "1024")
        assertValue("100 divided by 8", "12.5")
        assertValue("sum of 3 and 4", "7")
        assertValue("difference between 10 and 4", "6")
        assertValue("1,200 + 300", "1500")
        assertValue("3 million / 1000", "3000")
        assertValue("2 + 5 =", "7")
        assertValue("lunch 12 + coffee 4", "16")
    }

    func testLabelsNeverJoinNumbers() {
        XCTAssertNil(value("lunch 12 coffee 4"), "two numbers a label kept apart aren't multiplied")
        XCTAssertNil(value("hello"))
    }

    // MARK: Notes sheet

    func testSheetVariablesAnswersAndTotals() {
        let results = CalculatorSheet.evaluate(lines: ["rent = 1200", "food = 300", "rent + food", "",
                                                       "Groceries", "10 + 5", "4 × 5", "total", "2026"],
                                               angle: .degrees)
        XCTAssertEqual(results.map(\.value), [1200, 300, 1500, nil, nil, 15, 20, 35, nil])
        XCTAssertEqual(results[0].assigns, "rent")
    }

    // MARK: Keypad

    private func keypad(_ keys: [CalculatorKeypad.Key]) -> CalculatorKeypad {
        var keypad = CalculatorKeypad()
        keys.forEach { keypad.press($0) }
        return keypad
    }

    func testTheKeypadKeepsTheWholeCalculationOnScreen() {
        // The 2.2 QA bug: 80 × 5 showed only 5, then only 400.
        var pad = keypad([.digit(8), .digit(0), .operation(.multiply), .digit(5)])
        XCTAssertEqual(pad.input, "80 × 5")
        XCTAssertEqual(pad.preview, 400, "the answer shows live under the calculation")
        pad.press(.equals)
        XCTAssertTrue(pad.showsAnswer)
        XCTAssertEqual(pad.currentValue, 400)
        XCTAssertEqual(pad.answeredExpression, "80 × 5", "the calculation stays above its answer")
        XCTAssertEqual(pad.history.map(\.expression), ["80 × 5"])
        XCTAssertEqual(pad.history.map(\.value), [400])
    }

    func testKeypadContinuesFromAnAnswerOrStartsOver() {
        var pad = keypad([.digit(2), .operation(.add), .digit(3), .equals, .operation(.multiply), .digit(2), .equals])
        XCTAssertEqual(pad.currentValue, 10, "an operator continues from the answer")
        pad.press(.digit(7))
        XCTAssertEqual(pad.input, "7", "a digit starts over")
        XCTAssertFalse(pad.showsAnswer)
    }

    func testKeypadClassicBehaviours() {
        XCTAssertEqual(keypad([.decimalPoint, .digit(1), .operation(.add), .decimalPoint, .digit(2), .equals]).currentValue,
                       Decimal(string: "0.3"))
        XCTAssertEqual(keypad([.digit(2), .operation(.add), .digit(3), .operation(.multiply), .digit(4), .equals]).currentValue, 14)
        XCTAssertEqual(keypad([.digit(5), .digit(0), .operation(.add), .digit(1), .digit(0), .percent, .equals]).currentValue, 55)
        XCTAssertEqual(keypad([.digit(2), .operation(.add), .digit(3), .equals, .equals]).currentValue, 8, "= repeats the last step")
        XCTAssertEqual(keypad([.digit(5), .operation(.add), .equals]).currentValue, 10, "= after an operator reuses the number")
        XCTAssertEqual(keypad([.digit(5), .operation(.add), .operation(.multiply)]).input, "5 × ", "an operator replaces the last one")
        XCTAssertEqual(keypad([.digit(1), .digit(2), .delete]).input, "1")
        XCTAssertEqual(keypad([.digit(1), .operation(.add), .delete]).input, "1", "an operator deletes in one press")
        XCTAssertEqual(keypad([.function("sin"), .delete]).input, "", "a function deletes with its parenthesis")
        XCTAssertEqual(keypad([.digit(5), .toggleSign]).input, "−5")
        XCTAssertEqual(keypad([.digit(5), .toggleSign, .toggleSign]).input, "5")
        XCTAssertEqual(keypad([.digit(3), .operation(.subtract), .digit(4), .toggleSign]).input, "3 − −4")
        XCTAssertEqual(keypad([.digit(1), .decimalPoint, .decimalPoint, .digit(5)]).input, "1.5", "one decimal point")
    }

    func testKeypadErrorsAndClear() {
        var pad = keypad([.digit(1), .operation(.divide), .digit(0), .equals])
        XCTAssertTrue(pad.failed)
        XCTAssertNil(pad.currentValue)
        XCTAssertTrue(pad.history.isEmpty)
        pad.press(.clear)
        XCTAssertFalse(pad.failed)
        XCTAssertEqual(pad.input, "")
        XCTAssertEqual(pad.currentValue, 0)
    }

    func testScientificKeys() {
        XCTAssertEqual(keypad([.function("sqrt"), .digit(8), .digit(1), .close, .equals]).currentValue, 9)
        XCTAssertEqual(keypad([.digit(2), .power, .digit(1), .digit(0), .equals]).currentValue, 1024)
        XCTAssertEqual(keypad([.digit(4), .reciprocal, .equals]).currentValue, Decimal(string: "0.25"))
        XCTAssertEqual(keypad([.digit(3), .equals, .digit(1), .operation(.add), .answer, .equals]).currentValue, 4)
    }

    func testUsingAHistoryAnswer() {
        var pad = keypad([.digit(6), .operation(.multiply), .digit(7), .equals, .clear, .digit(1), .operation(.add)])
        pad.use(42)
        XCTAssertEqual(pad.input, "1 + 42")
    }

    // MARK: Review findings (PR 338)

    func testEdgeCasesFromReview() {
        XCTAssertEqual(CalculatorExpression.evaluate(String(repeating: "one hundred ", count: 1) + String(repeating: "hundred ", count: 30)),
                       .failure(.overflow), "spelled-out overflow is an error, not a crash")
        assertValue("2²^3", "64")
        assertValue("3²!", "362880")
        XCTAssertNil(value("2.3.4"), "a malformed number isn't a product")
        XCTAssertEqual(CalculatorExpression.evaluate("fact(18446744073709551616)"), .failure(.overflow))
        let results = CalculatorSheet.evaluate(lines: ["subtotal = 5", "subtotal + 2", "total"], angle: .degrees)
        XCTAssertEqual(results.map(\.value), [5, 7, 12])
    }

    func testKeypadReusesTheExactSignedAnswer() {
        XCTAssertEqual(keypad([.digit(3), .operation(.divide), .digit(7), .equals, .operation(.multiply), .digit(7), .equals])
                        .currentValue.map { LocalCalculatorFormat.rounded($0, significantDigits: 15) }, 3)
        XCTAssertEqual(keypad([.operation(.subtract), .digit(2), .equals, .square, .equals]).currentValue, 4)
        XCTAssertEqual(keypad([.digit(2), .operation(.add), .digit(3), .equals, .clear, .operation(.multiply), .digit(2), .equals])
                        .currentValue, 0, "after AC an operator starts from 0")
        XCTAssertEqual(keypad([.operation(.subtract), .digit(5), .operation(.multiply), .equals]).currentValue, 25)
        XCTAssertEqual(keypad([.digit(5), .operation(.subtract), .digit(3), .toggleSign, .equals, .equals]).currentValue, 11)
        var pad = keypad([.digit(4), .operation(.add), .digit(1), .equals, .operation(.multiply), .digit(2)])
        XCTAssertEqual(pad.displayInput(locale: Locale(identifier: "en_US")), "5 × 2", "the answer shows as its number")
        pad.press(.equals)
        XCTAssertEqual(pad.answeredExpression, "5 × 2")
    }

    // MARK: Review findings, round 2 (PR 338)

    func testRoundTwoEdgeCases() {
        let nested = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
        XCTAssertNil(value(nested), "deep nesting is an error, not a crash")
        XCTAssertNil(value(String(repeating: "-", count: 5000) + "1"))
        XCTAssertEqual(value("200 + 2π%"), value("200 + 2 × π%"), "an implied × reads like a written one")
        XCTAssertEqual(value("10^(-100)"), LocalCalculatorFormat.power(-100))
        XCTAssertEqual(value("2^-3"), Decimal(string: "0.125"))
        XCTAssertEqual(CalculatorExpression.evaluate("0^-1"), .failure(.divisionByZero))
    }

    func testDefinedNamesWinOverShorthand() {
        let results = CalculatorSheet.evaluate(lines: ["x2 = 7", "x2 + 1", "ans1 = 10", "ans1 * 2",
                                                       "one = 5", "one + 1", "half = 4", "half * 3"], angle: .degrees)
        XCTAssertEqual(results.map(\.value), [7, 8, 10, 20, 5, 6, 4, 12])
    }

    func testSmartAnswersCountTowardTotals() {
        let results = CalculatorSheet.evaluate(lines: ["5 km in m", "2 km in m", "total"], angle: .degrees)
        XCTAssertEqual(results.last?.value, 7000)
    }

    func testTypingAfterErrorStartsOver() {
        var pad = keypad([.digit(1), .operation(.divide), .digit(0), .equals])
        XCTAssertTrue(pad.failed)
        pad.press(.digit(2))
        pad.press(.equals)
        XCTAssertEqual(pad.currentValue, 2)
        let edited = keypad([.digit(1), .operation(.divide), .digit(0), .equals, .delete, .digit(4), .equals])
        XCTAssertEqual(edited.currentValue, Decimal(string: "0.25"), "⌫ still edits the failed calculation")
    }

    func testRoundThreeEdgeCases() {
        XCTAssertEqual(value("100 + 2^10%"), value("100 + (2^10%)"), "a % in the exponent isn't a relative percent")
        XCTAssertEqual(value("1,234,567,890 + 1"), 1_234_567_891)
        XCTAssertEqual(value("ans!", answer: 3), 6)
        XCTAssertNil(value("π!"), "π has no factorial")
        XCTAssertEqual(keypad([.open, .digit(2), .operation(.add), .digit(3), .close, .toggleSign, .equals]).currentValue, -5)
        var pad = CalculatorKeypad()
        let big = Decimal(string: "1124000727777607680000")!
        pad.use(big)
        pad.press(.operation(.subtract))
        pad.use(big)
        pad.press(.equals)
        XCTAssertEqual(pad.currentValue, 0, "a reused answer stays exact")
    }
}
