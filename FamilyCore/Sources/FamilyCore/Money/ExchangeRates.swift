import Foundation

/// A daily reference rate of the European Central Bank, as published by Frankfurter (free, no key).
public struct ReferenceRate: Equatable, Sendable {
    /// Units of the target currency per 1 unit of the source currency (the meaning of `fx_rate`).
    public let rate: Decimal
    /// The ECB publishes on working days only; a weekend or holiday gets the previous working day's rate.
    public let publishedOn: LocalDate
}

public enum ExchangeRates {
    /// Currencies the ECB publishes reference rates for (`/v1/currencies`). RUB, for example, is not among them,
    /// so such a rate stays a manual entry.
    public static let supported: Set<String> = [
        "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD", "HUF", "IDR", "ILS", "INR", "ISK",
        "JPY", "KRW", "MXN", "MYR", "NOK", "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR",
    ]

    /// The request for the rate of `from` in `to` on `day` (clamped to `today`: there are no future rates).
    /// Only the currency pair and the date leave the device.
    public static func url(from: CurrencyCode, to: CurrencyCode, on day: LocalDate, today: LocalDate) -> URL? {
        guard from != to, supported.contains(from.rawValue), supported.contains(to.rawValue) else { return nil }
        let date = min(day, today)
        return URL(string: "https://api.frankfurter.dev/v1/\(date)?base=\(from.rawValue)&symbols=\(to.rawValue)")
    }

    /// Reads `{"base":"USD","date":"2026-10-02","rates":{"EUR":0.89087}}`. The number is taken from the text so it
    /// keeps every published digit (a Double would not).
    public static func parse(_ data: Data, to: CurrencyCode) -> ReferenceRate? {
        guard let text = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dateText = object["date"] as? String, let date = LocalDate(dateText),
              let regex = try? NSRegularExpression(pattern: #""\#(to.rawValue)"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let rate = Decimal(string: String(text[range]), locale: Locale(identifier: "en_US_POSIX")),
              rate > 0, rate < 1_000_000   // the database CHECK on fx_rate
        else { return nil }
        return ReferenceRate(rate: rate, publishedOn: date)
    }
}
