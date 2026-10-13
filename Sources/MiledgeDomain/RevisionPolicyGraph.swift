import Foundation

public enum VaultPolicy {
    public static let supportedSchemaVersion = 1
    public static let supportedFieldKinds: Set<String> = [
        "string", "concealed", "multiline", "url", "email", "phone", "address",
        "date", "year-month", "number", "select", "multi-select", "otp-seed",
        "key-material", "boolean", "recovery-codes"
    ]
    public static let prohibitedHealthTypes: Set<String> = [
        "medical-record", "medical", "health", "health-record", "health-information",
        "diagnosis", "diagnostic-record", "test-result", "lab-result", "laboratory-result",
        "prescription", "medication", "disability", "disability-record", "vaccination",
        "vaccination-certificate", "medical-certificate", "health-insurance",
        "health-insurance-card", "medical-insurance", "long-term-care-insurance",
        "illness-insurance", "medical-bill", "medical-claim", "health-disclosure",
        "medical-expense", "medical-deduction", "medical-device", "medical-device-purchase",
        "health-insurance-identifier", "injury", "treatment"
    ]

    public static func validateForWrite(_ revision: VaultRevision) throws {
        if let type = healthType(in: revision) { throw RevisionError.healthInformationProhibited(type) }
        let reasons = unsupportedReasons(for: revision)
        guard reasons.isEmpty else { throw RevisionError.unsupported(reasons) }
        try validateStructure(revision)
        guard !revision.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RevisionError.malformedProperty("title")
        }
        for section in revision.sections {
            for field in section.fields { try validateValue(field) }
        }
    }

    /// A restore may preserve unknown non-health data as read-only, never convert it.
    public static func validateForRestore(_ revision: VaultRevision) throws {
        if let type = healthType(in: revision) { throw RevisionError.healthInformationProhibited(type) }
        if let scope = revision.unsupportedStorageScope {
            throw RevisionError.unsupported(["storageScope:\(scope)"])
        }
        try validateStructure(revision)
        if unsupportedReasons(for: revision).isEmpty { try validateForWrite(revision) }
    }

    /// Unknown attributes conservatively make the whole record read-only, not just the field.
    public static func unsupportedReasons(for revision: VaultRevision) -> [String] {
        var reasons: [String] = []
        if revision.schemaVersion != supportedSchemaVersion { reasons.append("schemaVersion:\(revision.schemaVersion)") }
        if let template = TemplateCatalog.template(id: revision.templateId) {
            if revision.templateVersion != template.version { reasons.append("templateVersion:\(revision.templateVersion)") }
        } else { reasons.append("templateId:\(revision.templateId)") }
        if let scope = revision.unsupportedStorageScope { reasons.append("storageScope:\(scope)") }
        if !revision.unknownProperties.isEmpty { reasons.append("unknown revision attributes") }
        for section in revision.sections {
            if !section.unknownProperties.isEmpty { reasons.append("unknown section attributes:\(section.id)") }
            for field in section.fields {
                if !supportedFieldKinds.contains(field.kind) { reasons.append("fieldKind:\(field.kind)") }
                else if !valueShapeIsSupported(field) { reasons.append("fieldValueType:\(field.id)") }
                if !field.unknownProperties.isEmpty { reasons.append("unknown field attributes:\(field.id)") }
            }
        }
        let fields = revision.sections.flatMap(\.fields)
        if revision.templateId == "affiliate-account" {
            let profileIds = fields.filter { $0.id == "profileId" }.compactMap { field -> String? in
                guard case .string(let value) = field.value, !value.isEmpty else { return nil }
                return value
            }
            for id in profileIds {
                if !TemplateCatalog.affiliateProfiles.contains(where: { $0.id == id }) { reasons.append("profileId:\(id)") }
            }
            for field in fields where field.id == "profileVersion" {
                if field.value != .string("") && field.value != .string("1") { reasons.append("profileVersion") }
            }
        }
        if revision.templateId == "api-credential" {
            for field in fields where field.id == "profileId" {
                if case .string(let id) = field.value, !id.isEmpty,
                   !TemplateCatalog.apiCredentialProfiles.contains(where: { $0.id == id }) { reasons.append("profileId:\(id)") }
            }
        }
        for attachment in revision.attachments {
            guard case .object(let object) = attachment else { reasons.append("attachment shape"); continue }
            let knownKeys: Set<String> = ["blobId", "formatVersion", "algorithm", "key", "originalFilename", "mediaType", "plaintextSize"]
            if !Set(object.keys).isSubset(of: knownKeys) { reasons.append("unknown attachment attributes") }
            if let version = object["formatVersion"], version != .number("1") && version != .string("1") {
                reasons.append("attachment formatVersion")
            }
            if let algorithm = object["algorithm"], algorithm != .string("AES-GCM") {
                reasons.append("attachment algorithm")
            }
        }
        return reasons
    }

    public static func containsHealthInformation(_ revision: VaultRevision) -> Bool { healthType(in: revision) != nil }

    static func validateStructure(_ revision: VaultRevision) throws {
        guard revision.schemaVersion > 0 else { throw RevisionError.malformedProperty("schemaVersion") }
        guard revision.templateVersion > 0 else { throw RevisionError.malformedProperty("templateVersion") }
        guard !revision.templateId.isEmpty else { throw RevisionError.malformedProperty("templateId") }
        guard revision.createdAt.timeIntervalSince1970.isFinite, revision.modifiedAt.timeIntervalSince1970.isFinite else {
            throw RevisionError.malformedProperty("timestamp")
        }
        var parents: Set<UUID> = []
        for parent in revision.parentRevisionIds {
            guard parents.insert(parent).inserted else { throw RevisionError.duplicateParent(parent) }
        }
        var sections: Set<String> = []
        for section in revision.sections {
            guard !section.id.isEmpty, sections.insert(section.id).inserted else {
                throw RevisionError.malformedProperty("section.id")
            }
            var fields: Set<String> = []
            for field in section.fields {
                guard !field.id.isEmpty, fields.insert(field.id).inserted, !field.kind.isEmpty else {
                    throw RevisionError.malformedProperty("field.id/kind")
                }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-").lowercased()
    }

    private static func healthType(in revision: VaultRevision) -> String? {
        if prohibitedHealthTypes.contains(normalized(revision.templateId)) { return revision.templateId }
        for section in revision.sections {
            if let type = healthType(in: .object(section.unknownProperties)) { return type }
        }
        for field in revision.sections.flatMap(\.fields) {
            if prohibitedHealthTypes.contains(normalized(field.kind)) { return field.kind }
            if prohibitedHealthTypes.contains(normalized(field.id)) { return field.id }
            if ["type", "policyType", "insuranceType", "identifierSystem", "profileId"].contains(field.id),
               case .string(let value) = field.value, prohibitedHealthTypes.contains(normalized(value)) { return value }
            if let type = healthType(in: .object(field.unknownProperties)) ?? healthType(in: field.value) { return type }
        }
        return healthType(in: .object(revision.unknownProperties)) ??
            revision.attachments.compactMap { healthType(in: $0) }.first
    }

    private static func healthType(in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let value = object[key]!
                if ["templateId", "kind", "type", "policyType", "insuranceType", "identifierSystem", "profileId"].contains(key),
                   case .string(let string) = value, prohibitedHealthTypes.contains(normalized(string)) { return string }
                if let type = healthType(in: value) { return type }
            }
        case .array(let values):
            for value in values { if let type = healthType(in: value) { return type } }
        default: break
        }
        return nil
    }

    private static func valueShapeIsSupported(_ field: VaultField) -> Bool {
        switch field.kind {
        case "address":
            guard case .object(let components) = field.value else { return false }
            return components.values.allSatisfy { if case .string = $0 { return true }; return false }
        case "multi-select":
            guard case .array(let values) = field.value else { return false }
            return values.allSatisfy { if case .string = $0 { return true }; return false }
        case "boolean":
            if case .bool = field.value { return true }
            return false
        case "recovery-codes":
            guard case .array(let codes) = field.value else { return false }
            return codes.allSatisfy {
                guard case .object(let object) = $0, Set(object.keys).isSubset(of: ["id", "code", "used"]),
                      case .string = object["id"], case .string = object["code"], case .bool = object["used"] else { return false }
                return true
            }
        default:
            if case .string = field.value { return true }
            return false
        }
    }

    private static func validateValue(_ field: VaultField) throws {
        func invalid() -> RevisionError { .malformedProperty("field.value:\(field.id)") }
        switch field.kind {
        case "address":
            guard case .object(let components) = field.value,
                  components.values.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw invalid() }
        case "multi-select":
            guard case .array(let values) = field.value,
                  values.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw invalid() }
        case "boolean":
            guard case .bool = field.value else { throw invalid() }
        case "recovery-codes":
            guard case .array(let codes) = field.value else { throw invalid() }
            var ids: Set<String> = []
            for code in codes {
                guard case .object(let object) = code, case .string(let id) = object["id"], !id.isEmpty,
                      ids.insert(id).inserted, case .string = object["code"], case .bool = object["used"] else { throw invalid() }
            }
        default:
            guard case .string(let value) = field.value else { throw invalid() }
            if value.isEmpty { return }
            switch field.kind {
            case "number":
                guard value.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil else { throw invalid() }
            case "date":
                _ = try RevisionTimestamp.parse(value + "T00:00:00Z", path: "field.value:\(field.id)")
            case "year-month":
                _ = try RevisionTimestamp.parse(value + "-01T00:00:00Z", path: "field.value:\(field.id)")
            default: break
            }
        }
    }
}

public enum RevisionGraph {
    /// Returns every unreferenced head, including tombstones and branches descended from tombstones.
    /// Missing ancestors are explicit errors: callers must fetch them rather than infer a winner.
    public static func heads(in revisions: [VaultRevision]) throws -> [VaultRevision] {
        var byID: [UUID: VaultRevision] = [:]
        var orderedIDs: [UUID] = []
        for revision in revisions {
            try VaultPolicy.validateStructure(revision)
            if let existing = byID[revision.id] {
                guard existing == revision else { throw RevisionError.duplicateRevision(revision.id) }
            } else {
                byID[revision.id] = revision
                orderedIDs.append(revision.id)
            }
        }
        var referenced: Set<UUID> = []
        for revision in revisions {
            for parentID in revision.parentRevisionIds {
                guard let parent = byID[parentID] else { throw RevisionError.missingParent(revision: revision.id, parent: parentID) }
                guard parent.recordId == revision.recordId, parent.storageScope == revision.storageScope,
                      parent.unsupportedStorageScope == revision.unsupportedStorageScope else {
                    throw RevisionError.invalidParent(revision: revision.id, parent: parentID)
                }
                referenced.insert(parentID)
            }
        }
        // Iterative DFS avoids exhausting the call stack for long immutable histories.
        var completed: Set<UUID> = []
        var active: Set<UUID> = []
        for id in orderedIDs where !completed.contains(id) {
            var stack: [(UUID, Bool)] = [(id, false)]
            while let (current, exiting) = stack.popLast() {
                if exiting { active.remove(current); completed.insert(current); continue }
                if completed.contains(current) { continue }
                guard active.insert(current).inserted else { throw RevisionError.cycle(current) }
                stack.append((current, true))
                for parent in byID[current]!.parentRevisionIds.reversed() { stack.append((parent, false)) }
            }
        }
        return orderedIDs.filter { !referenced.contains($0) }.map { byID[$0]! }
    }
}
