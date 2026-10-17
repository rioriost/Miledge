import XCTest
@testable import MiledgeDomain

final class PersonalNameTests: XCTestCase {
    func testPhoneRegionDoesNotPreventRemovalAndStaysScopedToItsPhone() throws {
        let fields: [VaultField] = [
            .init(id: "phone", kind: "phone", value: .string("03-1234-5678")),
            .init(id: "phone-region:phone", value: .string("JP"), label: "Phone region")
        ]
        let revision = VaultRevision(templateId: "identity", title: "Synthetic", sections: [
            .init(id: "optional", fields: fields), .init(id: "custom", fields: fields)
        ])
        XCTAssertTrue(VaultEditor.canRemoveSection(in: revision, sectionID: "optional"))
        let removed = try VaultEditor.removingField(in: revision, sectionID: "optional", fieldID: "phone")
        XCTAssertTrue(removed.sections[0].fields.isEmpty)
        XCTAssertEqual(removed.sections[1].fields, fields)
        let orphan = VaultRevision(templateId: "identity", title: "Synthetic", sections: [.init(id: "optional", fields: [fields[1]])])
        XCTAssertTrue(try VaultEditor.removingField(in: orphan, sectionID: "optional", fieldID: fields[1].id).sections[0].fields.isEmpty)
    }
    func testLegacyNamesRemainExactWhenAddingOptionalComponents() throws {
        let original = VaultRevision(templateId: "identity", title: "Synthetic", sections: [
            .init(id: "identity", fields: [.init(id: "name", value: .string("  李 小龍  "))]),
            .init(id: "optional", fields: [.init(id: "givenName", value: .string("小龍")), .init(id: "familyName", value: .string("李"))])
        ])
        let edited = try VaultEditor.addingSection(id: "template:identity:name-details", to: original)
        XCTAssertEqual(Array(edited.sections.prefix(2)), original.sections)
        XCTAssertEqual(edited.sections.flatMap(\.fields).filter { $0.id == "givenName" }.count, 1)
        XCTAssertEqual(edited.sections.flatMap(\.fields).filter { $0.id == "familyName" }.count, 1)
        XCTAssertEqual(try VaultEditor.addingSection(id: "template:identity:name-details", to: edited), edited)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(edited)), edited)
        XCTAssertFalse(edited.isReadOnly)
    }

    func testNameFirstThenLegacyOptionalSectionDoesNotDuplicateNames() throws {
        var revision = VaultRevision(templateId: "identity", title: "Synthetic", sections: TemplateCatalog.template(id: "identity")!.sections)
        revision = try VaultEditor.addingSection(id: "template:identity:name-details", to: revision)
        revision = try VaultEditor.addingSection(id: "template:identity:optional", to: revision)
        XCTAssertEqual(revision.sections.flatMap(\.fields).filter { $0.id == "givenName" }.count, 1)
        XCTAssertEqual(revision.sections.flatMap(\.fields).filter { $0.id == "familyName" }.count, 1)
    }

    func testSingleAndMultiPartUnicodeNamesNeverRequireWesternStructure() throws {
        for name in ["Sukarno", "山田 太郎", "María del Carmen García López", "محمد بن عبد الله", "O’Connor-Smith", "  A  B  "] {
            var revision = VaultRevision(templateId: "passport", title: "Synthetic", sections: [
                .init(id: "passport", fields: [.init(id: "holder", value: .string(name))])
            ])
            revision = try VaultEditor.addingSection(id: "template:passport:name-details", to: revision)
            XCTAssertEqual(revision.sections[0].fields[0].value, .string(name))
            XCTAssertTrue(revision.sections[1].fields.allSatisfy { $0.value == .string("") })
            try VaultEditor.validateDraft(revision)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(revision)), revision)
        }
    }
}
