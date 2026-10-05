import FamilyCore
import SwiftUI

struct GoalsHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            GoalsListView(model: GoalsModel(family: membership.family, service: app.services.goals))
                .id(membership.id)
        } else {
            ContentUnavailableView("goals.noAccess", systemImage: "lock")
        }
    }
}

private struct GoalsListView: View {
    @State var model: GoalsModel
    @State private var showAdd = false
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            List {
                if model.goals.isEmpty && !model.isLoading {
                    ContentUnavailableView("goals.empty", systemImage: "target",
                                           description: Text("goals.empty.description"))
                }
                ForEach(model.goals) { goal in
                    NavigationLink(value: goal.id) { GoalRow(goal: goal, status: model.status(goal), locale: locale) }
                }
                .onDelete { offsets in
                    let items = offsets.map { model.goals[$0] }
                    Task { for item in items { await model.delete(item) } }
                }
            }
            .navigationTitle("tab.goals")
            .navigationDestination(for: UUID.self) { id in
                if let goal = model.goals.first(where: { $0.id == id }) { GoalDetailView(model: model, goal: goal) }
            }
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel(Text("goals.add"))
                    .accessibilityIdentifier("addGoalButton")
            }
            .sheet(isPresented: $showAdd) { AddGoalView(model: model) }
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

private struct GoalRow: View {
    let goal: Goal
    let status: GoalStatus
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title).font(.headline)
                if goal.isPrivate { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                Spacer()
                Text("\(Int((status.fraction * 100).rounded()))%").font(.headline.monospacedDigit())
            }
            ProgressView(value: status.fraction).tint(status.pace.color)
            HStack {
                Text(verbatim: "\(status.current.formatted()) → \(goal.targetValue.formatted()) \(goal.unit)")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(status.pace.titleKey).font(.footnote).foregroundStyle(status.pace.color)
            }
            if let finish = status.projectedFinish, status.pace != .achieved {
                Text("goals.projected \(finish.formatted(locale: locale))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GoalDetailView: View {
    let model: GoalsModel
    let goal: Goal
    @State private var value = ""
    @Environment(\.locale) private var locale

    var body: some View {
        let status = model.status(goal)
        List {
            Section {
                GoalRow(goal: goal, status: status, locale: locale)
                if let deadline = goal.deadline {
                    LabeledContent("goals.deadline", value: deadline.formatted(locale: locale))
                }
            }
            Section("goals.log") {
                HStack {
                    TextField("goals.value", text: $value).keyboardType(.decimalPad).accessibilityIdentifier("goalValueField")
                    Text(goal.unit).foregroundStyle(.secondary)
                    Button("common.save") {
                        if let number = Decimal(string: value.replacingOccurrences(of: ",", with: ".")) {
                            Task { await model.log(goal, value: number); value = "" }
                        }
                    }
                    .disabled(Decimal(string: value.replacingOccurrences(of: ",", with: ".")) == nil)
                    .accessibilityIdentifier("saveGoalValueButton")
                }
            }
            Section("goals.history") {
                ForEach(model.entries(for: goal)) { entry in
                    HStack {
                        Text(entry.recordedOn.formatted(locale: locale))
                        Spacer()
                        Text(verbatim: "\(entry.value.formatted()) \(goal.unit)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(goal.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddGoalView: View {
    let model: GoalsModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = GoalKind.savings
    @State private var title = ""
    @State private var unit = ""
    @State private var start = "0"
    @State private var target = ""
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var isPrivate = false
    @State private var action = AsyncAction()
    @State private var invalid: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            Form {
                Picker("goals.kind", selection: $kind) {
                    Text("goals.kind.savings").tag(GoalKind.savings)
                    Text("goals.kind.weight").tag(GoalKind.weight)
                    Text("goals.kind.other").tag(GoalKind.other)
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, newKind in
                    unit = Self.defaultUnit(newKind, currency: model.family.baseCurrency)
                    if newKind == .other { start = "0"; target = "100"; if unit.isEmpty { unit = "%" } }
                }
                TextField("goals.title", text: $title).accessibilityIdentifier("goalTitleField")
                HStack {
                    TextField("goals.start", text: $start).keyboardType(.numbersAndPunctuation)
                    TextField("goals.target", text: $target).keyboardType(.numbersAndPunctuation)
                        .accessibilityIdentifier("goalTargetField")
                    TextField("goals.unit", text: $unit).frame(maxWidth: 60)
                }
                Toggle("goals.hasDeadline", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("goals.deadline", selection: $deadline, in: Date()..., displayedComponents: .date)
                }
                Toggle("goals.private", isOn: $isPrivate)
                if let invalid { Text(invalid).foregroundStyle(.red) }
            }
            .navigationTitle("goals.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(title.isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveGoalButton")
                }
            }
            .errorAlert(action)
            .onAppear { unit = Self.defaultUnit(kind, currency: model.family.baseCurrency) }
        }
    }

    static func defaultUnit(_ kind: GoalKind, currency: CurrencyCode) -> String {
        switch kind {
        case .savings: currency.rawValue
        case .weight: "kg"
        case .other: ""
        }
    }

    private func decimal(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        guard let startValue = decimal(start), let targetValue = decimal(target), startValue != targetValue else {
            invalid = "goals.invalid"
            return
        }
        invalid = nil
        let goal = NewGoal(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           unit: unit.trimmingCharacters(in: .whitespaces), start: startValue, target: targetValue,
                           startsOn: LocalDate(Date()), deadline: hasDeadline ? LocalDate(deadline) : nil,
                           isPrivate: isPrivate)
        Task {
            await action.run {
                try await model.add(goal)
                dismiss()
            }
        }
    }
}

extension GoalStatus.Pace {
    var titleKey: LocalizedStringKey {
        switch self {
        case .achieved: "goals.pace.achieved"
        case .overdue: "goals.pace.overdue"
        case .onTrack: "goals.pace.onTrack"
        case .behind: "goals.pace.behind"
        case .noDeadline: "goals.pace.noDeadline"
        }
    }

    var color: Color {
        switch self {
        case .achieved, .onTrack: .green
        case .behind: .orange
        case .overdue: .red
        case .noDeadline: .blue
        }
    }
}
