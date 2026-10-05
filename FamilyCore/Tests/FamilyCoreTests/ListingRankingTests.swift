import Foundation
import XCTest
@testable import FamilyCore

final class ListingRankingTests: XCTestCase {
    let balcony = ListingCriterion(id: UUID(), weight: 4)
    let metro = ListingCriterion(id: UUID(), weight: 1)

    private func listing(_ answers: [UUID: CriterionAnswer], price: Int64? = nil, area: Decimal? = nil,
                         status: ListingStatus = .new) -> ListingSummary {
        ListingSummary(id: UUID(), status: status, priceMinor: price, areaM2: area, answers: answers)
    }

    func testWeightedScore() {
        let result = ListingRanking.score(listing([balcony.id: .yes, metro.id: .no]), criteria: [balcony, metro])
        XCTAssertEqual(result.score, 80)
        XCTAssertEqual(result.unanswered, 0)
        XCTAssertEqual(ListingRanking.score(listing([:]), criteria: [balcony, metro]).unanswered, 2)
        XCTAssertEqual(ListingRanking.score(listing([balcony.id: .yes]), criteria: []).score, 0)
    }

    func testWeightIsClamped() {
        XCTAssertEqual(ListingCriterion(id: UUID(), weight: 99).weight, 5)
        XCTAssertEqual(ListingCriterion(id: UUID(), weight: 0).weight, 1)
    }

    func testPricePerM2() {
        XCTAssertEqual(listing([:], price: 32_000_000, area: Decimal(string: "78.5")).pricePerM2Minor, 407_643)
        XCTAssertNil(listing([:], price: 100, area: 0).pricePerM2Minor)
        XCTAssertNil(listing([:], price: nil, area: 50).pricePerM2Minor)
    }

    func testRankingOrderAndRejectedExcluded() {
        let best = listing([balcony.id: .yes, metro.id: .yes])
        let cheapTie = listing([balcony.id: .yes, metro.id: .no], price: 20_000_000, area: 80)
        let pricyTie = listing([balcony.id: .yes, metro.id: .no], price: 30_000_000, area: 80)
        let unknownPriceTie = listing([balcony.id: .yes, metro.id: .no])
        let rejected = listing([balcony.id: .yes, metro.id: .yes], status: .rejected)

        let ranked = ListingRanking.rank([unknownPriceTie, pricyTie, rejected, cheapTie, best],
                                         criteria: [balcony, metro])
        XCTAssertEqual(ranked.map(\.listing.id), [best.id, cheapTie.id, pricyTie.id, unknownPriceTie.id])
        XCTAssertEqual(ranked.first?.score, 100)
    }

    func testRawValuesMatchDatabase() {
        XCTAssertEqual(ListingStatus.allCases.map(\.rawValue), ["new", "to_visit", "visited", "shortlisted", "rejected"])
    }
}
