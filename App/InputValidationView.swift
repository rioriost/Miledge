import MiledgeApplication
import MiledgeDomain
import SwiftUI

struct InputCheckFeedback: View {
    let check: InputCheck
    var identifier = "input-check"
    @Environment(\.locale) private var locale
    private var message: String { String(localized: String.LocalizationValue(check.message), locale: locale) }

    private var symbol: String {
        switch check.status {
        case .matches: "checkmark.circle"
        case .review: "exclamationmark.triangle"
        case .notChecked: "info.circle"
        }
    }

    var body: some View {
        Label { Text(verbatim: message) } icon: { Image(systemName: symbol) }
            .ledgerFont(.caption)
            .foregroundStyle(check.status == .review ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text(verbatim: message))
            .accessibilityIdentifier(identifier)
    }
}
