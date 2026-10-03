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
    var listings: [Listing] = []
    var criteria: [Criterion] = []
    var answers: [ListingAnswer] = []
    var comments: [ListingComment] = []
    var kids: [Child] = []
    var vaccinations: [ChildVaccination] = []
    var measurements: [Measurement] = []
    var illnesses: [Illness] = []
    var goals: [Goal] = []
    var goalEntries: [GoalEntry] = []

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

    func requireAdult(_ familyId: UUID) throws {
        try requireMFA()
        guard role(in: familyId)?.isAtLeast(.adult) == true else { throw AppError.forbidden }
    }

    func addListing(familyId: UUID, _ new: NewListing) throws {
        try requireAdult(familyId)
        guard !listings.contains(where: { $0.familyId == familyId && $0.url == new.link.url }) else {
            throw AppError.conflict
        }
        listings.append(Listing(id: UUID(), familyId: familyId, url: new.link.url, source: new.link.source,
                                title: new.title, priceMinor: new.priceMinor, currency: .eur, areaM2: new.areaM2,
                                rooms: new.rooms, address: new.address, lat: new.lat, lng: new.lng,
                                status: .new, createdBy: userId))
    }

    func setStatus(_ listing: Listing, _ status: ListingStatus) throws {
        try requireAdult(listing.familyId)
        if let index = listings.firstIndex(where: { $0.id == listing.id }) { listings[index].status = status }
    }

    func setAnswer(familyId: UUID, listingId: UUID, criterionId: UUID, answer: CriterionAnswer) throws {
        try requireAdult(familyId)
        answers.removeAll { $0.listingId == listingId && $0.criterionId == criterionId }
        answers.append(ListingAnswer(listingId: listingId, criterionId: criterionId, answer: answer))
    }

    func addCriterion(familyId: UUID, name: String, weight: Int) throws {
        try requireAdult(familyId)
        criteria.append(Criterion(id: UUID(), name: name, weight: weight))
    }

    func addComment(familyId: UUID, listingId: UUID, body: String) throws {
        try requireAdult(familyId)
        comments.append(ListingComment(id: UUID(), listingId: listingId, body: body, createdBy: userId, createdAt: Date()))
    }

    func addChild(familyId: UUID, name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) throws {
        try requireAdult(familyId)
        kids.append(Child(id: UUID(), familyId: familyId, name: name, birthDate: birthDate, sex: sex,
                          bloodType: bloodType, allergies: allergies))
    }

    func recordVaccination(familyId: UUID, childId: UUID, vaccine: String, dose: Int, on day: LocalDate) throws {
        try requireAdult(familyId)
        guard !vaccinations.contains(where: { $0.childId == childId && $0.vaccineCode == vaccine && $0.dose == dose }) else {
            throw AppError.conflict
        }
        vaccinations.append(ChildVaccination(id: UUID(), childId: childId, vaccineCode: vaccine, dose: dose, givenOn: day))
    }

    func addMeasurement(familyId: UUID, childId: UUID, on day: LocalDate, heightMm: Int?, weightG: Int?) throws {
        try requireAdult(familyId)
        measurements.append(Measurement(id: UUID(), childId: childId, measuredOn: day, heightMm: heightMm, weightG: weightG))
    }

    func addIllness(familyId: UUID, childId: UUID, title: String, startedOn: LocalDate) throws {
        try requireAdult(familyId)
        illnesses.append(Illness(id: UUID(), childId: childId, title: title, startedOn: startedOn, endedOn: nil))
    }

    func addGoal(familyId: UUID, _ new: NewGoal) throws {
        try requireAdult(familyId)
        goals.append(Goal(id: UUID(), familyId: familyId, kind: new.kind, title: new.title, unit: new.unit,
                          startValue: new.start, targetValue: new.target, startsOn: new.startsOn,
                          deadline: new.deadline, isPrivate: new.isPrivate))
    }

    func logGoal(familyId: UUID, goalId: UUID, value: Decimal, on day: LocalDate) throws {
        try requireAdult(familyId)
        goalEntries.removeAll { $0.goalId == goalId && $0.recordedOn == day }
        goalEntries.append(GoalEntry(id: UUID(), goalId: goalId, value: value, recordedOn: day, note: nil))
    }

    func deleteGoal(_ goal: Goal) throws {
        try requireAdult(goal.familyId)
        goals.removeAll { $0.id == goal.id }
        goalEntries.removeAll { $0.goalId == goal.id }
    }

    func deleteChild(_ child: Child) throws {
        guard role(in: child.familyId) == .admin else { throw AppError.forbidden }
        kids.removeAll { $0.id == child.id }
    }

    func deleteListing(_ listing: Listing) throws {
        try requireAdult(listing.familyId)
        listings.removeAll { $0.id == listing.id }
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

final class InMemoryListingService: ListingServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func listings(familyId: UUID) async throws -> [Listing] {
        try await store.requireAdult(familyId)
        return await store.listings.filter { $0.familyId == familyId }
    }
    func criteria(familyId: UUID) async throws -> [Criterion] { await store.criteria }
    func answers(familyId: UUID) async throws -> [ListingAnswer] { await store.answers }
    func comments(listingId: UUID) async throws -> [ListingComment] {
        await store.comments.filter { $0.listingId == listingId }
    }
    func add(familyId: UUID, _ listing: NewListing) async throws { try await store.addListing(familyId: familyId, listing) }
    func setStatus(_ listing: Listing, _ status: ListingStatus) async throws { try await store.setStatus(listing, status) }
    func setAnswer(familyId: UUID, listingId: UUID, criterionId: UUID, answer: CriterionAnswer) async throws {
        try await store.setAnswer(familyId: familyId, listingId: listingId, criterionId: criterionId, answer: answer)
    }
    func addCriterion(familyId: UUID, name: String, weight: Int) async throws {
        try await store.addCriterion(familyId: familyId, name: name, weight: weight)
    }
    func addComment(familyId: UUID, listingId: UUID, body: String) async throws {
        try await store.addComment(familyId: familyId, listingId: listingId, body: body)
    }
    func delete(_ listing: Listing) async throws { try await store.deleteListing(listing) }
}
final class InMemoryChildService: ChildServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func children(familyId: UUID) async throws -> [Child] {
        try await store.requireAdult(familyId)
        return await store.kids.filter { $0.familyId == familyId }
    }
    func vaccinations(childId: UUID) async throws -> [ChildVaccination] { await store.vaccinations.filter { $0.childId == childId } }
    func measurements(childId: UUID) async throws -> [Measurement] { await store.measurements.filter { $0.childId == childId } }
    func illnesses(childId: UUID) async throws -> [Illness] { await store.illnesses.filter { $0.childId == childId } }
    func add(familyId: UUID, name: String, birthDate: LocalDate, sex: ChildSex, bloodType: String?, allergies: String?) async throws {
        try await store.addChild(familyId: familyId, name: name, birthDate: birthDate, sex: sex, bloodType: bloodType, allergies: allergies)
    }
    func record(familyId: UUID, childId: UUID, vaccine: String, dose: Int, on day: LocalDate) async throws {
        try await store.recordVaccination(familyId: familyId, childId: childId, vaccine: vaccine, dose: dose, on: day)
    }
    func measure(familyId: UUID, childId: UUID, on day: LocalDate, heightMm: Int?, weightG: Int?) async throws {
        try await store.addMeasurement(familyId: familyId, childId: childId, on: day, heightMm: heightMm, weightG: weightG)
    }
    func addIllness(familyId: UUID, childId: UUID, title: String, startedOn: LocalDate) async throws {
        try await store.addIllness(familyId: familyId, childId: childId, title: title, startedOn: startedOn)
    }
    func delete(_ child: Child) async throws { try await store.deleteChild(child) }
}
final class InMemoryGoalService: GoalServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func goals(familyId: UUID) async throws -> [Goal] {
        try await store.requireAdult(familyId)
        return await store.goals.filter { $0.familyId == familyId }
    }
    func entries(familyId: UUID) async throws -> [GoalEntry] { await store.goalEntries }
    func add(familyId: UUID, _ goal: NewGoal) async throws { try await store.addGoal(familyId: familyId, goal) }
    func log(familyId: UUID, goalId: UUID, value: Decimal, on day: LocalDate) async throws {
        try await store.logGoal(familyId: familyId, goalId: goalId, value: value, on: day)
    }
    func delete(_ goal: Goal) async throws { try await store.deleteGoal(goal) }
}
#endif
