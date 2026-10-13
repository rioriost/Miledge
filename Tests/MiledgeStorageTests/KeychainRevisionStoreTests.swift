import Foundation
import Security
import XCTest
@testable import MiledgeStorage

final class KeychainRevisionStoreTests: XCTestCase {
    private let payload = Data("synthetic revision".utf8)
    private let account = "550e8400-e29b-41d4-a716-446655440000/revision-id"

    func testConfigurationValidation() throws {
        for value in ["", " ", "service ", "\nservice", "a\0b"] {
            XCTAssertThrowsError(try KeychainConfiguration(service: value)) {
                XCTAssertEqual($0 as? KeychainStorageError, .invalidConfiguration)
            }
            XCTAssertThrowsError(try KeychainConfiguration(service: "test", accessGroup: value))
        }
        let configuration = try KeychainConfiguration(service: "org.example.test", accessGroup: "TEAM.test")
        XCTAssertEqual(configuration.service, "org.example.test")
        XCTAssertEqual(configuration.accessGroup, "TEAM.test")
        XCTAssertNil(try KeychainConfiguration(service: "test").accessGroup)
        XCTAssertEqual(try JSONDecoder().decode(KeychainScope.self, from: JSONEncoder().encode(KeychainScope.deviceLocal)), .deviceLocal)
    }

    func testReadAllUsesExplicitNonContentAttributesAndBothScopes() throws {
        let client = MockKeychainClient()
        client.results = [.init(status: errSecSuccess, value: [payload, Data()])]
        let store = try makeStore(client, accessGroup: "TEAM.shared")
        XCTAssertEqual(try store.readAll(), [payload, Data()])
        let query = try XCTUnwrap(client.queries.first)
        assertBase(query, accessGroup: "TEAM.shared")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(Set(query.keys), baseKeys.union([
            kSecAttrAccessGroup as String, kSecAttrSynchronizable as String,
            kSecMatchLimit as String, kSecReturnData as String,
        ]))
    }

    func testReadNotFoundIsEmptyButErrorsAndMalformedSuccessAreNot() throws {
        let client = MockKeychainClient()
        let store = try makeStore(client)
        client.results = [.init(status: errSecItemNotFound)]
        XCTAssertEqual(try store.readAll(), [])
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable] {
            client.results = [.init(status: status)]
            XCTAssertThrowsError(try store.readAll()) {
                XCTAssertEqual($0 as? KeychainStorageError, .osStatus(operation: .read, status: status))
            }
        }
        for value: Any? in [nil, payload, [payload, "not data"] as [Any], ["wrong": payload]] {
            client.results = [.init(status: errSecSuccess, value: value)]
            XCTAssertThrowsError(try store.readAll()) {
                XCTAssertEqual($0 as? KeychainStorageError, .malformedResult)
            }
        }
        client.results = [.init(status: errSecSuccess, value: [Data]())]
        XCTAssertEqual(try store.readAll(), [])
    }

    func testFoundationSecurityResultShapesBridgeWithoutLoss() throws {
        let client = MockKeychainClient()
        let store = try makeStore(client)
        client.results = [.init(status: errSecSuccess, value: NSArray(object: NSData(data: payload)))]
        XCTAssertEqual(try store.readAll(), [payload])
        let attributes = NSDictionary(dictionary: [
            kSecValueData as String: NSData(data: payload),
            kSecAttrSynchronizable as String: NSNumber(value: false),
        ])
        client.results = [.init(status: errSecSuccess, value: NSArray(object: attributes))]
        try store.append(data: payload, account: account, scope: .deviceLocal)
        XCTAssertTrue(client.additions.isEmpty)
    }

    func testAppendBothScopeAttributesAndNoSearchableContent() throws {
        for scope in [KeychainScope.deviceLocal, .synchronizable] {
            let client = MockKeychainClient()
            client.results = [.init(status: errSecItemNotFound)]
            let store = try makeStore(client, accessGroup: "TEAM.shared")
            try store.append(data: payload, account: account, scope: scope)
            let attributes = try XCTUnwrap(client.additions.first)
            assertBase(attributes, accessGroup: "TEAM.shared")
            XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, account)
            XCTAssertEqual(attributes[kSecValueData as String] as? Data, payload)
            XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, scope == .synchronizable)
            XCTAssertEqual(
                attributes[kSecAttrAccessible as String] as? String,
                (scope == .synchronizable ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly) as String
            )
            XCTAssertEqual(Set(attributes.keys), baseKeys.union([
                kSecAttrAccessGroup as String,
                kSecAttrAccount as String, kSecValueData as String,
                kSecAttrSynchronizable as String, kSecAttrAccessible as String,
            ]))
            let lookup = try XCTUnwrap(client.queries.first)
            assertBase(lookup, accessGroup: "TEAM.shared")
            XCTAssertEqual(lookup[kSecAttrAccount as String] as? String, account)
            XCTAssertEqual(lookup[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
            XCTAssertEqual(lookup[kSecReturnAttributes as String] as? Bool, true)
            XCTAssertEqual(lookup[kSecReturnData as String] as? Bool, true)
            XCTAssertEqual(lookup[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        }
    }

    func testInvalidAccountDoesNotCallClient() throws {
        let client = MockKeychainClient()
        let store = try makeStore(client)
        for value in ["", " ", "trailing ", "a\0b"] {
            XCTAssertThrowsError(try store.append(data: payload, account: value, scope: .deviceLocal)) {
                XCTAssertEqual($0 as? KeychainStorageError, .invalidAccount)
            }
        }
        XCTAssertTrue(client.queries.isEmpty)
        XCTAssertTrue(client.additions.isEmpty)
    }

    func testSynchronizableAppendRequiresAnExplicitEntitledAccessGroup() throws {
        let client = MockKeychainClient()
        let store = try makeStore(client)
        XCTAssertThrowsError(try store.append(data: payload, account: account, scope: .synchronizable)) {
            XCTAssertEqual($0 as? KeychainStorageError, .missingAccessGroup)
        }
        XCTAssertTrue(client.queries.isEmpty)
        XCTAssertTrue(client.additions.isEmpty)
    }

    func testPreexistingIdenticalRevisionIsIdempotentForEitherScope() throws {
        for scope in [KeychainScope.deviceLocal, .synchronizable] {
            let client = MockKeychainClient()
            client.results = [existing(payload, scope)]
            try makeStore(client, accessGroup: "TEAM.shared").append(data: payload, account: account, scope: scope)
            XCTAssertTrue(client.additions.isEmpty)
        }
    }

    func testDuplicateRaceIsIdempotentOnlyWithIdenticalBytesAndScope() throws {
        for scope in [KeychainScope.deviceLocal, .synchronizable] {
            let client = MockKeychainClient()
            client.addStatus = errSecDuplicateItem
            client.results = [.init(status: errSecItemNotFound), existing(payload, scope)]
            try makeStore(client, accessGroup: "TEAM.shared").append(data: payload, account: account, scope: scope)
            XCTAssertEqual(client.additions.count, 1)
            XCTAssertEqual(client.queries.count, 2)
        }
        for result in [
            existing(Data("different".utf8), .deviceLocal),
            existing(payload, .synchronizable),
            KeychainQueryResult(status: errSecItemNotFound),
        ] {
            let client = MockKeychainClient()
            client.addStatus = errSecDuplicateItem
            client.results = [.init(status: errSecItemNotFound), result]
            XCTAssertThrowsError(try makeStore(client).append(data: payload, account: account, scope: .deviceLocal)) {
                XCTAssertEqual($0 as? KeychainStorageError, .duplicateIntegrity)
            }
        }
    }

    func testPreflightRejectsCrossScopeOrContentChangeAndMixedMatches() throws {
        for result in [
            existing(payload, .synchronizable),
            existing(Data(), .deviceLocal),
            .init(status: errSecSuccess, value: [
                item(payload, .deviceLocal), item(payload, .synchronizable),
            ]),
        ] {
            let client = MockKeychainClient()
            client.results = [result]
            XCTAssertThrowsError(try makeStore(client).append(data: payload, account: account, scope: .deviceLocal)) {
                XCTAssertEqual($0 as? KeychainStorageError, .duplicateIntegrity)
            }
            XCTAssertTrue(client.additions.isEmpty)
        }
    }

    func testMalformedDuplicateResultsAlwaysThrow() throws {
        for value: Any? in [
            nil, payload, [[String: Any]](), ["single": payload],
            [[kSecValueData as String: payload]],
            [[kSecValueData as String: "not data", kSecAttrSynchronizable as String: false]],
            [[kSecValueData as String: payload, kSecAttrSynchronizable as String: NSNumber(value: 0)]],
        ] {
            let client = MockKeychainClient()
            client.results = [.init(status: errSecSuccess, value: value)]
            XCTAssertThrowsError(try makeStore(client).append(data: payload, account: account, scope: .deviceLocal)) {
                XCTAssertEqual($0 as? KeychainStorageError, .malformedResult)
            }
        }
    }

    func testAppendAndLookupOSFailuresRemainExplicit() throws {
        let client = MockKeychainClient()
        let store = try makeStore(client)
        client.results = [.init(status: errSecInteractionNotAllowed)]
        XCTAssertThrowsError(try store.append(data: payload, account: account, scope: .deviceLocal)) {
            XCTAssertEqual($0 as? KeychainStorageError, .osStatus(operation: .read, status: errSecInteractionNotAllowed))
        }
        client.results = [.init(status: errSecItemNotFound)]
        client.addStatus = errSecMissingEntitlement
        XCTAssertThrowsError(try store.append(data: payload, account: account, scope: .deviceLocal)) {
            XCTAssertEqual($0 as? KeychainStorageError, .osStatus(operation: .append, status: errSecMissingEntitlement))
        }
        client.results = [.init(status: errSecItemNotFound), .init(status: errSecAuthFailed)]
        client.addStatus = errSecDuplicateItem
        XCTAssertThrowsError(try store.append(data: payload, account: account, scope: .deviceLocal)) {
            XCTAssertEqual($0 as? KeychainStorageError, .osStatus(operation: .read, status: errSecAuthFailed))
        }
    }

    func testSecurityAdapterForwardsAttributesAndStatusesWithoutRealKeychainAccess() throws {
        var added: [String: Any]?
        var queried: [String: Any]?
        let client = SecurityKeychainClient(
            add: { added = $0; return errSecMissingEntitlement },
            copyMatching: {
                queried = $0
                return .init(status: errSecSuccess, value: [self.payload])
            }
        )
        XCTAssertEqual(client.add(["synthetic": true]), errSecMissingEntitlement)
        XCTAssertEqual(added?["synthetic"] as? Bool, true)
        let result = client.copyMatching(["query": false])
        XCTAssertEqual(queried?["query"] as? Bool, false)
        XCTAssertEqual(result.status, errSecSuccess)
        XCTAssertEqual(result.value as? [Data], [payload])
        // Construct, but never call, the actual Security.framework boundary.
        _ = SecurityKeychainClient()
        _ = KeychainRevisionStore(configuration: try KeychainConfiguration(service: "synthetic-unused"))
    }

    private var baseKeys: Set<String> {
        var keys: Set<String> = [kSecClass as String, kSecAttrService as String]
        #if os(macOS)
        keys.insert(kSecUseDataProtectionKeychain as String)
        #endif
        return keys
    }

    private func assertBase(_ query: [String: Any], accessGroup: String? = nil) {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "org.example.miledge.synthetic")
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, accessGroup)
        #if os(macOS)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
    }

    private func makeStore(_ client: MockKeychainClient, accessGroup: String? = nil) throws -> KeychainRevisionStore {
        KeychainRevisionStore(
            configuration: try KeychainConfiguration(service: "org.example.miledge.synthetic", accessGroup: accessGroup),
            client: client
        )
    }

    private func existing(_ data: Data, _ scope: KeychainScope) -> KeychainQueryResult {
        .init(status: errSecSuccess, value: [item(data, scope)])
    }

    private func item(_ data: Data, _ scope: KeychainScope) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrSynchronizable as String: scope == .synchronizable]
    }
}

private final class MockKeychainClient: KeychainClient {
    var results: [KeychainQueryResult] = []
    var addStatus: OSStatus = errSecSuccess
    var additions: [[String: Any]] = []
    var queries: [[String: Any]] = []

    func add(_ attributes: [String: Any]) -> OSStatus {
        additions.append(attributes)
        return addStatus
    }

    func copyMatching(_ query: [String: Any]) -> KeychainQueryResult {
        queries.append(query)
        precondition(!results.isEmpty, "Unexpected mock Keychain call")
        return results.removeFirst()
    }
}
