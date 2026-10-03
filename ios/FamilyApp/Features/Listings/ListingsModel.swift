import FamilyCore
import Foundation
import Observation

@MainActor
@Observable
final class ListingsModel {
    private(set) var listings: [Listing] = []
    private(set) var criteria: [Criterion] = []
    private(set) var answers: [ListingAnswer] = []
    private(set) var isLoading = false
    var error: AppError?

    let family: Family
    private let service: any ListingServicing

    init(family: Family, service: any ListingServicing) {
        self.family = family
        self.service = service
    }

    private var summaries: [ListingSummary] {
        listings.map { listing in
            ListingSummary(
                id: listing.id, status: listing.status,
                // Only prices in the family currency are comparable.
                priceMinor: listing.currency == family.baseCurrency ? listing.priceMinor : nil,
                areaM2: listing.areaM2,
                answers: Dictionary(uniqueKeysWithValues: answers.filter { $0.listingId == listing.id }
                    .map { ($0.criterionId, $0.answer) }))
        }
    }

    private var weights: [ListingCriterion] { criteria.map { ListingCriterion(id: $0.id, weight: $0.weight) } }

    /// Best first, rejected excluded.
    var ranked: [(listing: Listing, rank: RankedListing)] {
        ListingRanking.rank(summaries, criteria: weights).compactMap { ranked in
            listings.first { $0.id == ranked.listing.id }.map { ($0, ranked) }
        }
    }

    var rejected: [Listing] { listings.filter { $0.status == .rejected } }

    func answer(_ listing: Listing, _ criterion: Criterion) -> CriterionAnswer {
        answers.first { $0.listingId == listing.id && $0.criterionId == criterion.id }?.answer ?? .unknown
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await perform {
            async let listingsRequest = service.listings(familyId: family.id)
            async let criteriaRequest = service.criteria(familyId: family.id)
            async let answersRequest = service.answers(familyId: family.id)
            (listings, criteria, answers) = try await (listingsRequest, criteriaRequest, answersRequest)
        }
    }

    func add(_ listing: NewListing) async throws {
        try await service.add(familyId: family.id, listing)
        await load()
    }

    func setStatus(_ listing: Listing, _ status: ListingStatus) async {
        await perform {
            try await service.setStatus(listing, status)
            if let index = listings.firstIndex(of: listing) { listings[index].status = status }
        }
    }

    func setAnswer(_ listing: Listing, _ criterion: Criterion, _ answer: CriterionAnswer) async {
        await perform {
            try await service.setAnswer(familyId: family.id, listingId: listing.id, criterionId: criterion.id, answer: answer)
            answers.removeAll { $0.listingId == listing.id && $0.criterionId == criterion.id }
            answers.append(ListingAnswer(listingId: listing.id, criterionId: criterion.id, answer: answer))
        }
    }

    func addCriterion(name: String, weight: Int) async {
        await perform {
            try await service.addCriterion(familyId: family.id, name: name, weight: weight)
            criteria = try await service.criteria(familyId: family.id)
        }
    }

    func delete(_ listing: Listing) async {
        await perform {
            try await service.delete(listing)
            listings.removeAll { $0.id == listing.id }
        }
    }

    func comments(_ listing: Listing) async -> [ListingComment] {
        (try? await service.comments(listingId: listing.id)) ?? []
    }

    func addComment(_ listing: Listing, body: String) async throws {
        try await service.addComment(familyId: family.id, listingId: listing.id, body: body)
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}
