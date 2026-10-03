import FamilyCore
import Foundation
import Observation

struct AgendaItem: Identifiable, Equatable {
    let occurrence: SportOccurrence
    let sport: ChildSport
    let childName: String
    /// Overlaps another session the same day (two children, or one child double-booked).
    let clashes: Bool
    var id: String { "\(sport.id)-\(occurrence.date)" }
}

struct AgendaDay: Identifiable, Equatable {
    let date: LocalDate
    let items: [AgendaItem]
    var id: LocalDate { date }
}

@MainActor
@Observable
final class SportsModel {
    private(set) var sports: [ChildSport] = []
    private(set) var children: [Child] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any SportServicing
    private let childService: any ChildServicing
    private let today: () -> LocalDate

    init(family: Family, service: any SportServicing, childService: any ChildServicing,
         today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.service = service
        self.childService = childService
        self.today = today
    }

    /// Trainings and events from today for the next `days` days, grouped by day.
    func agenda(days: Int = 28) -> [AgendaDay] {
        let start = today()
        let occurrences = SportsCalendar.occurrences(of: sports.map(\.entry), from: start, through: start.adding(days: days - 1))
        var clashing = Set<String>()
        for (first, second) in SportsCalendar.clashes(occurrences) {
            clashing.insert("\(first.entryId)-\(first.date)")
            clashing.insert("\(second.entryId)-\(second.date)")
        }
        let byId = Dictionary(uniqueKeysWithValues: sports.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0.name) })
        let items = occurrences.compactMap { occurrence -> AgendaItem? in
            guard let sport = byId[occurrence.entryId] else { return nil }
            return AgendaItem(occurrence: occurrence, sport: sport, childName: names[sport.childId] ?? "",
                              clashes: clashing.contains("\(occurrence.entryId)-\(occurrence.date)"))
        }
        return Dictionary(grouping: items, by: \.occurrence.date).keys.sorted().map { day in
            AgendaDay(date: day, items: items.filter { $0.occurrence.date == day })
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let s = service.sports(familyId: family.id)
            async let c = childService.children(familyId: family.id)
            (sports, children) = try await (s, c)
        }
    }

    func add(_ sport: NewChildSport) async throws {
        try await service.add(familyId: family.id, sport)
        await load()
    }

    func delete(_ sport: ChildSport) async {
        await perform {
            try await service.delete(sport)
            sports.removeAll { $0.id == sport.id }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
