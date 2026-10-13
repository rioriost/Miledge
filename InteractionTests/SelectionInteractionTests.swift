import XCTest

@MainActor
final class SelectionInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 { print(app.debugDescription); capture("Selection failure") }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    private func launch(_ scenario: String = "selection-empty", largest: Bool = false) {
        app.launchArguments = [scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largest { app.launchArguments.append("selection-largest") }
        app.launch()
    }

    private func activate(_ element: XCUIElement) {
        makeReachable(element, in: app)
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 5))
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func saved() throws -> [String: Any] {
        activate(app.buttons["Save"])
        let result = app.staticTexts["saved-revision"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let data = try XCTUnwrap((result.value as? String)?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func values(_ revision: [String: Any]) throws -> [String: String] {
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        var values: [String: String] = [:]
        for section in sections {
            for field in try XCTUnwrap(section["fields"] as? [[String: Any]]) {
                if let id = field["id"] as? String, let value = field["value"] as? String { values[id] = value }
            }
        }
        return values
    }

    private func chooseType(_ name: String, confirm: Bool) {
        #if os(macOS)
        activate(app.popUpButtons["item-type-picker"])
        let choice = app.menuItems[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        #else
        activate(app.buttons["item-type-picker"])
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        #endif
        let actions = app.buttons.matching(identifier: confirm ? "confirm-change-type" : "cancel-change-type")
        let action = actions.allElementsBoundByIndex.last ?? actions.firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        #if os(macOS)
        action.click()
        #else
        action.tap()
        #endif
    }

    func testCountrySearchChoosesStableCodeAndKeepsUntouchedValues() throws {
        launch(largest: true)
        activate(app.buttons["field-choice-issuingCountry"])
        let search = app.searchFields.firstMatch
        activate(search)
        search.typeText("JP")
        capture("Largest text searchable country")
        activate(app.buttons["choice-JP"])
        let revision = try saved()
        let fields = try values(revision)
        XCTAssertEqual(fields["issuingCountry"], "JP")
        XCTAssertEqual(fields["brand"], "Private custom brand")
        XCTAssertEqual(fields["issueDate"], "")
        XCTAssertEqual(fields["expiry"], "2031-09")
        XCTAssertEqual(fields["currency"], "USD")
        XCTAssertEqual(revision["title"] as? String, "Passport 2026-10-13")
    }

    func testCustomCountryAndShortPickerPreserveExactText() throws {
        launch()
        #if os(macOS)
        activate(app.popUpButtons["field-choice-brand"])
        let choice = app.menuItems["Visa"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        #else
        activate(app.buttons["field-choice-brand"])
        let choice = app.buttons["Visa"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        #endif
        activate(app.buttons["field-choice-issuingCountry"])
        activate(app.buttons["choice-custom"])
        let custom = app.textFields["field-custom-issuingCountry"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertEqual(custom.value as? String, "  historical issuer  ")
        activate(custom)
        replaceSingleLineInput(custom, with: "  Special authority  ")
        let fields = try values(saved())
        XCTAssertEqual(fields["issuingCountry"], "  Special authority  ")
        XCTAssertEqual(fields["brand"], "Visa")
    }

    func testOpeningAndCancellingEmptyDateDoesNotWriteToday() throws {
        launch()
        activate(app.buttons["field-calendar-issueDate"])
        capture("Empty date native calendar")
        activate(app.buttons["calendar-cancel"])
        XCTAssertEqual(try values(saved())["issueDate"], "")
    }

    func testDateDoneAndMonthChoiceStoreCanonicalValues() throws {
        launch()
        activate(app.buttons["field-calendar-issueDate"])
        activate(app.buttons["calendar-done"])
        activate(app.buttons["field-calendar-expiry"])
        #if os(macOS)
        activate(app.popUpButtons["calendar-month"])
        activate(app.menuItems["February"])
        #else
        activate(app.buttons["calendar-month"])
        activate(app.buttons["February"])
        #endif
        capture("Native month selector")
        activate(app.buttons["calendar-done"])
        let fields = try values(saved())
        let date = try XCTUnwrap(fields["issueDate"])
        XCTAssertNotNil(date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(date, formatter.string(from: Date()))
        XCTAssertEqual(fields["expiry"], "2031-02")
    }

    func testDateAndMonthClearAreExplicit() throws {
        launch("selection-dates", largest: true)
        activate(app.buttons["field-calendar-issueDate"])
        capture("Largest native date picker")
        activate(app.buttons["calendar-clear"])
        activate(app.buttons["field-calendar-expiry"])
        activate(app.buttons["calendar-clear"])
        let fields = try values(saved())
        XCTAssertEqual(fields["issueDate"], "")
        XCTAssertEqual(fields["expiry"], "")
    }

    func testOnlyConfirmedTypeChangesUpdateAutomaticTitle() throws {
        launch("selection-title")
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Passport 2026-10-13")
        chooseType("Reward Program", confirm: false)
        XCTAssertEqual(title.value as? String, "Passport 2026-10-13")
        chooseType("Reward Program", confirm: true)
        XCTAssertEqual(title.value as? String, "Reward Program 2026-10-13")
        activate(title)
        replaceSingleLineInput(title, with: "  My title  ")
        #if os(iOS)
        title.typeText("\n")
        #endif
        chooseType("Passport", confirm: true)
        XCTAssertEqual(title.value as? String, "  My title  ")
        activate(title)
        replaceSingleLineInput(title, with: "")
        #if os(iOS)
        title.typeText("\n")
        #endif
        chooseType("Reward Program", confirm: true)
        XCTAssertEqual(title.value as? String, title.placeholderValue)
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        capture("Intentionally cleared title after type change")
    }
}
