import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class TasksModelTests: XCTestCase {
    private func makeModel(today: String = "2026-10-10", role: MemberRole = .admin, userId: UUID? = nil) async throws -> (TasksModel, Services) {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let day = LocalDate(today)!
        let model = TasksModel(family: family, service: services.tasks, familyService: services.family, userId: userId, role: role, today: { day })
        return (model, services)
    }

    func testAddAssignOrderAndDiscuss() async throws {
        let (model, _) = try await makeModel()
        await model.load()
        let me = try XCTUnwrap(model.members.first)

        try await model.add(NewFamilyTask(title: "Later", description: nil, assigneeId: nil, dueOn: LocalDate("2026-12-01")))
        try await model.add(NewFamilyTask(title: "Overdue", description: "Passports", assigneeId: me.userId, dueOn: LocalDate("2026-10-01")))
        try await model.add(NewFamilyTask(title: "Someday", description: nil, assigneeId: nil, dueOn: nil))
        XCTAssertEqual(model.ordered.map(\.title), ["Overdue", "Later", "Someday"])
        let overdue = try XCTUnwrap(model.ordered.first)
        XCTAssertTrue(model.isOverdue(overdue))
        XCTAssertEqual(model.name(of: overdue.assigneeId), me.displayName)

        await model.setStatus(overdue, .done)
        XCTAssertEqual(model.ordered.map(\.title), ["Later", "Someday", "Overdue"], "done goes last")
        XCTAssertFalse(model.isOverdue(model.tasks.first { $0.title == "Overdue" }!), "and is no longer overdue")

        await model.addComment("Photos taken", to: overdue)
        await model.addComment("Booked for Friday", to: overdue)
        XCTAssertEqual(model.comments(for: overdue).map(\.body), ["Photos taken", "Booked for Friday"])

        await model.setAssignee(overdue, nil)
        XCTAssertNil(model.tasks.first { $0.title == "Overdue" }?.assigneeId)
        XCTAssertNil(model.error)
    }

    func testAssigneeMustBeAMember() async throws {
        let (model, _) = try await makeModel()
        do {
            try await model.add(NewFamilyTask(title: "Wrong", description: nil, assigneeId: UUID(), dueOn: nil))
            XCTFail("a stranger cannot be assigned")
        } catch {}
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testDeletingTaskRemovesItsDiscussionAndOnlyAuthorOrAdminMayDelete() async throws {
        let (model, _) = try await makeModel()
        try await model.add(NewFamilyTask(title: "Gone", description: nil, assigneeId: nil, dueOn: nil))
        let task = try XCTUnwrap(model.tasks.first)
        await model.addComment("x", to: task)

        XCTAssertTrue(model.canDelete(task))
        let (services, family) = (Services.inMemory(startSignedIn: true), model.family)
        let other = TasksModel(family: family, service: services.tasks, familyService: services.family, userId: UUID(), role: .child)
        XCTAssertFalse(other.canDelete(task), "a child who did not write it is not offered delete")

        await model.delete(task)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(model.comments.isEmpty)
    }
}
