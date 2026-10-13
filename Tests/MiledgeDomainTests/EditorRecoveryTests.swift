import Foundation
import XCTest
@testable import MiledgeDomain

final class EditorRecoveryTests: XCTestCase {
    private func card() throws -> VaultRevision {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        return VaultRevision(templateId: template.id, title: " Synthetic \n", sections: template.sections)
    }

    func testCustomRemovalUsesExactIdentityAndPreservesOtherEdits() throws {
        var draft = try card()
        draft.sections[0].fields[0].value = .string("  Synthetic Name\n")
        let id = UUID().uuidString
        let other = try VaultEditor.customField(kind: "number", label: "Duplicate label")
        draft.sections.append(.init(id: id, fields: [
            try VaultEditor.customField(kind: "string", label: "Duplicate label"), other
        ]))
        let customIndex = draft.sections.count - 1
        draft.sections[customIndex].fields[1].value = .string("-999999999999999999999.00010")
        let before = draft
        let removed = try VaultEditor.removingField(in: draft, sectionID: id, fieldID: draft.sections[customIndex].fields[0].id)
        XCTAssertEqual(removed.sections[0], before.sections[0])
        XCTAssertEqual(removed.sections[customIndex].fields, [before.sections[customIndex].fields[1]])
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(removed)), removed)
        XCTAssertEqual(before.sections[customIndex].fields.count, 2)
    }

    func testOptionalSectionCanBeRemovedAndReaddedWithoutLosingMainFields() throws {
        let original = try card()
        let option = try XCTUnwrap(VaultEditor.availableSections(for: original).first { $0.section.id == "optional" })
        let added = try VaultEditor.addingSection(id: option.id, to: original)
        XCTAssertTrue(VaultEditor.canRemoveSection(in: added, sectionID: "optional"))
        let removed = try VaultEditor.removingSection(in: added, sectionID: "optional")
        XCTAssertEqual(removed, original)
        XCTAssertTrue(try VaultEditor.availableSections(for: removed).contains { $0.id == option.id })
        XCTAssertFalse(VaultEditor.canRemoveField(in: original, sectionID: "card", fieldID: "cardNumber"))
        XCTAssertThrowsError(try VaultEditor.removingField(in: original, sectionID: "card", fieldID: "cardNumber"))
    }

    func testUnknownReadOnlyDataCannotBeRemovedToMakeItWritable() throws {
        var draft = try card()
        let sectionID = UUID().uuidString
        draft.sections.append(.init(id: sectionID, fields: [try VaultEditor.customField(kind: "string", label: "Unknown")]))
        draft.sections[draft.sections.count - 1].unknownProperties["future"] = .string("do not drop")
        let before = try RevisionCodec.encode(draft)
        XCTAssertFalse(VaultEditor.canRemoveSection(in: draft, sectionID: sectionID))
        XCTAssertThrowsError(try VaultEditor.removingSection(in: draft, sectionID: sectionID))
        XCTAssertEqual(try RevisionCodec.encode(draft), before)
    }

    func testConfirmedTypeReplacementOnlyReplacesTypeFields() throws {
        var original = try card()
        original.tags = ["  literal tag  "]
        original.favorite = true
        original.linkedRecordIds = [UUID()]
        original.sections[0].fields[0].value = .string("explicitly discarded")
        let template = try XCTUnwrap(TemplateCatalog.template(id: "bank-account"))
        let replacement = VaultRevision(templateId: template.id, sections: template.sections)
        let changed = try VaultEditor.replacingTypeFields(in: original, with: replacement)
        XCTAssertEqual(changed.recordId, original.recordId)
        XCTAssertEqual(changed.revisionId, original.revisionId)
        XCTAssertEqual(changed.title, original.title)
        XCTAssertEqual(changed.tags, original.tags)
        XCTAssertEqual(changed.favorite, original.favorite)
        XCTAssertEqual(changed.linkedRecordIds, original.linkedRecordIds)
        XCTAssertEqual(changed.storageScope, .deviceLocal)
        XCTAssertEqual(changed.sections, replacement.sections)
        XCTAssertEqual(original.sections[0].fields[0].value, .string("explicitly discarded"))
    }
    func testTypeReplacementPreservesCustomSectionsAndUUIDFieldsInsideCatalogSections() throws {
        var original = try card()
        let inline = VaultField(kind: "number", value: .string("-999999999999.00010"), concealed: true, label: "  Literal\n")
        original.sections[0].fields.append(inline)
        let custom = VaultSection(id: UUID().uuidString, fields: [
            VaultField(kind: "multiline", value: .string("  user text\n"), concealed: true, label: "My label")
        ])
        let legacyCustom = VaultSection(id: "custom", fields: [
            VaultField(id: "legacy-user-field", value: .string("verbatim"), label: "User field")
        ])
        original.sections += [custom, legacyCustom]
        let template = try XCTUnwrap(TemplateCatalog.template(id: "custom-item"))
        let replacement = VaultRevision(templateId: template.id, sections: template.sections)
        let changed = try VaultEditor.replacingTypeFields(in: original, with: replacement)
        XCTAssertEqual(changed.sections.first { $0.id == custom.id }, custom)
        XCTAssertEqual(changed.sections.first { $0.id == "card" }?.fields, [inline])
        XCTAssertEqual(changed.sections.first { $0.id == "custom" }?.fields, legacyCustom.fields)
        XCTAssertEqual(changed.sections.flatMap(\.fields).filter { UUID(uuidString: $0.id) != nil }.count, 2)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(changed)), changed)
        XCTAssertTrue(original.sections[0].fields.contains { $0.id == "cardNumber" })
    }

}
