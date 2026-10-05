import FamilyCore
import Foundation

struct FamilyTask: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var title: String
    var description: String?
    var status: TaskStatus
    var assigneeId: UUID?
    var dueOn: LocalDate?
    let createdBy: UUID?

    var line: TaskLine { TaskLine(id: id, status: status, due: dueOn) }

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case familyId = "family_id"
        case assigneeId = "assignee_id"
        case dueOn = "due_on"
        case createdBy = "created_by"
    }
}

struct TaskComment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let taskId: UUID
    let body: String
    let createdBy: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case taskId = "task_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

struct NewFamilyTask: Sendable {
    var title: String
    var description: String?
    var assigneeId: UUID?
    var dueOn: LocalDate?
}
