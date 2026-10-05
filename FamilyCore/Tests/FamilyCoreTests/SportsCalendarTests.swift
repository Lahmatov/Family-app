import XCTest
@testable import FamilyCore

final class SportsCalendarTests: XCTestCase {
    private func date(_ s: String) -> LocalDate { LocalDate(s)! }
    private let a = UUID(), b = UUID(), c = UUID()

    func testIsoWeekday() {
        XCTAssertEqual(date("2000-01-03").isoWeekday, 1)
        XCTAssertEqual(date("2026-10-03").isoWeekday, 6, "3 Oct 2026 is a Saturday")
        XCTAssertEqual(date("2026-10-04").isoWeekday, 7)
        XCTAssertEqual(date("1999-12-31").isoWeekday, 5, "before the anchor date")
    }

    func testWeeklyTrainingStopsAtSeasonEnd() {
        let swim = SportEntry(id: a, kind: .training, weekday: 2, onDate: nil, startMinute: 17 * 60, durationMinutes: 60, until: date("2026-10-20"))
        // Tuesdays: Oct 6, 13, 20 (until is inclusive); Oct 27 is after the season.
        let result = SportsCalendar.occurrences(of: [swim], from: date("2026-10-03"), through: date("2026-11-01"))
        XCTAssertEqual(result.map(\.date), [date("2026-10-06"), date("2026-10-13"), date("2026-10-20")])
        XCTAssertEqual(result.first?.endMinute, 18 * 60)
    }

    func testTrainingOnTheFirstDayOfTheRangeIsIncluded() {
        let football = SportEntry(id: a, kind: .training, weekday: 6, onDate: nil, startMinute: 600, durationMinutes: 90, until: nil)
        let result = SportsCalendar.occurrences(of: [football], from: date("2026-10-03"), through: date("2026-10-10"))
        XCTAssertEqual(result.map(\.date), [date("2026-10-03"), date("2026-10-10")])
    }

    func testEventsOnlyInRangeAndMergedInOrder() {
        let match = SportEntry(id: b, kind: .event, weekday: nil, onDate: date("2026-10-10"), startMinute: 9 * 60, durationMinutes: 120, until: nil)
        let later = SportEntry(id: c, kind: .event, weekday: nil, onDate: date("2026-12-01"), startMinute: 9 * 60, durationMinutes: 120, until: nil)
        let football = SportEntry(id: a, kind: .training, weekday: 6, onDate: nil, startMinute: 600, durationMinutes: 90, until: nil)
        let result = SportsCalendar.occurrences(of: [football, match, later], from: date("2026-10-03"), through: date("2026-10-10"))
        XCTAssertEqual(result.map(\.entryId), [a, b, a], "Sat Oct 3 training, Sat Oct 10 09:00 match before the 10:00 training")
        XCTAssertFalse(result.contains { $0.entryId == c })
    }

    func testRangeIsCappedAtOneYear() {
        let daily = (1...7).map { SportEntry(id: UUID(), kind: .training, weekday: $0, onDate: nil, startMinute: 0, durationMinutes: 30, until: nil) }
        let result = SportsCalendar.occurrences(of: daily, from: date("2026-01-01"), through: date("2100-01-01"))
        XCTAssertEqual(result.count, 366)
        XCTAssertEqual(SportsCalendar.occurrences(of: daily, from: date("2026-02-01"), through: date("2026-01-01")), [])
    }

    func testClashesIgnoreBackToBackSessions() {
        let day = date("2026-10-06")
        let one = SportEntry(id: a, kind: .event, weekday: nil, onDate: day, startMinute: 17 * 60, durationMinutes: 60, until: nil)
        let overlap = SportEntry(id: b, kind: .event, weekday: nil, onDate: day, startMinute: 17 * 60 + 30, durationMinutes: 60, until: nil)
        let afterwards = SportEntry(id: c, kind: .event, weekday: nil, onDate: day, startMinute: 18 * 60, durationMinutes: 60, until: nil)
        let occurrences = SportsCalendar.occurrences(of: [one, overlap, afterwards], from: day, through: day)
        let clashes = SportsCalendar.clashes(occurrences)
        XCTAssertEqual(clashes.count, 2, "one/overlap and overlap/afterwards; one and afterwards only touch")
        XCTAssertTrue(clashes.contains { $0.0.entryId == a && $0.1.entryId == b })
        XCTAssertTrue(clashes.contains { $0.0.entryId == b && $0.1.entryId == c })
    }
}
