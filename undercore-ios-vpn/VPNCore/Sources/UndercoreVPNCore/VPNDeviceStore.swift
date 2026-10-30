import Foundation
import Security
import UndercoreCore

/// Only an idempotency key and public device ID. No tunnel parameters or credentials.
@MainActor public final class VPNDeviceStore {
    struct Registration: Codable {
        let key: UUID
        var configurationID: String?
    }
    // Injected only by isolated tests. Production records use ThisDeviceOnly Keychain.
    private let defaults: UserDefaults?
    private let origin: String
    public init(origin: URL, defaults: UserDefaults? = nil) {
        self.origin = origin.absoluteString; self.defaults = defaults
    }
    private func storageKey(_ owner: Int) -> String { "vpn.automatic-device.\(origin).\(owner)" }
    func registration(owner: Int) throws -> Registration {
        if let data = try load(owner: owner) {
            guard let value = try? JSONDecoder().decode(Registration.self, from: data),
                  value.configurationID.map(DeepLink.isConfigurationID) ?? true else { throw ClientError.invalidResponse }
            return value
        }
        // Persist before sending the first mutation. Never replace after a timeout or revoke.
        let value = Registration(key: UUID(), configurationID: nil)
        try save(value, owner: owner)
        return value
    }
    func bind(_ id: String, owner: Int) throws {
        guard DeepLink.isConfigurationID(id) else { throw ClientError.invalidResponse }
        var value = try registration(owner: owner)
        guard value.configurationID == nil || value.configurationID == id else { throw ClientError.invalidResponse }
        value.configurationID = id
        try save(value, owner: owner)
    }
    private func save(_ value: Registration, owner: Int) throws {
        let data = try JSONEncoder().encode(value)
        if let defaults { defaults.set(data, forKey: storageKey(owner)); return }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = query(owner: owner)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ClientError.insecureStorage }
        } else if status != errSecSuccess { throw ClientError.insecureStorage }
    }
    private func query(owner: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ru.undercore.ios.vpn.devices",
         kSecAttrAccount as String: storageKey(owner)]
    }
    private func load(owner: Int) throws -> Data? {
        if let defaults {
            guard defaults.object(forKey: storageKey(owner)) == nil || defaults.data(forKey: storageKey(owner)) != nil else {
                throw ClientError.invalidResponse
            }
            return defaults.data(forKey: storageKey(owner))
        }
        var query = query(owner: owner)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ClientError.insecureStorage }
        return data
    }
}
