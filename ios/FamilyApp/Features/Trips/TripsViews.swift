import FamilyCore
import SwiftUI

struct TripsHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            TripsListView(model: TripsModel(family: membership.family, service: app.services.trips,
                                            userId: app.userId, role: membership.role))
                .id(membership.id)
        } else {
            ContentUnavailableView("trips.noAccess", systemImage: "lock")
        }
    }
}

private struct TripsListView: View {
    @State var model: TripsModel
    @State private var showAdd = false
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            if model.trips.isEmpty && !model.isLoading {
                ContentUnavailableView("trips.empty", systemImage: "airplane", description: Text("trips.empty.description"))
            }
            ForEach(model.trips) { trip in
                NavigationLink(value: trip.id) { TripRow(trip: trip, countdown: model.countdown(trip), summary: model.summary(trip), locale: locale) }
                    .swipeActions {
                        if model.canDelete(trip) {
                            Button("common.delete", role: .destructive) { Task { await model.delete(trip) } }
                        }
                    }
            }
        }
        .navigationTitle("trips.title")
        .navigationDestination(for: UUID.self) { id in
            if let trip = model.trips.first(where: { $0.id == id }) { TripDetailView(model: model, trip: trip) }
        }
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel(Text("trips.add"))
                .accessibilityIdentifier("addTripButton")
        }
        .sheet(isPresented: $showAdd) { AddTripView(model: model) }
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

private struct TripRow: View {
    let trip: Trip
    let countdown: TripCountdown
    let summary: TripSummary
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title).font(.headline)
            if !trip.destination.isEmpty { Text(trip.destination).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                CountdownLabel(countdown: countdown)
                Spacer()
                Text("\(Money(minorUnits: summary.plannedMinor, currency: trip.currency).formatted(locale: locale)) / \(Money(minorUnits: trip.budgetMinor, currency: trip.currency).formatted(locale: locale))")
                    .font(.footnote)
                    .foregroundStyle(summary.overBudget ? .red : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CountdownLabel: View {
    let countdown: TripCountdown

    var body: some View {
        switch countdown {
        case .upcoming(let days): Text("trips.countdown.upcoming \(days)")
        case .ongoing(let day, let total): Text("trips.countdown.ongoing \(day) \(total)")
        case .finished: Text("trips.countdown.finished")
        }
    }
}

private struct TripDetailView: View {
    let model: TripsModel
    let trip: Trip
    @State private var showAdd = false
    @Environment(\.locale) private var locale

    var body: some View {
        let summary = model.summary(trip)
        let items = model.items(for: trip)
        List {
            Section {
                LabeledContent("trips.dates", value: "\(trip.startsOn.formatted(locale: locale)) – \(trip.endsOn.formatted(locale: locale))")
                CountdownLabel(countdown: model.countdown(trip))
                LabeledContent("trips.budget", value: Money(minorUnits: trip.budgetMinor, currency: trip.currency).formatted(locale: locale))
                LabeledContent("trips.planned", value: Money(minorUnits: summary.plannedMinor, currency: trip.currency).formatted(locale: locale))
                LabeledContent(summary.overBudget ? "trips.over" : "trips.left",
                               value: Money(minorUnits: abs(summary.remainingMinor), currency: trip.currency).formatted(locale: locale))
                    .foregroundStyle(summary.overBudget ? .red : .green)
                LabeledContent("trips.booked", value: Money(minorUnits: summary.doneMinor, currency: trip.currency).formatted(locale: locale))
                if summary.totalCount > 0 {
                    ProgressView(value: Double(summary.doneCount), total: Double(summary.totalCount))
                }
            }
            Section("trips.items") {
                if items.isEmpty { Text("trips.items.empty").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack {
                        Button { Task { await model.setDone(item, done: !item.isDone) } } label: {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(item.isDone ? "trips.markUndone" : "trips.markDone"))
                        VStack(alignment: .leading) {
                            Text(item.title).strikethrough(item.isDone)
                            HStack(spacing: 4) {
                                Text(LocalizedStringKey("trips.kind." + item.kind.rawValue))
                                Text(details(item))
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let link = item.link, let url = URL(string: link), url.scheme == "https" {
                            Link(destination: url) { Image(systemName: "link") }
                                .accessibilityLabel(Text("trips.openLink"))
                        }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { items[$0] }
                    Task { for item in doomed { await model.delete(item) } }
                }
            }
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel(Text("trips.item.add"))
                .accessibilityIdentifier("addTripItemButton")
        }
        .sheet(isPresented: $showAdd) { AddTripItemView(model: model, trip: trip) }
    }

    private func details(_ item: TripItem) -> String {
        var parts: [String] = []
        if let day = item.day { parts.append(day.formatted(locale: locale)) }
        if item.costMinor > 0 { parts.append(Money(minorUnits: item.costMinor, currency: trip.currency).formatted(locale: locale)) }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }
}

private struct AddTripView: View {
    let model: TripsModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var destination = ""
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var budget = ""
    @State private var action = AsyncAction()
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("trips.name", text: $title).accessibilityIdentifier("tripTitleField")
                TextField("trips.destination", text: $destination)
                DatePicker("trips.starts", selection: $start, displayedComponents: .date)
                DatePicker("trips.ends", selection: $end, in: start..., displayedComponents: .date)
                TextField("trips.budget.field", text: $budget).keyboardType(.decimalPad).accessibilityIdentifier("tripBudgetField")
                if invalid { Text("trips.invalid").foregroundStyle(.red) }
            }
            .navigationTitle("trips.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(title.isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveTripButton")
                }
            }
            .errorAlert(action)
        }
    }

    private func save() {
        let currency = model.family.baseCurrency
        let amount = budget.isEmpty ? Money(minorUnits: 0, currency: currency) : (try? Money(parsing: budget, currency: currency))
        let first = LocalDate(start), last = LocalDate(end)
        guard let amount, amount.minorUnits >= 0, last >= first, first.days(until: last) <= 366 else {
            invalid = true
            return
        }
        invalid = false
        let trip = NewTrip(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                           startsOn: first, endsOn: last, currency: currency, budgetMinor: amount.minorUnits)
        Task { await action.run { try await model.add(trip); dismiss() } }
    }
}

private struct AddTripItemView: View {
    let model: TripsModel
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var kind = TripItemKind.activity
    @State private var title = ""
    @State private var hasDay = false
    @State private var day = Date()
    @State private var cost = ""
    @State private var link = ""
    @State private var action = AsyncAction()
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("trips.kind", selection: $kind) {
                    ForEach(TripItemKind.allCases, id: \.self) { Text(LocalizedStringKey("trips.kind." + $0.rawValue)).tag($0) }
                }
                TextField("trips.item.name", text: $title).accessibilityIdentifier("tripItemTitleField")
                Toggle("trips.item.hasDay", isOn: $hasDay)
                if hasDay {
                    DatePicker("trips.item.day", selection: $day, in: trip.startsOn.toDate()...trip.endsOn.toDate(), displayedComponents: .date)
                }
                TextField("trips.item.cost", text: $cost).keyboardType(.decimalPad).accessibilityIdentifier("tripItemCostField")
                TextField("trips.item.link", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if invalid { Text("trips.item.invalid").foregroundStyle(.red) }
            }
            .navigationTitle("trips.item.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save() }.disabled(title.isEmpty || action.isRunning)
                        .accessibilityIdentifier("saveTripItemButton")
                }
            }
            .errorAlert(action)
        }
    }

    private func save() {
        let amount = cost.isEmpty ? Money(minorUnits: 0, currency: trip.currency) : (try? Money(parsing: cost, currency: trip.currency))
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only https links are stored (the database enforces the same rule).
        let linkOK = trimmedLink.isEmpty || (URL(string: trimmedLink)?.scheme == "https" && !trimmedLink.contains(" "))
        guard let amount, amount.minorUnits >= 0, linkOK else {
            invalid = true
            return
        }
        invalid = false
        let item = NewTripItem(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                               day: hasDay ? LocalDate(day) : nil, costMinor: amount.minorUnits,
                               link: trimmedLink.isEmpty ? nil : trimmedLink)
        Task { await action.run { try await model.add(item, to: trip); dismiss() } }
    }
}
