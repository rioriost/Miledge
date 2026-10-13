import MiledgeApplication
import MiledgeDomain
import SwiftUI
import XCTest
@testable import MiledgeApp

@MainActor
final class LedgerBrowserTests: XCTestCase {
    func testCategoriesCoverEveryTemplateAndDoNotInventPasswordFeatures() {
        let groups = [LedgerCategory.credentials, .finances, .records]
        let ids = groups.flatMap { $0.templates.map(\.id) }
        XCTAssertEqual(Set(ids), Set(TemplateCatalog.all.map(\.id)))
        XCTAssertEqual(ids.count, TemplateCatalog.all.count)
        for category in LedgerCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
            XCTAssertFalse(category.symbol.isEmpty)
            XCTAssertNotEqual(category.title, LocalizedStringKey(""))
            _ = category.color
            XCTAssertFalse(category.templates.isEmpty)
        }
        XCTAssertEqual(LedgerCategory.group(for: "future-type"), .records)
        for category in [LedgerCategory.all, .favorites, .conflicts] {
            XCTAssertEqual(category.templates.map(\.id), TemplateCatalog.all.map(\.id))
        }
    }

    func testOneRowPerRecordCountsAllConflictingVersionsWithoutChoosingAWinner() {
        var first = VaultRevision(templateId: "api-credential", title: "Alpha")
        first.tags = ["First tag"]
        var second = first
        second.revisionId = UUID()
        second.templateId = "credit-card"
        second.title = "Beta"
        second.favorite = true
        second.deleted = true
        let tombstone = VaultRevision(title: "Hidden deletion", deleted: true)
        let items = LedgerBrowser.items(from: [second, tombstone, first])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, first.recordId)
        XCTAssertEqual(item.title, "Alpha / Beta")
        XCTAssertTrue(item.isConflicted)
        XCTAssertTrue(item.favorite)
        XCTAssertNil(item.revision)
        XCTAssertEqual(Set(item.versions.map(\.revisionId)), [first.revisionId, second.revisionId])
        for category in [LedgerCategory.all, .favorites, .credentials, .finances, .conflicts] {
            XCTAssertTrue(category.contains(item))
        }
        XCTAssertFalse(LedgerCategory.records.contains(item))
        XCTAssertTrue(item.matches("FIRST TAG"))
        XCTAssertTrue(item.matches(" Beta "))
        XCTAssertFalse(item.matches("Hidden deletion"))
        var browser = LedgerBrowser()
        browser.query = "First tag"
        XCTAssertEqual(browser.visibleItems(from: [first, second])[0].versions.count, 2)
    }

    func testSearchNeverIncludesSecretFieldsOrAttachmentNamesAndSortingIsStable() throws {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = VaultRevision(recordId: id1, templateId: "credit-card", title: "Same", tags: ["Work"], sections: [
            VaultSection(id: "card", fields: [
                VaultField(id: "number", kind: "string", value: .string("Never search this field"), concealed: false)
            ])
        ], attachments: [.object(["originalFilename": .string("Private attachment.pdf")])])
        let second = VaultRevision(recordId: id2, templateId: "future-type", title: "Same")
        let alpha = VaultRevision(title: "Alpha")
        let heads = [second, first, alpha]
        var browser = LedgerBrowser()
        XCTAssertEqual(browser.visibleItems(from: heads).map(\.id), [alpha.recordId, id1, id2])
        browser.descending = true
        XCTAssertEqual(browser.visibleItems(from: heads).map(\.id), [id1, id2, alpha.recordId])
        for query in ["Work", "credit-card", "Credit Card", " SAME "] {
            browser.query = query
            XCTAssertTrue(browser.visibleItems(from: heads).contains { $0.id == id1 })
        }
        for query in ["Never search this field", "Private attachment", "no match"] {
            browser.query = query
            XCTAssertTrue(browser.visibleItems(from: heads).isEmpty)
        }
        let item = try XCTUnwrap(LedgerBrowser.items(from: [first]).first)
        XCTAssertEqual(item.revision, first)
        XCTAssertFalse(item.isConflicted)
        XCTAssertFalse(item.favorite)
        XCTAssertTrue(item.matches(" \n "))
        XCTAssertFalse(LedgerBrowser.items(from: [second])[0].matches("Unknown secret"))
    }

    func testLocalizedTypeSearchRetainsEnglishAliasAndExcludesPrivateContent() throws {
        let revision = VaultRevision(templateId: "credit-card", title: "Synthetic", tags: ["Travel"], sections: [
            VaultSection(id: "card", fields: [
                VaultField(id: "cardNumber", value: .string("PRIVATE-FIELD-ONLY"), concealed: false)
            ])
        ], attachments: [.object(["originalFilename": .string("PRIVATE-FILENAME-ONLY.pdf")])])
        let item = try XCTUnwrap(LedgerBrowser.items(from: [revision]).first)
        let japanese = Locale(identifier: "ja")
        for query in ["クレジット", "Credit Card", "credit-card", " Travel "] {
            XCTAssertTrue(item.matches(query, locale: japanese), query)
        }
        for query in ["PRIVATE-FIELD-ONLY", "PRIVATE-FILENAME-ONLY", "Card Number", "カード番号"] {
            XCTAssertFalse(item.matches(query, locale: japanese), query)
        }
    }

    func testLedgerTypeSearchDoesNotExpandOtherProviderCandidates() throws {
        let revision = VaultRevision(templateId: "affiliate-account", title: "Synthetic program", sections: [
            VaultSection(id: "profile", fields: [VaultField(id: "profileId", value: .string("rakuten-webservice-jp"))])
        ])
        let item = try XCTUnwrap(LedgerBrowser.items(from: [revision]).first)
        let japanese = Locale(identifier: "ja")
        let template = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        XCTAssertTrue(item.matches(template.name, locale: japanese))
        XCTAssertTrue(item.matches(CatalogLocalization.templateName(template, locale: japanese), locale: japanese))
        for provider in ["Amazon", "Rakuten", "楽天", "rakuten-webservice-jp"] {
            XCTAssertFalse(item.matches(provider, locale: japanese), provider)
        }
        // Provider-name expansion is useful only while choosing a new type/profile.
        XCTAssertTrue(CatalogLocalization.matches(template, query: "Amazon", locale: japanese))
    }

    func testSelectionSurvivesRevisionReplacementAndSortButNotFilteringOrDeletion() {
        let first = VaultRevision(templateId: "api-credential", title: "Alpha")
        let second = VaultRevision(templateId: "credit-card", title: "Beta", favorite: true)
        var browser = LedgerBrowser()
        browser.show(recordId: first.recordId, heads: [first, second])
        var updated = first
        updated.revisionId = UUID()
        updated.title = "Gamma"
        browser.descending = true
        browser.reconcileSelection(heads: [updated, second])
        XCTAssertEqual(browser.selectedRecordId, first.recordId)
        browser.selectCategory(.credentials, heads: [updated, second])
        XCTAssertEqual(browser.selectedRecordId, first.recordId)
        browser.selectCategory(.favorites, heads: [updated, second])
        XCTAssertNil(browser.selectedRecordId)
        browser.query = "Beta"
        browser.show(recordId: first.recordId, heads: [updated, second])
        XCTAssertEqual(browser.category, .all)
        XCTAssertEqual(browser.query, "")
        XCTAssertEqual(browser.selectedRecordId, first.recordId)
        browser.query = "Beta"
        browser.reconcileSelection(heads: [updated, second])
        XCTAssertNil(browser.selectedRecordId)
        browser.show(recordId: second.recordId, heads: [updated, second])
        XCTAssertEqual(browser.selectedRecordId, second.recordId)
        var deleted = second
        deleted.deleted = true
        browser.reconcileSelection(heads: [updated, deleted])
        XCTAssertNil(browser.selectedRecordId)
        browser.show(recordId: UUID(), heads: [updated])
        XCTAssertNil(browser.selectedRecordId)
        browser.reset()
        XCTAssertEqual(browser.category, .all)
        XCTAssertEqual(browser.query, "")
        XCTAssertFalse(browser.descending)
        XCTAssertNil(browser.selectedRecordId)
    }
}
