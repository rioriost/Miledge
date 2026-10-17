import SwiftUI

/// A visible editing surface, including when a field has no value or placeholder.
@MainActor
struct LedgerTextFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .ledgerInputSurface()
    }
}

private struct LedgerInputSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6)
                    #if os(macOS)
                    .fill(Color(nsColor: .textBackgroundColor))
                    #else
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    #endif
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary, lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func ledgerInputSurface() -> some View { modifier(LedgerInputSurface()) }
}
