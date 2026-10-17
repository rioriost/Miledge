import MiledgeDomain
import SwiftUI

/// Presentation helpers never derive action names from a stored secret value.
enum FieldPresentation {
    static func name(for field: VaultField, locale: Locale = .current) -> String {
        let label = CatalogLocalization.fieldLabel(field, locale: locale)
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(field.label == nil && UUID(uuidString: field.id) != nil) else {
            return CatalogLocalization.string("Unnamed field", locale: locale)
        }
        return label
    }

    static func action(_ format: String, field: VaultField, locale: Locale = .current) -> String {
        String(format: CatalogLocalization.string(format, locale: locale), locale: locale, name(for: field, locale: locale))
    }

    static func formatHint(for kind: String) -> String? {
        switch kind {
        case "date": "Use YYYY-MM-DD."
        case "year-month": "Use YYYY-MM."
        case "number": "Use a decimal number with a dot."
        default: nil
        }
    }

    static func usesRomanInput(for kind: String) -> Bool {
        ["number", "date", "year-month"].contains(kind)
    }

}

struct FieldLabel: View {
    let field: VaultField
    @Environment(\.locale) private var locale

    var text: Text { Text(verbatim: FieldPresentation.name(for: field, locale: locale)) }

    var body: some View { text }
}

struct FieldDetailRow: View {
    let field: VaultField
    var copy: ((JSONValue) -> Bool)?
    @State private var revealed = false
    @State var copied = false
    @State private var hovering = false
    @State private var menuPresented = false
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale
    @Environment(\.concealValuesByDefault) private var concealByDefault
    @Environment(\.scenePhase) private var scenePhase

    private var canCopy: Bool { copy != nil && FieldValueView.hasContent(field) }

    private var copyName: String {
        FieldPresentation.action(structured ? "Copy %@ as JSON" : "Copy %@", field: field, locale: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(field: field)
                .ledgerFont(.caption)
                .foregroundStyle(.primary)
            valueControl
        }
        .textSelection(.disabled)
        .onChange(of: field) { _, _ in reset() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reset() }
        }
        .onDisappear { reset() }
        .initialFieldVisibility(revealed: $revealed, concealed: field.concealed, identity: field.id)
    }

    private var valueControl: some View {
        Button {
            #if os(macOS)
            if canCopy { copyValue() } else { revealed.toggle() }
            #else
            copied = false
            if canCopy { revealed = true; menuPresented = true }
            else { revealed.toggle() }
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if copied {
                    Label("Copied", systemImage: "doc.on.doc")
                } else if field.concealed, !revealed {
                    Text(verbatim: "••••••••••••")
                        .accessibilityLabel("Concealed value")
                } else {
                    FieldValueView(value: field.value, kind: field.kind)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
            .background(hovering || menuPresented ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(canCopy ? "copy-value" : "field-value")
        .accessibilityLabel(Text(verbatim: FieldPresentation.name(for: field, locale: locale)))
        .accessibilityValue(accessibleValue)
        .accessibilityActions {
            if canCopy { Button(copyName) { copyValue() } }
            if field.concealed {
                Button(FieldPresentation.action(revealed ? "Hide %@" : "Reveal %@", field: field, locale: locale)) {
                    revealed.toggle()
                }
            }
        }
        #if os(macOS)
        .focused($focused)
        .onChange(of: focused) { _, value in
            revealed = value || hovering || !concealByDefault
            if !value { copied = false }
        }
        .onHover { value in
            hovering = value
            revealed = value || !concealByDefault
            if !value { copied = false }
        }
        .onKeyPress(.escape) { reset(); return .handled }
        .onKeyPress("c", phases: .down) { press in
            guard press.modifiers.contains(.command), canCopy else { return .ignored }
            copyValue()
            return .handled
        }
        .contextMenu {
            if canCopy { Button(copyName) { copyValue() } }
            if field.concealed {
                Button(LocalizedStringKey(revealed ? "Hide" : "Reveal")) { revealed.toggle() }
            }
        }
        .help(Text(verbatim: copyName))
        #else
        .background {
            FieldCopyEditMenu(presented: $menuPresented, title: copyName, copy: copyValue) {
                revealed = !concealByDefault
            }
        }
        .onLongPressGesture { copied = false; revealed = true; menuPresented = canCopy }
        #endif
    }

    private var accessibleValue: Text {
        if copied { return Text("Copied") }
        if field.concealed, !revealed { return Text("Concealed value") }
        return Text(verbatim: (try? field.value.plainTextForCopy()) ?? "")
    }

    private func copyValue() {
        guard canCopy, let copy else { return }
        copied = copy(field.value)
        // Acknowledgement replaces the value, so copying doesn't leave it visible.
        if copied { revealed = false }
    }

    private func reset() {
        revealed = false
        copied = false
        hovering = false
        menuPresented = false
        focused = false
    }

    private var structured: Bool {
        switch field.value {
        case .array, .object: true
        default: false
        }
    }
}

struct FieldValueView: View {
    let value: JSONValue
    var kind: String?

    static func hasContent(_ field: VaultField) -> Bool {
        if field.kind == "recovery-codes", case .array(let entries) = field.value {
            return entries.contains { value in
                if let entry = recoveryCode(value) { return !entry.code.isEmpty }
                return hasContent(value)
            }
        }
        return hasContent(field.value)
    }

    static func hasContent(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text), .number(let text): !text.isEmpty
        case .array(let values): values.contains(where: hasContent)
        case .object(let values): values.values.contains(where: hasContent)
        case .bool: true
        case .null: false
        }
    }

    var body: some View {
        switch value {
        case .array(let values):
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                if kind == "recovery-codes", let entry = Self.recoveryCode(value) {
                    if !entry.code.isEmpty {
                        VStack(alignment: .leading) {
                            Text(verbatim: entry.code)
                            Text(LocalizedStringKey(entry.used ? "Used" : "Unused"))
                                .ledgerFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    FlatValueView(value: value, numeric: kind == "number")
                }
            }
        default:
            FlatValueView(value: value, numeric: kind == "number")
        }
    }

    private static func recoveryCode(_ value: JSONValue) -> (code: String, used: Bool)? {
        guard case .object(let entry) = value, Set(entry.keys) == ["id", "code", "used"],
              case .string(let id) = entry["id"], !id.isEmpty,
              case .string(let code) = entry["code"],
              case .bool(let used) = entry["used"] else { return nil }
        return (code, used)
    }
}

private struct FlatValueView: View {
    let value: JSONValue
    var numeric = false

    var body: some View {
        switch value {
        case .object(let components):
            ForEach(components.keys.sorted(), id: \.self) { key in
                if let component = components[key] {
                    LabeledContent {
                        ScalarValueView(value: component)
                    } label: {
                        Text(verbatim: key)
                    }
                }
            }
        default:
            ScalarValueView(value: value, numeric: numeric)
        }
    }
}

private struct ScalarValueView: View {
    let value: JSONValue
    var numeric = false

    var body: some View {
        switch value {
        case .string(let text):
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(numeric ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: numeric ? .trailing : .leading)
        case .number(let text):
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .bool(let value):
            Text(LocalizedStringKey(value ? "Yes" : "No"))
        case .null:
            Text("No value").foregroundStyle(.secondary)
        case .array, .object:
            Text("Unsupported field").foregroundStyle(.secondary)
        }
    }
}
