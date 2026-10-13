import Foundation
import XCTest
@testable import MiledgeDomain

final class TemplateCatalogTests: XCTestCase {
    private let expectedIDs: Set<String> = [
        "secure-note", "credit-card", "identity", "document", "api-credential", "bank-account", "crypto-wallet",
        "database", "driver-license", "email-account", "membership", "outdoor-license", "passport",
        "reward-program", "ssh-key", "server", "social-security-number", "software-license", "wireless-router",
        "affiliate-account", "insurance-policy", "tax-record", "residence-document", "vehicle-record", "property-record",
        "service-contract", "purchase-warranty", "recovery-kit", "signing-certificate", "oauth-client", "custom-item"
    ]

    func testExactThirtyTemplatesPlusCustomAndNoForbiddenCategory() {
        XCTAssertEqual(TemplateCatalog.all.count, 31)
        XCTAssertEqual(Set(TemplateCatalog.all.map(\.id)), expectedIDs)
        XCTAssertNil(TemplateCatalog.template(id: "medical-record"))
        XCTAssertNil(TemplateCatalog.template(id: "login"))
        XCTAssertNil(TemplateCatalog.template(id: "password"))
        XCTAssertNil(TemplateCatalog.template(id: "unknown"))
        XCTAssertEqual(TemplateCatalog.template(id: "social-security-number")?.name, "Government Identifier")
        let custom = ItemTemplate(id: "synthetic", name: "Synthetic", sections: [])
        XCTAssertEqual(custom.version, 1)
        XCTAssertTrue(custom.optionalSections.isEmpty)
    }

    func testEveryCoreAndOptionalTemplateRoundTripsAndFieldsAreStableAndSupported() throws {
        for template in TemplateCatalog.all {
            XCTAssertFalse(template.name.isEmpty)
            XCTAssertEqual(template.version, 1)
            XCTAssertFalse(template.sections.isEmpty)
            let sections = template.sections + template.optionalSections
            XCTAssertEqual(Set(sections.map(\.id)).count, sections.count, template.id)
            for section in sections {
                XCTAssertEqual(Set(section.fields.map(\.id)).count, section.fields.count)
                for field in section.fields {
                    XCTAssertFalse(field.id.isEmpty)
                    XCTAssertFalse(field.label?.isEmpty ?? true)
                    XCTAssertTrue(VaultPolicy.supportedFieldKinds.contains(field.kind))
                }
            }
            let revision = VaultRevision(templateId: template.id, templateVersion: template.version,
                                         title: "Synthetic \(template.name)", createdAt: Date(timeIntervalSince1970: 0), sections: sections)
            try VaultPolicy.validateForWrite(revision)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(revision)), revision)
            XCTAssertFalse(revision.isReadOnly)
            XCTAssertTrue(template.sections.flatMap(\.fields).contains { $0.kind == "multiline" }, template.id)
        }
        XCTAssertEqual(TemplateCatalog.template(id: "credit-card")?.sections.map(\.id), ["card", "notes"])
    }

    func testCoreFieldCoverageForEveryFormatAgainstDesign() throws {
        let required: [String: Set<String>] = [
            "secure-note": ["body"],
            "credit-card": ["cardholder", "brand", "cardNumber", "expiry", "verificationNumber", "pin", "issuer", "billingAddress"],
            "identity": ["name", "address", "birthDate", "phone", "email", "username", "company"],
            "document": ["originalFilename", "mediaType", "plaintextSize", "description"],
            "api-credential": ["provider", "username", "credential", "host", "credentialType", "issueDate", "expiryDate"],
            "bank-account": ["bank", "branch", "holder", "accountType", "accountNumber", "routingNumber", "iban", "swiftBic", "pin"],
            "crypto-wallet": ["chain", "address", "recoveryPhrase", "privateKey", "password"],
            "database": ["databaseType", "host", "port", "databaseName", "username", "password", "connectionString"],
            "driver-license": ["holder", "licenseNumber", "authority", "jurisdiction", "licenseClass", "issueDate", "expiryDate"],
            "email-account": ["email", "username", "password", "incomingServer", "outgoingServer", "incomingPort", "outgoingPort", "incomingTls", "outgoingTls", "authenticationScheme"],
            "membership": ["organization", "holder", "memberNumber", "contact", "pin", "startDate", "expiryDate"],
            "outdoor-license": ["holder", "permitNumber", "activity", "animal", "quantityLimit", "jurisdiction", "country", "expiryDate"],
            "passport": ["holder", "passportNumber", "nationality", "issuingCountry", "authority", "birthDate", "issueDate", "expiryDate"],
            "reward-program": ["company", "holder", "memberNumber", "pin", "tier", "contact"],
            "ssh-key": ["privateKey", "publicKey", "keyType", "fingerprint", "passphrase"],
            "server": ["url", "host", "username", "password", "administrationUrl", "environment"],
            "social-security-number": ["holder", "jurisdiction", "identifierSystem", "authority", "identifier", "issueDate", "expiryDate"],
            "software-license": ["product", "version", "licenseKey", "registeredName", "registeredEmail", "purchaseDate", "downloadUrl"],
            "wireless-router": ["deviceName", "administrationUrl", "administrationUsername", "administrationPassword", "ssid", "networkPassword", "encryption"],
            "affiliate-account": ["providerId", "profileId", "profileVersion", "program", "marketplace", "siteUrl", "publisherId", "trackingId", "authenticationScheme"],
            "insurance-policy": ["insurer", "product", "policyType", "policyNumber", "policyholder", "insuredAsset", "startDate", "expiryDate", "premium", "currency", "paymentInterval", "limits", "deductible", "agentContact", "claimsContact"],
            "tax-record": ["jurisdiction", "authority", "taxType", "taxPeriod", "filingNumber", "receiptNumber", "submissionDate", "deadline", "amount", "currency", "adviserContact"],
            "residence-document": ["issuingCountry", "authority", "documentType", "documentNumber", "holder", "status", "issueDate", "expiryDate"],
            "vehicle-record": ["registrationCountry", "authority", "vin", "registrationNumber", "owner", "make", "model", "modelYear", "registrationExpiry", "inspectionExpiry"],
            "property-record": ["country", "address", "propertyNumber", "ownerTenant", "contractStart", "contractEnd", "manager", "deposit", "rent", "currency", "keys", "accessCode"],
            "service-contract": ["provider", "serviceType", "contractNumber", "customerNumber", "serviceLocation", "startDate", "renewalDate", "cancellationDeadline", "fee", "currency", "paymentInterval", "contacts"],
            "purchase-warranty": ["product", "serialNumber", "seller", "purchaseDate", "orderNumber", "price", "currency", "warrantyStart", "warrantyExpiry", "repairContact"],
            "recovery-kit": ["service", "accountIdentifier", "codes", "issueDate", "instructions"],
            "signing-certificate": ["purpose", "subject", "issuer", "serialNumber", "fingerprint", "issueDate", "expiryDate", "publicCertificate", "privateKey", "passphrase"],
            "oauth-client": ["provider", "tenantProject", "clientId", "clientSecret", "authorizationUrl", "tokenUrl", "redirectUris", "scopes", "issueDate", "expiryDate"]
        ]
        for (id, fieldIDs) in required {
            let template = try XCTUnwrap(TemplateCatalog.template(id: id))
            let actual = Set((template.sections + template.optionalSections).flatMap(\.fields).map(\.id))
            XCTAssertTrue(fieldIDs.isSubset(of: actual), "\(id): \(fieldIDs.subtracting(actual))")
        }
    }

    func testSensitiveDefaultsAndMoneyDateIdentifierKinds() throws {
        let sensitive: Set<String> = [
            "body", "notes", "keys", "recoveryPhrase", "connectionString",
            "credentialId", "accessKeyId", "applicationId",
            "cardNumber", "accountNumber", "iban", "licenseNumber", "passportNumber", "identifier",
            "memberNumber", "permitNumber", "policyNumber", "filingNumber", "receiptNumber",
            "documentNumber", "propertyNumber", "contractNumber", "customerNumber",
            "credential", "credentialSecret", "sharedKey", "password", "pin", "verificationNumber",
            "privateKey", "passphrase", "licenseKey", "administrationPassword", "networkPassword",
            "accessCode", "codes", "clientSecret", "secretAccessKey", "accessKey", "token"
        ]
        let sections = (TemplateCatalog.all + TemplateCatalog.apiCredentialProfiles).flatMap { $0.sections + $0.optionalSections }
            + TemplateCatalog.affiliateProfiles.flatMap { $0.sections + $0.optionalSections }
        for section in sections {
            for field in section.fields {
                XCTAssertEqual(field.concealed, sensitive.contains(field.id), "\(section.id).\(field.id)")
                if field.id.hasSuffix("Number") || ["identifier", "clientId"].contains(field.id) {
                    guard case .string = field.value else { return XCTFail("Non-string identifier: \(field.id)") }
                }
                if field.id == "pin" { XCTAssertEqual(field.kind, "concealed") }
            }
        }
        let card = try XCTUnwrap(TemplateCatalog.template(id: "credit-card"))
        XCTAssertEqual(card.sections[0].fields.first { $0.id == "expiry" }?.kind, "year-month")
        let money = try XCTUnwrap(TemplateCatalog.template(id: "tax-record")?.optionalSections[0].fields.first { $0.id == "amount" })
        XCTAssertEqual(money.kind, "number")
        XCTAssertEqual(money.value, .string(""))
    }

    func testCurrentAmazonLegacyRakutenAndGenericProfilesAreDistinctAndConcealed() throws {
        XCTAssertEqual(Set(TemplateCatalog.affiliateProfiles.map(\.id)),
                       ["amazon-creators-api", "amazon-paapi-5", "rakuten-webservice-jp", "affiliate-generic"])
        XCTAssertNil(TemplateCatalog.affiliateProfile(id: "rakuten-advertising"))
        let creators = try XCTUnwrap(TemplateCatalog.affiliateProfile(id: "amazon-creators-api"))
        let legacy = try XCTUnwrap(TemplateCatalog.affiliateProfile(id: "amazon-paapi-5"))
        let rakuten = try XCTUnwrap(TemplateCatalog.affiliateProfile(id: "rakuten-webservice-jp"))
        XCTAssertEqual(creators.authenticationScheme, "oauth2")
        XCTAssertFalse(creators.isLegacy)
        XCTAssertTrue(legacy.isLegacy)
        XCTAssertEqual(Set(creators.sections.flatMap(\.fields).map(\.id)),
                       ["credentialId", "credentialSecret", "credentialVersion", "partnerTag", "marketplace"])
        XCTAssertEqual(Set(legacy.sections.flatMap(\.fields).map(\.id)), ["accessKeyId", "secretAccessKey", "partnerTag", "host", "region"])
        XCTAssertEqual(Set(rakuten.sections.flatMap(\.fields).map(\.id)), ["applicationId", "accessKey", "apiVersion"])
        XCTAssertEqual(rakuten.optionalSections.flatMap(\.fields).map(\.id), ["affiliateId"])
        XCTAssertFalse((rakuten.sections + rakuten.optionalSections).flatMap(\.fields).contains { $0.id == "secretKey" })
        for profile in TemplateCatalog.affiliateProfiles {
            XCTAssertFalse(profile.name.isEmpty)
            XCTAssertFalse(profile.providerId.isEmpty)
            XCTAssertEqual(profile.version, 1)
            let common = VaultSection(id: "program", fields: [
                .init(id: "profileId", value: .string(profile.id)), .init(id: "profileVersion", value: .string("1"))
            ])
            let value = VaultRevision(templateId: "affiliate-account", title: "Synthetic", createdAt: Date(timeIntervalSince1970: 0),
                                      sections: [common] + profile.sections + profile.optionalSections)
            try VaultPolicy.validateForWrite(value)
            XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)), value)
            for field in (profile.sections + profile.optionalSections).flatMap(\.fields) where
                ["credentialId", "credentialSecret", "accessKeyId", "secretAccessKey", "applicationId", "accessKey",
                 "token"].contains(field.id) {
                XCTAssertTrue(field.concealed)
            }
            for field in (profile.sections + profile.optionalSections).flatMap(\.fields) where
                ["affiliateId", "partnerTag", "publisherId", "trackingId", "host", "region"].contains(field.id) {
                XCTAssertFalse(field.concealed)
            }
        }
    }

    func testAPIProfilesAndOrderedCredentialRotation() throws {
        XCTAssertEqual(TemplateCatalog.apiCredentialProfiles.map(\.id), ["id-secret-pair", "webhook-signing-key"])
        let webhook = TemplateCatalog.apiCredentialProfiles[1].sections[0]
        XCTAssertEqual(webhook.fields.map(\.id), ["url", "events", "signatureScheme", "sharedKey"])
        for profile in TemplateCatalog.apiCredentialProfiles {
            let value = VaultRevision(templateId: "api-credential", title: "Synthetic", createdAt: Date(timeIntervalSince1970: 0), sections: profile.sections)
            try VaultPolicy.validateForWrite(value)
        }
        var first = try XCTUnwrap(TemplateCatalog.affiliateProfile(id: "amazon-creators-api")?.sections[0])
        var second = first
        first.id = "credential-rotation-1"
        second.id = "credential-rotation-2"
        first.fields[0].value = .string("000-old")
        second.fields[0].value = .string("000-new")
        let value = VaultRevision(templateId: "affiliate-account", title: "Synthetic", createdAt: Date(timeIntervalSince1970: 0), sections: [first, second])
        try VaultPolicy.validateForWrite(value)
        XCTAssertEqual(try RevisionCodec.decode(RevisionCodec.encode(value)).sections, [first, second])
    }
}

extension TemplateCatalogTests {
    private var localizationResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "App/Resources")
    }

    private func strings(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: localizationResources.appending(path: "\(language).lproj/Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testDynamicLocalizationKeysCoverEveryCatalogAndProfileField() {
        let sections = (TemplateCatalog.all + TemplateCatalog.apiCredentialProfiles).flatMap { $0.sections + $0.optionalSections }
            + TemplateCatalog.affiliateProfiles.flatMap { $0.sections + $0.optionalSections }
        let fields = sections.flatMap(\.fields)
        XCTAssertEqual(Set(fields.map(\.id)).count, 187)
        XCTAssertEqual(TemplateCatalog.fieldLocalizationKeys.count, 187)
        for field in fields {
            XCTAssertEqual(TemplateCatalog.fieldLocalizationKeys[field.id], field.label, field.id)
            XCTAssertTrue(TemplateCatalog.localizationKeys.contains(field.label ?? ""), field.id)
        }
        for name in (TemplateCatalog.all + TemplateCatalog.apiCredentialProfiles).map(\.name)
            + TemplateCatalog.affiliateProfiles.map(\.name) {
            XCTAssertTrue(TemplateCatalog.localizationKeys.contains(name), name)
        }
    }

    func testAllTwelveLocalesContainEveryDynamicAndStaticKeyAndPreserveFormatArguments() throws {
        let languages = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es", "pt-BR", "it", "ar", "hi"]
        let actualLanguages = try FileManager.default.contentsOfDirectory(at: localizationResources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertEqual(Set(actualLanguages), Set(languages))
        let english = try strings("en")
        XCTAssertTrue(TemplateCatalog.localizationKeys.isSubset(of: Set(english.keys)),
                      "Missing dynamically generated keys: \(TemplateCatalog.localizationKeys.subtracting(english.keys))")
        let pattern = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:@|lld)"#)
        func placeholders(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }.sorted()
        }
        for language in languages {
            let localized = try strings(language)
            XCTAssertEqual(Set(localized.keys), Set(english.keys), language)
            for key in english.keys {
                let value = try XCTUnwrap(localized[key], "\(language): \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
                // Symbolic format keys don't contain their own argument markers.
                let expectedFormat = key == "New item title format" ? "%1$@ %2$@" : key
                XCTAssertEqual(placeholders(value), placeholders(expectedFormat), "\(language): \(key)")
                XCTAssertFalse(value.contains("ZZPH") || value.contains("ZZCOUNT"), "Unreplaced marker: \(language): \(key)")
            }
        }
    }

    func testLiteralUIKeysAreRegisteredAndFaceIDPurposeIsLocalized() throws {
        let english = try strings("en")
        let app = localizationResources.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // This supplements catalog-generated key extraction; it deliberately excludes Text(verbatim:).
        let pattern = try NSRegularExpression(pattern: #"(?:Text|Button|Label|Section|LabeledContent|Toggle|Menu|SecureField|TextField|ProgressView|ContentUnavailableView|navigationTitle|accessibilityLabel|alert|confirmationDialog)\(\s*"([^"\\]*)"|String\(localized:\s*"([^"\\]*)""#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let range = Range(capture, in: source) else { continue }
                let key = String(source[range])
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                XCTAssertNotNil(english[key], "\(file.lastPathComponent): unregistered UI key \(key)")
            }
        }
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es", "pt-BR", "it", "ar", "hi"] {
            let file = localizationResources.appending(path: "\(language).lproj/InfoPlist.strings")
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String])
            XCTAssertEqual(info["NSFaceIDUsageDescription"], try strings(language)["Unlock your private ledger."])
        }
    }

    func testPluralResourcesResolveLanguageSpecificCounts() throws {
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es", "pt-BR", "it", "ar", "hi"] {
            let path = localizationResources.appending(path: "\(language).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path.path))
            let data = try Data(contentsOf: path.appending(path: "Localizable.stringsdict"))
            let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]])
            let rule = try XCTUnwrap(dictionary["%lld items"]?["items"] as? [String: String])
            XCTAssertEqual(rule["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
            XCTAssertNotNil(rule["other"])
            if language == "ar" {
                XCTAssertTrue(Set(["zero", "one", "two", "few", "many", "other"]).isSubset(of: Set(rule.keys)))
            }
            let format = bundle.localizedString(forKey: "%lld items", value: nil, table: nil)
            let values = [0, 1, 2, 3, 11, 100].map {
                String(format: format, locale: Locale(identifier: language), arguments: [Int64($0)])
            }
            XCTAssertFalse(values.contains { $0.isEmpty || $0.contains("%") })
            if language == "en" { XCTAssertEqual(values[1], "1 item"); XCTAssertEqual(values[2], "2 items") }
            if language == "ja" { XCTAssertEqual(values[1], "1件"); XCTAssertEqual(values[2], "2件") }
            if language == "ar" { XCTAssertEqual(values[1], "عنصر واحد"); XCTAssertEqual(values[2], "عنصران") }
        }
    }
}
