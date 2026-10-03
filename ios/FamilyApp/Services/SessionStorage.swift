import Foundation
import Security
import Supabase

/// Keeps the Supabase session in the Keychain, readable after the first unlock (so token refresh
/// works in the background) but never migrating to another device: unlike the library default,
/// the item is `ThisDeviceOnly`, so it is excluded from backups restored elsewhere and from iCloud.
struct DeviceOnlyKeychainStorage: AuthLocalStorage {
    struct Failure: Error, Equatable { let status: OSStatus }

    let service: String

    init(service: String = "app.family.session") {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(key)
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        default:
            throw Failure(status: status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure(status: status)
        }
    }

    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
}
