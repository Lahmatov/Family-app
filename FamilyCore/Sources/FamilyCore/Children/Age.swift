import Foundation

/// Age of a child on a given day, in completed years and months.
public struct Age: Equatable, Sendable {
    public let years: Int
    public let months: Int // 0...11 after the years
    public var totalMonths: Int { years * 12 + months }

    public init?(birth: LocalDate, on day: LocalDate) {
        guard birth <= day else { return nil }
        var total = (day.year - birth.year) * 12 + (day.month - birth.month)
        if day.day < birth.day { total -= 1 }
        years = total / 12
        months = total % 12
    }
}
