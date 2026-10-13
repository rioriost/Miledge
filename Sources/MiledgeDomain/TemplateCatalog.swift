import Foundation

public struct ItemTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sections: [VaultSection]
    public let version: Int
    /// Optional fields are disclosed on demand, rather than required for item creation.
    public let optionalSections: [VaultSection]

    public init(id: String, name: String, sections: [VaultSection], version: Int = 1, optionalSections: [VaultSection] = []) {
        self.id = id
        self.name = name
        self.sections = sections
        self.version = version
        self.optionalSections = optionalSections
    }
}

public struct AffiliateProviderProfile: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let providerId: String
    public let version: Int
    public let authenticationScheme: String
    public let isLegacy: Bool
    public let sections: [VaultSection]
    public let optionalSections: [VaultSection]
}

/// Screen concealment is independent of encryption and access protection.
public enum FieldPrivacy {
    public static func concealedByDefault(id: String, kind: String) -> Bool {
        if ["concealed", "otp-seed", "recovery-codes"].contains(kind) { return true }
        if kind == "key-material" { return !["publicKey", "publicCertificate"].contains(id) }
        return [
            "body", "notes", "keys", "recoveryPhrase", "connectionString",
            "credentialId", "accessKeyId", "applicationId",
            "cardNumber", "accountNumber", "iban",
            "licenseNumber", "passportNumber", "identifier", "memberNumber", "permitNumber",
            "policyNumber", "filingNumber", "receiptNumber", "documentNumber", "propertyNumber",
            "contractNumber", "customerNumber"
        ].contains(id)
    }
}

public enum TemplateCatalog {
    public static func template(id: String) -> ItemTemplate? { all.first { $0.id == id } }
    public static func affiliateProfile(id: String) -> AffiliateProviderProfile? { affiliateProfiles.first { $0.id == id } }

    public static let affiliateProfiles: [AffiliateProviderProfile] = [
        .init(
            id: "amazon-creators-api", name: "Amazon Creators API", providerId: "amazon", version: 1,
            authenticationScheme: "oauth2", isLegacy: false,
            sections: [section("credentials", [
                field("credentialId"), field("credentialSecret", "concealed"), field("credentialVersion"),
                field("partnerTag"), field("marketplace", "select", concealed: false)
            ])], optionalSections: []
        ),
        .init(
            id: "amazon-paapi-5", name: "Amazon PA-API 5.0 (legacy)", providerId: "amazon", version: 1,
            authenticationScheme: "aws-signature-v4", isLegacy: true,
            sections: [section("credentials", [
                field("accessKeyId"), field("secretAccessKey", "concealed"), field("partnerTag"),
                field("host"), field("region", "string", concealed: false)
            ])], optionalSections: []
        ),
        .init(
            id: "rakuten-webservice-jp", name: "Rakuten Web Service (Japan)", providerId: "rakuten-webservice",
            version: 1, authenticationScheme: "application-id-and-access-key", isLegacy: false,
            sections: [section("credentials", [
                field("applicationId"), field("accessKey", "concealed"), field("apiVersion")
            ])], optionalSections: [section("optional-credentials", [field("affiliateId")])]
        ),
        .init(
            id: "affiliate-generic", name: "Other affiliate network", providerId: "other", version: 1,
            authenticationScheme: "user-defined", isLegacy: false,
            sections: [section("credentials", [
                field("network", "string", concealed: false), field("publisherId"), field("programId"),
                field("trackingId"), field("authenticationScheme", "select", concealed: false)
            ])], optionalSections: [section("optional-credentials", [
                field("token", "concealed"), field("credentialId"), field("credentialSecret", "concealed")
            ])]
        )
    ]

    /// Provider-neutral credential profiles. These store material; they never execute requests.
    public static let apiCredentialProfiles: [ItemTemplate] = [
        .init(id: "id-secret-pair", name: "ID and secret pair", sections: [
            section("credentials", [field("credentialId"), field("credentialSecret", "concealed")])
        ]),
        .init(id: "webhook-signing-key", name: "Webhook signing key", sections: [
            section("webhook", [
                field("url", "url"), field("events", "multi-select"), field("signatureScheme", "select", concealed: false),
                field("sharedKey", "concealed")
            ])
        ])
    ]

    public static let all: [ItemTemplate] = [
        item("secure-note", "Secure Note", "note", [field("body", "multiline")]),
        item("credit-card", "Credit Card", "card", [
            field("cardholder"), field("brand", "select", concealed: false), field("cardNumber"),
            field("expiry", "year-month"), field("verificationNumber", "concealed")
        ], extra: [field("pin", "concealed"), field("issuer", "string", concealed: false), field("billingAddress", "address")]),
        item("identity", "Identity", "identity", [field("name"), field("address", "address")], extra: [
            field("givenName"), field("familyName"), field("birthDate", "date"), field("phone", "phone"),
            field("email", "email"), field("username"), field("company")
        ]),
        item("document", "Document", "document", [field("description", "multiline")], extra: [
            field("originalFilename"), field("mediaType", "string", concealed: false), field("plaintextSize", "number")
        ]),
        item("api-credential", "API Credential", "credentials", [
            field("provider", "string", concealed: false), field("credential", "concealed")
        ], extra: [
            field("username"), field("host"), field("credentialType", "select", concealed: false),
            field("issueDate", "date"), field("expiryDate", "date"), field("profileId", "select", concealed: false),
            field("credentialId"), field("credentialSecret", "concealed"), field("url", "url"),
            field("events", "multi-select"), field("signatureScheme", "select", concealed: false), field("sharedKey", "concealed")
        ]),
        item("bank-account", "Bank Account", "account", [
            field("bank", "string", concealed: false), field("holder"), field("accountNumber")
        ], extra: [
            field("branch"), field("accountType", "select", concealed: false), field("routingNumber"),
            field("iban"), field("swiftBic"), field("pin", "concealed")
        ]),
        item("crypto-wallet", "Crypto Wallet", "wallet", [
            field("chain", "select", concealed: false), field("address"), field("recoveryPhrase", "multiline")
        ], extra: [field("privateKey", "key-material"), field("password", "concealed")]),
        item("database", "Database", "connection", [
            field("databaseType", "select", concealed: false), field("host"), field("databaseName"), field("username"), field("password", "concealed")
        ], extra: [field("port"), field("connectionString", "concealed")]),
        item("driver-license", "Driver License", "license", [
            field("holder"), field("licenseNumber"), field("jurisdiction", "string", concealed: false), field("expiryDate", "date")
        ], extra: [
            field("authority", "string", concealed: false), field("licenseClass", "select", concealed: false), field("issueDate", "date")
        ]),
        item("email-account", "Email Account", "credentials", [
            field("email", "email"), field("username"), field("password", "concealed")
        ], extra: [
            field("incomingServer"), field("incomingPort"), field("incomingTls", "select", concealed: false),
            field("outgoingServer"), field("outgoingPort"), field("outgoingTls", "select", concealed: false),
            field("authenticationScheme", "select", concealed: false)
        ]),
        item("membership", "Membership", "membership", [
            field("organization", "string", concealed: false), field("holder"), field("memberNumber")
        ], extra: [field("contact"), field("pin", "concealed"), field("startDate", "date"), field("expiryDate", "date")]),
        item("outdoor-license", "Outdoor License", "permit", [
            field("holder"), field("permitNumber"), field("activity", "select", concealed: false),
            field("jurisdiction", "string", concealed: false), field("expiryDate", "date")
        ], extra: [field("animal", "string", concealed: false), field("quantityLimit", "number"), field("country", "string", concealed: false)]),
        item("passport", "Passport", "passport", [
            field("holder"), field("passportNumber"), field("issuingCountry", "string", concealed: false), field("expiryDate", "date")
        ], extra: [
            field("nationality", "string", concealed: false), field("authority", "string", concealed: false),
            field("birthDate", "date"), field("issueDate", "date")
        ]),
        item("reward-program", "Reward Program", "membership", [
            field("company", "string", concealed: false), field("holder"), field("memberNumber")
        ], extra: [field("pin", "concealed"), field("tier", "select", concealed: false), field("contact")]),
        item("ssh-key", "SSH Key", "key", [field("privateKey", "key-material"), field("publicKey", "key-material")], extra: [
            field("keyType", "select", concealed: false), field("fingerprint"), field("passphrase", "concealed")
        ]),
        item("server", "Server", "connection", [
            field("host"), field("username"), field("password", "concealed")
        ], extra: [field("url", "url"), field("administrationUrl", "url"), field("environment", "select", concealed: false)]),
        item("social-security-number", "Government Identifier", "identifier", [
            field("holder"), field("jurisdiction", "string", concealed: false), field("identifierSystem", "string", concealed: false),
            field("identifier")
        ], extra: [field("authority", "string", concealed: false), field("issueDate", "date"), field("expiryDate", "date")]),
        item("software-license", "Software License", "license", [
            field("product", "string", concealed: false), field("licenseKey", "concealed")
        ], extra: [field("version", "string", concealed: false), field("registeredName"), field("registeredEmail", "email"),
                   field("purchaseDate", "date"), field("downloadUrl", "url")]),
        item("wireless-router", "Wireless Router", "router", [
            field("deviceName"), field("administrationUsername"), field("administrationPassword", "concealed"),
            field("ssid"), field("networkPassword", "concealed")
        ], extra: [field("administrationUrl", "url"), field("encryption", "select", concealed: false)]),
        item("affiliate-account", "Affiliate Account", "program", [
            field("providerId", "select", concealed: false), field("profileId", "select", concealed: false),
            field("profileVersion", "string", concealed: false, value: .string("1")),
            field("program"), field("marketplace", "select", concealed: false), field("publisherId"), field("trackingId")
        ], extra: [field("siteUrl", "url"), field("authenticationScheme", "select", concealed: false)]),
        item("insurance-policy", "Insurance Policy (non-health)", "policy", [
            field("insurer", "string", concealed: false), field("product"), field("policyType", "select", concealed: false),
            field("policyNumber"), field("policyholder"), field("insuredAsset"), field("startDate", "date"), field("expiryDate", "date")
        ], extra: [
            field("premium", "number"), field("currency", "string", concealed: false),
            field("paymentInterval", "select", concealed: false), field("limits", "number"), field("deductible", "number"),
            field("agentContact"), field("claimsContact")
        ]),
        item("tax-record", "Tax Record", "tax", [
            field("jurisdiction", "string", concealed: false), field("authority", "string", concealed: false),
            field("taxType", "select", concealed: false), field("taxPeriod"), field("filingNumber")
        ], extra: [
            field("receiptNumber"), field("submissionDate", "date"), field("deadline", "date"),
            field("amount", "number"), field("currency", "string", concealed: false), field("adviserContact")
        ]),
        item("residence-document", "Visa / Residence Document", "residence", [
            field("issuingCountry", "string", concealed: false), field("documentType", "select", concealed: false),
            field("documentNumber"), field("holder"), field("status"), field("expiryDate", "date")
        ], extra: [field("authority", "string", concealed: false), field("issueDate", "date")]),
        item("vehicle-record", "Vehicle Record", "vehicle", [
            field("registrationCountry", "string", concealed: false), field("vin"), field("registrationNumber"),
            field("owner"), field("make", "string", concealed: false), field("model", "string", concealed: false)
        ], extra: [
            field("authority", "string", concealed: false), field("modelYear"), field("registrationExpiry", "date"),
            field("inspectionExpiry", "date")
        ]),
        item("property-record", "Property / Tenancy", "property", [
            field("country", "string", concealed: false), field("address", "address"), field("propertyNumber"),
            field("ownerTenant"), field("contractStart", "date"), field("contractEnd", "date")
        ], extra: [
            field("manager"), field("deposit", "number"), field("rent", "number"),
            field("currency", "string", concealed: false), field("keys", "multiline"), field("accessCode", "concealed")
        ]),
        item("service-contract", "Utilities / Service Contract", "contract", [
            field("provider", "string", concealed: false), field("serviceType", "select", concealed: false),
            field("contractNumber"), field("customerNumber"), field("serviceLocation", "address")
        ], extra: [
            field("startDate", "date"), field("renewalDate", "date"), field("cancellationDeadline", "date"),
            field("fee", "number"), field("currency", "string", concealed: false),
            field("paymentInterval", "select", concealed: false), field("contacts", "multiline")
        ]),
        item("purchase-warranty", "Purchase / Warranty", "purchase", [
            field("product", "string", concealed: false), field("serialNumber"), field("seller", "string", concealed: false),
            field("purchaseDate", "date"), field("orderNumber")
        ], extra: [
            field("price", "number"), field("currency", "string", concealed: false),
            field("warrantyStart", "date"), field("warrantyExpiry", "date"), field("repairContact")
        ]),
        item("recovery-kit", "Recovery Kit", "recovery", [
            field("service", "string", concealed: false), field("accountIdentifier"), field("codes", "recovery-codes")
        ], extra: [field("issueDate", "date"), field("instructions", "multiline")]),
        item("signing-certificate", "Signing Certificate", "certificate", [
            field("purpose", "string", concealed: false), field("subject"), field("issuer", "string", concealed: false),
            field("serialNumber"), field("fingerprint"), field("publicCertificate", "key-material")
        ], extra: [
            field("issueDate", "date"), field("expiryDate", "date"), field("privateKey", "key-material"),
            field("passphrase", "concealed")
        ]),
        item("oauth-client", "OAuth App", "oauth", [
            field("provider", "string", concealed: false), field("tenantProject"), field("clientId"),
            field("authorizationUrl", "url"), field("tokenUrl", "url"), field("redirectUris", "multi-select"), field("scopes", "multi-select")
        ], extra: [field("clientSecret", "concealed"), field("issueDate", "date"), field("expiryDate", "date")]),
        item("custom-item", "Custom Item", "custom", [])
    ]

    /// Localization keys are derived from the complete built-in catalog, never user records.
    /// The field ID stays stable and stored labels are preserved for backward compatibility.
    public static let fieldLocalizationKeys: [String: String] = {
        let sections = (all + apiCredentialProfiles).flatMap { $0.sections + $0.optionalSections }
            + affiliateProfiles.flatMap { $0.sections + $0.optionalSections }
        return Dictionary(sections.flatMap(\.fields).compactMap { field in
            field.label.map { (field.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }()

    public static var localizationKeys: Set<String> {
        Set((all + apiCredentialProfiles).map(\.name))
            .union(affiliateProfiles.map(\.name))
            .union(fieldLocalizationKeys.values)
            .union(["Organization name"])
    }

    private static func item(_ id: String, _ name: String, _ sectionID: String, _ fields: [VaultField], extra: [VaultField] = []) -> ItemTemplate {
        var sections = [section(sectionID, fields)]
        if id != "secure-note" { sections.append(section("notes", [field("notes", "multiline")])) }
        var optional = extra.isEmpty ? [] : [section("optional", extra)]
        optional.append(section("original-notation", [field("originalDateNotation")]))
        return .init(id: id, name: name, sections: sections, optionalSections: optional)
    }

    private static func section(_ id: String, _ fields: [VaultField]) -> VaultSection { .init(id: id, fields: fields) }

    private static func field(_ id: String, _ kind: String = "string", concealed: Bool? = nil, value: JSONValue? = nil) -> VaultField {
        let defaultValue: JSONValue
        switch kind {
        case "address": defaultValue = .object([:])
        case "multi-select", "recovery-codes": defaultValue = .array([])
        case "boolean": defaultValue = .bool(false)
        default: defaultValue = .string("")
        }
        let label = id.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return .init(id: id, kind: kind, value: value ?? defaultValue,
                     concealed: concealed ?? FieldPrivacy.concealedByDefault(id: id, kind: kind),
                     label: label.prefix(1).uppercased() + label.dropFirst())
    }
}
