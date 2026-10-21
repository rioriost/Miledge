import MiledgeApplication
import MiledgeDomain
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
enum MacFieldInputSource {
    case unrestricted, roman

    var allowedLocales: [String]? {
        self == .roman ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    func apply(to editor: NSTextView) {
        if editor.allowedInputSourceLocales != allowedLocales {
            editor.allowedInputSourceLocales = allowedLocales
        }
    }
}

@MainActor
private enum MacFieldTextEditing {
    static func configure(_ editor: NSTextView) {
        editor.allowsUndo = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
    }
}

private enum MacFieldTextGeometry {
    static func centered(_ rect: NSRect, in bounds: NSRect, font: NSFont?) -> NSRect {
        let height = min(rect.height, NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: 16)))
        return NSRect(x: rect.minX, y: bounds.midY - height / 2, width: rect.width, height: height)
    }
}

private final class MacFieldCell: NSTextFieldCell {
    var inputSource = MacFieldInputSource.unrestricted

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        guard let view = editor as? NSTextView else {
            preconditionFailure("Mac text fields require a native text-view field editor")
        }
        // Configure the shared editor before focus/IME activation, not after the first keystroke.
        inputSource.apply(to: view)
        return editor
    }

    override func endEditing(_ textObj: NSText) {
        super.endEditing(textObj)
        if let editor = textObj as? NSTextView {
            MacFieldInputSource.unrestricted.apply(to: editor)
        }
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        MacFieldTextGeometry.centered(super.drawingRect(forBounds: rect), in: rect, font: font)
    }
}

private final class MacSecureFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        MacFieldTextGeometry.centered(super.drawingRect(forBounds: rect), in: rect, font: font)
    }
}

// Grouped SwiftUI forms override single-line alignment and width, even with explicit text alignment.
struct MacFieldInput: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var placeholder: String? = nil
    var alignment: NSTextAlignment = .left
    var secure = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    var inputSource = MacFieldInputSource.unrestricted
    @Environment(\.displayTextSize) private var size
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var points: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 36

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    func makeNSView(context: Context) -> NSTextField {
        let view = secure ? NSSecureTextField() : NSTextField()
        view.cell = secure ? MacSecureFieldCell(textCell: "") : MacFieldCell(textCell: "")
        view.isEditable = true
        view.isSelectable = true
        view.isBezeled = true
        view.bezelStyle = .roundedBezel
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 1
        view.controlSize = .large
        view.usesSingleLineMode = true
        view.cell?.isScrollable = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        context.coordinator.input = self
        view.font = .systemFont(ofSize: max(10, points * size.scale))
        view.alignment = alignment
        view.isEnabled = enabled
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
        }
        view.placeholderString = placeholder
        view.setAccessibilityLabel(label)
        if let cell = view.cell as? MacFieldCell { cell.inputSource = inputSource }
        if view.stringValue != text { view.stringValue = text }
        if let editor = view.currentEditor() as? NSTextView {
            editor.alignment = alignment
            editor.font = view.font
            if !secure { inputSource.apply(to: editor) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: max(nsView.intrinsicContentSize.height, max(28, height * size.scale)))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: MacFieldInput
        init(input: MacFieldInput) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else {
                preconditionFailure("Text editing notifications must identify their text field")
            }
            input.text = view.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { input.onEditingChanged(false) }

        func controlTextDidBeginEditing(_ notification: Notification) {
            input.onEditingChanged(true)
            guard let view = notification.object as? NSTextField else {
                preconditionFailure("Text editing notifications must identify their text field")
            }
            if let editor = view.currentEditor() as? NSTextView {
                MacFieldTextEditing.configure(editor)
            }
        }
    }
}

struct MacMultilineFieldInput: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var alignment: NSTextAlignment = .left
    var inputSource = MacFieldInputSource.unrestricted
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.displayTextSize) private var size
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var points: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        guard let editor = scroll.documentView as? NSTextView else {
            preconditionFailure("Mac multiline fields require a native text view")
        }
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.delegate = context.coordinator
        MacFieldTextEditing.configure(editor)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.input = self
        guard let editor = view.documentView as? NSTextView else {
            preconditionFailure("Mac multiline fields require a native text view")
        }
        editor.font = .systemFont(ofSize: max(10, points * size.scale))
        editor.alignment = alignment
        editor.isEditable = enabled
        inputSource.apply(to: editor)
        editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var input: MacMultilineFieldInput
        init(input: MacMultilineFieldInput) { self.input = input }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else {
                preconditionFailure("Text editing notifications must identify their text view")
            }
            input.text = editor.string
        }

        func textDidBeginEditing(_ notification: Notification) { input.onEditingChanged(true) }
        func textDidEndEditing(_ notification: Notification) { input.onEditingChanged(false) }
    }
}
#endif

struct FieldRevealButton: View {
    @Binding var revealed: Bool
    let field: VaultField
    @Environment(\.locale) private var locale

    private var actionName: String {
        FieldPresentation.action(revealed ? "Hide %@" : "Reveal %@", field: field, locale: locale)
    }

    var body: some View {
        Button { revealed.toggle() } label: {
            Text(LocalizedStringKey(revealed ? "Hide" : "Reveal"))
                .fieldControlFrame()
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: actionName))
        .accessibilityIdentifier("field-visibility")
        .help(Text(verbatim: actionName))
    }
}

struct StringFieldInput: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool
    @State var text: String
    let templateID: String?
    let initiallyVisible: Bool
    @State private var pendingWrites: [JSONValue] = []
    @FocusState private var focused: Bool
    private let onEditingChanged: (Bool) -> Void
    @State private var revealed: Bool
    @State private var urlSuggestion: String?
    @State private var editing = false
    @Environment(\.locale) private var locale
    private var rowLayout = FieldRowLayout()

    init(field: Binding<VaultField>, invalid: Binding<Bool>, text: String, templateID: String? = nil,
         initiallyVisible: Bool = false, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _field = field
        _invalid = invalid
        _text = State(initialValue: text)
        self.templateID = templateID
        self.onEditingChanged = onEditingChanged
        self.initiallyVisible = initiallyVisible
        _revealed = State(initialValue: initiallyVisible || !field.wrappedValue.concealed)
    }

    private var format: StructuredInput? { StructuredInput.format(for: field, templateID: templateID) }

    private var multiline: Bool {
        ["multiline", "key-material"].contains(field.kind) || text.contains("\n") || text.contains("\r")
    }

    // Only a user edit writes the model. Synchronizing an externally replaced field
    // must never send a stale @State value back through the field binding.
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { value in
            text = value
            let replacement = JSONValue.string(value)
            if pendingWrites.last != replacement { pendingWrites.append(replacement) }
            field.value = replacement
            invalid = false
        })
    }

    var body: some View {
        let layout = rowLayout.layout(alignment: multiline ? .top : .center)
        VStack(alignment: .leading, spacing: 4) {
            layout {
                value
                    .fieldControlFrame()
                    .multilineTextAlignment(field.kind == "number" ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if field.concealed { FieldRevealButton(revealed: $revealed, field: field) }
            }
            if revealed, !multiline, format == .port {
                Menu("Common ports") {
                    ForEach(StructuredInput.portChoices(fieldID: field.id), id: \.value) { choice in
                        Button(choice.label) {
                            textBinding.wrappedValue = choice.value
                            editingChanged(false)
                        }
                            .accessibilityIdentifier("port-option-" + choice.value)
                    }
                }
                .accessibilityIdentifier("port-suggestions-" + field.id)
                .help("Choose the port specified by your server provider.")
            }
            if revealed, !editing, let suggestion = urlSuggestion {
                Button("Add https://") {
                    textBinding.wrappedValue = suggestion
                    editingChanged(false)
                }
                    .accessibilityIdentifier("url-add-scheme-" + field.id)
            }
            if let hint = FieldPresentation.formatHint(for: field.kind), field.kind == "number" || invalid {
                Text(LocalizedStringKey(hint))
                    .ledgerFont(.caption)
                    .foregroundStyle(invalid ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if invalid {
                Text("Check the value and format.").ledgerFont(.caption).foregroundStyle(.red)
            }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(keyboardType)
        .textContentType(contentType)
        #endif
        .onChange(of: focused) { _, focused in editingChanged(focused) }
        .onAppear { refreshURLSuggestion() }
        .onDisappear { editingChanged(false) }
        .onChange(of: field.value) { _, value in
            if let index = pendingWrites.lastIndex(of: value) {
                pendingWrites.removeFirst(index + 1)
                return
            }
            pendingWrites.removeAll()
            if case .string(let replacement) = value, replacement != text {
                text = replacement
                invalid = false
            }
        }
        .onChange(of: field.id) { _, _ in
            pendingWrites.removeAll()
            if case .string(let replacement) = field.value { text = replacement }
            invalid = false
        }
        .initialFieldVisibility(
            revealed: $revealed, concealed: field.concealed, identity: field.id, initiallyVisible: initiallyVisible
        )
    }

    private func refreshURLSuggestion() {
        urlSuggestion = format == .url ? StructuredInput.httpsSuggestion(text) : nil
    }

    private func editingChanged(_ active: Bool) {
        editing = active
        if !active { refreshURLSuggestion() }
        onEditingChanged(active)
    }

    @ViewBuilder
    private var value: some View {
        if !revealed {
            if multiline {
                Text("Concealed").accessibilityLabel("Concealed value")
                    .accessibilityIdentifier("field-input-\(field.id)")
            } else {
                singleLine(secure: true)
            }
        } else if multiline {
            #if os(macOS)
            if FieldPresentation.usesRomanInput(for: field.kind) {
                MacMultilineFieldInput(
                    text: textBinding, label: FieldPresentation.name(for: field, locale: locale),
                    alignment: field.kind == "number" ? .right : .left, inputSource: .roman,
                    onEditingChanged: editingChanged
                )
                .frame(minHeight: 100, idealHeight: 120, maxHeight: 180)
                .ledgerInputSurface()
                .accessibilityIdentifier("field-input-\(field.id)")
            } else {
                multilineInput
            }
            #else
            multilineInput
            #endif
        } else if ["date", "year-month"].contains(field.kind) {
            CalendarFieldInput(
                text: textBinding, kind: field.kind, label: FieldPresentation.name(for: field, locale: locale),
                identifier: field.id, onEditingChanged: editingChanged
            )
        } else if !FieldSelectionCatalog.choices(for: field, templateID: templateID, locale: locale).isEmpty {
            ChoiceFieldInput(
                text: textBinding, choices: FieldSelectionCatalog.choices(for: field, templateID: templateID, locale: locale),
                label: FieldPresentation.name(for: field, locale: locale), identifier: field.id,
                searchable: FieldSelectionCatalog.countryIDs.contains(field.id) || field.id == "currency",
                onEditingChanged: editingChanged
            )
        } else {
            singleLine(secure: false)
        }
    }

    private var multilineInput: some View {
        TextEditor(text: textBinding)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .ledgerInputSurface()
            .frame(minHeight: 100, idealHeight: 120, maxHeight: 180)
            .accessibilityLabel(Text(verbatim: FieldPresentation.name(for: field, locale: locale)))
            .accessibilityIdentifier("field-input-\(field.id)")
    }

    @ViewBuilder
    private func singleLine(secure: Bool) -> some View {
        #if os(macOS)
        MacFieldInput(
            text: textBinding, label: FieldPresentation.name(for: field, locale: locale),
            placeholder: promptString, alignment: field.kind == "number" ? .right : .left, secure: secure,
            onEditingChanged: editingChanged,
            inputSource: FieldPresentation.usesRomanInput(for: field.kind) ? .roman : .unrestricted
        )
        .id(secure)
        .accessibilityIdentifier("field-input-\(field.id)")
        #else
        if secure {
            SecureField("", text: textBinding, prompt: prompt)
                .focused($focused)
                .accessibilityLabel(Text(verbatim: FieldPresentation.name(for: field, locale: locale)))
                .accessibilityIdentifier("field-input-\(field.id)")
        } else {
            TextField("", text: textBinding, prompt: prompt)
                .focused($focused)
                .accessibilityLabel(Text(verbatim: FieldPresentation.name(for: field, locale: locale)))
                .accessibilityIdentifier("field-input-\(field.id)")
        }
        #endif
    }

    private var promptString: String? {
        switch field.kind {
        case "date": "YYYY-MM-DD"
        case "year-month": "YYYY-MM"
        default: format?.example
        }
    }

    private var prompt: Text? {
        promptString.map { Text(verbatim: $0) }
    }

    #if os(iOS)
    private var contentType: UITextContentType? {
        switch format {
        case .email: .emailAddress
        case .url: .URL
        case .cardNumber: .creditCardNumber
        default: field.kind == "phone" ? .telephoneNumber : nil
        }
    }

    private var keyboardType: UIKeyboardType {
        if format?.usesDigits == true { return .asciiCapableNumberPad }
        if [.iban, .bic, .vin, .otpSeed].contains(format) { return .asciiCapable }
        return switch field.kind {
        case "email": .emailAddress
        case "url": .URL
        case "phone": .phonePad
        // decimalPad omits the minus sign. Keep both signs and a decimal separator
        // available, and retain the exact string instead of passing through Double.
        case "number", "date", "year-month": .numbersAndPunctuation
        default: .default
        }
    }
    #endif
}

struct BooleanFieldInput: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool
    @State var value: Bool
    @State private var revealed: Bool
    let initiallyVisible: Bool
    @Environment(\.locale) private var locale

    init(field: Binding<VaultField>, invalid: Binding<Bool>, value: Bool, initiallyVisible: Bool = false) {
        _field = field
        _invalid = invalid
        _value = State(initialValue: value)
        self.initiallyVisible = initiallyVisible
        _revealed = State(initialValue: initiallyVisible || !field.wrappedValue.concealed)
    }

    private var valueBinding: Binding<Bool> {
        Binding(get: { value }, set: { value in
            self.value = value
            field.value = .bool(value)
            invalid = false
        })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !revealed {
                Text("Concealed").accessibilityLabel("Concealed value")
            } else {
                Toggle("Value", isOn: valueBinding)
                    .accessibilityLabel(Text(verbatim: FieldPresentation.name(for: field, locale: locale)))
                    .accessibilityIdentifier("field-input-\(field.id)")
            }
            if field.concealed { FieldRevealButton(revealed: $revealed, field: field) }
        }
        .fieldControlFrame()
        .onChange(of: field.value) { _, replacement in
            if case .bool(let replacement) = replacement { value = replacement; invalid = false }
        }
        .initialFieldVisibility(
            revealed: $revealed, concealed: field.concealed, identity: field.id, initiallyVisible: initiallyVisible
        )
        if invalid {
            Text("Check the value and format.").ledgerFont(.caption).foregroundStyle(.red)
        }
    }
}
