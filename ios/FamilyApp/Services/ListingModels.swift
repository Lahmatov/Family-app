import FamilyCore
import Foundation

struct Listing: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var url: URL
    var source: String?
    var title: String
    var priceMinor: Int64?
    var currency: CurrencyCode
    var areaM2: Decimal?
    var rooms: Int?
    var address: String?
    var lat: Double?
    var lng: Double?
    var status: ListingStatus
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id, url, source, title, currency, rooms, address, lat, lng, status
        case familyId = "family_id"
        case priceMinor = "price_minor"
        case areaM2 = "area_m2"
        case createdBy = "created_by"
    }
}

struct Criterion: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var weight: Int
}

struct ListingAnswer: Codable, Hashable, Sendable {
    let listingId: UUID
    let criterionId: UUID
    var answer: CriterionAnswer

    enum CodingKeys: String, CodingKey {
        case answer
        case listingId = "listing_id"
        case criterionId = "criterion_id"
    }
}

struct ListingComment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let listingId: UUID
    let body: String
    let createdBy: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case listingId = "listing_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

/// Fields the user fills in when adding a listing.
struct NewListing: Sendable {
    var link: ListingLink
    var title = ""
    var priceMinor: Int64?
    var areaM2: Decimal?
    var rooms: Int?
    var address: String?
    var lat: Double?
    var lng: Double?
}
