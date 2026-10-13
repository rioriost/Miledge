import Foundation
import MiledgeDomain

public enum StructuredFieldError: Error, Equatable {
    case unsupportedValue
    case duplicateComponents
    case invalidRecoveryIdentifiers
}

public struct AddressFieldDraft: Equatable, Sendable {
    public struct Component: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var value: String

        public init(name: String, value: String, id: UUID = UUID()) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    public var components: [Component]

    public init(value: JSONValue) throws {
        guard case .object(let values) = value else { throw StructuredFieldError.unsupportedValue }
        components = try values.keys.sorted().map { name in
            guard case .string(let text) = values[name] else { throw StructuredFieldError.unsupportedValue }
            return Component(name: name, value: text)
        }
    }

    public func json() throws -> JSONValue {
        guard Set(components.map(\.name)).count == components.count else {
            throw StructuredFieldError.duplicateComponents
        }
        return .object(Dictionary(uniqueKeysWithValues: components.map { ($0.name, .string($0.value)) }))
    }
}

public struct StringListFieldDraft: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var value: String

        public init(value: String, id: UUID = UUID()) {
            self.id = id
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(strings: [String]) {
        entries = strings.map { Entry(value: $0) }
    }

    public init(value: JSONValue) throws {
        guard case .array(let values) = value else { throw StructuredFieldError.unsupportedValue }
        entries = try values.map { value in
            guard case .string(let text) = value else { throw StructuredFieldError.unsupportedValue }
            return Entry(value: text)
        }
    }

    public var json: JSONValue {
        .array(strings.map(JSONValue.string))
    }

    public var strings: [String] { entries.map(\.value) }
}

public struct RelatedItemsDraft: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let recordId: UUID

        public init(recordId: UUID, id: UUID = UUID()) {
            self.id = id
            self.recordId = recordId
        }
    }

    public var entries: [Entry]

    public init(recordIds: [UUID]) {
        entries = recordIds.map { Entry(recordId: $0) }
    }

    public var recordIds: [UUID] { entries.map(\.recordId) }
}

public struct RecoveryCodesFieldDraft: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: String
        public var code: String
        public var used: Bool

        public init(code: String, used: Bool = false, id: String = UUID().uuidString) {
            self.id = id
            self.code = code
            self.used = used
        }
    }

    public var entries: [Entry]

    public init(value: JSONValue) throws {
        guard case .array(let values) = value else { throw StructuredFieldError.unsupportedValue }
        entries = try values.map { value in
            guard case .object(let properties) = value,
                  Set(properties.keys) == ["id", "code", "used"],
                  case .string(let id) = properties["id"],
                  case .string(let code) = properties["code"],
                  case .bool(let used) = properties["used"] else {
                throw StructuredFieldError.unsupportedValue
            }
            return Entry(code: code, used: used, id: id)
        }
        _ = try json()
    }

    public func json() throws -> JSONValue {
        guard entries.allSatisfy({ !$0.id.isEmpty }),
              Set(entries.map(\.id)).count == entries.count else {
            throw StructuredFieldError.invalidRecoveryIdentifiers
        }
        return .array(entries.map {
            .object(["id": .string($0.id), "code": .string($0.code), "used": .bool($0.used)])
        })
    }
}
