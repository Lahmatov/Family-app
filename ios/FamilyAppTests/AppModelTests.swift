import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class AppModelTests: XCTestCase {
    /// Fresh, isolated defaults for each test.
    private var defaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "AppModelTests-\(name)")!
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: "AppModelTests-\(name)")
        super.tearDown()
    }

    func testSignedOutWithoutSession() async {
        let model = AppModel(services: .inMemory(), defaults: defaults)
        await model.refresh()
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testPasswordAloneIsNotEnough() async throws {
        let services = Services.inMemory()
        let model = AppModel(services: services, defaults: defaults)
        try await services.auth.signIn(email: "parent@example.com", password: InMemoryStore.testPassword)
        await model.refresh()
        XCTAssertEqual(model.phase, .mfaEnrollment, "a new account must set up the second factor first")
        XCTAssertTrue(model.memberships.isEmpty)
    }

    func testFullOnboardingGates() async throws {
        let services = Services.inMemory()
        let model = AppModel(services: services, defaults: defaults)
        try await services.auth.signIn(email: "parent@example.com", password: InMemoryStore.testPassword)

        let enrollment = try await services.auth.enrollTOTP()
        do {
            try await services.auth.verifyTOTP(factorId: enrollment.factorId, code: "000000")
            XCTFail("wrong code must be rejected")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidCode)
        }
        try await services.auth.verifyTOTP(factorId: enrollment.factorId, code: InMemoryStore.testCode)
        await model.refresh()
        XCTAssertEqual(model.phase, .noFamily)

        let id = try await services.family.createFamily(name: "Lahmatov", currency: .eur)
        model.selectedFamilyId = id
        try await model.loadMemberships()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.currentMembership?.role, .admin)
        XCTAssertEqual(defaults.string(forKey: "selectedFamilyId"), id.uuidString)
    }

    func testReturningUserGetsChallenge() async throws {
        let services = Services.inMemory(startSignedIn: true)
        await services.auth.signOut()
        try await services.auth.signIn(email: "parent@example.com", password: InMemoryStore.testPassword)
        let model = AppModel(services: services, defaults: defaults)
        await model.refresh()
        guard case .mfaChallenge = model.phase else {
            return XCTFail("expected MFA challenge, got \(model.phase)")
        }
    }

    func testSignOutClearsState() async {
        let model = AppModel(services: .inMemory(startSignedIn: true), defaults: defaults)
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.userId)
        XCTAssertTrue(model.memberships.isEmpty)
    }

    func testMisconfiguredBackendFailsClosed() async {
        let model = AppModel(services: .misconfigured, defaults: defaults)
        await model.refresh()
        XCTAssertEqual(model.phase, .signedOut)
        do {
            try await model.services.auth.signIn(email: "a@b.c", password: "x")
            XCTFail("must not sign in")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidConfiguration)
        }
    }
}

@MainActor
final class BudgetModelTests: XCTestCase {
    func testAddAndSummarise() async throws {
        let services = Services.inMemory(startSignedIn: true)
        let membership = try await services.family.memberships()[0]
        let model = BudgetModel(family: membership.family, role: membership.role, service: services.budget,
                                today: { LocalDate("2026-10-10")! })
        await model.load()
        let groceries = try XCTUnwrap(model.categories.first { $0.systemKey == "groceries" })

        let draft = TransactionDraft(amountText: "45,50", currency: .eur, categoryId: groceries.id,
                                     occurredOn: LocalDate("2026-10-05")!)
        try await model.add(draft.validate(baseCurrency: .eur).get(), receipt: nil)
        try await model.setBudget(categoryId: groceries.id, amount: Money(minorUnits: 50_000, currency: .eur))

        XCTAssertEqual(model.overall?.spent.minorUnits, 4550)
        XCTAssertEqual(model.statuses.first { $0.categoryId == groceries.id }?.remaining?.minorUnits, 45_450)
        XCTAssertFalse(model.canGoForward)
        await model.showPreviousMonth()
        XCTAssertEqual(model.month.description, "2026-09")
        XCTAssertTrue(model.transactions.isEmpty)
    }

    func testChildHasNoFinanceAccess() async {
        let family = Family(id: UUID(), name: "F", baseCurrency: .eur)
        let model = BudgetModel(family: family, role: .child, service: Services.inMemory().budget)
        await model.load()
        XCTAssertTrue(model.transactions.isEmpty)
        XCTAssertNil(model.error)
    }
}
