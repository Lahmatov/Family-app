import FamilyCore
import Foundation
import Observation

/// Schedules the local "payment due" notifications. A protocol so the model is testable
/// and so the iOS notification centre stays out of the logic.
protocol ReminderScheduling: Sendable {
    /// Replaces all pending loan reminders with `reminders` (title/body are built by the scheduler).
    func replaceLoanReminders(_ reminders: [(loan: Loan, spec: ReminderSpec)]) async
    func clearLoanReminders() async
}

struct NoReminders: ReminderScheduling {
    func replaceLoanReminders(_ reminders: [(loan: Loan, spec: ReminderSpec)]) async {}
    func clearLoanReminders() async {}
}

@MainActor
@Observable
final class LoansModel {
    private(set) var loans: [Loan] = []
    private(set) var overviews: [LoanOverview] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any LoanServicing
    private let reminders: any ReminderScheduling
    private let today: () -> LocalDate
    private var rates: [LoanRateChangeRow] = []
    private var extras: [LoanExtraRow] = []
    private var paid: [LoanPaidRow] = []

    init(family: Family, service: any LoanServicing, reminders: any ReminderScheduling = NoReminders(),
         today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.service = service
        self.reminders = reminders
        self.today = today
    }

    func overview(_ loan: Loan) -> LoanOverview? { overviews.first { $0.loan.id == loan.id } }
    func paidNumbers(_ loan: Loan) -> Set<Int> { Set(paid.filter { $0.loanId == loan.id }.map(\.installmentNo)) }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let l = service.loans(familyId: family.id)
            async let r = service.rateChanges(familyId: family.id)
            async let e = service.extras(familyId: family.id)
            async let p = service.payments(familyId: family.id)
            (loans, rates, extras, paid) = try await (l, r, e, p)
            rebuild()
        }
    }

    func add(_ loan: NewLoan) async throws {
        try await service.add(familyId: family.id, loan)
        await load()
    }

    func addRateChange(_ loan: Loan, from: LocalDate, annualRate: Decimal) async throws {
        try await service.addRateChange(familyId: family.id, loanId: loan.id, from: from, annualRate: annualRate)
        await load()
    }

    func addExtra(_ loan: Loan, amountMinor: Int64, strategy: ExtraStrategy) async throws {
        try await service.addExtra(familyId: family.id, loanId: loan.id, on: today(), amountMinor: amountMinor, strategy: strategy)
        await load()
    }

    func setPaid(_ loan: Loan, number: Int, paid isPaid: Bool) async {
        await perform {
            try await service.setPaid(familyId: family.id, loanId: loan.id, number: number, paid: isPaid, on: today())
            paid = try await service.payments(familyId: family.id)
            rebuild()
        }
    }

    func delete(_ loan: Loan) async {
        await perform {
            try await service.delete(loan)
            await load()
        }
    }

    /// Rebuilds the local notifications from the current state; call after `load()`.
    func scheduleReminders(enabled: Bool) async {
        guard enabled else { return await reminders.clearLoanReminders() }
        let specs = overviews.flatMap { item in
            PaymentReminders.plan(loanId: item.loan.id, schedule: item.schedule, paid: paidNumbers(item.loan), today: today())
                .map { (loan: item.loan, spec: $0) }
        }
        await reminders.replaceLoanReminders(specs)
    }

    private func rebuild() {
        let now = today()
        overviews = loans.map { loan in
            let loanRates = rates.filter { $0.loanId == loan.id }.map { RateChange(effectiveFrom: $0.effectiveFrom, annualRate: $0.annualRate) }
            let loanExtras = extras.filter { $0.loanId == loan.id }.map { ExtraPayment(on: $0.paidOn, amount: $0.amountMinor, strategy: $0.strategy) }
            let schedule = LoanCalculator.schedule(loan.terms, rateChanges: loanRates, extras: loanExtras)
            return LoanOverview(
                loan: loan, schedule: schedule,
                status: LoanCalculator.status(schedule, paid: paidNumbers(loan), today: now),
                interestSaved: loanExtras.isEmpty ? 0 : LoanCalculator.interestSaved(loan.terms, rateChanges: loanRates, extras: loanExtras))
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
