import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class NotesModelTests: XCTestCase {
    func testAddPinSearchDelete() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let model = NotesModel(family: family, service: services.notes)

        try await model.add(title: "Wi-Fi", body: "password on the fridge", isPrivate: false)
        try await model.add(title: "Lista", body: "Comprar açúcar", isPrivate: true)
        XCTAssertEqual(model.notes.count, 2)

        model.query = "acucar"
        XCTAssertEqual(model.visible.map(\.title), ["Lista"])
        model.query = ""

        let wifi = try XCTUnwrap(model.notes.first { $0.title == "Wi-Fi" })
        await model.togglePin(wifi)
        XCTAssertEqual(model.visible.first?.title, "Wi-Fi", "pinned notes come first")

        var edited = try XCTUnwrap(model.notes.first { $0.title == "Lista" })
        edited.body = "Comprar leite"
        try await model.save(edited)
        XCTAssertTrue(model.notes.first { $0.title == "Lista" }?.isPrivate == true, "privacy never changes on edit")

        await model.delete(edited)
        XCTAssertEqual(model.notes.count, 1)
    }

    func testEmptyNoteIsRejected() async {
        let services = Services.inMemory(startSignedIn: true)
        let family = try! await services.family.memberships()[0].family
        let model = NotesModel(family: family, service: services.notes)
        do {
            try await model.add(title: " ", body: "", isPrivate: false)
            XCTFail("an empty note must be refused")
        } catch {}
    }
}
