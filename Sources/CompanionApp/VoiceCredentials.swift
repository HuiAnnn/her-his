import Foundation
import Security
import CompanionCore

@MainActor protocol VoiceCredentialStoring {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

/// One successful authorization per running app, scoped to one service.
/// The backing Keychain remains the only persistent credential store.
@MainActor final class SessionCredentials: VoiceCredentialStoring {
    private let backing: any VoiceCredentialStoring
    private var cached: String?
    init(_ backing: any VoiceCredentialStoring) { self.backing = backing }
    func invalidate() { cached = nil }
    func read() throws -> String? {
        if let cached { return cached }
        let value = try backing.read()
        if let value, !value.isEmpty { cached = value }
        return value
    }
    func save(_ value: String) throws {
        invalidate()
        try backing.save(value)
        if !value.isEmpty { cached = value }
    }
    func delete() throws {
        invalidate()
        try backing.delete()
    }
}

@MainActor struct VoiceKeychain: VoiceCredentialStoring {
    var service = "com.huian.herhis.elevenlabs"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }
    func read() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw CloudVoiceError.keychain }
        return key
    }
    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudVoiceError.keychain }
        } else if status != errSecSuccess { throw CloudVoiceError.keychain }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudVoiceError.keychain }
    }
}
