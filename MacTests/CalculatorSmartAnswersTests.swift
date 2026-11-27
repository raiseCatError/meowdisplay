import XCTest

/// The calculator notes' everyday answers (`CalculatorSmartAnswers`) and
/// variables, at a fixed time: Friday 27 Nov 2026, 12:00 UTC.
final class CalculatorSmartAnswersTests: XCTestCase {
    private var context: CalculatorSmartContext {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        calendar.timeZone = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12))!
        return CalculatorSmartContext(now: now, calendar: calendar, timeZone: utc, locale: Locale(identifier: "en_GB"))
    }

    private func answer(_ text: String) -> String? {
        CalculatorSmartAnswers.answer(text, context: context)?.text
    }

    func testUnitConversions() {
        XCTAssertEqual(answer("5 km in miles"), "3.10685596 mi")
        XCTAssertEqual(answer("100 f to c"), "37.7777778 °C")
        XCTAssertEqual(answer("2 GB in MB"), "2,000 MB")
        XCTAssertEqual(answer("3 hours in minutes"), "180 min")
        XCTAssertEqual(answer("1 mile in km"), "1.609344 km")
        XCTAssertEqual(answer("10 kg to lbs"), "22.0462262 lb")
        XCTAssertNil(answer("5 km in kg"), "different kinds of unit don't convert")
    }

    func testNumberBases() {
        XCTAssertEqual(answer("255 in hex"), "0xFF")
        XCTAssertEqual(answer("10 in binary"), "0b1010")
        XCTAssertEqual(answer("0xff"), "255")
        XCTAssertEqual(answer("0xff in decimal"), "255")
    }

    func testPercentQuestions() {
        XCTAssertEqual(answer("30 is what percent of 150"), "20%")
        XCTAssertEqual(answer("what percent of 200 is 50"), "25%")
        XCTAssertEqual(answer("percent change from 50 to 75"), "+50%")
    }

    func testTimeZones() {
        XCTAssertEqual(answer("3pm pst in london"), "23:00 GMT")
        XCTAssertEqual(answer("12:00 utc to ist"), "17:30 GMT+5:30")
        XCTAssertEqual(answer("time in tokyo"), "21:00 GMT+9")
        XCTAssertEqual(answer("noon in new york"), "07:00 EST")
    }

    func testRelativeTimes() {
        XCTAssertEqual(answer("5 hours from now"), "17:00")
        XCTAssertEqual(answer("90 minutes after 3pm"), "16:30")
        XCTAssertEqual(answer("in 10 days"), "Mon 7 Dec")
        XCTAssertEqual(answer("2 weeks ago"), "Fri 13 Nov")
        XCTAssertEqual(answer("now + 30 minutes"), "12:30")
    }

    func testDates() {
        XCTAssertEqual(answer("days until christmas"), "28 days")
        XCTAssertEqual(answer("what day is 4 july 2027"), "Sunday")
    }

    func testPlainMathIsLeftToTheEngine() {
        XCTAssertNil(answer("2 + 3"))
        XCTAssertNil(answer("rent = 1200"))
        XCTAssertNil(answer("Groceries"))
    }

    func testSheetUsesVariablesXAndSmartAnswers() {
        let lines = ["rent = 1200", "rent × 12", "x = 4", "2x + 1", "x * 3", "let y = x^2", "y - x",
                     "5 km in miles", "", "price = 80", "15% off price"]
        let results = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context)
        XCTAssertEqual(results.map(\.value).prefix(7), [1200, 14400, 4, 9, 12, 16, 12])
        XCTAssertEqual(results[7].text, "3.10685596 mi")
        XCTAssertNotNil(results[7].value)
        XCTAssertEqual(results.map(\.value).suffix(3), [nil, 80, 68])
    }

    func testRoundTwoReviewFindings() {
        XCTAssertNil(answer("in 10000000000000000000 days"), "an absurd count is no answer, not a crash")
        XCTAssertNil(answer("100000000 hours from now"))
        XCTAssertEqual(answer("3pm pdt in london"), "22:00 GMT", "PDT is UTC−7 even in November")
        XCTAssertEqual(answer("3pm pt in london"), "23:00 GMT", "PT follows the season")
        XCTAssertEqual(answer("days since christmas"), "337 days")
        XCTAssertEqual(answer("days until christmas"), "28 days")
    }

    func testOnlyRecurringDatesRollForward() {
        XCTAssertEqual(answer("days until yesterday"), "1 day ago")
        XCTAssertEqual(answer("days until 25 dec"), "28 days")
    }
}
