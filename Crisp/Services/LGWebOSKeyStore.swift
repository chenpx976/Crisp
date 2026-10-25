import Foundation
import Security

protocol LGWebOSKeyStore: Sendable {
    func read(host: String) async throws -> String?
    func save(_ key: String, host: String) async throws
    func delete(host: String) async throws
}

struct LGWebOSKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error (\(status))"
    }
}

/// The boundary also lets tests exercise OSStatus handling without touching real credentials.
protocol LGWebOSKeychainAPI: Sendable {
    func read(host: String) -> (OSStatus, Data?)
    func update(host: String, data: Data) -> OSStatus
    func add(host: String, data: Data) -> OSStatus
    func delete(host: String) -> OSStatus
}

struct LGWebOSSecurityAPI: LGWebOSKeychainAPI {
    private func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.crisp.webos", kSecAttrAccount as String: host]
    }

    func read(host: String) -> (OSStatus, Data?) {
        var query = query(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(host: String, data: Data) -> OSStatus {
        SecItemUpdate(query(host) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func add(host: String, data: Data) -> OSStatus {
        var query = query(host)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete(host: String) -> OSStatus { SecItemDelete(query(host) as CFDictionary) }
}

struct LGWebOSKeychainStore: LGWebOSKeyStore {
    // Security APIs may wait for user input. Serialize them away from the UI/event-tap thread.
    private static let queue = DispatchQueue(label: "com.crisp.webos.keychain", qos: .utility)
    let api: any LGWebOSKeychainAPI
    init(api: any LGWebOSKeychainAPI = LGWebOSSecurityAPI()) { self.api = api }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func read(host: String) async throws -> String? {
        try await perform {
            let (status, data) = api.read(host: host)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw LGWebOSKeychainError(status: status) }
            guard let data, let key = String(data: data, encoding: .utf8) else {
                throw LGWebOSKeychainError(status: errSecDecode)
            }
            return key
        }
    }

    func save(_ key: String, host: String) async throws {
        try await perform {
            let data = Data(key.utf8)
            var status = api.update(host: host, data: data)
            if status == errSecItemNotFound { status = api.add(host: host, data: data) }
            guard status == errSecSuccess else { throw LGWebOSKeychainError(status: status) }
        }
    }

    func delete(host: String) async throws {
        try await perform {
            let status = api.delete(host: host)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LGWebOSKeychainError(status: status)
            }
        }
    }
}
