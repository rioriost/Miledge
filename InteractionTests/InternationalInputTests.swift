import XCTest

@MainActor
final class InternationalInputTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 { print(app.debugDescription); capture("International input failure") }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    private func launch(_ scenario: String, locale: String = "en", large: Bool = false) {
        app.launchArguments = ["international-" + scenario, "-AppleLanguages", "(\(locale))", "-AppleLocale", locale]
        app.launchEnvironment["MILEDGE_UI_LOCALE"] = locale
        app.launchEnvironment["MILEDGE_UI_APPEARANCE"] = large ? "dark" : "light"
        if large {
            app.launchArguments.append("selection-largest")
            app.launchEnvironment["MILEDGE_AX_TEXT"] = "ax3"
        }
        app.launch()
    }

    private func reach(_ element: XCUIElement) {
        #if os(macOS)
        for _ in 0..<12 {
            if element.exists && element.isHittable { break }
            let scroll = app.scrollViews.firstMatch
            scroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        #endif
        makeReachable(element, in: app)
    }

    private func activate(_ element: XCUIElement) {
        reach(element)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = title + " AX"; tree.lifetime = .keepAlways; add(tree)
    }

    private func selectCountry(_ country: String, control: String) {
        activate(app.buttons["field-choice-" + control])
        activate(app.searchFields.firstMatch)
        app.searchFields.firstMatch.typeText(country)
        if country == "JP" && control == "issuingCountry" { capture("Native country search") }
        activate(app.buttons["choice-" + country])
    }

    private func feedback(_ id: String, contains text: String) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.label.contains(text), element.label)
    }

    private func save() throws -> [[String: Any]] {
        #if os(iOS)
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        if !app.buttons["editor-save"].exists, app.buttons["OverflowBarButtonItem"].exists {
            activate(app.buttons["OverflowBarButtonItem"])
        }
        #endif
        let save = app.buttons["editor-save"].exists ? app.buttons["editor-save"]
            : app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "保存"])).firstMatch
        activate(save)
        let result = app.staticTexts["saved-revision"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let data = try XCTUnwrap((result.value as? String)?.data(using: .utf8))
        let revision = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        return sections.flatMap { $0["fields"] as? [[String: Any]] ?? [] }
    }

    func testPassportIssuerChangesCheckWithoutChangingNumber() throws {
        launch("passport")
        feedback("input-check-passportNumber", contains: "US passport")
        selectCountry("JP", control: "issuingCountry")
        feedback("input-check-passportNumber", contains: "format matches")
        capture("Passport Japanese issuer matching format")
        selectCountry("FR", control: "issuingCountry")
        feedback("input-check-passportNumber", contains: "vary by issuer")
        let fields = try save()
        XCTAssertEqual(fields.first { $0["id"] as? String == "passportNumber" }?["value"] as? String, "AB0123456")
    }

    func testPhoneRegionAndWarningDoNotBlockSaving() throws {
        launch("phone")
        feedback("input-check-phone", contains: "Choose the phone region")
        selectCountry("JP", control: "phone-region-phone")
        feedback("input-check-phone", contains: "format matches")
        let phone = app.textFields["field-input-phone"]
        activate(phone)
        replaceSingleLineInput(phone, with: "123")
        feedback("input-check-phone", contains: "Check the phone number")
        capture("Phone review message preserves save")
        let fields = try save()
        XCTAssertEqual(fields.first { $0["id"] as? String == "phone" }?["value"] as? String, "123")
        XCTAssertEqual(fields.first { $0["id"] as? String == "phone-region:phone" }?["value"] as? String, "JP")
    }

    func testNameDetailsPreserveLegacyNames() throws {
        launch("names")
        activate(app.buttons["add-name-details"])
        let middle = app.textFields["field-input-middleName"]
        activate(middle)
        for character in "Alex" { middle.typeText(String(character)) }
        capture("Optional personal name components")
        let fields = try save()
        for (id, expected) in [("name", "山田 Alex 太郎"), ("givenName", "太郎"), ("familyName", "山田"), ("middleName", "Alex")] {
            let matches = fields.filter { $0["id"] as? String == id }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?["value"] as? String, expected)
        }
    }

    func testAddressCountryChangePreservesPostalCode() throws {
        launch("address")
        activate(app.buttons["add-address-fields-address"])
        selectCountry("JP", control: "address-country")
        let postal = app.textFields["address-address-postalCode"]
        activate(postal)
        for character in "001-0001" { postal.typeText(String(character)) }
        XCTAssertEqual(postal.value as? String, "001-0001")
        feedback("input-check-postal-address", contains: "format matches")
        selectCountry("US", control: "address-country")
        feedback("input-check-postal-address", contains: "Check the postal code")
        capture("Postal code after country change")
        let fields = try save()
        let address = try XCTUnwrap(fields.first { $0["id"] as? String == "address" }?["value"] as? [String: String])
        XCTAssertEqual(address["postalCode"], "001-0001")
        XCTAssertEqual(address["country"], "US")
    }

    func testLargeJapaneseNamesRemainEditable() throws {
        launch("names-complete", locale: "ja", large: true)
        let middle = app.textFields["field-input-middleName"]
        activate(middle)
        #if os(iOS)
        // Use a Latin keyboard for Latin test text; this is not an IME composition test.
        for _ in 0..<4 {
            if app.keys["a"].exists || app.keys["A"].exists { break }
            let next = app.buttons["次のキーボード"]
            if next.exists { next.tap() }
        }
        #endif
        for character in "Alex" { middle.typeText(String(character)) }
        #if os(iOS)
        let keyboardTip = app.buttons["Continue"]
        if app.staticTexts["Quickly Change Keyboards"].exists, keyboardTip.exists { keyboardTip.tap() }
        #endif
        capture("Japanese names dark AX3 largest app font")
        XCTAssertEqual(middle.value as? String, "Alex")
        let fields = try save()
        XCTAssertEqual(fields.first { $0["id"] as? String == "middleName" }?["value"] as? String, "Alex")
    }

    func testArabicPassportFeedback() throws {
        launch("passport", locale: "ar")
        let message = app.descendants(matching: .any).matching(identifier: "input-check-passportNumber").firstMatch
        reach(message)
        capture("Arabic RTL passport advisory")
        XCTAssertTrue(message.label.contains("جوازات"))
    }
}
