import Foundation
import MiledgeDomain
import XCTest
@testable import MiledgeApp

final class LocalizationTests: XCTestCase {
    func testJapaneseCatalogSearchFindsLocalizedNamesWithoutChangingStableIDs() throws {
        let japanese = Locale(identifier: "ja-JP")
        for (query, id) in [("クレジット", "credit-card"), ("銀行", "bank-account"), ("旅券", "passport")] {
            let template = try XCTUnwrap(TemplateCatalog.template(id: id))
            XCTAssertTrue(CatalogLocalization.matches(template, query: query, locale: japanese))
            XCTAssertNotEqual(CatalogLocalization.templateName(template, locale: japanese), template.name)
            XCTAssertEqual(template.id, id)
        }
        let card = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        XCTAssertTrue(CatalogLocalization.matches(card, query: "CREDIT", locale: japanese))
        XCTAssertTrue(CatalogLocalization.matches(card, query: "  ", locale: japanese))
        XCTAssertFalse(CatalogLocalization.matches(card, query: "never-a-type", locale: japanese))
        XCTAssertEqual(CatalogLocalization.templateName(id: "unknown-template", locale: japanese), "unknown-template")
        let affiliate = try XCTUnwrap(TemplateCatalog.template(id: "affiliate-account"))
        XCTAssertTrue(CatalogLocalization.matches(affiliate, query: "楽天", locale: japanese))
    }

    func testCatalogLabelsLocalizeButCustomRenamedAndUnknownLabelsRemainVerbatim() throws {
        let japanese = Locale(identifier: "ja")
        var field = try XCTUnwrap(TemplateCatalog.template(id: "credit-card")?.sections.first?.fields.first { $0.id == "cardholder" })
        let organization = try XCTUnwrap(TemplateCatalog.template(id: "membership")?.sections.first?.fields.first { $0.id == "organization" })
        XCTAssertEqual(CatalogLocalization.fieldLabel(organization, locale: japanese), "組織名")
        let originalValue = field.value
        XCTAssertEqual(CatalogLocalization.fieldLabel(field, locale: japanese), "カード名義人")
        XCTAssertEqual(field.label, "Cardholder")
        XCTAssertEqual(field.value, originalValue)
        field.label = "My personal Cardholder 名義"
        XCTAssertEqual(CatalogLocalization.fieldLabel(field, locale: japanese), "My personal Cardholder 名義")
        field.label = ""
        XCTAssertEqual(CatalogLocalization.fieldLabel(field, locale: japanese), "")
        field.label = nil
        XCTAssertEqual(CatalogLocalization.fieldLabel(field, locale: japanese), "カード名義人")
        for id in [UUID().uuidString, "future-field"] {
            let custom = VaultField(id: id, value: .string("Secret unchanged 🔐"), label: "Cardholder")
            XCTAssertEqual(CatalogLocalization.fieldLabel(custom, locale: japanese), "Cardholder")
            XCTAssertEqual(custom.value, .string("Secret unchanged 🔐"))
        }
    }

    func testAllBundledLocalesResolveCatalogLabelsAndProviderNames() throws {
        for language in CatalogLocalization.supportedLanguages {
            let locale = Locale(identifier: language)
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path), language)
            for key in TemplateCatalog.localizationKeys.union(FieldSelectionCatalog.localizationKeys) {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "__missing_translation__", table: nil),
                                  "__missing_translation__", "\(language): \(key)")
                XCTAssertFalse(CatalogLocalization.string(key, locale: locale).isEmpty, "\(language): \(key)")
            }
            for profile in TemplateCatalog.affiliateProfiles {
                let display = CatalogLocalization.affiliateName(profile, locale: locale)
                XCTAssertTrue(CatalogLocalization.matches(profile, query: display, locale: locale))
                XCTAssertTrue(CatalogLocalization.matches(profile, query: profile.name, locale: locale))
            }
        }
        XCTAssertEqual(CatalogLocalization.affiliateName(try XCTUnwrap(TemplateCatalog.affiliateProfile(id: "rakuten-webservice-jp")), locale: Locale(identifier: "ja")), "楽天ウェブサービス（日本）")
    }

    func testCountUsesPluralRulesAndUnknownLocaleFallsBackToEnglish() {
        XCTAssertEqual(CatalogLocalization.itemCount(1, locale: Locale(identifier: "en")), "1 item")
        XCTAssertEqual(CatalogLocalization.itemCount(2, locale: Locale(identifier: "en")), "2 items")
        XCTAssertEqual(CatalogLocalization.itemCount(2, locale: Locale(identifier: "ja")), "2件")
        XCTAssertEqual(CatalogLocalization.itemCount(2, locale: Locale(identifier: "ar")), "عنصران")
        XCTAssertEqual(CatalogLocalization.templateName(id: "credit-card", locale: Locale(identifier: "ru")), "Credit Card")
    }
}
