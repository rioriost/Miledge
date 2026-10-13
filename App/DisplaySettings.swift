import SwiftUI

#if os(macOS)
import AppKit
#endif

enum DisplayTextSize: Int, CaseIterable, Identifiable {
    #if os(macOS)
    case small = 13
    case standard = 16
    case large = 18
    case extraLarge = 20
    case largest = 24
    #else
    case small = 15
    case standard = 17
    case large = 20
    case extraLarge = 22
    case largest = 26
    #endif

    var id: Int { rawValue }
    var scale: CGFloat { CGFloat(rawValue) / CGFloat(Self.standard.rawValue) }
}

private struct DisplayTextSizeKey: EnvironmentKey {
    static let defaultValue = DisplayTextSize.standard
}

private struct ConcealValuesByDefaultKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var displayTextSize: DisplayTextSize {
        get { self[DisplayTextSizeKey.self] }
        set { self[DisplayTextSizeKey.self] = newValue }
    }

    var concealValuesByDefault: Bool {
        get { self[ConcealValuesByDefaultKey.self] }
        set { self[ConcealValuesByDefaultKey.self] = newValue }
    }
}

enum FieldVisibility {
    static func initiallyRevealed(concealed: Bool, initiallyVisible: Bool, concealByDefault: Bool) -> Bool {
        initiallyVisible || !concealed || !concealByDefault
    }
}

private struct InitialFieldVisibility: ViewModifier {
    @Binding var revealed: Bool
    let concealed: Bool
    let identity: String
    let initiallyVisible: Bool
    @Environment(\.concealValuesByDefault) private var concealByDefault

    private func reset() {
        revealed = FieldVisibility.initiallyRevealed(
            concealed: concealed, initiallyVisible: initiallyVisible, concealByDefault: concealByDefault
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { reset() }
            .onChange(of: concealByDefault) { _, _ in reset() }
            .onChange(of: concealed) { _, _ in reset() }
            .onChange(of: identity) { _, _ in reset() }
    }
}

struct FieldRowLayout: DynamicProperty {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicSize
    @Environment(\.displayTextSize) private var textSize
    #endif

    func layout(auxiliary: Bool = false, alignment: VerticalAlignment = .top) -> AnyLayout {
        #if os(iOS)
        let stacked = sizeClass == .compact && (auxiliary
            ? dynamicSize.isAccessibilitySize && textSize.scale > 1
            : dynamicSize.isAccessibilitySize || textSize.scale > 1)
        if stacked { return AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) }
        #endif
        return AnyLayout(HStackLayout(alignment: alignment, spacing: 8))
    }
}

private struct LedgerFont: ViewModifier {
    @Environment(\.displayTextSize) private var size
    @ScaledMetric private var points: CGFloat
    let weight: Font.Weight

    init(style: Font.TextStyle, weight: Font.Weight?) {
        let base: CGFloat
        switch style {
        case .largeTitle: base = 34
        case .title: base = 28
        case .title2: base = 22
        case .title3: base = 20
        case .caption: base = 12
        case .caption2: base = 11
        case .subheadline: base = 15
        default:
            #if os(macOS)
            base = 16
            #else
            base = 17
            #endif
        }
        _points = ScaledMetric(wrappedValue: base, relativeTo: style)
        self.weight = weight ?? (style == .headline ? .semibold : .regular)
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        let minimum: CGFloat = 10
        #else
        let minimum: CGFloat = 11
        #endif
        content.font(.system(size: max(minimum, points * size.scale), weight: weight))
    }
}

private struct FieldControlFrame: ViewModifier {
    @Environment(\.displayTextSize) private var size
    #if os(iOS)
    @ScaledMetric private var height: CGFloat = 44
    #else
    @ScaledMetric private var height: CGFloat = 36
    #endif
    var square: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        let minimum: CGFloat = 44
        #else
        let minimum: CGFloat = 28
        #endif
        let dimension = max(minimum, height * size.scale)
        content.frame(minWidth: square ? dimension : nil, minHeight: dimension)
    }
}

struct DisplayPreferences: ViewModifier {
    @AppStorage("displayTextSize") private var size = DisplayTextSize.standard
    @AppStorage("concealValuesByDefault") private var concealByDefault = true

    func body(content: Content) -> some View {
        content.ledgerFont(.body).environment(\.displayTextSize, size)
            .environment(\.concealValuesByDefault, concealByDefault)
    }
}

extension View {
    func ledgerFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(LedgerFont(style: style, weight: weight))
    }

    func fieldControlFrame(square: Bool = false) -> some View {
        modifier(FieldControlFrame(square: square))
    }

    func displayPreferences() -> some View {
        modifier(DisplayPreferences())
    }

    func initialFieldVisibility(
        revealed: Binding<Bool>, concealed: Bool, identity: String, initiallyVisible: Bool = false
    ) -> some View {
        modifier(InitialFieldVisibility(
            revealed: revealed, concealed: concealed, identity: identity, initiallyVisible: initiallyVisible
        ))
    }

    @ViewBuilder
    func resizeForDisplayText() -> some View {
        #if os(macOS)
        modifier(DisplayWindowSizing())
        #else
        self
        #endif
    }
}

struct DisplaySettingsView: View {
    @AppStorage("displayTextSize") private var size = DisplayTextSize.standard
    @AppStorage("concealValuesByDefault") private var concealByDefault = true

    var body: some View {
        Form {
            Picker("Font size", selection: $size) {
                ForEach(DisplayTextSize.allCases) { size in
                    Text("\(size.rawValue) pt").tag(size)
                }
            }
            .accessibilityIdentifier("display-font-size")
            Text("Sample text: Aa 0123456789")
                .ledgerFont(.body)
                .accessibilityIdentifier("display-font-preview")
            Toggle("Conceal by default", isOn: $concealByDefault)
                .accessibilityIdentifier("display-conceal-values")
        }
        .formStyle(.grouped)
        .navigationTitle("Display")
        #if os(macOS)
        .frame(width: 400 * size.scale, height: 240 * size.scale)
        #else
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                DisplaySettingsDoneButton()
            }
        }
        #endif
        .displayPreferences()
    }
}

#if os(iOS)
private struct DisplaySettingsDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Done") { dismiss() } }
}
#endif

#if os(macOS)
private struct DisplayWindowSizing: ViewModifier {
    @Environment(\.displayTextSize) private var size
    func body(content: Content) -> some View {
        content.background(WindowFontSizer(scale: size.scale).frame(width: 0, height: 0))
    }
}

struct WindowFontSizer: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> FontSizingView { FontSizingView() }
    func updateNSView(_ view: FontSizingView, context: Context) {
        view.requestedScale = scale
        DispatchQueue.main.async { [weak view] in view?.applySize() }
    }

    final class FontSizingView: NSView {
        var requestedScale: CGFloat = 1
        private var previousScale: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySize()
        }

        func applySize() {
            guard let window else { return }
            defer { previousScale = requestedScale }
            guard let previousScale, previousScale != requestedScale else { return }
            Self.resize(window, ratio: requestedScale / previousScale)
        }

        static func resize(_ window: NSWindow, ratio: CGFloat) {
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let available = screen.visibleFrame
            let current = window.frame
            let content = window.contentRect(forFrameRect: current)
            let chrome = current.height - content.height
            let minimum = window.contentMinSize
            let width = min(available.width, max(minimum.width, content.width * ratio))
            let height = min(available.height, max(minimum.height + chrome, content.height * ratio + chrome))
            let frame = NSRect(
                x: min(max(current.minX, available.minX), available.maxX - width),
                y: min(max(current.maxY - height, available.minY), available.maxY - height),
                width: width, height: height
            )
            window.setFrame(frame, display: true)
        }
    }
}
#endif
