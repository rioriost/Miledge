import XCTest

@MainActor
final class TypedInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
            app.launchArguments = ["validation", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let testRun, testRun.failureCount > 0 {
                print(app.debugDescription)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Synthetic failure accessibility tree"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "Synthetic failure screenshot"
                image.lifetime = .keepAlways
                add(image)
            }
            app.terminate()
            app = nil
        }
        try await super.tearDown()
    }

    private func assertSaveRejected() {
        activate(app.buttons["Save"])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Check the fields before saving."].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["saved-revision"].exists)
        activate(app.alerts.buttons["OK"])
    }

    private func launch(_ scenario: String) {
        app.launchArguments[0] = scenario
        app.launchEnvironment["MILEDGE_AX_TEXT"] = "large"
        app.launch()
        if scenario.hasPrefix("conflict") || ["clipboard", "organization-ledger", "related-ledger"].contains(scenario) {
            openAllItems()
        }
    }

    private func openAllItems() {
        let category = app.buttons["category-all"]
        if category.waitForExistence(timeout: 3), category.isHittable { activate(category) }
    }

    private func unlockLedger() {
        activate(app.buttons["Unlock"])
        openAllItems()
    }

    private func activate(_ element: XCUIElement) {
        #if os(iOS)
        if !element.exists || !element.isHittable || !app.frame.contains(element.frame) {
            makeReachable(element, in: app)
        }
        #else
        if !element.exists || !element.isHittable {
            makeReachable(element, in: app)
        }
        #endif
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 5))
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func visibilityButton(_ action: String) -> XCUIElement {
        app.buttons.matching(identifier: "field-visibility").matching(NSPredicate(
            format: "label BEGINSWITH %@", action + " "
        )).firstMatch
    }

    private func replace(_ element: XCUIElement, with text: String) {
        activate(element)
        #if os(macOS)
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
        #else
        let existing = element.value as? String ?? ""
        if !existing.isEmpty, existing != element.placeholderValue {
            if element.elementType == .searchField {
                activate(element.buttons["Clear text"])
                activate(element)
                element.typeText(text)
                XCTAssertEqual(element.value as? String, text.isEmpty ? element.placeholderValue : text)
                return
            }
            if element.elementType == .textField {
                replaceSingleLineInput(element, with: text)
                return
            }
            element.press(forDuration: 1)
            let selectAll = app.descendants(matching: .any).matching(identifier: "Select All").firstMatch
            for _ in 0..<4 {
                if selectAll.waitForExistence(timeout: 1) { break }
                let next = app.buttons["Next Page"]
                if !next.exists { break }
                activate(next)
            }
            activate(selectAll)
        }
        if text.isEmpty { element.typeText(XCUIKeyboardKey.delete.rawValue) }
        else { for character in text { element.typeText(String(character)) } }
        #endif
    }

    private func savedRevision() throws -> [String: Any] {
        activate(app.buttons["Save"])
        let saved = app.staticTexts["saved-revision"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let data = try XCTUnwrap((saved.value as? String)?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func savedField() throws -> [String: Any] {
        let revision = try savedRevision()
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        let fields = try XCTUnwrap(sections.first?["fields"] as? [[String: Any]])
        return try XCTUnwrap(fields.first)
    }

    private func savedValue() throws -> Any {
        try XCTUnwrap(try savedField()["value"])
    }

    private func toggle(_ label: String) {
        #if os(macOS)
        activate(app.checkBoxes[label])
        #else
        let toggle = app.switches[label]
        makeReachable(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let previous = toggle.value as? String
        XCTAssertTrue(previous == "0" || previous == "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, previous == "1" ? "0" : "1")
        #endif
    }

    private func ledgerRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private let relatedSource = "00000000-0000-0000-0000-000000000001"
    private let relatedBravo = "00000000-0000-0000-0000-000000000002"
    private let relatedCharlie = "00000000-0000-0000-0000-000000000003"
    private let relatedDeleted = "00000000-0000-0000-0000-000000000004"
    private let relatedConflict = "00000000-0000-0000-0000-000000000005"
    private let relatedMissing = "00000000-0000-0000-0000-000000000006"

    private func addRelatedItem(_ recordId: String) {
        let add = app.buttons["Add related item"]
        #if !os(macOS)
        if !add.isHittable { app.swipeUp() }
        #endif
        activate(add)
        activate(app.buttons["related-choice-\(recordId)"])
    }

    private func showLedgerList() {
        #if !os(macOS)
        if !app.buttons["Lock"].firstMatch.isHittable {
            activate(app.navigationBars.buttons.matching(NSPredicate(
                format: "label IN %@", ["All", "Favorites", "Credentials", "Finances", "Records", "Conflicts"]
            )).firstMatch)
        }
        #endif
    }

    private func openCategory(_ id: String) {
        let category = app.buttons["category-\(id)"]
        #if os(iOS)
        if !app.scrollViews["ledger-categories"].isHittable {
            showLedgerList()
            activate(app.navigationBars.buttons["Miledge"])
        }
        #endif
        activate(category)
    }

    func testCategoryListDetailFlowAndPrivateSearch() throws {
        launch("navigation")
        XCTAssertEqual(app.buttons["category-all"].value as? String, "3 items")
        XCTAssertEqual(app.buttons["category-credentials"].value as? String, "1 item")
        XCTAssertEqual(app.buttons["category-finances"].value as? String, "1 item")
        XCTAssertEqual(app.buttons["category-records"].value as? String, "1 item")
        XCTAssertEqual(app.buttons["category-conflicts"].value as? String, "0 items")
        try auditAccessibility(of: app, state: "category navigation")
        openCategory("credentials")
        XCTAssertTrue(ledgerRow("Synthetic API").waitForExistence(timeout: 5))
        XCTAssertFalse(ledgerRow("Synthetic Card").exists)
        XCTAssertFalse(app.debugDescription.contains("Never search this secret"))
        activate(ledgerRow("Synthetic API"))
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.debugDescription.contains("Never search this secret"))
        showLedgerList()
        replace(app.searchFields.firstMatch, with: "Never search this secret")
        XCTAssertFalse(ledgerRow("Synthetic API").exists)
        replace(app.searchFields.firstMatch, with: "Work")
        XCTAssertTrue(ledgerRow("Synthetic API").exists)
    }

    func testCreationUsesOnePresentationAndSelectsSavedItemThroughLockReload() {
        launch("navigation")
        openCategory("records")
        activate(app.buttons["Add"])
        XCTAssertTrue(templateChoice("document", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(templateChoice("credit-card", in: app).exists)
        activateTemplate("document", in: app)
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Do not store health information."].exists)
        replace(app.textFields["Title"], with: "Synthetic new document")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic new document"].exists)
        showLedgerList()
        activate(app.buttons["Lock"])
        unlockLedger()
        activate(ledgerRow("Synthetic new document"))
        XCTAssertTrue(app.staticTexts["Synthetic new document"].waitForExistence(timeout: 5))
    }

    func testCreationCancellationAndFailedSaveRetainDataForRetry() {
        launch("navigation-save-failure")
        openCategory("records")
        activate(app.buttons["Add"])
        activate(app.buttons["Cancel"])
        XCTAssertTrue(ledgerRow("Synthetic Document").exists)
        activate(app.buttons["Add"])
        activateTemplate("document", in: app)
        replace(app.textFields["Title"], with: "Synthetic cancelled")
        activate(app.buttons["Cancel"])
        XCTAssertFalse(ledgerRow("Synthetic cancelled").exists)
        activate(app.buttons["Add"])
        activateTemplate("document", in: app)
        replace(app.textFields["Title"], with: "Synthetic retry")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.alerts["Unable to complete the action"].waitForExistence(timeout: 5))
        activate(app.alerts.buttons["OK"])
        XCTAssertEqual(app.textFields["Title"].value as? String, "Synthetic retry")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        showLedgerList()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Synthetic retry")).count, 1)
    }

    func testEditingKeepsRecordSelectionAndCategorySwitchDoesNotShowStaleDetail() {
        launch("navigation")
        openCategory("credentials")
        activate(ledgerRow("Synthetic API"))
        activate(app.buttons["Edit"])
        replace(app.textFields["Title"], with: "Synthetic renamed API")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts["Synthetic renamed API"].waitForExistence(timeout: 5))
        openCategory("finances")
        XCTAssertFalse(app.staticTexts["Synthetic renamed API"].exists)
        activate(ledgerRow("Synthetic Card"))
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        showLedgerList()
        activate(app.buttons["Lock"])
        unlockLedger()
        XCTAssertTrue(ledgerRow("Synthetic renamed API").waitForExistence(timeout: 5))
        XCTAssertTrue(ledgerRow("Synthetic Card").exists)
        XCTAssertTrue(ledgerRow("Synthetic Document").exists)
    }

    func testRelatedNavigationRevealsTargetOutsideCategoryAndSearch() {
        launch("navigation")
        openCategory("credentials")
        replace(app.searchFields.firstMatch, with: "Work")
        activate(ledgerRow("Synthetic API"))
        activate(app.buttons["related-open-30000000-0000-0000-0000-000000000002"])
        XCTAssertTrue(app.staticTexts["Synthetic Card"].waitForExistence(timeout: 5))
        showLedgerList()
        XCTAssertTrue(ledgerRow("Synthetic API").exists)
        XCTAssertTrue(ledgerRow("Synthetic Document").exists)
    }

    func testBackgroundLockDiscardsCreationAndReturnsToCategories() {
        launch("navigation")
        openCategory("records")
        activate(app.buttons["Add"])
        activateTemplate("document", in: app)
        replace(app.textFields["Title"], with: "Synthetic interrupted draft")
        #if os(macOS)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Title"].exists)
        activate(app.buttons["Unlock"])
        XCTAssertTrue(app.buttons["category-all"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["category-all"].value as? String, "3 items")
        openAllItems()
        XCTAssertFalse(ledgerRow("Synthetic interrupted draft").exists)
    }

    private let conflictAlpha = "10000000-0000-0000-0000-000000000002"
    private let conflictBeta = "10000000-0000-0000-0000-000000000003"
    private let conflictGamma = "10000000-0000-0000-0000-000000000004"

    private func reviewConflict(_ identifier: String = "10000000-0000-0000-0000-000000000003") {
        activate(ledgerRow("Synthetic conflict Alpha"))
        activate(app.buttons["Resolve conflict"])
        activate(app.buttons["conflict-version-\(identifier)"])
    }

    private func resolveVersionAction(deleted: Bool = false) -> XCUIElement {
        let action = app.buttons["resolve-version"]
        #if os(iOS)
        if !action.waitForExistence(timeout: 2) {
            activate(app.navigationBars.buttons["OverflowBarButtonItem"])
            let menuAction = app.buttons[deleted ? "Keep deleted" : "Use this version"]
            XCTAssertTrue(menuAction.waitForExistence(timeout: 5))
            return menuAction
        }
        #endif
        return action
    }

    private func confirmVersion(deleted: Bool = false) {
        activate(resolveVersionAction(deleted: deleted))
        let confirmation = app.buttons["confirm-conflict-version"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(confirmation.label, deleted ? "Keep deleted" : "Use this version")
        activate(confirmation)
    }

    private func conflictHistory() throws -> [[String: Any]] {
        activate(app.buttons["Inspect test history"])
        let value = try XCTUnwrap(app.staticTexts["test-history"].value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]])
    }

    func testEditorAccessibilityAuditAndValidationKeepsSaveReachable() throws {
        launch("validation")
        try auditAccessibility(of: app, state: "editor")
        replace(app.textFields["Amount"], with: "invalid\n")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        assertSaveRejected()
        XCTAssertTrue(app.staticTexts["Use a decimal number with a dot."].exists)
        try auditAccessibility(of: app, state: "invalid editor")
        replace(app.textFields["Amount"], with: "9007199254740993.25\n")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertEqual(try savedValue() as? String, "9007199254740993.25")
    }

    func testConcealedFieldsAccessibilityAuditAndRevealIsolation() throws {
        launch("reveal")
        try auditAccessibility(of: app, state: "concealed fields")
        XCTAssertFalse(app.debugDescription.contains("Synthetic first secret"))
        XCTAssertFalse(app.debugDescription.contains("Synthetic second secret"))
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "First")).firstMatch
        activate(first)
        XCTAssertTrue((first.value as? String)?.contains("Synthetic first secret") == true)
        XCTAssertFalse(app.debugDescription.contains("Synthetic second secret"))
        try auditAccessibility(of: app, state: "revealed field")
        activate(first)
        XCTAssertFalse(app.debugDescription.contains("Synthetic first secret"))
    }

    func testRelatedPickerAccessibilityAuditAndSelection() throws {
        launch("related-empty")
        activate(app.buttons["Related items"])
        activate(app.buttons["Add related item"])
        XCTAssertTrue(app.buttons["related-choice-\(relatedBravo)"].waitForExistence(timeout: 5))
        try auditAccessibility(of: app, state: "related picker")
        activate(app.buttons["related-choice-\(relatedBravo)"])
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        let revision = try savedRevision()
        XCTAssertEqual(revision["linkedRecordIds"] as? [String], [relatedBravo])
    }

    func testConflictAccessibilityAuditAndCancellation() throws {
        launch("conflict")
        activate(ledgerRow("Synthetic conflict Alpha"))
        try auditAccessibility(of: app, state: "conflicted detail")
        activate(app.buttons["Resolve conflict"])
        XCTAssertTrue(app.buttons["conflict-version-\(conflictBeta)"].waitForExistence(timeout: 5))
        try auditAccessibility(of: app, state: "conflict choices")
        activate(app.buttons["conflict-version-\(conflictBeta)"])
        try auditAccessibility(of: app, state: "conflict review")
        let action = resolveVersionAction()
        XCTAssertTrue(action.isEnabled)
        activate(action)
        XCTAssertTrue(app.buttons["confirm-conflict-version"].firstMatch.waitForExistence(timeout: 5))
        #if os(iOS)
        let dismissPopup = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismissPopup.exists {
            let point = CGPoint(x: app.frame.minX + app.frame.width * 0.05, y: app.frame.midY)
            XCTAssertFalse(app.popovers.firstMatch.frame.contains(point))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        } else {
            activate(app.sheets.buttons["Cancel"].firstMatch)
        }
        #else
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        #endif
        XCTAssertTrue(app.buttons["confirm-conflict-version"].firstMatch.waitForNonExistence(timeout: 5))
        activate(app.buttons["Cancel"].firstMatch)
        XCTAssertTrue(app.buttons["Resolve conflict"].waitForExistence(timeout: 5))
        XCTAssertEqual(try conflictHistory().count, 2)
    }

    func testConflictChoiceAppendsAllParentsAndKeepsExactVersionThroughLockReload() throws {
        launch("conflict")
        reviewConflict()
        XCTAssertFalse(app.debugDescription.contains("0002 secret"))
        XCTAssertFalse(app.buttons["Edit"].isHittable)
        XCTAssertFalse(app.staticTexts["Item unavailable"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "10000000-0000-0000-0000-000000000001")
        ).firstMatch.exists)
        confirmVersion()
        XCTAssertTrue(app.buttons["resolve-version"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Resolve conflict"].exists)
        showLedgerList()
        activate(app.buttons["Lock"])
        unlockLedger()
        activate(ledgerRow("Synthetic conflict Beta"))
        XCTAssertFalse(app.buttons["Resolve conflict"].exists)
        let history = try conflictHistory()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0]["title"] as? String, "Synthetic conflict Alpha")
        XCTAssertEqual(history[1]["title"] as? String, "Synthetic conflict Beta")
        let current = try XCTUnwrap(history.last)
        XCTAssertEqual(Set(try XCTUnwrap(current["parentRevisionIds"] as? [String])), [conflictAlpha, conflictBeta])
        XCTAssertEqual(current["tags"] as? [String], ["Keep Beta"])
        XCTAssertEqual(current["sections"] as? NSArray, history[1]["sections"] as? NSArray)
        XCTAssertEqual(current["linkedRecordIds"] as? [String], history[1]["linkedRecordIds"] as? [String])
    }

    func testCancellingConflictReviewNeverAddsARevision() throws {
        launch("conflict")
        reviewConflict()
        activate(app.buttons["Cancel"])
        XCTAssertTrue(app.buttons["Resolve conflict"].waitForExistence(timeout: 5))
        XCTAssertEqual(try conflictHistory().count, 2)
    }

    func testConflictDeletionRequiresExplicitChoiceAndPreservesBothOriginalVersions() throws {
        launch("conflict-delete")
        reviewConflict()
        XCTAssertTrue(app.staticTexts["Deletion revision"].exists)
        confirmVersion(deleted: true)
        XCTAssertTrue(app.buttons["resolve-version"].waitForNonExistence(timeout: 5))
        showLedgerList()
        XCTAssertTrue(app.staticTexts["No items"].waitForExistence(timeout: 5))
        let history = try conflictHistory()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0]["deleted"] as? Bool, false)
        XCTAssertEqual(history[1]["deleted"] as? Bool, true)
        XCTAssertEqual(history.last?["deleted"] as? Bool, true)
        XCTAssertEqual(Set(try XCTUnwrap(history.last?["parentRevisionIds"] as? [String])),
                       [conflictAlpha, conflictBeta])
    }

    func testConflictCanRetainLiveVersionInsteadOfConcurrentDeletion() throws {
        launch("conflict-delete")
        reviewConflict(conflictAlpha)
        confirmVersion()
        XCTAssertTrue(app.staticTexts["Synthetic conflict Alpha"].waitForExistence(timeout: 5))
        let history = try conflictHistory()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last?["deleted"] as? Bool, false)
        XCTAssertEqual(history.last?["sections"] as? NSArray, history[0]["sections"] as? NSArray)
    }

    func testUnsupportedOrMixedScopeVersionsCanBeReviewedButNotResolved() throws {
        for scenario in ["conflict-unsupported", "conflict-scope"] {
            launch(scenario)
            activate(ledgerRow("Synthetic conflict Alpha"))
            activate(app.buttons["Resolve conflict"])
            XCTAssertTrue(app.staticTexts["These versions cannot be resolved by this app."].exists)
            activate(app.buttons["conflict-version-\(conflictAlpha)"])
            XCTAssertFalse(app.buttons["resolve-version"].isEnabled)
            activate(app.buttons["Cancel"])
            XCTAssertEqual(try conflictHistory().count, 2)
            app.terminate()
        }
    }

    func testNewConcurrentVersionRequiresReloadBeforeResolution() throws {
        launch("conflict-stale")
        reviewConflict()
        confirmVersion()
        XCTAssertTrue(app.alerts["Unable to resolve conflict"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Versions changed. Reload before resolving."].exists)
        activate(app.alerts.buttons["OK"])
        activate(app.buttons["Reload versions"])
        activate(app.buttons["conflict-version-\(conflictGamma)"])
        confirmVersion()
        let history = try conflictHistory()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.last?["title"] as? String, "Synthetic conflict Gamma")
        XCTAssertEqual(Set(try XCTUnwrap(history.last?["parentRevisionIds"] as? [String])),
                       [conflictAlpha, conflictBeta, conflictGamma])
    }

    func testFailedConflictWriteKeepsTheReviewOpenAndCanBeRetried() throws {
        launch("conflict-retry")
        reviewConflict()
        confirmVersion()
        XCTAssertTrue(app.alerts["Unable to resolve conflict"].waitForExistence(timeout: 5))
        activate(app.alerts.buttons["OK"])
        XCTAssertTrue(app.buttons["resolve-version"].exists)
        confirmVersion()
        XCTAssertEqual(try conflictHistory().count, 3)
    }

    func testFailedConflictReloadDoesNotDismissOrReplaceReviewedVersions() throws {
        launch("conflict-reload-failure")
        activate(ledgerRow("Synthetic conflict Alpha"))
        activate(app.buttons["Resolve conflict"])
        activate(app.buttons["Reload versions"])
        XCTAssertTrue(app.alerts["Unable to resolve conflict"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Versions could not be reloaded. Try again."].exists)
        activate(app.alerts.buttons["OK"])
        XCTAssertTrue(app.buttons["conflict-version-\(conflictAlpha)"].exists)
        activate(app.buttons["Reload versions"])
        activate(app.buttons["Cancel"])
        XCTAssertEqual(try conflictHistory().count, 2)
    }

    func testBackgroundLockDiscardsConflictReviewWithoutWritingHistory() throws {
        launch("conflict")
        reviewConflict()
        #if os(macOS)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resolve-version"].exists)
        unlockLedger()
        XCTAssertTrue(ledgerRow("Synthetic conflict Alpha").waitForExistence(timeout: 5))
        XCTAssertEqual(try conflictHistory().count, 2)
    }

    private func clipboardAction(_ action: String) {
        activate(app.buttons["Test clipboard"])
        activate(app.buttons[action])
    }

    private func inspectClipboard() -> String? {
        clipboardAction("Inspect test clipboard")
        return app.staticTexts["test-clipboard"].value as? String
    }

    private func copyDetailField(at index: Int) {
        let field = app.buttons.matching(identifier: "copy-value").element(boundBy: index)
        activate(field)
        #if os(iOS)
        let action = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy ")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        activate(action)
        #endif
    }

    #if os(iOS)
    func testDismissingCopyMenuConcealsWithoutCopying() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        let field = app.buttons.matching(identifier: "copy-value").firstMatch
        activate(field)
        XCTAssertTrue(app.menuItems["Copy Synthetic key"].waitForExistence(timeout: 5))
        app.navigationBars.staticTexts.firstMatch.tap()
        XCTAssertTrue(app.menuItems["Copy Synthetic key"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Concealed value")
        XCTAssertEqual(inspectClipboard(), "Empty")
    }
    #endif

    func testDetailTapRevealsThenNativeCopyMenuConceals() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        XCTAssertFalse(app.debugDescription.contains("Exact Case"))
        XCTAssertEqual(app.buttons.matching(identifier: "field-visibility").count, 0)
        let field = app.buttons.matching(identifier: "copy-value").firstMatch
        #if os(macOS)
        field.hover()
        XCTAssertTrue(app.debugDescription.contains("Exact Case"))
        activate(field)
        #else
        activate(field)
        XCTAssertTrue(app.menuItems["Copy Synthetic key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.debugDescription.contains("Exact Case"))
        XCTAssertFalse(app.debugDescription.contains("postalCode"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native floating copy menu"
        image.lifetime = .keepAlways
        add(image)
        activate(app.menuItems["Copy Synthetic key"])
        #endif
        XCTAssertEqual(field.value as? String, "Copied")
        XCTAssertFalse(app.debugDescription.contains("Exact Case"))
        XCTAssertEqual(inspectClipboard(), "  Exact Case\n0001\nالعربية e\u{301} \n")
    }

    #if os(iOS)
    func testJapaneseNativeControlsInDarkAppearance() {
        app.launchEnvironment["MILEDGE_UI_LOCALE"] = "ja"
        app.launchEnvironment["MILEDGE_UI_APPEARANCE"] = "dark"
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        let field = app.buttons.matching(identifier: "copy-value").firstMatch
        activate(field)
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 5))
        captureNative("Japanese floating copy menu")
        activate(app.menuItems.firstMatch)
        XCTAssertFalse(app.debugDescription.contains("Exact Case"))
        activate(field)
        XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.debugDescription.contains("Exact Case"))
        activate(app.menuItems.firstMatch)
        launch("selection-dates")
        activate(app.buttons["field-calendar-issueDate"])
        makeReachable(app.buttons["calendar-done"], in: app)
        captureNative("Japanese inline calendar")
        activate(app.buttons["DatePicker.Show"])
        XCTAssertEqual(app.pickerWheels.count, 2)
        captureNative("Japanese month year selection")
    }

    private func captureNative(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    #endif

    func testExplicitCopyKeepsSecretConcealedAndPreservesExactMultilineUnicode() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        XCTAssertFalse(app.debugDescription.contains("Exact Case"))
        copyDetailField(at: 0)
        XCTAssertTrue(app.buttons.matching(identifier: "copy-value").element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "copy-value").element(boundBy: 0).value as? String, "Copied")
        XCTAssertFalse(app.debugDescription.contains("Exact Case"))
        XCTAssertEqual(inspectClipboard(), "  Exact Case\n0001\nالعربية e\u{301} \n")
        clipboardAction("Expire test clipboard")
        XCTAssertEqual(inspectClipboard(), "Empty")
    }

    func testStructuredCopyUsesJSONWithoutDroppingUnknownValuesOrLeadingZeros() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        copyDetailField(at: 1)
        XCTAssertEqual(inspectClipboard(), "{\"future\":9007199254740993,\"postalCode\":\"000001\"}")
        XCTAssertFalse(app.staticTexts["000001"].exists)
    }

    func testManualLockClearsOwnedCopyButKeepsAnotherAppsReplacement() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        copyDetailField(at: 0)
        showLedgerList()
        activate(app.buttons["Lock"])
        XCTAssertEqual(inspectClipboard(), "Empty")
        unlockLedger()
        activate(ledgerRow("Synthetic copy source"))
        copyDetailField(at: 0)
        clipboardAction("Replace test clipboard")
        showLedgerList()
        activate(app.buttons["Lock"])
        XCTAssertEqual(inspectClipboard(), "Synthetic other clipboard")
    }

    func testCopyFailureIsVisibleAndNeverAcknowledgedAsCopied() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        clipboardAction("Fail next copy")
        copyDetailField(at: 0)
        XCTAssertTrue(app.alerts["Clipboard unavailable"].waitForExistence(timeout: 5))
        activate(app.alerts.buttons["OK"])
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "value == %@", "Copied")).firstMatch.exists)
        XCTAssertEqual(inspectClipboard(), "Empty")
    }

    func testSwitchingAppsLocksTheLedgerButKeepsTheCopyUntilExpiry() {
        launch("clipboard")
        activate(ledgerRow("Synthetic copy source"))
        copyDetailField(at: 0)
        #if os(macOS)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Concealed"].exists)
        XCTAssertEqual(inspectClipboard(), "  Exact Case\n0001\nالعربية e\u{301} \n")
        clipboardAction("Expire test clipboard")
        XCTAssertEqual(inspectClipboard(), "Empty")
    }

    func testRelatedEditsPreserveDuplicateMissingAndSelfReferencesAndOtherData() throws {
        launch("related")
        XCTAssertFalse(app.buttons["Remove related item"].exists)
        activate(app.buttons["Related items"])
        let remove = app.buttons.matching(identifier: "Remove related item")
        XCTAssertEqual(remove.count, 6)
        activate(remove.element(boundBy: 0))
        XCTAssertEqual(remove.count, 5)
        addRelatedItem(relatedCharlie)
        let revision = try savedRevision()
        XCTAssertEqual(revision["linkedRecordIds"] as? [String], [
            relatedBravo, relatedMissing, relatedSource, relatedDeleted, relatedConflict, relatedCharlie
        ])
        XCTAssertEqual(revision["tags"] as? [String], ["Keep tags"])
        XCTAssertEqual(revision["favorite"] as? Bool, true)
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        let fields = try XCTUnwrap(sections.first?["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["value"] as? String, "Synthetic untouched value")
    }

    func testRelatedPickerExcludesExistingDeletedAndConflictingItemsAndSearchesOnlyMetadata() throws {
        launch("related")
        activate(app.buttons["Related items"])
        let add = app.buttons["Add related item"]
        #if !os(macOS)
        if !add.isHittable { app.swipeUp() }
        #endif
        activate(add)
        for id in [relatedSource, relatedBravo, relatedDeleted, relatedConflict] {
            XCTAssertFalse(app.buttons["related-choice-\(id)"].exists)
        }
        XCTAssertTrue(app.buttons["related-choice-\(relatedCharlie)"].exists)
        launch("related-empty")
        activate(app.buttons["Related items"])
        activate(app.buttons["Add related item"])
        XCTAssertTrue(app.buttons["related-choice-\(relatedBravo)"].exists)
        let search = app.searchFields.firstMatch
        replace(search, with: "Never search this secret")
        XCTAssertFalse(app.buttons["related-choice-\(relatedBravo)"].exists)
        XCTAssertFalse(app.buttons["related-choice-\(relatedCharlie)"].exists)
        replace(search, with: "work")
        XCTAssertTrue(app.buttons["related-choice-\(relatedBravo)"].exists)
        XCTAssertFalse(app.buttons["related-choice-\(relatedCharlie)"].exists)
        replace(search, with: relatedCharlie)
        XCTAssertTrue(app.buttons["related-choice-\(relatedCharlie)"].exists)
        XCTAssertFalse(app.buttons["related-choice-\(relatedBravo)"].exists)
        replace(search, with: "Charlie")
        activate(app.buttons["related-choice-\(relatedCharlie)"])
        XCTAssertEqual(try savedRevision()["linkedRecordIds"] as? [String], [relatedCharlie])
    }

    func testRelatedLastRemovalKeepsTargetAndEmptyListCanBeSaved() throws {
        launch("related-empty")
        activate(app.buttons["Related items"])
        addRelatedItem(relatedBravo)
        activate(app.buttons["Remove related item"])
        XCTAssertFalse(app.buttons["Remove related item"].exists)
        XCTAssertEqual(try savedRevision()["linkedRecordIds"] as? [String], [])
    }

    func testRelatedCancelDiscardsChangesAndPickerExcludesTheCurrentRecord() throws {
        launch("related-ledger")
        activate(ledgerRow("Synthetic Alpha"))
        activate(app.buttons["Edit"])
        activate(app.buttons["Related items"])
        activate(app.buttons["Add related item"])
        XCTAssertFalse(app.buttons["related-choice-\(relatedSource)"].exists)
        activate(app.buttons["related-choice-\(relatedBravo)"])
        activate(app.buttons["Cancel"])
        XCTAssertFalse(app.buttons["related-open-\(relatedBravo)"].exists)
        activate(app.buttons["Edit"])
        activate(app.buttons["Related items"])
        XCTAssertFalse(app.buttons["Remove related item"].exists)
        activate(app.buttons["Add related item"])
        #if os(macOS)
        activate(app.buttons["Cancel"])
        #else
        activate(app.navigationBars["Add related item"].buttons["Cancel"])
        #endif
        XCTAssertFalse(app.buttons["Remove related item"].exists)
        activate(app.buttons["Cancel"])
    }

    func testRelatedSaveNavigationAndLockReloadUseRecordReferencesWithoutDeletingTargets() throws {
        launch("related-ledger")
        activate(ledgerRow("Synthetic Alpha"))
        activate(app.buttons["Edit"])
        activate(app.buttons["Related items"])
        addRelatedItem(relatedBravo)
        activate(app.buttons["Save"])
        let link = app.buttons["related-open-\(relatedBravo)"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        activate(link)
        XCTAssertTrue(app.staticTexts["Synthetic Bravo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Never search this secret"].exists)
        showLedgerList()
        activate(app.buttons["Lock"])
        XCTAssertFalse(app.buttons["related-open-\(relatedBravo)"].exists)
        unlockLedger()
        activate(ledgerRow("Synthetic Alpha"))
        XCTAssertTrue(app.buttons["related-open-\(relatedBravo)"].waitForExistence(timeout: 5))
        activate(app.buttons["Edit"])
        activate(app.buttons["Related items"])
        activate(app.buttons["Remove related item"])
        activate(app.buttons["Save"])
        XCTAssertFalse(app.buttons["related-open-\(relatedBravo)"].exists)
        showLedgerList()
        XCTAssertTrue(ledgerRow("Synthetic Bravo").exists)
    }

    func testRelatedUnavailableAndConflictingLinksAreRetainedButNotNavigable() {
        launch("related-detail")
        XCTAssertTrue(app.staticTexts.matching(identifier: "Item unavailable").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conflicting changes"].exists)
        XCTAssertTrue(app.staticTexts[relatedMissing].exists)
        for id in [relatedMissing, relatedSource, relatedDeleted, relatedConflict] {
            XCTAssertFalse(app.buttons["related-open-\(id)"].exists)
        }
        XCTAssertEqual(app.buttons.matching(identifier: "related-open-\(relatedBravo)").count, 2)
    }

    func testRelatedReadOnlySourceCannotChangeLinks() {
        launch("related-readonly")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertFalse(app.buttons["Related items"].isEnabled)
        XCTAssertFalse(app.buttons["Remove related item"].exists)
    }

    func testOrganizationEditsPreserveExactTagsAndUnchangedFieldData() throws {
        launch("organization")
        XCTAssertFalse(app.textFields["Tag"].exists)
        activate(app.buttons["Organization"])
        toggle("Favorite")
        activate(app.buttons.matching(identifier: "Remove tag").element(boundBy: 0))
        activate(app.buttons["Add tag"])
        let tags = app.textFields.matching(identifier: "Tag")
        XCTAssertEqual(tags.count, 4)
        replace(tags.element(boundBy: 3), with: "  New, Tag  ")
        let revision = try savedRevision()
        XCTAssertEqual(revision["tags"] as? [String], ["A", "A", "  Keep Case  ", "  New, Tag  "])
        XCTAssertEqual(revision["favorite"] as? Bool, true)
        XCTAssertEqual(revision["linkedRecordIds"] as? [String], ["11111111-2222-3333-4444-555555555555"])
        let sections = try XCTUnwrap(revision["sections"] as? [[String: Any]])
        let fields = try XCTUnwrap(sections.first?["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["value"] as? String, "Synthetic untouched value")
    }

    func testLastTagRemovalLeavesAnEmptyListWithoutChangingFavorite() throws {
        launch("organization-empty")
        activate(app.buttons["Organization"])
        activate(app.buttons["Add tag"])
        replace(app.textFields["Tag"], with: "Temporary")
        activate(app.buttons["Remove tag"])
        XCTAssertFalse(app.textFields["Tag"].exists)
        let revision = try savedRevision()
        XCTAssertEqual(revision["tags"] as? [String], [])
        XCTAssertEqual(revision["favorite"] as? Bool, false)
    }

    func testCancelDiscardsOrganizationChanges() throws {
        launch("organization-ledger")
        activate(ledgerRow("Synthetic Alpha"))
        activate(app.buttons["Edit"])
        activate(app.buttons["Organization"])
        toggle("Favorite")
        replace(app.textFields["Tag"], with: "Cancelled")
        activate(app.buttons["Cancel"])
        XCTAssertTrue(app.staticTexts["Alpha Tag"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Cancelled"].exists)
        activate(app.buttons["Edit"])
        activate(app.buttons["Organization"])
        XCTAssertEqual(app.textFields["Tag"].value as? String, "Alpha Tag")
        #if os(macOS)
        XCTAssertEqual(app.checkBoxes["Favorite"].value as? String, "0")
        #else
        XCTAssertEqual(app.switches["Favorite"].value as? String, "0")
        #endif
        activate(app.buttons["Cancel"])
    }

    func testSavedOrganizationUpdatesDetailAndListAndSurvivesLock() throws {
        launch("organization-ledger")
        activate(ledgerRow("Synthetic Alpha"))
        activate(app.buttons["Edit"])
        activate(app.buttons["Organization"])
        toggle("Favorite")
        replace(app.textFields["Tag"], with: "  Saved, Tag  ")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts["  Saved, Tag  "].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha Tag"].exists)
        showLedgerList()
        XCTAssertTrue(ledgerRow("Synthetic Alpha").label.contains("Favorite"))
        activate(app.buttons["Lock"])
        unlockLedger()
        XCTAssertTrue(ledgerRow("Synthetic Alpha").waitForExistence(timeout: 5))
        XCTAssertTrue(ledgerRow("Synthetic Alpha").label.contains("Favorite"))
        activate(ledgerRow("Synthetic Alpha"))
        XCTAssertTrue(app.staticTexts["  Saved, Tag  "].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha Tag"].exists)
    }

    func testFavoritesFilterCombinesTagSearchAndResetsOnLock() throws {
        launch("organization-ledger")
        XCTAssertTrue(ledgerRow("Synthetic Alpha").waitForExistence(timeout: 5))
        openCategory("favorites")
        XCTAssertFalse(ledgerRow("Synthetic Alpha").exists)
        XCTAssertTrue(ledgerRow("Synthetic Bravo").exists)
        let search = app.searchFields.firstMatch
        replace(search, with: "Alpha")
        XCTAssertFalse(ledgerRow("Synthetic Alpha").exists)
        XCTAssertFalse(ledgerRow("Synthetic Bravo").exists)
        replace(search, with: "Work")
        XCTAssertTrue(ledgerRow("Synthetic Bravo").exists)
        #if !os(macOS)
        if !app.buttons["Lock"].isHittable {
            activate(app.buttons["close"])
        }
        #endif
        activate(app.buttons["Lock"])
        XCTAssertFalse(ledgerRow("Synthetic Bravo").exists)
        unlockLedger()
        XCTAssertTrue(ledgerRow("Synthetic Alpha").waitForExistence(timeout: 5))
        XCTAssertTrue(ledgerRow("Synthetic Bravo").exists)
    }

    func testReadOnlyOrganizationCannotBeEditedOrSaved() {
        launch("organization-readonly")
        XCTAssertTrue(app.staticTexts["This item is read-only or no longer available."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        XCTAssertFalse(app.buttons["Organization"].isEnabled)
    }

    func testInvalidDecimalBlocksSaveAndCorrectionPreservesPrecision() throws {
        launch("validation")
        let input = app.textFields["Amount"]
        XCTAssertFalse(visibilityButton("Hide").exists)
        XCTAssertFalse(app.buttons["field-options-amount"].exists)
        launch("validation-concealed")
        activate(visibilityButton("Reveal"))
        replace(input, with: "not-a-number")
        XCTAssertTrue(app.staticTexts["Use a decimal number with a dot."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        assertSaveRejected()
        XCTAssertEqual(input.value as? String, "not-a-number")
        activate(visibilityButton("Hide"))
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        activate(visibilityButton("Reveal"))
        XCTAssertEqual(input.value as? String, "not-a-number")
        let exact = "9007199254740993.000001"
        replace(input, with: exact)
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertEqual(try savedValue() as? String, exact)
    }

    func testConcealedMultilineKeyRequiresRevealAndKeepsExactText() throws {
        launch("multiline")
        XCTAssertFalse(app.textViews["Key"].exists)
        activate(visibilityButton("Reveal"))
        let key = app.textViews["Key"]
        let exact = "  Exact Case\n001\n-----Synthetic Key-----\n"
        replace(key, with: exact)
        XCTAssertEqual(key.value as? String, exact)
        activate(visibilityButton("Hide"))
        XCTAssertFalse(key.exists)
        let field = try savedField()
        XCTAssertEqual(field["value"] as? String, exact)
        XCTAssertEqual(field["concealed"] as? Bool, true)
    }

    func testEyeButtonHidesCollectionWithoutChangingValuesOrConcealmentDefault() throws {
        launch("choices")
        let entries = app.textFields.matching(identifier: "Choice")
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(visibilityButton("Hide").exists)
        XCTAssertFalse(visibilityButton("Reveal").exists)
        launch("choices-concealed")
        XCTAssertEqual(entries.count, 0)
        activate(visibilityButton("Reveal"))
        activate(visibilityButton("Hide"))
        XCTAssertEqual(entries.count, 0)
        XCTAssertTrue(visibilityButton("Reveal").exists)
        try auditAccessibility(of: app, state: "eye-button hidden collection")
        activate(visibilityButton("Reveal"))
        XCTAssertEqual(entries.allElementsBoundByIndex.map { $0.value as? String }, ["B", "A", "A"])
        try auditAccessibility(of: app, state: "eye-button visible collection")
        activate(visibilityButton("Hide"))
        let field = try savedField()
        XCTAssertEqual(field["value"] as? [String], ["B", "A", "A"])
        XCTAssertEqual(field["concealed"] as? Bool, true)
    }

    func testConcealmentDefaultSettingsRemainSeparateFromEyeButton() throws {
        launch("conceal-settings")
        XCTAssertFalse(app.buttons["field-options-choices"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "Choice").count, 0)
        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.checkBoxes["display-conceal-values"]
        #else
        activate(app.buttons["display-settings"])
        let toggle = app.switches["display-conceal-values"]
        #endif
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        #if os(macOS)
        activate(toggle)
        app.typeKey("w", modifierFlags: .command)
        #else
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        activate(app.buttons["Done"])
        #endif
        XCTAssertEqual(app.textFields.matching(identifier: "Choice").count, 3)
        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        #else
        activate(app.buttons["display-settings"])
        #endif
        XCTAssertEqual(toggle.value as? String, "0")
        #if os(macOS)
        activate(toggle)
        app.typeKey("w", modifierFlags: .command)
        #else
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        activate(app.buttons["Done"])
        #endif
        XCTAssertEqual(app.textFields.matching(identifier: "Choice").count, 0)
        activate(visibilityButton("Reveal"))
        let field = try savedField()
        XCTAssertEqual(field["value"] as? [String], ["B", "A", "A"])
        XCTAssertEqual(field["concealed"] as? Bool, true)
    }

    func testDuplicateAddressNamesBlockSaveWithoutDroppingEitherValue() throws {
        launch("address")
        let names = app.textFields.matching(identifier: "Component name")
        replace(names.element(boundBy: 1), with: "alpha")
        XCTAssertEqual(names.element(boundBy: 1).value as? String, "alpha")
        XCTAssertTrue(app.staticTexts["Component names must be different."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        assertSaveRejected()
        XCTAssertEqual(names.count, 2)
        replace(names.element(boundBy: 1), with: "custom locality")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertEqual(try savedValue() as? [String: String], ["alpha": "001", "custom locality": "002"])
    }

    func testChoiceRemovalAndAdditionKeepOrderAndDuplicates() throws {
        launch("choices")
        activate(app.buttons.matching(identifier: "Remove choice").element(boundBy: 0))
        activate(app.buttons["Add choice"])
        let entries = app.textFields.matching(identifier: "Choice")
        replace(entries.element(boundBy: 2), with: "B")
        XCTAssertEqual(try savedValue() as? [String], ["A", "A", "B"])
    }

    func testGrowingCollectionsKeepSheetActionsReachableAndSaveExactOrder() throws {
        launch("choices")
        for _ in 0..<8 {
            activate(app.buttons["Add choice"])
            for label in ["Save", "Cancel"] {
                XCTAssertTrue(app.buttons[label].isHittable)
                XCTAssertTrue(app.frame.contains(app.buttons[label].frame))
            }
        }
        let remove = try XCTUnwrap(app.buttons.matching(identifier: "Remove choice")
            .allElementsBoundByIndex.last { $0.isHittable })
        activate(remove)
        XCTAssertEqual(try savedValue() as? [String], ["B", "A", "A"] + Array(repeating: "", count: 7))
    }

    func testAddressRemovalAndAdditionKeepRemainingValue() throws {
        launch("address")
        activate(app.buttons.matching(identifier: "Remove component").element(boundBy: 0))
        activate(app.buttons["Add component"])
        let names = app.textFields.matching(identifier: "Component name")
        let values = app.textFields.matching(identifier: "Value")
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(values.count, 2)
        replace(names.element(boundBy: 1), with: "custom street")
        replace(values.element(boundBy: 1), with: "003")
        XCTAssertEqual(try savedValue() as? [String: String], ["beta": "002", "custom street": "003"])
    }

    func testRecoveryCodeUsedStateKeepsOriginalIdentityAndWhitespace() throws {
        launch("recovery")
        #if os(macOS)
        activate(app.checkBoxes["Used"])
        #else
        let toggle = app.switches["Used"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        #endif
        XCTAssertFalse(visibilityButton("Hide").exists)
        XCTAssertFalse(visibilityButton("Reveal").exists)
        let entries = try XCTUnwrap(try savedValue() as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["id"] as? String, "stable-code-id")
        XCTAssertEqual(entries[0]["code"] as? String, " 0001 ")
        XCTAssertEqual(entries[0]["used"] as? Bool, true)
    }

    func testNewSecretAcceptsInputImmediatelyAndKeepsSavedConcealment() throws {
        launch("new-secret")
        let key = app.textViews["Key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let exact = "  New Key\n0001\n"
        replace(key, with: exact)
        XCTAssertTrue(visibilityButton("Hide").exists)
        activate(visibilityButton("Hide"))
        activate(visibilityButton("Reveal"))
        XCTAssertEqual(key.value as? String, exact)
        try auditAccessibility(of: app, state: "new secret directly editable")
        let field = try savedField()
        XCTAssertEqual(field["value"] as? String, exact)
        XCTAssertEqual(field["concealed"] as? Bool, true)
    }

    func testExistingSecretCanBeCopiedWithoutRevealingAndPublicFieldsHaveNoEyes() throws {
        launch("editor-copy")
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))
        makeReachable(app.textFields["Amount"], in: app)
        XCTAssertEqual(app.textFields["Amount"].value as? String, "9007199254740993.000001")
        makeReachable(app.buttons["editor-copy-key"], in: app)
        XCTAssertFalse(app.textViews["Key"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "field-visibility").count, 1)
        XCTAssertFalse(app.buttons["field-options-key"].exists)
        let concealed = app.staticTexts["field-input-key"]
        XCTAssertFalse(concealed.frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(concealed.frame))
        activate(app.buttons["editor-copy-key"])
        let result = app.staticTexts["editor-copied-value"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.value as? String, "  Exact Case\n0001\nالعربية e\u{301} \n")
        XCTAssertFalse(app.textViews["Key"].exists)
        try auditAccessibility(of: app, state: "copy existing secret without reveal")
    }

    func testEditorControlsStayReachableAtLargestAppFontWithoutRevealing() throws {
        launch("editor-copy-largest-font")
        let copy = app.buttons["editor-copy-key"]
        makeReachable(copy, in: app)
        activate(copy)
        let result = app.staticTexts["editor-copied-value"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.value as? String, "  Exact Case\n0001\nالعربية e\u{301} \n")
        XCTAssertFalse(app.textViews["Key"].exists)
        XCTAssertFalse(app.buttons["field-options-key"].exists)
        let concealed = app.staticTexts["field-input-key"]
        makeReachable(concealed, in: app)
        XCTAssertFalse(concealed.frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(concealed.frame))
        XCTAssertTrue(visibilityButton("Reveal").exists)
        try auditAccessibility(of: app, state: "largest app font keeps editor input and actions reachable")
    }

    func testEditorCopyFailureIsReportedWithoutSuccessFeedback() {
        launch("editor-copy-failure")
        activate(app.buttons["editor-copy-key"])
        XCTAssertTrue(app.staticTexts["The value could not be copied. Try again."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["editor-copied-value"].exists)
        XCTAssertFalse(app.textViews["Key"].exists)
    }

    func testEditorCopyUsesCurrentRawDraftInsteadOfLastValidValue() {
        launch("editor-copy")
        replace(app.textFields["Amount"], with: "invalid")
        XCTAssertTrue(app.buttons["editor-copy-amount"].isEnabled)
        activate(app.buttons["editor-copy-amount"])
        XCTAssertEqual(app.staticTexts["editor-copied-value"].value as? String, "invalid")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        replace(app.textFields["Amount"], with: "9007199254740993.000001")
        XCTAssertTrue(app.buttons["editor-copy-amount"].isEnabled)
        activate(app.buttons["editor-copy-amount"])
        XCTAssertEqual(app.staticTexts["editor-copied-value"].value as? String, "9007199254740993.000001")
    }

    func testDisplayFontSettingChangesAndPersistsInSettingsView() {
        launch("display-settings")
        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        #else
        XCTAssertFalse(app.buttons["app-settings"].exists)
        activate(app.buttons["Unlock"])
        activate(app.buttons["app-settings"])
        #endif
        activate(app.popUpButtons["display-font-size"].exists
            ? app.popUpButtons["display-font-size"] : app.buttons["display-font-size"])
        #if os(macOS)
        activate(app.menuItems["24 pt"])
        let expected = "24"
        app.typeKey("w", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)
        #else
        activate(app.buttons["26 pt"])
        let expected = "26"
        activate(app.buttons["Done"])
        activate(app.buttons["app-settings"])
        #endif
        let picker = app.descendants(matching: .any).matching(identifier: "display-font-size").firstMatch
        XCTAssertTrue((picker.value as? String ?? "").contains(expected) || picker.label.contains(expected))
    }

    func testRecoveryCodeRemovalAndAdditionCreateDistinctIdentity() throws {
        launch("recovery")
        activate(app.buttons["Remove code"])
        activate(app.buttons["Add code"])
        let codes = app.textFields.matching(identifier: "Code")
        XCTAssertEqual(codes.count, 1)
        replace(codes.element(boundBy: 0), with: " 0020 ")
        let entries = try XCTUnwrap(try savedValue() as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let id = try XCTUnwrap(entries[0]["id"] as? String)
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotEqual(id, "stable-code-id")
        XCTAssertEqual(entries[0]["code"] as? String, " 0020 ")
        XCTAssertEqual(entries[0]["used"] as? Bool, false)
    }

    func testRemovingLastAddressAndChoiceRowsLeavesEmptyCollections() throws {
        launch("address")
        let components = app.buttons.matching(identifier: "Remove component")
        activate(components.element(boundBy: 0))
        activate(components.element(boundBy: 0))
        XCTAssertEqual(app.textFields.matching(identifier: "Component name").count, 0)
        XCTAssertEqual(try savedValue() as? [String: String], [:])
        launch("choices")
        let choices = app.buttons.matching(identifier: "Remove choice")
        activate(choices.element(boundBy: 0))
        activate(choices.element(boundBy: 0))
        activate(choices.element(boundBy: 0))
        XCTAssertEqual(app.textFields.matching(identifier: "Choice").count, 0)
        XCTAssertEqual(try savedValue() as? [String], [])
    }

    func testIdenticalFieldIDsDoNotShareRevealState() throws {
        launch("reveal")
        XCTAssertFalse(app.debugDescription.contains("Synthetic first secret"))
        XCTAssertFalse(app.debugDescription.contains("Synthetic second secret"))
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "First")).firstMatch
        activate(first)
        XCTAssertTrue((first.value as? String)?.contains("Synthetic first secret") == true)
        XCTAssertFalse(app.debugDescription.contains("Synthetic second secret"))
        activate(first)
        XCTAssertFalse(app.debugDescription.contains("Synthetic first secret"))
    }
}
