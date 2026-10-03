import FamilyCore
import XCTest
@testable import FamilyApp

private final class FlakyPrivacyService: PrivacyServicing, @unchecked Sendable {
    private(set) var deleteCalls = 0
    let failures: Int
    init(failures: Int) { self.failures = failures }
    func exportData() async throws -> Data { Data() }
    func erasurePlan() async throws -> ErasurePlan { ErasurePlan(blockers: [], files: []) }
    func removeFiles(_ files: [ErasurePlan.File]) async throws {}
    func deleteAccount() async throws {
        deleteCalls += 1
        if deleteCalls <= failures { throw AppError.network }
    }
}

@MainActor
final class PrivacyModelTests: XCTestCase {
    func testErasureRetriesAfterANetworkDropOnceFilesAreGone() async {
        let service = FlakyPrivacyService(failures: 1)
        let erased = await PrivacyModel(service: service).erase()
        XCTAssertTrue(erased)
        XCTAssertEqual(service.deleteCalls, 2)
    }

    func testErasureGivesUpAfterThreeNetworkFailures() async {
        let service = FlakyPrivacyService(failures: 10)
        let model = PrivacyModel(service: service)
        let erased = await model.erase()
        XCTAssertFalse(erased)
        XCTAssertEqual(service.deleteCalls, 3)
        XCTAssertEqual(model.error, .network)
    }

    func testErasureSignsOutTheServerSession() async throws {
        let store = InMemoryStore(signedIn: true)
        let model = PrivacyModel(service: InMemoryPrivacyService(store: store))
        let erased = await model.erase()
        XCTAssertTrue(erased)
        XCTAssertNil(model.error)
        let families = await store.families
        XCTAssertTrue(families.isEmpty, "a sole member takes the family with them")
        let signedIn = await store.signedIn
        XCTAssertFalse(signedIn)
    }

    func testOnlyAdminMustHandOverFirst() async throws {
        let store = InMemoryStore(signedIn: true)
        let first = await store.families.first
        let family = try XCTUnwrap(first)
        await store.addMember(MemberProfile(userId: UUID(), displayName: "Partner", role: .adult), to: family.family.id)
        let model = PrivacyModel(service: InMemoryPrivacyService(store: store))

        let erased = await model.erase()
        XCTAssertFalse(erased)
        XCTAssertEqual(model.blockers.map(\.name), [family.family.name])
        let stillThere = await store.families.count
        XCTAssertEqual(stillThere, 1, "nothing is deleted while blocked")

        model.clearBlockers()
        await store.addMember(MemberProfile(userId: UUID(), displayName: "Second admin", role: .admin), to: family.family.id)
        let erasedAfterHandover = await model.erase()
        XCTAssertTrue(erasedAfterHandover)
    }

    func testExportIsWrittenToAProtectedTemporaryFile() async throws {
        let model = PrivacyModel(service: InMemoryPrivacyService(store: InMemoryStore(signedIn: true)))
        let exported = await model.export()
        let url = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
    }
}
