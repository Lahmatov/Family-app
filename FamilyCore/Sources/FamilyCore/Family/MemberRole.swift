import Foundation

/// Role of a person inside a family. Mirrors `public.member_role`.
public enum MemberRole: String, Codable, Sendable, CaseIterable, Comparable {
    case admin
    case adult
    case child
    case guest

    /// Must match `private.role_rank` in the database.
    public var rank: Int {
        switch self {
        case .admin: 40
        case .adult: 30
        case .child: 20
        case .guest: 10
        }
    }

    public static func < (lhs: MemberRole, rhs: MemberRole) -> Bool { lhs.rank < rhs.rank }

    public func isAtLeast(_ other: MemberRole) -> Bool { self >= other }
}

/// What a role may do. The database (RLS) is the source of truth; this only
/// drives the UI so users are not offered actions that would be refused.
public enum Capability: Sendable, CaseIterable {
    case viewFamily
    case viewFinance
    case addTransactions
    case editOthersTransactions
    case manageCategories
    case manageBudgets
    case requestCriticalActions
    case approveCriticalActions
    case viewAuditLog
    case renameFamily
}

public extension MemberRole {
    func can(_ capability: Capability) -> Bool {
        switch capability {
        case .viewFamily:
            return isAtLeast(.guest)
        case .viewFinance, .addTransactions, .manageCategories:
            return isAtLeast(.adult)
        case .editOthersTransactions, .manageBudgets, .requestCriticalActions,
             .approveCriticalActions, .viewAuditLog, .renameFamily:
            return self == .admin
        }
    }
}
