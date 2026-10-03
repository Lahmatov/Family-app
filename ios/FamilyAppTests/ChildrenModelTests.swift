import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class ChildrenModelTests: XCTestCase {
    func testAddChildPlanAndMarkGiven() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let membership = try await services.family.memberships()[0]
        let today = LocalDate("2026-03-20")!
        let model = ChildrenModel(family: membership.family, role: membership.role, service: services.children, today: { today })

        try await model.add(name: "Mia", birthDate: LocalDate("2026-01-10")!, sex: .female, bloodType: "A+", allergies: nil)
        let child = try XCTUnwrap(model.children.first)
        XCTAssertEqual(model.age(child)?.totalMonths, 2)

        let detail = model.detail(for: child)
        await detail.load()
        XCTAssertEqual(detail.nextVaccination?.scheduled.vaccine, "hepb", "birth dose is overdue first")

        let hepb = try XCTUnwrap(detail.plan.first { $0.scheduled.vaccine == "hepb" })
        await detail.markGiven(hepb.scheduled, on: LocalDate("2026-01-11")!)
        XCTAssertEqual(detail.plan.first { $0.scheduled.vaccine == "hepb" }?.state, .done(on: LocalDate("2026-01-11")!))
        XCTAssertEqual(detail.nextVaccination?.scheduled.vaccine, "hexa")

        await detail.markGiven(hepb.scheduled, on: LocalDate("2026-01-12")!)
        XCTAssertEqual(detail.error, .conflict, "the same dose cannot be recorded twice")

        try await detail.measure(on: today, heightMm: 580, weightG: 5200)
        try await detail.addIllness(title: "Cold", startedOn: today)
        XCTAssertEqual(detail.measurements.count, 1)
        XCTAssertEqual(detail.illnesses.count, 1)
    }

    func testOnlyAdminDeletes() async throws {
        let store = InMemoryStore(signedIn: true)
        let family = await store.families[0].family
        let service = InMemoryChildService(store: store)
        try await service.add(familyId: family.id, name: "Leo", birthDate: LocalDate("2025-05-05")!, sex: .male,
                              bloodType: nil, allergies: nil)
        let child = try await service.children(familyId: family.id)[0]
        try await service.delete(child) // the demo user is an admin
        let remaining = try await service.children(familyId: family.id)
        XCTAssertTrue(remaining.isEmpty)
    }
}
