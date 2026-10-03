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
    var notes: [Note] = []
    var loanRows: [Loan] = []
    var loanRates: [LoanRateChangeRow] = []
    var loanExtras: [LoanExtraRow] = []
    var loanPaid: [LoanPaidRow] = []
    var tripRows: [Trip] = []
    var tripItemRows: [TripItem] = []
    var sportRows: [ChildSport] = []

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

    func addNote(familyId: UUID, title: String, body: String, isPrivate: Bool) throws {
        try requireAdult(familyId)
        guard !(title.trimmingCharacters(in: .whitespaces).isEmpty && body.trimmingCharacters(in: .whitespaces).isEmpty) else {
            throw AppError.unknown
        }
        notes.append(Note(id: UUID(), familyId: familyId, title: title, body: body, isPrivate: isPrivate,
                          pinned: false, updatedAt: Date()))
    }

    func updateNote(_ note: Note) throws {
        try requireAdult(note.familyId)
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { throw AppError.notFound }
        notes[index].title = note.title
        notes[index].body = note.body
        notes[index].pinned = note.pinned
        notes[index].updatedAt = Date()
    }

    func deleteNote(_ note: Note) throws {
        try requireAdult(note.familyId)
        notes.removeAll { $0.id == note.id }
    }

    func addLoan(familyId: UUID, _ new: NewLoan) throws {
        try requireAdult(familyId)
        loanRows.append(Loan(id: UUID(), familyId: familyId, title: new.title, lender: new.lender,
                             principalMinor: new.principalMinor, currency: new.currency, annualRate: new.annualRate,
                             termMonths: new.termMonths, firstPaymentOn: new.firstPaymentOn, loanType: new.type))
    }

    func addLoanRate(familyId: UUID, loanId: UUID, from: LocalDate, annualRate: Decimal) throws {
        try requireAdult(familyId)
        guard !loanRates.contains(where: { $0.loanId == loanId && $0.effectiveFrom == from }) else { throw AppError.conflict }
        loanRates.append(LoanRateChangeRow(id: UUID(), loanId: loanId, effectiveFrom: from, annualRate: annualRate))
    }

    func addLoanExtra(familyId: UUID, loanId: UUID, on day: LocalDate, amountMinor: Int64, strategy: ExtraStrategy) throws {
        try requireAdult(familyId)
        loanExtras.append(LoanExtraRow(id: UUID(), loanId: loanId, paidOn: day, amountMinor: amountMinor, strategy: strategy))
    }

    func setLoanPaid(familyId: UUID, loanId: UUID, number: Int, paid: Bool, on day: LocalDate) throws {
        try requireAdult(familyId)
        loanPaid.removeAll { $0.loanId == loanId && $0.installmentNo == number }
        if paid { loanPaid.append(LoanPaidRow(loanId: loanId, installmentNo: number, paidOn: day)) }
    }

    func addTrip(familyId: UUID, _ new: NewTrip) throws {
        try requireAdult(familyId)
        guard new.endsOn >= new.startsOn, new.budgetMinor >= 0 else { throw AppError.unknown }
        tripRows.append(Trip(id: UUID(), familyId: familyId, title: new.title, destination: new.destination,
                             startsOn: new.startsOn, endsOn: new.endsOn, currency: new.currency, budgetMinor: new.budgetMinor, notes: nil))
    }

    func addTripItem(familyId: UUID, tripId: UUID, _ new: NewTripItem) throws {
        try requireAdult(familyId)
        guard tripRows.contains(where: { $0.id == tripId && $0.familyId == familyId }), new.costMinor >= 0 else { throw AppError.forbidden }
        tripItemRows.append(TripItem(id: UUID(), tripId: tripId, kind: new.kind, title: new.title, day: new.day,
                                     costMinor: new.costMinor, isDone: false, link: new.link))
    }

    func setTripItemDone(_ item: TripItem, done: Bool) throws {
        guard let trip = tripRows.first(where: { $0.id == item.tripId }) else { throw AppError.notFound }
        try requireAdult(trip.familyId)
        if let index = tripItemRows.firstIndex(where: { $0.id == item.id }) { tripItemRows[index].isDone = done }
    }

    func deleteTrip(_ trip: Trip) throws {
        try requireAdult(trip.familyId)
        tripRows.removeAll { $0.id == trip.id }
        tripItemRows.removeAll { $0.tripId == trip.id }
    }

    func deleteTripItem(_ item: TripItem) throws {
        guard let trip = tripRows.first(where: { $0.id == item.tripId }) else { throw AppError.notFound }
        try requireAdult(trip.familyId)
        tripItemRows.removeAll { $0.id == item.id }
    }

    /// Mirrors `account_erasure_plan` / `delete_my_account` closely enough for UI tests and models.
    func addMember(_ profile: MemberProfile, to familyId: UUID) { members[familyId, default: []].append(profile) }

    func erasureBlockers() throws -> [ErasurePlan.Blocker] {
        try requireMFA()
        return families.compactMap { membership in
            let others = (members[membership.family.id] ?? []).filter { $0.userId != userId }
            let otherAdmins = others.filter { $0.role == .admin }
            return membership.role == .admin && !others.isEmpty && otherAdmins.isEmpty
                ? ErasurePlan.Blocker(name: membership.family.name) : nil
        }
    }

    func eraseAccount() throws {
        guard try erasureBlockers().isEmpty else { throw AppError.conflict }
        families = []
        members = [:]
        signedIn = false
        mfaVerified = false
    }

    func addSport(familyId: UUID, _ new: NewChildSport) throws {
        try requireAdult(familyId)
        guard kids.contains(where: { $0.id == new.childId && $0.familyId == familyId }) else { throw AppError.forbidden }
        let shapeOK = new.kind == .training
            ? new.weekday != nil && new.onDate == nil
            : new.onDate != nil && new.weekday == nil && new.untilDate == nil
        guard shapeOK, (0..<1440).contains(new.startMinute), new.startMinute + new.durationMinutes <= 1440 else { throw AppError.unknown }
        sportRows.append(ChildSport(id: UUID(), childId: new.childId, kind: new.kind, title: new.title, location: new.location,
                                    weekday: new.weekday, onDate: new.onDate, startMinute: new.startMinute,
                                    durationMinutes: new.durationMinutes, untilDate: new.untilDate))
    }

    func deleteSport(_ sport: ChildSport) throws {
        guard let child = kids.first(where: { $0.id == sport.childId }) else { throw AppError.notFound }
        try requireAdult(child.familyId)
        sportRows.removeAll { $0.id == sport.id }
    }

    func deleteLoan(_ loan: Loan) throws {
        try requireAdult(loan.familyId)
        loanRows.removeAll { $0.id == loan.id }
        loanRates.removeAll { $0.loanId == loan.id }
        loanExtras.removeAll { $0.loanId == loan.id }
        loanPaid.removeAll { $0.loanId == loan.id }
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
final class InMemoryNoteService: NoteServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func notes(familyId: UUID) async throws -> [Note] {
        try await store.requireAdult(familyId)
        return await store.notes.filter { $0.familyId == familyId }
    }
    func add(familyId: UUID, title: String, body: String, isPrivate: Bool) async throws {
        try await store.addNote(familyId: familyId, title: title, body: body, isPrivate: isPrivate)
    }
    func update(_ note: Note) async throws { try await store.updateNote(note) }
    func delete(_ note: Note) async throws { try await store.deleteNote(note) }
}
final class InMemoryLoanService: LoanServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func loans(familyId: UUID) async throws -> [Loan] {
        try await store.requireAdult(familyId)
        return await store.loanRows.filter { $0.familyId == familyId }
    }
    func rateChanges(familyId: UUID) async throws -> [LoanRateChangeRow] { await store.loanRates }
    func extras(familyId: UUID) async throws -> [LoanExtraRow] { await store.loanExtras }
    func payments(familyId: UUID) async throws -> [LoanPaidRow] { await store.loanPaid }
    func add(familyId: UUID, _ loan: NewLoan) async throws { try await store.addLoan(familyId: familyId, loan) }
    func addRateChange(familyId: UUID, loanId: UUID, from: LocalDate, annualRate: Decimal) async throws {
        try await store.addLoanRate(familyId: familyId, loanId: loanId, from: from, annualRate: annualRate)
    }
    func addExtra(familyId: UUID, loanId: UUID, on day: LocalDate, amountMinor: Int64, strategy: ExtraStrategy) async throws {
        try await store.addLoanExtra(familyId: familyId, loanId: loanId, on: day, amountMinor: amountMinor, strategy: strategy)
    }
    func setPaid(familyId: UUID, loanId: UUID, number: Int, paid: Bool, on day: LocalDate) async throws {
        try await store.setLoanPaid(familyId: familyId, loanId: loanId, number: number, paid: paid, on: day)
    }
    func delete(_ loan: Loan) async throws { try await store.deleteLoan(loan) }
}

final class InMemoryTripService: TripServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func trips(familyId: UUID) async throws -> [Trip] {
        try await store.requireAdult(familyId)
        return await store.tripRows.filter { $0.familyId == familyId }
    }
    func items(familyId: UUID) async throws -> [TripItem] {
        try await store.requireAdult(familyId)
        let ids = await Set(store.tripRows.filter { $0.familyId == familyId }.map(\.id))
        return await store.tripItemRows.filter { ids.contains($0.tripId) }
    }
    func add(familyId: UUID, _ trip: NewTrip) async throws { try await store.addTrip(familyId: familyId, trip) }
    func add(familyId: UUID, tripId: UUID, _ item: NewTripItem) async throws {
        try await store.addTripItem(familyId: familyId, tripId: tripId, item)
    }
    func setDone(_ item: TripItem, done: Bool) async throws { try await store.setTripItemDone(item, done: done) }
    func delete(_ trip: Trip) async throws { try await store.deleteTrip(trip) }
    func delete(_ item: TripItem) async throws { try await store.deleteTripItem(item) }
}

final class InMemoryPrivacyService: PrivacyServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func exportData() async throws -> Data { Data("{\"exported\": true}".utf8) }
    func erasurePlan() async throws -> ErasurePlan { ErasurePlan(blockers: try await store.erasureBlockers(), files: []) }
    func removeFiles(_ files: [ErasurePlan.File]) async throws {}
    func deleteAccount() async throws { try await store.eraseAccount() }
}

final class InMemorySportService: SportServicing {
    let store: InMemoryStore
    init(store: InMemoryStore) { self.store = store }

    func sports(familyId: UUID) async throws -> [ChildSport] {
        try await store.requireAdult(familyId)
        let childIds = await Set(store.kids.filter { $0.familyId == familyId }.map(\.id))
        return await store.sportRows.filter { childIds.contains($0.childId) }
    }
    func add(familyId: UUID, _ sport: NewChildSport) async throws { try await store.addSport(familyId: familyId, sport) }
    func delete(_ sport: ChildSport) async throws { try await store.deleteSport(sport) }
}
#endif
