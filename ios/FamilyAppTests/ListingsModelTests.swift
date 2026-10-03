import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class ListingsModelTests: XCTestCase {
    func testAddRankAndDuplicate() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let family = try await services.family.memberships()[0].family
        let model = ListingsModel(family: family, service: services.listings)

        await model.addCriterion(name: "Balcony", weight: 4)
        await model.addCriterion(name: "Metro", weight: 1)
        XCTAssertEqual(model.criteria.count, 2)

        try await model.add(NewListing(link: try ListingLink(parsing: "https://www.idealista.pt/imovel/1/?utm_source=a"),
                                       title: "A", priceMinor: 20_000_000, areaM2: 80))
        try await model.add(NewListing(link: try ListingLink(parsing: "https://www.idealista.pt/imovel/2/"),
                                       title: "B", priceMinor: 30_000_000, areaM2: 80))
        await model.load()
        XCTAssertEqual(model.ranked.count, 2)

        do {
            try await model.add(NewListing(link: try ListingLink(parsing: "https://www.idealista.pt/imovel/1/#x")))
            XCTFail("same ad twice must be rejected")
        } catch { XCTAssertEqual(error as? AppError, .conflict) }

        let b = try XCTUnwrap(model.listings.first { $0.title == "B" })
        for criterion in model.criteria { await model.setAnswer(b, criterion, .yes) }
        XCTAssertEqual(model.ranked.first?.listing.title, "B", "full checklist beats the cheaper listing")
        XCTAssertEqual(model.ranked.first?.rank.score, 100)

        await model.setStatus(b, .rejected)
        XCTAssertEqual(model.ranked.map(\.listing.title), ["A"])
        XCTAssertEqual(model.rejected.count, 1)
    }

    func testChildCannotUseListings() async throws {
        let store = InMemoryStore(signedIn: true)
        let family = Family(id: UUID(), name: "F", baseCurrency: .eur)
        let service = InMemoryListingService(store: store)
        do {
            _ = try await service.listings(familyId: family.id)
            XCTFail("unknown family must be refused")
        } catch { XCTAssertEqual(error as? AppError, .forbidden) }
    }
}
