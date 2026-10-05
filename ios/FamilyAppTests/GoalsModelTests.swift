import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class GoalsModelTests: XCTestCase {
    func testAddLogAndStatus() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let day = LocalDate("2026-06-30")!
        let model = GoalsModel(family: family, service: services.goals, today: { day })

        try await model.add(NewGoal(kind: .savings, title: "Holiday", unit: "EUR", start: 0, target: 3000,
                                    startsOn: LocalDate("2026-01-01")!, deadline: LocalDate("2026-12-31")!, isPrivate: false))
        let goal = try XCTUnwrap(model.goals.first)
        XCTAssertEqual(model.status(goal).fraction, 0)

        await model.log(goal, value: 1600)
        let status = model.status(goal)
        XCTAssertEqual(status.current, 1600)
        XCTAssertEqual(status.pace, .onTrack)
        XCTAssertEqual(status.projectedFinish, LocalDate("2026-12-05"))

        await model.log(goal, value: 1700)
        XCTAssertEqual(model.entries(for: goal).count, 1, "logging again on the same day replaces the reading")
        XCTAssertEqual(model.status(goal).current, 1700)

        await model.delete(goal)
        XCTAssertTrue(model.goals.isEmpty)
    }

    func testNewGoalDefaultUnits() {
        XCTAssertEqual(AddGoalView.defaultUnit(.savings, currency: .eur), "EUR")
        XCTAssertEqual(AddGoalView.defaultUnit(.weight, currency: .eur), "kg")
        XCTAssertEqual(AddGoalView.defaultUnit(.other, currency: .eur), "")
    }
}
