import Foundation
import MiledgeDomain
import XCTest
@testable import MiledgeApp

final class EditorTypeChangeStateTests: XCTestCase {
    func testChangingTypeRetainsCustomInputIdentityAndInvalidStateOnly() throws {
        let card = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        let bank = try XCTUnwrap(TemplateCatalog.template(id: "bank-account"))
        var original = VaultRevision(templateId: card.id, sections: card.sections)
        let custom = VaultField(kind: "number", value: .string("-5.000"), label: "Custom decimal")
        let section = VaultSection(id: UUID().uuidString, fields: [custom])
        original.sections.append(section)
        let retained = EditorFieldID(section: section.id, field: custom.id)
        let discarded = EditorFieldID(section: "card", field: "expiry")
        let stale = EditorFieldID(section: "removed", field: UUID().uuidString)
        let before = UUID()
        let after = UUID()

        // A temporarily invalid custom text buffer is outside VaultRevision. Its last
        // valid value, view identity and invalid marker must all survive the switch.
        let changed = try VaultEditor.replacingTypeFields(
            in: original, with: VaultRevision(templateId: bank.id, sections: bank.sections)
        )
        let retainedSection = try XCTUnwrap(changed.sections.first { $0.id == section.id })
        XCTAssertEqual(retainedSection.fields, [custom])
        XCTAssertEqual(
            EditorTypeChangeState.identity(for: custom, in: section, generation: before),
            EditorTypeChangeState.identity(for: custom, in: retainedSection, generation: after)
        )
        XCTAssertEqual(
            EditorTypeChangeState.retainedInvalidFields([retained, discarded, stale], in: changed), [retained]
        )
        let oldCatalogField = try XCTUnwrap(original.sections.first?.fields.first)
        XCTAssertNotEqual(
            EditorTypeChangeState.identity(for: oldCatalogField, in: original.sections[0], generation: before),
            EditorTypeChangeState.identity(for: oldCatalogField, in: original.sections[0], generation: after)
        )
    }

    func testUUIDFieldWithinCatalogSectionAndLegacyCustomSectionKeepTheirState() throws {
        let uuidField = VaultField(kind: "date", value: .string("2032-02-29"), label: "Custom date")
        let legacy = VaultField(id: "legacy", kind: "number", value: .string("-0.0010"), label: "Legacy number")
        let sections = [VaultSection(id: "card", fields: [uuidField]), VaultSection(id: "custom", fields: [legacy])]
        let revision = VaultRevision(sections: sections)
        var invalid = Set<EditorFieldID>()
        for section in sections {
            let field = try XCTUnwrap(section.fields.first)
            let id = EditorFieldID(section: section.id, field: field.id)
            invalid.insert(id)
            XCTAssertEqual(
                EditorTypeChangeState.identity(for: field, in: section, generation: UUID()),
                EditorTypeChangeState.identity(for: field, in: section, generation: UUID())
            )
        }
        XCTAssertEqual(EditorTypeChangeState.retainedInvalidFields(invalid, in: revision), invalid)
    }
    func testPartialAPIProfileRemainsEditableUntilCorrectedButCannotSave() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "api-credential"))
        var revision = VaultRevision(templateId: template.id, title: "Synthetic API", sections: template.sections)
        let option = try XCTUnwrap(VaultEditor.availableSections(for: revision).first { $0.section.id == "optional" })
        revision = try VaultEditor.addingSection(id: option.id, to: revision)
        let section = try XCTUnwrap(revision.sections.firstIndex { $0.id == "optional" })
        let field = try XCTUnwrap(revision.sections[section].fields.firstIndex { $0.id == "profileId" })
        let access = EditorInitialAccess(revision: revision)
        XCTAssertFalse(access.readOnly)
        for partial in ["i", "id-", "id-secret-"] {
            revision.sections[section].fields[field] = try VaultEditor.replacingValue(
                in: revision.sections[section].fields[field], with: .string(partial)
            )
            XCTAssertFalse(access.readOnly)
            XCTAssertThrowsError(try VaultEditor.validateDraft(revision))
        }
        revision.sections[section].fields[field] = try VaultEditor.replacingValue(
            in: revision.sections[section].fields[field], with: .string("id-secret-pair")
        )
        XCTAssertFalse(access.readOnly)
        XCTAssertNoThrow(try VaultEditor.validateDraft(revision))
        XCTAssertEqual(revision.sections[section].fields[field].value, .string("id-secret-pair"))
    }

    func testInitiallyUnknownOrDeletedRecordsRemainReadOnly() throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "api-credential"))
        var unknown = VaultRevision(templateId: template.id, title: "Unknown", sections: template.sections)
        unknown.unknownProperties["future"] = .string("preserve")
        let snapshot = try RevisionCodec.encode(unknown)
        XCTAssertTrue(EditorInitialAccess(revision: unknown).readOnly)
        XCTAssertThrowsError(try VaultEditor.validateDraft(unknown))
        XCTAssertEqual(try RevisionCodec.encode(unknown), snapshot)
        var deleted = VaultRevision(title: "Deleted")
        deleted.deleted = true
        XCTAssertTrue(EditorInitialAccess(revision: deleted).readOnly)
    }

    func testUnvalidatedDraftNeverMutatesBaselineAndSaveRejectsIncompleteValue() throws {
        let field = VaultField(id: "amount", kind: "number", value: .string("1.000"), concealed: false)
        let original = VaultRevision(templateId: "custom-item", title: "Synthetic", sections: [
            VaultSection(id: "custom", fields: [field])
        ])
        let id = EditorFieldID(section: "custom", field: field.id)
        let draft = EditorDraftValues()
        for text in ["-", "１２３\r\ninvalid-number\n", "invalid"] {
            draft.set(.string(text), for: id)
            XCTAssertEqual(draft.value(for: id, fallback: field.value), .string(text))
            XCTAssertEqual(original.sections[0].fields[0].value, .string("1.000"))
            XCTAssertThrowsError(try VaultPolicy.validateForWrite(draft.applying(to: original)))
        }
        let exact = "-9007199254740993.00000100"
        draft.set(.string(exact), for: id)
        let saved = draft.applying(to: original)
        XCTAssertNoThrow(try VaultPolicy.validateForWrite(saved))
        XCTAssertEqual(saved.sections[0].fields[0].value, .string(exact))
    }

    func testRawCustomDraftSurvivesTypeChangeAndRemovedValuesStayRemoved() throws {
        let card = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        let bank = try XCTUnwrap(TemplateCatalog.template(id: "bank-account"))
        var original = VaultRevision(templateId: card.id, title: "Synthetic", sections: card.sections)
        let field = VaultField(kind: "number", value: .string(""), label: "Custom decimal")
        let custom = VaultSection(id: UUID().uuidString, fields: [field])
        original.sections.append(custom)
        let customID = EditorFieldID(section: custom.id, field: field.id)
        let catalog = try XCTUnwrap(original.sections.first)
        let catalogField = try XCTUnwrap(catalog.fields.first)
        let catalogID = EditorFieldID(section: catalog.id, field: catalogField.id)
        let draft = EditorDraftValues()
        draft.set(.string("-"), for: customID)
        draft.set(.string("incomplete"), for: catalogID)
        let changed = try VaultEditor.replacingTypeFields(
            in: original, with: VaultRevision(templateId: bank.id, sections: bank.sections)
        )
        draft.retainFields(in: changed, customOnly: true)
        XCTAssertEqual(draft.applying(to: changed).sections.last?.fields.first?.value, .string("-"))
        XCTAssertEqual(draft.value(for: catalogID, fallback: .null), .null)
        let removed = try VaultEditor.removingSection(in: changed, sectionID: custom.id)
        draft.retainFields(in: removed)
        XCTAssertEqual(draft.value(for: customID, fallback: .null), .null)
        XCTAssertFalse(draft.applying(to: removed).sections.contains { $0.id == custom.id })
    }

}
