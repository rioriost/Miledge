import Foundation
import MiledgeDomain

struct FieldChoice: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }

    func matches(_ query: String, locale: Locale) -> Bool {
        [value, label].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
        }
    }
}

enum FieldSelectionCatalog {
    // These depend on the issuing authority, provider or program, not a global enumeration.
    static let freeTextSelectIDs: Set<String> = ["licenseClass", "tier", "marketplace"]
    static let countryIDs: Set<String> = ["issuingCountry", "registrationCountry", "country"]
    private static let localizedIDs: Set<String> = [
        "credentialType", "accountType", "activity", "environment", "policyType",
        "paymentInterval", "taxType", "documentType", "serviceType"
    ]

    static let commonValues: [String: [String]] = [
        "brand": ["Visa", "Mastercard", "American Express", "JCB", "Diners Club", "Discover", "UnionPay"],
        "credentialType": ["API key", "Token", "Password", "ID and secret pair", "Certificate"],
        "signatureScheme": ["HMAC-SHA256", "HMAC-SHA512", "RSA-SHA256", "ECDSA-SHA256", "Ed25519"],
        "accountType": ["Checking / current", "Savings", "Business", "Investment", "Loan"],
        "chain": ["Bitcoin", "Ethereum", "Solana", "Polygon", "Arbitrum", "Optimism", "Avalanche", "BNB Chain"],
        "databaseType": ["PostgreSQL", "MySQL", "MariaDB", "SQLite", "Microsoft SQL Server",
                         "Oracle Database", "MongoDB", "Redis", "Amazon DynamoDB", "Apache Cassandra"],
        "incomingTls": ["TLS", "STARTTLS", "None"],
        "outgoingTls": ["TLS", "STARTTLS", "None"],
        "activity": ["Fishing", "Hunting", "Boating", "Camping"],
        "keyType": ["Ed25519", "ECDSA", "RSA", "FIDO2 Ed25519", "FIDO2 ECDSA", "DSA"],
        "environment": ["Production", "Staging", "Testing", "Development"],
        "encryption": ["WPA3-Personal", "WPA3-Enterprise", "WPA2/WPA3-Personal", "WPA2-Personal",
                       "WPA2-Enterprise", "OWE", "WEP (legacy)", "None"],
        "policyType": ["Vehicle", "Home", "Contents", "Property", "Liability", "Business"],
        "paymentInterval": ["Monthly", "Quarterly", "Semiannual", "Annual", "One-time"],
        "taxType": ["Income", "Corporate", "VAT / sales tax", "Property", "Capital gains", "Inheritance", "Gift"],
        "documentType": ["Visa", "Residence permit", "Permanent residence", "Work permit"],
        "serviceType": ["Electricity", "Water", "Gas", "Internet", "Telephone", "Cable / TV"]
    ]

    static var localizationKeys: Set<String> {
        Set(commonValues.filter { localizedIDs.contains($0.key) }.values.flatMap { $0 }).union([
            "Not set", "Other…", "Choose a date", "Choose a month", "Month", "Year",
            "Clear", "None", "WEP (legacy)", "New item title format",
            "Existing type fields and their values will be removed. Your title edits, organization, related items, and files are kept."
        ])
    }

    static func choices(
        for field: VaultField, templateID: String? = nil, locale: Locale = .current
    ) -> [FieldChoice] {
        guard let label = TemplateCatalog.fieldLocalizationKeys[field.id],
              field.label == nil || field.label == label else { return [] }
        if field.kind == "string", countryIDs.contains(field.id) { return countries(locale: locale) }
        if field.kind == "string", field.id == "currency" { return currencies(locale: locale) }
        let profileField = ["providerId", "profileId", "authenticationScheme"].contains(field.id)
        guard field.kind == "select" || (profileField && field.kind == "string") else { return [] }
        switch field.id {
        case "providerId":
            return unique(TemplateCatalog.affiliateProfiles.map {
                FieldChoice(value: $0.providerId, label: $0.providerId == "amazon" ? "Amazon"
                    : $0.providerId == "rakuten-webservice" ? "Rakuten Web Service"
                    : CatalogLocalization.string("Other affiliate network", locale: locale))
            })
        case "profileId":
            switch templateID {
            case "affiliate-account":
                return TemplateCatalog.affiliateProfiles.map {
                    FieldChoice(value: $0.id, label: CatalogLocalization.affiliateName($0, locale: locale))
                }
            case "api-credential":
                return TemplateCatalog.apiCredentialProfiles.map {
                    FieldChoice(value: $0.id, label: CatalogLocalization.templateName($0, locale: locale))
                }
            default: return []
            }
        case "authenticationScheme":
            return unique((TemplateCatalog.affiliateProfiles.map(\.authenticationScheme)
                + ["basic", "bearer", "api-key", "oauth2", "password"]).map {
                FieldChoice(value: $0, label: $0)
            })
        default:
            return (commonValues[field.id] ?? []).map {
                FieldChoice(value: $0, label: localizedIDs.contains(field.id) || ["None", "WEP (legacy)"].contains($0)
                    ? CatalogLocalization.string($0, locale: locale) : $0)
            }
        }
    }

    static func countries(locale: Locale = .current) -> [FieldChoice] {
        sorted(Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier
            guard code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
            return FieldChoice(value: code, label: locale.localizedString(forRegionCode: code) ?? code)
        }, locale: locale)
    }

    static func currencies(locale: Locale = .current) -> [FieldChoice] {
        sorted(Locale.Currency.isoCurrencies.map {
            let code = $0.identifier
            let name = locale.localizedString(forCurrencyCode: code) ?? code
            return FieldChoice(value: code, label: name == code ? code : "\(name) (\(code))")
        }, locale: locale)
    }

    private static func sorted(_ choices: [FieldChoice], locale: Locale) -> [FieldChoice] {
        unique(choices).sorted {
            let result = $0.label.compare($1.label, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return result == .orderedSame ? $0.value < $1.value : result == .orderedAscending
        }
    }

    private static func unique(_ choices: [FieldChoice]) -> [FieldChoice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.value).inserted }
    }
}

enum CalendarFieldValue {
    enum InvalidValue: Error { case date }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { preconditionFailure("UTC must be available.") }
        calendar.timeZone = utc
        return calendar
    }

    static func date(_ text: String, kind: String) throws -> Date {
        guard ["date", "year-month"].contains(kind), !text.isEmpty else { throw InvalidValue.date }
        try VaultEditor.validateField(VaultField(kind: kind, value: .string(text)))
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: (kind == "year-month" ? text + "-01" : text) + "T00:00:00Z") else {
            throw InvalidValue.date
        }
        return date
    }

    static func string(_ date: Date, kind: String) throws -> String {
        guard ["date", "year-month"].contains(kind) else { throw InvalidValue.date }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day, (1...9999).contains(year) else {
            throw InvalidValue.date
        }
        let text = kind == "year-month" ? String(format: "%04d-%02d", year, month)
            : String(format: "%04d-%02d-%02d", year, month, day)
        try VaultEditor.validateField(VaultField(kind: kind, value: .string(text)))
        return text
    }

    static func month(year: Int, month: Int) throws -> Date {
        try date(String(format: "%04d-%02d", year, month), kind: "year-month")
    }

    static func today(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        var local = calendar
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: now)
        guard let date = calendar.date(from: parts) else {
            preconditionFailure("A current Gregorian civil date must be representable.")
        }
        return date
    }

    static var range: ClosedRange<Date> {
        guard let start = calendar.date(from: DateComponents(year: 1, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31)) else {
            preconditionFailure("The supported Gregorian date range must be representable.")
        }
        return start...end
    }
}
