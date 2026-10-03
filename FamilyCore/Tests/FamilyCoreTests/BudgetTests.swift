import Foundation
import XCTest
@testable import FamilyCore

final class BudgetCalculatorTests: XCTestCase {
    let family = UUID()
    let groceries = UUID()
    let transport = UUID()
    let october = YearMonth(year: 2026, month: 10)!

    private func expense(_ amount: Int64, _ category: UUID, _ date: String, kind: TransactionKind = .expense) -> Transaction {
        Transaction(id: UUID(), familyId: family, kind: kind, amountMinor: amount, currency: .eur, fxRate: 1,
                    amountBaseMinor: amount, categoryId: category, occurredOn: LocalDate(date)!,
                    merchant: nil, note: nil, paidBy: nil, isPrivate: false, createdBy: nil)
    }

    private func budget(_ amount: Int64, _ category: UUID?, _ from: String) -> Budget {
        Budget(id: UUID(), familyId: family, categoryId: category, amountMinor: amount, validFrom: LocalDate(from)!)
    }

    func testEffectiveBudgetPicksLatestApplicable() {
        let budgets = [
            budget(100, groceries, "2026-01-01"),
            budget(200, groceries, "2026-09-01"),
            budget(300, groceries, "2026-11-01"),
        ]
        XCTAssertEqual(BudgetCalculator.effectiveBudget(for: groceries, in: october, budgets: budgets)?.amountMinor, 200)
        XCTAssertNil(BudgetCalculator.effectiveBudget(for: transport, in: october, budgets: budgets))
        XCTAssertNil(BudgetCalculator.effectiveBudget(for: groceries, in: YearMonth(year: 2025, month: 12)!, budgets: budgets))
    }

    /// Same scenario as `budget_report` in supabase/tests/030_budget.test.sql.
    func testStatusesMatchServerReport() {
        let transactions = [
            expense(4550, groceries, "2026-10-01"),
            expense(900, groceries, "2026-10-02"),
            expense(620, groceries, "2026-10-03"),
            expense(100, groceries, "2026-10-04"),
            expense(500, groceries, "2026-10-06"),
            expense(99_999, groceries, "2026-09-30"),          // other month
            expense(500_000, groceries, "2026-10-10", kind: .income), // income ignored
        ]
        let budgets = [budget(50_000, groceries, "2026-09-01"), budget(300_000, nil, "2026-01-01")]

        let result = BudgetCalculator.statuses(month: october, baseCurrency: .eur, transactions: transactions,
                                               budgets: budgets, today: LocalDate("2026-11-15")!)
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result[0].categoryId)
        XCTAssertEqual(result[0].spent.minorUnits, 6670)
        XCTAssertEqual(result[0].limit?.minorUnits, 300_000)
        XCTAssertEqual(result[1].categoryId, groceries)
        XCTAssertEqual(result[1].spent.minorUnits, 6670)
        XCTAssertEqual(result[1].remaining?.minorUnits, 43_330)
        XCTAssertNil(result[1].projected, "no projection for a past month")
    }

    func testLevels() {
        let budgets = [budget(10_000, groceries, "2026-10-01"), budget(10_000, transport, "2026-10-01")]
        let transactions = [expense(8_000, groceries, "2026-10-01"), expense(10_001, transport, "2026-10-02")]
        let result = BudgetCalculator.statuses(month: october, baseCurrency: .eur, transactions: transactions,
                                               budgets: budgets, today: LocalDate("2026-12-01")!)
        let byCategory = Dictionary(uniqueKeysWithValues: result.map { ($0.categoryId, $0) })
        XCTAssertEqual(byCategory[groceries]?.level, .warning)
        XCTAssertEqual(byCategory[transport]?.level, .exceeded)
        XCTAssertEqual(byCategory[nil]?.level, .noBudget)
        XCTAssertEqual(result[1].categoryId, transport, "sorted by spend, descending")
    }

    func testBudgetedCategoryWithoutSpendIsListed() {
        let result = BudgetCalculator.statuses(month: october, baseCurrency: .eur, transactions: [],
                                               budgets: [budget(5_000, transport, "2026-10-01")],
                                               today: LocalDate("2026-10-02")!)
        XCTAssertEqual(result.map(\.categoryId), [nil, transport])
        XCTAssertEqual(result[1].level, .onTrack)
        XCTAssertEqual(result[1].spent.minorUnits, 0)
    }

    func testProjection() {
        let transactions = [expense(10_000, groceries, "2026-10-05")]
        let budgets = [budget(50_000, groceries, "2026-10-01")]
        let result = BudgetCalculator.statuses(month: october, baseCurrency: .eur, transactions: transactions,
                                               budgets: budgets, today: LocalDate("2026-10-05")!)
        // 100 € in 5 days -> 620 € over 31 days
        XCTAssertEqual(result[1].projected?.minorUnits, 62_000)
        XCTAssertTrue(result[1].projectedToExceed)
        XCTAssertEqual(result[1].level, .onTrack)
    }
}

final class TransactionDraftTests: XCTestCase {
    let category = UUID()
    let today = LocalDate("2026-10-02")!

    private func draft(_ amount: String, currency: CurrencyCode = .eur, rate: Decimal? = nil) -> TransactionDraft {
        TransactionDraft(amountText: amount, currency: currency, fxRate: rate, categoryId: category, occurredOn: today)
    }

    func testValidBaseCurrencyDraft() throws {
        var input = draft("12,50")
        input.merchant = "  Continente  "
        let validated = try input.validate(baseCurrency: .eur).get()
        XCTAssertEqual(validated.amount.minorUnits, 1250)
        XCTAssertEqual(validated.amountInBase.minorUnits, 1250)
        XCTAssertEqual(validated.fxRate, 1)
        XCTAssertEqual(validated.merchant, "Continente")
        XCTAssertNil(validated.note)
    }

    func testForeignCurrencyNeedsRate() throws {
        XCTAssertEqual(draft("10", currency: .usd).validate(baseCurrency: .eur), .failure(.fxRateMissing))
        XCTAssertEqual(draft("10", currency: .usd, rate: 0).validate(baseCurrency: .eur), .failure(.fxRateInvalid))
        let ok = try draft("10", currency: .usd, rate: Decimal(string: "0.9")).validate(baseCurrency: .eur).get()
        XCTAssertEqual(ok.amountInBase.minorUnits, 900)
    }

    func testAmountErrors() {
        XCTAssertEqual(draft("").validate(baseCurrency: .eur), .failure(.amountMissing))
        XCTAssertEqual(draft("abc").validate(baseCurrency: .eur), .failure(.amountInvalid))
        XCTAssertEqual(draft("0").validate(baseCurrency: .eur), .failure(.amountNotPositive))
        XCTAssertEqual(draft("1000000000").validate(baseCurrency: .eur), .failure(.amountTooLarge))
        XCTAssertEqual(draft("1,001").validate(baseCurrency: .eur), .success(try! draft("1001").validate(baseCurrency: .eur).get()))
    }

    func testOtherErrors() {
        var input = draft("5")
        input.categoryId = nil
        XCTAssertEqual(input.validate(baseCurrency: .eur), .failure(.categoryMissing))

        input = draft("5")
        input.note = String(repeating: "x", count: TransactionDraft.maxNoteLength + 1)
        XCTAssertEqual(input.validate(baseCurrency: .eur), .failure(.noteTooLong))

        input = draft("5")
        input.merchant = String(repeating: "x", count: TransactionDraft.maxMerchantLength + 1)
        XCTAssertEqual(input.validate(baseCurrency: .eur), .failure(.merchantTooLong))

        input = draft("5")
        input.occurredOn = LocalDate("1999-12-31")!
        XCTAssertEqual(input.validate(baseCurrency: .eur), .failure(.dateOutOfRange))
    }

    func testDecodesServerRow() throws {
        let json = """
        {"id":"7f1c2a8e-8d2e-4a43-9d7b-0c6d1d1f7a10","family_id":"2b1c2a8e-8d2e-4a43-9d7b-0c6d1d1f7a10",
         "kind":"expense","amount_minor":1000,"currency":"USD","fx_rate":0.9000000000,"amount_base_minor":900,
         "category_id":"3c1c2a8e-8d2e-4a43-9d7b-0c6d1d1f7a10","occurred_on":"2026-10-02","merchant":null,
         "note":"x","paid_by":null,"is_private":false,"created_by":null,"created_at":"2026-10-02T10:00:00.123+00:00"}
        """
        let txn = try JSONDecoder().decode(Transaction.self, from: Data(json.utf8))
        XCTAssertEqual(txn.amount, Money(minorUnits: 1000, currency: .usd))
        XCTAssertEqual(txn.amountBaseMinor, 900)
        XCTAssertEqual(txn.occurredOn.description, "2026-10-02")
        XCTAssertEqual(txn.fxRate, Decimal(string: "0.9"))
    }
}
