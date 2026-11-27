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

    func testRoundFiveFindings() {
        XCTAssertNotNil(answer("1 m2 in ft2"), "units whose names hold digits convert")
        XCTAssertEqual(answer("days since 25 dec"), "337 days")
    }

    func testRoundSixFindings() {
        let sheet = CalculatorSheet.evaluate(lines: ["rate = 30 is what percent of 150", "150 * rate"], angle: .degrees, smart: context)
        XCTAssertEqual(sheet.map(\.value), [Decimal(string: "0.2"), 30], "a percent answer is kept as its fraction")
        var german = context
        german.locale = Locale(identifier: "de_DE")
        let comma = CalculatorSheet.evaluate(lines: ["1,5 + 2", "1.250 + 1"], angle: .degrees, smart: german)
        XCTAssertEqual(comma.map(\.value), [Decimal(string: "3.5"), 1251])
    }

    func testIncrementalSheetMatchesAFullOne() {
        let first = ["rent = 1200", "food = 300", "rent + food", "", "x = 2", "x * 3", "total"]
        let edited = ["rent = 1200", "food = 350", "rent + food", "", "x = 2", "x * 3", "total", "ans + 1"]
        let before = CalculatorSheet.evaluate(lines: first, angle: .degrees, smart: context, reusing: nil)
        let after = CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context, reusing: before)
        XCTAssertEqual(after.results, CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context))
        let appended = CalculatorSheet.evaluate(lines: first + ["total + 1"], angle: .degrees, smart: context, reusing: before)
        XCTAssertEqual(appended.results, CalculatorSheet.evaluate(lines: first + ["total + 1"], angle: .degrees, smart: context))
    }
    // Codex round 7 (on the round 6 fixes).
    func testDecimalCommaLocalesWithoutDotGroupingKeepDots() {
        var french = context
        french.locale = Locale(identifier: "fr_FR")
        let sheet = CalculatorSheet.evaluate(lines: ["1.250 + 1", "1,5 + 2"], angle: .degrees, smart: french)
        XCTAssertEqual(sheet.map(\.value), [Decimal(string: "2.25"), Decimal(string: "3.5")],
                       "fr_FR groups with spaces: a dot stays a decimal point")
    }

    func testTimeAnswersAreNeverReused() {
        let lines = ["30 seconds from now", "2 + 2"]
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        var later = context
        later.now = context.now.addingTimeInterval(45)
        let reused = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: later, reusing: before)
        XCTAssertEqual(reused.results, CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: later))
        XCTAssertEqual(before.firstTimeDependent, 0)
    }

    // Performance: within a second a time answer is current, so typing below it doesn't redo
    // the sheet; the second is counted from when that answer was worked out.
    func testTimeAnswersAreReusedOnlyWhileCurrent() {
        // Long enough to have a saved state past the time answer, so an edit at the bottom
        // can start below it.
        let lines = ["time in Tokyo", "a = 2"] + (0..<38).map { "a + \($0)" }
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        var soon = context
        soon.now = context.now.addingTimeInterval(0.4)
        var edited = lines
        edited[39] = "a + 100"
        let typed = CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: soon, reusing: before)
        XCTAssertEqual(typed.results[0], before.results[0], "the time answer is still current")
        XCTAssertEqual(typed.results[39].value, 102)
        XCTAssertEqual(typed.timeAnswersMadeAt, before.timeAnswersMadeAt, "it keeps its age")
        XCTAssertEqual(CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: soon, reusing: typed).results,
                       typed.results, "a redraw in the same second reuses it all")
        var later = context
        later.now = context.now.addingTimeInterval(1.2)
        let due = CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: later, reusing: typed)
        XCTAssertEqual(due.results, CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: later))
        XCTAssertEqual(due.timeAnswersMadeAt, later.now, "over a second old (from when it was worked out): redone")
        var earlier = context
        earlier.now = context.now.addingTimeInterval(-5)
        XCTAssertEqual(CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: earlier, reusing: before).results,
                       CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: earlier),
                       "a clock set back redoes it")
    }

    // Codex round 12: one sheet asks the same time question twice across a minute boundary.
    func testOneSheetShowsOneTimeForOneQuestion() {
        var edge = context
        edge.now = Date(timeIntervalSinceReferenceDate: (context.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 59.6)
        let lines = ["time in Tokyo", "a = 2"] + (0..<38).map { "a + \($0)" }
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: edge, reusing: nil)
        var next = edge
        next.now = edge.now.addingTimeInterval(0.6) // the next minute
        var asked = lines
        asked[39] = "time in Tokyo"
        let after = CalculatorSheet.evaluate(lines: asked, angle: .degrees, smart: next, reusing: before)
        XCTAssertEqual(after.results[39], after.results[0])
    }

    // Codex round 12: canonically equivalent spellings are compared as written.
    func testAnEquivalentSpellingIsNotTakenForTheSameLine() {
        let first = ["\u{00ED} = 5", "twenty-\u{00ED} + 1"]
        let second = ["\u{00ED} = 5", "twenty-i\u{0301} + 1"]
        let before = CalculatorSheet.evaluate(lines: first, angle: .degrees, smart: context, reusing: nil)
        XCTAssertEqual(CalculatorSheet.evaluate(lines: second, angle: .degrees, smart: context, reusing: before).results,
                       CalculatorSheet.evaluate(lines: second, angle: .degrees, smart: context))
        // Codex round 13: also when a saved state lies past it and a later line changes too.
        let filler = (0..<30).map { "\($0) + 1" }
        let long = first + filler, edited = second + filler.dropLast() + ["99 + 1"]
        let saved = CalculatorSheet.evaluate(lines: long, angle: .degrees, smart: context, reusing: nil)
        XCTAssertTrue(saved.checkpoints.keys.contains { $0 > 1 }, "a saved state past the changed line")
        XCTAssertEqual(CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context, reusing: saved).results,
                       CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context))
    }

    func testAnotherAngleRedoesTheSheet() {
        let lines = ["sin(30)"]
        let degrees = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        XCTAssertEqual(CalculatorSheet.evaluate(lines: lines, angle: .radians, smart: context, reusing: degrees).results,
                       CalculatorSheet.evaluate(lines: lines, angle: .radians, smart: context))
        XCTAssertNotEqual(CalculatorSheet.evaluate(lines: lines, angle: .radians, smart: context), degrees.results)
    }

    // Codex round 12: a thousands group that ends before a combining mark doesn't stop the scan.
    func testThousandsAfterACombiningMarkStillGroup() {
        XCTAssertTrue(CalculatorLanguage.normalize("1,200\u{0301} + 2,345").contains("2345"))
    }

    func testAnotherLocaleRedoesTheSheet() {
        let lines = ["1,5 + 2"]
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        var german = context
        german.locale = Locale(identifier: "de_DE")
        let after = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: german, reusing: before)
        XCTAssertEqual(after.results, CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: german))
    }

    func testAssignmentHeavySheetsKeepFewStates() {
        let lines = (0..<2_500).map { "v\($0) = \($0)" } + ["v10 + v2499"]
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        XCTAssertLessThanOrEqual(before.checkpoints.count, 17, "saved states stay few, not one per line")
        var edited = lines
        edited[2_000] = "v2000 = 7"
        let after = CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context, reusing: before)
        XCTAssertEqual(after.results, CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context))
        XCTAssertEqual(after.results.last?.value, 2_509)
    }
    // Codex round 8.
    func testLocaleNumbersAndTheRailsLeadingComma() {
        var french = context
        french.locale = Locale(identifier: "fr_FR")
        let sheet = CalculatorSheet.evaluate(lines: [",5 + ,2", "1 250,5 + 1", "1\u{202F}250,5 + 1", "1.250 + 1"],
                                             angle: .degrees, smart: french)
        XCTAssertEqual(sheet.map(\.value), [Decimal(string: "0.7"), Decimal(string: "1251.5"),
                                            Decimal(string: "1251.5"), Decimal(string: "2.25")])
        var german = context
        german.locale = Locale(identifier: "de_DE")
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["1.250,5 + ,5"], angle: .degrees, smart: german).map(\.value),
                       [1251])
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("five, plus three", locale: french.locale), "five, plus three")
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("five plus,3", locale: french.locale), "five plus,3",
                       "a comma after a word is punctuation")
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["five plus,3"], angle: .degrees, smart: french).map(\.value), [8])
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("2 × ,5", locale: french.locale), "2 × .5")
        // Codex round 10: every operator the calculator reads, with any spaces before the comma.
        for expression in ["2 · ,5", "2 *    ,5", "2 ⋅ ,5", "2×,5", "(,5) * 2", "2 * [,5]", "2 x ,5", "2x,5"] {
            XCTAssertEqual(CalculatorSheet.evaluate(lines: [expression], angle: .degrees, smart: french).map(\.value), [1],
                           expression)
        }
        // Codex round 11: roots and "mod".
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["√,25"], angle: .degrees, smart: french).map(\.value), [0.5])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["2 mod ,5"], angle: .degrees, smart: french).map(\.value), [0])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["7 modulo ,4"], angle: .degrees, smart: french).map(\.value), [0.2])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["(2+3) x ,4"], angle: .degrees, smart: french).map(\.value), [2])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["balance = 7", "balance modulo ,4"], angle: .degrees,
                                                smart: french).map(\.value), [7, 0.2])
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("box ,5", locale: french.locale), "box ,5", "inside a word")
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("commodity ,5", locale: french.locale), "commodity ,5")
        // Codex round 13: naming x doesn't change what a unit conversion's amount means.
        let km = CalculatorSheet.evaluate(lines: ["2 x ,5 km in m"], angle: .degrees, smart: french).map(\.value)
        XCTAssertEqual(km, [1000])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["x = 3", "2 x ,5 km in m"], angle: .degrees,
                                                smart: french).map(\.value).last, km.first)
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["2 × ,5 km in m"], angle: .degrees, smart: french).map(\.value), [1000])
        XCTAssertEqual(CalculatorSheet.evaluate(lines: ["five plus,3"], angle: .degrees, smart: french).map(\.value), [8])
        XCTAssertEqual(CalculatorSheet.normalizingNumbers("1,5", locale: context.locale), "1,5", "en_GB is left alone")
    }

    func testCheckpointsSurviveAStrideChange() {
        let lines = (0..<2_495).map { "v\($0) = \($0)" }
        let before = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: context, reusing: nil)
        let grown = lines + ["v2494 + 1"]
        let appended = CalculatorSheet.evaluate(lines: grown, angle: .degrees, smart: context, reusing: before)
        XCTAssertGreaterThan(appended.checkpoints.count, 8, "earlier states are kept when the stride changes")
        XCTAssertLessThanOrEqual(appended.checkpoints.count, 17)
        var edited = grown
        edited[2_495] = "v2494 + 2"
        let after = CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context, reusing: appended)
        XCTAssertEqual(after.results, CalculatorSheet.evaluate(lines: edited, angle: .degrees, smart: context))
        XCTAssertEqual(after.results.last?.value, 2_496)
        // Insertions, deletions and truncation match a full evaluation too.
        for change in [Array(edited.prefix(100)), Array(edited.prefix(50) + ["x = 3"] + edited.dropFirst(50)),
                       Array(edited.prefix(10) + edited.dropFirst(11))] {
            XCTAssertEqual(CalculatorSheet.evaluate(lines: change, angle: .degrees, smart: context, reusing: after).results,
                           CalculatorSheet.evaluate(lines: change, angle: .degrees, smart: context))
        }
    }

    // Performance: the phrase patterns are compiled once, and an unchanged sheet is not redone.
    func testPhrasesCompileOnceAndAnUnchangedSheetIsReused() {
        XCTAssertTrue(CalculatorLanguage.allPhrasesCompile)
        let lines = (0..<40).map { $0 % 2 == 0 ? "a\($0) = \($0) * 2 + 15%" : "a\($0 - 1) + 3 cm in inches" }
        let smart = CalculatorSmartContext()
        let first = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: smart, reusing: nil)
        let again = CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: smart, reusing: first)
        XCTAssertEqual(again.results, first.results)
        XCTAssertEqual(again.results, CalculatorSheet.evaluate(lines: lines, angle: .degrees, smart: smart))
        XCTAssertEqual(CalculatorSheet.evaluate(lines: lines, angle: .radians, smart: smart, reusing: first).results,
                       CalculatorSheet.evaluate(lines: lines, angle: .radians, smart: smart),
                       "another angle redoes it")
    }
}
