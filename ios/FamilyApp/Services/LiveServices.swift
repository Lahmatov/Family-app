import FamilyCore
import Foundation
import Supabase

enum SupabaseClientFactory {
    /// Reads `SupabaseURL` / `SupabaseAnonKey` from Info.plist (filled from xcconfig).
    /// Refuses plain HTTP except for local development hosts.
    static func make(bundle: Bundle = .main) throws -> SupabaseClient {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !key.isEmpty,
            let url = URL(string: urlString),
            isAllowed(url)
        else {
            throw AppError.invalidConfiguration
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(redirectToURL: URL(string: "familyapp://auth-callback"), flowType: .pkce)
            )
        )
    }

    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme {
        case "https":
            return url.host != nil
        case "http":
            #if DEBUG
            return ["127.0.0.1", "localhost"].contains(url.host ?? "")
            #else
            return false
            #endif
        default:
            return false
        }
    }
}

/// Maps transport/server errors to user-facing ones without leaking server messages.
func mapError(_ error: Error) -> AppError {
    if let appError = error as? AppError { return appError }
    if error is URLError { return .network }
    if let authError = error as? AuthError {
        switch authError.errorCode {
        case .invalidCredentials: return .invalidCredentials
        case .mfaVerificationFailed, .mfaChallengeExpired: return .invalidCode
        default: return .unknown
        }
    }
    let text = String(describing: error)
    if text.contains("42501") { return .forbidden }
    if text.contains("P0002") { return .notFound }
    if text.contains("23505") { return .conflict }
    return .unknown
}

// MARK: - Auth

final class LiveAuthService: AuthServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func currentUser() async -> (id: UUID, email: String?)? {
        guard let session = try? await client.auth.session else { return nil }
        return (session.user.id, session.user.email)
    }

    func signIn(email: String, password: String) async throws {
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw mapError(error)
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(displayName)]
            )
            return response.session == nil ? .confirmEmail : .signedIn
        } catch {
            throw mapError(error)
        }
    }

    func signOut() async {
        // Revoke refresh tokens on all devices of this user.
        try? await client.auth.signOut(scope: .global)
    }

    func assurance() async throws -> AssuranceState {
        do {
            let level = try await client.auth.mfa.getAuthenticatorAssuranceLevel()
            if level.currentLevel == "aal2" { return .verified }
            let factors = try await client.auth.mfa.listFactors()
            if let factor = factors.totp.first {
                return .challengeRequired(factorId: factor.id)
            }
            return .enrollmentRequired
        } catch {
            throw mapError(error)
        }
    }

    func enrollTOTP() async throws -> TOTPEnrollment {
        do {
            // Drop abandoned, unverified factors first (enrol limit is per user).
            let factors = try await client.auth.mfa.listFactors()
            for factor in factors.all where factor.status == .unverified {
                _ = try? await client.auth.mfa.unenroll(params: MFAUnenrollParams(factorId: factor.id))
            }
            let response = try await client.auth.mfa.enroll(
                params: MFATotpEnrollParams(issuer: "Family", friendlyName: "iPhone \(UUID().uuidString.prefix(4))")
            )
            guard let totp = response.totp else { throw AppError.unknown }
            return TOTPEnrollment(factorId: response.id, uri: totp.uri, secret: totp.secret)
        } catch {
            throw mapError(error)
        }
    }

    func verifyTOTP(factorId: String, code: String) async throws {
        do {
            try await client.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(factorId: factorId, code: code)
            )
        } catch {
            throw mapError(error)
        }
    }

    func handleDeepLink(_ url: URL) async throws {
        guard url.scheme == "familyapp", url.host == "auth-callback" else { return }
        do {
            _ = try await client.auth.session(from: url)
        } catch {
            throw mapError(error)
        }
    }
}

// MARK: - Family

private struct MembershipRow: Decodable {
    let role: MemberRole
    let families: Family
}

private struct MemberRow: Decodable {
    let userId: UUID
    let role: MemberRole
    enum CodingKeys: String, CodingKey {
        case role
        case userId = "user_id"
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct RequestActionResponse: Decodable {
    let id: UUID
    let status: ApprovalStatus
}

final class LiveFamilyService: FamilyServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func memberships() async throws -> [Membership] {
        do {
            guard let user = try? await client.auth.session.user else { return [] }
            let rows: [MembershipRow] = try await client.from("family_members")
                .select("role, families(id, name, base_currency)")
                .eq("user_id", value: user.id)
                .execute()
                .value
            return rows.map { Membership(family: $0.families, role: $0.role) }
                .sorted { $0.family.name < $1.family.name }
        } catch {
            throw mapError(error)
        }
    }

    func createFamily(name: String, currency: CurrencyCode) async throws -> UUID {
        struct Params: Encodable {
            let p_name: String
            let p_base_currency: String
        }
        do {
            return try await client.rpc("create_family", params: Params(p_name: name, p_base_currency: currency.rawValue))
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func members(of familyId: UUID) async throws -> [MemberProfile] {
        do {
            async let membersRequest: [MemberRow] = client.from("family_members")
                .select("user_id, role")
                .eq("family_id", value: familyId)
                .execute()
                .value
            async let profilesRequest: [ProfileRow] = client.from("profiles")
                .select("id, display_name")
                .execute()
                .value
            let (members, profiles) = try await (membersRequest, profilesRequest)
            let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.displayName) })
            return members
                .map { MemberProfile(userId: $0.userId, displayName: names[$0.userId] ?? "", role: $0.role) }
                .sorted { ($0.role.rank, $1.displayName) > ($1.role.rank, $0.displayName) }
        } catch {
            throw mapError(error)
        }
    }

    func myInvitations() async throws -> [Invitation] {
        do {
            guard let email = try? await client.auth.session.user.email?.lowercased() else { return [] }
            return try await client.from("family_invitations")
                .select("id, family_id, email, role, expires_at")
                .eq("email", value: email)
                .is("accepted_at", value: nil)
                .is("declined_at", value: nil)
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func accept(_ invitation: Invitation) async throws {
        try await call("accept_invitation", ["p_invitation": invitation.id])
    }

    func decline(_ invitation: Invitation) async throws {
        try await call("decline_invitation", ["p_invitation": invitation.id])
    }

    func invite(familyId: UUID, email: String, role: MemberRole) async throws -> ActionRequestOutcome {
        try await requestAction(familyId: familyId, action: .inviteMember,
                                payload: ["email": email, "role": role.rawValue])
    }

    func requestRoleChange(familyId: UUID, userId: UUID, role: MemberRole) async throws -> ActionRequestOutcome {
        try await requestAction(familyId: familyId, action: .changeRole,
                                payload: ["user_id": userId.uuidString.lowercased(), "role": role.rawValue])
    }

    func requestRemoval(familyId: UUID, userId: UUID) async throws -> ActionRequestOutcome {
        try await requestAction(familyId: familyId, action: .removeMember,
                                payload: ["user_id": userId.uuidString.lowercased()])
    }

    func pendingApprovals(familyId: UUID) async throws -> [ApprovalRequest] {
        do {
            return try await client.from("approval_requests")
                .select("id, family_id, action, payload, status, requested_by, expires_at")
                .eq("family_id", value: familyId)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func approve(_ request: ApprovalRequest) async throws {
        try await call("approve_request", ["p_request": request.id])
    }

    func reject(_ request: ApprovalRequest) async throws {
        try await call("reject_request", ["p_request": request.id])
    }

    private func requestAction(familyId: UUID, action: ApprovalAction,
                               payload: [String: String]) async throws -> ActionRequestOutcome {
        struct Params: Encodable {
            let p_family: UUID
            let p_action: String
            let p_payload: [String: String]
        }
        do {
            let response: RequestActionResponse = try await client
                .rpc("request_action", params: Params(p_family: familyId, p_action: action.rawValue, p_payload: payload))
                .execute()
                .value
            return response.status == .executed ? .executed : .pendingApproval
        } catch {
            throw mapError(error)
        }
    }

    private func call(_ function: String, _ params: [String: UUID]) async throws {
        do {
            try await client.rpc(function, params: params).execute()
        } catch {
            throw mapError(error)
        }
    }
}

// MARK: - Budget

private struct NewTransaction: Encodable {
    let id: UUID
    let family_id: UUID
    let kind: TransactionKind
    let amount_minor: Int64
    let currency: CurrencyCode
    let fx_rate: Decimal
    let category_id: UUID
    let occurred_on: LocalDate
    let merchant: String?
    let note: String?
    let paid_by: UUID?
    let is_private: Bool
}

private struct NewAttachment: Encodable {
    let family_id: UUID
    let entity_type = "transaction"
    let entity_id: UUID
    let storage_path: String
    let mime_type: String
    let size_bytes: Int
}

private struct NewBudget: Encodable {
    let family_id: UUID
    let category_id: UUID?
    let amount_minor: Int64
    let valid_from: LocalDate
}

final class LiveBudgetService: BudgetServicing {
    private let client: SupabaseClient
    private static let bucket = "family-files"

    init(client: SupabaseClient) {
        self.client = client
    }

    func categories(familyId: UUID) async throws -> [FamilyCore.Category] {
        do {
            return try await client.from("categories")
                .select()
                .eq("family_id", value: familyId)
                .eq("archived", value: false)
                .order("sort_order")
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func transactions(familyId: UUID, month: YearMonth) async throws -> [Transaction] {
        do {
            return try await client.from("transactions")
                .select()
                .eq("family_id", value: familyId)
                .gte("occurred_on", value: month.firstDay.description)
                .lt("occurred_on", value: month.adding(months: 1).firstDay.description)
                .order("occurred_on", ascending: false)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func budgets(familyId: UUID) async throws -> [Budget] {
        do {
            return try await client.from("budgets")
                .select()
                .eq("family_id", value: familyId)
                .execute()
                .value
        } catch {
            throw mapError(error)
        }
    }

    func addTransaction(familyId: UUID, _ input: TransactionDraft.Validated, receipt: ReceiptUpload?) async throws {
        let id = UUID()
        do {
            try await client.from("transactions").insert(NewTransaction(
                id: id, family_id: familyId, kind: input.kind, amount_minor: input.amount.minorUnits,
                currency: input.amount.currency, fx_rate: input.fxRate, category_id: input.categoryId,
                occurred_on: input.occurredOn, merchant: input.merchant, note: input.note,
                paid_by: input.paidBy, is_private: input.isPrivate
            )).execute()

            if let receipt {
                // Lower-case UUIDs: the database checks the path against family_id::text.
                let path = "\(familyId.uuidString.lowercased())/transaction/\(UUID().uuidString.lowercased()).\(receipt.fileExtension)"
                try await client.storage.from(Self.bucket).upload(
                    path, data: receipt.data,
                    options: FileOptions(cacheControl: "private, max-age=0", contentType: receipt.mimeType)
                )
                try await client.from("attachments").insert(NewAttachment(
                    family_id: familyId, entity_id: id, storage_path: path,
                    mime_type: receipt.mimeType, size_bytes: receipt.data.count
                )).execute()
            }
        } catch {
            throw mapError(error)
        }
    }

    func deleteTransaction(_ transaction: Transaction) async throws {
        do {
            try await client.from("transactions").delete().eq("id", value: transaction.id).execute()
        } catch {
            throw mapError(error)
        }
    }

    func setBudget(familyId: UUID, categoryId: UUID?, amountMinor: Int64, from month: YearMonth) async throws {
        do {
            try await client.from("budgets").upsert(
                NewBudget(family_id: familyId, category_id: categoryId, amount_minor: amountMinor,
                          valid_from: month.firstDay),
                onConflict: "family_id,category_id,valid_from"
            ).execute()
        } catch {
            throw mapError(error)
        }
    }
}

// MARK: - Misconfigured

struct MisconfiguredService: AuthServicing, FamilyServicing, BudgetServicing {
    func currentUser() async -> (id: UUID, email: String?)? { nil }
    func signIn(email: String, password: String) async throws { throw AppError.invalidConfiguration }
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        throw AppError.invalidConfiguration
    }
    func signOut() async {}
    func assurance() async throws -> AssuranceState { throw AppError.invalidConfiguration }
    func enrollTOTP() async throws -> TOTPEnrollment { throw AppError.invalidConfiguration }
    func verifyTOTP(factorId: String, code: String) async throws { throw AppError.invalidConfiguration }
    func handleDeepLink(_ url: URL) async throws {}
    func memberships() async throws -> [Membership] { throw AppError.invalidConfiguration }
    func createFamily(name: String, currency: CurrencyCode) async throws -> UUID { throw AppError.invalidConfiguration }
    func members(of familyId: UUID) async throws -> [MemberProfile] { throw AppError.invalidConfiguration }
    func myInvitations() async throws -> [Invitation] { throw AppError.invalidConfiguration }
    func accept(_ invitation: Invitation) async throws { throw AppError.invalidConfiguration }
    func decline(_ invitation: Invitation) async throws { throw AppError.invalidConfiguration }
    func invite(familyId: UUID, email: String, role: MemberRole) async throws -> ActionRequestOutcome {
        throw AppError.invalidConfiguration
    }
    func requestRoleChange(familyId: UUID, userId: UUID, role: MemberRole) async throws -> ActionRequestOutcome {
        throw AppError.invalidConfiguration
    }
    func requestRemoval(familyId: UUID, userId: UUID) async throws -> ActionRequestOutcome {
        throw AppError.invalidConfiguration
    }
    func pendingApprovals(familyId: UUID) async throws -> [ApprovalRequest] { throw AppError.invalidConfiguration }
    func approve(_ request: ApprovalRequest) async throws { throw AppError.invalidConfiguration }
    func reject(_ request: ApprovalRequest) async throws { throw AppError.invalidConfiguration }
    func categories(familyId: UUID) async throws -> [FamilyCore.Category] { throw AppError.invalidConfiguration }
    func transactions(familyId: UUID, month: YearMonth) async throws -> [Transaction] { throw AppError.invalidConfiguration }
    func budgets(familyId: UUID) async throws -> [Budget] { throw AppError.invalidConfiguration }
    func addTransaction(familyId: UUID, _ input: TransactionDraft.Validated, receipt: ReceiptUpload?) async throws {
        throw AppError.invalidConfiguration
    }
    func deleteTransaction(_ transaction: Transaction) async throws { throw AppError.invalidConfiguration }
    func setBudget(familyId: UUID, categoryId: UUID?, amountMinor: Int64, from month: YearMonth) async throws {
        throw AppError.invalidConfiguration
    }
}
