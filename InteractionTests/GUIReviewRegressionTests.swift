import XCTest

/// Product navigation with synthetic records; these tests never unlock a real vault.
@MainActor
final class GUIReviewRegressionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 {
            print(app.debugDescription)
            capture("GUI review failure")
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    private func launch(_ scenario: String = "navigation", locale: String = "en") {
        app.launchArguments = [scenario, "-AppleLanguages", "(\(locale))", "-AppleLocale", locale]
        app.launchEnvironment["MILEDGE_UI_LOCALE"] = locale
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

    // A system confirmation may extend beyond the app's content frame on iPad.
    // Scrolling the presenting form can dismiss it instead of reaching its action.
    private func confirm(_ identifier: String) {
        let matches = app.buttons.matching(identifier: identifier)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))
        capture("Confirmation before action")
        // SwiftUI exposes both the confirmation's wrapper and its nested button.
        let element = matches.allElementsBoundByIndex.last!
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ state: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = state
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(state) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private var typePicker: XCUIElement {
        #if os(macOS)
        app.popUpButtons["item-type-picker"]
        #else
        app.buttons["item-type-picker"]
        #endif
    }

    private func chooseType(_ name: String) {
        activate(typePicker)
        #if os(macOS)
        let choice = app.menuItems[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        #else
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        #endif
    }

    private var templateSearch: XCUIElement {
        #if os(macOS)
        app.sheets.searchFields.firstMatch
        #else
        app.searchFields.firstMatch
        #endif
    }

    func testJapaneseSearchFindsLocalizedTypes() throws {
        for (query, identifier) in [("クレジット", "credit-card"), ("銀行", "bank-account"), ("旅券", "passport")] {
            launch(locale: "ja")
            activate(app.buttons["category-all"])
            activate(app.buttons["ledger-add"])
            activate(templateSearch)
            templateSearch.typeText(query)
            let choice = templateChoice(identifier, in: app)
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "Localized search must find \(identifier)")
            capture("Japanese type search \(identifier)")
            activateTemplate(identifier, in: app)
            XCTAssertTrue(app.textFields["タイトル"].waitForExistence(timeout: 5))
            capture("Japanese editor \(identifier)")
            app.terminate()
        }
    }

    func testArabicCreationUsesLocalizedSinglePresentation() throws {
        launch(locale: "ar")
        activate(app.buttons["category-all"])
        // The category's add action is the same product command in every locale.
        #if os(macOS)
        app.typeKey("n", modifierFlags: .command)
        #else
        activate(app.buttons["ledger-add"])
        #endif
        activateTemplate("credit-card", in: app)
        XCTAssertTrue(app.buttons["حفظ"].waitForExistence(timeout: 5))
        capture("Arabic credit card editor")
        try auditAccessibility(of: app, state: "Arabic credit card editor")
    }

    func testFiftyFieldDetailCanReachLastValue() {
        launch("navigation-long-detail")
        activate(app.buttons["category-credentials"])
        activate(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic API")).firstMatch)
        let last = app.staticTexts["Synthetic value 50"]
        let detail = app.descendants(matching: .any).matching(identifier: "item-detail-form").firstMatch
        for _ in 0..<30 {
            if last.exists, last.isHittable, app.frame.contains(last.frame) { break }
            #if os(macOS)
            detail.scroll(byDeltaX: 0, deltaY: -600)
            #else
            detail.swipeUp()
            #endif
        }
        XCTAssertTrue(last.exists)
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(app.frame.contains(last.frame))
        capture("Fifty field detail end")
    }

    func testChangingTypeCanReturnAndKeepsTitleAfterExplicitConfirmation() {
        launch()
        activate(app.buttons["category-all"])
        activate(app.buttons["ledger-add"])
        activateTemplate("credit-card", in: app)
        let typeDisplay = typePicker
        XCTAssertTrue(typeDisplay.waitForExistence(timeout: 5))
        XCTAssertEqual(typeDisplay.value as? String, "Credit Card")
        activate(app.textFields["Title"])
        app.textFields["Title"].typeText("Synthetic retained title")
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Synthetic retained title"), object: app.textFields["Title"])
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["change-item-type"].exists)
        chooseType("Document")
        confirm("cancel-change-type")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Synthetic retained title")
        XCTAssertEqual(typeDisplay.value as? String, "Credit Card")
        chooseType("Document")
        confirm("confirm-change-type")
        let updatedType = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Document"), object: typeDisplay)
        XCTAssertEqual(XCTWaiter.wait(for: [updatedType], timeout: 5), .completed)
        XCTAssertEqual(app.textFields["Title"].value as? String, "Synthetic retained title")
        XCTAssertFalse(app.secureTextFields["field-input-cardNumber"].exists)
        capture("Changed type retains title")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts["Synthetic retained title"].waitForExistence(timeout: 5))
    }

    func testAttachmentRemovalKeepsOriginalBytesAndHistory() {
        launch("attachments")
        activate(app.buttons["category-all"])
        activate(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic files")).firstMatch)
        XCTAssertTrue(app.buttons["preview-attachment-40000000-0000-0000-0000-000000000001"].waitForExistence(timeout: 5))
        capture("Attachment detail actions")
        activate(app.buttons["Edit"])
        activate(app.buttons["remove-attachment-40000000-0000-0000-0000-000000000001"])
        confirm("confirm-remove-attachment")
        activate(app.buttons["Save"])
        XCTAssertFalse(app.buttons["preview-attachment-40000000-0000-0000-0000-000000000001"].exists)
        activate(app.buttons["Test files"])
        #if os(macOS)
        activate(app.menuItems["Inspect attachment history"])
        #else
        activate(app.buttons["Inspect attachment history"])
        #endif
        XCTAssertEqual(app.staticTexts["attachment-inspection"].value as? String, "revisions=2;current=1;original=intact")
        capture("Attachment unlinked with historical bytes intact")
    }

    func testTypeChangeRetainsInvalidCustomBufferUntilCorrected() throws {
        launch("type-change-custom")
        let field = app.textFields["field-input-50000000-0000-0000-0000-000000000002"]
        activate(field)
        field.typeText("-")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        #if os(iOS)
        let form = app.descendants(matching: .any).matching(identifier: "item-editor-form").firstMatch
        for _ in 0..<8 {
            if typePicker.exists, typePicker.isHittable { break }
            form.swipeDown()
        }
        #endif
        chooseType("Document")
        confirm("confirm-change-type")
        makeReachable(field, in: app)
        XCTAssertEqual(field.value as? String, "-")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        capture("Custom invalid buffer retained after type change")
        activate(field)
        replaceSingleLineInput(field, with: "-5.000")
        XCTAssertEqual(field.value as? String, "-5.000")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        activate(app.buttons["Save"])
        let saved = app.staticTexts["saved-revision"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let data = try XCTUnwrap((saved.value as? String)?.data(using: .utf8))
        let revision = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(revision["templateId"] as? String, "document")
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        let custom = try XCTUnwrap(sections.first { $0["id"] as? String == "50000000-0000-0000-0000-000000000001" })
        let fields = try XCTUnwrap(custom["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["value"] as? String, "-5.000")
    }

    func testCustomFieldCanBeRemovedWithoutDiscardingTitle() throws {
        launch("type-change-custom")
        XCTAssertFalse(app.buttons["field-options-50000000-0000-0000-0000-000000000002"].exists)
        activate(app.buttons["remove-field-50000000-0000-0000-0000-000000000002"])
        confirm("confirm-remove-field")
        XCTAssertTrue(app.textFields["field-input-50000000-0000-0000-0000-000000000002"].waitForNonExistence(timeout: 5))
        activate(app.buttons["Save"])
        let saved = app.staticTexts["saved-revision"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let data = try XCTUnwrap((saved.value as? String)?.data(using: .utf8))
        let revision = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(revision["title"] as? String, "Synthetic custom draft")
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        XCTAssertFalse(sections.contains { ($0["fields"] as? [[String: Any]])?.contains { $0["id"] as? String == "50000000-0000-0000-0000-000000000002" } == true })
    }

    func testAttachmentPreviewAndExportCancellationReturnToDetail() {
        launch("attachments")
        activate(app.buttons["category-all"])
        activate(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic files")).firstMatch)
        let id = "40000000-0000-0000-0000-000000000001"
        activate(app.buttons["preview-attachment-\(id)"])
        #if os(iOS)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "No personal information.")).firstMatch.waitForExistence(timeout: 15))
        #endif
        capture("Synthetic PDF preview")
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        activate(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"])
        XCTAssertTrue(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].waitForNonExistence(timeout: 5))
        #endif
        XCTAssertTrue(app.buttons["export-attachment-\(id)"].waitForExistence(timeout: 5))
        activate(app.buttons["export-attachment-\(id)"])
        capture("Synthetic PDF export destination")
        #if os(macOS)
        activate(app.buttons["Cancel"])
        #else
        let pickerBar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(pickerBar.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            // Compact Files presents a draggable sheet. Dismiss by its header
            // when the system's cancel wrapper has no actionable button.
            pickerBar.swipeDown()
        }
        XCTAssertTrue(pickerBar.waitForNonExistence(timeout: 5))
        #endif
        XCTAssertTrue(app.buttons["preview-attachment-\(id)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preview-attachment-\(id)"].isHittable)
        XCTAssertFalse(app.alerts["Attachment unavailable"].exists)
        capture("Attachment detail after export cancellation")
    }
}
