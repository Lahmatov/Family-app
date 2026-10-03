import Crypto
import Foundation

/// End-to-end encryption for the family vault. The server only ever stores ciphertext and
/// public keys; every secret is created and used on a device. See docs/08-vault.md.
///
/// Primitives: X25519 (key agreement), HKDF-SHA256, AES-256-GCM with random 96-bit nonces.
/// Every blob starts with a version byte so the format can evolve.
public enum VaultError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    /// Wrong key, wrong context, or the data was modified.
    case authenticationFailed
    case invalidRecoveryKey
}

public enum VaultCrypto {
    static let version: UInt8 = 1

    // MARK: Symmetric sealing

    /// `version || nonce(12) || ciphertext || tag(16)`; the context is authenticated but not stored.
    static func seal(_ plaintext: Data, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw VaultError.malformed }
        return Data([version]) + combined
    }

    static func open(_ blob: Data, key: SymmetricKey, context: String) throws -> Data {
        guard let first = blob.first else { throw VaultError.malformed }
        guard first == version else { throw VaultError.unsupportedVersion }
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst())
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch is CryptoKitError {
            throw VaultError.authenticationFailed
        } catch {
            throw VaultError.malformed
        }
    }

    public static func newSymmetricKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    // MARK: Key wrapped to a recipient (ECIES: ephemeral X25519 + HKDF + AES-GCM)

    /// `version || ephemeralPublicKey(32) || sealedKey`. `context` ties the wrap to one key and one
    /// recipient (see `wrapContext`), so a wrap cannot be replayed for another purpose.
    public static func wrap(_ key: SymmetricKey, to recipient: Data, context: String) throws -> Data {
        let recipientKey = try publicKey(recipient)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.publicKey.rawRepresentation + recipient,
            sharedInfo: Data(("family-app/vault/key-wrap/v1|" + context).utf8),
            outputByteCount: 32)
        let sealed = try seal(raw(key), key: derived, context: context)
        return Data([version]) + ephemeral.publicKey.rawRepresentation + sealed
    }

    public static func unwrap(_ blob: Data, with identity: VaultIdentity, context: String) throws -> SymmetricKey {
        guard blob.count > 1 + 32 else { throw VaultError.malformed }
        guard blob[blob.startIndex] == version else { throw VaultError.unsupportedVersion }
        let ephemeral = blob.dropFirst().prefix(32)
        let sealed = Data(blob.dropFirst(1 + 32))
        let ephemeralKey = try publicKey(Data(ephemeral))
        let shared: SharedSecret
        do { shared = try identity.privateKey.sharedSecretFromKeyAgreement(with: ephemeralKey) } catch { throw VaultError.malformed }
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(ephemeral) + identity.publicKey,
            sharedInfo: Data(("family-app/vault/key-wrap/v1|" + context).utf8),
            outputByteCount: 32)
        return SymmetricKey(data: try open(sealed, key: derived, context: context))
    }

    public static func wrapContext(keyId: UUID, recipient: UUID) -> String {
        "key|\(keyId.uuidString.lowercased())|user|\(recipient.uuidString.lowercased())"
    }

    private static func publicKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) } catch { throw VaultError.malformed }
    }

    // MARK: Fingerprints

    /// 30 digits in six groups of five, e.g. "12345 67890 ...": read out or compare to confirm that the
    /// server did not swap a public key.
    public static func fingerprint(of publicKey: Data) -> String {
        digits(SHA256.hash(data: Data("family-app/vault/fingerprint/v1".utf8) + publicKey))
    }

    /// The same number for both people, whoever computes it.
    public static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let (low, high) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        return digits(SHA256.hash(data: Data("family-app/vault/safety-number/v1".utf8) + low + high))
    }

    private static func digits(_ digest: SHA256.Digest) -> String {
        let bytes = Array(digest)
        let groups = (0..<6).map { index -> String in
            let value = bytes[(index * 5)..<(index * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(format: "%05d", Int(value % 100_000))
        }
        return groups.joined(separator: " ")
    }
}

/// A person's long-term vault identity: an X25519 key pair created on the device.
public struct VaultIdentity: @unchecked Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public init(privateKeyData: Data) throws {
        do { privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) } catch { throw VaultError.malformed }
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    /// Secret bytes for the device Keychain. Never log or send them.
    public var privateKeyData: Data { privateKey.rawRepresentation }
}
