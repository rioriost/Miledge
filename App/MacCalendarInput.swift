#if os(macOS)
import AppKit
import SwiftUI

/// Standard segmented date entry with AppKit's calendar overlay.
struct MacCalendarInput: NSViewRepresentable {
    @Binding var date: Date
    let kind: String
    let label: String
    let identifier: String
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayTextSize) private var textSize

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.presentsCalendarOverlay = true
        picker.isBezeled = true
        picker.drawsBackground = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.locale = locale
        picker.calendar = CalendarFieldValue.calendar
        picker.timeZone = CalendarFieldValue.calendar.timeZone
        picker.datePickerElements = kind == "year-month" ? .yearMonth : .yearMonthDay
        picker.minDate = CalendarFieldValue.range.lowerBound
        picker.maxDate = CalendarFieldValue.range.upperBound
        picker.font = .systemFont(ofSize: 16 * textSize.scale)
        picker.isEnabled = enabled
        picker.setAccessibilityLabel(label)
        picker.setAccessibilityIdentifier(identifier)
        if picker.dateValue != date { picker.dateValue = date }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var parent: MacCalendarInput
        init(parent: MacCalendarInput) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) { parent.date = picker.dateValue }
    }
}
#endif
