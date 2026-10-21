import SwiftUI

private enum FieldChoiceSelection: Hashable {
    case value(String)
    case custom
}

struct ChoiceFieldInput: View {
    @Binding var text: String
    let choices: [FieldChoice]
    let label: String
    let identifier: String
    var searchable = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var custom = false
    @State private var presented = false
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool

    private var selection: Binding<FieldChoiceSelection> {
        Binding(get: { custom ? .custom : .value(text) }, set: {
            switch $0 {
            case .custom: custom = true
            case .value(let value): custom = false; text = value; onEditingChanged(false)
            }
        })
    }

    private var currentLabel: String {
        text.isEmpty ? CatalogLocalization.string("Not set", locale: locale)
            : choices.first { $0.value == text }?.label ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searchable {
                Button { presented = true } label: {
                    HStack {
                        Text(verbatim: currentLabel).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityValue(Text(verbatim: currentLabel))
                .accessibilityIdentifier("field-choice-\(identifier)")
                #if os(macOS)
                .popover(isPresented: $presented) { selectionList }
                #else
                .sheet(isPresented: $presented) {
                    selectionList
                        .presentationSizing(.form)
                }
                #endif
            } else {
                Picker(selection: selection) {
                    Text("Not set").tag(FieldChoiceSelection.value(""))
                    ForEach(choices) { choice in
                        Text(verbatim: choice.label).tag(FieldChoiceSelection.value(choice.value))
                    }
                    if !text.isEmpty, !choices.contains(where: { $0.value == text }) {
                        Text(verbatim: text).tag(FieldChoiceSelection.value(text))
                    }
                    Text("Other…").tag(FieldChoiceSelection.custom)
                } label: {
                    Text(verbatim: label)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityValue(Text(verbatim: currentLabel))
                .accessibilityIdentifier("field-choice-\(identifier)")
            }
            if custom {
                #if os(macOS)
                MacFieldInput(text: $text, label: label, onEditingChanged: onEditingChanged)
                    .accessibilityIdentifier("field-custom-\(identifier)")
                #else
                TextField("", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...4)
                    .fieldControlFrame()
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityIdentifier("field-custom-\(identifier)")
                #endif
            }
        }
        .onChange(of: focused) { _, editing in onEditingChanged(editing) }
    }

    private var selectionList: some View {
        ChoiceSelectionList(
            text: $text, choices: choices, label: label,
            custom: { custom = true; presented = false },
            select: { text = $0; custom = false; presented = false; onEditingChanged(false) },
            cancel: { presented = false }
        )
    }

}

private struct ChoiceSelectionList: View {
    @Binding var text: String
    let choices: [FieldChoice]
    let label: String
    let custom: () -> Void
    let select: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @Environment(\.locale) private var locale

    private var filteredChoices: [FieldChoice] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return choices }
        let matches = choices.filter { $0.matches(term, locale: locale) }
        // A complete country code is more specific than a substring in a country name.
        return matches.filter { $0.value.caseInsensitiveCompare(term) == .orderedSame }
            + matches.filter { $0.value.caseInsensitiveCompare(term) != .orderedSame }
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: label).font(.headline)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            CountrySearchField(text: $query, label: label) {
                guard !query.isEmpty, let choice = filteredChoices.first else { return }
                select(choice.value)
            }
                .frame(height: 28)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    choiceRows
                }
            }
            .buttonStyle(.borderless)
            Button("Other…", action: custom).accessibilityIdentifier("choice-custom")
        }
        .padding(16)
        .frame(width: 360, height: 440)
        #else
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Text(verbatim: label).font(.headline).multilineTextAlignment(.center)
                Spacer()
                Button("Other…", action: custom).accessibilityIdentifier("choice-custom")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            CountrySearchField(text: $query, label: label)
                .frame(height: 52)
            choicesList
        }
        #endif
    }

    private var choicesList: some View {
        List { choiceRows }
            .ledgerFont(.body)
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private var choiceRows: some View {
            Button("Not set") { select("") }.accessibilityIdentifier("choice-clear")
            if !text.isEmpty, !choices.contains(where: { $0.value == text }) {
                Text(verbatim: text).textSelection(.disabled)
            }
            ForEach(filteredChoices) { choice in
                Button { select(choice.value) } label: {
                    HStack {
                        Text(verbatim: choice.label).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if choice.value == text { Image(systemName: "checkmark") }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("choice-\(choice.value)")
            }
    }

}

struct CalendarFieldInput: View {
    @Binding var text: String
    let kind: String
    let label: String
    let identifier: String
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var presented = false

    var body: some View {
        #if os(macOS)
        if let date = try? CalendarFieldValue.date(text, kind: kind) {
            HStack {
                MacCalendarInput(date: Binding(get: { date }, set: {
                    if let value = try? CalendarFieldValue.string($0, kind: kind) {
                        text = value
                        onEditingChanged(false)
                    }
                }), kind: kind, label: label, identifier: "field-calendar-\(identifier)")
                Button("Clear") { text = ""; onEditingChanged(false) }
                    .accessibilityIdentifier("calendar-clear-\(identifier)")
            }
        } else {
            trigger.popover(isPresented: $presented) { panel }
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            trigger
            if presented { panel }
        }
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var trigger: some View {
        Button { presented.toggle() } label: {
            HStack {
                if text.isEmpty { Text(kind == "year-month" ? "Choose a month" : "Choose a date") }
                else { Text(verbatim: text) }
                Spacer(minLength: 8)
                Image(systemName: "calendar")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("field-calendar-\(identifier)")
    }

    private var panel: some View {
        CalendarSelectionPanel(text: text, kind: kind, label: label) {
            text = $0
            presented = false
            onEditingChanged(false)
        } cancel: {
            presented = false
        }
    }

}

struct CalendarSelectionPanel: View {
    let kind: String
    let label: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var pending: Date
    @State private var issue: Bool
    @Environment(\.locale) private var locale
    @Environment(\.displayTextSize) private var textSize

    init(text: String, kind: String, label: String, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.kind = kind
        self.label = label
        self.commit = commit
        self.cancel = cancel
        switch Result(catching: { try CalendarFieldValue.date(text, kind: kind) }) {
        case .success(let date):
            _pending = State(initialValue: date)
            _issue = State(initialValue: false)
        case .failure:
            _pending = State(initialValue: CalendarFieldValue.today())
            _issue = State(initialValue: !text.isEmpty)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            Text(verbatim: label).ledgerFont(.headline).fixedSize(horizontal: false, vertical: true)
            MacCalendarInput(date: $pending, kind: kind, label: label, identifier: "calendar-date")
            #else
            if kind == "year-month" {
                MonthYearInput(date: $pending, label: label)
            } else {
                DatePicker("Date", selection: $pending, in: CalendarFieldValue.range, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.calendar, CalendarFieldValue.calendar)
                    .environment(\.timeZone, CalendarFieldValue.calendar.timeZone)
                    .accessibilityIdentifier("calendar-date")
            }
            #endif
            if issue {
                Text("Check the value and format.").ledgerFont(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Clear") { commit("") }.accessibilityIdentifier("calendar-clear")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("calendar-cancel")
                Button("Done") {
                    do { commit(try CalendarFieldValue.string(pending, kind: kind)) }
                    catch { issue = true }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("calendar-done")
            }
            .buttonStyle(.bordered)
        }
        .onChange(of: pending) { _, _ in issue = false }
        .ledgerFont(.body)
        .fixedSize(horizontal: false, vertical: true)
        #if os(macOS)
        .padding()
        .frame(minWidth: 300, idealWidth: 340 * textSize.scale)
        #endif
    }

}

#if os(macOS)
/// A native search field keeps the search and cancel controls inside the popover.
private struct CountrySearchField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, submit: submit) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .large
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("country-choice-search")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.submit = submit
        if field.stringValue != text { field.stringValue = text }
        field.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var submit: () -> Void
        init(text: Binding<String>, submit: @escaping () -> Void) { self.text = text; self.submit = submit }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                submit()
                return true
            }
            return false
        }
    }
}
#endif

#if os(iOS)
/// Keep the native search field local to the selector rather than sharing navigation toolbar state.
private struct CountrySearchField: UIViewRepresentable {
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UISearchBar {
        let field = UISearchBar()
        field.searchBarStyle = .minimal
        field.delegate = context.coordinator
        field.searchTextField.accessibilityLabel = label
        field.searchTextField.accessibilityIdentifier = "country-choice-search"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        return field
    }
    func updateUIView(_ field: UISearchBar, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
        field.searchTextField.accessibilityLabel = label
    }
    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    }
}
#endif
