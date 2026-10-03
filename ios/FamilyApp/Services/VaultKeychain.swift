import FamilyCore
import Foundation
import Security

/// The private key lives in the Keychain of this device only: `WhenPasscodeSetThisDeviceOnly` means it
/// needs a device passcode, never leaves the phone (no iCloud, no backup migration) and is deleted if the
/// passcode is removed. The encrypted copy on the server is what recovery uses.
struct KeychainVaultIdentityStore: VaultIdentityStoring {
    struct Failure: Error, Equatable { let status: OSStatus }

    let service: String

    init(service: String = "app.family.vault") {
        self.service = service
    }

    func load(userId: UUID) throws -> VaultIdentity? {
        var request = query(userId)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).flatMap { try? VaultIdentity(privateKeyData: $0) }
        case errSecItemNotFound: return nil
        default: throw Failure(status: status)
        }
    }

    func save(_ identity: VaultIdentity, userId: UUID) throws {
        try remove(userId: userId)
        var item = query(userId)
        item[kSecValueData as String] = identity.privateKeyData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func remove(userId: UUID) throws {
        let status = SecItemDelete(query(userId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func query(_ userId: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: userId.uuidString.lowercased(),
         kSecAttrSynchronizable as String: false]
    }
}
