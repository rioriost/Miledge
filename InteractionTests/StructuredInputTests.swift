import XCTest

@MainActor
final class StructuredInputInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws { continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 { print(app.debugDescription); capture("Structured input failure") }
        app.terminate(); app = nil
    }
    private func launch(_ scenario: String, locale: String = "en", large: Bool = false) {
        app.launchArguments = ["format-" + scenario, "-AppleLanguages", "(\(locale))", "-AppleLocale", locale]
        app.launchEnvironment["MILEDGE_UI_LOCALE"] = locale
        app.launchEnvironment["MILEDGE_UI_APPEARANCE"] = large ? "dark" : "light"
        app.launchEnvironment["MILEDGE_AX_TEXT"] = "large"
        if large { app.launchArguments.append("selection-largest"); app.launchEnvironment["MILEDGE_AX_TEXT"] = "ax3" }
        app.launch()
    }
    private func activate(_ element: XCUIElement) {
        makeReachable(element, in: app)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func feedback(_ id: String, contains text: String) {
        let field = app.descendants(matching: .any).matching(identifier: "input-check-" + id).firstMatch
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: 8)
    }
    private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = title + " AX"; tree.lifetime = .keepAlways; add(tree)
    }
    private func save() throws -> [[String: Any]] {
        #if os(iOS)
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        if !app.buttons["editor-save"].exists && app.buttons["OverflowBarButtonItem"].exists { activate(app.buttons["OverflowBarButtonItem"]) }
        #endif
        let button = app.buttons["editor-save"].exists ? app.buttons["editor-save"] : app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "保存"])).firstMatch
        activate(button)
        let result = app.staticTexts["saved-revision"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let bytes = try XCTUnwrap((result.value as? String)?.data(using: .utf8))
        let revision = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap(revision["sections"] as? [[String: Any]]).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
    }
    func testURLAndPortSuggestionsOnlyChangeTheSelectedField() throws {
        launch("server")
        feedback("url", contains: "Check the URL")
        feedback("port", contains: "1 to 65535")
        activate(app.buttons["url-add-scheme-url"])
        feedback("url", contains: "Format matches")
        activate(app.buttons["port-suggestions-port"])
        capture("Native port choices")
        activate(app.buttons["port-option-5432"])
        feedback("port", contains: "Format matches")
        capture("URL and port assistance")
        let port = app.textFields["field-input-port"]
        XCTAssertEqual(port.value as? String, "5432")
        activate(port)
        #if os(iOS)
        XCTAssertTrue(app.keys["1"].exists)
        #endif
        replaceSingleLineInput(port, with: "65536")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "input-check-port").firstMatch.exists)
        activate(app.textFields["field-input-url"])
        feedback("port", contains: "1 to 65535")
        capture("Port number keyboard and review")
        let values = try save()
        XCTAssertEqual(values.first { $0["id"] as? String == "url" }?["value"] as? String, "https://example.com")
        XCTAssertEqual(values.first { $0["id"] as? String == "port" }?["value"] as? String, "65536")
        XCTAssertEqual(values.first { $0["id"] as? String == "email" }?["value"] as? String, "name..test@example.com")
    }
    func testEmailChecksAfterLeavingField() throws {
        launch("email")
        feedback("email", contains: "Check the email")
        let email = app.textFields["field-input-email"]
        activate(email)
        let message = app.descendants(matching: .any).matching(identifier: "input-check-email").firstMatch
        XCTAssertFalse(message.exists)
        replaceSingleLineInput(email, with: "name+tag@example.com")
        XCTAssertFalse(message.exists)
        capture("Email typing without format feedback")
        activate(app.textFields["field-input-name"])
        feedback("email", contains: "Format matches")
        capture("Email format feedback after blur")
        let values = try save()
        XCTAssertEqual(values.first { $0["id"] as? String == "email" }?["value"] as? String, "name+tag@example.com")
    }
    func testCardWarningDoesNotRevealOrBlockSaving() throws {
        launch("card")
        feedback("cardNumber", contains: "check digit")
        XCTAssertTrue(app.secureTextFields["field-input-cardNumber"].exists)
        let message = app.descendants(matching: .any).matching(identifier: "input-check-cardNumber").firstMatch.label
        XCTAssertFalse(message.contains("4242"))
        capture("Concealed card with advisory")
        let values = try save()
        XCTAssertEqual(values.first { $0["id"] as? String == "cardNumber" }?["value"] as? String, "4242 4242 4242 4241")
    }
    func testDateOrderWarningPreservesNativePickerAndRawDates() throws {
        launch("dates")
        feedback("expiryDate", contains: "earlier")
        capture("Date order advisory")
        let values = try save()
        XCTAssertEqual(values.first { $0["id"] as? String == "expiryDate" }?["value"] as? String, "2025-10-17")
    }
    func testLargeJapaneseBankWarningCanBeSaved() throws {
        launch("bank", locale: "ja", large: true)
        feedback("iban", contains: "チェック桁")
        makeReachable(app.descendants(matching: .any).matching(identifier: "input-check-iban").firstMatch, in: app)
        capture("Japanese bank dark large text")
        let values = try save()
        XCTAssertEqual(values.first { $0["id"] as? String == "iban" }?["value"] as? String, "GB83 WEST 1234 5698 7654 32")
    }
    func testArabicServerAssistanceAndAccessibleNames() throws {
        launch("server", locale: "ar")
        feedback("port", contains: "65535")
        activate(app.buttons["url-add-scheme-url"])
        feedback("url", contains: "مطابق")
        capture("Arabic server assistance")
        try auditAccessibility(of: app, state: "structured Arabic server")
    }
}
