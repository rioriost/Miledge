import Foundation
import MiledgeDomain

/// Presentation only: stable IDs, stored labels and values never change during localization.
enum CatalogLocalization {
    static let supportedLanguages = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es", "pt-BR", "it", "ar", "hi"]

    static func templateName(_ template: ItemTemplate, locale: Locale = .current) -> String {
        string(template.name, locale: locale)
    }

    static func templateName(id: String, locale: Locale = .current) -> String {
        guard let template = TemplateCatalog.template(id: id) else { return id }
        return templateName(template, locale: locale)
    }

    static func affiliateName(_ profile: AffiliateProviderProfile, locale: Locale = .current) -> String {
        string(profile.name, locale: locale)
    }

    static func fieldLabel(_ field: VaultField, locale: Locale = .current) -> String {
        guard let defaultLabel = TemplateCatalog.fieldLocalizationKeys[field.id],
              field.label == nil || field.label == defaultLabel else {
            return field.label ?? field.id
        }
        // The catalog organization field names an institution; the UI Organization section means sorting/tagging.
        return string(field.id == "organization" ? "Organization name" : defaultLabel, locale: locale)
    }

    static func matches(_ template: ItemTemplate, query: String, locale: Locale = .current) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || templateName(template, locale: locale).range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            || template.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            || (template.id == "affiliate-account" && TemplateCatalog.affiliateProfiles.contains { matches($0, query: query, locale: locale) })
    }

    static func matches(_ profile: AffiliateProviderProfile, query: String, locale: Locale = .current) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || affiliateName(profile, locale: locale).range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            || profile.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
    }

    static func itemCount(_ count: Int, locale: Locale = .current, bundle: Bundle = .main) -> String {
        let format = string("%lld items", locale: locale, bundle: bundle)
        return String(format: format, locale: locale, arguments: [Int64(count)])
    }

    static func string(_ key: String, locale: Locale = .current, bundle: Bundle = .main) -> String {
        let languages = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: [locale.identifier])
        guard let language = languages.first,
              let path = bundle.path(forResource: language, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }
}
