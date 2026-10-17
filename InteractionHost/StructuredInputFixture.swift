import MiledgeDomain

/// Public test numbers and reserved example domains only; never reads the user's Keychain.
enum StructuredInputFixture {
    static func make(_ scenario: String) -> VaultRevision {
        switch scenario {
        case "format-email":
            .init(templateId: "identity", title: "Synthetic email", sections: [.init(id: "identity", fields: [
                .init(id: "email", kind: "email", value: .string("name..test@example.com")),
                .init(id: "name", value: .string("Synthetic person"))
            ])])
        case "format-card":
            .init(templateId: "credit-card", title: "Synthetic card", sections: [.init(id: "card", fields: [
                .init(id: "brand", kind: "select", value: .string("Visa")),
                .init(id: "cardNumber", value: .string("4242 4242 4242 4241"), concealed: true),
                .init(id: "verificationNumber", kind: "concealed", value: .string("123"), concealed: true)
            ])])
        case "format-bank":
            .init(templateId: "bank-account", title: "Synthetic bank", sections: [.init(id: "optional", fields: [
                .init(id: "iban", value: .string("GB83 WEST 1234 5698 7654 32"), concealed: true),
                .init(id: "swiftBic", value: .string("DEUTDEFF"))
            ])])
        case "format-dates":
            .init(templateId: "passport", title: "Synthetic dates", sections: [.init(id: "optional", fields: [
                .init(id: "issueDate", kind: "date", value: .string("2026-10-17")),
                .init(id: "expiryDate", kind: "date", value: .string("2025-10-17"))
            ])])
        default:
            .init(templateId: "database", title: "Synthetic server", sections: [.init(id: "optional", fields: [
                .init(id: "url", kind: "url", value: .string("example.com")),
                .init(id: "port", value: .string("70000")),
                .init(id: "email", kind: "email", value: .string("name..test@example.com"))
            ])])
        }
    }
}
