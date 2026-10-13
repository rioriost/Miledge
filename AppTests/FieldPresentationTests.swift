import MiledgeDomain
import XCTest
@testable import MiledgeApp

@MainActor
final class FieldPresentationTests: XCTestCase {
    func testInputSourceRestrictionRequiresAnExactASCIIFormat() throws {
        let constrained = Set(["number", "date", "year-month"])
        for kind in VaultEditor.supportedKinds + ["future-kind"] {
            XCTAssertEqual(FieldPresentation.usesRomanInput(for: kind), constrained.contains(kind), kind)
        }
        for (kind, text) in [
            ("string", "名前１２３"), ("concealed", "秘密の合言葉"),
            ("email", "利用者@例え.テスト"), ("url", "https://例え.テスト/資料"),
            ("phone", "+８１ ０３"), ("otp-seed", "任意の値"), ("key-material", "鍵\n資料")
        ] {
            let field = VaultField(kind: kind, value: .string(""), label: "Numeric ID")
            XCTAssertFalse(FieldPresentation.usesRomanInput(for: field.kind))
            XCTAssertEqual(try VaultEditor.replacingValue(in: field, with: .string(text)).value, .string(text))
        }
    }

    func testUnnamedFieldActionsHaveNamesAndNeverIncludeSecret() throws {
        for label in [nil, "", " \t\n"] as [String?] {
            let field = VaultField(kind: "concealed", value: .string("SECRET-MUST-NOT-BE-IN-ACTION"), label: label)
            let name = FieldPresentation.name(for: field, locale: Locale(identifier: "en"))
            XCTAssertEqual(name, "Unnamed field")
            for format in ["Reveal %@", "Hide %@", "Options for %@", "Remove %@", "Copy %@", "Copy %@ as JSON"] {
                let action = FieldPresentation.action(format, field: field, locale: Locale(identifier: "en"))
                XCTAssertTrue(action.contains(name))
                XCTAssertFalse(action.contains("SECRET"))
            }
        }
    }

    func testCustomAndUnknownLabelsPreserveExactText() {
        for id in [UUID().uuidString, "future-field", "cardNumber"] {
            let field = VaultField(id: id, label: "  My custom\nlabel  ")
            XCTAssertEqual(FieldPresentation.name(for: field, locale: Locale(identifier: "ja")), "  My custom\nlabel  ")
        }
        let unknown = VaultField(id: "unknown", label: "Card Number")
        XCTAssertEqual(FieldPresentation.name(for: unknown, locale: Locale(identifier: "ja")), "Card Number")
    }

    func testChoicesRequireKnownIdentityAndNeverReplaceCustomValues() throws {
        let original = "  Private\ncustom brand  "
        let brand = VaultField(id: "brand", kind: "select", value: .string(original), label: "Brand")
        XCTAssertTrue(FieldSelectionCatalog.choices(for: brand).contains { $0.value == "Visa" })
        XCTAssertEqual(brand.value, .string(original))
        XCTAssertEqual(try VaultEditor.replacingValue(in: brand, with: .string(original)).value, .string(original))
        for field in [
            VaultField(id: UUID().uuidString, kind: "select", label: "Brand"),
            VaultField(id: "brand", kind: "select", label: "Custom choices"),
            VaultField(id: "brand", kind: "string", label: "Brand"),
            VaultField(id: "future-choice", kind: "select", label: "Brand")
        ] {
            XCTAssertTrue(FieldSelectionCatalog.choices(for: field).isEmpty)
        }
    }

    func testProfileChoicesComeFromCatalogAndAreUnique() {
        for kind in ["select", "string"] {
            let provider = FieldSelectionCatalog.choices(for: VaultField(id: "providerId", kind: kind)).map(\.value)
            XCTAssertEqual(Set(provider), Set(TemplateCatalog.affiliateProfiles.map(\.providerId)))
            let schemes = FieldSelectionCatalog.choices(for: VaultField(id: "authenticationScheme", kind: kind)).map(\.value)
            XCTAssertTrue(Set(TemplateCatalog.affiliateProfiles.map(\.authenticationScheme)).isSubset(of: Set(schemes)))
            XCTAssertEqual(schemes.count, Set(schemes).count)
        }
        let profile = VaultField(id: "profileId", kind: "select")
        let affiliate = FieldSelectionCatalog.choices(for: profile, templateID: "affiliate-account").map(\.value)
        let api = FieldSelectionCatalog.choices(for: profile, templateID: "api-credential").map(\.value)
        XCTAssertEqual(Set(affiliate), Set(TemplateCatalog.affiliateProfiles.map(\.id)))
        XCTAssertEqual(Set(api), Set(TemplateCatalog.apiCredentialProfiles.map(\.id)))
        XCTAssertTrue(Set(affiliate).isDisjoint(with: Set(api)))
        XCTAssertTrue(FieldSelectionCatalog.choices(for: profile).isEmpty)
        XCTAssertTrue(FieldSelectionCatalog.choices(for: profile, templateID: "custom-item").isEmpty)
    }

    func testNumericAndDateInputKeepsExactRepresentation() throws {
        let cases = [("number", "-123456789012345678901234567890.00000000000000000100"),
                     ("number", "-0.000"), ("year-month", "2031-09"), ("date", "2032-02-29"),
                     ("string", "  text\nwith\r\nwhitespace  ")]
        for (kind, value) in cases {
            let field = VaultField(kind: kind, value: .string(""))
            let edited = try VaultEditor.replacingValue(in: field, with: .string(value))
            XCTAssertEqual(edited.value, .string(value))
        }
        let unknown = VaultField(kind: "number", value: .string("1.00"), unknownProperties: ["future": .string("preserve")])
        let original = unknown
        XCTAssertThrowsError(try VaultEditor.replacingValue(in: unknown, with: .string("2.00")))
        XCTAssertEqual(unknown, original)
        XCTAssertNotNil(FieldPresentation.formatHint(for: "date"))
        XCTAssertNotNil(FieldPresentation.formatHint(for: "year-month"))
        XCTAssertNotNil(FieldPresentation.formatHint(for: "number"))
    }
}
