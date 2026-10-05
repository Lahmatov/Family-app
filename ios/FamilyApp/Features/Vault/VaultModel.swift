import Crypto
import FamilyCore
import Foundation
import Observation

/// All vault logic on the device: keys are unwrapped here, documents are encrypted and decrypted here,
/// and the server only ever sees ciphertext (see docs/08-vault.md).
@MainActor
@Observable
final class VaultModel {
    enum Phase: Equatable { case loading, needsSetup, needsRestore, ready }

    struct Document: Identifiable, Equatable {
        let id: UUID
        let keyId: UUID
        let metadata: VaultItemMetadata
        let sizeBytes: Int64
        let createdAt: Date
        let isPersonal: Bool
    }

    /// An adult member who published a vault identity but does not hold the family key yet.
    struct PendingMember: Identifiable, Equatable {
        let member: MemberProfile
        let publicKey: Data
        /// Both people should see the same number; compare it in person before granting access.
        let safetyNumber: String
        var id: UUID { member.userId }
    }

    static let maxFileBytes = 20 * 1024 * 1024

    private(set) var phase = Phase.loading
    private(set) var documents: [Document] = []
    private(set) var pending: [PendingMember] = []
    private(set) var rotationNeeded = false
    /// False while another adult has not yet shared the family key with this person.
    private(set) var hasFamilyAccess = false
    var error: AppError?

    let userId: UUID
    let familyId: UUID
    let role: MemberRole
    private let service: any VaultServicing
    private let identities: any VaultIdentityStoring
    private let members: @Sendable () async throws -> [MemberProfile]

    private var identity: VaultIdentity?
    private var keys: [UUID: SymmetricKey] = [:]
    private var keyInfos: [VaultKeyInfo] = []
    private var rows: [UUID: VaultItemRow] = [:]

    init(userId: UUID, familyId: UUID, role: MemberRole, service: any VaultServicing, identities: any VaultIdentityStoring,
         members: @escaping @Sendable () async throws -> [MemberProfile]) {
        self.userId = userId
        self.familyId = familyId
        self.role = role
        self.service = service
        self.identities = identities
        self.members = members
    }

    var safetyNumberOwnKey: String? { identity.map { VaultCrypto.fingerprint(of: $0.publicKey) } }
    private var familyKey: VaultKeyInfo? { keyInfos.filter { $0.kind == .family }.max { $0.version < $1.version } }
    private var personalKey: VaultKeyInfo? { keyInfos.first { $0.kind == .personal } }

    // MARK: Lifecycle

    func start() async {
        await perform {
            if let stored = try identities.load(userId: userId) {
                identity = stored
                try await refresh()
            } else {
                phase = try await service.backup() == nil ? .needsSetup : .needsRestore
            }
        }
    }

    /// First use: creates the identity, stores it on the device and publishes the public key and the encrypted backup.
    /// Returns the recovery key, to be shown exactly once; the vault opens with `finishSetup()`.
    func createVault() async throws -> String {
        let fresh = VaultIdentity()
        let recovery = RecoveryKey()
        let backup = try VaultCrypto.backUp(fresh, userId: userId, recoveryKey: recovery)
        try identities.save(fresh, userId: userId)
        do {
            try await service.publish(userId: userId, publicKey: fresh.publicKey, backup: backup)
        } catch {
            try? identities.remove(userId: userId)
            throw error
        }
        identity = fresh
        return recovery.formatted
    }

    /// Called once the person confirmed they stored the recovery key: creates the keys and opens the vault.
    func finishSetup() async {
        await perform { try await refresh() }
    }

    /// New phone: the recovery key decrypts the identity backup stored on the server.
    func restore(recoveryKey text: String) async throws {
        let recovery: RecoveryKey
        do { recovery = try RecoveryKey(parsing: text) } catch { throw AppError.invalidCode }
        guard let backup = try await service.backup() else { throw AppError.notFound }
        let restored: VaultIdentity
        do { restored = try VaultCrypto.restoreIdentity(from: backup, userId: userId, recoveryKey: recovery) } catch { throw AppError.invalidCode }
        try identities.save(restored, userId: userId)
        identity = restored
        try await refresh()
    }

    /// Forget everything in memory (the identity stays in the Keychain).
    func lock() {
        keys = [:]
        keyInfos = []
        rows = [:]
        documents = []
        pending = []
        identity = nil
        phase = .loading
    }

    func refresh() async throws {
        if identity == nil { identity = try identities.load(userId: userId) }
        guard let identity else { phase = .needsSetup; return }

        try await ensureKeys(identity)
        keyInfos = try await service.myKeys(familyId: familyId)
        keys = [:]
        for info in keyInfos {
            // A wrap made for an old identity simply cannot be opened; skip it.
            if let key = try? VaultCrypto.unwrap(info.wrapped, with: identity,
                                                 context: VaultCrypto.wrapContext(keyId: info.id, recipient: userId)) {
                keys[info.id] = key
            }
        }
        hasFamilyAccess = familyKey.flatMap { keys[$0.id] } != nil
        rotationNeeded = hasFamilyAccess && (familyKey?.rotationNeeded ?? false)

        let fetched = try await service.items(familyId: familyId)
        rows = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        documents = fetched.compactMap { row in
            guard let key = keys[row.keyId],
                  let metadata = try? VaultCrypto.openMetadata(sealed(row, ciphertext: Data()), itemId: row.id, vaultKey: key, keyId: row.keyId)
            else { return nil }
            return Document(id: row.id, keyId: row.keyId, metadata: metadata, sizeBytes: row.sizeBytes, createdAt: row.createdAt,
                            isPersonal: keyInfos.first { $0.id == row.keyId }?.kind == .personal)
        }
        try await loadPending(identity)
        phase = .ready
    }

    // MARK: Documents

    func add(file: Data, title: String, kind: String, fileName: String, mimeType: String, personal: Bool) async throws {
        guard file.count <= Self.maxFileBytes, !file.isEmpty else { throw AppError.unknown }
        guard let info = personal ? personalKey : familyKey, let key = keys[info.id] else { throw AppError.forbidden }
        let itemId = UUID()
        let sealed = try VaultCrypto.seal(
            file: file, metadata: VaultItemMetadata(title: title, kind: kind, fileName: fileName, mimeType: mimeType),
            itemId: itemId, vaultKey: key, keyId: info.id)
        try await service.addItem(familyId: familyId, id: itemId, keyId: info.id, encryptedMeta: sealed.encryptedMetadata,
                                  wrappedItemKey: sealed.wrappedItemKey, ciphertext: sealed.ciphertext)
        try await refresh()
    }

    /// Downloads and decrypts a document. The plaintext exists only in the returned value.
    func open(_ document: Document) async throws -> Data {
        guard let row = rows[document.id], let key = keys[row.keyId] else { throw AppError.forbidden }
        let blob = try await service.download(familyId: familyId, itemId: row.id)
        do {
            return try VaultCrypto.openFile(sealed(row, ciphertext: blob), itemId: row.id, vaultKey: key, keyId: row.keyId)
        } catch {
            throw AppError.invalidCode
        }
    }

    func delete(_ document: Document) async throws {
        try await service.deleteItem(familyId: familyId, id: document.id)
        try await refresh()
    }

    // MARK: Sharing the family key

    func grantAccess(to member: PendingMember) async throws {
        guard let info = familyKey, let key = keys[info.id] else { throw AppError.forbidden }
        let wrapped = try VaultCrypto.wrap(key, to: member.publicKey,
                                           context: VaultCrypto.wrapContext(keyId: info.id, recipient: member.member.userId))
        try await service.shareKey(keyId: info.id, with: member.member.userId, wrapped: wrapped)
        try await refresh()
    }

    /// After a member left: a new family key for the people who should keep access; item keys are re-wrapped,
    /// files stay as they are. Admins only (enforced by the database too).
    func rotateFamilyKey() async throws {
        guard role == .admin, let old = familyKey, let oldKey = keys[old.id], let identity else { throw AppError.forbidden }
        let adults = try await members().filter { $0.role.isAtLeast(.adult) }
        let holders = Set(try await service.holders(of: old.id))
        let recipients = adults.filter { holders.contains($0.userId) || $0.userId == userId }
        let publicKeys = try await service.publicKeys(of: recipients.map(\.userId))

        let newId = UUID()
        let newKey = VaultCrypto.newSymmetricKey()
        var wraps: [(userId: UUID, wrapped: Data)] = []
        for member in recipients {
            guard let publicKey = member.userId == userId ? identity.publicKey : publicKeys[member.userId] else { continue }
            wraps.append((member.userId, try VaultCrypto.wrap(newKey, to: publicKey,
                                                              context: VaultCrypto.wrapContext(keyId: newId, recipient: member.userId))))
        }
        var items: [(id: UUID, wrappedItemKey: Data)] = []
        for row in rows.values where row.keyId == old.id {
            items.append((row.id, try VaultCrypto.rewrapItemKey(row.wrappedItemKey, itemId: row.id, from: oldKey, oldKeyId: old.id,
                                                                to: newKey, newKeyId: newId)))
        }
        try await service.rotate(newKeyId: newId, familyId: familyId, wraps: wraps, items: items)
        try await refresh()
    }

    // MARK: Internals

    private func ensureKeys(_ identity: VaultIdentity) async throws {
        let existing = try await service.myKeys(familyId: familyId)
        for kind in [VaultKeyKind.personal, .family] where !existing.contains(where: { $0.kind == kind }) {
            do { try await createKey(kind, identity: identity) } catch AppError.conflict {
                // The key exists but this person holds no wrap: the family key has to be shared by an adult who
                // holds it; a personal key whose wrap was deleted (left the family, was demoted) stays unreadable.
            }
        }
    }

    private func createKey(_ kind: VaultKeyKind, identity: VaultIdentity) async throws {
        let id = UUID()
        let key = VaultCrypto.newSymmetricKey()
        let wrapped = try VaultCrypto.wrap(key, to: identity.publicKey, context: VaultCrypto.wrapContext(keyId: id, recipient: userId))
        try await service.createKey(id: id, familyId: familyId, kind: kind, wrapped: wrapped)
    }

    private func loadPending(_ identity: VaultIdentity) async throws {
        pending = []
        guard let info = familyKey, keys[info.id] != nil else { return }
        let adults = try await members().filter { $0.role.isAtLeast(.adult) && $0.userId != userId }
        let holders = Set(try await service.holders(of: info.id))
        let waiting = adults.filter { !holders.contains($0.userId) }
        let publicKeys = try await service.publicKeys(of: waiting.map(\.userId))
        pending = waiting.compactMap { member in
            publicKeys[member.userId].map {
                PendingMember(member: member, publicKey: $0, safetyNumber: VaultCrypto.safetyNumber(identity.publicKey, $0))
            }
        }
    }

    private func sealed(_ row: VaultItemRow, ciphertext: Data) -> SealedVaultItem {
        SealedVaultItem(encryptedMetadata: row.encryptedMeta, wrappedItemKey: row.wrappedItemKey, ciphertext: ciphertext)
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch let appError as AppError { error = appError } catch { self.error = .unknown }
    }
}

/// Compares what the user typed with the recovery key, ignoring case, spaces and dashes.
enum RecoveryKeyMatch {
    static func matches(_ typed: String, _ key: String) -> Bool {
        normalize(typed) == normalize(key) && !normalize(key).isEmpty
    }
    private static func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
