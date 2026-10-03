import FamilyCore
import Foundation

protocol AuthServicing: Sendable {
    func currentUser() async -> (id: UUID, email: String?)?
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome
    func signOut() async
    func assurance() async throws -> AssuranceState
    func enrollTOTP() async throws -> TOTPEnrollment
    func verifyTOTP(factorId: String, code: String) async throws
    func handleDeepLink(_ url: URL) async throws
}

protocol FamilyServicing: Sendable {
    func memberships() async throws -> [Membership]
    func createFamily(name: String, currency: CurrencyCode) async throws -> UUID
    func members(of familyId: UUID) async throws -> [MemberProfile]
    func myInvitations() async throws -> [Invitation]
    func accept(_ invitation: Invitation) async throws
    func decline(_ invitation: Invitation) async throws
    func invite(familyId: UUID, email: String, role: MemberRole) async throws -> ActionRequestOutcome
    func requestRoleChange(familyId: UUID, userId: UUID, role: MemberRole) async throws -> ActionRequestOutcome
    func requestRemoval(familyId: UUID, userId: UUID) async throws -> ActionRequestOutcome
    func pendingApprovals(familyId: UUID) async throws -> [ApprovalRequest]
    func approve(_ request: ApprovalRequest) async throws
    func reject(_ request: ApprovalRequest) async throws
}

protocol BudgetServicing: Sendable {
    func categories(familyId: UUID) async throws -> [FamilyCore.Category]
    func transactions(familyId: UUID, month: YearMonth) async throws -> [Transaction]
    func budgets(familyId: UUID) async throws -> [Budget]
    func addTransaction(familyId: UUID, _ input: TransactionDraft.Validated, receipt: ReceiptUpload?) async throws
    func deleteTransaction(_ transaction: Transaction) async throws
    func setBudget(familyId: UUID, categoryId: UUID?, amountMinor: Int64, from month: YearMonth) async throws
}

/// The set of services the app runs with: live (Supabase) or in-memory (UI tests, previews).
struct Services: Sendable {
    let auth: any AuthServicing
    let family: any FamilyServicing
    let budget: any BudgetServicing
    let listings: any ListingServicing

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> Services {
        #if DEBUG
        if arguments.contains("-ui-testing") {
            return .inMemory(startSignedIn: arguments.contains("-signed-in"))
        }
        #endif
        do {
            let client = try SupabaseClientFactory.make()
            return Services(
                auth: LiveAuthService(client: client),
                family: LiveFamilyService(client: client),
                budget: LiveBudgetService(client: client),
                listings: LiveListingService(client: client)
            )
        } catch {
            return .misconfigured
        }
    }

    #if DEBUG
    static func inMemory(startSignedIn: Bool = false) -> Services {
        let store = InMemoryStore(signedIn: startSignedIn)
        return Services(auth: InMemoryAuthService(store: store),
                        family: InMemoryFamilyService(store: store),
                        budget: InMemoryBudgetService(store: store),
                        listings: InMemoryListingService(store: store))
    }
    #endif

    /// Used when Info.plist has no valid Supabase settings: every call fails clearly.
    static let misconfigured = Services(auth: MisconfiguredService(), family: MisconfiguredService(),
                                        budget: MisconfiguredService(), listings: MisconfiguredService())
}

protocol ListingServicing: Sendable {
    func listings(familyId: UUID) async throws -> [Listing]
    func criteria(familyId: UUID) async throws -> [Criterion]
    func answers(familyId: UUID) async throws -> [ListingAnswer]
    func comments(listingId: UUID) async throws -> [ListingComment]
    func add(familyId: UUID, _ listing: NewListing) async throws
    func setStatus(_ listing: Listing, _ status: ListingStatus) async throws
    func setAnswer(familyId: UUID, listingId: UUID, criterionId: UUID, answer: CriterionAnswer) async throws
    func addCriterion(familyId: UUID, name: String, weight: Int) async throws
    func addComment(familyId: UUID, listingId: UUID, body: String) async throws
    func delete(_ listing: Listing) async throws
}
