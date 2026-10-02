#if DEBUG
import FamilyCore
import Foundation

/// In-memory backend for UI tests (`-ui-testing`) and SwiftUI previews.
/// Implements the same rules the database enforces where the UI depends on them.
actor InMemoryStore {
    static let testPassword = "Correct-Horse-1"
    static let testCode = "123456"

    let userId = UUID()
    let email = "parent@example.com"
    var signedIn: Bool
    var mfaVerified: Bool
    var factorId: String?
    var families: [Membership] = []
    var members: [UUID: [MemberProfile]] = [:]
    var categories: [UUID: [FamilyCore.Category]] = [:]
    var transactions: [Transaction] = []
    var budgets: [Budget] = []
    var invitations: [Invitation] = []
    var approvals: [ApprovalRequest] = []

    init(signedIn: Bool) {
        self.signedIn = signedIn
        self.mfaVerified = signedIn
        self.factorId = signedIn ? UUID().uuidString : nil
        if signedIn {
            let family = Family(id: UUID(), name: "Demo", baseCurrency: .eur)
            Self.seed(family: family, into: &categories)
            families = [Membership(family: family, role: .admin)]
            members[family.id] = [MemberProfile(userId: userId, displayName: "Parent", role: .admin)]
        }
    }

    static func seed(family: Family, into categories: inout [UUID: [FamilyCore.Category]]) {
        let defaults: [(String, String)] = [("groceries", "cart"), ("housing", "house"), ("transport", "car"),
                                            ("kids", "figure.and.child.holdinghands"), ("other", "ellipsis.circle")]
        categories[family.id] = defaults.enumerated().map { index, item in
            FamilyCore.Category(id: UUID(), familyId: family.id, kind: .expense, systemKey: item.0, name: nil,
                                icon: item.1, color: "#34C759", sortOrder: index, archived: false)
        } + [FamilyCore.Category(id: UUID(), familyId: family.id, kind: .income, systemKey: "salary", name: nil,
                                 icon: "briefcase", color: "#34C759", sortOrder: 0, archived: false)]
    }

    func signIn(email: String, password: String) throws {
        guard email.lowercased() == self.email, password == Self.testPassword else { throw AppError.invalidCredentials }
        signedIn = true
        mfaVerified = false
    }

    func signOut() {
        signedIn = false
        mfaVerified = false
    }

    func assurance() throws -> AssuranceState {
        guard signedIn else { throw AppError.forbidden }
        if mfaVerified { return .verified }
        if let factorId { return .challengeRequired(factorId: factorId) }
        return .enrollmentRequired
    }

    func enroll() -> TOTPEnrollment {
        let id = UUID().uuidString
        factorId = id
        return TOTPEnrollment(factorId: id, uri: "otpauth://totp/Family:\(email)?secret=JBSWY3DPEHPK3PXP&issuer=Family",
                              secret: "JBSWY3DPEHPK3PXP")
    }

    func verify(factorId: String, code: String) throws {
        guard factorId == self.factorId, code == Self.testCode else { throw AppError.invalidCode }
        mfaVerified = true
    }

    func requireMFA() throws {
        guard signedIn, mfaVerified else { throw AppError.forbidden }
    }

    func role(in familyId: UUID) -> MemberRole? {
        families.first { $0.family.id == familyId }?.role
    }

    func createFamily(name: String, currency: CurrencyCode) throws -> UUID {
        try requireMFA()
        let family = Family(id: UUID(), name: name, baseCurrency: currency)
        families.append(Membership(family: family, role: .admin))
        members[family.id] = [MemberProfile(userId: userId, displayName: "Parent", role: .admin)]
        Self.seed(family: family, into: &categories)
        return family.id
    }

    func addTransaction(familyId: UUID, input: TransactionDraft.Validated) throws {
        try requireMFA()
        guard role(in: familyId)?.can(.addTransactions) == true else { throw AppError.forbidden }
        transactions.append(Transaction(
            id: UUID(), familyId: familyId, kind: input.kind, amountMinor: input.amount.minorUnits,
            currency: input.amount.currency, fxRate: input.fxRate, amountBaseMinor: input.amountInBase.minorUnits,
            categoryId: input.categoryId, occurredOn: input.occurredOn, merchant: input.merchant, note: input.note,
            paidBy: input.paidBy, isPrivate: input.isPrivate, createdBy: userId
        ))
    }

    func setBudget(familyId: UUID, categoryId: UUID?, amountMinor: Int64, month: YearMonth) throws {
        try requireMFA()
        guard role(in: familyId) == .admin else { throw AppError.forbidden }
        budgets.removeAll { $0.familyId == familyId && $0.categoryId == categoryId && $0.validFrom == month.firstDay }
        budgets.append(Budget(id: UUID(), familyId: familyId, categoryId: categoryId, amountMinor: amountMinor,
                              validFrom: month.firstDay))
    }

    func invite(familyId: UUID, email: String, role: MemberRole) throws -> ActionRequestOutcome {
        try requireMFA()
        guard self.role(in: familyId) == .admin else { throw AppError.forbidden }
        let adminCount = members[familyId, default: []].filter { $0.role == .admin }.count
        if ApprovalPolicy.requiresSecondAdmin(adminCount: adminCount) {
            approvals.append(ApprovalRequest(id: UUID(), familyId: familyId, action: .inviteMember,
                                             payload: ["email": email, "role": role.rawValue], status: .pending,
                                             requestedBy: userId, expiresAt: Date().addingTimeInterval(7 * 86400)))
            return .pendingApproval
        }
        invitations.append(Invitation(id: UUID(), familyId: familyId, email: email.lowercased(), role: role,
                                      expiresAt: Date().addingTimeInterval(14 * 86400)))
        return .executed
    }

    func deleteTransaction(id: UUID) {
        transactions.removeAll { $0.id == id }
    }
}

final class InMemoryAuthService: AuthServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func currentUser() async -> (id: UUID, email: String?)? {
        guard await store.signedIn else { return nil }
        return (store.userId, store.email)
    }
    func signIn(email: String, password: String) async throws { try await store.signIn(email: email, password: password) }
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome { .confirmEmail }
    func signOut() async { await store.signOut() }
    func assurance() async throws -> AssuranceState { try await store.assurance() }
    func enrollTOTP() async throws -> TOTPEnrollment { await store.enroll() }
    func verifyTOTP(factorId: String, code: String) async throws { try await store.verify(factorId: factorId, code: code) }
    func handleDeepLink(_ url: URL) async throws {}
}

final class InMemoryFamilyService: FamilyServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func memberships() async throws -> [Membership] {
        try await store.requireMFA()
        return await store.families
    }
    func createFamily(name: String, currency: CurrencyCode) async throws -> UUID {
        try await store.createFamily(name: name, currency: currency)
    }
    func members(of familyId: UUID) async throws -> [MemberProfile] { await store.members[familyId] ?? [] }
    func myInvitations() async throws -> [Invitation] { [] }
    func accept(_ invitation: Invitation) async throws {}
    func decline(_ invitation: Invitation) async throws {}
    func invite(familyId: UUID, email: String, role: MemberRole) async throws -> ActionRequestOutcome {
        try await store.invite(familyId: familyId, email: email, role: role)
    }
    func requestRoleChange(familyId: UUID, userId: UUID, role: MemberRole) async throws -> ActionRequestOutcome {
        .pendingApproval
    }
    func requestRemoval(familyId: UUID, userId: UUID) async throws -> ActionRequestOutcome { .pendingApproval }
    func pendingApprovals(familyId: UUID) async throws -> [ApprovalRequest] {
        await store.approvals.filter { $0.familyId == familyId && $0.status == .pending }
    }
    func approve(_ request: ApprovalRequest) async throws { throw AppError.forbidden }
    func reject(_ request: ApprovalRequest) async throws {}
}

final class InMemoryBudgetService: BudgetServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func categories(familyId: UUID) async throws -> [FamilyCore.Category] { await store.categories[familyId] ?? [] }
    func transactions(familyId: UUID, month: YearMonth) async throws -> [Transaction] {
        await store.transactions
            .filter { $0.familyId == familyId && month.contains($0.occurredOn) }
            .sorted { $0.occurredOn > $1.occurredOn }
    }
    func budgets(familyId: UUID) async throws -> [Budget] { await store.budgets.filter { $0.familyId == familyId } }
    func addTransaction(familyId: UUID, _ input: TransactionDraft.Validated, receipt: ReceiptUpload?) async throws {
        try await store.addTransaction(familyId: familyId, input: input)
    }
    func deleteTransaction(_ transaction: Transaction) async throws { await store.deleteTransaction(id: transaction.id) }
    func setBudget(familyId: UUID, categoryId: UUID?, amountMinor: Int64, from month: YearMonth) async throws {
        try await store.setBudget(familyId: familyId, categoryId: categoryId, amountMinor: amountMinor, month: month)
    }
}
#endif
