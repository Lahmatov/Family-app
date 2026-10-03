import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class TasksModel {
    private(set) var tasks: [FamilyTask] = []
    private(set) var comments: [TaskComment] = []
    private(set) var members: [MemberProfile] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any TaskServicing
    private let familyService: any FamilyServicing
    private let userId: UUID?
    private let role: MemberRole
    private let today: () -> LocalDate

    init(family: Family, service: any TaskServicing, familyService: any FamilyServicing, userId: UUID?, role: MemberRole,
         today: @escaping () -> LocalDate = { LocalDate(Date()) }) {
        self.family = family
        self.service = service
        self.familyService = familyService
        self.userId = userId
        self.role = role
        self.today = today
    }

    /// Open tasks first (overdue, then by date), done tasks last.
    var ordered: [FamilyTask] {
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return TaskPlanner.ordered(tasks.map(\.line), today: today()).compactMap { byId[$0.id] }
    }

    func comments(for task: FamilyTask) -> [TaskComment] {
        comments.filter { $0.taskId == task.id }.sorted { $0.createdAt < $1.createdAt }
    }

    func name(of userId: UUID?) -> String? {
        userId.flatMap { id in members.first { $0.userId == id }?.displayName }
    }

    func isOverdue(_ task: FamilyTask) -> Bool { TaskPlanner.isOverdue(task.line, today: today()) }

    /// The database lets only the author or an admin delete a task; the UI offers it only then.
    func canDelete(_ task: FamilyTask) -> Bool { role == .admin || task.createdBy == userId }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let t = service.tasks(familyId: family.id)
            async let c = service.comments(familyId: family.id)
            async let m = familyService.members(of: family.id)
            (tasks, comments, members) = try await (t, c, m)
        }
    }

    func add(_ task: NewFamilyTask) async throws {
        try await service.add(familyId: family.id, task)
        await load()
    }

    func setStatus(_ task: FamilyTask, _ status: TaskStatus) async {
        await perform {
            try await service.setStatus(task, status)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].status = status }
        }
    }

    func setAssignee(_ task: FamilyTask, _ assigneeId: UUID?) async {
        await perform {
            try await service.setAssignee(task, assigneeId)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index].assigneeId = assigneeId }
        }
    }

    func addComment(_ body: String, to task: FamilyTask) async {
        await perform {
            try await service.addComment(familyId: family.id, taskId: task.id, body: body)
            comments = try await service.comments(familyId: family.id)
        }
    }

    func delete(_ task: FamilyTask) async {
        await perform {
            try await service.delete(task)
            tasks.removeAll { $0.id == task.id }
            comments.removeAll { $0.taskId == task.id }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
