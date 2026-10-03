import Foundation
import XCTest
@testable import FamilyCore

final class GoalProgressTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    func testSavingsOnTrack() {
        let spec = GoalSpec(start: 0, target: 3000, startsOn: date("2026-01-01"), deadline: date("2026-12-31"))
        let status = GoalProgress.evaluate(spec, readings: [GoalReading(value: 1600, on: date("2026-06-30"))],
                                           today: date("2026-06-30"))
        XCTAssertEqual(status.current, 1600)
        XCTAssertEqual(status.fraction, 1600.0 / 3000, accuracy: 1e-9)
        XCTAssertEqual(status.pace, .onTrack, "53% saved at ~50% of the time")
        // 1600 in 180 days -> 3000 needs 337.5 -> 338 days after Jan 1 = day 339 of the year = Dec 5
        XCTAssertEqual(status.projectedFinish, date("2026-12-05"))
    }

    func testBehindAndOverdue() {
        let spec = GoalSpec(start: 0, target: 1000, startsOn: date("2026-01-01"), deadline: date("2026-12-31"))
        let readings = [GoalReading(value: 100, on: date("2026-09-01"))]
        XCTAssertEqual(GoalProgress.evaluate(spec, readings: readings, today: date("2026-09-01")).pace, .behind)
        XCTAssertEqual(GoalProgress.evaluate(spec, readings: readings, today: date("2027-01-01")).pace, .overdue)
    }

    func testWeightLossIsDirectionAware() {
        let spec = GoalSpec(start: 90, target: 80, startsOn: date("2026-01-01"), deadline: nil)
        let status = GoalProgress.evaluate(spec, readings: [GoalReading(value: dec("87.5"), on: date("2026-02-01")),
                                                            GoalReading(value: dec("85"), on: date("2026-03-03"))],
                                           today: date("2026-03-10"))
        XCTAssertEqual(status.current, 85, "the latest reading by date wins")
        XCTAssertEqual(status.fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(status.pace, .noDeadline)
        XCTAssertEqual(status.projectedFinish, date("2026-05-03"), "5 kg in 61 days -> 10 kg in 122 days = day 123 of the year")

        let gained = GoalProgress.evaluate(spec, readings: [GoalReading(value: 92, on: date("2026-02-01"))], today: date("2026-02-02"))
        XCTAssertEqual(gained.fraction, 0, "moving away from the target never goes negative")
        XCTAssertNil(gained.projectedFinish)
    }

    func testAchievedAndEmpty() {
        let spec = GoalSpec(start: 90, target: 80, startsOn: date("2026-01-01"), deadline: date("2026-06-01"))
        let done = GoalProgress.evaluate(spec, readings: [GoalReading(value: 79, on: date("2026-05-01"))], today: date("2026-07-01"))
        XCTAssertEqual(done.pace, .achieved, "achieved beats overdue")
        XCTAssertEqual(done.fraction, 1)
        XCTAssertNil(done.projectedFinish)

        let none = GoalProgress.evaluate(spec, readings: [], today: date("2026-02-01"))
        XCTAssertEqual(none.current, 90)
        XCTAssertEqual(none.fraction, 0)
        XCTAssertNil(none.projectedFinish)
        XCTAssertEqual(none.pace, .behind)
    }

    func testRawValuesMatchDatabase() {
        XCTAssertEqual(GoalKind.allCases.map(\.rawValue), ["savings", "weight", "other"])
    }
}
