import Foundation

public enum VaultEditingError: Error, Equatable, Sendable {
    case missingSection(String)
    case missingField(String)
    case unavailableSection(String)
    case fieldKindConflict(section: String, field: String)
    case ambiguousProfile
    case deletedRevision
    case requiredField(String)
    case requiredSection(String)
}

public enum VaultSectionSource: Equatable, Sendable {
    case template
    case affiliateProfile(String)
    case apiCredentialProfile(String)
}

public struct VaultSectionOption: Identifiable, Sendable {
    public let id: String
    /// The complete definition; addition appends only missing fields and never replaces values.
    public let section: VaultSection
    public let source: VaultSectionSource
}

/// Validated value-draft edits. This does not persist revisions, generate credentials, or normalize input.
public enum VaultEditor {
    public static var supportedKinds: [String] { VaultPolicy.supportedFieldKinds.sorted() }

    public static func emptyValue(forKind kind: String) throws -> JSONValue {
        let value: JSONValue
        switch kind {
        case "address": value = .object([:])
        case "multi-select", "recovery-codes": value = .array([])
        case "boolean": value = .bool(false)
        default: value = .string("")
        }
        try validateField(VaultField(kind: kind, value: value))
        return value
    }

    public static func customField(
        kind: String, label: String, concealed: Bool? = nil, id: String = UUID().uuidString
    ) throws -> VaultField {
        let field = VaultField(id: id, kind: kind, value: try emptyValue(forKind: kind),
                               concealed: concealed ?? FieldPrivacy.concealedByDefault(id: id, kind: kind), label: label)
        try validateField(field)
        return field
    }

    public static func validateField(_ field: VaultField) throws {
        try VaultPolicy.validateForWrite(VaultRevision(
            title: "Field validation", createdAt: Date(timeIntervalSince1970: 0),
            sections: [VaultSection(id: "validation", fields: [field])]
        ))
    }

    /// Blank titles are permitted while drafting; all other write checks remain enforced.
    public static func validateDraft(_ revision: VaultRevision) throws {
        guard !revision.deleted else { throw VaultEditingError.deletedRevision }
        var validation = revision
        if validation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validation.title = "Draft validation"
        }
        try VaultPolicy.validateForWrite(validation)
    }

    public static func replacingValue(in field: VaultField, with value: JSONValue) throws -> VaultField {
        try validateField(field)
        var edited = field
        edited.value = value
        try validateField(edited)
        return edited
    }

    public static func replacingValue(
        in revision: VaultRevision, sectionID: String, fieldID: String, with value: JSONValue
    ) throws -> VaultRevision {
        try validateDraft(revision)
        guard let sectionIndex = revision.sections.firstIndex(where: { $0.id == sectionID }) else {
            throw VaultEditingError.missingSection(sectionID)
        }
        guard let fieldIndex = revision.sections[sectionIndex].fields.firstIndex(where: { $0.id == fieldID }) else {
            throw VaultEditingError.missingField(fieldID)
        }
        var edited = revision
        edited.sections[sectionIndex].fields[fieldIndex] = try replacingValue(
            in: edited.sections[sectionIndex].fields[fieldIndex], with: value
        )
        try validateDraft(edited)
        return edited
    }

    /// Missing template sections/fields and the selected profile's sections, in catalog order.
    public static func availableSections(for revision: VaultRevision) throws -> [VaultSectionOption] {
        try definitions(for: revision).filter { try !missingFields(for: $0.section, in: revision).isEmpty }
    }

    /// IDs come from availableSections. Repeating a completed addition is an unchanged no-op.
    public static func addingSection(id: String, to revision: VaultRevision) throws -> VaultRevision {
        guard let option = try definitions(for: revision).first(where: { $0.id == id }) else {
            throw VaultEditingError.unavailableSection(id)
        }
        let fields = try missingFields(for: option.section, in: revision)
        guard !fields.isEmpty else { return revision }
        var edited = revision
        if let index = edited.sections.firstIndex(where: { $0.id == option.section.id }) {
            edited.sections[index].fields.append(contentsOf: fields)
        } else {
            edited.sections.append(option.section)
        }
        try validateDraft(edited)
        return edited
    }

    public static func canRemoveField(in revision: VaultRevision, sectionID: String, fieldID: String) -> Bool {
        guard !revision.isReadOnly, !revision.deleted,
              let section = revision.sections.first(where: { $0.id == sectionID }),
              section.fields.contains(where: { $0.id == fieldID }) else { return false }
        if UUID(uuidString: fieldID) != nil || sectionID == "custom" || UUID(uuidString: sectionID) != nil { return true }
        return optionalDefinitions(for: revision).contains { $0.id == sectionID && $0.fields.contains { $0.id == fieldID } }
    }

    public static func canRemoveSection(in revision: VaultRevision, sectionID: String) -> Bool {
        guard let section = revision.sections.first(where: { $0.id == sectionID }), !section.fields.isEmpty else { return false }
        return section.fields.allSatisfy { canRemoveField(in: revision, sectionID: sectionID, fieldID: $0.id) }
    }

    /// Removal addresses an exact section/field pair, so matching names in other sections remain untouched.
    public static func removingField(in revision: VaultRevision, sectionID: String, fieldID: String) throws -> VaultRevision {
        try validateDraft(revision)
        guard canRemoveField(in: revision, sectionID: sectionID, fieldID: fieldID) else {
            throw VaultEditingError.requiredField(fieldID)
        }
        var edited = revision
        let index = edited.sections.firstIndex { $0.id == sectionID }!
        edited.sections[index].fields.removeAll { $0.id == fieldID }
        // Retain the section identity even when empty; addition can restore its catalog fields.
        try validateDraft(edited)
        return edited
    }

    public static func removingSection(in revision: VaultRevision, sectionID: String) throws -> VaultRevision {
        try validateDraft(revision)
        guard canRemoveSection(in: revision, sectionID: sectionID) else {
            throw VaultEditingError.requiredSection(sectionID)
        }
        var edited = revision
        edited.sections.removeAll { $0.id == sectionID }
        try validateDraft(edited)
        return edited
    }

    /// Called only after the creation UI explicitly confirms replacement of old catalog fields.
    /// Custom sections/UUID fields, identity, scope, title, organization, links and files are unchanged.
    public static func replacingTypeFields(in revision: VaultRevision, with replacement: VaultRevision) throws -> VaultRevision {
        try validateDraft(revision)
        try validateDraft(replacement)
        var edited = revision
        edited.templateId = replacement.templateId
        edited.templateVersion = replacement.templateVersion
        edited.sections = replacement.sections
        for original in revision.sections {
            var retained = original
            let customSection = original.id == "custom" || UUID(uuidString: original.id) != nil
            if !customSection {
                retained.fields = original.fields.filter { UUID(uuidString: $0.id) != nil }
            }
            guard customSection || !retained.fields.isEmpty else { continue }
            if let index = edited.sections.firstIndex(where: { $0.id == retained.id }) {
                // Catalog IDs and custom UUIDs cannot collide. Retain the original section ID.
                edited.sections[index].fields.append(contentsOf: retained.fields)
            } else {
                edited.sections.append(retained)
            }
        }
        try validateDraft(edited)
        return edited
    }

    private static func optionalDefinitions(for revision: VaultRevision) -> [VaultSection] {
        guard let template = TemplateCatalog.template(id: revision.templateId) else { return [] }
        var sections = template.optionalSections
        let profiles = revision.sections.flatMap(\.fields).compactMap { field -> String? in
            guard field.id == "profileId", case .string(let value) = field.value else { return nil }
            return value
        }
        for profileID in profiles {
            let profileSections: [VaultSection]
            if revision.templateId == "affiliate-account", let profile = TemplateCatalog.affiliateProfile(id: profileID) {
                profileSections = profile.sections + profile.optionalSections
            } else if revision.templateId == "api-credential", let profile = TemplateCatalog.apiCredentialProfiles.first(where: { $0.id == profileID }) {
                profileSections = profile.sections + profile.optionalSections
            } else { continue }
            sections += profileSections.map { section in
                var section = section
                section.id = "profile:\(profileID):\(section.id)"
                return section
            }
        }
        return sections
    }

    private static func definitions(for revision: VaultRevision) throws -> [VaultSectionOption] {
        try validateDraft(revision)
        let template = TemplateCatalog.template(id: revision.templateId)!
        var options = (template.sections + template.optionalSections).map {
            VaultSectionOption(id: "template:\(template.id):\($0.id)", section: $0, source: .template)
        }
        guard ["affiliate-account", "api-credential"].contains(revision.templateId) else { return options }
        let profileIDs = Set(revision.sections.flatMap(\.fields).filter { $0.id == "profileId" }.compactMap { field -> String? in
            guard case .string(let id) = field.value, !id.isEmpty else { return nil }
            return id
        })
        guard profileIDs.count <= 1 else { throw VaultEditingError.ambiguousProfile }
        guard let id = profileIDs.first else { return options }
        let sections: [VaultSection]
        let source: VaultSectionSource
        if revision.templateId == "affiliate-account" {
            let profile = TemplateCatalog.affiliateProfile(id: id)!
            sections = profile.sections + profile.optionalSections
            source = .affiliateProfile(id)
        } else {
            let profile = TemplateCatalog.apiCredentialProfiles.first { $0.id == id }!
            sections = profile.sections + profile.optionalSections
            source = .apiCredentialProfile(id)
        }
        for var section in sections {
            // Provider-specific sections must not reuse another scheme's existing credentials.
            section.id = "profile:\(id):\(section.id)"
            options.append(VaultSectionOption(id: section.id, section: section, source: source))
        }
        return options
    }

    private static func missingFields(for definition: VaultSection, in revision: VaultRevision) throws -> [VaultField] {
        guard let existing = revision.sections.first(where: { $0.id == definition.id }) else { return definition.fields }
        for field in definition.fields {
            if let previous = existing.fields.first(where: { $0.id == field.id }), previous.kind != field.kind {
                throw VaultEditingError.fieldKindConflict(section: definition.id, field: field.id)
            }
        }
        return definition.fields.filter { field in !existing.fields.contains(where: { $0.id == field.id }) }
    }
}
