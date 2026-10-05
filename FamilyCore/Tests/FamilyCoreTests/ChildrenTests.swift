import Foundation
import XCTest
@testable import FamilyCore

final class ChildrenTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }

    func testDateArithmetic() {
        XCTAssertEqual(date("2026-01-31").adding(months: 1), date("2026-02-28"))
        XCTAssertEqual(date("2024-01-31").adding(months: 1), date("2024-02-29"))
        XCTAssertEqual(date("2026-10-15").adding(months: -10), date("2025-12-15"))
        XCTAssertEqual(date("2026-02-28").adding(days: 1), date("2026-03-01"))
        XCTAssertEqual(date("2026-03-01").adding(days: -1), date("2026-02-28"))
        XCTAssertEqual(date("2026-01-01").days(until: date("2026-12-31")), 364)
        XCTAssertEqual(date("2026-05-10").days(until: date("2026-05-01")), -9)
    }

    func testAge() {
        XCTAssertEqual(Age(birth: date("2024-10-15"), on: date("2026-10-14"))?.totalMonths, 23)
        XCTAssertEqual(Age(birth: date("2024-10-15"), on: date("2026-10-15"))?.years, 2)
        XCTAssertEqual(Age(birth: date("2026-01-31"), on: date("2026-02-28"))?.totalMonths, 0)
        XCTAssertNil(Age(birth: date("2026-10-15"), on: date("2026-10-14")))
    }

    func testPlanStates() throws {
        let birth = date("2026-01-10")
        let given = [GivenDose(vaccine: "hepb", dose: 1, givenOn: date("2026-01-11"))]
        let plan = VaccinationPlanner.plan(birth: birth, given: given, today: date("2026-03-20"))

        func item(_ vaccine: String, _ dose: Int) throws -> VaccinationItem {
            try XCTUnwrap(plan.first { $0.scheduled.vaccine == vaccine && $0.scheduled.dose == dose })
        }
        XCTAssertEqual(try item("hepb", 1).state, .done(on: date("2026-01-11")))
        XCTAssertEqual(try item("hexa", 1).dueDate, date("2026-03-10"))
        XCTAssertEqual(try item("hexa", 1).state, .overdue(days: 10))
        XCTAssertEqual(try item("hexa", 2).dueDate, date("2026-05-10"))
        XCTAssertEqual(try item("hexa", 2).state, .upcoming(inDays: 51))
        XCTAssertEqual(try item("hexa", 3).state, .upcoming(inDays: 51 + 61))

        XCTAssertEqual(plan.map(\.dueDate), plan.map(\.dueDate).sorted(), "ordered by due date")
        XCTAssertEqual(VaccinationPlanner.nextAction(plan)?.scheduled.vaccine, "hexa", "overdue comes first")
        XCTAssertEqual(VaccinationPlanner.nextAction(plan)?.scheduled.dose, 1)
    }

    func testDueSoonWindowAndGivenAfterDue() throws {
        let birth = date("2026-01-10")
        let soon = VaccinationPlanner.plan(birth: birth, given: [], today: date("2026-02-20"))
        XCTAssertEqual(soon.first { $0.scheduled.vaccine == "hexa" && $0.scheduled.dose == 1 }?.state, .dueSoon(inDays: 18))

        // A dose given late is still "done"; the earliest record wins if duplicated.
        let late = [GivenDose(vaccine: "hexa", dose: 1, givenOn: date("2026-05-01")),
                    GivenDose(vaccine: "hexa", dose: 1, givenOn: date("2026-04-01"))]
        let plan = VaccinationPlanner.plan(birth: birth, given: late, today: date("2026-06-01"))
        XCTAssertEqual(plan.first { $0.scheduled.vaccine == "hexa" && $0.scheduled.dose == 1 }?.state,
                       .done(on: date("2026-04-01")))
    }

    func testScheduleIsWellFormed() {
        let schedule = VaccinationSchedule.portugalDraft
        XCTAssertEqual(Set(schedule.map { "\($0.vaccine)#\($0.dose)" }).count, schedule.count, "no duplicate doses")
        XCTAssertTrue(schedule.allSatisfy { $0.vaccine.range(of: "^[a-z0-9_]{1,40}$", options: .regularExpression) != nil },
                      "codes must satisfy the database CHECK on vaccine_code")
        XCTAssertTrue(schedule.allSatisfy { (1...10).contains($0.dose) }, "dose range matches the database")
    }
}
