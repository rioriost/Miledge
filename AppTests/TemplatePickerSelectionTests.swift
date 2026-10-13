import Foundation
import MiledgeDomain
import XCTest
@testable import MiledgeApp

@MainActor
final class TemplatePickerSelectionTests: XCTestCase {
    func testInlineTypeChoicesIncludeEveryTemplateAndAffiliateProfileWithoutDuplicates() {
        let choices = ItemTypePicker.choices
        XCTAssertEqual(choices.count, TemplateCatalog.all.count + TemplateCatalog.affiliateProfiles.count)
        XCTAssertEqual(Set(choices).count, choices.count)
        for template in TemplateCatalog.all {
            XCTAssertTrue(choices.contains(TemplatePickerChoice(templateID: template.id, profileID: nil)))
        }
        for profile in TemplateCatalog.affiliateProfiles {
            let revision = VaultRevision(templateId: "affiliate-account", sections: [
                VaultSection(id: "profile", fields: [VaultField(id: "profileId", value: .string(profile.id))])
            ])
            let selected = ItemTypePicker.choice(for: revision)
            XCTAssertEqual(selected.profileID, profile.id)
            XCTAssertTrue(choices.contains(selected))
        }
        XCTAssertEqual(ItemTypePicker.choice(for: VaultRevision(templateId: "document")),
                       TemplatePickerChoice(templateID: "document", profileID: nil))
        let genericAffiliate = VaultRevision(templateId: "affiliate-account", sections: [
            VaultSection(id: "program", fields: [VaultField(id: "profileId", value: .string(""))])
        ])
        XCTAssertEqual(ItemTypePicker.choice(for: genericAffiliate),
                       TemplatePickerChoice(templateID: "affiliate-account", profileID: nil))
    }

    func testFilteredSelectionCannotActivateHiddenOrMissingRow() throws {
        let locale = Locale(identifier: "en")
        let all = TemplatePicker.choices(category: .all, query: "", locale: locale)
        XCTAssertEqual(Set(all).count, all.count)
        let card = TemplatePickerChoice(templateID: "credit-card", profileID: nil)
        XCTAssertEqual(TemplatePicker.resolve(card, in: all)?.0.id, "credit-card")
        let bankOnly = TemplatePicker.choices(category: .all, query: "Bank Account", locale: locale)
        XCTAssertNil(TemplatePicker.resolve(card, in: bankOnly))
        XCTAssertNil(TemplatePicker.resolve(nil, in: bankOnly))
        XCTAssertNil(TemplatePicker.resolve(.init(templateID: "missing", profileID: nil), in: all))
        XCTAssertEqual(bankOnly, [.init(templateID: "bank-account", profileID: nil)])
    }

    func testAffiliateSelectionResolvesExactProfileAndRespectsCategory() throws {
        let locale = Locale(identifier: "ja")
        let choices = TemplatePicker.choices(category: .all, query: "楽天", locale: locale)
        XCTAssertEqual(choices, [.init(templateID: "affiliate-account", profileID: "rakuten-webservice-jp")])
        let selected = try XCTUnwrap(TemplatePicker.resolve(choices.first, in: choices))
        XCTAssertEqual(selected.0.id, "affiliate-account")
        XCTAssertEqual(selected.1, "rakuten-webservice-jp")
        XCTAssertTrue(TemplatePicker.choices(category: .finances, query: "楽天", locale: locale).isEmpty)
        let amazon = TemplatePickerChoice(templateID: "affiliate-account", profileID: "amazon-creators-api")
        XCTAssertNil(TemplatePicker.resolve(amazon, in: choices))
    }

    func testAffiliateTypeSearchWithoutAccentsKeepsEveryProviderChoice() throws {
        let locale = Locale(identifier: "fr")
        let template = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        XCTAssertEqual(CatalogLocalization.templateName(template, locale: locale), "Compte affilié")
        let choices = TemplatePicker.choices(category: .all, query: "  COMPTE AFFILIE  ", locale: locale)
        let expected = TemplateCatalog.affiliateProfiles.map {
            TemplatePickerChoice(templateID: template.id, profileID: $0.id)
        }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(choices, expected)
        for choice in choices {
            XCTAssertEqual(TemplatePicker.resolve(choice, in: choices)?.1, choice.profileID)
        }
    }
}
