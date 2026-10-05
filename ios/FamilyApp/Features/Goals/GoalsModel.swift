import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class GoalsModel {
    private(set) var goals: [Goal] = []
    private(set) var entries: [GoalEntry] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any GoalServicing
    private let today: () -> LocalDate

    init(family: Family, service: any GoalServicing, today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.service = service
        self.today = today
    }

    func entries(for goal: Goal) -> [GoalEntry] {
        entries.filter { $0.goalId == goal.id }.sorted { $0.recordedOn > $1.recordedOn }
    }

    func status(_ goal: Goal) -> GoalStatus {
        GoalProgress.evaluate(goal.spec,
                              readings: entries(for: goal).map { GoalReading(value: $0.value, on: $0.recordedOn) },
                              today: today())
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let g = service.goals(familyId: family.id)
            async let e = service.entries(familyId: family.id)
            (goals, entries) = try await (g, e)
        }
    }

    func add(_ goal: NewGoal) async throws {
        try await service.add(familyId: family.id, goal)
        await load()
    }

    func log(_ goal: Goal, value: Decimal) async {
        await perform {
            try await service.log(familyId: family.id, goalId: goal.id, value: value, on: today())
            entries = try await service.entries(familyId: family.id)
        }
    }

    func delete(_ goal: Goal) async {
        await perform {
            try await service.delete(goal)
            goals.removeAll { $0.id == goal.id }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
