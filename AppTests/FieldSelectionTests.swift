import Foundation
import MiledgeDomain
import XCTest
@testable import MiledgeApp

final class FieldSelectionTests: XCTestCase {
    func testEntireRequiredOptionalAndProfileCatalogHasReviewedChoices() throws {
        let templates = TemplateCatalog.all + TemplateCatalog.apiCredentialProfiles
        var fields: [(String, VaultField)] = []
        for template in templates {
            for section in template.sections + template.optionalSections {
                for field in section.fields { fields.append((template.id, field)) }
            }
        }
        for profile in TemplateCatalog.affiliateProfiles {
            for section in profile.sections + profile.optionalSections {
                for field in section.fields { fields.append(("affiliate-account", field)) }
            }
        }
        var reviewed = Set<String>()
        for (templateID, field) in fields {
            let choices = FieldSelectionCatalog.choices(for: field, templateID: templateID, locale: Locale(identifier: "en"))
            if field.kind == "select" {
                reviewed.insert(field.id)
                if FieldSelectionCatalog.freeTextSelectIDs.contains(field.id) {
                    XCTAssertTrue(choices.isEmpty, field.id)
                } else {
                    XCTAssertFalse(choices.isEmpty, "\(templateID): \(field.id)")
                }
            } else if FieldSelectionCatalog.countryIDs.contains(field.id) || field.id == "currency" {
                XCTAssertGreaterThan(choices.count, 200, "\(templateID): \(field.id)")
            }
            XCTAssertEqual(choices.count, Set(choices.map(\.value)).count, field.id)
            XCTAssertTrue(choices.allSatisfy { !$0.value.isEmpty && !$0.label.isEmpty }, field.id)
            XCTAssertEqual(try VaultEditor.replacingValue(in: field, with: field.value), field)
        }
        XCTAssertEqual(reviewed, Set(FieldSelectionCatalog.commonValues.keys)
            .union(["providerId", "profileId", "authenticationScheme"])
            .union(FieldSelectionCatalog.freeTextSelectIDs))
    }

    func testCountriesAndCurrenciesLocalizeWithoutChangingValuesOrCustomIdentity() throws {
        for (id, value, expected) in [("issuingCountry", "JP", "日本"), ("currency", "JPY", "日本円 (JPY)")] {
            let field = VaultField(id: id, kind: "string", value: .string("  historical / custom  "))
            let japanese = FieldSelectionCatalog.choices(for: field, locale: Locale(identifier: "ja"))
            let english = FieldSelectionCatalog.choices(for: field, locale: Locale(identifier: "en"))
            XCTAssertEqual(Set(japanese.map(\.value)), Set(english.map(\.value)))
            XCTAssertEqual(japanese.first { $0.value == value }?.label, expected)
            XCTAssertEqual(field.value, .string("  historical / custom  "))
            XCTAssertEqual(try VaultEditor.replacingValue(in: field, with: field.value), field)
            for custom in [
                VaultField(id: UUID().uuidString, kind: "string", label: id),
                VaultField(id: id, kind: "string", label: "My custom label"),
                VaultField(id: id, kind: "number", value: .string(""))
            ] {
                XCTAssertTrue(FieldSelectionCatalog.choices(for: custom).isEmpty)
            }
        }
        for id in ["nationality", "jurisdiction", "authority", "identifierSystem", "status", "taxPeriod", "modelYear"] {
            XCTAssertTrue(FieldSelectionCatalog.choices(for: VaultField(id: id, kind: "string")).isEmpty, id)
        }
        let brand = VaultField(id: "brand", kind: "select")
        XCTAssertEqual(FieldSelectionCatalog.choices(for: brand, locale: Locale(identifier: "ja")).first?.label, "Visa")
        let choice = FieldChoice(value: "JPY", label: "日本円 (JPY)")
        XCTAssertTrue(choice.matches("jpy", locale: Locale(identifier: "ja")))
        XCTAssertTrue(choice.matches("日本", locale: Locale(identifier: "ja")))
        XCTAssertFalse(choice.matches("USD", locale: Locale(identifier: "en")))
    }

    func testDateAndMonthRoundTripStrictGregorianCivilValues() throws {
        for (kind, values) in [
            ("date", ["0001-01-01", "1900-02-28", "2000-02-29", "2032-02-29", "9999-12-31"]),
            ("year-month", ["0001-01", "2031-09", "9999-12"])
        ] {
            for text in values {
                XCTAssertEqual(try CalendarFieldValue.string(CalendarFieldValue.date(text, kind: kind), kind: kind), text)
            }
        }
        for (kind, text) in [
            ("date", "1900-02-29"), ("date", "2031-02-29"), ("date", "2032-02-30"),
            ("date", "2032-2-9"), ("date", "令和14年2月29日"), ("date", "2032-02-29\n"),
            ("date", ""), ("year-month", "2031-13"), ("year-month", "2031-00"),
            ("year-month", "2031-09-01"), ("year-month", "0000-01"), ("year-month", "10000-01"),
            ("string", "2031-09")
        ] {
            XCTAssertThrowsError(try CalendarFieldValue.date(text, kind: kind), "\(kind): \(text)")
        }
        XCTAssertEqual(try CalendarFieldValue.string(CalendarFieldValue.month(year: 2032, month: 2), kind: "year-month"), "2032-02")
        XCTAssertThrowsError(try CalendarFieldValue.month(year: 2032, month: 13))
    }

    func testTodayUsesLocalCivilDayButPickerSerializationDoesNotShiftIt() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-13T00:30:00Z"))
        for (zone, expected) in [("Asia/Tokyo", "2026-10-13"), ("America/Los_Angeles", "2026-10-12")] {
            let today = CalendarFieldValue.today(now: instant, timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
            XCTAssertEqual(try CalendarFieldValue.string(today, kind: "date"), expected)
        }
        for text in ["2026-03-08", "2026-11-01"] {
            XCTAssertEqual(try CalendarFieldValue.string(CalendarFieldValue.date(text, kind: "date"), kind: "date"), text)
        }
    }

    func testDefaultTitleUsesTypeAndOriginalRegistrationDayAndFollowsUntouchedType() throws {
        var revision = VaultRevision(templateId: "passport", createdAt: try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-10-12T23:30:00Z")
        ))
        let original = revision
        var state = EditorDefaultTitle()
        let japanese = Locale(identifier: "ja-JP-u-ca-japanese")
        state.initialize(revision: &revision, creating: true, locale: japanese,
                         timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        XCTAssertEqual(revision.title, "旅券（パスポート） 2026-10-13")
        XCTAssertEqual(revision.createdAt, original.createdAt)
        XCTAssertEqual(revision.recordId, original.recordId)
        revision.templateId = "bank-account"
        state.updateType(revision: &revision, locale: japanese)
        XCTAssertEqual(revision.title, "銀行口座 2026-10-13")
        state.initialize(revision: &revision, creating: true, locale: Locale(identifier: "en"),
                         timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        XCTAssertEqual(revision.title, "銀行口座 2026-10-13")
    }

    func testExistingSuppliedEditedAndIntentionallyClearedTitlesNeverRegenerate() {
        let locale = Locale(identifier: "en")
        for (creating, title) in [(false, ""), (false, "Existing"), (true, "  My title  ")] {
            var revision = VaultRevision(templateId: "passport", title: title)
            var state = EditorDefaultTitle()
            state.initialize(revision: &revision, creating: creating, locale: locale)
            revision.templateId = "bank-account"
            state.updateType(revision: &revision, locale: locale)
            XCTAssertEqual(revision.title, title)
        }
        for text in ["", "  Manual title  "] {
            var revision = VaultRevision(templateId: "passport")
            var state = EditorDefaultTitle()
            state.initialize(revision: &revision, creating: true, locale: locale)
            state.edit(text, revision: &revision)
            revision.templateId = "bank-account"
            state.updateType(revision: &revision, locale: locale)
            state.initialize(revision: &revision, creating: true, locale: locale)
            XCTAssertEqual(revision.title, text)
        }
    }
}
