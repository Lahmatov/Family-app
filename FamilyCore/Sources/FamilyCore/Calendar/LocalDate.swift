import Foundation

/// A calendar date without time zone (Postgres `date`), encoded as "yyyy-MM-dd".
public struct LocalDate: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...Self.daysIn(year: year, month: month)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The date of `date` as seen in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!
        self.month = c.month!
        self.day = c.day!
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Calendar-month arithmetic; the day is clamped (Jan 31 + 1 month = Feb 28/29).
    public func adding(months: Int) -> LocalDate? {
        let target = YearMonth(self).adding(months: months)
        return LocalDate(year: target.year, month: target.month, day: min(day, target.numberOfDays))
    }

    public func adding(days: Int) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return LocalDate(calendar.date(byAdding: .day, value: days, to: base)!, timeZone: calendar.timeZone)
    }

    /// Whole days from `self` to `other` (negative if `other` is earlier).
    public func days(until other: LocalDate) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let a = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let b = calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
        return calendar.dateComponents([.day], from: a, to: b).day!
    }

    /// ISO weekday: Monday = 1 ... Sunday = 7 (2000-01-03 was a Monday).
    public var isoWeekday: Int {
        let offset = LocalDate(year: 2000, month: 1, day: 3)!.days(until: self)
        return ((offset % 7) + 7) % 7 + 1
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 0
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let date = LocalDate(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid date \(raw)"))
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A calendar month, e.g. 2026-10.
public struct YearMonth: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    public init(_ date: LocalDate) {
        year = date.year
        month = date.month
    }

    public var firstDay: LocalDate { LocalDate(year: year, month: month, day: 1)! }
    public var numberOfDays: Int { LocalDate.daysIn(year: year, month: month) }

    public func contains(_ date: LocalDate) -> Bool {
        date.year == year && date.month == month
    }

    public func adding(months: Int) -> YearMonth {
        let index = year * 12 + (month - 1) + months
        return YearMonth(year: index / 12, month: index % 12 + 1)!
    }

    public var description: String { String(format: "%04d-%02d", year, month) }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}
