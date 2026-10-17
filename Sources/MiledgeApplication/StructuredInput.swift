import Foundation
import Darwin
import MiledgeDomain

/// Semantics come from an explicit kind or a known, unchanged template field, never its display name.
public enum StructuredInput: String, Sendable {
    case email, url, cardNumber, cardSecurityCode, iban, bic, port, vin, otpSeed

    public static func format(for field: VaultField, templateID: String?) -> Self? {
        switch field.kind {
        case "email": return .email
        case "url": return .url
        case "otp-seed": return .otpSeed
        default: break
        }
        guard let templateID, let template = TemplateCatalog.template(id: templateID),
              let definition = (template.sections + template.optionalSections).flatMap(\.fields).first(where: { $0.id == field.id }),
              definition.kind == field.kind, field.label == nil || field.label == definition.label else { return nil }
        switch (templateID, field.id) {
        case ("credit-card", "cardNumber"): return .cardNumber
        case ("credit-card", "verificationNumber"): return .cardSecurityCode
        case ("bank-account", "iban"): return .iban
        case ("bank-account", "swiftBic"): return .bic
        case ("database", "port"), ("email-account", "incomingPort"), ("email-account", "outgoingPort"): return .port
        case ("vehicle-record", "vin"): return .vin
        default: return nil
        }
    }

    public var example: String? {
        switch self {
        case .email: "name@example.com"
        case .url: "https://example.com"
        case .port: "1–65535"
        // Do not suggest a dummy secret that could be mistaken for the user's real value.
        default: nil
        }
    }

    public var usesDigits: Bool { [.cardNumber, .cardSecurityCode, .port].contains(self) }

    public static func portChoices(fieldID: String) -> [(label: String, value: String)] {
        switch fieldID {
        case "incomingPort": [("IMAP TLS — 993", "993"), ("POP3 TLS — 995", "995"), ("IMAP — 143", "143"), ("POP3 — 110", "110")]
        case "outgoingPort": [("SMTP Submission — 587", "587"), ("SMTP TLS — 465", "465"), ("SMTP — 25", "25")]
        default: [("PostgreSQL — 5432", "5432"), ("MySQL / MariaDB — 3306", "3306"), ("Microsoft SQL Server — 1433", "1433"), ("Oracle — 1521", "1521"), ("MongoDB — 27017", "27017"), ("Redis — 6379", "6379")]
        }
    }

    /// Offer a deliberate edit only for an unambiguous schemeless web address.
    public static func httpsSuggestion(_ raw: String) -> String? {
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains(":"), !raw.contains("@"), !raw.hasPrefix("/"),
              let host = raw.split(separator: "/", maxSplits: 1).first, host.contains("."),
              StructuredChecks.url("https://" + raw)?.status == .matches else { return nil }
        return "https://" + raw
    }
}

/// Bounded syntax/check-digit checks only. Results never include the supplied value.
public enum StructuredChecks {
    public static func check(_ format: StructuredInput, text: String, context: String = "") -> InputCheck? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Bound work before normalization or regex parsing; imports may contain arbitrarily large strings.
        guard text.utf8.count <= 4096 else { return .init(.notChecked, "This value is too long for a format check. It will be kept.") }
        switch format {
        case .email: return email(text)
        case .url: return url(text)
        case .cardNumber: return card(text, brand: context)
        case .cardSecurityCode: return securityCode(text, brand: context)
        case .iban: return iban(text)
        case .bic: return bic(text)
        case .port: return port(text)
        case .vin: return vin(text, country: context)
        case .otpSeed: return otp(text)
        }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
    static func compact(_ text: String) -> String {
        // Spaces are presentation separators in these specific formats. Stored text is untouched.
        text.filter { !$0.isWhitespace }.asciiUppercased
    }
    static func result(_ valid: Bool, _ error: String, success: String = "Format matches. Existence and validity are not checked.") -> InputCheck {
        .init(valid ? .matches : .review, valid ? success : error)
    }

    static func email(_ text: String) -> InputCheck {
        let error = "Check the email address: name@example.com."
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .init(.review, error) }
        // RFC 5322 quoted local parts, comments, domain literals and EAI need a fuller parser.
        // Preserve these as unchecked instead of rejecting legitimate addresses.
        if text.contains("\"") || text.contains("(") || text.contains("[") || !text.isASCII {
            return .init(.notChecked, "This email format is not checked. The address will be kept.")
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .init(.review, error) }
        let local = String(parts[0]), domain = String(parts[1])
        let atom = #"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let valid = matches(local, atom + "(?:\\." + atom + ")*") && hostname(domain)
        return result(valid, error)
    }

    static func hostname(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        let value = text.hasSuffix(".") ? String(text.dropLast()) : text
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            matches(String($0), "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
        }
    }

    static func url(_ text: String) -> InputCheck? {
        guard !text.isEmpty else { return nil }
        let error = "Check the URL, including its scheme, such as https://."
        guard text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              matches(text, #"[A-Za-z][A-Za-z0-9+.-]*:.+"#),
              !text.contains("\\"),
              text.range(of: #"%(?![0-9A-Fa-f]{2})"#, options: .regularExpression) == nil,
              let components = URLComponents(string: text), let scheme = components.scheme else { return .init(.review, error) }
        if ["http", "https", "ftp"].contains(scheme.lowercased()) {
            guard text.dropFirst(scheme.count + 1).hasPrefix("//"),
                  let host = components.host, !host.isEmpty,
                  let url = components.url, url.host != nil else { return .init(.review, error) }
            // Foundation handles IDNA and IPv6; ports in a URL may be zero per URI syntax.
            if let port = components.port, !(0...65535).contains(port) { return .init(.review, error) }
            let asciiHost = url.host ?? host
            if host.hasPrefix("[") {
                var address = in6_addr()
                let literal = String(asciiHost.split(separator: "%", maxSplits: 1).first ?? "")
                guard inet_pton(AF_INET6, literal, &address) == 1 else { return .init(.review, error) }
            } else if !hostname(asciiHost) { return .init(.review, error) }
        } else {
            return .init(.notChecked, "The URL scheme is recognized syntactically. Service-specific rules are not checked.")
        }
        return result(true, error)
    }

    static func card(_ text: String, brand: String) -> InputCheck {
        let value = compact(text).replacingOccurrences(of: "-", with: "")
        let error = "Check the card number length, digits, and check digit."
        guard matches(value, "[0-9]{12,19}"), value.contains(where: { $0 != "0" }) else { return .init(.review, error) }
        let digits = value.reversed().map { Int(String($0))! }
        let total = digits.enumerated().reduce(0) { sum, pair in
            let doubled = pair.element * (pair.offset % 2 == 1 ? 2 : 1)
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        if total % 10 != 0 && brand == "UnionPay" {
            return .init(.notChecked, "This card brand may use different check-digit rules. Confirm the number with the issuer.")
        }
        return result(total % 10 == 0, error, success: "Card check digit matches. Card validity and issuer are not checked.")
    }

    static func securityCode(_ text: String, brand: String) -> InputCheck {
        let threeDigitBrands = ["Visa", "Mastercard", "JCB", "Diners Club", "Discover"]
        let length = brand == "American Express" ? "4" : (threeDigitBrands.contains(brand) ? "3" : "3,4")
        return result(matches(text, "[0-9]{" + length + "}"), "Security codes usually contain three digits; American Express uses four.")
    }

    static func iban(_ text: String) -> InputCheck {
        let value = compact(text)
        let error = "Check the IBAN letters, digits, and check digits."
        guard matches(value, "[A-Z]{2}[0-9]{2}[A-Z0-9]{1,30}"),
              let checkDigits = Int(value.dropFirst(2).prefix(2)), (2...98).contains(checkDigits) else { return .init(.review, error) }
        let rotated = value.dropFirst(4) + value.prefix(4)
        var remainder = 0
        for byte in rotated.utf8 {
            let value = byte >= 65 ? Int(byte - 55) : Int(byte - 48)
            remainder = (remainder * (value >= 10 ? 100 : 10) + value) % 97
        }
        return result(remainder == 1, error, success: "IBAN check digits match. National format and account existence are not checked.")
    }

    static func bic(_ text: String) -> InputCheck {
        result(matches(text.asciiUppercased, "[A-Z0-9]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?"),
               "BIC uses eight or eleven letters and digits, with a two-letter country code.")
    }

    static func port(_ text: String) -> InputCheck {
        result(matches(text, "[0-9]{1,5}") && (Int(text).map { (1...65535).contains($0) } ?? false),
               "Enter a server port from 1 to 65535.")
    }

    static func vin(_ text: String, country: String) -> InputCheck {
        let value = text.asciiUppercased
        guard matches(value, "[A-HJ-NPR-Z0-9]{17}") else {
            return .init(.review, "Modern VINs use 17 letters and digits without I, O, or Q. Older or local chassis numbers may differ.")
        }
        guard ["US", "USA"].contains(country.uppercased()) else {
            return .init(.matches, "VIN format matches. Regional check digits and vehicle existence are not checked.")
        }
        let letters = Array("ABCDEFGHJKLMNPRSTUVWXYZ")
        let numbers = [1,2,3,4,5,6,7,8,1,2,3,4,5,7,9,2,3,4,5,6,7,8,9]
        let map = Dictionary(uniqueKeysWithValues: zip(letters, numbers))
        let weights = [8,7,6,5,4,3,2,10,0,9,8,7,6,5,4,3,2]
        let sum = zip(value, weights).reduce(0) { $0 + (map[$1.0] ?? $1.0.wholeNumberValue!) * $1.1 }
        let expected = sum % 11 == 10 ? "X" : String(sum % 11)
        return result(String(Array(value)[8]) == expected, "Check the ninth VIN character for a US-registered vehicle.")
    }

    static func otp(_ text: String) -> InputCheck {
        let value = compact(text)
        let error = "Check the Base32 secret: letters A–Z and digits 2–7."
        if value.hasPrefix("OTPAUTH:") { return .init(.notChecked, "Enter the secret key here, rather than the whole otpauth URL.") }
        guard matches(value, "[A-Z2-7]+=*") else { return .init(.review, error) }
        let data = value.prefix { $0 != "=" }
        let padding = value.count - data.count
        let expectedPadding = [0:0, 2:6, 4:4, 5:3, 7:1][data.count % 8]
        guard let expectedPadding, padding == 0 || padding == expectedPadding else { return .init(.review, error) }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let tail = alphabet.firstIndex(of: data.last!)!
        let unusedBits = (data.count * 5) % 8
        return result(tail % (1 << unusedBits) == 0, error)
    }
}

private extension String {
    var isASCII: Bool { unicodeScalars.allSatisfy(\.isASCII) }
    // Unicode case expansion (for example ß → SS) must not make a non-ASCII identifier pass.
    var asciiUppercased: String {
        String(decoding: utf8.map { (97...122).contains($0) ? $0 - 32 : $0 }, as: UTF8.self)
    }
}
