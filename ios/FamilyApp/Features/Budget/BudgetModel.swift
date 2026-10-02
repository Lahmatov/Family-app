import FamilyCore
import Foundation
import Observation

/// State of the budget screen for one family and month.
@MainActor
@Observable
final class BudgetModel {
    private(set) var month: YearMonth
    private(set) var categories: [FamilyCore.Category] = []
    private(set) var transactions: [Transaction] = []
    private(set) var budgets: [Budget] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    let role: MemberRole
    private let service: any BudgetServicing
    private let today: () -> LocalDate

    init(family: Family, role: MemberRole, service: any BudgetServicing,
         today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.role = role
        self.service = service
        self.today = today
        self.month = YearMonth(today())
    }

    var statuses: [BudgetStatus] {
        BudgetCalculator.statuses(month: month, baseCurrency: family.baseCurrency,
                                  transactions: transactions, budgets: budgets, today: today())
    }

    var overall: BudgetStatus? { statuses.first }

    var income: Money {
        Money(minorUnits: transactions.filter { $0.kind == .income }.map(\.amountBaseMinor).reduce(0, +),
              currency: family.baseCurrency)
    }

    var canGoForward: Bool { month < YearMonth(today()) }

    func category(_ id: UUID?) -> FamilyCore.Category? {
        categories.first { $0.id == id }
    }

    func expenseCategories() -> [FamilyCore.Category] { categories.filter { $0.kind == .expense } }

    func showPreviousMonth() async {
        month = month.adding(months: -1)
        await load()
    }

    func showNextMonth() async {
        guard canGoForward else { return }
        month = month.adding(months: 1)
        await load()
    }

    func load() async {
        guard role.can(.viewFinance) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let categoriesRequest = service.categories(familyId: family.id)
            async let transactionsRequest = service.transactions(familyId: family.id, month: month)
            async let budgetsRequest = service.budgets(familyId: family.id)
            (categories, transactions, budgets) = try await (categoriesRequest, transactionsRequest, budgetsRequest)
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .unknown
        }
    }

    func add(_ input: TransactionDraft.Validated, receipt: ReceiptUpload?) async throws {
        try await service.addTransaction(familyId: family.id, input, receipt: receipt)
        await load()
    }

    func delete(_ transaction: Transaction) async {
        do {
            try await service.deleteTransaction(transaction)
            transactions.removeAll { $0.id == transaction.id }
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .unknown
        }
    }

    func setBudget(categoryId: UUID?, amount: Money) async throws {
        try await service.setBudget(familyId: family.id, categoryId: categoryId,
                                    amountMinor: amount.minorUnits, from: month)
        await load()
    }

    struct DayGroup: Identifiable {
        let day: LocalDate
        let items: [Transaction]
        var id: LocalDate { day }
    }

    /// Transactions grouped by day, newest first.
    var groupedByDay: [DayGroup] {
        Dictionary(grouping: transactions, by: \.occurredOn)
            .map { DayGroup(day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }
}
