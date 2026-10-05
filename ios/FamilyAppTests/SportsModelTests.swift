import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class SportsModelTests: XCTestCase {
    private func makeModel(today: String = "2026-10-03") async throws -> (SportsModel, Services, Family) {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let day = LocalDate(today)!
        let model = SportsModel(family: family, service: services.sports, childService: services.children, today: { day })
        return (model, services, family)
    }

    private func addChild(_ services: Services, _ family: Family, _ name: String) async throws -> UUID {
        try await services.children.add(familyId: family.id, name: name, birthDate: LocalDate("2018-05-01")!, sex: .unspecified,
                                        bloodType: nil, allergies: nil)
        return try await services.children.children(familyId: family.id).first { $0.name == name }!.id
    }

    func testAgendaExpandsTrainingsAndFlagsClashesBetweenChildren() async throws {
        let (model, services, family) = try await makeModel()
        let mia = try await addChild(services, family, "Mia")
        let leo = try await addChild(services, family, "Leo")

        // Tuesdays 17:00-18:00 for Mia, a Tuesday 17:30 event for Leo (Oct 6), a Saturday event for Mia.
        try await model.add(NewChildSport(childId: mia, kind: .training, title: "Swimming", location: "Piscina", weekday: 2, onDate: nil,
                                          startMinute: 1020, durationMinutes: 60, untilDate: nil))
        try await model.add(NewChildSport(childId: leo, kind: .event, title: "Football", location: nil, weekday: nil,
                                          onDate: LocalDate("2026-10-06")!, startMinute: 1050, durationMinutes: 90, untilDate: nil))
        try await model.add(NewChildSport(childId: mia, kind: .event, title: "Tournament", location: nil, weekday: nil,
                                          onDate: LocalDate("2026-10-10")!, startMinute: 540, durationMinutes: 120, untilDate: nil))

        let agenda = model.agenda(days: 14)
        XCTAssertEqual(agenda.map(\.date.description), ["2026-10-06", "2026-10-10", "2026-10-13"])
        let firstTuesday = try XCTUnwrap(agenda.first)
        XCTAssertEqual(firstTuesday.items.map(\.sport.title), ["Swimming", "Football"])
        XCTAssertEqual(firstTuesday.items.map(\.clashes), [true, true], "17:00-18:00 overlaps 17:30-19:00")
        XCTAssertEqual(firstTuesday.items.map(\.childName), ["Mia", "Leo"])
        XCTAssertEqual(agenda[1].items.map(\.clashes), [false])
        XCTAssertEqual(agenda[2].items.map(\.clashes), [false], "the next Tuesday has only the training")
    }

    func testDeleteRemovesFromTheAgenda() async throws {
        let (model, services, family) = try await makeModel()
        let mia = try await addChild(services, family, "Mia")
        try await model.add(NewChildSport(childId: mia, kind: .training, title: "Judo", location: nil, weekday: 4, onDate: nil,
                                          startMinute: 600, durationMinutes: 60, untilDate: nil))
        XCTAssertFalse(model.agenda().isEmpty)
        await model.delete(try XCTUnwrap(model.sports.first))
        XCTAssertTrue(model.agenda().isEmpty)
        XCTAssertNil(model.error)
    }

    func testInvalidShapeIsRejected() async throws {
        let (model, services, family) = try await makeModel()
        let mia = try await addChild(services, family, "Mia")
        do {
            try await model.add(NewChildSport(childId: mia, kind: .training, title: "No weekday", location: nil, weekday: nil, onDate: nil,
                                              startMinute: 600, durationMinutes: 60, untilDate: nil))
            XCTFail("a training needs a weekday")
        } catch {}
        do {
            try await model.add(NewChildSport(childId: UUID(), kind: .training, title: "Stranger", location: nil, weekday: 1, onDate: nil,
                                              startMinute: 600, durationMinutes: 60, untilDate: nil))
            XCTFail("child from another family")
        } catch {}
        XCTAssertTrue(model.sports.isEmpty)
    }
}
