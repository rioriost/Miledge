import MiledgeApplication
import MiledgeDomain
import SwiftUI

struct EditorFieldID: Hashable {
    let section: String
    let field: String
}

enum EditorSectionName {
    static func name(for id: String) -> LocalizedStringKey {
        switch id.split(separator: ":").last.map(String.init) ?? id {
        case "note", "notes": "Notes"
        case "credentials", "optional-credentials": "Credentials"
        case "optional": "Additional information"
        case "original-notation": "Original notation"
        default: "Details"
        }
    }
}

enum FieldKindName {
    static func name(for kind: String) -> LocalizedStringKey {
        switch kind {
        case "string": "Text"
        case "concealed": "Concealed text"
        case "multiline": "Multiline text"
        case "url": "URL"
        case "email": "Email"
        case "phone": "Phone"
        case "address": "Address"
        case "date": "Date"
        case "year-month": "Month"
        case "number": "Decimal number"
        case "select": "Choice"
        case "multi-select": "Multiple choices"
        case "otp-seed": "OTP seed"
        case "key-material": "Key material"
        case "boolean": "Boolean"
        case "recovery-codes": "Recovery codes"
        default: "Unsupported field"
        }
    }
}

struct EditableField: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool

    var onRemove: (() -> Void)?
    let templateID: String?
    let initiallyVisible: Bool
    var copy: ((JSONValue) -> Bool)?
    @State private var copied = false
    @Environment(\.locale) private var locale
    private var rowLayout = FieldRowLayout()

    init(field: Binding<VaultField>, invalid: Binding<Bool> = .constant(false), templateID: String? = nil,
         initiallyVisible: Bool = false, copy: ((JSONValue) -> Bool)? = nil, onRemove: (() -> Void)? = nil) {
        _field = field
        _invalid = invalid
        self.onRemove = onRemove
        self.templateID = templateID
        self.initiallyVisible = initiallyVisible
        self.copy = copy
    }

    private var isCustom: Bool { UUID(uuidString: field.id) != nil }
    private var compact: Bool {
        guard !isCustom, !["multiline", "key-material", "address", "multi-select", "recovery-codes"].contains(field.kind) else { return false }
        if case .string(let value) = field.value { return !value.contains("\n") && !value.contains("\r") }
        return true
    }

    var body: some View {
        Group {
            #if os(macOS)
            if compact {
                LabeledContent {
                    inputAndOptions
                } label: {
                    FieldLabel(field: field)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .labeledContentStyle(EditorFieldLabelStyle())
            } else {
                stacked
            }

            #else
            stacked
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: field) { _, _ in copied = false }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    #if os(macOS)
    private struct EditorFieldLabelStyle: LabeledContentStyle {
        @Environment(\.displayTextSize) private var size

        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .top, spacing: 12) {
                configuration.label
                    .fieldControlFrame()
                    .frame(width: 140 * size.scale, alignment: .leading)
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    #endif

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCustom {
                #if os(macOS)
                MacFieldInput(
                    text: Binding(get: { field.label ?? "" }, set: { field.label = $0 }),
                    label: FieldPresentation.action("Field name for %@", field: field, locale: locale),
                    placeholder: String(localized: "Field name", locale: locale)
                )
                #else
                TextField("Field name", text: Binding(
                    get: { field.label ?? "" }, set: { field.label = $0 }
                ))
                .multilineTextAlignment(.leading)
                .fieldControlFrame()
                .accessibilityLabel(Text(verbatim: FieldPresentation.action("Field name for %@", field: field, locale: locale)))
                #endif
                Text(FieldKindName.name(for: field.kind)).ledgerFont(.caption).foregroundStyle(.secondary)
            } else {
                FieldLabel(field: field).ledgerFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            inputAndOptions
        }
    }

    private var inputAndOptions: some View {
        let layout = rowLayout.layout()
        return layout {
            Group {
                if VaultEditor.supportedKinds.contains(field.kind) {
                    input.id(field.id)
                } else {
                    Label("Unsupported field", systemImage: "lock")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            auxiliaryControls
        }
    }

    private var auxiliaryControls: some View {
        let layout = rowLayout.layout(auxiliary: true)
        return layout {
            if let copy, FieldValueView.hasContent(field) {
                Button { copied = copy(field.value) } label: {
                    Label(LocalizedStringKey(copied ? "Copied" : "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .fieldControlFrame(square: true)
                }
                .buttonStyle(.borderless)
                .disabled(invalid)
                .accessibilityIdentifier("editor-copy-\(field.id)")
                .accessibilityLabel(Text(verbatim: FieldPresentation.action("Copy %@", field: field, locale: locale)))
                .help(Text(verbatim: FieldPresentation.action("Copy %@", field: field, locale: locale)))
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove field", systemImage: "minus.circle")
                        .labelStyle(.iconOnly)
                        .fieldControlFrame(square: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: FieldPresentation.action("Remove %@", field: field, locale: locale)))
                .accessibilityIdentifier("remove-field-\(field.id)")
                .help(Text(verbatim: FieldPresentation.action("Remove %@", field: field, locale: locale)))
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        switch field.kind {
        case "address":
            if case .success(let draft) = Result(catching: { try AddressFieldDraft(value: field.value) }) {
                AddressFieldInput(field: $field, invalid: $invalid, draft: draft, initiallyVisible: initiallyVisible)
            } else {
                Label("Unsupported field", systemImage: "lock")
            }
        case "multi-select":
            if case .success(let draft) = Result(catching: { try StringListFieldDraft(value: field.value) }) {
                StringListFieldInput(field: $field, invalid: $invalid, draft: draft, initiallyVisible: initiallyVisible)
            } else {
                Label("Unsupported field", systemImage: "lock")
            }
        case "recovery-codes":
            if case .success(let draft) = Result(catching: { try RecoveryCodesFieldDraft(value: field.value) }) {
                RecoveryCodesFieldInput(field: $field, invalid: $invalid, draft: draft, initiallyVisible: initiallyVisible)
            } else {
                Label("Unsupported field", systemImage: "lock")
            }
        case "boolean":
            if case .bool(let value) = field.value {
                BooleanFieldInput(field: $field, invalid: $invalid, value: value, initiallyVisible: initiallyVisible)
            } else {
                Label("Unsupported field", systemImage: "lock")
            }
        default:
            if case .string(let text) = field.value {
                StringFieldInput(field: $field, invalid: $invalid, text: text, templateID: templateID, initiallyVisible: initiallyVisible)
            } else {
                Label("Unsupported field", systemImage: "lock")
            }
        }
    }
}
