import Crypto
import Foundation

/// What a vault document is, kept inside the encrypted metadata (the server learns nothing, not
/// even the file name).
public struct VaultItemMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var kind: String
    public var fileName: String
    public var mimeType: String

    public init(title: String, kind: String, fileName: String, mimeType: String) {
        self.title = title
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

/// The three opaque blobs stored for a document.
public struct SealedVaultItem: Equatable, Sendable {
    public let encryptedMetadata: Data
    public let wrappedItemKey: Data
    public let ciphertext: Data

    public init(encryptedMetadata: Data, wrappedItemKey: Data, ciphertext: Data) {
        self.encryptedMetadata = encryptedMetadata
        self.wrappedItemKey = wrappedItemKey
        self.ciphertext = ciphertext
    }
}

extension VaultCrypto {
    /// Each document gets its own random key. Data and metadata are bound to the item id; the item key
    /// is bound to the vault key id. Rotating the vault key therefore only re-wraps the small item keys.
    public static func seal(
        file: Data, metadata: VaultItemMetadata, itemId: UUID, vaultKey: SymmetricKey, keyId: UUID
    ) throws -> SealedVaultItem {
        let itemKey = newSymmetricKey()
        return SealedVaultItem(
            encryptedMetadata: try seal(JSONEncoder().encode(metadata), key: itemKey, context: metaContext(itemId)),
            wrappedItemKey: try seal(raw(itemKey), key: vaultKey, context: itemKeyContext(itemId, keyId)),
            ciphertext: try seal(file, key: itemKey, context: dataContext(itemId)))
    }

    public static func openMetadata(
        _ item: SealedVaultItem, itemId: UUID, vaultKey: SymmetricKey, keyId: UUID
    ) throws -> VaultItemMetadata {
        let itemKey = try openItemKey(item.wrappedItemKey, itemId: itemId, vaultKey: vaultKey, keyId: keyId)
        let json = try open(item.encryptedMetadata, key: itemKey, context: metaContext(itemId))
        do { return try JSONDecoder().decode(VaultItemMetadata.self, from: json) } catch { throw VaultError.malformed }
    }

    public static func openFile(
        _ item: SealedVaultItem, itemId: UUID, vaultKey: SymmetricKey, keyId: UUID
    ) throws -> Data {
        let itemKey = try openItemKey(item.wrappedItemKey, itemId: itemId, vaultKey: vaultKey, keyId: keyId)
        return try open(item.ciphertext, key: itemKey, context: dataContext(itemId))
    }

    /// Moves an item key from one vault key to another (after a member leaves) without touching the file.
    public static func rewrapItemKey(
        _ wrapped: Data, itemId: UUID, from old: SymmetricKey, oldKeyId: UUID, to new: SymmetricKey, newKeyId: UUID
    ) throws -> Data {
        let itemKey = try openItemKey(wrapped, itemId: itemId, vaultKey: old, keyId: oldKeyId)
        return try seal(raw(itemKey), key: new, context: itemKeyContext(itemId, newKeyId))
    }

    private static func openItemKey(_ wrapped: Data, itemId: UUID, vaultKey: SymmetricKey, keyId: UUID) throws -> SymmetricKey {
        SymmetricKey(data: try open(wrapped, key: vaultKey, context: itemKeyContext(itemId, keyId)))
    }

    private static func metaContext(_ id: UUID) -> String { "item-meta|\(id.uuidString.lowercased())" }
    private static func dataContext(_ id: UUID) -> String { "item-data|\(id.uuidString.lowercased())" }
    private static func itemKeyContext(_ id: UUID, _ keyId: UUID) -> String {
        "item-key|\(id.uuidString.lowercased())|\(keyId.uuidString.lowercased())"
    }
}
