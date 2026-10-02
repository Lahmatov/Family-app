import Foundation

/// An exact amount of money in integer minor units (e.g. cents).
/// Never use floating point for money.
public struct Money: Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: CurrencyCode

    public init(minorUnits: Int64, currency: CurrencyCode) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public static func zero(_ currency: CurrencyCode) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    /// Decimal value in major units (e.g. 12.34 for 1234 cents).
    public var decimalValue: Decimal {
        Decimal(minorUnits) / Self.pow10(currency.minorUnitExponent)
    }

    public enum ParseError: Error, Equatable {
        case empty
        case invalidFormat
        case tooManyFractionDigits(allowed: Int)
        case outOfRange
    }

    /// Parses user input such as "12,50", "12.5", "1 234,56", "1,234.56", "1.234".
    ///
    /// Rules:
    /// * spaces, NBSP and apostrophes are grouping and ignored;
    /// * if both `.` and `,` occur, the last one is the decimal separator;
    /// * a single kind of separator occurring more than once is grouping;
    /// * a single separator followed by exactly 3 digits is grouping
    ///   ("1.234" == 1234) unless the currency itself has 3 decimals;
    /// * otherwise a single separator is the decimal separator.
    /// Negative values are rejected (direction is expressed by the transaction kind).
    public init(parsing input: String, currency: CurrencyCode) throws {
        let ignored: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "'"]
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).filter { !ignored.contains($0) }
        guard !text.isEmpty else { throw ParseError.empty }
        guard text.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "," }) else {
            throw ParseError.invalidFormat
        }

        let exponent = currency.minorUnitExponent
        let separators = text.filter { $0 == "." || $0 == "," }
        var integerPart = text
        var fractionPart = ""

        if let decimalIndex = text.lastIndex(where: { $0 == "." || $0 == "," }) {
            let decimalChar = text[decimalIndex]
            let after = String(text[text.index(after: decimalIndex)...])
            let before = String(text[..<decimalIndex])
            let kinds = Set(separators)

            let isDecimal: Bool
            if kinds.count == 2 {
                // The decimal separator must not appear in the integer part.
                guard !before.contains(decimalChar) else { throw ParseError.invalidFormat }
                isDecimal = true
            } else if separators.count > 1 {
                isDecimal = false
            } else {
                isDecimal = !(after.count == 3 && exponent < 3)
            }

            let grouped = isDecimal ? before : text
            guard Self.hasValidGrouping(grouped) else { throw ParseError.invalidFormat }
            integerPart = grouped.filter { $0 != "." && $0 != "," }
            fractionPart = isDecimal ? after : ""
        }

        guard !integerPart.isEmpty || !fractionPart.isEmpty else { throw ParseError.invalidFormat }
        guard fractionPart.count <= exponent else {
            throw ParseError.tooManyFractionDigits(allowed: exponent)
        }
        let paddedFraction = fractionPart.padding(toLength: exponent, withPad: "0", startingAt: 0)
        var digits = (integerPart.isEmpty ? "0" : integerPart) + paddedFraction
        while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count <= 15, let value = Int64(digits) else { throw ParseError.outOfRange }
        self.init(minorUnits: value, currency: currency)
    }

    /// "1.234.567" is fine, "1.2.3" or "12.34.567" are not.
    private static func hasValidGrouping(_ text: String) -> Bool {
        let groups = text.split(separator: ".", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard groups.count > 1 else { return true }
        guard let first = groups.first, (1...3).contains(first.count) else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 }
    }

    public enum ArithmeticError: Error, Equatable {
        case currencyMismatch
        case overflow
    }

    public func adding(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw ArithmeticError.currencyMismatch }
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw ArithmeticError.overflow }
        return Money(minorUnits: sum, currency: currency)
    }

    public func subtracting(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw ArithmeticError.currencyMismatch }
        let (diff, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw ArithmeticError.overflow }
        return Money(minorUnits: diff, currency: currency)
    }

    /// Localised representation, e.g. "12,50 €" for pt-PT / ru, "€12.50" for en.
    public func formatted(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency.rawValue
        formatter.minimumFractionDigits = currency.minorUnitExponent
        formatter.maximumFractionDigits = currency.minorUnitExponent
        return formatter.string(from: decimalValue as NSDecimalNumber) ?? "\(decimalValue) \(currency)"
    }

    static func pow10(_ n: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<max(0, n) { result *= 10 }
        return result
    }
}

extension Money: Comparable {
    /// Ordering is only meaningful within one currency; mixed currencies order by code.
    public static func < (lhs: Money, rhs: Money) -> Bool {
        if lhs.currency != rhs.currency { return lhs.currency.rawValue < rhs.currency.rawValue }
        return lhs.minorUnits < rhs.minorUnits
    }
}
