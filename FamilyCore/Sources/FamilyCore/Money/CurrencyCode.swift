import Foundation

/// ISO 4217 currency code, validated and upper-cased.
public struct CurrencyCode: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return nil
        }
        rawValue = code
    }

    public static let eur = CurrencyCode("EUR")!
    public static let usd = CurrencyCode("USD")!
    public static let gbp = CurrencyCode("GBP")!
    public static let rub = CurrencyCode("RUB")!
    public static let jpy = CurrencyCode("JPY")!

    /// Number of minor-unit digits. Must match `private.currency_exponent` in the database.
    public var minorUnitExponent: Int {
        if Self.zeroDecimal.contains(rawValue) { return 0 }
        if Self.threeDecimal.contains(rawValue) { return 3 }
        return 2
    }

    public var description: String { rawValue }

    private static let zeroDecimal: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
        "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
    ]
    private static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let code = CurrencyCode(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid currency code \(raw)"))
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
