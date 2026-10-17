import Foundation
import XCTest
import MiledgeDomain
@testable import MiledgeApplication

@MainActor
final class InputValidationTests: XCTestCase {
    private let validator = InputValidator()

    func testPhoneNeedsExplicitRegionAndInternationalPrefixTakesPriority() {
        XCTAssertEqual(validator.phone("03-1234-5678", region: "")?.status, .notChecked)
        XCTAssertEqual(validator.phone("03-1234-5678", region: "JP")?.status, .matches)
        XCTAssertEqual(validator.phone("٠٣-١٢٣٤-٥٦٧٨", region: "JP")?.status, .matches)
        XCTAssertEqual(validator.phone("+44 20 7031 3000", region: "JP")?.status, .matches)
        XCTAssertEqual(validator.phone("020 7031 3000", region: "GB")?.status, .matches)
        XCTAssertEqual(validator.phone("+39 02 3661 8300", region: "")?.status, .matches)
        XCTAssertEqual(validator.phone("+1 202 555 0123 ext. 123", region: "")?.status, .matches)
        XCTAssertEqual(validator.phone("+999 123456789", region: "")?.status, .review)
        XCTAssertEqual(validator.phone("+044 20 7031 3000", region: "JP")?.status, .review)
        XCTAssertEqual(validator.phone("03-1234-5678 123456", region: "JP")?.status, .review)
        XCTAssertEqual(validator.phone("+1 1234567890123456", region: "")?.status, .review)
        XCTAssertEqual(validator.phone("Call me at +1 202 555 0123", region: "US")?.status, .review)
        XCTAssertEqual(validator.phone("123", region: "JP")?.status, .review)
        XCTAssertNil(validator.phone("", region: "JP"))
    }

    func testEveryBundledPostalPatternCompilesAndRecognizesPublishedExamples() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/MiledgeApplication/Resources/PostalRules.json"))
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let regions = try XCTUnwrap(snapshot["regions"] as? [String: [String: Any]])
        for (country, rule) in regions {
            guard let pattern = rule["pattern"] as? String else { continue }
            XCTAssertNoThrow(try NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z"), country)
            for example in (rule["examples"] as? String ?? "").split(separator: ",") {
                XCTAssertEqual(validator.postalCode(String(example), country: country)?.status, .matches, country + ": " + example)
            }
        }
    }

    func testPostalCountryRulesResourcesAndUnknownRegions() {
        XCTAssertGreaterThan(validator.postalRegionCount, 200)
        for (country, code) in [("JP", "001-0001"), ("JP", "００１０００１"), ("US", "02108-1234"),
                                ("CA", "k1a 0b1"), ("GB", "SW1A 1AA"), ("FR", "75001"),
                                ("DE", "10115"), ("BR", "01310-100"), ("IN", "110001")] {
            XCTAssertEqual(validator.postalCode(code, country: country)?.status, .matches, country)
        }
        XCTAssertEqual(validator.postalCode("12345", country: "JP")?.status, .review)
        XCTAssertEqual(validator.postalCode("123-4567", country: "US")?.status, .review)
        XCTAssertEqual(validator.postalCode("999999", country: "HK")?.status, .notChecked)
        XCTAssertEqual(validator.postalCode("12345", country: "")?.status, .notChecked)
        XCTAssertEqual(validator.postalCode("12345", country: "ZZ")?.status, .notChecked)
        XCTAssertNil(validator.postalCode("", country: "US"))
    }

    func testPassportUsesIssuerNotNationalityWithoutUniversalNineCharacterRejection() {
        XCTAssertEqual(validator.passport("AB0123456", issuingCountry: "JP")?.status, .matches)
        XCTAssertEqual(validator.passport("A01234567", issuingCountry: "JP")?.status, .review)
        XCTAssertEqual(validator.passport("A01234567", issuingCountry: "US")?.status, .matches)
        XCTAssertEqual(validator.passport("012345678", issuingCountry: "USA")?.status, .matches)
        XCTAssertEqual(validator.passport("legacy-number-longer-than-nine", issuingCountry: "XX")?.status, .notChecked)
        var revision = VaultRevision(templateId: "passport", title: "Synthetic", sections: [
            .init(id: "passport", fields: [
                .init(id: "passportNumber", value: .string("AB0123456"), concealed: true),
                .init(id: "nationality", value: .string("JP")), .init(id: "issuingCountry", value: .string("US"))
            ])
        ])
        let before = revision
        XCTAssertEqual(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport")?.status, .review)
        XCTAssertEqual(revision, before)
        revision.sections[0].fields[2].value = .string("JP")
        XCTAssertEqual(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport")?.status, .matches)
    }

    func testPhoneRegionIsScopedToExactSectionAndValueIsNeverNormalizedOrLogged() throws {
        let phone = VaultField(id: "phone", kind: "phone", value: .string(" ０３-１２３４-５６７８ "))
        let revision = VaultRevision(title: "Synthetic", sections: [
            .init(id: "one", fields: [phone, .init(id: "phone-region:phone", value: .string("JP"))]),
            .init(id: "two", fields: [phone])
        ])
        let data = try RevisionCodec.encode(revision)
        let result = validator.check(phone, in: revision, sectionID: "one")
        XCTAssertEqual(result?.status, .matches)
        XCTAssertEqual(validator.check(phone, in: revision, sectionID: "two")?.status, .notChecked)
        XCTAssertFalse(result!.message.contains("１２３４"))
        XCTAssertEqual(try RevisionCodec.encode(revision), data)
    }
}
