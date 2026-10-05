import Crypto
import Foundation
import XCTest
@testable import FamilyCore

final class VaultCryptoTests: XCTestCase {
    private let alice = UUID()
    private let bob = UUID()

    // MARK: Sealing

    func testSealOpenRoundTripAndTamperDetection() throws {
        let key = VaultCrypto.newSymmetricKey()
        let blob = try VaultCrypto.seal(Data("passport".utf8), key: key, context: "ctx")
        XCTAssertEqual(blob.first, 1, "version byte")
        XCTAssertEqual(try VaultCrypto.open(blob, key: key, context: "ctx"), Data("passport".utf8))

        var flipped = blob
        flipped[flipped.count - 1] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.open(flipped, key: key, context: "ctx")) { XCTAssertEqual($0 as? VaultError, .authenticationFailed) }
        XCTAssertThrowsError(try VaultCrypto.open(blob, key: key, context: "other")) { XCTAssertEqual($0 as? VaultError, .authenticationFailed) }
        XCTAssertThrowsError(try VaultCrypto.open(blob, key: VaultCrypto.newSymmetricKey(), context: "ctx"))
        XCTAssertThrowsError(try VaultCrypto.open(Data(), key: key, context: "ctx")) { XCTAssertEqual($0 as? VaultError, .malformed) }
        XCTAssertThrowsError(try VaultCrypto.open(Data([9]) + blob.dropFirst(), key: key, context: "ctx")) { XCTAssertEqual($0 as? VaultError, .unsupportedVersion) }
    }

    func testSealingTheSameDataTwiceGivesDifferentCiphertext() throws {
        let key = VaultCrypto.newSymmetricKey()
        let first = try VaultCrypto.seal(Data("x".utf8), key: key, context: "c")
        let second = try VaultCrypto.seal(Data("x".utf8), key: key, context: "c")
        XCTAssertNotEqual(first, second, "random nonces")
    }

    // MARK: Key wrapping

    func testWrapToRecipientOnlyOpensForTheRecipientAndContext() throws {
        let recipient = VaultIdentity()
        let other = VaultIdentity()
        let key = VaultCrypto.newSymmetricKey()
        let keyId = UUID()
        let context = VaultCrypto.wrapContext(keyId: keyId, recipient: bob)

        let wrapped = try VaultCrypto.wrap(key, to: recipient.publicKey, context: context)
        XCTAssertEqual(VaultCrypto.raw(try VaultCrypto.unwrap(wrapped, with: recipient, context: context)), VaultCrypto.raw(key))
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: other, context: context), "someone else cannot open it")
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: recipient, context: VaultCrypto.wrapContext(keyId: UUID(), recipient: bob)),
                             "a wrap for another key id is rejected")
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: recipient, context: VaultCrypto.wrapContext(keyId: keyId, recipient: alice)),
                             "a wrap addressed to another user is rejected")
        XCTAssertThrowsError(try VaultCrypto.unwrap(Data([1, 2, 3]), with: recipient, context: context)) { XCTAssertEqual($0 as? VaultError, .malformed) }
        XCTAssertThrowsError(try VaultCrypto.wrap(key, to: Data(count: 5), context: context)) { XCTAssertEqual($0 as? VaultError, .malformed) }
    }

    // MARK: Documents

    func testDocumentRoundTripWithHiddenMetadata() throws {
        let vaultKey = VaultCrypto.newSymmetricKey()
        let keyId = UUID(), itemId = UUID()
        let file = Data((0..<10_000).map { UInt8($0 % 251) })
        let metadata = VaultItemMetadata(title: "Passaporte da Mia", kind: "passport", fileName: "mia.pdf", mimeType: "application/pdf")

        let sealed = try VaultCrypto.seal(file: file, metadata: metadata, itemId: itemId, vaultKey: vaultKey, keyId: keyId)
        XCTAssertFalse(String(decoding: sealed.encryptedMetadata, as: UTF8.self).contains("Mia"), "title is not visible to the server")
        XCTAssertFalse(sealed.ciphertext.contains(file.prefix(32)), "no plaintext in the blob")
        XCTAssertEqual(try VaultCrypto.openMetadata(sealed, itemId: itemId, vaultKey: vaultKey, keyId: keyId), metadata)
        XCTAssertEqual(try VaultCrypto.openFile(sealed, itemId: itemId, vaultKey: vaultKey, keyId: keyId), file)
    }

    func testBlobsCannotBeMovedBetweenItemsOrKeys() throws {
        let vaultKey = VaultCrypto.newSymmetricKey()
        let keyId = UUID()
        let a = UUID(), b = UUID()
        let metadata = VaultItemMetadata(title: "t", kind: "k", fileName: "f", mimeType: "m")
        let first = try VaultCrypto.seal(file: Data("A".utf8), metadata: metadata, itemId: a, vaultKey: vaultKey, keyId: keyId)

        XCTAssertThrowsError(try VaultCrypto.openFile(first, itemId: b, vaultKey: vaultKey, keyId: keyId), "same blobs under another item id")
        XCTAssertThrowsError(try VaultCrypto.openFile(first, itemId: a, vaultKey: vaultKey, keyId: UUID()), "same blobs under another key id")
        // Swapping only the ciphertext with another item's ciphertext fails as well.
        let second = try VaultCrypto.seal(file: Data("B".utf8), metadata: metadata, itemId: b, vaultKey: vaultKey, keyId: keyId)
        let spliced = SealedVaultItem(encryptedMetadata: first.encryptedMetadata, wrappedItemKey: first.wrappedItemKey, ciphertext: second.ciphertext)
        XCTAssertThrowsError(try VaultCrypto.openFile(spliced, itemId: a, vaultKey: vaultKey, keyId: keyId))
    }

    func testRotationRewrapsItemKeysWithoutTouchingTheFile() throws {
        let oldKey = VaultCrypto.newSymmetricKey(), newKey = VaultCrypto.newSymmetricKey()
        let oldId = UUID(), newId = UUID(), itemId = UUID()
        let metadata = VaultItemMetadata(title: "Lease", kind: "contract", fileName: "l.pdf", mimeType: "application/pdf")
        let sealed = try VaultCrypto.seal(file: Data("lease".utf8), metadata: metadata, itemId: itemId, vaultKey: oldKey, keyId: oldId)

        let rewrapped = try VaultCrypto.rewrapItemKey(sealed.wrappedItemKey, itemId: itemId, from: oldKey, oldKeyId: oldId, to: newKey, newKeyId: newId)
        let moved = SealedVaultItem(encryptedMetadata: sealed.encryptedMetadata, wrappedItemKey: rewrapped, ciphertext: sealed.ciphertext)
        XCTAssertEqual(try VaultCrypto.openFile(moved, itemId: itemId, vaultKey: newKey, keyId: newId), Data("lease".utf8))
        XCTAssertEqual(try VaultCrypto.openMetadata(moved, itemId: itemId, vaultKey: newKey, keyId: newId), metadata)
        XCTAssertThrowsError(try VaultCrypto.openFile(moved, itemId: itemId, vaultKey: oldKey, keyId: oldId), "the old key no longer opens it")
    }

    // MARK: Recovery key and identity backup

    func testRecoveryKeyFormatAndParsing() throws {
        let key = RecoveryKey()
        let text = key.formatted
        XCTAssertEqual(text.filter { $0 != "-" }.count, 34)
        XCTAssertEqual(text.split(separator: "-").map(\.count), [4, 4, 4, 4, 4, 4, 4, 4, 2])
        XCTAssertEqual(try RecoveryKey(parsing: text), key)
        XCTAssertEqual(try RecoveryKey(parsing: text.lowercased().replacingOccurrences(of: "-", with: " ")), key, "case, spaces and dashes are ignored")
        XCTAssertNotEqual(RecoveryKey(), RecoveryKey())

        let garbled = text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(try RecoveryKey(parsing: garbled), key, "look-alike characters are forgiven")
    }

    func testRecoveryKeyDetectsTypos() {
        let text = RecoveryKey().formatted
        var chars = Array(text)
        let index = chars.firstIndex { $0 != "-" }!
        chars[index] = chars[index] == "A" ? "B" : "A"
        XCTAssertThrowsError(try RecoveryKey(parsing: String(chars))) { XCTAssertEqual($0 as? VaultError, .invalidRecoveryKey) }
        XCTAssertThrowsError(try RecoveryKey(parsing: String(text.dropLast())))
        XCTAssertThrowsError(try RecoveryKey(parsing: ""))
        XCTAssertThrowsError(try RecoveryKey(parsing: "UUUU-" + text.dropFirst(5)), "U is not in the alphabet")
    }

    func testIdentityBackupRestoresOnANewDeviceOnlyWithTheRightKeyAndUser() throws {
        let identity = VaultIdentity()
        let recovery = RecoveryKey()
        let backup = try VaultCrypto.backUp(identity, userId: alice, recoveryKey: recovery)
        XCTAssertFalse(backup.contains(identity.privateKeyData.prefix(16)), "the backup is encrypted")

        let restored = try VaultCrypto.restoreIdentity(from: backup, userId: alice, recoveryKey: recovery)
        XCTAssertEqual(restored.publicKey, identity.publicKey)
        XCTAssertEqual(restored.privateKeyData, identity.privateKeyData)
        XCTAssertThrowsError(try VaultCrypto.restoreIdentity(from: backup, userId: alice, recoveryKey: RecoveryKey()), "wrong recovery key")
        XCTAssertThrowsError(try VaultCrypto.restoreIdentity(from: backup, userId: bob, recoveryKey: recovery), "backup is bound to its owner")
    }

    // MARK: Fingerprints

    func testFingerprintAndSafetyNumber() {
        let a = VaultIdentity().publicKey, b = VaultIdentity().publicKey
        let fingerprint = VaultCrypto.fingerprint(of: a)
        XCTAssertEqual(fingerprint, VaultCrypto.fingerprint(of: a), "stable")
        XCTAssertEqual(fingerprint.split(separator: " ").map(\.count), [5, 5, 5, 5, 5, 5])
        XCTAssertNotEqual(fingerprint, VaultCrypto.fingerprint(of: b))
        XCTAssertEqual(VaultCrypto.safetyNumber(a, b), VaultCrypto.safetyNumber(b, a), "both people see the same number")
        XCTAssertNotEqual(VaultCrypto.safetyNumber(a, b), VaultCrypto.safetyNumber(a, VaultIdentity().publicKey), "changes if a key is swapped")
    }

    func testIdentityRejectsBadKeyMaterial() {
        XCTAssertThrowsError(try VaultIdentity(privateKeyData: Data(count: 3))) { XCTAssertEqual($0 as? VaultError, .malformed) }
    }
}
