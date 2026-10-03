import FamilyCore
import Foundation

struct ChildSport: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let childId: UUID
    let kind: SportKind
    var title: String
    var location: String?
    var weekday: Int?
    var onDate: LocalDate?
    var startMinute: Int
    var durationMinutes: Int
    var untilDate: LocalDate?

    var entry: SportEntry {
        SportEntry(id: id, kind: kind, weekday: weekday, onDate: onDate, startMinute: startMinute,
                   durationMinutes: durationMinutes, until: untilDate)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, location, weekday
        case childId = "child_id"
        case onDate = "on_date"
        case startMinute = "start_minute"
        case durationMinutes = "duration_minutes"
        case untilDate = "until_date"
    }
}

struct NewChildSport: Sendable {
    var childId: UUID
    var kind: SportKind
    var title: String
    var location: String?
    var weekday: Int?
    var onDate: LocalDate?
    var startMinute: Int
    var durationMinutes: Int
    var untilDate: LocalDate?
}
