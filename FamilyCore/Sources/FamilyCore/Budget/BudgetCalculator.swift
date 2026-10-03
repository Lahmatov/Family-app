import Foundation

/// Spending against a budget for one category (or overall) in one month.
public struct BudgetStatus: Hashable, Sendable {
    public enum Level: Sendable, Equatable {
        case noBudget
        case onTrack
        /// Spent ≥ `warningThreshold` of the limit.
        case warning
        case exceeded
    }

    /// nil = overall family budget.
    public let categoryId: UUID?
    public let spent: Money
    public let limit: Money?
    /// Linear projection of spending at month end (only for the current month).
    public let projected: Money?

    public var remaining: Money? {
        limit.map { Money(minorUnits: $0.minorUnits - spent.minorUnits, currency: spent.currency) }
    }

    /// 0.0 ... (can exceed 1.0)
    public var progress: Double? {
        guard let limit, limit.minorUnits > 0 else { return nil }
        return Double(spent.minorUnits) / Double(limit.minorUnits)
    }

    public var level: Level {
        guard let progress else { return .noBudget }
        if progress > 1 { return .exceeded }
        if progress >= BudgetCalculator.warningThreshold { return .warning }
        return .onTrack
    }

    /// True when the month is on pace to exceed the limit even if it hasn't yet.
    public var projectedToExceed: Bool {
        guard let limit, let projected else { return false }
        return projected.minorUnits > limit.minorUnits
    }
}

public enum BudgetCalculator {
    public static let warningThreshold = 0.8

    /// The budget row in effect for `month`: the latest one with `validFrom <= month start`.
    public static func effectiveBudget(for categoryId: UUID?, in month: YearMonth, budgets: [Budget]) -> Budget? {
        budgets
            .filter { $0.categoryId == categoryId && $0.validFrom <= month.firstDay }
            .max { $0.validFrom < $1.validFrom }
    }

    /// Computes per-category statuses plus one overall status (categoryId == nil, always first).
    ///
    /// - Parameters:
    ///   - today: used for projection; projection is only produced when `today` is inside `month`.
    public static func statuses(
        month: YearMonth,
        baseCurrency: CurrencyCode,
        transactions: [Transaction],
        budgets: [Budget],
        today: LocalDate
    ) -> [BudgetStatus] {
        let expenses = transactions.filter { $0.kind == .expense && month.contains($0.occurredOn) }

        var spentByCategory: [UUID: Int64] = [:]
        for txn in expenses {
            spentByCategory[txn.categoryId, default: 0] += txn.amountBaseMinor
        }
        let total = spentByCategory.values.reduce(0, +)

        let budgetedCategories = Set(budgets.compactMap(\.categoryId)).filter {
            effectiveBudget(for: $0, in: month, budgets: budgets) != nil
        }
        let categories = budgetedCategories.union(spentByCategory.keys)

        func status(_ categoryId: UUID?, spent: Int64) -> BudgetStatus {
            let budget = effectiveBudget(for: categoryId, in: month, budgets: budgets)
            return BudgetStatus(
                categoryId: categoryId,
                spent: Money(minorUnits: spent, currency: baseCurrency),
                limit: budget.map { Money(minorUnits: $0.amountMinor, currency: baseCurrency) },
                projected: projection(spent: spent, month: month, today: today)
                    .map { Money(minorUnits: $0, currency: baseCurrency) }
            )
        }

        let perCategory = categories
            .map { status($0, spent: spentByCategory[$0] ?? 0) }
            .sorted { lhs, rhs in
                if lhs.spent.minorUnits != rhs.spent.minorUnits {
                    return lhs.spent.minorUnits > rhs.spent.minorUnits
                }
                return lhs.categoryId!.uuidString < rhs.categoryId!.uuidString
            }

        return [status(nil, spent: total)] + perCategory
    }

    static func projection(spent: Int64, month: YearMonth, today: LocalDate) -> Int64? {
        guard month.contains(today) else { return nil }
        let elapsed = today.day
        let days = month.numberOfDays
        guard elapsed > 0 else { return nil }
        // Round half up; integer arithmetic avoids floating point drift.
        let (product, overflow) = spent.multipliedReportingOverflow(by: Int64(days))
        guard !overflow else { return nil }
        return (product + Int64(elapsed) / 2) / Int64(elapsed)
    }
}
