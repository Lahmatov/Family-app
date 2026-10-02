import Foundation

/// Mirrors `public.listing_status`.
public enum ListingStatus: String, Codable, Sendable, CaseIterable {
    case new, toVisit = "to_visit", visited, shortlisted, rejected
}

/// Mirrors `public.criterion_answer`.
public enum CriterionAnswer: String, Codable, Sendable {
    case yes, no, unknown
}

public struct ListingCriterion: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let weight: Int // 1...5

    public init(id: UUID, weight: Int) {
        self.id = id
        self.weight = min(5, max(1, weight))
    }
}

public struct ListingSummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let status: ListingStatus
    /// Price in the family's base currency (minor units), if known.
    public let priceMinor: Int64?
    public let areaM2: Decimal?
    public let answers: [UUID: CriterionAnswer]

    public init(id: UUID, status: ListingStatus, priceMinor: Int64?, areaM2: Decimal?,
                answers: [UUID: CriterionAnswer]) {
        self.id = id
        self.status = status
        self.priceMinor = priceMinor
        self.areaM2 = areaM2
        self.answers = answers
    }

    /// Price per square metre in minor units, rounded half up.
    public var pricePerM2Minor: Int64? {
        guard let priceMinor, let areaM2, areaM2 > 0 else { return nil }
        var value = Decimal(priceMinor) / areaM2
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

public struct RankedListing: Hashable, Sendable {
    public let listing: ListingSummary
    /// 0...100, weight of "yes" answers over the weight of all criteria.
    public let score: Int
    /// Criteria nobody has answered yet — the score may still change.
    public let unanswered: Int
}

public enum ListingRanking {
    public static func score(_ listing: ListingSummary, criteria: [ListingCriterion]) -> (score: Int, unanswered: Int) {
        let total = criteria.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return (0, 0) }
        var yes = 0
        var unanswered = 0
        for criterion in criteria {
            switch listing.answers[criterion.id] ?? .unknown {
            case .yes: yes += criterion.weight
            case .no: break
            case .unknown: unanswered += 1
            }
        }
        // Round half up in integer arithmetic.
        return ((yes * 100 + total / 2) / total, unanswered)
    }

    /// Best first: higher score, then cheaper per m² (unknown last), then stable by id.
    /// Rejected listings are excluded.
    public static func rank(_ listings: [ListingSummary], criteria: [ListingCriterion]) -> [RankedListing] {
        listings
            .filter { $0.status != .rejected }
            .map { listing -> RankedListing in
                let result = score(listing, criteria: criteria)
                return RankedListing(listing: listing, score: result.score, unanswered: result.unanswered)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                switch (lhs.listing.pricePerM2Minor, rhs.listing.pricePerM2Minor) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.listing.id.uuidString < rhs.listing.id.uuidString
                }
            }
    }
}
