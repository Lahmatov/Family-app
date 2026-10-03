import FamilyCore
import SwiftUI

struct ChildrenHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            ChildrenListView(model: ChildrenModel(family: membership.family, role: membership.role,
                                                  service: app.services.children))
                .id(membership.id)
        } else {
            ContentUnavailableView("children.noAccess", systemImage: "lock")
        }
    }
}

private struct ChildrenListView: View {
    @State var model: ChildrenModel
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.children.isEmpty && !model.isLoading {
                    ContentUnavailableView("children.empty", systemImage: "figure.and.child.holdinghands",
                                           description: Text("children.empty.description"))
                }
                ForEach(model.children) { child in
                    NavigationLink(value: child.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.name).font(.headline)
                            if let age = model.age(child) { AgeText(age: age).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete(perform: model.canDelete ? { offsets in
                    let items = offsets.map { model.children[$0] }
                    Task { for item in items { await model.delete(item) } }
                } : nil)
            }
            .navigationTitle("tab.children")
            .navigationDestination(for: UUID.self) { id in
                if let child = model.children.first(where: { $0.id == id }) {
                    ChildDetailView(model: model.detail(for: child))
                }
            }
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel(Text("children.add"))
                    .accessibilityIdentifier("addChildButton")
            }
            .sheet(isPresented: $showAdd) { AddChildView(model: model) }
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

struct AgeText: View {
    let age: Age

    var body: some View {
        if age.years == 0 {
            Text("children.age.months \(age.months)")
        } else {
            Text("children.age.yearsMonths \(age.years) \(age.months)")
        }
    }
}

struct ChildDetailView: View {
    @State var model: ChildDetailModel
    @State private var showMeasure = false
    @State private var showIllness = false
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            if let allergies = model.child.allergies, !allergies.isEmpty {
                Section("children.allergies") { Text(allergies) }
            }
            Section {
                ForEach(model.plan, id: \.scheduled) { item in
                    VaccinationRow(item: item, locale: locale) { day in
                        Task { await model.markGiven(item.scheduled, on: day) }
                    }
                }
            } header: {
                Text("children.vaccinations")
            } footer: {
                Text("children.vaccinations.disclaimer")
            }
            Section {
                ForEach(model.measurements) { m in
                    HStack {
                        Text(m.measuredOn.formatted(locale: locale))
                        Spacer()
                        Text([m.heightMm.map { "\(Double($0) / 10) cm" }, m.weightG.map { "\(Double($0) / 1000) kg" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button { showMeasure = true } label: { Label("children.measure.add", systemImage: "ruler") }
            } header: { Text("children.growth") }
            Section {
                ForEach(model.illnesses) { illness in
                    VStack(alignment: .leading) {
                        Text(illness.title)
                        Text(illness.startedOn.formatted(locale: locale)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { showIllness = true } label: { Label("children.illness.add", systemImage: "cross.case") }
            } header: { Text("children.illnesses") }
        }
        .navigationTitle(model.child.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMeasure) { AddMeasurementView(model: model) }
        .sheet(isPresented: $showIllness) { AddIllnessView(model: model) }
        .task { await model.load() }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

/// Display name of a vaccine code; keys live in the string catalog as `vaccine.<code>`.
func vaccineName(_ code: String) -> String {
    let key = "vaccine." + code
    return String(localized: String.LocalizationValue(key))
}

private struct VaccinationRow: View {
    let item: VaccinationItem
    let locale: Locale
    let markGiven: (LocalDate) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(vaccineName(item.scheduled.vaccine)) · \(item.scheduled.dose)")
                Text(item.dueDate.formatted(locale: locale)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch item.state {
            case let .done(date):
                Label(date.formatted(locale: locale), systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
                    .accessibilityLabel(Text("children.vaccine.done"))
            case let .overdue(days):
                Button("children.vaccine.markGiven") { markGiven(LocalDate(Date())) }
                    .buttonStyle(.bordered).tint(.red)
                    .accessibilityHint(Text("children.vaccine.overdue \(days)"))
            case .dueSoon:
                Button("children.vaccine.markGiven") { markGiven(LocalDate(Date())) }.buttonStyle(.bordered).tint(.orange)
            case .upcoming:
                Button("children.vaccine.markGiven") { markGiven(LocalDate(Date())) }.buttonStyle(.bordered)
            }
        }
    }
}

struct AddChildView: View {
    let model: ChildrenModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var birth = Date()
    @State private var sex = ChildSex.unspecified
    @State private var blood = ""
    @State private var allergies = ""
    @State private var action = AsyncAction()

    private let bloodTypes = ["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("children.name", text: $name).accessibilityIdentifier("childNameField")
                DatePicker("children.birth", selection: $birth, in: ...Date(), displayedComponents: .date)
                Picker("children.sex", selection: $sex) {
                    Text("children.sex.female").tag(ChildSex.female)
                    Text("children.sex.male").tag(ChildSex.male)
                    Text("children.sex.unspecified").tag(ChildSex.unspecified)
                }
                Picker("children.blood", selection: $blood) {
                    Text("children.blood.unknown").tag("")
                    ForEach(bloodTypes, id: \.self) { Text($0).tag($0) }
                }
                TextField("children.allergies", text: $allergies, axis: .vertical)
            }
            .navigationTitle("children.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await action.run {
                                let trimmed = allergies.trimmingCharacters(in: .whitespacesAndNewlines)
                                try await model.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    birthDate: LocalDate(birth), sex: sex,
                                                    bloodType: blood.isEmpty ? nil : blood,
                                                    allergies: trimmed.isEmpty ? nil : trimmed)
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || action.isRunning)
                    .accessibilityIdentifier("saveChildButton")
                }
            }
            .errorAlert(action)
        }
    }
}

struct AddMeasurementView: View {
    let model: ChildDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var height = ""
    @State private var weight = ""
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("children.measure.date", selection: $day, in: ...Date(), displayedComponents: .date)
                TextField("children.measure.height", text: $height).keyboardType(.decimalPad)
                TextField("children.measure.weight", text: $weight).keyboardType(.decimalPad)
            }
            .navigationTitle("children.measure.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await action.run {
                                try await model.measure(on: LocalDate(day), heightMm: Self.number(height, scale: 10),
                                                        weightG: Self.number(weight, scale: 1000))
                                dismiss()
                            }
                        }
                    }
                    .disabled((height.isEmpty && weight.isEmpty) || action.isRunning)
                }
            }
            .errorAlert(action)
        }
    }

    /// "12,5" with scale 10 -> 125. Returns nil for empty or invalid input.
    static func number(_ text: String, scale: Int) -> Int? {
        guard let value = Decimal(string: text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return NSDecimalNumber(decimal: (value * Decimal(scale)).rounded()).intValue
    }
}

struct AddIllnessView: View {
    let model: ChildDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day = Date()
    @State private var action = AsyncAction()

    var body: some View {
        NavigationStack {
            Form {
                TextField("children.illness.title", text: $title)
                DatePicker("children.illness.started", selection: $day, in: ...Date(), displayedComponents: .date)
            }
            .navigationTitle("children.illness.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task {
                            await action.run {
                                try await model.addIllness(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           startedOn: LocalDate(day))
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || action.isRunning)
                }
            }
            .errorAlert(action)
        }
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
