import FamilyCore
import Foundation

struct Note: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var title: String
    var body: String
    let isPrivate: Bool
    var pinned: Bool
    var updatedAt: Date

    var summary: NoteSummary { NoteSummary(id: id, title: title, body: body, pinned: pinned, updatedAt: updatedAt) }

    enum CodingKeys: String, CodingKey {
        case id, title, body, pinned
        case familyId = "family_id"
        case isPrivate = "is_private"
        case updatedAt = "updated_at"
    }
}
