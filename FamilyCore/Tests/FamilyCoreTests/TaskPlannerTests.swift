import XCTest
@testable import FamilyCore

final class TaskPlannerTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }
    private let today = LocalDate("2026-10-10")!

    private func line(_ status: TaskStatus, _ due: String?) -> TaskLine {
        TaskLine(id: UUID(), status: status, due: due.map { LocalDate($0)! })
    }

    func testOverdueMeansPastDueAndNotDone() {
        XCTAssertTrue(TaskPlanner.isOverdue(line(.todo, "2026-10-09"), today: today))
        XCTAssertFalse(TaskPlanner.isOverdue(line(.todo, "2026-10-10"), today: today), "due today is not overdue yet")
        XCTAssertFalse(TaskPlanner.isOverdue(line(.done, "2026-01-01"), today: today), "done tasks are never overdue")
        XCTAssertFalse(TaskPlanner.isOverdue(line(.todo, nil), today: today))
    }

    func testOrdering() {
        let doneEarly = line(.done, "2026-09-01")
        let later = line(.todo, "2026-12-01")
        let undated = line(.todo, nil)
        let overdue = line(.todo, "2026-10-01")
        let dueToday = line(.todo, "2026-10-10")
        let doingToday = line(.doing, "2026-10-10")
        let ordered = TaskPlanner.ordered([doneEarly, later, undated, dueToday, overdue, doingToday], today: today)
        XCTAssertEqual(ordered, [overdue, doingToday, dueToday, later, undated, doneEarly],
                       "overdue first, then by date with doing before todo, undated after dated, done last")
    }

    func testEqualTasksKeepTheirOrder() {
        let tasks = (0..<5).map { _ in line(.todo, nil) }
        XCTAssertEqual(TaskPlanner.ordered(tasks, today: today), tasks)
    }
}
