import MiledgeApplication
import MiledgeDomain
import SwiftUI

struct CollectionDraftRow<Entry: Identifiable & Equatable, Content: View>: View {
    // Retiring controls must not retain a binding to a removed array index.
    @State var entry: Entry
    @State private var pendingWrites: [Entry] = []
    let source: Entry
    let update: (Entry) -> Void
    @ViewBuilder let content: (Binding<Entry>) -> Content

    init(entry: Entry, update: @escaping (Entry) -> Void, @ViewBuilder content: @escaping (Binding<Entry>) -> Content) {
        _entry = State(initialValue: entry)
        source = entry
        self.update = update
        self.content = content
    }

    var body: some View {
        content(Binding(get: { entry }, set: { replacement in
            entry = replacement
            if pendingWrites.last != replacement { pendingWrites.append(replacement) }
            update(replacement)
        }))
        .onChange(of: source) { _, replacement in
            // A model echo from an earlier keystroke must not replace newer input.
            if let index = pendingWrites.lastIndex(of: replacement) {
                pendingWrites.removeFirst(index + 1)
            } else {
                pendingWrites.removeAll()
                entry = replacement
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func collectionIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private struct CollectionRemoveButton: View {
    let label: LocalizedStringKey
    var target: String? = nil
    var identifier: String? = nil
    let remove: () -> Void

    var body: some View {
        Button(role: .destructive, action: remove) {
            Label(label, systemImage: "minus.circle")
                .labelStyle(.iconOnly)
                .fieldControlFrame(square: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .collectionIdentifier(identifier)
        .accessibilityLabel(Text(label) + Text(verbatim: target.map { " " + $0 } ?? ""))
        .help(Text(label) + Text(verbatim: target.map { " " + $0 } ?? ""))
    }
}

struct CollectionDisclosure<Content: View>: View {
    let field: VaultField
    let initiallyVisible: Bool
    @ViewBuilder let content: () -> Content
    @State private var revealed: Bool

    init(field: VaultField, initiallyVisible: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.field = field
        self.content = content
        self.initiallyVisible = initiallyVisible
        _revealed = State(initialValue: initiallyVisible || !field.concealed)
    }

    var body: some View {
        VStack(alignment: .leading) {
            if revealed {
                content()
            }
            if field.concealed {
                HStack {
                    if !revealed {
                        Text("Concealed").accessibilityLabel("Concealed value")
                    }
                    Spacer()
                    FieldRevealButton(revealed: $revealed, field: field)
                }
            }
        }
        .autocorrectionDisabled()
        .buttonStyle(.borderless)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .initialFieldVisibility(
            revealed: $revealed, concealed: field.concealed, identity: field.id, initiallyVisible: initiallyVisible
        )
    }
}

struct AddressFieldInput: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool
    @State var draft: AddressFieldDraft
    var initiallyVisible = false
    @State private var pendingWrites: [JSONValue] = []
    @State private var duplicateNames = false
    @Environment(\.locale) private var locale

    private let standardComponents = ["country", "postalCode", "region", "city", "street"]
    private let componentLabels = ["country": "Country", "postalCode": "Postal code", "region": "State / province", "city": "City / locality", "street": "Street address"]

    var body: some View {
        CollectionDisclosure(field: field, initiallyVisible: initiallyVisible) {
            ForEach(Array(draft.components.enumerated()), id: \.element.id) { index, component in
                CollectionDraftRow(entry: component, update: { updated in
                    updateDraft { $0.components = $0.components.map { $0.id == updated.id ? updated : $0 } }
                }) { $component in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let label = componentLabels[component.name] {
                                Text(LocalizedStringKey(label)).ledgerFont(.subheadline)
                            } else {
                            #if os(macOS)
                            MacFieldInput(
                                text: $component.name,
                                label: String(localized: "Component name", locale: locale) + " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)",
                                placeholder: String(localized: "Component name", locale: locale)
                            )
                            .accessibilityIdentifier("Component name")
                            #else
                            TextField("Component name", text: $component.name)
                                .fieldControlFrame()
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("Component name")
                                .accessibilityLabel(Text("Component name") + Text(verbatim: " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)"))
                            #endif
                            }
                            if component.name == "country" {
                                ChoiceFieldInput(
                                    text: $component.value, choices: FieldSelectionCatalog.countries(locale: locale),
                                    label: CatalogLocalization.string("Country", locale: locale)
                                        + " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)",
                                    identifier: "\(field.id)-country", searchable: true
                                )
                                .fieldControlFrame()
                            } else {
                                TextField("Value", text: $component.value, axis: .vertical)
                                    .fieldControlFrame()
                                    .multilineTextAlignment(.leading)
                                    .accessibilityIdentifier(componentLabels[component.name] == nil ? "Value" : "address-\(field.id)-\(component.name)")
                                    .lineLimit(1...4)
                                    .accessibilityLabel(Text(LocalizedStringKey(componentLabels[component.name] ?? "Value")) + Text(verbatim: " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)"))
                            }
                            if ["postalCode", "postal", "zip", "zipCode", "postcode"].contains(component.name),
                               let check = InputValidator.shared.postalCode(
                                component.value, country: draft.components.first { $0.name == "country" }?.value ?? ""
                               ) {
                                InputCheckFeedback(check: check, identifier: "input-check-postal-\(field.id)")
                            }
                        }
                        CollectionRemoveButton(label: "Remove component", target: "\(FieldPresentation.name(for: field, locale: locale)) \(index + 1)", identifier: "Remove component") {
                            let id = component.id
                            updateDraft { $0.components.removeAll { $0.id == id } }
                        }
                    }
                }
            }
            if standardComponents.contains(where: { name in !draft.components.contains { $0.name == name } }) {
                Button("Add address fields", systemImage: "plus") {
                    updateDraft { draft in
                        for name in standardComponents where !draft.components.contains(where: { $0.name == name }) {
                            draft.components.append(.init(name: name, value: ""))
                        }
                    }
                }
                .accessibilityIdentifier("add-address-fields-\(field.id)")
            }
            Button("Add component", systemImage: "plus") {
                updateDraft { $0.components.append(.init(name: "", value: "")) }
            }
            .accessibilityIdentifier("Add component")
            .accessibilityLabel(Text("Add component") + Text(verbatim: " " + FieldPresentation.name(for: field, locale: locale)))
        }
        .onChange(of: field.value) { _, replacement in
            if let index = pendingWrites.lastIndex(of: replacement) {
                pendingWrites.removeFirst(index + 1)
                return
            }
            pendingWrites.removeAll()
            guard (try? draft.json()) != replacement,
                  let replacement = try? AddressFieldDraft(value: replacement) else { return }
            draft = replacement
            invalid = false
            duplicateNames = false
        }
        if invalid {
            Text(LocalizedStringKey(duplicateNames
                ? "Component names must be different." : "Check the value and format."))
                .ledgerFont(.caption)
                .foregroundStyle(.red)
        }
    }

    private func updateDraft(_ edit: (inout AddressFieldDraft) -> Void) {
        var replacement = draft
        edit(&replacement)
        draft = replacement
        do {
            let edited = try VaultEditor.replacingValue(in: field, with: replacement.json())
            if pendingWrites.last != edited.value { pendingWrites.append(edited.value) }
            field = edited
            duplicateNames = false
            invalid = false
        } catch StructuredFieldError.duplicateComponents {
            duplicateNames = true
            invalid = true
        } catch {
            duplicateNames = false
            invalid = true
        }
    }
}

struct StringListDraftInput: View {
    @Binding var draft: StringListFieldDraft
    let valueLabel: LocalizedStringKey
    let addLabel: LocalizedStringKey
    let removeLabel: LocalizedStringKey
    var target: String? = nil
    var valueIdentifier: String? = nil
    var addIdentifier: String? = nil
    var removeIdentifier: String? = nil

    var body: some View {
        ForEach(Array(draft.entries.enumerated()), id: \.element.id) { index, entry in
            CollectionDraftRow(entry: entry, update: { updated in
                draft.entries = draft.entries.map { $0.id == updated.id ? updated : $0 }
            }) { $entry in
                HStack(alignment: .top, spacing: 12) {
                    TextField(valueLabel, text: $entry.value, axis: .vertical)
                        .fieldControlFrame()
                        .multilineTextAlignment(.leading)
                        .collectionIdentifier(valueIdentifier)
                        .lineLimit(1...4)
                        .accessibilityLabel(Text(valueLabel) + Text(verbatim: target.map { " \($0) \(index + 1)" } ?? ""))
                    CollectionRemoveButton(label: removeLabel, target: target.map { "\($0) \(index + 1)" }, identifier: removeIdentifier) {
                        let id = entry.id
                        draft.entries.removeAll { $0.id == id }
                    }
                }
            }
        }
        Button(addLabel, systemImage: "plus") {
            draft.entries.append(.init(value: ""))
        }
        .collectionIdentifier(addIdentifier)
        .accessibilityLabel(Text(addLabel) + Text(verbatim: target.map { " " + $0 } ?? ""))
    }
}

struct StringListFieldInput: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool
    @State var draft: StringListFieldDraft
    var initiallyVisible = false
    @State private var lastWrittenValue: JSONValue?
    @Environment(\.locale) private var locale

    var body: some View {
        CollectionDisclosure(field: field, initiallyVisible: initiallyVisible) {
            StringListDraftInput(
                draft: draftBinding, valueLabel: "Choice", addLabel: "Add choice", removeLabel: "Remove choice",
                target: FieldPresentation.name(for: field, locale: locale),
                valueIdentifier: "Choice", addIdentifier: "Add choice", removeIdentifier: "Remove choice"
            )
        }
        .onChange(of: field.value) { _, replacement in
            guard replacement != lastWrittenValue else { return }
            lastWrittenValue = nil
            guard draft.json != replacement,
                  let replacement = try? StringListFieldDraft(value: replacement) else { return }
            draft = replacement
            invalid = false
        }
        if invalid {
            Text("Check the value and format.").ledgerFont(.caption).foregroundStyle(.red)
        }
    }

    private var draftBinding: Binding<StringListFieldDraft> {
        Binding(get: { draft }, set: { replacement in
            draft = replacement
            do {
                let edited = try VaultEditor.replacingValue(in: field, with: replacement.json)
                lastWrittenValue = edited.value
                field = edited
                invalid = false
            } catch { invalid = true }
        })
    }
}

struct RecoveryCodesFieldInput: View {
    @Binding var field: VaultField
    @Binding var invalid: Bool
    @State var draft: RecoveryCodesFieldDraft
    var initiallyVisible = false
    @State private var lastWrittenValue: JSONValue?
    @Environment(\.locale) private var locale

    var body: some View {
        CollectionDisclosure(field: field, initiallyVisible: initiallyVisible) {
            ForEach(Array(draft.entries.enumerated()), id: \.element.id) { index, entry in
                CollectionDraftRow(entry: entry, update: { updated in
                    updateDraft { $0.entries = $0.entries.map { $0.id == updated.id ? updated : $0 } }
                }) { $entry in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Code", text: $entry.code, axis: .vertical)
                                .fieldControlFrame()
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("Code")
                                .lineLimit(1...4)
                                .accessibilityLabel(Text("Code") + Text(verbatim: " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)"))
                            Toggle("Used", isOn: $entry.used)
                                .accessibilityIdentifier("Used")
                                .accessibilityLabel(Text("Used") + Text(verbatim: " \(FieldPresentation.name(for: field, locale: locale)) \(index + 1)"))
                        }
                        CollectionRemoveButton(label: "Remove code", target: "\(FieldPresentation.name(for: field, locale: locale)) \(index + 1)", identifier: "Remove code") {
                            let id = entry.id
                            updateDraft { $0.entries.removeAll { $0.id == id } }
                        }
                    }
                }
            }
            Button("Add code", systemImage: "plus") {
                updateDraft { $0.entries.append(.init(code: "")) }
            }
            .accessibilityIdentifier("Add code")
            .accessibilityLabel(Text("Add code") + Text(verbatim: " " + FieldPresentation.name(for: field, locale: locale)))
        }
        .onChange(of: field.value) { _, replacement in
            guard replacement != lastWrittenValue else { return }
            lastWrittenValue = nil
            guard (try? draft.json()) != replacement,
                  let replacement = try? RecoveryCodesFieldDraft(value: replacement) else { return }
            draft = replacement
            invalid = false
        }
        if invalid {
            Text("Check the value and format.").ledgerFont(.caption).foregroundStyle(.red)
        }
    }

    private func updateDraft(_ edit: (inout RecoveryCodesFieldDraft) -> Void) {
        var replacement = draft
        edit(&replacement)
        draft = replacement
        do {
            let edited = try VaultEditor.replacingValue(in: field, with: replacement.json())
            lastWrittenValue = edited.value
            field = edited
            invalid = false
        } catch { invalid = true }
    }
}
