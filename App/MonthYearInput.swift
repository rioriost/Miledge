#if os(iOS)
import SwiftUI
import UIKit

/// UIKit's two-component date mode avoids inventing a day for month-only values.
struct MonthYearInput: UIViewRepresentable {
    @Binding var date: Date
    let label: String
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.preferredDatePickerStyle = .wheels
        picker.datePickerMode = .yearAndMonth
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.locale = locale
        picker.calendar = CalendarFieldValue.calendar
        picker.timeZone = CalendarFieldValue.calendar.timeZone
        picker.minimumDate = CalendarFieldValue.range.lowerBound
        picker.maximumDate = CalendarFieldValue.range.upperBound
        picker.accessibilityLabel = label
        picker.accessibilityIdentifier = "calendar-month-year"
        if picker.date != date { picker.setDate(date, animated: false) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: uiView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MonthYearInput
        init(parent: MonthYearInput) { self.parent = parent }
        @objc func changed(_ picker: UIDatePicker) { parent.date = picker.date }
    }
}
#endif
