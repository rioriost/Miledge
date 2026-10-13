import Foundation

public enum StorageScope: String, Codable, Sendable {
    case deviceLocal = "device-local"
    case synchronizable
}

public struct VaultField: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var value: JSONValue
    public var concealed: Bool
    public var label: String?
    public var unknownProperties: [String: JSONValue]

    public init(
        id: String = UUID().uuidString, kind: String = "string", value: JSONValue = .string(""),
        concealed: Bool = false, label: String? = nil, unknownProperties: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.concealed = concealed
        self.label = label
        self.unknownProperties = unknownProperties
    }

    public init(from decoder: any Decoder) throws { self = try Self(json: JSONValue(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }

    init(json: JSONValue) throws {
        var object = try JSONObject(json, path: "field")
        id = try object.string("id")
        kind = try object.string("kind")
        value = try object.required("value")
        concealed = try object.bool("concealed")
        if let labelValue = object.remove("label"), labelValue != .null {
            guard case .string(let text) = labelValue else { throw RevisionError.malformedProperty("label") }
            label = text
        } else { label = nil }
        unknownProperties = object.values
    }

    var json: JSONValue {
        var object = unknownProperties
        object["id"] = .string(id)
        object["kind"] = .string(kind)
        object["value"] = value
        object["concealed"] = .bool(concealed)
        object["label"] = label.map(JSONValue.string)
        return .object(object)
    }
}

public struct VaultSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var fields: [VaultField]
    public var unknownProperties: [String: JSONValue]

    public init(id: String = UUID().uuidString, fields: [VaultField] = [], unknownProperties: [String: JSONValue] = [:]) {
        self.id = id
        self.fields = fields
        self.unknownProperties = unknownProperties
    }

    public init(from decoder: any Decoder) throws { self = try Self(json: JSONValue(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }

    init(json: JSONValue) throws {
        var object = try JSONObject(json, path: "section")
        id = try object.string("id")
        fields = try object.array("fields").map(VaultField.init(json:))
        unknownProperties = object.values
    }

    var json: JSONValue {
        var object = unknownProperties
        object["id"] = .string(id)
        object["fields"] = .array(fields.map(\.json))
        return .object(object)
    }
}

/// Mutable value drafts are allowed; persisted revisions must be added, never overwritten.
public struct VaultRevision: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var recordId: UUID
    public var revisionId: UUID
    public var parentRevisionIds: [UUID]
    public var templateId: String
    public var templateVersion: Int
    public var storageScope: StorageScope
    public var title: String
    public var tags: [String]
    public var favorite: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var deleted: Bool
    public var sections: [VaultSection]
    public var attachments: [JSONValue]
    public var linkedRecordIds: [UUID]
    public var unknownProperties: [String: JSONValue]
    /// Preserves future storage scopes without treating them as writable local records.
    public private(set) var unsupportedStorageScope: String?
    private var originalCreatedAt: String?
    private var originalModifiedAt: String?

    public var id: UUID { revisionId }
    public var isReadOnly: Bool { !VaultPolicy.unsupportedReasons(for: self).isEmpty || VaultPolicy.containsHealthInformation(self) }

    public init(
        schemaVersion: Int = 1, recordId: UUID = UUID(), revisionId: UUID = UUID(),
        parentRevisionIds: [UUID] = [], templateId: String = "custom-item", templateVersion: Int = 1,
        storageScope: StorageScope = .deviceLocal, title: String = "", tags: [String] = [],
        favorite: Bool = false, createdAt: Date = Date(), modifiedAt: Date? = nil, deleted: Bool = false,
        sections: [VaultSection] = [], attachments: [JSONValue] = [], linkedRecordIds: [UUID] = [],
        unknownProperties: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.recordId = recordId
        self.revisionId = revisionId
        self.parentRevisionIds = parentRevisionIds
        self.templateId = templateId
        self.templateVersion = templateVersion
        self.storageScope = storageScope
        self.title = title
        self.tags = tags
        self.favorite = favorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.deleted = deleted
        self.sections = sections
        self.attachments = attachments
        self.linkedRecordIds = linkedRecordIds
        self.unknownProperties = unknownProperties
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var object: [String: JSONValue] = [:]
        for key in container.allKeys {
            if ["schemaVersion", "templateVersion"].contains(key.stringValue) {
                object[key.stringValue] = .number(String(try container.decode(Int.self, forKey: key)))
            } else { object[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
        }
        self = try Self(json: .object(object))
    }
    public func encode(to encoder: any Encoder) throws { try json.encodeRevision(to: encoder) }

    init(json: JSONValue) throws {
        var object = try JSONObject(json, path: "revision")
        schemaVersion = try object.integer("schemaVersion")
        recordId = try object.uuid("recordId")
        revisionId = try object.uuid("revisionId")
        parentRevisionIds = try object.uuids("parentRevisionIds")
        templateId = try object.string("templateId")
        templateVersion = try object.integer("templateVersion")
        let scope = try object.string("storageScope")
        storageScope = StorageScope(rawValue: scope) ?? .deviceLocal
        unsupportedStorageScope = StorageScope(rawValue: scope) == nil ? scope : nil
        title = try object.string("title")
        tags = try object.strings("tags")
        favorite = try object.bool("favorite")
        let created = try object.string("createdAt")
        let modified = try object.string("modifiedAt")
        createdAt = try RevisionTimestamp.parse(created, path: "createdAt")
        modifiedAt = try RevisionTimestamp.parse(modified, path: "modifiedAt")
        originalCreatedAt = created
        originalModifiedAt = modified
        deleted = try object.bool("deleted")
        sections = try object.array("sections").map(VaultSection.init(json:))
        attachments = try object.array("attachments")
        linkedRecordIds = try object.uuids("linkedRecordIds")
        unknownProperties = object.values
        try VaultPolicy.validateStructure(self)
    }

    var json: JSONValue {
        get throws {
            var object = unknownProperties
            object["schemaVersion"] = .number(String(schemaVersion))
            object["recordId"] = .string(recordId.uuidString.lowercased())
            object["revisionId"] = .string(revisionId.uuidString.lowercased())
            object["parentRevisionIds"] = .array(parentRevisionIds.map { .string($0.uuidString.lowercased()) })
            object["templateId"] = .string(templateId)
            object["templateVersion"] = .number(String(templateVersion))
            object["storageScope"] = .string(unsupportedStorageScope ?? storageScope.rawValue)
            object["title"] = .string(title)
            object["tags"] = .array(tags.map(JSONValue.string))
            object["favorite"] = .bool(favorite)
            object["createdAt"] = .string(try RevisionTimestamp.string(createdAt, original: originalCreatedAt))
            object["modifiedAt"] = .string(try RevisionTimestamp.string(modifiedAt, original: originalModifiedAt))
            object["deleted"] = .bool(deleted)
            object["sections"] = .array(sections.map(\.json))
            object["attachments"] = .array(attachments)
            object["linkedRecordIds"] = .array(linkedRecordIds.map { .string($0.uuidString.lowercased()) })
            return .object(object)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Timestamp spelling is retained for backup, but is not distinct revision content.
        guard let left = lhs.canonicalContent, let right = rhs.canonicalContent else { return false }
        return left == right
    }

    private var canonicalContent: JSONValue? {
        guard case .object(var object) = try? json else { return nil }
        object["createdAt"] = .string(String(createdAt.timeIntervalSinceReferenceDate))
        object["modifiedAt"] = .string(String(modifiedAt.timeIntervalSinceReferenceDate))
        return .object(object)
    }
}

public enum RevisionCodec {
    /// Encoding is also used for read-only backup. Call VaultPolicy before persistence.
    public static func encode(_ revision: VaultRevision) throws -> Data {
        try VaultPolicy.validateStructure(revision)
        return try LosslessJSON.encode(revision.json)
    }

    public static func decode(_ data: Data) throws -> VaultRevision {
        try VaultRevision(json: LosslessJSON.decode(data))
    }
}

enum RevisionTimestamp {
    static func parse(_ string: String, path: String) throws -> Date {
        guard string.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z"#, options: .regularExpression
        ) != nil else { throw RevisionError.malformedProperty(path) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let segments = string.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        guard let base = formatter.date(from: String(segments[0]) + "Z") else { throw RevisionError.malformedProperty(path) }
        // Foundation normalizes dates such as February 30; reject them instead.
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: base)
        let prefix = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
        guard string.hasPrefix(prefix) else { throw RevisionError.malformedProperty(path) }
        guard segments.count == 2 else { return base }
        let fractionText = "0." + segments[1]
        if base.timeIntervalSinceReferenceDate == 0 {
            return Date(timeIntervalSinceReferenceDate: Double(fractionText)!)
        }
        let fraction = Decimal(string: "0." + segments[1].prefix(38), locale: Locale(identifier: "en_US_POSIX"))!
        let reference = Decimal(string: String(base.timeIntervalSinceReferenceDate))! + fraction
        return Date(timeIntervalSinceReferenceDate: Double(NSDecimalNumber(decimal: reference).stringValue)!)
    }

    static func string(_ date: Date, original: String?) throws -> String {
        guard date.timeIntervalSince1970.isFinite else { throw RevisionError.malformedProperty("timestamp") }
        if let original, try parse(original, path: "timestamp") == date { return original }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let seconds = floor(date.timeIntervalSinceReferenceDate)
        let base = formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
        guard let precise = Decimal(string: String(date.timeIntervalSinceReferenceDate), locale: Locale(identifier: "en_US_POSIX")) else {
            throw RevisionError.malformedProperty("timestampPrecision")
        }
        let fraction = precise - Decimal(string: String(seconds))!
        // Decimal subtraction avoids cancellation immediately before the reference epoch.
        let digits = fraction == 0 ? "" : String(NSDecimalNumber(decimal: fraction).stringValue.dropFirst(2))
        let result = String(base.dropLast()) + (digits.isEmpty ? "" : "." + digits) + "Z"
        guard try parse(result, path: "timestamp") == date else { throw RevisionError.malformedProperty("timestampPrecision") }
        return result
    }
}

struct JSONObject {
    var values: [String: JSONValue]

    init(_ json: JSONValue, path: String) throws {
        guard case .object(let values) = json else { throw RevisionError.malformedProperty(path) }
        self.values = values
    }

    mutating func remove(_ key: String) -> JSONValue? { values.removeValue(forKey: key) }
    mutating func required(_ key: String) throws -> JSONValue {
        guard let value = remove(key) else { throw RevisionError.malformedProperty(key) }
        return value
    }
    mutating func string(_ key: String) throws -> String {
        guard case .string(let value) = try required(key) else { throw RevisionError.malformedProperty(key) }
        return value
    }
    mutating func bool(_ key: String) throws -> Bool {
        guard case .bool(let value) = try required(key) else { throw RevisionError.malformedProperty(key) }
        return value
    }
    mutating func integer(_ key: String) throws -> Int {
        guard case .number(let token) = try required(key), let value = Int(token) else {
            throw RevisionError.malformedProperty(key)
        }
        return value
    }
    mutating func array(_ key: String) throws -> [JSONValue] {
        guard case .array(let values) = try required(key) else { throw RevisionError.malformedProperty(key) }
        return values
    }
    mutating func strings(_ key: String) throws -> [String] {
        try array(key).map {
            guard case .string(let value) = $0 else { throw RevisionError.malformedProperty(key) }
            return value
        }
    }
    mutating func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else { throw RevisionError.malformedProperty(key) }
        return value
    }
    mutating func uuids(_ key: String) throws -> [UUID] {
        try strings(key).map {
            guard let value = UUID(uuidString: $0) else { throw RevisionError.malformedProperty(key) }
            return value
        }
    }
}

private extension JSONValue {
    func encodeRevision(to encoder: any Encoder) throws {
        // Only schema/template versions use machine integers. Other numeric tokens require the lossless codec.
        guard case .object(let object) = self else { throw RevisionError.malformedProperty("revision") }
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in object {
            let codingKey = DynamicKey(stringValue: key)!
            if ["schemaVersion", "templateVersion"].contains(key), case .number(let token) = value, let number = Int(token) {
                try container.encode(number, forKey: codingKey)
            } else { try container.encode(value, forKey: codingKey) }
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
