import DictationCore
import Foundation
import Observation
import Security

/// Storage for the one secret this app has.
@MainActor
public protocol SecretStoring: AnyObject {
    func read() throws -> String?
    func write(_ secret: String) throws
    func delete() throws
}

public struct KeychainError: Error, Equatable {
    public var status: OSStatus
}

/// A generic-password item in the user's login keychain. Not synchronized to iCloud.
@MainActor
public final class KeychainSecretStore: SecretStoring {
    public let service: String
    public let account: String

    public init(service: String, account: String = "gemini-api-key") {
        self.service = service
        self.account = account
    }

    /// Identifies only this app's item; the query never matches other Keychain entries.
    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError(status: errSecDecode)
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func write(_ secret: String) throws {
        let data = Data(secret.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Gemini Dictation API key"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Session-only storage, also used by tests and UI snapshots.
@MainActor
public final class InMemorySecretStore: SecretStoring {
    public private(set) var secret: String?
    public private(set) var readCount = 0

    public init(secret: String? = nil) {
        self.secret = secret
    }

    public func read() throws -> String? {
        readCount += 1
        return secret
    }

    public func write(_ secret: String) throws {
        self.secret = secret
    }

    public func delete() throws {
        secret = nil
    }
}

public enum APIKeyStatus: Equatable, Sendable {
    case notSet
    case sessionOnly
    case savedInKeychain
}

public enum APIKeyInputError: Error, Equatable {
    case empty
    case containsWhitespace
}

/// Result of flipping the "store in Keychain" switch.
public enum KeyPersistenceChange: Equatable, Sendable {
    case unchanged
    case savedToKeychain
    case keptInMemoryOnly
    case removed
}

/// The API key entered by the user. Read lazily, cached in memory for the session,
/// and never logged, displayed, or sent anywhere except the `x-goog-api-key` header.
@MainActor
@Observable
public final class APIKeyManager: APIKeyProviding {
    @ObservationIgnored private let store: SecretStoring
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var cachedKey: String?
    private var hasCachedKey = false

    public init(store: SecretStoring, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    public var status: APIKeyStatus {
        if settings.keySavedInKeychain { return .savedInKeychain }
        return hasCachedKey ? .sessionOnly : .notSet
    }

    public var isConfigured: Bool {
        status != .notSet
    }

    public func apiKey() throws -> String? {
        if let cachedKey { return cachedKey }
        guard settings.keySavedInKeychain else { return nil }
        guard let key = try store.read(), !key.isEmpty else {
            // The item was removed outside the app.
            settings.keySavedInKeychain = false
            return nil
        }
        remember(key)
        return key
    }

    public func save(_ rawKey: String, persist: Bool) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIKeyInputError.empty }
        guard !key.contains(where: { $0.isWhitespace }) else { throw APIKeyInputError.containsWhitespace }
        if persist {
            try store.write(key)
            settings.keySavedInKeychain = true
        } else if settings.keySavedInKeychain {
            try store.delete()
            settings.keySavedInKeychain = false
        }
        remember(key)
    }

    /// Applies the "store in Keychain" switch to the key that is already set.
    public func applyPersistence(_ persist: Bool) throws -> KeyPersistenceChange {
        if persist {
            guard !settings.keySavedInKeychain, let cachedKey else { return .unchanged }
            try store.write(cachedKey)
            settings.keySavedInKeychain = true
            return .savedToKeychain
        }
        guard settings.keySavedInKeychain else { return .unchanged }
        // Delete without reading first, so switching off never causes a Keychain prompt.
        try store.delete()
        settings.keySavedInKeychain = false
        return hasCachedKey ? .keptInMemoryOnly : .removed
    }

    public func remove() throws {
        cachedKey = nil
        hasCachedKey = false
        // Always delete this app's item, even if the marker was lost, so nothing is left behind.
        try store.delete()
        settings.keySavedInKeychain = false
    }

    private func remember(_ key: String) {
        cachedKey = key
        hasCachedKey = true
    }
}
