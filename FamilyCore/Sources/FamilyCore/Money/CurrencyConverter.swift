import Foundation

/// Converts between currencies with the same rounding as the database trigger
/// `private.transactions_before_write` (half away from zero), so the amount the
/// app previews is exactly the amount the server stores.
public enum CurrencyConverter {
    public enum ConversionError: Error, Equatable {
        case invalidRate
        case resultTooSmall
        case overflow
    }

    /// - Parameter rate: units of `base` per 1 unit of `money.currency`.
    public static func convert(_ money: Money, to base: CurrencyCode, rate: Decimal) throws -> Money {
        if money.currency == base { return money }
        guard rate > 0 else { throw ConversionError.invalidRate }

        let shift = base.minorUnitExponent - money.currency.minorUnitExponent
        var value = Decimal(money.minorUnits) * rate
        if shift >= 0 {
            value *= Money.pow10(shift)
        } else {
            value /= Money.pow10(-shift)
        }

        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)

        guard rounded <= Decimal(Int64.max) else { throw ConversionError.overflow }
        let minor = NSDecimalNumber(decimal: rounded).int64Value
        guard minor > 0 || money.minorUnits == 0 else { throw ConversionError.resultTooSmall }
        return Money(minorUnits: minor, currency: base)
    }
}
