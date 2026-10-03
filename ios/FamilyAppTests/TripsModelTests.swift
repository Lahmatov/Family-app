import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class TripsModelTests: XCTestCase {
    private func makeModel(today: String = "2027-07-01") async throws -> TripsModel {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let day = LocalDate(today)!
        return TripsModel(family: family, service: services.trips, userId: nil, role: .admin, today: { day })
    }

    private func newTrip(budget: Int64 = 150_000) -> NewTrip {
        NewTrip(title: "Algarve", destination: "Faro", startsOn: LocalDate("2027-07-10")!, endsOn: LocalDate("2027-07-20")!,
                currency: .eur, budgetMinor: budget)
    }

    func testPlanBudgetCountdownAndChecklist() async throws {
        let model = try await makeModel()
        try await model.add(newTrip())
        let trip = try XCTUnwrap(model.trips.first)
        XCTAssertEqual(model.countdown(trip), .upcoming(days: 9))

        try await model.add(NewTripItem(kind: .stay, title: "Hotel", day: LocalDate("2027-07-10"), costMinor: 90_000, link: "https://example.com"), to: trip)
        try await model.add(NewTripItem(kind: .todo, title: "Passports", day: nil, costMinor: 0, link: nil), to: trip)
        try await model.add(NewTripItem(kind: .transport, title: "Flights", day: LocalDate("2027-07-09"), costMinor: 70_000, link: nil), to: trip)

        XCTAssertEqual(model.items(for: trip).map(\.title), ["Flights", "Hotel", "Passports"], "dated items first, by day; undated last")
        var summary = model.summary(trip)
        XCTAssertEqual(summary.plannedMinor, 160_000)
        XCTAssertTrue(summary.overBudget)

        let hotel = try XCTUnwrap(model.items(for: trip).first { $0.title == "Hotel" })
        await model.setDone(hotel, done: true)
        summary = model.summary(trip)
        XCTAssertEqual(summary.doneMinor, 90_000)
        XCTAssertEqual(summary.doneCount, 1)

        await model.delete(try XCTUnwrap(model.items(for: trip).first { $0.title == "Flights" }))
        XCTAssertFalse(model.summary(trip).overBudget)
        XCTAssertNil(model.error)
    }

    func testDeletingTripRemovesItsItems() async throws {
        let model = try await makeModel()
        try await model.add(newTrip())
        let trip = try XCTUnwrap(model.trips.first)
        try await model.add(NewTripItem(kind: .todo, title: "x", day: nil, costMinor: 0, link: nil), to: trip)
        await model.delete(trip)
        XCTAssertTrue(model.trips.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testInvalidTripIsRejected() async throws {
        let model = try await makeModel()
        var backwards = newTrip()
        backwards.endsOn = LocalDate("2027-07-01")!
        do {
            try await model.add(backwards)
            XCTFail("end before start must be rejected")
        } catch {}
        XCTAssertTrue(model.trips.isEmpty)
    }

    func testOnlyTheAuthorOrAnAdminMayDeleteATrip() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let admin = TripsModel(family: family, service: services.trips, userId: nil, role: .admin)
        try await admin.add(newTrip())
        let trip = try XCTUnwrap(admin.trips.first)

        let author = TripsModel(family: family, service: services.trips, userId: trip.createdBy, role: .adult)
        let other = TripsModel(family: family, service: services.trips, userId: UUID(), role: .adult)
        XCTAssertTrue(admin.canDelete(trip))
        XCTAssertTrue(author.canDelete(trip))
        XCTAssertFalse(other.canDelete(trip), "another adult's trip: the swipe action is not offered")
    }
}
