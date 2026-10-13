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
    @State private var custom = false
    @State private var presented = false
    @Environment(\.locale) private var locale

    private var selection: Binding<FieldChoiceSelection> {
        Binding(get: { custom ? .custom : .value(text) }, set: {
            switch $0 {
            case .custom: custom = true
            case .value(let value): custom = false; text = value
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
                .sheet(isPresented: $presented) { selectionList }
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
                MacFieldInput(text: $text, label: label)
                    .accessibilityIdentifier("field-custom-\(identifier)")
                #else
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .fieldControlFrame()
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityIdentifier("field-custom-\(identifier)")
                #endif
            }
        }
    }

    private var selectionList: some View {
        ChoiceSelectionList(
            text: $text, choices: choices, label: label,
            custom: { custom = true; presented = false },
            select: { text = $0; custom = false; presented = false },
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

    var body: some View {
        NavigationStack {
            List {
                Button("Not set") { select("") }.accessibilityIdentifier("choice-clear")
                if !text.isEmpty, !choices.contains(where: { $0.value == text }) {
                    Text(verbatim: text).textSelection(.disabled)
                }
                ForEach(choices.filter { query.isEmpty || $0.matches(query, locale: locale) }) { choice in
                    Button { select(choice.value) } label: {
                        HStack {
                            Text(verbatim: choice.label).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if choice.value == text { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("choice-\(choice.value)")
                }
            }
            .ledgerFont(.body)
            .searchable(text: $query)
            .navigationTitle(Text(verbatim: label))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Other…", action: custom).accessibilityIdentifier("choice-custom")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 240, idealWidth: 360, maxWidth: 420, minHeight: 360, idealHeight: 480)
        #endif
    }
}

struct CalendarFieldInput: View {
    @Binding var text: String
    let kind: String
    let label: String
    let identifier: String
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
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
        .popover(isPresented: $presented) {
            CalendarSelectionPanel(text: text, kind: kind, label: label) {
                text = $0
                presented = false
            } cancel: {
                presented = false
            }
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

    private var year: Binding<Int> {
        Binding(get: { CalendarFieldValue.calendar.component(.year, from: pending) },
                set: { update(year: $0, month: month.wrappedValue) })
    }

    private var month: Binding<Int> {
        Binding(get: { CalendarFieldValue.calendar.component(.month, from: pending) },
                set: { update(year: year.wrappedValue, month: $0) })
    }

    private var monthNames: [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = CalendarFieldValue.calendar
        return formatter.monthSymbols
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: label).ledgerFont(.headline).fixedSize(horizontal: false, vertical: true)
            if kind == "year-month" {
                Picker("Month", selection: month) {
                    ForEach(1...12, id: \.self) { month in
                        Text(verbatim: monthNames[month - 1]).tag(month)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("calendar-month")
                Stepper(value: year, in: 1...9999) {
                    HStack {
                        Text("Year")
                        Spacer()
                        Text(verbatim: String(year.wrappedValue))
                    }
                }
                .accessibilityIdentifier("calendar-year")
            } else {
                DatePicker("Date", selection: $pending, in: CalendarFieldValue.range, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.calendar, CalendarFieldValue.calendar)
                    .environment(\.timeZone, CalendarFieldValue.calendar.timeZone)
                    .accessibilityIdentifier("calendar-date")
            }
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
        .ledgerFont(.body)
        .padding()
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 340 * textSize.scale)
        #endif
    }

    private func update(year: Int, month: Int) {
        do { pending = try CalendarFieldValue.month(year: year, month: month); issue = false }
        catch { issue = true }
    }
}
