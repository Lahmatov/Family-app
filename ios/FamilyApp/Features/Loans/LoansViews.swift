import FamilyCore
import SwiftUI

struct LoansHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            LoansListView(model: LoansModel(family: membership.family, service: app.services.loans,
                                            reminders: LocalReminderScheduler()))
                .id(membership.id)
        } else {
            ContentUnavailableView("loans.noAccess", systemImage: "lock")
        }
    }
}

private struct LoansListView: View {
    @State var model: LoansModel
    @State private var showAdd = false
    @AppStorage("loanRemindersEnabled") private var remindersEnabled = false
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section {
                Toggle(isOn: $remindersEnabled) { Label("loans.reminders", systemImage: "bell") }
            } footer: { Text("loans.reminders.footer") }
            if model.overviews.isEmpty && !model.isLoading {
                ContentUnavailableView("loans.empty", systemImage: "banknote", description: Text("loans.empty.description"))
            }
            ForEach(model.overviews, id: \.loan.id) { item in
                NavigationLink(value: item.loan.id) { LoanRow(item: item, locale: locale) }
            }
            .onDelete { offsets in
                let items = offsets.map { model.overviews[$0].loan }
                Task { for item in items { await model.delete(item) } }
            }
        }
        .navigationTitle("loans.title")
        .navigationDestination(for: UUID.self) { id in
            if let loan = model.loans.first(where: { $0.id == id }) { LoanDetailView(model: model, loan: loan) }
        }
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel(Text("loans.add"))
                .accessibilityIdentifier("addLoanButton")
        }
        .sheet(isPresented: $showAdd) { AddLoanView(model: model) }
        .refreshable { await model.load(); await model.scheduleReminders(enabled: remindersEnabled) }
        .task { await model.load(); await model.scheduleReminders(enabled: remindersEnabled) }
        .onChange(of: remindersEnabled) { _, enabled in Task { await model.scheduleReminders(enabled: enabled) } }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

private struct LoanRow: View {
    let item: LoanOverview
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.loan.title).font(.headline)
                Spacer()
                if !item.status.overdue.isEmpty {
                    Label("loans.overdue \(item.status.overdue.count)", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            ProgressView(value: min(max(item.progress, 0), 1))
            HStack {
                Text("loans.remaining \(Money(minorUnits: item.status.remainingBalance, currency: item.loan.currency).formatted(locale: locale))")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if let next = item.status.next {
                    Text("loans.next \(next.dueOn.formatted(locale: locale)) \(Money(minorUnits: next.payment, currency: item.loan.currency).formatted(locale: locale))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LoanDetailView: View {
    let model: LoansModel
    let loan: Loan
    @State private var showExtra = false
    @State private var showRate = false
    @Environment(\.locale) private var locale

    var body: some View {
        let overview = model.overview(loan)
        let paid = model.paidNumbers(loan)
        List {
            if let overview {
                Section {
                    LabeledContent("loans.principal", value: Money(minorUnits: loan.principalMinor, currency: loan.currency).formatted(locale: locale))
                    LabeledContent("loans.rate", value: "\(loan.annualRate.formatted()) %")
                    LabeledContent("loans.totalInterest", value: Money(minorUnits: overview.schedule.totalInterest, currency: loan.currency).formatted(locale: locale))
                    if let payoff = overview.schedule.payoffDate {
                        LabeledContent("loans.payoff", value: payoff.formatted(locale: locale))
                    }
                    if overview.interestSaved > 0 {
                        LabeledContent("loans.saved", value: Money(minorUnits: overview.interestSaved, currency: loan.currency).formatted(locale: locale))
                            .foregroundStyle(.green)
                    }
                }
                Section {
                    Button { showExtra = true } label: { Label("loans.extra.add", systemImage: "plus.forwardslash.minus") }
                    Button { showRate = true } label: { Label("loans.rate.add", systemImage: "percent") }
                }
                Section("loans.schedule") {
                    ForEach(overview.schedule.installments, id: \.number) { row in
                        HStack {
                            Button {
                                Task { await model.setPaid(loan, number: row.number, paid: !paid.contains(row.number)) }
                            } label: {
                                Image(systemName: paid.contains(row.number) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(paid.contains(row.number) ? .green : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(paid.contains(row.number) ? "loans.markUnpaid" : "loans.markPaid"))
                            VStack(alignment: .leading) {
                                Text(row.dueOn.formatted(locale: locale)).font(.subheadline)
                                Text("loans.split \(Money(minorUnits: row.principal, currency: loan.currency).formatted(locale: locale)) \(Money(minorUnits: row.interest, currency: loan.currency).formatted(locale: locale))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money(minorUnits: row.payment, currency: loan.currency).formatted(locale: locale)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(loan.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExtra) { AddExtraView(model: model, loan: loan) }
        .sheet(isPresented: $showRate) { AddRateChangeView(model: model, loan: loan) }
    }
}

struct AddLoanView: View {
    let model: LoansModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var lender = ""
    @State private var amount = ""
    @State private var rate = ""
    @State private var years = "25"
    @State private var firstPayment = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var type = LoanType.annuity
    @State private var action = AsyncAction()
    @State private var invalid: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            Form {
                TextField("loans.name", text: $title).accessibilityIdentifier("loanTitleField")
                TextField("loans.lender", text: $lender)
                TextField("loans.amount", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("loanAmountField")
                TextField("loans.rate.field", text: $rate).keyboardType(.decimalPad)
                TextField("loans.years", text: $years).keyboardType(.numberPad)
                DatePicker("loans.firstPayment", selection: $firstPayment, displayedComponents: .date)
                Picker("loans.type", selection: $type) {
                    Text("loans.type.annuity").tag(LoanType.annuity)
                    Text("loans.type.differentiated").tag(LoanType.differentiated)
                }
                if let invalid { Text(invalid).foregroundStyle(.red) }
            }
            .navigationTitle("loans.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(title.isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveLoanButton")
                }
            }
            .errorAlert(action)
        }
    }

    private func save() {
        let currency = model.family.baseCurrency
        guard let principal = try? Money(parsing: amount, currency: currency), principal.minorUnits > 0,
              let annual = Decimal(string: rate.replacingOccurrences(of: ",", with: ".")), annual >= 0, annual <= 100,
              let yearCount = Int(years), (1...50).contains(yearCount) else {
            invalid = "loans.invalid"
            return
        }
        invalid = nil
        let lenderName = lender.trimmingCharacters(in: .whitespacesAndNewlines)
        let loan = NewLoan(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           lender: lenderName.isEmpty ? nil : lenderName, principalMinor: principal.minorUnits,
                           currency: currency, annualRate: annual, termMonths: yearCount * 12,
                           firstPaymentOn: LocalDate(firstPayment), type: type)
        Task {
            await action.run {
                try await model.add(loan)
                dismiss()
            }
        }
    }
}

struct AddExtraView: View {
    let model: LoansModel
    let loan: Loan
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var strategy = ExtraStrategy.reduceTerm
    @State private var action = AsyncAction()
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("loans.amount", text: $amount).keyboardType(.decimalPad)
                Picker("loans.strategy", selection: $strategy) {
                    Text("loans.strategy.term").tag(ExtraStrategy.reduceTerm)
                    Text("loans.strategy.payment").tag(ExtraStrategy.reducePayment)
                }
                .pickerStyle(.inline)
                if invalid { Text("loans.invalid").foregroundStyle(.red) }
            }
            .navigationTitle("loans.extra.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        guard let money = try? Money(parsing: amount, currency: loan.currency), money.minorUnits > 0 else {
                            invalid = true
                            return
                        }
                        Task { await action.run { try await model.addExtra(loan, amountMinor: money.minorUnits, strategy: strategy); dismiss() } }
                    }
                    .disabled(action.isRunning)
                }
            }
            .errorAlert(action)
        }
    }
}

struct AddRateChangeView: View {
    let model: LoansModel
    let loan: Loan
    @Environment(\.dismiss) private var dismiss
    @State private var rate = ""
    @State private var from = Date()
    @State private var action = AsyncAction()
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("loans.rate.field", text: $rate).keyboardType(.decimalPad)
                DatePicker("loans.rate.from", selection: $from, displayedComponents: .date)
                if invalid { Text("loans.invalid").foregroundStyle(.red) }
            }
            .navigationTitle("loans.rate.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        guard let value = Decimal(string: rate.replacingOccurrences(of: ",", with: ".")), value >= 0, value <= 100 else {
                            invalid = true
                            return
                        }
                        Task { await action.run { try await model.addRateChange(loan, from: LocalDate(from), annualRate: value); dismiss() } }
                    }
                    .disabled(action.isRunning)
                }
            }
            .errorAlert(action)
        }
    }
}
