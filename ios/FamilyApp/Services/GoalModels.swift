import FamilyCore
import Foundation

struct Goal: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    let kind: GoalKind
    var title: String
    var unit: String
    let startValue: Decimal
    var targetValue: Decimal
    let startsOn: LocalDate
    var deadline: LocalDate?
    var isPrivate: Bool

    var spec: GoalSpec {
        GoalSpec(start: startValue, target: targetValue, startsOn: startsOn, deadline: deadline)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, unit, deadline
        case familyId = "family_id"
        case startValue = "start_value"
        case targetValue = "target_value"
        case startsOn = "starts_on"
        case isPrivate = "is_private"
    }
}

struct GoalEntry: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let goalId: UUID
    let value: Decimal
    let recordedOn: LocalDate
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, value, note
        case goalId = "goal_id"
        case recordedOn = "recorded_on"
    }
}

struct NewGoal: Sendable {
    var kind: GoalKind
    var title: String
    var unit: String
    var start: Decimal
    var target: Decimal
    var startsOn: LocalDate
    var deadline: LocalDate?
    var isPrivate: Bool
}
