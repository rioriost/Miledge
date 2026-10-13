import Foundation
import MiledgeDomain

struct EditorDefaultTitle {
    private var initialized = false
    private var automatic = false
    private var registrationDate = ""

    mutating func initialize(
        revision: inout VaultRevision, creating: Bool, locale: Locale, timeZone: TimeZone = .current
    ) {
        guard !initialized else { return }
        initialized = true
        guard creating, revision.title.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        registrationDate = formatter.string(from: revision.createdAt)
        automatic = true
        updateType(revision: &revision, locale: locale)
    }

    mutating func edit(_ value: String, revision: inout VaultRevision) {
        initialized = true
        automatic = false
        revision.title = value
    }

    func updateType(revision: inout VaultRevision, locale: Locale) {
        guard automatic else { return }
        let format = CatalogLocalization.string("New item title format", locale: locale)
        revision.title = String(
            format: format, locale: locale,
            CatalogLocalization.templateName(id: revision.templateId, locale: locale), registrationDate
        )
    }
}
