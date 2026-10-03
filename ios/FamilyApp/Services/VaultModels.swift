import FamilyCore
import Foundation

enum VaultKeyKind: String, Codable, Sendable { case family, personal }

/// A vault key the current user holds, with the user's own wrap of it.
struct VaultKeyInfo: Equatable, Sendable {
    let id: UUID
    let kind: VaultKeyKind
    let version: Int
    let rotationNeeded: Bool
    let wrapped: Data
}

/// A stored document: everything except `ciphertext` (downloaded on demand) is opaque to the server.
struct VaultItemRow: Equatable, Sendable, Identifiable {
    let id: UUID
    let keyId: UUID
    let encryptedMeta: Data
    let wrappedItemKey: Data
    let sizeBytes: Int64
    let createdAt: Date
    let createdBy: UUID?
}

/// Postgres `bytea` as PostgREST sends it: a JSON string `\x0123abcd`.
struct Bytea: Codable, Hashable, Sendable {
    let data: Data

    init(_ data: Data) { self.data = data }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.hasPrefix("\\x"), let data = Data(hex: String(text.dropFirst(2))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a bytea hex string"))
        }
        self.data = data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\\x" + data.map { String(format: "%02x", $0) }.joined())
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}

protocol VaultServicing: Sendable {
    func backup() async throws -> Data?
    func publish(userId: UUID, publicKey: Data, backup: Data) async throws
    func publicKeys(of userIds: [UUID]) async throws -> [UUID: Data]
    func myKeys(familyId: UUID) async throws -> [VaultKeyInfo]
    func holders(of keyId: UUID) async throws -> [UUID]
    /// The id is chosen by the client: it is part of every wrap's encryption context.
    func createKey(id: UUID, familyId: UUID, kind: VaultKeyKind, wrapped: Data) async throws
    func shareKey(keyId: UUID, with userId: UUID, wrapped: Data) async throws
    func rotate(newKeyId: UUID, familyId: UUID, wraps: [(userId: UUID, wrapped: Data)], items: [(id: UUID, wrappedItemKey: Data)]) async throws
    func items(familyId: UUID) async throws -> [VaultItemRow]
    func addItem(familyId: UUID, id: UUID, keyId: UUID, encryptedMeta: Data, wrappedItemKey: Data, ciphertext: Data) async throws
    func download(familyId: UUID, itemId: UUID) async throws -> Data
    func deleteItem(familyId: UUID, id: UUID) async throws
}

/// Where the private key lives on this device.
protocol VaultIdentityStoring: Sendable {
    func load(userId: UUID) throws -> VaultIdentity?
    func save(_ identity: VaultIdentity, userId: UUID) throws
    func remove(userId: UUID) throws
}
