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
    let children: any ChildServicing
    let goals: any GoalServicing
    let notes: any NoteServicing
    let loans: any LoanServicing

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
                listings: LiveListingService(client: client),
                children: LiveChildService(client: client),
                goals: LiveGoalService(client: client),
                notes: LiveNoteService(client: client),
                loans: LiveLoanService(client: client)
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
                        listings: InMemoryListingService(store: store),
                        children: InMemoryChildService(store: store),
                        goals: InMemoryGoalService(store: store),
                        notes: InMemoryNoteService(store: store),
                        loans: InMemoryLoanService(store: store))
    }
    #endif

    /// Used when Info.plist has no valid Supabase settings: every call fails clearly.
    static let misconfigured = Services(auth: MisconfiguredService(), family: MisconfiguredService(),
                                        budget: MisconfiguredService(), listings: MisconfiguredService(),
                                        children: MisconfiguredService(), goals: MisconfiguredService(),
                                        notes: MisconfiguredService(), loans: MisconfiguredService())
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

protocol ChildServicing: Sendable {
    func children(familyId: UUID) async throws -> [Child]
    func vaccinations(childId: UUID) async throws -> [ChildVaccination]
    func measurements(childId: UUID) async throws -> [Measurement]
    func illnesses(childId: UUID) async throws -> [Illness]
    func add(familyId: UUID, name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) async throws
    func record(familyId: UUID, childId: UUID, vaccine: String, dose: Int, on: LocalDate) async throws
    func measure(familyId: UUID, childId: UUID, on: LocalDate, heightMm: Int?, weightG: Int?) async throws
    func addIllness(familyId: UUID, childId: UUID, title: String, startedOn: LocalDate) async throws
    func delete(_ child: Child) async throws
}

protocol GoalServicing: Sendable {
    func goals(familyId: UUID) async throws -> [Goal]
    func entries(familyId: UUID) async throws -> [GoalEntry]
    func add(familyId: UUID, _ goal: NewGoal) async throws
    func log(familyId: UUID, goalId: UUID, value: Decimal, on: LocalDate) async throws
    func delete(_ goal: Goal) async throws
}

protocol NoteServicing: Sendable {
    func notes(familyId: UUID) async throws -> [Note]
    func add(familyId: UUID, title: String, body: String, isPrivate: Bool) async throws
    func update(_ note: Note) async throws
    func delete(_ note: Note) async throws
}

protocol LoanServicing: Sendable {
    func loans(familyId: UUID) async throws -> [Loan]
    func rateChanges(familyId: UUID) async throws -> [LoanRateChangeRow]
    func extras(familyId: UUID) async throws -> [LoanExtraRow]
    func payments(familyId: UUID) async throws -> [LoanPaidRow]
    func add(familyId: UUID, _ loan: NewLoan) async throws
    func addRateChange(familyId: UUID, loanId: UUID, from: LocalDate, annualRate: Decimal) async throws
    func addExtra(familyId: UUID, loanId: UUID, on: LocalDate, amountMinor: Int64, strategy: ExtraStrategy) async throws
    func setPaid(familyId: UUID, loanId: UUID, number: Int, paid: Bool, on: LocalDate) async throws
    func delete(_ loan: Loan) async throws
}
