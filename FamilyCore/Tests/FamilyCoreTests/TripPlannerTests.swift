import XCTest
@testable import FamilyCore

final class TripPlannerTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }

    func testSummaryAgainstBudget() {
        let lines = [
            TripLine(kind: .stay, day: date("2027-07-10"), costMinor: 90_000, isDone: true),
            TripLine(kind: .transport, day: nil, costMinor: 40_050, isDone: true),
            TripLine(kind: .activity, day: date("2027-07-12"), costMinor: 25_000, isDone: false),
            TripLine(kind: .todo, day: nil, costMinor: 0, isDone: false),
        ]
        let summary = TripPlanner.summary(budgetMinor: 150_000, lines: lines)
        XCTAssertEqual(summary.plannedMinor, 155_050)
        XCTAssertEqual(summary.doneMinor, 130_050)
        XCTAssertEqual(summary.remainingMinor, -5_050)
        XCTAssertTrue(summary.overBudget)
        XCTAssertEqual(summary.undatedMinor, 40_050)
        XCTAssertEqual(summary.doneCount, 2)
        XCTAssertEqual(summary.totalCount, 4)
    }

    func testExactlyOnBudgetIsNotOver() {
        let summary = TripPlanner.summary(budgetMinor: 100, lines: [TripLine(kind: .stay, day: nil, costMinor: 100, isDone: false)])
        XCTAssertFalse(summary.overBudget)
        XCTAssertEqual(summary.remainingMinor, 0)
    }

    func testCountdown() {
        let start = date("2027-07-10"), end = date("2027-07-20")
        XCTAssertEqual(TripPlanner.countdown(starts: start, ends: end, today: date("2027-07-01")), .upcoming(days: 9))
        XCTAssertEqual(TripPlanner.countdown(starts: start, ends: end, today: start), .ongoing(day: 1, of: 11))
        XCTAssertEqual(TripPlanner.countdown(starts: start, ends: end, today: end), .ongoing(day: 11, of: 11))
        XCTAssertEqual(TripPlanner.countdown(starts: start, ends: end, today: date("2027-07-21")), .finished)
    }
}
