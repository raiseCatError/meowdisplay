import XCTest

/// The receiver's local calculator engine (`LocalCalculator`): exact decimal
/// arithmetic with the iPhone basic Calculator's semantics. Keys are typed as
/// a space-separated string: digits and `.`, `+ - * /`, `=`, `C` (the clear
/// key, C or AC), `±`, `%` and `<` (Delete).
final class LocalCalculatorTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func calculator(_ keys: String) -> LocalCalculator {
        var calculator = LocalCalculator()
        for token in keys.split(separator: " ") {
            switch token {
            case "+": calculator.press(.operation(.add))
            case "-": calculator.press(.operation(.subtract))
            case "*": calculator.press(.operation(.multiply))
            case "/": calculator.press(.operation(.divide))
            case "=": calculator.press(.equals)
            case "C": calculator.press(.clear)
            case "±": calculator.press(.toggleSign)
            case "%": calculator.press(.percent)
            case "<": calculator.press(.delete)
            default:
                for character in token {
                    if character == "." {
                        calculator.press(.decimalPoint)
                    } else {
                        calculator.press(.digit(Int(String(character))!))
                    }
                }
            }
        }
        return calculator
    }

    private func shown(_ keys: String, locale: Locale? = nil) -> String {
        calculator(keys).display(locale: locale ?? us).text
    }

    private func copied(_ keys: String, locale: Locale? = nil) -> String? {
        calculator(keys).copyText(locale: locale ?? us)
    }

    // MARK: Exact decimals

    func testDecimalArithmeticIsExact() {
        XCTAssertEqual(shown("0.1 + 0.2 ="), "0.3")
        XCTAssertEqual(copied("0.1 + 0.2 ="), "0.3", "not 0.30000000000000004")
        XCTAssertEqual(calculator("0.1 + 0.2 =").currentValue, Decimal(string: "0.3"))
        XCTAssertEqual(shown("1.1 * 3 ="), "3.3")
        XCTAssertEqual(shown("0.3 - 0.1 ="), "0.2")
        XCTAssertEqual(shown("1 / 3 * 3 ="), "1")
    }

    // MARK: Precedence and chaining

    func testMultiplicationAndDivisionBindTighterThanAdditionAndSubtraction() {
        XCTAssertEqual(shown("2 + 3 * 4 ="), "14")
        XCTAssertEqual(shown("2 * 3 + 4 ="), "10")
        XCTAssertEqual(shown("10 - 4 / 2 ="), "8")
        XCTAssertEqual(shown("1 + 2 * 3 - 4 / 2 ="), "5")
        XCTAssertEqual(shown("2 * 3 * 4 ="), "24")
        XCTAssertEqual(shown("10 - 2 - 3 ="), "5", "left to right within a level")
        XCTAssertEqual(shown("100 / 10 / 2 ="), "5")
    }

    func testTheDisplayShowsWhatEachOperatorReduced() {
        XCTAssertEqual(shown("2 * 3 +"), "6")
        XCTAssertEqual(shown("2 + 3 *"), "3", "× waits for its own operand")
        XCTAssertEqual(shown("2 + 3 * 4 -"), "14")
        XCTAssertEqual(calculator("2 + 3 *").highlightedOperation, .multiply)
        XCTAssertNil(calculator("2 + 3 * 4").highlightedOperation, "typing the operand clears the highlight")
    }

    func testAnOperatorRightAfterAnotherReplacesIt() {
        XCTAssertEqual(shown("2 + * 3 ="), "6")
        XCTAssertEqual(shown("2 * 3 + - 1 ="), "5")
        XCTAssertEqual(shown("2 + 3 * - 1 ="), "4", "a lower operator reduces what the replaced one held")
        XCTAssertEqual(calculator("2 + * ").highlightedOperation, .multiply)
    }

    func testAResultContinuesIntoTheNextOperation() {
        XCTAssertEqual(shown("2 + 3 = * 2 ="), "10")
        XCTAssertEqual(shown("2 + 3 = 7 * 2 ="), "14", "a new number after = starts over")
    }

    // MARK: Equals

    func testRepeatedEqualsRepeatsTheLastStep() {
        XCTAssertEqual(shown("2 + 3 ="), "5")
        XCTAssertEqual(shown("2 + 3 = ="), "8")
        XCTAssertEqual(shown("2 + 3 = = ="), "11")
        XCTAssertEqual(shown("10 - 2 = ="), "6")
        XCTAssertEqual(shown("2 + 3 * 4 = ="), "56", "the last operator with its operand: × 4")
        XCTAssertEqual(shown("2 + 3 = 7 ="), "10", "a new number takes the same step")
    }

    func testEqualsRightAfterAnOperatorReusesTheShownValue() {
        XCTAssertEqual(shown("5 + ="), "10")
        XCTAssertEqual(shown("5 * ="), "25")
        XCTAssertEqual(shown("5 * = ="), "125")
    }

    func testEqualsWithNothingPendingKeepsTheNumber() {
        XCTAssertEqual(shown("5 ="), "5")
        XCTAssertEqual(shown("="), "0")
        XCTAssertEqual(shown("5 = = ="), "5")
    }

    func testAllClearEndsTheRepeatedStep() {
        XCTAssertEqual(shown("2 + 3 = C 7 ="), "7")
    }

    // MARK: Percent

    func testPercentMatchesTheIPhoneCalculator() {
        XCTAssertEqual(shown("50 + 10 %"), "5", "percent of the left operand after +")
        XCTAssertEqual(shown("50 + 10 % ="), "55")
        XCTAssertEqual(shown("50 - 10 % ="), "45")
        XCTAssertEqual(shown("10 %"), "0.1", "on its own it divides by 100")
        XCTAssertEqual(shown("50 * 10 % ="), "5")
        XCTAssertEqual(shown("50 / 10 % ="), "500")
        XCTAssertEqual(shown("2 * 3 + 10 % ="), "6.6", "of the reduced left side")
        XCTAssertEqual(shown("10 % %"), "0.001")
        XCTAssertEqual(shown("2 + 3 = %"), "0.05", "of a result")
        XCTAssertEqual(shown("50 + 10 % 2 ="), "52", "a digit replaces the percent value")
    }

    // MARK: Negative values

    func testPlusOrMinus() {
        XCTAssertEqual(shown("±"), "-0", "ready for digits, like iOS")
        XCTAssertEqual(shown("± 5"), "-5")
        XCTAssertEqual(shown("5 ±"), "-5")
        XCTAssertEqual(shown("5 ± ±"), "5")
        XCTAssertEqual(shown("5 ± + 3 ="), "-2")
        XCTAssertEqual(shown("2 + 3 = ±"), "-5", "flips a result")
        XCTAssertEqual(shown("5 + ± 2 ="), "3", "after an operator it starts −0")
        XCTAssertEqual(shown("3 - 5 ="), "-2")
        XCTAssertEqual(shown("± 1.5 * 2 ="), "-3")
        XCTAssertEqual(copied("3 - 5.5 ="), "-2.5")
    }

    // MARK: Input limits

    func testInputStopsAtNineDigits() {
        XCTAssertEqual(shown("1234567891"), "123,456,789")
        XCTAssertEqual(shown(".123456789123"), "0.123456789", "the 0 before the point isn't counted")
        XCTAssertEqual(shown("12345.67891"), "12,345.6789")
        XCTAssertEqual(shown("123456789."), "123,456,789", "no point when nothing more can follow")
    }

    func testOneDecimalPointAndNoLeadingZeros() {
        XCTAssertEqual(shown("0.5.5"), "0.55")
        XCTAssertEqual(shown("000"), "0")
        XCTAssertEqual(shown("007"), "7")
        XCTAssertEqual(shown("."), "0.")
        XCTAssertEqual(shown("1."), "1.")
        XCTAssertEqual(shown("1.50"), "1.50", "typed zeros stay while typing")
        XCTAssertEqual(copied("1.50"), "1.5")
    }

    // MARK: Large and small numbers

    func testLargeResultsUseScientificNotation() {
        XCTAssertEqual(shown("999999999 + 1 ="), "1e9")
        XCTAssertEqual(shown("123456789 * 1000 ="), "1.234568e11")
        XCTAssertEqual(calculator("123456789 * 1000 =").display(locale: us),
                       .scientific(mantissa: "1.234568", exponent: "11"))
        XCTAssertEqual(shown("± 123456789 * 1000 ="), "-1.234568e11")
        XCTAssertEqual(shown("123456789 * 123456789 ="), "1.524158e16", "seven significant digits in the mantissa")
        XCTAssertEqual(shown("999999999 * 999999999 ="), "1e18", "a mantissa rounding up to 10 carries into the exponent")
        XCTAssertEqual(shown("999999999"), "999,999,999", "nine digits still fit")
    }

    func testResultsRoundToNineSignificantDigits() {
        XCTAssertEqual(shown("1 / 3 ="), "0.333333333")
        XCTAssertEqual(shown("2 / 3 ="), "0.666666667")
        XCTAssertEqual(shown("1234567.89 + 0.001 ="), "1,234,567.89")
        XCTAssertEqual(shown("99999999.9 + 0.06 ="), "100,000,000", "rounding can carry into a new digit")
    }

    func testTinyResultsUseScientificNotation() {
        XCTAssertEqual(shown("1 / 100000000 / 100 ="), "1e-10")
        XCTAssertEqual(shown("0.000001 * 0.000001 ="), "1e-12")
        XCTAssertEqual(shown("1 / 100000000 ="), "0.00000001", "still shown plainly")
    }

    func testAnOverflowIsAnError() {
        let keys = "99999999 * 99999999" + String(repeating: " =", count: 14)
        XCTAssertTrue(calculator(keys).isError)
        XCTAssertEqual(shown(keys), "Error")
    }

    // MARK: Division by zero

    func testDivisionByZeroShowsErrorAndTheNextInputRecovers() {
        let error = calculator("5 / 0 =")
        XCTAssertTrue(error.isError)
        XCTAssertEqual(error.display(locale: us), .error)
        XCTAssertNil(error.currentValue)
        XCTAssertNil(error.copyText(locale: us), "nothing to copy")
        XCTAssertTrue(error.showsAllClear)
        XCTAssertEqual(shown("5 / 0 = 7"), "7", "a digit starts over")
        XCTAssertEqual(shown("5 / 0 = 7 + 1 ="), "8")
        XCTAssertEqual(shown("5 / 0 = ."), "0.")
        XCTAssertEqual(shown("5 / 0 = C"), "0")
        XCTAssertFalse(calculator("5 / 0 = C").isError)
    }

    func testOtherKeysAreIgnoredWhileShowingError() {
        for key in ["+", "*", "=", "%", "±", "<"] {
            XCTAssertTrue(calculator("5 / 0 = \(key)").isError, "\(key) is ignored")
        }
        XCTAssertTrue(calculator("1 + 5 / 0 *").isError, "a division by zero inside a chain fails when reduced")
        XCTAssertEqual(shown("5 / 0 = + 2 ="), "2", "the ignored + doesn't survive into the new number")
    }

    // MARK: Clear and Delete

    func testClearThenAllClear() {
        XCTAssertTrue(calculator("").showsAllClear)
        XCTAssertFalse(calculator("5").showsAllClear, "C once something is typed")
        XCTAssertTrue(calculator("5 +").showsAllClear)
        XCTAssertEqual(shown("5 + 3 C 4 ="), "9", "C clears only the number being typed")
        XCTAssertTrue(calculator("5 + 3 C").showsAllClear)
        XCTAssertEqual(shown("5 + 3 C C 4 ="), "4", "AC clears the calculation")
        XCTAssertTrue(calculator("2 + 3 =").showsAllClear)
        XCTAssertEqual(calculator("2 + 3 = C"), LocalCalculator(), "AC is a fresh calculator")
    }

    func testDeleteEditsOnlyTheNumberBeingTyped() {
        XCTAssertEqual(shown("123 <"), "12")
        XCTAssertEqual(shown("1.5 <"), "1.")
        XCTAssertEqual(shown("1.5 < <"), "1")
        XCTAssertEqual(shown("1.5 < < <"), "0")
        XCTAssertEqual(shown("5 ± <"), "0")
        XCTAssertEqual(shown("2 + 3 = <"), "5", "a result is never edited")
        XCTAssertEqual(shown("2 + <"), "2")
        XCTAssertEqual(shown("2 + 34 < ="), "5")
        XCTAssertTrue(calculator("12").canDelete)
        XCTAssertFalse(calculator("").canDelete)
        XCTAssertFalse(calculator("2 + 3 =").canDelete)
    }

    // MARK: Locale and Copy Result

    func testTheDisplayFollowsTheRegion() {
        let germany = Locale(identifier: "de_DE")
        XCTAssertEqual(shown("1234.5", locale: germany), "1.234,5")
        XCTAssertEqual(shown("1 / 3 =", locale: germany), "0,333333333")
        XCTAssertEqual(shown("123456789 * 1000 =", locale: germany), "1,234568e11")
        XCTAssertEqual(shown(".", locale: germany), "0,")
    }

    func testCopyResultIsPlainDigitsWithTheRegionsDecimalSeparator() {
        XCTAssertEqual(copied("1234.5"), "1234.5", "no grouping separators")
        XCTAssertEqual(copied("1234.5", locale: Locale(identifier: "de_DE")), "1234,5")
        XCTAssertEqual(copied("1234.5", locale: Locale(identifier: "fr_FR")), "1234,5")
        XCTAssertEqual(copied("1234.5", locale: Locale(identifier: "ar_EG")), "1234.5",
                       "ASCII digits and a point where the region's separator isn't , or .")
        XCTAssertEqual(copied("0"), "0")
        XCTAssertEqual(copied("."), "0")
    }

    func testCopyResultKeepsFullPrecisionNotTheRoundedDisplay() {
        XCTAssertEqual(copied("123456789 * 1000 ="), "123456789000", "the display shows 1.234568e11")
        XCTAssertEqual(copied("1 / 3 ="), "0.333333333333333", "15 significant digits")
        XCTAssertEqual(copied("99999999.9 + 0.06 ="), "99999999.96")
        XCTAssertEqual(copied("1 / 100000000 / 100 ="), "1E-10")
        XCTAssertEqual(copied("1 / 4 ="), "0.25")
    }

    func testCopyResultUsesENotationOnlyForExtremeMagnitudes() {
        let keys = "100000000 * 100000000 * 100000 =" // 1e21
        XCTAssertEqual(copied(keys), "1E21")
        XCTAssertEqual(copied("100000000 * 100000000 * 10000 ="), "100000000000000000000")
    }

    func testFormattingHelpers() {
        XCTAssertEqual(LocalCalculatorFormat.magnitude(of: 1), 0)
        XCTAssertEqual(LocalCalculatorFormat.magnitude(of: 999), 2)
        XCTAssertEqual(LocalCalculatorFormat.magnitude(of: 1000), 3)
        XCTAssertEqual(LocalCalculatorFormat.magnitude(of: Decimal(string: "0.001")!), -3)
        XCTAssertEqual(LocalCalculatorFormat.magnitude(of: Decimal(string: "-0.0099")!), -3)
        XCTAssertEqual(LocalCalculatorFormat.rounded(Decimal(string: "2.5")!, scale: 0), 3, "half away from zero")
        XCTAssertEqual(LocalCalculatorFormat.rounded(Decimal(string: "-2.5")!, scale: 0), -3)
        XCTAssertEqual(LocalCalculatorFormat.rounded(Decimal(string: "123456789123")!, significantDigits: 9),
                       Decimal(string: "123456789000"))
    }

    func testOnlyLocalStateChanges() {
        // The engine is a value: every key press is a pure state change with
        // no side channel — what the panel shows is all there is.
        var calculator = LocalCalculator()
        let before = calculator
        calculator.press(.digit(4))
        XCTAssertNotEqual(calculator, before)
        XCTAssertEqual(LocalCalculator(), before)
    }
}
