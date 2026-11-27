// Everyday questions the calculator's notes answer beside arithmetic, as
// Soulver and Raycast do: time zones ("3pm PST in London", "time in
// Tokyo"), relative times ("5 hours from now", "90 minutes after 3pm",
// "in 10 days", "2 weeks ago"), date maths ("days until 25 Dec", "days
// between 1 Jan 2026 and 15 Mar 2026", "what day is 4 Jul 2027"), unit
// conversions ("5 km in miles", "100 F to C", "2 GB in MB", "3 hours in
// minutes"), number bases ("255 in hex", "0xff"), and percent questions
// ("30 is what percent of 150", "percent change from 50 to 75").
// Foundation only; `now`, the calendar and the time zone are injected so
// it is hostless-testable (`CalculatorSmartAnswersTests`). Nothing here
// reaches the network or the Mac.

import Foundation

struct CalculatorSmartAnswer: Equatable {
    /// What the line shows ("8:00 PM", "3.10686 mi", "0xFF").
    var text: String
    /// The number behind it, when there is one, for Copy and variables.
    var value: Decimal?
}

struct CalculatorSmartContext {
    var now: Date = Date()
    var calendar: Calendar = .current
    var timeZone: TimeZone = .current
    var locale: Locale = .current
}

enum CalculatorSmartAnswers {
    static func answer(_ raw: String, context: CalculatorSmartContext = CalculatorSmartContext()) -> CalculatorSmartAnswer? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        while let last = text.last, "=?".contains(last) { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        for prefix in ["what is ", "what's ", "whats ", "how much is ", "convert ", "calculate "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !text.isEmpty else { return nil }
        return percentQuestion(text)
            ?? baseConversion(text)
            ?? unitConversion(text, context: context)
            ?? timeZoneAnswer(text, context: context)
            ?? relativeTime(text, context: context)
            ?? dateDifference(text, context: context)
            ?? dayOfWeek(text, context: context)
            ?? nowAnswer(text, context: context)
    }

    // MARK: Helpers

    private static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// A number written plainly or as a small expression ("1,200", "2*3").
    private static func number(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return CalculatorExpression.value(t)
    }

    private static func format(_ value: Decimal, locale: Locale) -> String {
        LocalCalculatorFormat.display(value, locale: locale).text
    }

    // MARK: Percent questions

    private static func percentQuestion(_ text: String) -> CalculatorSmartAnswer? {
        let num = #"(-?[\d.,]+)"#
        func ratio(_ part: Decimal, _ whole: Decimal) -> CalculatorSmartAnswer? {
            guard whole != 0 else { return nil }
            let percent = part / whole * 100
            return CalculatorSmartAnswer(text: format(percent, locale: .current) + "%", value: percent)
        }
        if let m = match(text, num + #" is what (?:percent|%) of "# + num),
           let a = number(m[1]), let b = number(m[2]) { return ratio(a, b) }
        if let m = match(text, #"what (?:percent|%) of "# + num + " is " + num),
           let b = number(m[1]), let a = number(m[2]) { return ratio(a, b) }
        if let m = match(text, num + #" as (?:a )?(?:percent|%|percentage) of "# + num),
           let a = number(m[1]), let b = number(m[2]) { return ratio(a, b) }
        if let m = match(text, #"(?:percent|%|percentage) (?:change|increase|decrease|difference) from "# + num + " to " + num)
            ?? match(text, num + " to " + num + #" (?:percent|%|percentage) change"#),
           let a = number(m[1]), let b = number(m[2]), a != 0 {
            let change = (b - a) / a.magnitude * 100
            return CalculatorSmartAnswer(text: (change > 0 ? "+" : "") + format(change, locale: .current) + "%", value: change)
        }
        return nil
    }

    // MARK: Number bases

    private static func baseConversion(_ text: String) -> CalculatorSmartAnswer? {
        func parse(_ literal: String) -> Int? {
            let t = literal.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
            if t.hasPrefix("0b") { return Int(t.dropFirst(2), radix: 2) }
            if t.hasPrefix("0o") { return Int(t.dropFirst(2), radix: 8) }
            return Int(t)
        }
        let bases: [String: (radix: Int, prefix: String)] = [
            "hex": (16, "0x"), "hexadecimal": (16, "0x"), "binary": (2, "0b"), "bin": (2, "0b"),
            "octal": (8, "0o"), "oct": (8, "0o"), "decimal": (10, ""), "dec": (10, ""),
        ]
        if let m = match(text, #"(0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+) (?:in|to|as) (hex|hexadecimal|binary|bin|octal|oct|decimal|dec)"#),
           let n = parse(m[1]), let base = bases[m[2]] {
            let digits = String(n, radix: base.radix, uppercase: true)
            return CalculatorSmartAnswer(text: base.prefix + digits, value: Decimal(n))
        }
        if let m = match(text, #"(0x[0-9a-f]+|0b[01]+|0o[0-7]+)"#), let n = parse(m[1]) {
            return CalculatorSmartAnswer(text: String(n), value: Decimal(n))
        }
        return nil
    }

    // MARK: Units

    private struct UnitEntry {
        let unit: Dimension
        let label: String
    }

    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    private static let pound = UnitMass(symbol: "lb", converter: UnitConverterLinear(coefficient: 0.45359237))
    private static let ounce = UnitMass(symbol: "oz", converter: UnitConverterLinear(coefficient: 0.028349523125))
    private static let year = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600))

    private static let units: [String: UnitEntry] = {
        var t: [String: UnitEntry] = [:]
        func add(_ unit: Dimension, _ label: String, _ names: [String]) {
            for n in names { t[n] = UnitEntry(unit: unit, label: label) }
        }
        add(UnitLength.meters, "m", ["m", "meter", "meters", "metre", "metres"])
        add(UnitLength.kilometers, "km", ["km", "kilometer", "kilometers", "kilometre", "kilometres", "kms"])
        add(UnitLength.centimeters, "cm", ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add(UnitLength.millimeters, "mm", ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add(UnitLength.miles, "mi", ["mi", "mile", "miles"])
        add(UnitLength.feet, "ft", ["ft", "foot", "feet"])
        add(UnitLength.inches, "in", ["inch", "inches", "\""])
        add(UnitLength.yards, "yd", ["yd", "yard", "yards"])
        add(UnitLength.nauticalMiles, "nmi", ["nmi", "nautical mile", "nautical miles"])
        add(UnitMass.kilograms, "kg", ["kg", "kgs", "kilogram", "kilograms", "kilo", "kilos"])
        add(UnitMass.grams, "g", ["g", "gram", "grams", "gm"])
        add(UnitMass.milligrams, "mg", ["mg", "milligram", "milligrams"])
        // Exact international pound (Foundation's rounds it to 0.453592 kg).
        add(pound, "lb", ["lb", "lbs", "pound", "pounds"])
        add(ounce, "oz", ["oz", "ounce", "ounces"])
        add(UnitMass.stones, "st", ["st", "stone", "stones"])
        add(UnitMass.metricTons, "t", ["t", "tonne", "tonnes", "metric ton", "metric tons"])
        add(UnitVolume.liters, "L", ["l", "liter", "liters", "litre", "litres"])
        add(UnitVolume.milliliters, "mL", ["ml", "milliliter", "milliliters", "millilitre", "millilitres"])
        add(UnitVolume.gallons, "gal", ["gal", "gallon", "gallons"])
        add(UnitVolume.quarts, "qt", ["qt", "quart", "quarts"])
        add(UnitVolume.pints, "pt", ["pint", "pints"])
        add(UnitVolume.cups, "cups", ["cup", "cups"])
        add(UnitVolume.fluidOunces, "fl oz", ["fl oz", "floz", "fluid ounce", "fluid ounces"])
        add(UnitVolume.tablespoons, "tbsp", ["tbsp", "tablespoon", "tablespoons"])
        add(UnitVolume.teaspoons, "tsp", ["tsp", "teaspoon", "teaspoons"])
        add(UnitTemperature.celsius, "°C", ["c", "°c", "celsius", "centigrade", "degrees c", "deg c"])
        add(UnitTemperature.fahrenheit, "°F", ["f", "°f", "fahrenheit", "degrees f", "deg f"])
        add(UnitTemperature.kelvin, "K", ["k", "kelvin"])
        add(UnitSpeed.milesPerHour, "mph", ["mph", "miles per hour", "mi/h"])
        add(UnitSpeed.kilometersPerHour, "km/h", ["km/h", "kmh", "kph", "kilometers per hour", "kilometres per hour"])
        add(UnitSpeed.metersPerSecond, "m/s", ["m/s", "meters per second", "metres per second"])
        add(UnitSpeed.knots, "kn", ["knot", "knots", "kn", "kt"])
        add(UnitArea.squareMeters, "m²", ["m2", "m²", "sq m", "square meter", "square meters", "square metre", "square metres"])
        add(UnitArea.squareKilometers, "km²", ["km2", "km²", "sq km", "square kilometer", "square kilometers"])
        add(UnitArea.squareFeet, "ft²", ["ft2", "ft²", "sq ft", "sqft", "square foot", "square feet"])
        add(UnitArea.acres, "ac", ["acre", "acres", "ac"])
        add(UnitArea.hectares, "ha", ["ha", "hectare", "hectares"])
        add(UnitArea.squareMiles, "mi²", ["mi2", "mi²", "sq mi", "square mile", "square miles"])
        add(UnitDuration.seconds, "s", ["s", "sec", "secs", "second", "seconds"])
        add(UnitDuration.minutes, "min", ["min", "mins", "minute", "minutes"])
        add(UnitDuration.hours, "h", ["h", "hr", "hrs", "hour", "hours"])
        add(day, "days", ["d", "day", "days"])
        add(week, "weeks", ["wk", "wks", "week", "weeks"])
        add(year, "years", ["yr", "yrs", "year", "years"])
        add(UnitInformationStorage.bytes, "B", ["b", "byte", "bytes"])
        add(UnitInformationStorage.bits, "bits", ["bit", "bits"])
        add(UnitInformationStorage.kilobytes, "KB", ["kb", "kilobyte", "kilobytes"])
        add(UnitInformationStorage.megabytes, "MB", ["mb", "megabyte", "megabytes"])
        add(UnitInformationStorage.gigabytes, "GB", ["gb", "gigabyte", "gigabytes", "gig", "gigs"])
        add(UnitInformationStorage.terabytes, "TB", ["tb", "terabyte", "terabytes"])
        add(UnitInformationStorage.kibibytes, "KiB", ["kib", "kibibyte", "kibibytes"])
        add(UnitInformationStorage.mebibytes, "MiB", ["mib", "mebibyte", "mebibytes"])
        add(UnitInformationStorage.gibibytes, "GiB", ["gib", "gibibyte", "gibibytes"])
        add(UnitEnergy.kilocalories, "kcal", ["kcal", "calorie", "calories", "cal", "kilocalorie", "kilocalories"])
        add(UnitEnergy.kilojoules, "kJ", ["kj", "kilojoule", "kilojoules"])
        add(UnitEnergy.joules, "J", ["j", "joule", "joules"])
        add(UnitEnergy.kilowattHours, "kWh", ["kwh", "kilowatt hour", "kilowatt hours"])
        add(UnitPressure.poundsForcePerSquareInch, "psi", ["psi"])
        add(UnitPressure.bars, "bar", ["bar", "bars"])
        add(UnitPressure.kilopascals, "kPa", ["kpa", "kilopascal", "kilopascals"])
        add(UnitPressure.hectopascals, "hPa", ["hpa", "hectopascal", "hectopascals", "mbar", "millibar"])
        return t
    }()

    private static func unit(_ name: String) -> UnitEntry? {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("degrees ") || n.hasPrefix("degree ") { n = "degrees " + n.split(separator: " ").dropFirst().joined(separator: " ") }
        return units[n] ?? units[n.replacingOccurrences(of: " ", with: "")]
    }

    private static func unitConversion(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        guard let m = match(text, #"(-?[\d.,]+(?:\s*[-+*/x×÷]\s*[\d.,]+)*)\s*([a-z°"][a-z0-9°"²³/ .]*?)\s+(?:in|to|into|as|=|->|→)\s+([a-z°"][a-z0-9°"²³/ .]*?)"#),
              let amount = number(m[1]), let from = unit(m[2]), let to = unit(m[3]),
              type(of: from.unit).baseUnit().symbol == type(of: to.unit).baseUnit().symbol else { return nil }
        let measurement = Measurement(value: NSDecimalNumber(decimal: amount).doubleValue, unit: from.unit)
        let converted = measurement.converted(to: to.unit).value
        guard converted.isFinite, let value = try? CalculatorNumber.decimal(converted) else { return nil }
        return CalculatorSmartAnswer(text: format(value, locale: context.locale) + " " + to.label, value: value)
    }

    // MARK: Time zones

    private static let fixedAbbreviations: [String: Double] = [
        "pst": -8, "pdt": -7, "mst": -7, "mdt": -6, "cst": -6, "cdt": -5, "est": -5, "edt": -4,
        "akst": -9, "akdt": -8, "hst": -10, "bst": 1, "cet": 1, "cest": 2, "eet": 2, "eest": 3, "wet": 0, "west": 1,
        "aest": 10, "aedt": 11, "acst": 9.5, "acdt": 10.5, "awst": 8, "nzst": 12, "nzdt": 13,
    ]

    private static let zoneAliases: [String: String] = [
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "mst": "America/Denver", "mdt": "America/Denver", "mt": "America/Denver", "mountain": "America/Denver",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "central": "America/Chicago",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "eastern": "America/New_York",
        "akst": "America/Anchorage", "hst": "Pacific/Honolulu",
        "gmt": "GMT", "utc": "UTC", "z": "UTC", "bst": "Europe/London", "uk": "Europe/London", "britain": "Europe/London",
        "cet": "Europe/Paris", "cest": "Europe/Paris", "eet": "Europe/Athens", "wet": "Europe/Lisbon",
        "ist": "Asia/Kolkata", "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata",
        "pune": "Asia/Kolkata", "kolkata": "Asia/Kolkata",
        "jst": "Asia/Tokyo", "japan": "Asia/Tokyo", "kst": "Asia/Seoul", "korea": "Asia/Seoul",
        "sgt": "Asia/Singapore", "hkt": "Asia/Hong_Kong", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "acst": "Australia/Adelaide", "awst": "Australia/Perth",
        "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland", "nz": "Pacific/Auckland",
        "gst": "Asia/Dubai", "uae": "Asia/Dubai", "pkt": "Asia/Karachi", "msk": "Europe/Moscow",
        "brt": "America/Sao_Paulo", "brazil": "America/Sao_Paulo",
        "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "silicon valley": "America/Los_Angeles", "cupertino": "America/Los_Angeles", "la": "America/Los_Angeles",
        "nyc": "America/New_York", "boston": "America/New_York", "miami": "America/New_York", "washington": "America/New_York",
        "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago",
        "germany": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid", "italy": "Europe/Rome",
        "canada": "America/Toronto", "us": "America/New_York", "usa": "America/New_York",
    ]

    /// A time zone named by an abbreviation, a city, a country or "here".
    static func zone(_ name: String, context: CalculatorSmartContext) -> TimeZone? {
        let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+time$"#, with: "", options: .regularExpression)
        guard !n.isEmpty else { return nil }
        if ["here", "local", "my time", "local time", "mine", "me"].contains(n) { return context.timeZone }
        // An explicit standard or daylight abbreviation is that fixed offset
        // all year ("PDT" in November is still UTC−7); city names and
        // generic ones ("PT") follow the seasons.
        if let hours = fixedAbbreviations[n] { return TimeZone(secondsFromGMT: Int(hours * 3600)) }
        if let id = zoneAliases[n] { return TimeZone(identifier: id) }
        if let m = match(n, #"(?:utc|gmt)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?"#) {
            let hours = Int(m[2]) ?? 0, minutes = Int(m[3]) ?? 0
            let seconds = (hours * 3600 + minutes * 60) * (m[1] == "-" ? -1 : 1)
            return TimeZone(secondsFromGMT: seconds)
        }
        let city = n.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().hasSuffix("/" + city) }) {
            return TimeZone(identifier: id)
        }
        return nil
    }

    /// "3pm", "3:30 pm", "15:30", "noon", "midnight" today in `zone`.
    private static func clockTime(_ text: String, in zone: TimeZone, context: CalculatorSmartContext) -> Date? {
        var calendar = context.calendar
        calendar.timeZone = zone
        let t = text.trimmingCharacters(in: .whitespaces)
        var hour: Int
        var minute = 0
        if t == "noon" || t == "midday" { hour = 12 } else if t == "midnight" { hour = 0 } else if t == "now" {
            return context.now
        } else if let m = match(t, #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#) {
            guard let h = Int(m[1]) else { return nil }
            hour = h
            minute = Int(m[2]) ?? 0
            let suffix = m[3].replacingOccurrences(of: ".", with: "")
            if suffix.isEmpty, m[2].isEmpty { return nil }   // a bare "3" isn't a time
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        } else {
            return nil
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: context.now)
    }

    private static func timeText(_ date: Date, in zone: TimeZone, context: CalculatorSmartContext, showZone: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = zone
        var calendar = context.calendar
        calendar.timeZone = zone
        var here = context.calendar
        here.timeZone = context.timeZone
        let sameDay = calendar.isDate(date, inSameDayAs: context.now)
            && here.component(.day, from: context.now) == calendar.component(.day, from: context.now)
        formatter.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "EEEjmm")
        let abbreviation = showZone ? (zone.abbreviation(for: date) ?? zone.identifier) : ""
        return formatter.string(from: date) + (abbreviation.isEmpty ? "" : " " + abbreviation)
    }

    private static func timeZoneAnswer(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        // "3pm pst in london", "15:30 utc to ist", "noon in tokyo" (from here)
        if let m = match(text, #"(.+?)\s+(?:in|to|into|as|->|→)\s+(.+)"#) {
            let left = m[1], target = m[2]
            if let to = zone(target, context: context) {
                // "<time> <zone>" or "<time>" (here)
                if let split = match(left, #"(now|noon|midnight|midday|\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?)\s*(.*)"#),
                   let from = split[2].isEmpty ? context.timeZone : zone(split[2], context: context),
                   let date = clockTime(split[1], in: from, context: context) {
                    return CalculatorSmartAnswer(text: timeText(date, in: to, context: context), value: nil)
                }
            }
        }
        // "time in tokyo", "tokyo time", "now in utc"
        if let m = match(text, #"(?:what )?(?:(?:current )?time|now)(?: is it)?(?: now)? (?:in|at) (.+)"#)
            ?? match(text, #"(.+) time(?: now)?"#),
           let to = zone(m[1], context: context) {
            return CalculatorSmartAnswer(text: timeText(context.now, in: to, context: context), value: nil)
        }
        return nil
    }

    // MARK: Relative times and dates

    private static let calendarUnits: [String: Calendar.Component] = [
        "second": .second, "seconds": .second, "sec": .second, "secs": .second, "s": .second,
        "minute": .minute, "minutes": .minute, "min": .minute, "mins": .minute, "m": .minute,
        "hour": .hour, "hours": .hour, "hr": .hour, "hrs": .hour, "h": .hour,
        "day": .day, "days": .day, "d": .day,
        "week": .weekOfYear, "weeks": .weekOfYear, "wk": .weekOfYear, "wks": .weekOfYear,
        "month": .month, "months": .month,
        "year": .year, "years": .year, "yr": .year, "yrs": .year,
    ]

    /// A date or time named in `text`: "now", "today", "tomorrow", "3pm", or one NSDataDetector finds.
    private static func anchor(_ text: String, context: CalculatorSmartContext,
                               past: Bool = false) -> (date: Date, hasTime: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        switch t {
        case "now", "": return (context.now, true)
        case "today": return (calendar.startOfDay(for: context.now), false)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: context.now)).map { ($0, false) }
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: context.now)).map { ($0, false) }
        default: break
        }
        if let date = clockTime(t, in: context.timeZone, context: context) { return (date, true) }
        if let date = namedDate(t, context: context, past: past) { return (date, false) }
        return nil
    }

    /// A date that comes round every year: a holiday, or a day and month with no year
    /// ("25 dec"), unlike "yesterday" or "4 july 2027".
    private static func isRecurring(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if holidays[t] != nil { return true }
        let months = #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#
        return t.range(of: months, options: .regularExpression) != nil
            && t.range(of: #"\d{4}"#, options: .regularExpression) == nil
    }

    private static let holidays: [String: (month: Int, day: Int)] = [
        "christmas": (12, 25), "xmas": (12, 25), "christmas day": (12, 25), "christmas eve": (12, 24),
        "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1), "new year's day": (1, 1), "new years day": (1, 1),
        "new year's eve": (12, 31), "new years eve": (12, 31), "halloween": (10, 31),
        "valentine's day": (2, 14), "valentines day": (2, 14), "valentines": (2, 14),
    ]

    /// Holidays and dates NSDataDetector reads ("25 dec", "july 4 2027", "next friday").
    /// A holiday is its next occurrence, or its last one when `past`
    /// ("days since christmas").
    private static func namedDate(_ text: String, context: CalculatorSmartContext, past: Bool = false) -> Date? {
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        if let h = holidays[text] {
            let year = calendar.component(.year, from: context.now)
            let today = calendar.startOfDay(for: context.now)
            for y in past ? [year, year - 1] : [year, year + 1] {
                if let d = calendar.date(from: DateComponents(year: y, month: h.month, day: h.day)),
                   past ? d <= today : d >= today { return d }
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = detector.firstMatch(in: text, range: range), result.range.length >= range.length - 1,
              let date = result.date else { return nil }
        // "since 25 dec": a yearless day comes round every year, so its last one.
        if past, isRecurring(text), date > context.now,
           let last = calendar.date(byAdding: .year, value: -1, to: date) { return last }
        return date
    }

    private static func dateText(_ date: Date, hasTime: Bool, context: CalculatorSmartContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: context.now)
        let template = (sameYear ? "EEEdMMM" : "EEEdMMMy") + (hasTime ? "jmm" : "")
        if hasTime, calendar.isDate(date, inSameDayAs: context.now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        return formatter.string(from: date)
    }

    private static func relativeTime(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        let amount = #"(\d+(?:\.\d+)?|a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|half an?)"#
        let unitPattern = #"(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|months?|years?|yrs?)"#
        func count(_ word: String) -> Double? {
            let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                           "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "fifteen": 15,
                                           "twenty": 20, "thirty": 30, "half a": 0.5, "half an": 0.5]
            return words[word] ?? Double(word)
        }
        func shifted(_ date: Date, _ n: Double, _ unitName: String) -> Date? {
            guard let component = calendarUnits[unitName] else { return nil }
            let seconds: [Calendar.Component: Double] = [.second: 1, .minute: 60, .hour: 3600]
            if let s = seconds[component] {
                guard n.isFinite, abs(n * s) <= 1e11 else { return nil }
                return date.addingTimeInterval(n * s)
            }
            if n == n.rounded() {
                // Whole counts only within a few thousand years: beyond that
                // `Int(n)` traps and Calendar has nothing to say.
                guard n.isFinite, abs(n) <= 10_000_000, let whole = Int(exactly: n) else { return nil }
                return calendar.date(byAdding: component, value: whole, to: date)
            }
            guard n.isFinite, abs(n) <= 10_000_000 else { return nil }
            if component == .day { return date.addingTimeInterval(n * 86_400) }
            if component == .weekOfYear { return date.addingTimeInterval(n * 604_800) }
            return nil
        }
        // "5 hours from now", "90 minutes after 3pm", "3 days before christmas", "2 weeks ago", "in 10 days"
        var n: Double?, unitName = "", sign = 1.0, base = "now"
        if let m = match(text, amount + #"\s*"# + unitPattern + #" (from|after|before|since|past) (.+)"#) {
            n = count(m[1]); unitName = m[2]; sign = m[3] == "before" ? -1 : 1; base = m[4]
        } else if let m = match(text, amount + #"\s*"# + unitPattern + " ago") {
            n = count(m[1]); unitName = m[2]; sign = -1
        } else if let m = match(text, #"in "# + amount + #"\s*"# + unitPattern) {
            n = count(m[1]); unitName = m[2]
        } else if let m = match(text, #"(now|today|tomorrow|\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*([+-])\s*"# + amount + #"\s*"# + unitPattern) {
            base = m[1]; sign = m[2] == "-" ? -1 : 1; n = count(m[3]); unitName = m[4]
        } else {
            return nil
        }
        guard let n, let start = anchor(base, context: context),
              let date = shifted(start.date, n * sign, unitName) else { return nil }
        let component = calendarUnits[unitName]
        // "in 10 days" is a date; "5 hours from now" and "3 days after 3pm" are times.
        let hasTime = [.second, .minute, .hour].contains(component) || (start.hasTime && base.trimmingCharacters(in: .whitespaces) != "now")
        return CalculatorSmartAnswer(text: dateText(date, hasTime: hasTime, context: context), value: nil)
    }

    private static func dateDifference(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        var calendar = context.calendar
        calendar.timeZone = context.timeZone
        func days(_ from: Date, _ to: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        }
        func phrase(_ count: Int, unit: String) -> CalculatorSmartAnswer {
            let word = count == 1 ? unit : unit + "s"
            return CalculatorSmartAnswer(text: "\(count) \(word)", value: Decimal(count))
        }
        let unitWords: [String: (divisor: Int, name: String)] = ["days": (1, "day"), "weeks": (7, "week"), "day": (1, "day"), "week": (7, "week")]
        if let m = match(text, #"(?:how many )?(days|weeks) (until|till|til|to|since|from) (.+)"#)
            ?? match(text, #"(?:how long) (until|till|til|since) (.+)"#).map({ ["", "days", $0[1], $0[2]] }),
           let unit = unitWords[m[1]], let target = anchor(m[3], context: context, past: ["since", "from"].contains(m[2])) {
            var d = days(context.now, target.date)
            if ["since", "from"].contains(m[2]) {
                d = -d
            } else if d < 0, isRecurring(m[3]), let next = calendar.date(byAdding: .year, value: 1, to: target.date) {
                // "days until 25 Dec" after this year's has passed: next year's.
                d = days(context.now, next)
            }
            // A date that has passed (or, "since", is still to come) says which way it lies.
            let answer = phrase(abs(d) / unit.divisor, unit: unit.name)
            guard d < 0 else { return answer }
            let ago = ["since", "from"].contains(m[2]) ? " from now" : " ago"
            return CalculatorSmartAnswer(text: answer.text + ago, value: answer.value)
        }
        if let m = match(text, #"(?:how many )?(days|weeks) between (.+) and (.+)"#), let unit = unitWords[m[1]],
           let a = anchor(m[2], context: context), let b = anchor(m[3], context: context) {
            return phrase(abs(days(a.date, b.date)) / unit.divisor, unit: unit.name)
        }
        return nil
    }

    private static func dayOfWeek(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        guard let m = match(text, #"(?:what|which) day (?:is|was|will be|of the week is) (.+)"#),
              let target = anchor(m[1], context: context) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return CalculatorSmartAnswer(text: formatter.string(from: target.date), value: nil)
    }

    private static func nowAnswer(_ text: String, context: CalculatorSmartContext) -> CalculatorSmartAnswer? {
        switch text {
        case "now", "time", "time now", "current time", "the time":
            return CalculatorSmartAnswer(text: timeText(context.now, in: context.timeZone, context: context, showZone: false), value: nil)
        case "today", "date", "today's date", "todays date", "the date":
            return CalculatorSmartAnswer(text: dateText(context.now, hasTime: false, context: context), value: nil)
        default:
            return nil
        }
    }
}
