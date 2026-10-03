import FamilyCore
import Foundation
import Supabase

final class LiveVaultService: VaultServicing {
    private let client: SupabaseClient
    private static let bucket = "vault"

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: Identity

    func backup() async throws -> Data? {
        struct Row: Decodable { let blob: Bytea }
        let rows: [Row] = try await run { try await self.client.from("vault_identity_backups").select("blob").limit(1).execute().value }
        return rows.first?.blob.data
    }

    func publish(userId: UUID, publicKey: Data, backup: Data) async throws {
        struct Backup: Encodable { let user_id: UUID; let blob: Bytea }
        struct Identity: Encodable { let user_id: UUID; let public_key: Bytea }
        // Backup first: an identity without a backup could never be recovered on a new phone.
        try await run { try await self.client.from("vault_identity_backups").insert(Backup(user_id: userId, blob: Bytea(backup))).execute() }
        do {
            try await run { try await self.client.from("vault_identities").insert(Identity(user_id: userId, public_key: Bytea(publicKey))).execute() }
        } catch {
            _ = try? await self.client.from("vault_identity_backups").delete().eq("user_id", value: userId).execute()
            throw error
        }
    }

    func publicKeys(of userIds: [UUID]) async throws -> [UUID: Data] {
        guard !userIds.isEmpty else { return [:] }
        struct Row: Decodable { let user_id: UUID; let public_key: Bytea }
        let rows: [Row] = try await run {
            try await self.client.from("vault_identities").select("user_id, public_key")
                .in("user_id", values: userIds.map { $0 as any PostgrestFilterValue }).execute().value
        }
        return Dictionary(rows.map { ($0.user_id, $0.public_key.data) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Keys

    func myKeys(familyId: UUID) async throws -> [VaultKeyInfo] {
        struct KeyRow: Decodable { let id: UUID; let kind: VaultKeyKind; let version: Int; let rotation_needed: Bool }
        struct WrapRow: Decodable { let key_id: UUID; let wrapped: Bytea }
        let keys: [KeyRow] = try await run {
            try await self.client.from("vault_keys").select("id, kind, version, rotation_needed").eq("family_id", value: familyId).execute().value
        }
        let wraps: [WrapRow] = try await run {
            try await self.client.from("vault_key_wraps").select("key_id, wrapped").eq("family_id", value: familyId).execute().value
        }
        let byKey = Dictionary(wraps.map { ($0.key_id, $0.wrapped.data) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { key in
            byKey[key.id].map { VaultKeyInfo(id: key.id, kind: key.kind, version: key.version, rotationNeeded: key.rotation_needed, wrapped: $0) }
        }
    }

    func holders(of keyId: UUID) async throws -> [UUID] {
        try await run { try await self.client.rpc("vault_key_holders", params: ["p_key": keyId]).execute().value }
    }

    func createKey(id: UUID, familyId: UUID, kind: VaultKeyKind, wrapped: Data) async throws {
        struct Params: Encodable { let p_key_id: UUID; let p_family: UUID; let p_kind: VaultKeyKind; let p_wrapped_for_me: Bytea }
        try await run {
            try await self.client.rpc("vault_create_key", params: Params(
                p_key_id: id, p_family: familyId, p_kind: kind, p_wrapped_for_me: Bytea(wrapped))).execute()
        }
    }

    func shareKey(keyId: UUID, with userId: UUID, wrapped: Data) async throws {
        struct Params: Encodable { let p_key: UUID; let p_user: UUID; let p_wrapped: Bytea }
        try await run {
            try await self.client.rpc("vault_share_key", params: Params(p_key: keyId, p_user: userId, p_wrapped: Bytea(wrapped))).execute()
        }
    }

    func rotate(newKeyId: UUID, familyId: UUID, wraps: [(userId: UUID, wrapped: Data)], items: [(id: UUID, wrappedItemKey: Data)]) async throws {
        struct WrapJSON: Encodable { let user_id: UUID; let wrapped: String }
        struct ItemJSON: Encodable { let id: UUID; let wrapped_item_key: String }
        struct Params: Encodable { let p_new_key_id: UUID; let p_family: UUID; let p_wraps: [WrapJSON]; let p_items: [ItemJSON] }
        let params = Params(p_new_key_id: newKeyId, p_family: familyId,
                            p_wraps: wraps.map { WrapJSON(user_id: $0.userId, wrapped: $0.wrapped.base64EncodedString()) },
                            p_items: items.map { ItemJSON(id: $0.id, wrapped_item_key: $0.wrappedItemKey.base64EncodedString()) })
        try await run { _ = try await self.client.rpc("vault_rotate_family_key", params: params).execute() }
    }

    // MARK: Items

    func items(familyId: UUID) async throws -> [VaultItemRow] {
        struct Row: Decodable {
            let id: UUID; let key_id: UUID; let encrypted_meta: Bytea; let wrapped_item_key: Bytea
            let size_bytes: Int64; let created_at: Date; let created_by: UUID?
        }
        let rows: [Row] = try await run {
            try await self.client.from("vault_items")
                .select("id, key_id, encrypted_meta, wrapped_item_key, size_bytes, created_at, created_by")
                .eq("family_id", value: familyId).order("created_at", ascending: false).execute().value
        }
        return rows.map {
            VaultItemRow(id: $0.id, keyId: $0.key_id, encryptedMeta: $0.encrypted_meta.data, wrappedItemKey: $0.wrapped_item_key.data,
                         sizeBytes: $0.size_bytes, createdAt: $0.created_at, createdBy: $0.created_by)
        }
    }

    func addItem(familyId: UUID, id: UUID, keyId: UUID, encryptedMeta: Data, wrappedItemKey: Data, ciphertext: Data) async throws {
        struct Row: Encodable {
            let id: UUID; let family_id: UUID; let key_id: UUID; let encrypted_meta: Bytea; let wrapped_item_key: Bytea
            let storage_path: String; let size_bytes: Int
        }
        let path = Self.path(familyId, id)
        try await run {
            try await self.client.storage.from(Self.bucket).upload(
                path, data: ciphertext, options: FileOptions(cacheControl: "private, max-age=0", contentType: "application/octet-stream"))
        }
        do {
            try await run {
                try await self.client.from("vault_items").insert(Row(
                    id: id, family_id: familyId, key_id: keyId, encrypted_meta: Bytea(encryptedMeta),
                    wrapped_item_key: Bytea(wrappedItemKey), storage_path: path, size_bytes: ciphertext.count)).execute()
            }
        } catch {
            _ = try? await self.client.storage.from(Self.bucket).remove(paths: [path])
            throw error
        }
    }

    func download(familyId: UUID, itemId: UUID) async throws -> Data {
        try await run { try await self.client.storage.from(Self.bucket).download(path: Self.path(familyId, itemId)) }
    }

    func deleteItem(familyId: UUID, id: UUID) async throws {
        try await run { try await self.client.from("vault_items").delete().eq("id", value: id).execute() }
        _ = try? await client.storage.from(Self.bucket).remove(paths: [Self.path(familyId, id)])
    }

    /// Lower-case: the database compares the path with `family_id::text`.
    private static func path(_ familyId: UUID, _ id: UUID) -> String {
        "\(familyId.uuidString.lowercased())/\(id.uuidString.lowercased())"
    }

    @discardableResult
    private func run<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() } catch { throw mapError(error) }
    }
}

struct MisconfiguredVault: VaultServicing, VaultIdentityStoring {
    func backup() async throws -> Data? { throw AppError.invalidConfiguration }
    func publish(userId: UUID, publicKey: Data, backup: Data) async throws { throw AppError.invalidConfiguration }
    func publicKeys(of userIds: [UUID]) async throws -> [UUID: Data] { throw AppError.invalidConfiguration }
    func myKeys(familyId: UUID) async throws -> [VaultKeyInfo] { throw AppError.invalidConfiguration }
    func holders(of keyId: UUID) async throws -> [UUID] { throw AppError.invalidConfiguration }
    func createKey(id: UUID, familyId: UUID, kind: VaultKeyKind, wrapped: Data) async throws { throw AppError.invalidConfiguration }
    func shareKey(keyId: UUID, with userId: UUID, wrapped: Data) async throws { throw AppError.invalidConfiguration }
    func rotate(newKeyId: UUID, familyId: UUID, wraps: [(userId: UUID, wrapped: Data)], items: [(id: UUID, wrappedItemKey: Data)]) async throws {
        throw AppError.invalidConfiguration
    }
    func items(familyId: UUID) async throws -> [VaultItemRow] { throw AppError.invalidConfiguration }
    func addItem(familyId: UUID, id: UUID, keyId: UUID, encryptedMeta: Data, wrappedItemKey: Data, ciphertext: Data) async throws {
        throw AppError.invalidConfiguration
    }
    func download(familyId: UUID, itemId: UUID) async throws -> Data { throw AppError.invalidConfiguration }
    func deleteItem(familyId: UUID, id: UUID) async throws { throw AppError.invalidConfiguration }
    func load(userId: UUID) throws -> VaultIdentity? { throw AppError.invalidConfiguration }
    func save(_ identity: VaultIdentity, userId: UUID) throws { throw AppError.invalidConfiguration }
    func remove(userId: UUID) throws { throw AppError.invalidConfiguration }
}
