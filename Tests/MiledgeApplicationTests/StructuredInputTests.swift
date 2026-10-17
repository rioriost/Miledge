import Foundation
import XCTest
import MiledgeDomain
@testable import MiledgeApplication

final class StructuredInputTests: XCTestCase {
    func testEmailCommonSyntaxAndUnverifiedInternationalForms() {
        for text in ["a+b@example.com", "o'hara@example.co.uk", "first.last@localhost", "a@xn--r8jz45g.xn--zckzah"] {
            XCTAssertEqual(StructuredChecks.check(.email, text: text)?.status, .matches, text)
        }
        for text in ["a..b@example.com", ".a@example.com", "a.@example.com", "a@-example.com", "a@@example.com", "a@example..com", "a b@example.com", "a@example.com\n"] {
            XCTAssertEqual(StructuredChecks.check(.email, text: text)?.status, .review, text)
        }
        for text in ["\"a b\"@example.com", "利用者@例え.テスト", "a@[IPv6:2001:db8::1]"] {
            XCTAssertEqual(StructuredChecks.check(.email, text: text)?.status, .notChecked, text)
        }
    }

    func testURLSyntaxWithoutNetworkOrRejectingCustomSchemes() {
        for text in ["https://example.com/a?q=x#fragment", "http://localhost:8080", "https://[2001:db8::1]/", "https://例え.テスト", "https://example.com/%20"] {
            XCTAssertEqual(StructuredChecks.check(.url, text: text)?.status, .matches, text)
        }
        for text in ["example.com", "https://", "https:/example.com", "https://example.com:65536", "https://example.com:bad", "https://a b.com", "https://example.com/%xx", "https://-example.com", "https://example..com", "https://[xyz]/", "https://example.com\\path"] {
            XCTAssertEqual(StructuredChecks.check(.url, text: text)?.status, .review, text)
        }
        XCTAssertEqual(StructuredChecks.check(.url, text: "myapp://oauth/callback")?.status, .notChecked)
        XCTAssertEqual(StructuredChecks.check(.url, text: "mailto:test@example.com")?.status, .notChecked)
        XCTAssertEqual(StructuredInput.httpsSuggestion("example.com/path"), "https://example.com/path")
        for text in ["", "https://example.com", "mailto:a@example.com", "a@example.com", "//example.com", " example.com", "foo bar.com"] {
            XCTAssertNil(StructuredInput.httpsSuggestion(text), text)
        }
    }

    func testPublishedCardTestNumbersAndIssuerExceptions() {
        for text in ["4242 4242 4242 4242", "378282246310005", "6205500000000000004"] {
            XCTAssertEqual(StructuredChecks.check(.cardNumber, text: text)?.status, .matches)
        }
        for text in ["4242424242424241", "0000000000000000", "4242", "42424242424242424242", "4242-4242-42A2-4242"] {
            XCTAssertEqual(StructuredChecks.check(.cardNumber, text: text)?.status, .review)
        }
        XCTAssertEqual(StructuredChecks.check(.cardNumber, text: "6205500000000000005", context: "UnionPay")?.status, .notChecked)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "123", context: "American Express")?.status, .review)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "1234", context: "American Express")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "012")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "1234", context: "Visa")?.status, .review)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "1234", context: "Other")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.cardSecurityCode, text: "12a")?.status, .review)
    }

    func testIBANCheckDigitsDoNotClaimNationalFormatOrExistence() {
        for text in ["GB82 WEST 1234 5698 7654 32", "AD1200012030200359100100", "AE070331234567890123456", "AL47212110090000000235698741", "TR470000100100000350930001"] {
            let result = StructuredChecks.check(.iban, text: text)
            XCTAssertEqual(result?.status, .matches, text)
            XCTAssertTrue(result!.message.contains("National format"))
        }
        for text in ["GB83WEST12345698765432", "GB82-WEST-12345698765432", "GB00WEST12345698765432", "GB99WEST12345698765432", "GB82", String(repeating: "A", count: 35)] {
            XCTAssertEqual(StructuredChecks.check(.iban, text: text)?.status, .review, text)
        }
        XCTAssertEqual(StructuredChecks.check(.bic, text: "DEUTDEFF")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.bic, text: "deutdeff500")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.bic, text: "A1BCDE22")?.status, .matches) // ISO 9362:2022 prefix is alphanumeric.
        XCTAssertEqual(StructuredChecks.check(.bic, text: "DEUT11FF")?.status, .review)
        XCTAssertEqual(StructuredChecks.check(.bic, text: "DEUTDEFFF")?.status, .review)
        XCTAssertEqual(StructuredChecks.check(.bic, text: "DEUTDEß")?.status, .review)
    }

    func testPortBoundariesAndExactRawPreservation() {
        for text in ["1", "65535", "05432"] { XCTAssertEqual(StructuredChecks.check(.port, text: text)?.status, .matches) }
        for text in ["0", "65536", "-1", "1.5", "1e2", "１２３", "123 "] { XCTAssertEqual(StructuredChecks.check(.port, text: text)?.status, .review) }
        XCTAssertTrue(StructuredInput.portChoices(fieldID: "incomingPort").contains { $0.value == "993" })
        XCTAssertFalse(StructuredInput.portChoices(fieldID: "outgoingPort").contains { $0.value == "993" })
    }

    func testVINUSCheckDigitAndInternationalChassisExceptions() {
        // NHTSA worked example: ninth position 4.
        XCTAssertEqual(StructuredChecks.check(.vin, text: "1G4AH59H45G118341", context: "US")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.vin, text: "1G4AH59H35G118341", context: "US")?.status, .review)
        XCTAssertEqual(StructuredChecks.check(.vin, text: "WVWZZZ1JZXW000001", context: "DE")?.status, .matches)
        XCTAssertEqual(StructuredChecks.check(.vin, text: "WVWZZZ1JZXW00000I")?.status, .review)
        XCTAssertTrue(StructuredChecks.check(.vin, text: "JZA80-0000001", context: "JP")!.message.contains("may differ"))
    }

    func testBase32PaddingAlphabetAndPadBits() {
        for text in ["MY======", "MZXQ====", "MZXW6===", "MZXW6YQ=", "MZXW6YTB", "mzxw 6ytb", "MZXW6"] {
            XCTAssertEqual(StructuredChecks.check(.otpSeed, text: text)?.status, .matches, text)
        }
        for text in ["M", "MZX", "MZXW6Y", "MZXW6Y0B", "MY=====", "MY=AA", "MZ"] {
            XCTAssertEqual(StructuredChecks.check(.otpSeed, text: text)?.status, .review, text)
        }
        XCTAssertEqual(StructuredChecks.check(.otpSeed, text: "otpauth://totp/example?secret=MY")?.status, .notChecked)
    }

    func testEmptyHugeAndSecretValuesNeverAppearInMessages() {
        for format in [StructuredInput.email, .url, .cardNumber, .cardSecurityCode, .iban, .bic, .port, .vin, .otpSeed] {
            XCTAssertNil(StructuredChecks.check(format, text: ""))
            XCTAssertEqual(StructuredChecks.check(format, text: String(repeating: "a", count: 4097))?.status, .notChecked)
            let secret = "synthetic-sensitive-123456789"
            XCTAssertFalse(StructuredChecks.check(format, text: secret)!.message.contains(secret))
        }
    }

    func testTemplateAndExplicitKindScopeAvoidsInventingCustomFieldMeaning() {
        let original = VaultField(id: "port", value: .string("70000"))
        XCTAssertEqual(StructuredInput.format(for: original, templateID: "database"), .port)
        XCTAssertNil(StructuredInput.format(for: original, templateID: "custom-item"))
        var renamed = original; renamed.label = "Serial port name"
        XCTAssertNil(StructuredInput.format(for: renamed, templateID: "database"))
        var changed = original; changed.kind = "number"
        XCTAssertNil(StructuredInput.format(for: changed, templateID: "database"))
        XCTAssertEqual(StructuredInput.format(for: .init(id: "custom", kind: "url", value: .string("")), templateID: nil), .url)
    }
}

@MainActor
final class RelatedInputTests: XCTestCase {
    func testDateOrderAndAdvisoriesPreserveSavableLegacyValues() throws {
        let validator = InputValidator()
        var revision = VaultRevision(templateId: "passport", title: "Synthetic", sections: [
            .init(id: "passport", fields: [.init(id: "expiryDate", kind: "date", value: .string("2025-02-28"))]),
            .init(id: "optional", fields: [.init(id: "issueDate", kind: "date", value: .string("2026-01-01"))])
        ])
        let bytes = try RevisionCodec.encode(revision)
        XCTAssertEqual(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport")?.status, .review)
        XCTAssertNoThrow(try VaultEditor.validateDraft(revision))
        XCTAssertEqual(try RevisionCodec.encode(revision), bytes)
        revision.sections[1].fields[0].value = .string("2025-02-28")
        XCTAssertNil(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport"))
        revision.sections[1].fields[0].value = .string("2026-01-01")
        revision.sections[1].fields[0].label = "Unrelated date"
        XCTAssertNil(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport"))
        revision.templateId = "custom-item"
        revision.sections[1].fields[0].value = .string("2026-01-01")
        XCTAssertNil(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "passport"))
    }

    func testBrandAndCountryContextAndNoMutation() throws {
        let validator = InputValidator()
        var revision = VaultRevision(templateId: "vehicle-record", title: "Synthetic", sections: [.init(id: "vehicle", fields: [
            .init(id: "vin", value: .string("1G4AH59H35G118341")), .init(id: "registrationCountry", value: .string("US"))
        ])])
        XCTAssertEqual(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "vehicle")?.status, .review)
        revision.sections[0].fields[1].value = .string("DE")
        XCTAssertEqual(validator.check(revision.sections[0].fields[0], in: revision, sectionID: "vehicle")?.status, .matches)
        let field = VaultField(id: "cardNumber", value: .string("4242 4242-4242 4241"), concealed: true)
        revision = .init(templateId: "credit-card", title: "Synthetic", sections: [.init(id: "card", fields: [field])])
        let data = try RevisionCodec.encode(revision)
        XCTAssertEqual(validator.check(field, in: revision, sectionID: "card")?.status, .review)
        XCTAssertNoThrow(try VaultEditor.validateDraft(revision))
        XCTAssertEqual(try RevisionCodec.encode(revision), data)
    }
}
