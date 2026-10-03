import FamilyCore
import SwiftUI

/// Admin screen: monthly limits per category (and overall), effective from the shown month.
struct BudgetLimitsView: View {
    let model: BudgetModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let categoryId: UUID?
        var id: String { categoryId?.uuidString ?? "overall" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: Text("budget.overall"), categoryId: nil)
                } footer: {
                    Text("budget.limits.footer \(model.month.formatted(locale: locale))")
                }
                Section("budget.byCategory") {
                    ForEach(model.expenseCategories()) { category in
                        row(title: Text(category.displayName), categoryId: category.id)
                    }
                }
            }
            .navigationTitle("budget.limits")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .sheet(item: $editing) { target in
                LimitEditor(model: model, categoryId: target.categoryId)
            }
        }
    }

    private func row(title: Text, categoryId: UUID?) -> some View {
        Button {
            editing = EditTarget(categoryId: categoryId)
        } label: {
            HStack {
                title.foregroundStyle(.primary)
                Spacer()
                if let budget = BudgetCalculator.effectiveBudget(for: categoryId, in: model.month, budgets: model.budgets) {
                    Text(Money(minorUnits: budget.amountMinor, currency: model.family.baseCurrency).formatted(locale: locale))
                        .foregroundStyle(.secondary)
                } else {
                    Text("budget.noLimit").foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct LimitEditor: View {
    let model: BudgetModel
    let categoryId: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                TextField("budget.amount", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.title2.monospacedDigit())
            }
            .navigationTitle(categoryId.flatMap { model.category($0)?.displayName } ?? String(localized: "budget.overall"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await action.run {
                                let amount = try Money(parsing: text, currency: model.family.baseCurrency)
                                guard amount.minorUnits > 0 else { throw AppError.unknown }
                                try await model.setBudget(categoryId: categoryId, amount: amount)
                                dismiss()
                            }
                        }
                    }
                    .disabled(text.isEmpty || action.isRunning)
                }
            }
            .errorAlert(action)
        }
        .presentationDetents([.medium])
    }
}
