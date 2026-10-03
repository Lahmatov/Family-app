import Foundation

/// Mirrors `public.task_status`.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case todo, doing, done
}

/// The part of a task the list ordering needs.
public struct TaskLine: Hashable, Sendable {
    public let id: UUID
    public let status: TaskStatus
    public let due: LocalDate?

    public init(id: UUID, status: TaskStatus, due: LocalDate?) {
        self.id = id
        self.status = status
        self.due = due
    }
}

public enum TaskPlanner {
    /// Past its due date and not done (a task due today is not overdue yet).
    public static func isOverdue(_ task: TaskLine, today: LocalDate) -> Bool {
        task.status != .done && (task.due.map { $0 < today } ?? false)
    }

    /// Open tasks first: overdue, then by due date (undated last), "doing" before "todo" on a tie; done tasks last.
    /// Equal tasks keep their given order (the sort is stable).
    public static func ordered(_ tasks: [TaskLine], today: LocalDate) -> [TaskLine] {
        func key(_ task: TaskLine) -> (Int, Int, Int, Int) {
            let due = task.due ?? LocalDate(year: 2100, month: 12, day: 31)!
            return (task.status == .done ? 1 : 0, isOverdue(task, today: today) ? 0 : 1,
                    due.year * 10_000 + due.month * 100 + due.day, task.status == .doing ? 0 : 1)
        }
        return tasks.enumerated().sorted { lhs, rhs in
            let (a, b) = (key(lhs.element), key(rhs.element))
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}
