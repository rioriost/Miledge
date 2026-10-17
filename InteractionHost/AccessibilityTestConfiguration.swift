import SwiftUI

/// Test-only display overrides. Production views and persistence code are unchanged.
struct AccessibilityTestConfiguration: ViewModifier {
    private let options = ProcessInfo.processInfo.environment
    @Environment(\.dynamicTypeSize) private var systemSize

    private var textSize: DynamicTypeSize {
        switch options["MILEDGE_AX_TEXT"] {
        case "small": .small
        case "large": .large
        case "xxxLarge": .xxxLarge
        case "ax1": .accessibility1
        case "ax3": .accessibility3
        case "ax5": .accessibility5
        default: systemSize
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.dynamicTypeSize, textSize)
    }
}

extension View {
    func accessibilityTestConfiguration() -> some View { modifier(AccessibilityTestConfiguration()) }
}
