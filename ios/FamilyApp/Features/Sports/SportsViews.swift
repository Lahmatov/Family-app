import FamilyCore
import SwiftUI

struct SportsHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let membership = app.currentMembership, membership.role.isAtLeast(.adult) {
            SportsAgendaView(model: SportsModel(family: membership.family, service: app.services.sports,
                                                childService: app.services.children))
                .id(membership.id)
        } else {
            ContentUnavailableView("sports.noAccess", systemImage: "lock")
        }
    }
}

private struct SportsAgendaView: View {
    @State var model: SportsModel
    @State private var showAdd = false
    @Environment(\.locale) private var locale

    var body: some View {
        let days = model.agenda()
        List {
            if days.isEmpty && !model.isLoading {
                ContentUnavailableView("sports.empty", systemImage: "figure.run", description: Text("sports.empty.description"))
            }
            ForEach(days) { day in
                Section(day.date.formatted(locale: locale)) {
                    ForEach(day.items) { item in
                        AgendaRow(item: item, locale: locale)
                            .swipeActions { Button("common.delete", role: .destructive) { Task { await model.delete(item.sport) } } }
                    }
                }
            }
        }
        .navigationTitle("sports.title")
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel(Text("sports.add"))
                .accessibilityIdentifier("addSportButton")
        }
        .sheet(isPresented: $showAdd) { AddSportView(model: model) }
        .refreshable { await model.load() }
        .task { await model.load() }
        .alert("error.title", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.error?.localizedDescription ?? "")
        }
    }
}

private struct AgendaRow: View {
    let item: AgendaItem
    let locale: Locale

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sport.title).font(.headline)
                Text("\(clock(item.occurrence.startMinute, locale)) – \(clock(item.occurrence.endMinute, locale)) · \(item.childName)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let place = item.sport.location, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.sport.kind == .event { Image(systemName: "trophy").foregroundStyle(.orange) }
            if item.clashes {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel(Text("sports.clash"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "17:30" in the user's locale, from minutes after midnight.
private func clock(_ minute: Int, _ locale: Locale) -> String {
    let date = Calendar.current.date(from: DateComponents(hour: minute / 60, minute: minute % 60)) ?? Date()
    return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
}

private struct AddSportView: View {
    let model: SportsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var childId: UUID?
    @State private var kind = SportKind.training
    @State private var title = ""
    @State private var location = ""
    @State private var weekday = 1
    @State private var day = Date()
    @State private var start = Calendar.current.date(from: DateComponents(hour: 17, minute: 0)) ?? Date()
    @State private var duration = 60
    @State private var hasEnd = false
    @State private var until = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var action = AsyncAction()
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            if model.children.isEmpty {
                ContentUnavailableView("sports.noChildren", systemImage: "figure.and.child.holdinghands")
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            Picker("sports.child", selection: $childId) {
                ForEach(model.children) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("sports.kind", selection: $kind) {
                Text("sports.kind.training").tag(SportKind.training)
                Text("sports.kind.event").tag(SportKind.event)
            }
            .pickerStyle(.segmented)
            TextField("sports.name", text: $title).accessibilityIdentifier("sportTitleField")
            TextField("sports.location", text: $location)
            if kind == .training {
                Picker("sports.weekday", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(weekdayName($0)).tag($0) }
                }
                Toggle("sports.hasEnd", isOn: $hasEnd)
                if hasEnd { DatePicker("sports.until", selection: $until, in: Date()..., displayedComponents: .date) }
            } else {
                DatePicker("sports.date", selection: $day, displayedComponents: .date)
            }
            DatePicker("sports.start", selection: $start, displayedComponents: .hourAndMinute)
            Picker("sports.duration", selection: $duration) {
                ForEach([30, 45, 60, 75, 90, 120, 180, 240], id: \.self) { Text("sports.minutes \($0)").tag($0) }
            }
            if invalid { Text("sports.invalid").foregroundStyle(.red) }
        }
        .navigationTitle("sports.add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { save() }.disabled(title.isEmpty || action.isRunning)
                    .accessibilityIdentifier("saveSportButton")
            }
        }
        .onAppear { if childId == nil { childId = model.children.first?.id } }
        .errorAlert(action)
    }

    private func weekdayName(_ iso: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.weekdaySymbols[iso % 7]   // symbols start on Sunday; ISO 7 (Sunday) -> 0
    }

    private func save() {
        let time = Calendar.current.dateComponents([.hour, .minute], from: start)
        let startMinute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        guard let childId, startMinute + duration <= 1440 else {
            invalid = true
            return
        }
        invalid = false
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = NewChildSport(
            childId: childId, kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            location: place.isEmpty ? nil : place,
            weekday: kind == .training ? weekday : nil, onDate: kind == .event ? LocalDate(day) : nil,
            startMinute: startMinute, durationMinutes: duration,
            untilDate: kind == .training && hasEnd ? LocalDate(until) : nil)
        Task { await action.run { try await model.add(sport); dismiss() } }
    }
}
