#if DEBUG
import FamilyCore
import Foundation

/// A stand-in for the server that enforces the same visibility rules as the database: you see a key
/// and its items only while you hold a wrap, and nothing but ciphertext is ever stored. Several
/// `InMemoryVaultService`s over one backend act as several people's devices.
final class InMemoryVaultBackend: @unchecked Sendable {
    struct Key { let id: UUID; let familyId: UUID; let kind: VaultKeyKind; var version: Int; var rotationNeeded: Bool; let owner: UUID? }
    struct Item { let id: UUID; let familyId: UUID; var keyId: UUID; let meta: Data; var wrapped: Data; let size: Int64; let createdBy: UUID; let createdAt: Date }

    let lock = NSLock()
    var publicKeys: [UUID: Data] = [:]
    var backups: [UUID: Data] = [:]
    var keys: [UUID: Key] = [:]
    var wraps: [UUID: [UUID: Data]] = [:]   // keyId -> userId -> wrapped
    var items: [UUID: Item] = [:]
    var blobs: [UUID: Data] = [:]

    /// Test hook: what a curious server could read.
    var everythingStored: [Data] {
        lock.lock(); defer { lock.unlock() }
        return Array(blobs.values) + items.values.flatMap { [$0.meta, $0.wrapped] } + Array(backups.values)
    }

    /// Simulates the database trigger when someone is removed from the family.
    func removeMember(_ userId: UUID, familyId: UUID) {
        lock.lock(); defer { lock.unlock() }
        for key in keys.values where key.familyId == familyId {
            wraps[key.id]?[userId] = nil
            if key.kind == .family { keys[key.id]?.rotationNeeded = true }
        }
    }
}

struct InMemoryVaultService: VaultServicing {
    let backend: InMemoryVaultBackend
    let userId: UUID

    func backup() async throws -> Data? { locked { backend.backups[userId] } }

    func publish(userId: UUID, publicKey: Data, backup: Data) async throws {
        try locked {
            guard backend.publicKeys[userId] == nil else { throw AppError.conflict }
            backend.publicKeys[userId] = publicKey
            backend.backups[userId] = backup
        }
    }

    func publicKeys(of userIds: [UUID]) async throws -> [UUID: Data] {
        locked { backend.publicKeys.filter { userIds.contains($0.key) } }
    }

    func myKeys(familyId: UUID) async throws -> [VaultKeyInfo] {
        locked {
            backend.keys.values.compactMap { key in
                guard key.familyId == familyId, let wrapped = backend.wraps[key.id]?[userId] else { return nil }
                return VaultKeyInfo(id: key.id, kind: key.kind, version: key.version, rotationNeeded: key.rotationNeeded, wrapped: wrapped)
            }
        }
    }

    func holders(of keyId: UUID) async throws -> [UUID] {
        try locked {
            guard backend.wraps[keyId]?[userId] != nil else { throw AppError.notFound }
            return Array(backend.wraps[keyId]!.keys)
        }
    }

    func createKey(id: UUID, familyId: UUID, kind: VaultKeyKind, wrapped: Data) async throws {
        try locked {
            guard backend.publicKeys[userId] != nil else { throw AppError.forbidden }
            let exists = backend.keys.values.contains { $0.familyId == familyId && $0.kind == kind && (kind == .family || $0.owner == userId) }
            guard !exists, backend.keys[id] == nil else { throw AppError.conflict }
            backend.keys[id] = .init(id: id, familyId: familyId, kind: kind, version: 1, rotationNeeded: false, owner: kind == .personal ? userId : nil)
            backend.wraps[id] = [userId: wrapped]
        }
    }

    func shareKey(keyId: UUID, with user: UUID, wrapped: Data) async throws {
        try locked {
            guard backend.wraps[keyId]?[userId] != nil, backend.keys[keyId]?.kind == .family else { throw AppError.notFound }
            guard backend.publicKeys[user] != nil else { throw AppError.forbidden }
            guard backend.wraps[keyId]?[user] == nil else { throw AppError.conflict }
            backend.wraps[keyId]?[user] = wrapped
        }
    }

    func rotate(newKeyId id: UUID, familyId: UUID, wraps: [(userId: UUID, wrapped: Data)], items: [(id: UUID, wrappedItemKey: Data)]) async throws {
        try locked {
            guard let old = backend.keys.values.filter({ $0.familyId == familyId && $0.kind == .family }).max(by: { $0.version < $1.version }),
                  backend.wraps[old.id]?[userId] != nil else { throw AppError.notFound }
            let current = backend.items.values.filter { $0.keyId == old.id }
            guard current.count == items.count, Set(current.map(\.id)) == Set(items.map(\.id)),
                  wraps.contains(where: { $0.userId == userId }) else { throw AppError.unknown }
            backend.keys[id] = .init(id: id, familyId: familyId, kind: .family, version: old.version + 1, rotationNeeded: false, owner: nil)
            backend.wraps[id] = Dictionary(uniqueKeysWithValues: wraps.map { ($0.userId, $0.wrapped) })
            for item in items { backend.items[item.id]?.keyId = id; backend.items[item.id]?.wrapped = item.wrappedItemKey }
            backend.keys[old.id] = nil
            backend.wraps[old.id] = nil
        }
    }

    func items(familyId: UUID) async throws -> [VaultItemRow] {
        locked {
            backend.items.values.filter { $0.familyId == familyId && backend.wraps[$0.keyId]?[userId] != nil }
                .sorted { $0.createdAt > $1.createdAt }
                .map { VaultItemRow(id: $0.id, keyId: $0.keyId, encryptedMeta: $0.meta, wrappedItemKey: $0.wrapped,
                                    sizeBytes: $0.size, createdAt: $0.createdAt, createdBy: $0.createdBy) }
        }
    }

    func addItem(familyId: UUID, id: UUID, keyId: UUID, encryptedMeta: Data, wrappedItemKey: Data, ciphertext: Data) async throws {
        try locked {
            guard backend.wraps[keyId]?[userId] != nil else { throw AppError.forbidden }
            backend.blobs[id] = ciphertext
            backend.items[id] = .init(id: id, familyId: familyId, keyId: keyId, meta: encryptedMeta, wrapped: wrappedItemKey,
                                      size: Int64(ciphertext.count), createdBy: userId, createdAt: Date())
        }
    }

    func download(familyId: UUID, itemId: UUID) async throws -> Data {
        try locked {
            guard let item = backend.items[itemId], backend.wraps[item.keyId]?[userId] != nil, let blob = backend.blobs[itemId] else {
                throw AppError.notFound
            }
            return blob
        }
    }

    func deleteItem(familyId: UUID, id: UUID) async throws {
        try locked {
            guard let item = backend.items[id], backend.wraps[item.keyId]?[userId] != nil else { throw AppError.notFound }
            backend.items[id] = nil
            backend.blobs[id] = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        backend.lock.lock(); defer { backend.lock.unlock() }
        return try body()
    }
}

final class InMemoryIdentityStore: VaultIdentityStoring, @unchecked Sendable {
    private var identities: [UUID: VaultIdentity] = [:]
    private let lock = NSLock()
    func load(userId: UUID) throws -> VaultIdentity? { lock.lock(); defer { lock.unlock() }; return identities[userId] }
    func save(_ identity: VaultIdentity, userId: UUID) throws { lock.lock(); defer { lock.unlock() }; identities[userId] = identity }
    func remove(userId: UUID) throws { lock.lock(); defer { lock.unlock() }; identities[userId] = nil }
}
#endif
