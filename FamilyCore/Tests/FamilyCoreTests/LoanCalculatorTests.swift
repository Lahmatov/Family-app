import Foundation
import XCTest
@testable import FamilyCore

final class LoanCalculatorTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func mortgage(type: LoanType = .annuity) -> LoanTerms {
        LoanTerms(principal: 10_000_000, annualRate: dec("3.6"), termMonths: 360, firstPaymentOn: date("2026-11-01"), type: type)
    }

    private func assertConsistent(_ schedule: LoanSchedule, principal: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let rows = schedule.installments
        XCTAssertEqual(rows.reduce(0) { $0 + $1.principal + $1.extra }, principal, "principal is repaid exactly", file: file, line: line)
        XCTAssertEqual(rows.last?.balanceAfter, 0, file: file, line: line)
        XCTAssertTrue(rows.allSatisfy { $0.balanceAfter >= 0 && $0.interest >= 0 && $0.payment == $0.principal + $0.interest },
                      file: file, line: line)
        XCTAssertEqual(schedule.totalPaid - schedule.totalInterest, principal, file: file, line: line)
    }

    func testAnnuityMatchesTheClosedForm() {
        let schedule = LoanCalculator.schedule(mortgage())
        XCTAssertEqual(schedule.installments.count, 360)
        assertConsistent(schedule, principal: 10_000_000)

        // Independent check in floating point: 100 000 at 3.6 % over 30 years.
        let r = 0.036 / 12
        let expected = 10_000_000 * r / (1 - pow(1 + r, -360))
        XCTAssertEqual(Double(schedule.installments[0].payment), expected, accuracy: 1.0)
        XCTAssertEqual(schedule.installments[0].interest, 30_000, "first month: 100 000 × 0.3 %")
        XCTAssertEqual(schedule.installments[0].dueOn, date("2026-11-01"))
        XCTAssertEqual(schedule.installments[359].dueOn, date("2056-10-01"))
        XCTAssertEqual(schedule.payoffDate, date("2056-10-01"))
        // The final instalment absorbs rounding: a payment rounded by at most half a cent compounds at
        // 0.3 % a month over 360 months, i.e. at most 0.5 × ((1 + r)^360 − 1) / r ≈ 327 cents.
        let bound = 0.5 * (pow(1 + r, 360) - 1) / r
        XCTAssertLessThan(Double(abs(schedule.installments[359].payment - schedule.installments[0].payment)), bound)
    }

    func testZeroInterest() {
        let terms = LoanTerms(principal: 120_000, annualRate: 0, termMonths: 12, firstPaymentOn: date("2026-01-31"), type: .annuity)
        let schedule = LoanCalculator.schedule(terms)
        XCTAssertTrue(schedule.installments.allSatisfy { $0.payment == 10_000 && $0.interest == 0 })
        XCTAssertEqual(schedule.installments[1].dueOn, date("2026-02-28"), "month end is clamped")
        XCTAssertEqual(schedule.installments[2].dueOn, date("2026-03-31"), "...but not carried forward")
        assertConsistent(schedule, principal: 120_000)
    }

    func testDifferentiated() {
        let terms = LoanTerms(principal: 120_000, annualRate: 12, termMonths: 12, firstPaymentOn: date("2026-01-01"), type: .differentiated)
        let rows = LoanCalculator.schedule(terms).installments
        XCTAssertEqual(rows.map(\.principal), Array(repeating: 10_000, count: 12))
        XCTAssertEqual(rows[0].interest, 1_200, "1 % of 1 200.00")
        XCTAssertEqual(rows[11].interest, 100, "1 % of the last 100.00")
        XCTAssertGreaterThan(rows[0].payment, rows[11].payment, "payments decrease")
        assertConsistent(LoanSchedule(installments: rows), principal: 120_000)
    }

    func testExtraPaymentReduceTermKeepsInstalment() {
        let base = LoanCalculator.schedule(mortgage())
        let extras = [ExtraPayment(on: date("2027-01-15"), amount: 2_000_000, strategy: .reduceTerm)]
        let faster = LoanCalculator.schedule(mortgage(), extras: extras)
        assertConsistent(faster, principal: 10_000_000)
        XCTAssertLessThan(faster.installments.count, base.installments.count)
        XCTAssertEqual(faster.installments[10].payment, base.installments[10].payment, "instalment unchanged")
        XCTAssertEqual(faster.installments.first { $0.extra > 0 }?.extra, 2_000_000)
        XCTAssertGreaterThan(LoanCalculator.interestSaved(mortgage(), extras: extras), 0)
    }

    func testExtraPaymentReducePaymentKeepsTerm() {
        let base = LoanCalculator.schedule(mortgage())
        let extras = [ExtraPayment(on: date("2027-01-15"), amount: 2_000_000, strategy: .reducePayment)]
        let cheaper = LoanCalculator.schedule(mortgage(), extras: extras)
        assertConsistent(cheaper, principal: 10_000_000)
        XCTAssertEqual(cheaper.installments.count, 360)
        XCTAssertLessThan(cheaper.installments[10].payment, base.installments[10].payment)
        XCTAssertGreaterThan(LoanCalculator.interestSaved(mortgage(), extras: extras), 0)
    }

    func testRateChangeRecalculatesPaymentAndStillEndsOnTime() {
        let rises = [RateChange(effectiveFrom: date("2027-11-01"), annualRate: dec("5.1"))]
        let schedule = LoanCalculator.schedule(mortgage(), rateChanges: rises)
        assertConsistent(schedule, principal: 10_000_000)
        XCTAssertEqual(schedule.installments.count, 360)
        XCTAssertEqual(schedule.installments[0].payment, LoanCalculator.schedule(mortgage()).installments[0].payment)
        XCTAssertGreaterThan(schedule.installments[12].payment, schedule.installments[11].payment, "payment jumps at the review")
        XCTAssertGreaterThan(schedule.totalInterest, LoanCalculator.schedule(mortgage()).totalInterest)
    }

    func testOverpayingTheWholeBalanceEndsTheLoan() {
        let terms = LoanTerms(principal: 100_000, annualRate: 6, termMonths: 24, firstPaymentOn: date("2026-01-01"), type: .annuity)
        let rows = LoanCalculator.schedule(terms, extras: [ExtraPayment(on: date("2026-03-10"), amount: 9_999_999, strategy: .reduceTerm)]).installments
        XCTAssertEqual(rows.count, 4, "paid in full at the April instalment date")
        XCTAssertEqual(rows.last?.payment, 0)
        XCTAssertEqual(rows.last?.balanceAfter, 0)
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + $1.principal + $1.extra }, 100_000)
    }

    func testStatusNextAndOverdue() {
        let terms = LoanTerms(principal: 120_000, annualRate: 0, termMonths: 12, firstPaymentOn: date("2026-01-01"), type: .annuity)
        let schedule = LoanCalculator.schedule(terms)
        let status = LoanCalculator.status(schedule, paid: [1, 2], today: date("2026-05-15"))
        XCTAssertEqual(status.paidCount, 2)
        XCTAssertEqual(status.remainingBalance, 100_000)
        XCTAssertEqual(status.next?.number, 3)
        XCTAssertEqual(status.overdue.map(\.number), [3, 4, 5], "March, April and May are unpaid and past due")

        let done = LoanCalculator.status(schedule, paid: Set(1...12), today: date("2027-06-01"))
        XCTAssertEqual(done.remainingBalance, 0)
        XCTAssertNil(done.next)
        XCTAssertTrue(done.overdue.isEmpty)

        let fresh = LoanCalculator.status(schedule, paid: [], today: date("2025-12-01"))
        XCTAssertEqual(fresh.remainingBalance, 120_000)
        XCTAssertTrue(fresh.overdue.isEmpty)
    }

    func testDegenerateInput() {
        XCTAssertTrue(LoanCalculator.schedule(LoanTerms(principal: 0, annualRate: 3, termMonths: 12, firstPaymentOn: date("2026-01-01"), type: .annuity)).installments.isEmpty)
        XCTAssertEqual(LoanCalculator.annuityPayment(0, 3, 12), 0)
        XCTAssertEqual(LoanType.allCases.map(\.rawValue), ["annuity", "differentiated"])
        XCTAssertEqual(ExtraStrategy.allCases.map(\.rawValue), ["reduce_term", "reduce_payment"])
    }
}

final class PaymentRemindersTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }
    private let loan = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private var schedule: LoanSchedule {
        LoanCalculator.schedule(LoanTerms(principal: 120_000, annualRate: 0, termMonths: 12,
                                          firstPaymentOn: date("2026-01-10"), type: .annuity))
    }

    func testPlansTheNextUnpaidInstalments() {
        let specs = PaymentReminders.plan(loanId: loan, schedule: schedule, paid: [1, 2], today: date("2026-03-01"))
        XCTAssertEqual(specs.map(\.number), [3, 4, 5], "limited to three, skipping paid ones")
        XCTAssertEqual(specs[0].dueOn, date("2026-03-10"))
        XCTAssertEqual(specs[0].fireOn, date("2026-03-09"), "one day before by default")
        XCTAssertEqual(specs[0].amount, 10_000)
        XCTAssertEqual(specs[0].id, "loan.11111111-1111-1111-1111-111111111111.3")
    }

    func testNeverSchedulesInThePastAndSkipsPastDue() {
        let specs = PaymentReminders.plan(loanId: loan, schedule: schedule, paid: [], today: date("2026-03-10"), leadDays: 3, limit: 2)
        XCTAssertEqual(specs.map(\.number), [3, 4], "instalments due before today are not reminded")
        XCTAssertEqual(specs[0].fireOn, date("2026-03-10"), "lead time would be in the past: notify today")
        XCTAssertEqual(specs[1].fireOn, date("2026-04-07"))
    }

    func testNothingToRemindWhenFinished() {
        XCTAssertTrue(PaymentReminders.plan(loanId: loan, schedule: schedule, paid: Set(1...12), today: date("2026-02-01")).isEmpty)
        XCTAssertTrue(PaymentReminders.plan(loanId: loan, schedule: schedule, paid: [], today: date("2030-01-01")).isEmpty)
        XCTAssertTrue(PaymentReminders.plan(loanId: loan, schedule: schedule, paid: [], today: date("2026-01-01"), limit: 0).isEmpty)
    }
}
