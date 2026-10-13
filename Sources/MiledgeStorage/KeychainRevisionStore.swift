import Foundation
import Security

public enum KeychainScope: String, Codable, Sendable {
    case deviceLocal
    case synchronizable
}

public enum KeychainOperation: String, Sendable {
    case read
    case append
}

public enum KeychainStorageError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidAccount
    case missingAccessGroup
    case malformedResult
    case duplicateIntegrity
    case osStatus(operation: KeychainOperation, status: OSStatus)
}

public struct KeychainConfiguration: Equatable, Sendable {
    public let service: String
    public let accessGroup: String?

    /// Omit the access group only for local development. Official signed apps must
    /// supply their shared, entitled group and keep it and the service stable.
    public init(service: String, accessGroup: String? = nil) throws {
        guard Self.isValidAttribute(service),
              accessGroup.map(Self.isValidAttribute) ?? true else {
            throw KeychainStorageError.invalidConfiguration
        }
        self.service = service
        self.accessGroup = accessGroup
    }

    fileprivate static func isValidAttribute(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\0")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Security results deliberately remain untyped until the store validates them.
public struct KeychainQueryResult {
    public let status: OSStatus
    public let value: Any?

    public init(status: OSStatus, value: Any? = nil) {
        self.status = status
        self.value = value
    }
}

/// A synchronous boundary. Stores and mutable clients are intentionally not Sendable;
/// keep each instance on its owning actor rather than sharing it across actors.
public protocol KeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> KeychainQueryResult
}

public struct SecurityKeychainClient: KeychainClient {
    private let addItem: ([String: Any]) -> OSStatus
    private let findItems: ([String: Any]) -> KeychainQueryResult

    public init() {
        self.init(
            add: { SecItemAdd($0 as CFDictionary, nil) },
            copyMatching: {
                var result: CFTypeRef?
                let status = SecItemCopyMatching($0 as CFDictionary, &result)
                return KeychainQueryResult(status: status, value: result)
            }
        )
    }

    internal init(
        add: @escaping ([String: Any]) -> OSStatus,
        copyMatching: @escaping ([String: Any]) -> KeychainQueryResult
    ) {
        addItem = add
        findItems = copyMatching
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        addItem(attributes)
    }

    public func copyMatching(_ query: [String: Any]) -> KeychainQueryResult {
        findItems(query)
    }
}

/// Stores opaque immutable revision payloads, without content-bearing attributes.
/// A successful append means locally stored, never verified iCloud delivery.
public final class KeychainRevisionStore {
    public let configuration: KeychainConfiguration
    private let client: any KeychainClient

    public init(
        configuration: KeychainConfiguration,
        client: (any KeychainClient)? = nil
    ) {
        self.configuration = configuration
        self.client = client ?? SecurityKeychainClient()
    }

    public func readAll() throws -> [Data] {
        var query = baseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        let result = client.copyMatching(query)
        if result.status == errSecItemNotFound { return [] }
        guard result.status == errSecSuccess else {
            throw KeychainStorageError.osStatus(operation: .read, status: result.status)
        }
        guard let values = result.value as? [Data] else {
            throw KeychainStorageError.malformedResult
        }
        return values
    }

    /// The account is an opaque record/revision identifier, not a title or filename.
    /// Existing identities cannot change bytes or storage scope.
    public func append(data: Data, account: String, scope: KeychainScope) throws {
        guard KeychainConfiguration.isValidAttribute(account) else {
            throw KeychainStorageError.invalidAccount
        }
        guard scope != .synchronizable || configuration.accessGroup != nil else {
            throw KeychainStorageError.missingAccessGroup
        }
        // Synchronizability participates in Keychain uniqueness. Looking across both
        // scopes prevents a sequential append from silently changing an identity's scope.
        if try verifyExisting(data: data, account: account, scope: scope) { return }
        var attributes = baseQuery()
        attributes[kSecAttrAccount as String] = account
        attributes[kSecValueData as String] = data
        attributes[kSecAttrSynchronizable as String] = scope == .synchronizable
        attributes[kSecAttrAccessible as String] = scope == .synchronizable
            ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = client.add(attributes)
        if status == errSecDuplicateItem {
            guard try verifyExisting(data: data, account: account, scope: scope) else {
                throw KeychainStorageError.duplicateIntegrity
            }
        } else if status != errSecSuccess {
            throw KeychainStorageError.osStatus(operation: .append, status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
        ]
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func verifyExisting(data: Data, account: String, scope: KeychainScope) throws -> Bool {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        let result = client.copyMatching(query)
        if result.status == errSecItemNotFound { return false }
        guard result.status == errSecSuccess else {
            throw KeychainStorageError.osStatus(operation: .read, status: result.status)
        }
        guard let items = result.value as? [[String: Any]], !items.isEmpty else {
            throw KeychainStorageError.malformedResult
        }
        for item in items {
            guard let storedData = item[kSecValueData as String] as? Data,
                  let sync = item[kSecAttrSynchronizable as String] as? NSNumber,
                  CFGetTypeID(sync) == CFBooleanGetTypeID() else {
                throw KeychainStorageError.malformedResult
            }
            guard storedData == data, sync.boolValue == (scope == .synchronizable) else {
                throw KeychainStorageError.duplicateIntegrity
            }
        }
        return true
    }
}
