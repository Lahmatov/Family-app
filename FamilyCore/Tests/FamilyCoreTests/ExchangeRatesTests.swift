import XCTest
@testable import FamilyCore

final class ExchangeRatesTests: XCTestCase {
    private let today = LocalDate("2026-10-04")!
    private let gbp = CurrencyCode("GBP")!

    func testRequestForASupportedPair() {
        let url = ExchangeRates.url(from: .usd, to: .eur, on: LocalDate("2026-10-01")!, today: today)
        XCTAssertEqual(url?.absoluteString, "https://api.frankfurter.dev/v1/2026-10-01?base=USD&symbols=EUR")
    }

    func testNoRequestWhenThereIsNothingToAsk() {
        XCTAssertNil(ExchangeRates.url(from: .eur, to: .eur, on: today, today: today), "same currency")
        XCTAssertNil(ExchangeRates.url(from: .rub, to: .eur, on: today, today: today), "the ECB does not publish RUB")
    }

    func testFutureDatesAskForToday() {
        let url = ExchangeRates.url(from: gbp, to: .eur, on: LocalDate("2026-12-31")!, today: today)
        XCTAssertEqual(url?.absoluteString, "https://api.frankfurter.dev/v1/2026-10-04?base=GBP&symbols=EUR")
    }

    /// Real responses, fetched on 2026-10-04.
    func testParsesRealResponsesWithAllDigits() {
        let weekday = Data(#"{"amount":1.0,"base":"USD","date":"2026-10-01","rates":{"EUR":0.88511}}"#.utf8)
        XCTAssertEqual(ExchangeRates.parse(weekday, to: .eur), ReferenceRate(rate: Decimal(string: "0.88511")!, publishedOn: LocalDate("2026-10-01")!))

        // Asked for Saturday 3 October: the ECB rate of Friday 2 October comes back, and that date is kept.
        let saturday = Data(#"{"amount":1.0,"base":"USD","date":"2026-10-02","rates":{"EUR":0.89087}}"#.utf8)
        XCTAssertEqual(ExchangeRates.parse(saturday, to: .eur)?.publishedOn, LocalDate("2026-10-02"))
    }

    func testRejectsErrorsAndNonsense() {
        XCTAssertNil(ExchangeRates.parse(Data(#"{"message":"not found"}"#.utf8), to: .eur))
        XCTAssertNil(ExchangeRates.parse(Data(#"{"date":"2026-10-02","rates":{"USD":1.12}}"#.utf8), to: .eur), "other currency")
        XCTAssertNil(ExchangeRates.parse(Data(#"{"date":"2026-10-02","rates":{"EUR":0}}"#.utf8), to: .eur), "zero")
        XCTAssertNil(ExchangeRates.parse(Data("<html>".utf8), to: .eur))
    }
}
