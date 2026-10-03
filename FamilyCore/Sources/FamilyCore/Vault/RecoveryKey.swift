import Crypto
import Foundation

/// 160 random bits that the person writes down once (and keeps on paper). It encrypts the backup of the
/// vault identity, so a new phone can recover access. 160 bits of entropy make a slow password hash
/// unnecessary: there is nothing to guess.
///
/// Written as Crockford base32 in groups of four, with one checksum byte to catch typos:
/// `ABCD-EFGH-...` (34 characters).
public struct RecoveryKey: Equatable, Sendable {
    static let byteCount = 20
    private let bytes: Data

    public init() {
        bytes = Data((0..<Self.byteCount).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Accepts any case, spaces and dashes; maps the look-alikes O→0 and I/L→1.
    public init(parsing text: String) throws {
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let decoded = Base32.decode(cleaned), decoded.count == Self.byteCount + 1 else {
            throw VaultError.invalidRecoveryKey
        }
        let payload = decoded.prefix(Self.byteCount)
        guard decoded.last == Self.checksum(Data(payload)) else { throw VaultError.invalidRecoveryKey }
        bytes = Data(payload)
    }

    public var formatted: String {
        let text = Base32.encode(bytes + [Self.checksum(bytes)])
        return stride(from: 0, to: text.count, by: 4).map { start in
            String(text.dropFirst(start).prefix(4))
        }.joined(separator: "-")
    }

    /// Key that encrypts the identity backup; bound to the person, so equal recovery keys of two
    /// people would still give different wrapping keys.
    func wrappingKey(for userId: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: Data(userId.uuidString.lowercased().utf8),
            info: Data("family-app/vault/recovery-wrap/v1".utf8),
            outputByteCount: 32)
    }

    private static func checksum(_ payload: Data) -> UInt8 {
        Array(SHA256.hash(data: Data("family-app/vault/recovery-checksum/v1".utf8) + payload)).first ?? 0
    }
}

extension VaultCrypto {
    /// The identity's private key encrypted for storage on the server. Useless without the recovery key.
    public static func backUp(_ identity: VaultIdentity, userId: UUID, recoveryKey: RecoveryKey) throws -> Data {
        try seal(identity.privateKeyData, key: recoveryKey.wrappingKey(for: userId),
                 context: "identity-backup|\(userId.uuidString.lowercased())")
    }

    public static func restoreIdentity(from backup: Data, userId: UUID, recoveryKey: RecoveryKey) throws -> VaultIdentity {
        try VaultIdentity(privateKeyData: open(backup, key: recoveryKey.wrappingKey(for: userId),
                                               context: "identity-backup|\(userId.uuidString.lowercased())"))
    }
}

enum Base32 {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int(buffer >> UInt32(bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[Int(buffer << UInt32(5 - bits)) & 31]) }
        return output
    }

    static func decode(_ text: String) -> Data? {
        var output = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in text {
            let normalized: Character = switch character {
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
            guard let value = alphabet.firstIndex(of: normalized) else { return nil }
            buffer = buffer << 5 | UInt32(value)
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        // Leftover bits are padding and must be zero in a canonical encoding.
        return bits < 5 && buffer & ((1 << UInt32(bits)) - 1) == 0 ? output : nil
    }
}
