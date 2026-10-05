import FamilyCore
import SwiftUI
import UIKit

struct BudgetHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership {
            if membership.role.can(.viewFinance) {
                BudgetContentView(model: BudgetModel(family: membership.family, role: membership.role,
                                                     service: app.services.budget))
                    .id(membership.id)
            } else {
                ContentUnavailableView("budget.noAccess", systemImage: "lock",
                                       description: Text("budget.noAccess.description"))
            }
        }
    }
}

private struct BudgetContentView: View {
    @State var model: BudgetModel
    @State private var showAdd = false
    @State private var showBudgets = false
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthSwitcher(model: model)
                    if let overall = model.overall {
                        OverviewCard(status: overall, income: model.income)
                    }
                }
                let categoryStatuses = model.statuses.dropFirst()
                if !categoryStatuses.isEmpty {
                    Section("budget.byCategory") {
                        ForEach(Array(categoryStatuses), id: \.categoryId) { status in
                            CategoryStatusRow(status: status, category: model.category(status.categoryId))
                        }
                    }
                }
                ForEach(model.groupedByDay) { group in
                    Section(group.day.formatted(locale: locale)) {
                        ForEach(group.items) { transaction in
                            TransactionRow(transaction: transaction, category: model.category(transaction.categoryId),
                                           baseCurrency: model.family.baseCurrency)
                        }
                        .onDelete { offsets in
                            let items = offsets.map { group.items[$0] }
                            Task { for item in items { await model.delete(item) } }
                        }
                    }
                }
                if model.transactions.isEmpty && !model.isLoading {
                    ContentUnavailableView("budget.empty", systemImage: "tray",
                                           description: Text("budget.empty.description"))
                }
            }
            .navigationTitle("tab.budget")
            .toolbar {
                if model.role.can(.manageBudgets) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showBudgets = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel(Text("budget.limits"))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityLabel(Text("budget.add"))
                        .accessibilityIdentifier("addTransactionButton")
                }
            }
            .sheet(isPresented: $showAdd) { AddTransactionView(model: model) }
            .sheet(isPresented: $showBudgets) { BudgetLimitsView(model: model) }
            .refreshable { await model.load() }
            .task { await model.load() }
            .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(model.error?.localizedDescription ?? "")
            }
        }
    }
}

private struct MonthSwitcher: View {
    let model: BudgetModel
    @Environment(\.locale) private var locale

    var body: some View {
        HStack {
            Button { Task { await model.showPreviousMonth() } } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(Text("budget.previousMonth"))
            Spacer()
            Text(model.month.formatted(locale: locale)).font(.headline)
            Spacer()
            Button { Task { await model.showNextMonth() } } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .accessibilityLabel(Text("budget.nextMonth"))
        }
        .buttonStyle(.borderless)
    }
}

private struct OverviewCard: View {
    let status: BudgetStatus
    let income: Money
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("budget.spent").font(.subheadline).foregroundStyle(.secondary)
            Text(status.spent.formatted(locale: locale))
                .font(.largeTitle.bold())
                .accessibilityIdentifier("totalSpent")
            if let limit = status.limit, let progress = status.progress {
                ProgressView(value: min(progress, 1))
                    .tint(status.level.color)
                Text("budget.ofLimit \(limit.formatted(locale: locale))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let projected = status.projected, status.projectedToExceed {
                Label {
                    Text("budget.projectedOver \(projected.formatted(locale: locale))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            if income.minorUnits > 0 {
                Text("budget.income \(income.formatted(locale: locale))")
                    .font(.footnote).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CategoryStatusRow: View {
    let status: BudgetStatus
    let category: FamilyCore.Category?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CategoryLabel(category: category)
                Spacer()
                Text(status.spent.formatted(locale: locale)).monospacedDigit()
            }
            if let progress = status.progress, let remaining = status.remaining {
                ProgressView(value: min(progress, 1)).tint(status.level.color)
                Group {
                    if remaining.minorUnits >= 0 {
                        Text("budget.remaining \(remaining.formatted(locale: locale))")
                    } else {
                        Text("budget.over \(Money(minorUnits: -remaining.minorUnits, currency: remaining.currency).formatted(locale: locale))")
                    }
                }
                .font(.caption)
                .foregroundStyle(status.level == .exceeded ? .red : .secondary)
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: FamilyCore.Transaction
    let category: FamilyCore.Category?
    let baseCurrency: CurrencyCode
    @Environment(\.locale) private var locale

    var body: some View {
        HStack {
            CategoryLabel(category: category, subtitle: transaction.merchant ?? transaction.note)
            Spacer()
            VStack(alignment: .trailing) {
                Text((transaction.kind == .income ? "+" : "−") + transaction.amount.formatted(locale: locale))
                    .foregroundStyle(transaction.kind == .income ? .green : .primary)
                    .monospacedDigit()
                if transaction.currency != baseCurrency {
                    Text(Money(minorUnits: transaction.amountBaseMinor, currency: baseCurrency).formatted(locale: locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if transaction.isPrivate {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .accessibilityLabel(Text("budget.private"))
            }
        }
    }
}

struct CategoryLabel: View {
    let category: FamilyCore.Category?
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.icon ?? "questionmark.circle")
                .foregroundStyle(Color(hex: category?.color) ?? .accentColor)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(category?.displayName ?? "")
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

extension FamilyCore.Category {
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let key = localizationKey { return String(localized: String.LocalizationValue(key)) }
        return ""
    }
}

extension BudgetStatus.Level {
    var color: Color {
        switch self {
        case .noBudget, .onTrack: .green
        case .warning: .orange
        case .exceeded: .red
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension LocalDate {
    func formatted(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return description
        }
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    func toDate() -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
}

extension YearMonth {
    func formatted(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return description
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style).capitalized(with: locale)
    }
}
