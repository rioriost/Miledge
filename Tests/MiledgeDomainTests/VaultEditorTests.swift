import Foundation
import XCTest
@testable import MiledgeDomain

final class VaultEditorTests: XCTestCase {
    private func draft(template: ItemTemplate? = nil, title: String = "") -> VaultRevision {
        VaultRevision(
            templateId: template?.id ?? "custom-item", title: title, createdAt: Date(timeIntervalSince1970: 0),
            sections: template?.sections ?? []
        )
    }

    func testEveryKindHasValidEmptyValueAndCustomField() throws {
        XCTAssertEqual(Set(VaultEditor.supportedKinds), VaultPolicy.supportedFieldKinds)
        XCTAssertEqual(VaultEditor.supportedKinds, VaultEditor.supportedKinds.sorted())
        for kind in VaultEditor.supportedKinds {
            let value = try VaultEditor.emptyValue(forKind: kind)
            switch kind {
            case "address": XCTAssertEqual(value, .object([:]))
            case "multi-select", "recovery-codes": XCTAssertEqual(value, .array([]))
            case "boolean": XCTAssertEqual(value, .bool(false))
            default: XCTAssertEqual(value, .string(""))
            }
            let field = try VaultEditor.customField(kind: kind, label: " Synthetic \n")
            XCTAssertNotNil(UUID(uuidString: field.id))
            XCTAssertEqual(field.label, " Synthetic \n")
            XCTAssertEqual(field.value, value)
            XCTAssertEqual(field.concealed, ["concealed", "otp-seed", "key-material", "recovery-codes"].contains(kind))
            try VaultEditor.validateField(field)
            let explicit = try VaultEditor.customField(kind: kind, label: "Label", concealed: false, id: "stable")
            XCTAssertEqual(explicit.id, "stable")
            XCTAssertFalse(explicit.concealed)
        }
        for kind in ["future-kind", "text", "medical-record", " Health_Record "] {
            XCTAssertThrowsError(try VaultEditor.emptyValue(forKind: kind))
            XCTAssertThrowsError(try VaultEditor.customField(kind: kind, label: "Synthetic"))
        }
        XCTAssertThrowsError(try VaultEditor.customField(kind: "string", label: "Synthetic", id: ""))
        XCTAssertThrowsError(try VaultEditor.customField(kind: "string", label: "Synthetic", id: "diagnosis"))
    }

    func testEveryKindAcceptsItsExactTypedShapeWithoutNormalization() throws {
        let text = "  000-ÄaZ\u{202E}\n秘密\n"
        let codes: JSONValue = .array([
            .object(["id": .string("code-b"), "code": .string(text), "used": .bool(true)]),
            .object(["id": .string("code-a"), "code": .string("0001"), "used": .bool(false)])
        ])
        let specialized: [String: JSONValue] = [
            "address": .object(["freeform": .string(text), "unrecognizedComponent": .string("00100")]),
            "multi-select": .array([.string("stable-b"), .string("stable-a"), .string("stable-b")]),
            "boolean": .bool(true), "recovery-codes": codes,
            "number": .string("-123456789012345678901234567890.000100"),
            "date": .string("2024-02-29"), "year-month": .string("2026-10")
        ]
        for kind in VaultEditor.supportedKinds {
            let original = try VaultEditor.customField(kind: kind, label: "Synthetic")
            let value = specialized[kind] ?? .string(text)
            let changed = try VaultEditor.replacingValue(in: original, with: value)
            XCTAssertEqual(changed.value, value)
            XCTAssertEqual(changed.id, original.id)
            XCTAssertEqual(changed.kind, original.kind)
            XCTAssertEqual(changed.label, original.label)
            XCTAssertEqual(changed.concealed, original.concealed)
            XCTAssertEqual(original.value, try VaultEditor.emptyValue(forKind: kind))
            var revision = draft()
            revision.sections = [.init(id: "custom", fields: [changed])]
            try VaultEditor.validateDraft(revision)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(revision)), revision)
        }
    }

    func testWholeFieldValidationRejectsMalformedValuesHealthAndUnknownData() throws {
        let invalid: [(String, JSONValue)] = [
            ("string", .number("0001")), ("concealed", .null), ("url", .object([:])),
            ("address", .object(["postalCode": .number("123")])), ("address", .string("free-form")),
            ("multi-select", .string("a,b")), ("multi-select", .array([.bool(true)])),
            ("boolean", .string("false")), ("recovery-codes", .array([.string("code")])),
            ("recovery-codes", .array([.object(["id": .string(""), "code": .string("0001"), "used": .bool(false)])])),
            ("recovery-codes", .array([.object(["id": .string("a"), "code": .string("0001"), "used": .bool(false), "future": .null])])),
            ("number", .string("1e3")), ("number", .string(" 1.00 ")),
            ("date", .string("2023-02-29")), ("date", .string("2026-10-10T00:00:00Z")),
            ("year-month", .string("2026-13")), ("year-month", .string("2026-1"))
        ]
        for (kind, value) in invalid {
            let original = try VaultEditor.customField(kind: kind, label: "Synthetic")
            XCTAssertThrowsError(try VaultEditor.replacingValue(in: original, with: value), kind)
            XCTAssertEqual(original.value, try VaultEditor.emptyValue(forKind: kind))
            XCTAssertThrowsError(try VaultEditor.validateField(.init(kind: kind, value: value)), kind)
        }
        let duplicateCode: JSONValue = .object(["id": .string("a"), "code": .string("0001"), "used": .bool(false)])
        XCTAssertThrowsError(try VaultEditor.validateField(.init(kind: "recovery-codes", value: .array([duplicateCode, duplicateCode]))))
        for field in [
            VaultField(kind: "future-kind", value: .number("1e999")),
            VaultField(id: "diagnosis"), VaultField(id: "policyType", value: .string("medical-insurance")),
            VaultField(unknownProperties: ["future": .number("1e999")])
        ] {
            let original = field
            XCTAssertThrowsError(try VaultEditor.validateField(field))
            XCTAssertThrowsError(try VaultEditor.replacingValue(in: field, with: .string("replacement")))
            XCTAssertEqual(original, field)
        }
    }

    func testDraftValidationPermitsBlankTitleButNeverChangesOrSavesIt() throws {
        for title in ["", " \n\t", "  Synthetic \n"] {
            let value = draft(title: title)
            try VaultEditor.validateDraft(value)
            XCTAssertEqual(value.title, title)
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertThrowsError(try VaultPolicy.validateForWrite(value))
            } else { try VaultPolicy.validateForWrite(value) }
        }
        var tombstone = draft()
        tombstone.deleted = true
        XCTAssertThrowsError(try VaultEditor.validateDraft(tombstone)) {
            XCTAssertEqual($0 as? VaultEditingError, .deletedRevision)
        }
    }

    func testRevisionEditsUseBothStableIDsPreserveAllMetadataAndAreAtomic() throws {
        let first = try VaultEditor.customField(kind: "concealed", label: "First", id: "f")
        let second = try VaultEditor.customField(kind: "concealed", label: "Second", id: "f")
        var value = draft(title: "Synthetic")
        value.sections = [.init(id: "first", fields: [first]), .init(id: "second", fields: [second])]
        value.favorite = true
        value.tags = ["日本語", "العربية"]
        value.parentRevisionIds = [UUID()]
        value.linkedRecordIds = [UUID()]
        value.attachments = [.object(["formatVersion": .number("1"), "algorithm": .string("AES-GCM")])]
        let secret: JSONValue = .string("  MiXeD \n0001\u{202E}")
        let edited = try VaultEditor.replacingValue(in: value, sectionID: "second", fieldID: "f", with: secret)
        var expected = value
        expected.sections[1].fields[0].value = secret
        XCTAssertEqual(edited, expected)
        XCTAssertEqual(value.sections[1].fields[0].value, .string(""))
        XCTAssertThrowsError(try VaultEditor.replacingValue(in: value, sectionID: "missing", fieldID: "f", with: secret)) {
            XCTAssertEqual($0 as? VaultEditingError, .missingSection("missing"))
        }
        XCTAssertThrowsError(try VaultEditor.replacingValue(in: value, sectionID: "second", fieldID: "missing", with: secret)) {
            XCTAssertEqual($0 as? VaultEditingError, .missingField("missing"))
        }
        XCTAssertThrowsError(try VaultEditor.replacingValue(in: value, sectionID: "second", fieldID: "f", with: .array([])))
        XCTAssertEqual(value.sections[1].fields[0], second)
    }

    func testAllThirtyTemplatesAndCustomAddActualOptionalSectionsInOrderIdempotently() throws {
        for template in TemplateCatalog.all {
            var value = draft(template: template)
            let originalSections = value.sections
            let eligible = try VaultEditor.availableSections(for: value)
            XCTAssertEqual(eligible.map(\.section.id), template.optionalSections.map(\.id), template.id)
            XCTAssertTrue(eligible.allSatisfy { $0.source == .template })
            for option in eligible {
                value = try VaultEditor.addingSection(id: option.id, to: value)
                let again = try VaultEditor.addingSection(id: option.id, to: value)
                XCTAssertEqual(again, value)
                XCTAssertEqual(value.sections.filter { $0.id == option.section.id }.count, 1)
            }
            var expectedOptional = template.optionalSections
            if template.id == "identity", let names = expectedOptional.firstIndex(where: { $0.id == "name-details" }) {
                expectedOptional[names].fields.removeAll { ["givenName", "familyName"].contains($0.id) }
            }
            XCTAssertEqual(value.sections, originalSections + expectedOptional)
            XCTAssertTrue(try VaultEditor.availableSections(for: value).isEmpty)
            try VaultEditor.validateDraft(value)
            value.title = "Synthetic"
            try VaultPolicy.validateForWrite(value)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
            XCTAssertThrowsError(try VaultEditor.addingSection(id: "template:other:optional", to: value))
        }
    }

    func testMissingCoreFieldsAreAppendedWithoutOverwritingValuesLabelsOrOrder() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        var value = draft(template: template)
        let kept = VaultField(id: "pin", kind: "concealed", value: .string("  0000\n"), concealed: false, label: "My PIN")
        let custom = VaultField(id: "user-field", value: .string("preserved"))
        value.sections.append(.init(id: "optional", fields: [custom, kept]))
        value.sections[0].fields.removeLast()
        value.sections[0].fields[0].value = .string("原文")
        let original = value
        let options = try VaultEditor.availableSections(for: value)
        XCTAssertEqual(options.map(\.section.id), ["card", "optional", "name-details", "original-notation"])
        for option in options { value = try VaultEditor.addingSection(id: option.id, to: value) }
        XCTAssertEqual(value.sections[0].fields[0], original.sections[0].fields[0])
        let optional = try XCTUnwrap(value.sections.first { $0.id == "optional" })
        XCTAssertEqual(Array(optional.fields.prefix(2)), [custom, kept])
        XCTAssertEqual(optional.fields.map(\.id), ["user-field", "pin", "issuer", "billingAddress"])
        XCTAssertEqual(value.sections.prefix(original.sections.count).map(\.id), original.sections.map(\.id))
        XCTAssertEqual(original.sections[0].fields.count + 1, value.sections[0].fields.count)
    }

    func testEmptyDraftOffersMissingTemplateSectionsWithoutCreatingEmptyCustomSection() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "bank-account"))
        var value = draft(template: template)
        value.sections = []
        XCTAssertEqual(try VaultEditor.availableSections(for: value).map(\.section.id),
                       (template.sections + template.optionalSections).map(\.id))
        for option in try VaultEditor.availableSections(for: value) {
            value = try VaultEditor.addingSection(id: option.id, to: value)
        }
        XCTAssertEqual(value.sections, template.sections + template.optionalSections)
        let custom = draft()
        XCTAssertFalse(try VaultEditor.availableSections(for: custom).contains { $0.section.id == "custom" })
        XCTAssertEqual(try VaultEditor.addingSection(id: "template:custom-item:custom", to: custom), custom)
    }

    func testIncompatibleExistingFieldsAndDuplicateSectionFieldIDsAreExplicitErrors() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        var value = draft(template: template)
        value.sections.append(.init(id: "optional", fields: [.init(id: "pin", kind: "string", value: .string("0001"))]))
        let original = value
        XCTAssertThrowsError(try VaultEditor.availableSections(for: value)) {
            XCTAssertEqual($0 as? VaultEditingError, .fieldKindConflict(section: "optional", field: "pin"))
        }
        XCTAssertThrowsError(try VaultEditor.addingSection(id: "template:credit-card:optional", to: value))
        XCTAssertEqual(value, original)
        value = draft(template: template)
        value.sections.append(value.sections[0])
        XCTAssertThrowsError(try VaultEditor.availableSections(for: value))
        value = draft(template: template)
        value.sections[0].fields.append(value.sections[0].fields[0])
        XCTAssertThrowsError(try VaultEditor.addingSection(id: "template:credit-card:optional", to: value))
    }

    func testEveryAffiliateProfileAddsActualCoreOptionalFieldsAndPreservesPreviousCredentials() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        for profile in TemplateCatalog.affiliateProfiles {
            var value = draft(template: template)
            let profileIndex = try XCTUnwrap(value.sections[0].fields.firstIndex { $0.id == "profileId" })
            value.sections[0].fields[profileIndex].value = .string(profile.id)
            let previous = VaultSection(id: "credentials", fields: [
                .init(id: "credentialId", value: .string("old-0001")),
                .init(id: "credentialSecret", kind: "concealed", value: .string("  OLD\n"))
            ])
            value.sections.append(previous)
            let profileOptions = try VaultEditor.availableSections(for: value).filter { $0.source == .affiliateProfile(profile.id) }
            XCTAssertEqual(profileOptions.count, profile.sections.count + profile.optionalSections.count)
            XCTAssertEqual(profileOptions.map(\.section.fields), (profile.sections + profile.optionalSections).map(\.fields))
            for option in profileOptions {
                XCTAssertEqual(option.id, option.section.id)
                XCTAssertTrue(option.id.hasPrefix("profile:\(profile.id):"))
                value = try VaultEditor.addingSection(id: option.id, to: value)
                XCTAssertEqual(try VaultEditor.addingSection(id: option.id, to: value), value)
            }
            XCTAssertEqual(value.sections.first { $0.id == previous.id }, previous)
            XCTAssertFalse(try VaultEditor.availableSections(for: value).contains { $0.source == .affiliateProfile(profile.id) })
            if profile.id == "rakuten-webservice-jp" {
                XCTAssertEqual(value.sections.last?.fields.map(\.id), ["affiliateId"])
            }
            if profile.id == "affiliate-generic" {
                XCTAssertEqual(value.sections.last?.fields.map(\.id), ["token", "credentialId", "credentialSecret"])
            }
            try VaultEditor.validateDraft(value)
        }
    }

    func testAPIProfilesAreSelectedExplicitlyAndDoNotOverwriteTemplateCredentials() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "api-credential"))
        for profile in TemplateCatalog.apiCredentialProfiles {
            var value = draft(template: template)
            value.sections[0].fields[1].value = .string("  OLD\n")
            let original = value.sections[0]
            let optional = try XCTUnwrap(VaultEditor.availableSections(for: value).first { $0.section.id == "optional" })
            value = try VaultEditor.addingSection(id: optional.id, to: value)
            value = try VaultEditor.replacingValue(in: value, sectionID: "optional", fieldID: "profileId", with: .string(profile.id))
            let options = try VaultEditor.availableSections(for: value).filter { $0.source == .apiCredentialProfile(profile.id) }
            XCTAssertEqual(options.map(\.section.fields), (profile.sections + profile.optionalSections).map(\.fields))
            for option in options { value = try VaultEditor.addingSection(id: option.id, to: value) }
            XCTAssertEqual(value.sections[0], original)
            XCTAssertTrue(try VaultEditor.availableSections(for: value).allSatisfy { $0.source == .template })
        }
    }

    func testProfileChangesRejectStaleOptionsAndNeverReuseOtherProvidersFields() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        var value = draft(template: template)
        let profileIndex = try XCTUnwrap(value.sections[0].fields.firstIndex { $0.id == "profileId" })
        XCTAssertTrue(try VaultEditor.availableSections(for: value).allSatisfy { $0.source == .template })
        value.sections[0].fields[profileIndex].value = .string("amazon-paapi-5")
        let oldOption = try XCTUnwrap(VaultEditor.availableSections(for: value).first { $0.source == .affiliateProfile("amazon-paapi-5") })
        value = try VaultEditor.addingSection(id: oldOption.id, to: value)
        value = try VaultEditor.replacingValue(in: value, sectionID: oldOption.section.id, fieldID: "secretAccessKey", with: .string("  OLD\n"))
        let oldSection = try XCTUnwrap(value.sections.first { $0.id == oldOption.section.id })
        value.sections[0].fields[profileIndex].value = .string("amazon-creators-api")
        XCTAssertThrowsError(try VaultEditor.addingSection(id: oldOption.id, to: value)) {
            XCTAssertEqual($0 as? VaultEditingError, .unavailableSection(oldOption.id))
        }
        let newOption = try XCTUnwrap(VaultEditor.availableSections(for: value).first { $0.source == .affiliateProfile("amazon-creators-api") })
        value = try VaultEditor.addingSection(id: newOption.id, to: value)
        XCTAssertEqual(value.sections.first { $0.id == oldSection.id }, oldSection)
        XCTAssertEqual(value.sections.first { $0.id == newOption.section.id }?.fields.first { $0.id == "credentialSecret" }?.value, .string(""))
        value.sections.append(.init(id: "another-program", fields: [.init(id: "profileId", value: .string("rakuten-webservice-jp"))]))
        XCTAssertThrowsError(try VaultEditor.availableSections(for: value)) {
            XCTAssertEqual($0 as? VaultEditingError, .ambiguousProfile)
        }
    }

    func testWholeReadOnlyRevisionsRejectAllEditorMutationsAndRetainUnknowns() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        let valid = draft(template: template)
        var variants: [VaultRevision] = []
        var value = valid
        value.schemaVersion = 2
        variants.append(value)
        value = valid
        value.templateVersion = 2
        variants.append(value)
        value = valid
        value.templateId = "future-non-health"
        variants.append(value)
        value = valid
        value.unknownProperties["future"] = .number("1e999")
        variants.append(value)
        value = valid
        value.sections[0].unknownProperties["future"] = .null
        variants.append(value)
        value = valid
        value.sections[0].fields[0].unknownProperties["future"] = .number("1e999")
        variants.append(value)
        value = valid
        value.sections[0].fields[0].kind = "future-kind"
        variants.append(value)
        value = valid
        value.sections[0].fields[0].value = .object(["future": .number("1e999")])
        variants.append(value)
        value = valid
        value.templateId = "medical-record"
        variants.append(value)
        value = valid
        value.deleted = true
        variants.append(value)
        value = valid
        value.attachments = [.object(["formatVersion": .number("2")])]
        variants.append(value)
        var object = try JSONObject(valid.json, path: "revision").values
        object["storageScope"] = .string("future-scope")
        variants.append(try RevisionCodec.decode(LosslessJSON.encode(.object(object))))
        for original in variants {
            XCTAssertThrowsError(try VaultEditor.validateDraft(original))
            XCTAssertThrowsError(try VaultEditor.availableSections(for: original))
            XCTAssertThrowsError(try VaultEditor.addingSection(id: "template:credit-card:optional", to: original))
            XCTAssertThrowsError(try VaultEditor.replacingValue(in: original, sectionID: "card", fieldID: "cardholder", with: .string("new")))
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(original)), original)
        }
        var affiliate = draft(template: try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account")))
        let affiliateProfileIndex = try XCTUnwrap(affiliate.sections[0].fields.firstIndex { $0.id == "profileId" })
        affiliate.sections[0].fields[affiliateProfileIndex].value = .string("future-profile")
        XCTAssertThrowsError(try VaultEditor.availableSections(for: affiliate))
        value = valid
        let monthIndex = try XCTUnwrap(value.sections[0].fields.firstIndex { $0.kind == "year-month" })
        value.sections[0].fields[monthIndex].value = .string("2026-13")
        XCTAssertThrowsError(try VaultEditor.availableSections(for: value))
    }
}
