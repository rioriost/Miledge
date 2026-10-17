import MiledgeDomain

/// Synthetic data only; no Keychain or network access.
enum InternationalInputFixture {
    static func make(_ scenario: String) -> VaultRevision {
        switch scenario {
        case "international-passport":
            return .init(templateId: "passport", title: "Synthetic passport", sections: [
                .init(id: "passport", fields: [
                    .init(id: "passportNumber", value: .string("AB0123456")),
                    .init(id: "issuingCountry", value: .string("US"))
                ])
            ])
        case "international-phone":
            return .init(templateId: "identity", title: "Synthetic phone", sections: [
                .init(id: "identity", fields: [.init(id: "phone", kind: "phone", value: .string("03-1234-5678"))])
            ])
        case "international-address":
            return .init(templateId: "identity", title: "Synthetic address", sections: [
                .init(id: "identity", fields: [.init(id: "address", kind: "address", value: .object([:]))])
            ])
        default:
            let value = VaultRevision(templateId: "identity", title: "Synthetic names", sections: [
                .init(id: "identity", fields: [.init(id: "name", value: .string("山田 Alex 太郎"))]),
                .init(id: "optional", fields: [
                    .init(id: "givenName", value: .string("太郎")),
                    .init(id: "familyName", value: .string("山田"))
                ])
            ])
            if scenario == "international-names-complete" {
                return try! VaultEditor.addingSection(id: "template:identity:name-details", to: value)
            }
            return value
        }
    }
}
