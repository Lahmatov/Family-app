import FamilyCore
import Foundation
import UserNotifications

/// Local notifications for upcoming loan instalments: no server, no Apple push account needed.
struct LocalReminderScheduler: ReminderScheduling {
    private static let prefix = "loan."

    func replaceLoanReminders(_ reminders: [(loan: Loan, spec: ReminderSpec)]) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        await clearLoanReminders()
        for (loan, spec) in reminders {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "loans.reminder.title")
            let amount = Money(minorUnits: spec.amount, currency: loan.currency).formatted()
            content.body = String(localized: "loans.reminder.body \(loan.title) \(amount)")
            content.sound = .default
            var when = DateComponents(year: spec.fireOn.year, month: spec.fireOn.month, day: spec.fireOn.day)
            when.hour = 9
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: spec.id, content: content, trigger: trigger))
        }
    }

    func clearLoanReminders() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
