import Foundation
import XCTest
@testable import FamilyCore

final class CurrencyCodeTests: XCTestCase {
    func testValidation() {
        XCTAssertEqual(CurrencyCode(" eur ")?.rawValue, "EUR")
        XCTAssertNil(CurrencyCode("EU"))
        XCTAssertNil(CurrencyCode("EURO"))
        XCTAssertNil(CurrencyCode("E1R"))
        XCTAssertNil(CurrencyCode("ЕВР"))
    }

    func testExponentsMatchDatabase() {
        XCTAssertEqual(CurrencyCode.eur.minorUnitExponent, 2)
        XCTAssertEqual(CurrencyCode.jpy.minorUnitExponent, 0)
        XCTAssertEqual(CurrencyCode("KWD")!.minorUnitExponent, 3)
    }

    func testCodableRejectsGarbage() {
        let data = Data(#"["EUR","xx"]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([CurrencyCode].self, from: data))
    }
}

final class MoneyParsingTests: XCTestCase {
    private func parse(_ text: String, _ currency: CurrencyCode = .eur) throws -> Int64 {
        try Money(parsing: text, currency: currency).minorUnits
    }

    func testSimpleValues() throws {
        XCTAssertEqual(try parse("12"), 1200)
        XCTAssertEqual(try parse("12,5"), 1250)
        XCTAssertEqual(try parse("12.50"), 1250)
        XCTAssertEqual(try parse(",99"), 99)
        XCTAssertEqual(try parse("0"), 0)
        XCTAssertEqual(try parse("007,10"), 710)
    }

    func testGroupingSeparators() throws {
        XCTAssertEqual(try parse("1 234,56"), 123_456)
        XCTAssertEqual(try parse("1\u{00A0}234,56"), 123_456)
        XCTAssertEqual(try parse("1.234,56"), 123_456)  // pt-PT / ru style
        XCTAssertEqual(try parse("1,234.56"), 123_456)  // en style
        XCTAssertEqual(try parse("1.234"), 123_400)     // grouping, not 1.234 €
        XCTAssertEqual(try parse("1,234,567"), 123_456_700)
        XCTAssertEqual(try parse("1'234.50"), 123_450)
        XCTAssertEqual(try parse("12,505"), 1_250_500) // single separator + 3 digits = grouping
    }

    func testCurrencyExponent() throws {
        XCTAssertEqual(try parse("1500", .jpy), 1500)
        XCTAssertThrowsError(try parse("15,5", .jpy)) { error in
            XCTAssertEqual(error as? Money.ParseError, .tooManyFractionDigits(allowed: 0))
        }
        XCTAssertEqual(try parse("1.234", CurrencyCode("KWD")!), 1234)
    }

    func testRejectsInvalidInput() {
        for bad in ["", "   ", "-5", "12a", "1e5", "12,345,6.7.8", "1.2,3", "١٢", "1,23,456", "12.34.567", "∞", "0x10"] {
            XCTAssertThrowsError(try parse(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testRejectsOverflow() {
        XCTAssertThrowsError(try parse("99999999999999999999")) { error in
            XCTAssertEqual(error as? Money.ParseError, .outOfRange)
        }
    }

    func testArithmetic() throws {
        let a = Money(minorUnits: 150, currency: .eur)
        let b = Money(minorUnits: 50, currency: .eur)
        XCTAssertEqual(try a.adding(b).minorUnits, 200)
        XCTAssertEqual(try a.subtracting(b).minorUnits, 100)
        XCTAssertThrowsError(try a.adding(Money(minorUnits: 1, currency: .usd))) { error in
            XCTAssertEqual(error as? Money.ArithmeticError, .currencyMismatch)
        }
        XCTAssertThrowsError(try Money(minorUnits: .max, currency: .eur).adding(b)) { error in
            XCTAssertEqual(error as? Money.ArithmeticError, .overflow)
        }
    }

    func testDecimalValueAndFormatting() {
        let money = Money(minorUnits: 123_456, currency: .eur)
        XCTAssertEqual(money.decimalValue, Decimal(string: "1234.56"))
        let pt = money.formatted(locale: Locale(identifier: "pt_PT"))
        XCTAssertTrue(pt.contains("1234,56") || pt.contains("1 234,56") || pt.contains("1\u{00A0}234,56")
                      || pt.contains("1.234,56"), pt)
        XCTAssertTrue(pt.contains("€"), pt)
        let en = Money(minorUnits: 500, currency: .jpy).formatted(locale: Locale(identifier: "en_US"))
        XCTAssertFalse(en.contains("."), en)
    }
}

final class CurrencyConverterTests: XCTestCase {
    func testSameCurrencyIsIdentity() throws {
        let money = Money(minorUnits: 4550, currency: .eur)
        XCTAssertEqual(try CurrencyConverter.convert(money, to: .eur, rate: 5), money)
    }

    /// Same numbers as supabase/tests/030_budget.test.sql.
    func testMatchesDatabase() throws {
        XCTAssertEqual(try CurrencyConverter.convert(Money(minorUnits: 1000, currency: .usd), to: .eur,
                                                     rate: Decimal(string: "0.9")!).minorUnits, 900)
        XCTAssertEqual(try CurrencyConverter.convert(Money(minorUnits: 1000, currency: .jpy), to: .eur,
                                                     rate: Decimal(string: "0.0062")!).minorUnits, 620)
    }

    func testRoundsHalfAwayFromZero() throws {
        // 0.5 cent rounds up like Postgres round(numeric)
        XCTAssertEqual(try CurrencyConverter.convert(Money(minorUnits: 1, currency: .usd), to: .eur,
                                                     rate: Decimal(string: "1.5")!).minorUnits, 2)
        XCTAssertEqual(try CurrencyConverter.convert(Money(minorUnits: 1, currency: .usd), to: .eur,
                                                     rate: Decimal(string: "2.5")!).minorUnits, 3)
    }

    func testFromBaseWithMoreDecimals() throws {
        // 1.000 KWD -> EUR at 3.0 = 3.00 EUR
        XCTAssertEqual(try CurrencyConverter.convert(Money(minorUnits: 1000, currency: CurrencyCode("KWD")!),
                                                     to: .eur, rate: 3).minorUnits, 300)
    }

    func testRejectsBadRates() {
        let money = Money(minorUnits: 100, currency: .usd)
        XCTAssertThrowsError(try CurrencyConverter.convert(money, to: .eur, rate: 0))
        XCTAssertThrowsError(try CurrencyConverter.convert(money, to: .eur, rate: -1))
        XCTAssertThrowsError(try CurrencyConverter.convert(Money(minorUnits: 1, currency: .jpy), to: .eur,
                                                           rate: Decimal(string: "0.001")!)) { error in
            XCTAssertEqual(error as? CurrencyConverter.ConversionError, .resultTooSmall)
        }
    }
}
