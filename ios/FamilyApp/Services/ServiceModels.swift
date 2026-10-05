import FamilyCore
import Foundation

/// Data returned when a TOTP factor is enrolled. The secret must never be logged.
struct TOTPEnrollment: Equatable, Sendable {
    let factorId: String
    /// otpauth:// URI — rendered as a QR code and offered as "Add to Passwords".
    let uri: String
    let secret: String
}

enum AssuranceState: Equatable, Sendable {
    /// Session already passed the second factor.
    case verified
    /// A factor exists; the user must enter a code.
    case challengeRequired(factorId: String)
    /// No factor yet; the user must set one up.
    case enrollmentRequired
}

enum SignUpOutcome: Equatable, Sendable {
    case signedIn
    case confirmEmail
}

struct Membership: Equatable, Hashable, Sendable, Identifiable {
    let family: Family
    let role: MemberRole
    var id: UUID { family.id }
}

struct MemberProfile: Equatable, Hashable, Sendable, Identifiable {
    let userId: UUID
    let displayName: String
    let role: MemberRole
    var id: UUID { userId }
}

struct Invitation: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    let email: String
    let role: MemberRole
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, role
        case familyId = "family_id"
        case expiresAt = "expires_at"
    }
}

struct ApprovalRequest: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let familyId: UUID
    let action: ApprovalAction
    let payload: [String: String]
    let status: ApprovalStatus
    let requestedBy: UUID?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, action, payload, status
        case familyId = "family_id"
        case requestedBy = "requested_by"
        case expiresAt = "expires_at"
    }
}

/// Result of `request_action`: executed immediately (single admin) or waiting for a second admin.
enum ActionRequestOutcome: Equatable, Sendable {
    case executed
    case pendingApproval
}

struct ReceiptUpload: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
}

/// Errors shown to the user. Server messages are never displayed verbatim.
enum AppError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidCredentials
    case invalidCode
    case network
    case forbidden
    case notFound
    case conflict
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "error.configuration")
        case .invalidCredentials: String(localized: "error.credentials")
        case .invalidCode: String(localized: "error.code")
        case .network: String(localized: "error.network")
        case .forbidden: String(localized: "error.forbidden")
        case .notFound: String(localized: "error.notFound")
        case .conflict: String(localized: "error.conflict")
        case .unknown: String(localized: "error.unknown")
        }
    }
}
