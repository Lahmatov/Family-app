import FamilyCore
import XCTest
@testable import FamilyApp

private actor RecordingScheduler: ReminderScheduling {
    private(set) var scheduled: [ReminderSpec] = []
    private(set) var clears = 0
    func replaceLoanReminders(_ reminders: [(loan: Loan, spec: ReminderSpec)]) async { scheduled = reminders.map(\.spec) }
    func clearLoanReminders() async { clears += 1 }
}

@MainActor
final class LoansModelTests: XCTestCase {
    private func makeModel(today: String = "2026-03-10") async throws -> (LoansModel, RecordingScheduler) {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let scheduler = RecordingScheduler()
        let day = LocalDate(today)!
        return (LoansModel(family: family, service: services.loans, reminders: scheduler, today: { day }), scheduler)
    }

    private let newLoan = NewLoan(title: "Car", lender: "Bank", principalMinor: 120_000, currency: .eur, annualRate: 0,
                                  termMonths: 12, firstPaymentOn: LocalDate("2026-01-10")!, type: .annuity)

    func testStatusPaidAndOverdue() async throws {
        let (model, _) = try await makeModel()
        try await model.add(newLoan)
        let loan = try XCTUnwrap(model.loans.first)

        var overview = try XCTUnwrap(model.overview(loan))
        XCTAssertEqual(overview.status.overdue.map(\.number), [1, 2], "January and February are unpaid and past; March 10 is due today, not overdue")
        XCTAssertEqual(overview.status.remainingBalance, 120_000)

        await model.setPaid(loan, number: 1, paid: true)
        await model.setPaid(loan, number: 2, paid: true)
        overview = try XCTUnwrap(model.overview(loan))
        XCTAssertEqual(overview.status.paidCount, 2)
        XCTAssertEqual(overview.status.remainingBalance, 100_000)
        XCTAssertEqual(overview.progress, 1.0 / 6, accuracy: 1e-9)

        await model.setPaid(loan, number: 2, paid: false)
        XCTAssertEqual(try XCTUnwrap(model.overview(loan)).status.paidCount, 1, "a mark can be removed")
    }

    func testExtraPaymentAndRateChangeAffectTheSchedule() async throws {
        let (model, _) = try await makeModel()
        try await model.add(NewLoan(title: "Mortgage", lender: nil, principalMinor: 10_000_000, currency: .eur, annualRate: 3,
                                    termMonths: 120, firstPaymentOn: LocalDate("2026-04-01")!, type: .annuity))
        let loan = try XCTUnwrap(model.loans.first)
        let before = try XCTUnwrap(model.overview(loan)).schedule
        XCTAssertEqual(before.installments.count, 120)

        try await model.addExtra(loan, amountMinor: 2_000_000, strategy: .reduceTerm)
        var after = try XCTUnwrap(model.overview(loan))
        XCTAssertLessThan(after.schedule.installments.count, 120)
        XCTAssertGreaterThan(after.interestSaved, 0)

        try await model.addRateChange(loan, from: LocalDate("2027-01-01")!, annualRate: 5)
        after = try XCTUnwrap(model.overview(loan))
        XCTAssertGreaterThan(after.schedule.totalInterest, 0)
        do {
            try await model.addRateChange(loan, from: LocalDate("2027-01-01")!, annualRate: 6)
            XCTFail("two rate changes on one date must be refused")
        } catch { XCTAssertEqual(error as? AppError, .conflict) }
    }

    func testRemindersAreBuiltFromUnpaidInstalments() async throws {
        let (model, scheduler) = try await makeModel(today: "2026-03-01")
        try await model.add(newLoan)
        let loan = try XCTUnwrap(model.loans.first)
        await model.setPaid(loan, number: 1, paid: true)

        await model.scheduleReminders(enabled: true)
        let numbers = await scheduler.scheduled.map(\.number)
        XCTAssertEqual(numbers, [3, 4, 5], "February is already past, so the plan starts with the March 10 instalment")
        await model.scheduleReminders(enabled: false)
        let clears = await scheduler.clears
        XCTAssertEqual(clears, 1)
    }

    func testDeleteRemovesTheLoan() async throws {
        let (model, _) = try await makeModel()
        try await model.add(newLoan)
        await model.delete(try XCTUnwrap(model.loans.first))
        XCTAssertTrue(model.loans.isEmpty)
        XCTAssertTrue(model.overviews.isEmpty)
    }
}
