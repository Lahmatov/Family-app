import FamilyCore
import XCTest
@testable import FamilyApp

@MainActor
final class VaultModelTests: XCTestCase {
    private let familyId = UUID()
    private let backend = InMemoryVaultBackend()
    private let alice = MemberProfile(userId: UUID(), displayName: "Alice", role: .admin)
    private let bob = MemberProfile(userId: UUID(), displayName: "Bob", role: .adult)
    private lazy var everyone = [alice, bob]

    private func device(_ person: MemberProfile, identities: InMemoryIdentityStore = InMemoryIdentityStore()) -> (VaultModel, InMemoryIdentityStore) {
        let members = everyone
        let model = VaultModel(userId: person.userId, familyId: familyId, role: person.role,
                               service: InMemoryVaultService(backend: backend, userId: person.userId),
                               identities: identities, members: { members })
        return (model, identities)
    }

    private func setUp(_ person: MemberProfile) async throws -> (VaultModel, String) {
        let (model, _) = device(person)
        await model.start()
        XCTAssertEqual(model.phase, .needsSetup)
        let recovery = try await model.createVault()
        await model.finishSetup()
        XCTAssertEqual(model.phase, .ready)
        return (model, recovery)
    }

    func testAddAndOpenRoundTripAndServerSeesNoPlaintext() async throws {
        let (model, _) = try await setUp(alice)
        XCTAssertTrue(model.hasFamilyAccess)
        let secret = Data("PASSPORT-NUMBER-X1234567".utf8)
        try await model.add(file: secret, title: "Alice passport", kind: "passport", fileName: "p.pdf", mimeType: "application/pdf", personal: false)

        let document = try XCTUnwrap(model.documents.first)
        XCTAssertEqual(document.metadata.title, "Alice passport")
        let opened = try await model.open(document)
        XCTAssertEqual(opened, secret)

        for blob in backend.everythingStored {
            XCTAssertNil(blob.range(of: secret), "no plaintext on the server")
            XCTAssertNil(blob.range(of: Data("passport".utf8)), "metadata is encrypted too")
        }
    }

    func testRecoveryKeyRestoresOnNewDeviceAndWrongKeyFails() async throws {
        let (first, recovery) = try await setUp(alice)
        try await first.add(file: Data("doc".utf8), title: "T", kind: "tax", fileName: "t.txt", mimeType: "text/plain", personal: true)

        let (second, _) = device(alice)
        await second.start()
        XCTAssertEqual(second.phase, .needsRestore, "backup exists, device key does not")

        do {
            try await second.restore(recoveryKey: RecoveryKey().formatted)
            XCTFail("a different key must not open the backup")
        } catch { XCTAssertEqual(error as? AppError, .invalidCode) }
        XCTAssertNotEqual(second.phase, .ready)

        try await second.restore(recoveryKey: recovery.lowercased())
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(second.documents.map(\.metadata.title), ["T"])
    }

    func testSharingNeedsExplicitGrantAndPersonalStaysPrivate() async throws {
        let (a, _) = try await setUp(alice)
        try await a.add(file: Data("family".utf8), title: "Family doc", kind: "other", fileName: "f", mimeType: "text/plain", personal: false)
        try await a.add(file: Data("mine".utf8), title: "Alice only", kind: "other", fileName: "m", mimeType: "text/plain", personal: true)

        let (b, _) = try await setUp(bob)
        XCTAssertFalse(b.hasFamilyAccess, "a new adult has no family key until someone grants it")
        XCTAssertTrue(b.documents.isEmpty)

        try await a.refresh()
        let waiting = try XCTUnwrap(a.pending.first)
        XCTAssertEqual(waiting.member.userId, bob.userId)
        try await a.grantAccess(to: waiting)
        XCTAssertTrue(a.pending.isEmpty)

        try await b.refresh()
        XCTAssertTrue(b.hasFamilyAccess)
        XCTAssertEqual(b.documents.map(\.metadata.title), ["Family doc"], "Alice's personal document stays hidden")
    }

    func testSafetyNumberIsTheSameOnBothSides() async throws {
        let (a, _) = try await setUp(alice)
        let (b, _) = try await setUp(bob)
        try await a.refresh()
        try await b.refresh()
        let number = try XCTUnwrap(a.pending.first?.safetyNumber)
        XCTAssertEqual(number.filter(\.isNumber).count, 30)
        XCTAssertNotNil(b.safetyNumberOwnKey)
    }

    func testRemovedMemberLosesAccessAfterRotationAdminKeeps() async throws {
        let (a, _) = try await setUp(alice)
        let (b, _) = try await setUp(bob)
        try await a.refresh()
        try await a.grantAccess(to: try XCTUnwrap(a.pending.first))
        try await a.add(file: Data("old".utf8), title: "Old", kind: "other", fileName: "o", mimeType: "text/plain", personal: false)
        try await b.refresh()
        XCTAssertEqual(b.documents.count, 1)

        backend.removeMember(bob.userId, familyId: familyId)
        everyone = [alice]
        try await a.refresh()
        XCTAssertTrue(a.rotationNeeded)
        try await a.rotateFamilyKey()
        XCTAssertFalse(a.rotationNeeded)

        try await a.add(file: Data("new".utf8), title: "New", kind: "other", fileName: "n", mimeType: "text/plain", personal: false)
        let adminDocs = Set(a.documents.map(\.metadata.title))
        XCTAssertEqual(adminDocs, ["Old", "New"])
        let reopened = try await a.open(try XCTUnwrap(a.documents.first { $0.metadata.title == "Old" }))
        XCTAssertEqual(reopened, Data("old".utf8))

        try await b.refresh()
        XCTAssertTrue(b.documents.isEmpty, "the removed member sees nothing")
        XCTAssertFalse(b.hasFamilyAccess)
    }

    func testOversizeAndEmptyFilesAreRejected() async throws {
        let (a, _) = try await setUp(alice)
        do {
            try await a.add(file: Data(), title: "x", kind: "other", fileName: "x", mimeType: "text/plain", personal: false)
            XCTFail("empty file")
        } catch {}
        do {
            try await a.add(file: Data(count: VaultModel.maxFileBytes + 1), title: "x", kind: "other", fileName: "x", mimeType: "text/plain", personal: false)
            XCTFail("too big")
        } catch {}
        XCTAssertTrue(a.documents.isEmpty)
    }

    func testLockForgetsEverythingInMemory() async throws {
        let (a, _) = try await setUp(alice)
        try await a.add(file: Data("x".utf8), title: "x", kind: "other", fileName: "x", mimeType: "text/plain", personal: false)
        a.lock()
        XCTAssertTrue(a.documents.isEmpty)
        XCTAssertEqual(a.phase, .loading)
        await a.start()
        XCTAssertEqual(a.phase, .ready, "device key is still in the keychain")
        XCTAssertEqual(a.documents.count, 1)
    }

    func testRecoveryKeyMatchIgnoresCaseAndSeparators() {
        XCTAssertTrue(RecoveryKeyMatch.matches("abcd-efgh 1234", "ABCDEFGH1234"))
        XCTAssertFalse(RecoveryKeyMatch.matches("ABCD", "ABCE"))
        XCTAssertFalse(RecoveryKeyMatch.matches("", ""))
    }
}
