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
                auth: .init(storage: DeviceOnlyKeychainStorage(),
                            redirectToURL: URL(string: "familyapp://auth-callback"), flowType: .pkce)
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

// MARK: - Listings

private struct NewListingRow: Encodable {
    let family_id: UUID
    let url: String
    let source: String
    let title: String
    let price_minor: Int64?
    let area_m2: Decimal?
    let rooms: Int?
    let address: String?
    let lat: Double?
    let lng: Double?
}

private struct AnswerRow: Encodable {
    let listing_id: UUID
    let criterion_id: UUID
    let family_id: UUID
    let answer: CriterionAnswer
}

final class LiveListingService: ListingServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func listings(familyId: UUID) async throws -> [Listing] {
        try await fetch("listings", familyId: familyId, order: "created_at")
    }

    func criteria(familyId: UUID) async throws -> [Criterion] {
        try await fetch("listing_criteria", familyId: familyId, order: "created_at")
    }

    func answers(familyId: UUID) async throws -> [ListingAnswer] {
        try await fetch("listing_answers", familyId: familyId, order: nil)
    }

    func comments(listingId: UUID) async throws -> [ListingComment] {
        do {
            return try await client.from("listing_comments").select().eq("listing_id", value: listingId)
                .order("created_at").execute().value
        } catch {
            throw mapError(error)
        }
    }

    func add(familyId: UUID, _ listing: NewListing) async throws {
        try await run {
            try await self.client.from("listings").insert(NewListingRow(
                family_id: familyId, url: listing.link.url.absoluteString, source: listing.link.source,
                title: listing.title, price_minor: listing.priceMinor, area_m2: listing.areaM2,
                rooms: listing.rooms, address: listing.address, lat: listing.lat, lng: listing.lng)).execute()
        }
    }

    func setStatus(_ listing: Listing, _ status: ListingStatus) async throws {
        try await run {
            try await self.client.from("listings").update(["status": status.rawValue])
                .eq("id", value: listing.id).execute()
        }
    }

    func setAnswer(familyId: UUID, listingId: UUID, criterionId: UUID, answer: CriterionAnswer) async throws {
        try await run {
            try await self.client.from("listing_answers").upsert(
                AnswerRow(listing_id: listingId, criterion_id: criterionId, family_id: familyId, answer: answer),
                onConflict: "listing_id,criterion_id").execute()
        }
    }

    func addCriterion(familyId: UUID, name: String, weight: Int) async throws {
        struct Row: Encodable { let family_id: UUID; let name: String; let weight: Int }
        try await run {
            try await self.client.from("listing_criteria")
                .insert(Row(family_id: familyId, name: name, weight: weight)).execute()
        }
    }

    func addComment(familyId: UUID, listingId: UUID, body: String) async throws {
        struct Row: Encodable { let listing_id: UUID; let family_id: UUID; let body: String }
        try await run {
            try await self.client.from("listing_comments")
                .insert(Row(listing_id: listingId, family_id: familyId, body: body)).execute()
        }
    }

    func delete(_ listing: Listing) async throws {
        try await run { try await self.client.from("listings").delete().eq("id", value: listing.id).execute() }
    }

    private func fetch<T: Decodable>(_ table: String, familyId: UUID, order: String?) async throws -> [T] {
        do {
            let query = client.from(table).select().eq("family_id", value: familyId)
            if let order { return try await query.order(order).execute().value }
            return try await query.execute().value
        } catch {
            throw mapError(error)
        }
    }

    private func run(_ operation: @Sendable () async throws -> Void) async throws {
        do { try await operation() } catch { throw mapError(error) }
    }
}

// MARK: - Children

final class LiveChildService: ChildServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func children(familyId: UUID) async throws -> [Child] {
        try await run { try await self.client.from("children").select().eq("family_id", value: familyId)
            .order("birth_date").execute().value }
    }

    func vaccinations(childId: UUID) async throws -> [ChildVaccination] {
        try await run { try await self.client.from("child_vaccinations").select().eq("child_id", value: childId)
            .execute().value }
    }

    func measurements(childId: UUID) async throws -> [Measurement] {
        try await run { try await self.client.from("child_measurements").select().eq("child_id", value: childId)
            .order("measured_on", ascending: false).execute().value }
    }

    func illnesses(childId: UUID) async throws -> [Illness] {
        try await run { try await self.client.from("child_illnesses").select().eq("child_id", value: childId)
            .order("started_on", ascending: false).execute().value }
    }

    func add(familyId: UUID, name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) async throws {
        struct Row: Encodable {
            let family_id: UUID; let name: String; let birth_date: LocalDate
            let sex: ChildSex; let blood_type: String?; let allergies: String?
        }
        try await run { try await self.client.from("children").insert(Row(
            family_id: familyId, name: name, birth_date: birthDate, sex: sex, blood_type: bloodType,
            allergies: allergies)).execute() }
    }

    func record(familyId: UUID, childId: UUID, vaccine: String, dose: Int, on day: LocalDate) async throws {
        struct Row: Encodable {
            let child_id: UUID; let family_id: UUID; let vaccine_code: String; let dose: Int; let given_on: LocalDate
        }
        try await run { try await self.client.from("child_vaccinations").insert(Row(
            child_id: childId, family_id: familyId, vaccine_code: vaccine, dose: dose, given_on: day)).execute() }
    }

    func measure(familyId: UUID, childId: UUID, on day: LocalDate, heightMm: Int?, weightG: Int?) async throws {
        struct Row: Encodable {
            let child_id: UUID; let family_id: UUID; let measured_on: LocalDate
            let height_mm: Int?; let weight_g: Int?
        }
        try await run { try await self.client.from("child_measurements").insert(Row(
            child_id: childId, family_id: familyId, measured_on: day, height_mm: heightMm, weight_g: weightG)).execute() }
    }

    func addIllness(familyId: UUID, childId: UUID, title: String, startedOn: LocalDate) async throws {
        struct Row: Encodable {
            let child_id: UUID; let family_id: UUID; let title: String; let started_on: LocalDate
        }
        try await run { try await self.client.from("child_illnesses").insert(Row(
            child_id: childId, family_id: familyId, title: title, started_on: startedOn)).execute() }
    }

    func delete(_ child: Child) async throws {
        try await run { try await self.client.from("children").delete().eq("id", value: child.id).execute() }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

// MARK: - Goals

final class LiveGoalService: GoalServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func goals(familyId: UUID) async throws -> [Goal] {
        try await run { try await self.client.from("goals").select().eq("family_id", value: familyId)
            .order("created_at").execute().value }
    }

    func entries(familyId: UUID) async throws -> [GoalEntry] {
        try await run { try await self.client.from("goal_entries").select().eq("family_id", value: familyId)
            .order("recorded_on").execute().value }
    }

    func add(familyId: UUID, _ goal: NewGoal) async throws {
        struct Row: Encodable {
            let family_id: UUID; let kind: GoalKind; let title: String; let unit: String
            let start_value: Decimal; let target_value: Decimal; let starts_on: LocalDate
            let deadline: LocalDate?; let is_private: Bool
        }
        try await run { try await self.client.from("goals").insert(Row(
            family_id: familyId, kind: goal.kind, title: goal.title, unit: goal.unit, start_value: goal.start,
            target_value: goal.target, starts_on: goal.startsOn, deadline: goal.deadline,
            is_private: goal.isPrivate)).execute() }
    }

    func log(familyId: UUID, goalId: UUID, value: Decimal, on day: LocalDate) async throws {
        struct Row: Encodable {
            let goal_id: UUID; let family_id: UUID; let value: Decimal; let recorded_on: LocalDate
        }
        // One reading per day: logging again on the same day replaces the earlier value.
        try await run { try await self.client.from("goal_entries").upsert(
            Row(goal_id: goalId, family_id: familyId, value: value, recorded_on: day),
            onConflict: "goal_id,recorded_on").execute() }
    }

    func delete(_ goal: Goal) async throws {
        try await run { try await self.client.from("goals").delete().eq("id", value: goal.id).execute() }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

// MARK: - Notes

final class LiveNoteService: NoteServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func notes(familyId: UUID) async throws -> [Note] {
        try await run { try await self.client.from("notes").select().eq("family_id", value: familyId)
            .order("updated_at", ascending: false).execute().value }
    }

    func add(familyId: UUID, title: String, body: String, isPrivate: Bool) async throws {
        struct Row: Encodable { let family_id: UUID; let title: String; let body: String; let is_private: Bool }
        try await run { try await self.client.from("notes").insert(Row(
            family_id: familyId, title: title, body: body, is_private: isPrivate)).execute() }
    }

    func update(_ note: Note) async throws {
        struct Row: Encodable { let title: String; let body: String; let pinned: Bool }
        try await run { try await self.client.from("notes").update(Row(
            title: note.title, body: note.body, pinned: note.pinned)).eq("id", value: note.id).execute() }
    }

    func delete(_ note: Note) async throws {
        try await run { try await self.client.from("notes").delete().eq("id", value: note.id).execute() }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

// MARK: - Loans

final class LiveLoanService: LoanServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func loans(familyId: UUID) async throws -> [Loan] { try await fetch("loans", familyId, order: "created_at") }
    func rateChanges(familyId: UUID) async throws -> [LoanRateChangeRow] { try await fetch("loan_rate_changes", familyId, order: "effective_from") }
    func extras(familyId: UUID) async throws -> [LoanExtraRow] { try await fetch("loan_extra_payments", familyId, order: "paid_on") }
    func payments(familyId: UUID) async throws -> [LoanPaidRow] { try await fetch("loan_payments", familyId, order: "installment_no") }

    func add(familyId: UUID, _ loan: NewLoan) async throws {
        struct Row: Encodable {
            let family_id: UUID; let title: String; let lender: String?; let principal_minor: Int64
            let currency: CurrencyCode; let annual_rate: Decimal; let term_months: Int
            let first_payment_on: LocalDate; let loan_type: LoanType
        }
        try await run { try await self.client.from("loans").insert(Row(
            family_id: familyId, title: loan.title, lender: loan.lender, principal_minor: loan.principalMinor,
            currency: loan.currency, annual_rate: loan.annualRate, term_months: loan.termMonths,
            first_payment_on: loan.firstPaymentOn, loan_type: loan.type)).execute() }
    }

    func addRateChange(familyId: UUID, loanId: UUID, from: LocalDate, annualRate: Decimal) async throws {
        struct Row: Encodable { let loan_id: UUID; let family_id: UUID; let effective_from: LocalDate; let annual_rate: Decimal }
        try await run { try await self.client.from("loan_rate_changes").insert(Row(
            loan_id: loanId, family_id: familyId, effective_from: from, annual_rate: annualRate)).execute() }
    }

    func addExtra(familyId: UUID, loanId: UUID, on day: LocalDate, amountMinor: Int64, strategy: ExtraStrategy) async throws {
        struct Row: Encodable {
            let loan_id: UUID; let family_id: UUID; let paid_on: LocalDate; let amount_minor: Int64; let strategy: ExtraStrategy
        }
        try await run { try await self.client.from("loan_extra_payments").insert(Row(
            loan_id: loanId, family_id: familyId, paid_on: day, amount_minor: amountMinor, strategy: strategy)).execute() }
    }

    func setPaid(familyId: UUID, loanId: UUID, number: Int, paid: Bool, on day: LocalDate) async throws {
        struct Row: Encodable { let loan_id: UUID; let family_id: UUID; let installment_no: Int; let paid_on: LocalDate }
        try await run {
            if paid {
                try await self.client.from("loan_payments").upsert(
                    Row(loan_id: loanId, family_id: familyId, installment_no: number, paid_on: day),
                    onConflict: "loan_id,installment_no").execute()
            } else {
                try await self.client.from("loan_payments").delete()
                    .eq("loan_id", value: loanId).eq("installment_no", value: number).execute()
            }
        }
    }

    func delete(_ loan: Loan) async throws {
        try await run { try await self.client.from("loans").delete().eq("id", value: loan.id).execute() }
    }

    private func fetch<T: Decodable>(_ table: String, _ familyId: UUID, order: String) async throws -> [T] {
        try await run { try await self.client.from(table).select().eq("family_id", value: familyId)
            .order(order).execute().value }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

final class LiveTripService: TripServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func trips(familyId: UUID) async throws -> [Trip] {
        try await run { try await self.client.from("trips").select().eq("family_id", value: familyId)
            .order("starts_on").execute().value }
    }

    func items(familyId: UUID) async throws -> [TripItem] {
        try await run { try await self.client.from("trip_items").select().eq("family_id", value: familyId)
            .order("created_at").execute().value }
    }

    func add(familyId: UUID, _ trip: NewTrip) async throws {
        struct Row: Encodable {
            let family_id: UUID; let title: String; let destination: String; let starts_on: LocalDate
            let ends_on: LocalDate; let currency: CurrencyCode; let budget_minor: Int64
        }
        try await run { try await self.client.from("trips").insert(Row(
            family_id: familyId, title: trip.title, destination: trip.destination, starts_on: trip.startsOn,
            ends_on: trip.endsOn, currency: trip.currency, budget_minor: trip.budgetMinor)).execute() }
    }

    func add(familyId: UUID, tripId: UUID, _ item: NewTripItem) async throws {
        struct Row: Encodable {
            let trip_id: UUID; let family_id: UUID; let kind: TripItemKind; let title: String
            let day: LocalDate?; let cost_minor: Int64; let link: String?
        }
        try await run { try await self.client.from("trip_items").insert(Row(
            trip_id: tripId, family_id: familyId, kind: item.kind, title: item.title, day: item.day,
            cost_minor: item.costMinor, link: item.link)).execute() }
    }

    func setDone(_ item: TripItem, done: Bool) async throws {
        try await run { try await self.client.from("trip_items").update(["is_done": done])
            .eq("id", value: item.id).execute() }
    }

    func delete(_ trip: Trip) async throws {
        try await run { try await self.client.from("trips").delete().eq("id", value: trip.id).execute() }
    }

    func delete(_ item: TripItem) async throws {
        try await run { try await self.client.from("trip_items").delete().eq("id", value: item.id).execute() }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

final class LivePrivacyService: PrivacyServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func exportData() async throws -> Data {
        let raw = try await run { try await self.client.rpc("export_my_data").execute().data }
        // Readable for the person who receives the file.
        let object = try JSONSerialization.jsonObject(with: raw)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    func erasurePlan() async throws -> ErasurePlan {
        try await run { try await self.client.rpc("account_erasure_plan").execute().value }
    }

    func removeFiles(_ files: [ErasurePlan.File]) async throws {
        for (bucket, group) in Dictionary(grouping: files, by: \.bucket) {
            // Storage accepts batches; 100 paths at a time keeps requests small.
            for start in stride(from: 0, to: group.count, by: 100) {
                let names = group[start..<min(start + 100, group.count)].map(\.name)
                _ = try await run { try await self.client.storage.from(bucket).remove(paths: names) }
            }
        }
    }

    func deleteAccount() async throws {
        try await run { try await self.client.rpc("delete_my_account").execute() }
    }

    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

// MARK: - Misconfigured

struct MisconfiguredService: AuthServicing, FamilyServicing, BudgetServicing, ListingServicing, ChildServicing, GoalServicing, NoteServicing, LoanServicing, TripServicing, PrivacyServicing {
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
    func listings(familyId: UUID) async throws -> [Listing] { throw AppError.invalidConfiguration }
    func criteria(familyId: UUID) async throws -> [Criterion] { throw AppError.invalidConfiguration }
    func answers(familyId: UUID) async throws -> [ListingAnswer] { throw AppError.invalidConfiguration }
    func comments(listingId: UUID) async throws -> [ListingComment] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, _ listing: NewListing) async throws { throw AppError.invalidConfiguration }
    func setStatus(_ listing: Listing, _ status: ListingStatus) async throws { throw AppError.invalidConfiguration }
    func setAnswer(familyId: UUID, listingId: UUID, criterionId: UUID, answer: CriterionAnswer) async throws {
        throw AppError.invalidConfiguration
    }
    func addCriterion(familyId: UUID, name: String, weight: Int) async throws { throw AppError.invalidConfiguration }
    func addComment(familyId: UUID, listingId: UUID, body: String) async throws { throw AppError.invalidConfiguration }
    func delete(_ listing: Listing) async throws { throw AppError.invalidConfiguration }
    func children(familyId: UUID) async throws -> [Child] { throw AppError.invalidConfiguration }
    func vaccinations(childId: UUID) async throws -> [ChildVaccination] { throw AppError.invalidConfiguration }
    func measurements(childId: UUID) async throws -> [Measurement] { throw AppError.invalidConfiguration }
    func illnesses(childId: UUID) async throws -> [Illness] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) async throws {
        throw AppError.invalidConfiguration
    }
    func record(familyId: UUID, childId: UUID, vaccine: String, dose: Int, on: LocalDate) async throws {
        throw AppError.invalidConfiguration
    }
    func measure(familyId: UUID, childId: UUID, on: LocalDate, heightMm: Int?, weightG: Int?) async throws {
        throw AppError.invalidConfiguration
    }
    func addIllness(familyId: UUID, childId: UUID, title: String, startedOn: LocalDate) async throws {
        throw AppError.invalidConfiguration
    }
    func delete(_ child: Child) async throws { throw AppError.invalidConfiguration }
    func goals(familyId: UUID) async throws -> [Goal] { throw AppError.invalidConfiguration }
    func entries(familyId: UUID) async throws -> [GoalEntry] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, _ goal: NewGoal) async throws { throw AppError.invalidConfiguration }
    func log(familyId: UUID, goalId: UUID, value: Decimal, on: LocalDate) async throws { throw AppError.invalidConfiguration }
    func delete(_ goal: Goal) async throws { throw AppError.invalidConfiguration }
    func notes(familyId: UUID) async throws -> [Note] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, title: String, body: String, isPrivate: Bool) async throws { throw AppError.invalidConfiguration }
    func update(_ note: Note) async throws { throw AppError.invalidConfiguration }
    func delete(_ note: Note) async throws { throw AppError.invalidConfiguration }
    func loans(familyId: UUID) async throws -> [Loan] { throw AppError.invalidConfiguration }
    func rateChanges(familyId: UUID) async throws -> [LoanRateChangeRow] { throw AppError.invalidConfiguration }
    func extras(familyId: UUID) async throws -> [LoanExtraRow] { throw AppError.invalidConfiguration }
    func payments(familyId: UUID) async throws -> [LoanPaidRow] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, _ loan: NewLoan) async throws { throw AppError.invalidConfiguration }
    func addRateChange(familyId: UUID, loanId: UUID, from: LocalDate, annualRate: Decimal) async throws {
        throw AppError.invalidConfiguration
    }
    func addExtra(familyId: UUID, loanId: UUID, on: LocalDate, amountMinor: Int64, strategy: ExtraStrategy) async throws {
        throw AppError.invalidConfiguration
    }
    func setPaid(familyId: UUID, loanId: UUID, number: Int, paid: Bool, on: LocalDate) async throws {
        throw AppError.invalidConfiguration
    }
    func delete(_ loan: Loan) async throws { throw AppError.invalidConfiguration }
    func trips(familyId: UUID) async throws -> [Trip] { throw AppError.invalidConfiguration }
    func items(familyId: UUID) async throws -> [TripItem] { throw AppError.invalidConfiguration }
    func add(familyId: UUID, _ trip: NewTrip) async throws { throw AppError.invalidConfiguration }
    func add(familyId: UUID, tripId: UUID, _ item: NewTripItem) async throws { throw AppError.invalidConfiguration }
    func setDone(_ item: TripItem, done: Bool) async throws { throw AppError.invalidConfiguration }
    func delete(_ trip: Trip) async throws { throw AppError.invalidConfiguration }
    func delete(_ item: TripItem) async throws { throw AppError.invalidConfiguration }
    func exportData() async throws -> Data { throw AppError.invalidConfiguration }
    func erasurePlan() async throws -> ErasurePlan { throw AppError.invalidConfiguration }
    func removeFiles(_ files: [ErasurePlan.File]) async throws { throw AppError.invalidConfiguration }
    func deleteAccount() async throws { throw AppError.invalidConfiguration }
}
