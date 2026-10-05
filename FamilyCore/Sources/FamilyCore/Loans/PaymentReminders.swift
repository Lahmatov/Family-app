import Foundation

/// A local notification to schedule for an upcoming instalment.
public struct ReminderSpec: Hashable, Sendable {
    /// Stable identifier, so rescheduling replaces instead of duplicating.
    public let id: String
    public let number: Int
    public let dueOn: LocalDate
    /// The day to notify (the due date minus the lead time, never in the past).
    public let fireOn: LocalDate
    public let amount: Int64
}

public enum PaymentReminders {
    /// Reminders for the next unpaid instalments of one loan. iOS keeps at most 64 pending local
    /// notifications per app, so only a few are planned per loan and the plan is rebuilt on each launch.
    public static func plan(
        loanId: UUID, schedule: LoanSchedule, paid: Set<Int>, today: LocalDate, leadDays: Int = 1, limit: Int = 3
    ) -> [ReminderSpec] {
        schedule.installments
            .filter { !paid.contains($0.number) && $0.payment > 0 && $0.dueOn >= today }
            .prefix(max(0, limit))
            .map { installment in
                let early = installment.dueOn.adding(days: -max(0, leadDays))
                return ReminderSpec(id: "loan.\(loanId.uuidString.lowercased()).\(installment.number)",
                                    number: installment.number, dueOn: installment.dueOn,
                                    fireOn: early < today ? today : early, amount: installment.payment)
            }
    }
}
