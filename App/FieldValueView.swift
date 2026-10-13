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
    @Environment(\.locale) private var locale
    @Environment(\.concealValuesByDefault) private var concealByDefault

    var body: some View {
        VStack(alignment: .leading) {
            FieldLabel(field: field)
                .ledgerFont(.caption)
                .foregroundStyle(.primary)
            if field.concealed, !revealed {
                Text("Concealed")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Concealed value")
            } else {
                FieldValueView(value: field.value, kind: field.kind)
                    .multilineTextAlignment(field.kind == "number" ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: field.kind == "number" ? .trailing : .leading)
            }
            HStack {
                if field.concealed {
                    FieldRevealButton(revealed: $revealed, field: field)
                }
                if let copy, FieldValueView.hasContent(field) {
                    Button(LocalizedStringKey(structured ? "Copy JSON" : "Copy"), systemImage: "doc.on.doc") {
                        copied = copy(field.value)
                    }
                    .accessibilityIdentifier("copy-value")
                    .accessibilityLabel(Text(verbatim: FieldPresentation.action(structured ? "Copy %@ as JSON" : "Copy %@", field: field, locale: locale)))
                    if copied { Label("Copied", systemImage: "checkmark").ledgerFont(.caption) }
                }
            }
        }
        .buttonStyle(.borderless)
        .textSelection(.disabled)
        .onChange(of: field) { _, _ in
            revealed = FieldVisibility.initiallyRevealed(
                concealed: field.concealed, initiallyVisible: false, concealByDefault: concealByDefault
            )
            copied = false
        }
        .initialFieldVisibility(revealed: $revealed, concealed: field.concealed, identity: field.id)
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
