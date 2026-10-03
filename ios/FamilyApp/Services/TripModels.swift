import FamilyCore
import Foundation

struct Trip: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var title: String
    var destination: String
    var startsOn: LocalDate
    var endsOn: LocalDate
    let currency: CurrencyCode
    var budgetMinor: Int64
    var notes: String?
    let createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title, destination, currency, notes
        case createdBy = "created_by"
        case familyId = "family_id"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case budgetMinor = "budget_minor"
    }
}

struct TripItem: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let tripId: UUID
    let kind: TripItemKind
    var title: String
    var day: LocalDate?
    var costMinor: Int64
    var isDone: Bool
    var link: String?

    var line: TripLine { TripLine(kind: kind, day: day, costMinor: costMinor, isDone: isDone) }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, day, link
        case tripId = "trip_id"
        case costMinor = "cost_minor"
        case isDone = "is_done"
    }
}

struct NewTrip: Sendable {
    var title: String
    var destination: String
    var startsOn: LocalDate
    var endsOn: LocalDate
    var currency: CurrencyCode
    var budgetMinor: Int64
}

struct NewTripItem: Sendable {
    var kind: TripItemKind
    var title: String
    var day: LocalDate?
    var costMinor: Int64
    var link: String?
}
