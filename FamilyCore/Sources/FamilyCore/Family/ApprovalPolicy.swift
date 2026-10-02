import Foundation

/// Critical actions that need a second admin. Mirrors `public.approval_action`.
public enum ApprovalAction: String, Codable, Sendable, CaseIterable {
    case inviteMember = "invite_member"
    case removeMember = "remove_member"
    case changeRole = "change_role"
    case deleteFamily = "delete_family"
}

public enum ApprovalStatus: String, Codable, Sendable {
    case pending, executed, rejected, cancelled
}

/// Client-side mirror of the approval rules enforced by `public.request_action`
/// and `public.approve_request`.
public enum ApprovalPolicy {
    /// With a single admin there is nobody to ask: the action executes immediately.
    public static func requiresSecondAdmin(adminCount: Int) -> Bool {
        adminCount >= 2
    }

    public enum Decision: Equatable, Sendable {
        case allowed
        case notAnAdmin
        case ownRequest
        case notPending
        case expired
    }

    public static func canApprove(
        approverId: UUID,
        approverRole: MemberRole?,
        requestedBy: UUID?,
        status: ApprovalStatus,
        expiresAt: Date,
        now: Date = Date()
    ) -> Decision {
        guard approverRole == .admin else { return .notAnAdmin }
        guard status == .pending else { return .notPending }
        guard expiresAt > now else { return .expired }
        guard requestedBy != approverId else { return .ownRequest }
        return .allowed
    }

    /// Would executing a role change / removal leave the family without an admin?
    public static func leavesNoAdmin(
        targetCurrentRole: MemberRole,
        newRole: MemberRole?,
        adminCount: Int
    ) -> Bool {
        guard targetCurrentRole == .admin, adminCount <= 1 else { return false }
        return newRole != .admin
    }
}
