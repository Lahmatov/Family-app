import FamilyCore
import Foundation

enum ChildSex: String, Codable, Sendable, CaseIterable { case female, male, unspecified }

struct Child: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    var name: String
    var birthDate: LocalDate
    var sex: ChildSex
    var bloodType: String?
    var allergies: String?

    enum CodingKeys: String, CodingKey {
        case id, name, sex, allergies
        case familyId = "family_id"
        case birthDate = "birth_date"
        case bloodType = "blood_type"
    }
}

struct ChildVaccination: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let childId: UUID
    let vaccineCode: String
    let dose: Int
    let givenOn: LocalDate

    enum CodingKeys: String, CodingKey {
        case id, dose
        case childId = "child_id"
        case vaccineCode = "vaccine_code"
        case givenOn = "given_on"
    }
}

struct Measurement: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let childId: UUID
    let measuredOn: LocalDate
    let heightMm: Int?
    let weightG: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case childId = "child_id"
        case measuredOn = "measured_on"
        case heightMm = "height_mm"
        case weightG = "weight_g"
    }
}

struct Illness: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let childId: UUID
    let title: String
    let startedOn: LocalDate
    let endedOn: LocalDate?

    enum CodingKeys: String, CodingKey {
        case id, title
        case childId = "child_id"
        case startedOn = "started_on"
        case endedOn = "ended_on"
    }
}
