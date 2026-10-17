import Foundation
import MiledgeDomain
import PhoneNumberKit

public struct InputCheck: Equatable, Sendable {
    public enum Status: String, Sendable { case matches, review, notChecked }
    public let status: Status
    /// A localization key, never an echo of the stored value.
    public let message: String
    public init(_ status: Status, _ message: String) { self.status = status; self.message = message }
}

/// Advisory, entirely offline checks. No mutation, network lookup, or existence/identity claim.
@MainActor
public final class InputValidator {
    public static let shared = InputValidator()
    private let phoneNumbers = PhoneNumberUtility()
    private let postalRules: [String: PostalRule]
    public static let phoneRegionPrefix = VaultEditor.phoneRegionPrefix

    private struct PostalRule: Decodable {
        let pattern: String?
        let usesPostalCode: Bool
    }
    private struct PostalSnapshot: Decodable { let regions: [String: PostalRule] }
    private final class ResourceAnchor {}

    public init() {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ResourceAnchor.self)
        #endif
        if let url = bundle.url(forResource: "PostalRules", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(PostalSnapshot.self, from: data) {
            postalRules = snapshot.regions
        } else {
            // A packaging failure must never turn into a successful validation result.
            postalRules = [:]
        }
    }

    public var postalRegionCount: Int { postalRules.count }

    public func check(_ field: VaultField, in revision: VaultRevision, sectionID: String) -> InputCheck? {
        guard case .string(let text) = field.value else { return nil }
        if field.kind == "phone" {
            let regionID = Self.phoneRegionPrefix + field.id
            let values = revision.sections.first { $0.id == sectionID }?.fields ?? []
            let region = values.first { $0.id == regionID }.flatMap { Self.string($0.value) } ?? ""
            return phone(text, region: region)
        }
        if field.id == "passportNumber", revision.templateId == "passport" {
            // Issuing authority is distinct from nationality and from the device's locale.
            let countries = revision.sections.flatMap(\.fields).filter { $0.id == "issuingCountry" }
                .compactMap { Self.string($0.value) }.filter { !$0.isEmpty }
            let country = Set(countries).count == 1 ? countries.first! : ""
            return passport(text, issuingCountry: country)
        }
        if let format = StructuredInput.format(for: field, templateID: revision.templateId) {
            let contextID = format == .vin ? "registrationCountry" : "brand"
            return StructuredChecks.check(format, text: text, context: uniqueValue(contextID, in: revision) ?? "")
        }
        return dateOrder(field, in: revision)
    }

    private func uniqueValue(_ id: String, in revision: VaultRevision) -> String? {
        let values = revision.sections.flatMap(\.fields).filter { $0.id == id }
        guard values.count == 1 else { return nil }
        return Self.string(values[0].value)
    }

    private func dateOrder(_ field: VaultField, in revision: VaultRevision) -> InputCheck? {
        guard field.kind == "date", let end = Self.string(field.value), !end.isEmpty,
              let template = TemplateCatalog.template(id: revision.templateId),
              let definition = (template.sections + template.optionalSections).flatMap(\.fields).first(where: { $0.id == field.id }),
              definition.kind == field.kind, field.label == nil || field.label == definition.label else { return nil }
        let candidates: [String]
        switch field.id {
        case "expiryDate": candidates = ["issueDate", "startDate", "birthDate"]
        case "issueDate": candidates = ["birthDate"]
        case "contractEnd": candidates = ["contractStart"]
        case "warrantyExpiry": candidates = ["warrantyStart"]
        case "renewalDate": candidates = ["startDate"]
        default: return nil
        }
        // Canonical ISO civil dates sort chronologically; validate calendar dates first.
        guard (try? VaultEditor.validateField(field)) != nil else { return nil }
        for id in candidates {
            guard let start = uniqueValue(id, in: revision), !start.isEmpty,
                  let startField = revision.sections.flatMap(\.fields).first(where: { $0.id == id }),
                  let startDefinition = (template.sections + template.optionalSections).flatMap(\.fields).first(where: { $0.id == id }),
                  startDefinition.kind == "date", startField.label == nil || startField.label == startDefinition.label,
                  startField.kind == "date", (try? VaultEditor.validateField(startField)) != nil else { continue }
            if end < start { return .init(.review, "This date is earlier than its related start, issue, or birth date. Check both dates.") }
        }
        return nil
    }

    public func phone(_ raw: String, region: String) -> InputCheck? {
        // Accept decimal digits used by other scripts for comparison, retaining raw input.
        let value = Self.comparisonText(raw).unicodeScalars.map { scalar -> String in
            if scalar.properties.generalCategory == .decimalNumber,
               let digit = Character(String(scalar)).wholeNumberValue { return String(digit) }
            return String(scalar)
        }.joined()
        guard !value.isEmpty else { return nil }
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let international = value.hasPrefix("+")
        if !international && phoneNumbers.countryCode(for: region) == nil {
            return .init(.notChecked, "Choose the phone region or include a + country calling code.")
        }
        // Avoid a permissive parser finding a plausible number inside arbitrary prose.
        guard Self.matches(value, #"\+?[0-9() .\-/]+(?:\s*(?:ext\.?|x|#|;ext=)\s*[0-9]+)?"#, caseInsensitive: true),
              value.count <= 100 else {
            return .init(.review, "Check the phone number, country calling code, and extension.")
        }
        do {
            // PhoneNumberKit requires a known parser region even for + numbers.
            // Derive it from the explicit calling code, never from device locale.
            var parsingRegion = region
            var callingCode: UInt64?
            if international {
                let digits = value.dropFirst().filter { $0.isASCII && $0.isNumber }
                guard digits.first != "0", !digits.isEmpty else { throw PhoneNumberError.invalidCountryCode }
                for length in 1...min(3, digits.count) {
                    if let code = UInt64(digits.prefix(length)), let country = phoneNumbers.mainCountry(forCode: code) {
                        callingCode = code; parsingRegion = country; break
                    }
                }
                guard callingCode != nil else { throw PhoneNumberError.invalidCountryCode }
            }
            let parsed = try phoneNumbers.parse(value, withRegion: parsingRegion)
            if let callingCode, parsed.countryCode != callingCode { throw PhoneNumberError.invalidCountryCode }
            return .init(.matches, "Phone number format matches. Availability is not checked.")
        } catch {
            return .init(.review, "Check the phone number, country calling code, and extension.")
        }
    }

    public func postalCode(_ raw: String, country: String) -> InputCheck? {
        let value = Self.comparisonText(raw).uppercased()
        guard !value.isEmpty else { return nil }
        guard let rule = postalRules[country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] else {
            return .init(.notChecked, "Choose the address country. Postal format is not checked for this region.")
        }
        guard let pattern = rule.pattern else {
            return .init(.notChecked, rule.usesPostalCode
                ? "Postal format is not checked for this region."
                : "This region does not normally use postal codes. The value will be kept.")
        }
        guard value.count <= 100 else { return .init(.review, "Check the postal code for the selected country.") }
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else {
            return .init(.notChecked, "Postal format is not checked for this region.")
        }
        let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        return .init(match ? .matches : .review, match
            ? "Postal code format matches. Address existence is not checked."
            : "Check the postal code for the selected country.")
    }

    public func passport(_ raw: String, issuingCountry: String) -> InputCheck? {
        let value = Self.comparisonText(raw).uppercased()
        guard !value.isEmpty else { return nil }
        let country = issuingCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch country {
        case "JP", "JPN":
            return .init(Self.matches(value, "[A-Z]{2}[0-9]{7}") ? .matches : .review,
                         Self.matches(value, "[A-Z]{2}[0-9]{7}")
                         ? "Passport number format matches. Authenticity and validity are not checked."
                         : "Japanese passports normally use two letters followed by seven digits.")
        case "US", "USA":
            return .init(Self.matches(value, "(?:[A-Z][0-9]{8}|[0-9]{9})") ? .matches : .review,
                         Self.matches(value, "(?:[A-Z][0-9]{8}|[0-9]{9})")
                         ? "Passport number format matches. Authenticity and validity are not checked."
                         : "US passport books normally use nine digits or one letter followed by eight digits.")
        default:
            return .init(.notChecked, "Passport rules vary by issuer. Country-specific checks currently cover Japan and the US.")
        }
    }

    public static func string(_ value: JSONValue) -> String? {
        if case .string(let text) = value { return text }; return nil
    }

    private static func comparisonText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func matches(_ value: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z",
                                                        options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
