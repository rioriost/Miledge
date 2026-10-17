import XCTest

/// Uses production views with synthetic records and an in-memory store.
@MainActor
final class VisualAccessibilityTests: XCTestCase {
    private var app: XCUIApplication!
    private var profile = ""
    private var auditIssues: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if testRun?.failureCount ?? 0 > 0 { capture("failure") }
        app.terminate()
        app = nil
    }

    private func launch(_ name: String, scenario: String = "accessibility-ledger", text: String = "large", dark: Bool = false, contrast: Bool = false) {
        profile = name
        #if os(iOS)
        print("SYSTEM_AX: bold=\(UIAccessibility.isBoldTextEnabled) contrast=\(UIAccessibility.isDarkerSystemColorsEnabled) transparency=\(UIAccessibility.isReduceTransparencyEnabled) motion=\(UIAccessibility.isReduceMotionEnabled) differentiate=\(UIAccessibility.shouldDifferentiateWithoutColor)")
        #endif
        app.launchArguments = [scenario, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MILEDGE_ACCESSIBILITY_TEST"] = "1"
        app.launchEnvironment["MILEDGE_UI_APPEARANCE"] = dark ? "dark" : "light"
        app.launchEnvironment["MILEDGE_AX_TEXT"] = text
        app.launchEnvironment["MILEDGE_AX_CONTRAST"] = contrast ? "1" : "0"
        app.launch()
        app.activate()
    }

    private func activate(_ element: XCUIElement) {
        app.activate()
        makeReachable(element, in: app)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ state: String) {
        #if os(macOS)
        let screenshot = app.windows.firstMatch.screenshot()
        #else
        let screenshot = app.screenshot()
        #endif
        let image = XCTAttachment(screenshot: screenshot)
        image.name = "visual-ax__\(profile)__\(state)"
        image.lifetime = .keepAlways
        add(image)
        let local = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("miledge-visual-ax__\(profile)__\(state).png")
        try? screenshot.pngRepresentation.write(to: local)
        print("VISUAL_AX_SCREENSHOT: \(local.path)")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "visual-ax-tree__\(profile)__\(state)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func audit(_ state: String) throws {
        capture(state)
        var types: XCUIAccessibilityAuditType = [.contrast]
        #if os(iOS)
        types.insert(.textClipped)
        #endif
        // Collect the complete diagnostics so a finding doesn't hide later screens.
        try app.performAccessibilityAudit(for: types) { issue in
            let description = "\(self.profile)/\(state): \(issue.auditType.rawValue) \(issue.detailedDescription)"
            self.auditIssues.append(description)
            #if os(iOS)
            if issue.auditType == .textClipped {
                print("CLIPPED_ELEMENT: \(issue.element?.debugDescription ?? "unknown")")
            }
            #endif
            print("VISUAL_AX_FINDING: \(description)")
            return true
        }
    }

    private func finishAudit() {
        let report = XCTAttachment(string: auditIssues.joined(separator: "\n"))
        report.name = "Visual accessibility findings"
        report.lifetime = .keepAlways
        add(report)
        continueAfterFailure = true
        // Audits can include dimmed views behind sheets or combined SF Symbol
        // labels. Every finding requires visual classification in the review
        // record. Passing these task assertions does not certify either audit.
    }

    private func openLibrary() {
        activate(app.buttons["Unlock"])
        activate(app.buttons["category-all"])
    }

    private func addItem() {
        activate(app.buttons["ledger-add"])
    }

    private func commonTasks() throws {
        try audit("01-locked")
        XCTAssertFalse(app.buttons["app-settings"].exists)
        openLibrary()
        #if os(iOS)
        activate(app.buttons["app-settings"])
        try audit("08-settings")
        activate(app.buttons["Done"])
        #endif
        try audit("02-library")
        let wifi = app.descendants(matching: .any).matching(identifier: "ledger-item-10000000-0000-0000-0000-000000000001").firstMatch
        activate(wifi)
        try audit("03-details")
        activate(app.buttons.matching(identifier: "copy-value").firstMatch)
        #if os(iOS)
        let copyAction = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy ")).firstMatch
        activate(copyAction)
        #endif
        XCTAssertEqual(app.buttons.matching(identifier: "copy-value").firstMatch.value as? String, "Copied")
        capture("03-copy-confirmation")
        activate(app.buttons["Edit"])
        try audit("04-editor")
        let title = app.textFields["Title"]
        activate(title)
        #if os(macOS)
        title.typeKey("a", modifierFlags: .command)
        title.typeKey("x", modifierFlags: [])
        #else
        title.typeText("x")
        #endif
        let updatedTitle = try XCTUnwrap(title.value as? String)
        XCTAssertTrue(updatedTitle.contains("x"))
        activate(app.buttons["Save"])
        XCTAssertTrue(app.staticTexts[updatedTitle].waitForExistence(timeout: 5))
        #if os(iOS)
        if !app.buttons["ledger-add"].isHittable { app.navigationBars.buttons.firstMatch.tap() }
        #endif
        addItem()
        try audit("05-templates")
        #if os(iOS)
        let templateSearch = app.searchFields.firstMatch
        activate(templateSearch)
        templateSearch.typeText("Secure Note")
        #endif
        activateTemplate("secure-note", in: app)
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        capture("05-empty-fields")
        activate(app.buttons["Save"])
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        capture("06-created")
        activate(app.buttons["Delete"])
        capture("07-delete-confirmation")
        let confirm = app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.last!
        activate(confirm)
        capture("09-completed")
        finishAudit()
    }

    func testLightCommonTasks() throws {
        launch("light-contrast", contrast: true)
        try commonTasks()
    }

    func testCopyLocalItemToKeychainKeepsOriginal() throws {
        launch("sync-copy", scenario: "synchronization-ledger")
        openLibrary()
        activate(app.descendants(matching: .any).matching(identifier: "ledger-item-10000000-0000-0000-0000-000000000001").firstMatch)
        activate(app.buttons["copy-to-icloud"])
        capture("copy-confirmation")
        activate(app.buttons.matching(identifier: "Copy to iCloud Keychain").allElementsBoundByIndex.last!)
        XCTAssertTrue(app.staticTexts["iCloud Keychain"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["copy-to-icloud"].exists)
        capture("copied-detail")
        #if os(iOS)
        app.navigationBars.buttons.firstMatch.tap()
        #endif
        activate(app.descendants(matching: .any).matching(identifier: "ledger-item-10000000-0000-0000-0000-000000000001").firstMatch)
        XCTAssertTrue(app.buttons["copy-to-icloud"].waitForExistence(timeout: 5))
        capture("original-retained")
    }

    func testProminentActionContrast() throws {
        for dark in [false, true] {
            launch(dark ? "unlock-dark" : "unlock-light", dark: dark, contrast: true)
            XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5))
            try audit("locked")
            app.terminate()
        }
        XCTAssertTrue(auditIssues.isEmpty, auditIssues.joined(separator: "\n"))
    }

    func testDarkIncreasedContrastCommonTasks() throws {
        launch("dark-contrast", dark: true, contrast: true)
        try commonTasks()
    }

    #if os(iOS)
    func testLargerTextCommonTasks() throws {
        launch("ax3", text: "ax3")
        try commonTasks()
    }

    func testMaximumTextCommonTasks() throws {
        launch("ax5-dark", text: "ax5", dark: true, contrast: true)
        try commonTasks()
    }

    func testMaximumTextValidation() throws {
        launch("ax5-validation", scenario: "validation", text: "ax5", contrast: true)
        let amount = app.textFields["Amount"]
        activate(amount)
        amount.typeText("x")
        XCTAssertTrue(app.staticTexts["Use a decimal number with a dot."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        try audit("validation-error")
        makeReachable(app.buttons["Template fields"], in: app)
        capture("validation-scrolled")
        finishAudit()
    }
    #endif

    func testWithoutColorCommonTasks() throws {
        // Enable Differentiate Without Color and the OS grayscale filter before this test.
        launch("without-color", contrast: true)
        try commonTasks()
    }
}
