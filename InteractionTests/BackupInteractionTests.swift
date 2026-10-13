import XCTest

@MainActor
final class BackupInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private let phrase = "Synthetic-backup-passphrase-0123456789"

    override func setUp() async throws {
        try await super.setUp()
        app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["backup", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openAllItems()
    }

    private func openAllItems() {
        let all = app.buttons["category-all"]
        if all.waitForExistence(timeout: 5), all.isHittable { activate(all) }
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 {
            print(app.debugDescription)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic backup accessibility tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Synthetic backup screen"
            image.lifetime = .keepAlways
            add(image)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    private func activate(_ element: XCUIElement) {
        if !element.exists || !element.isHittable {
            makeReachable(element, in: app)
        }
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 10))
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func openAction(_ name: String) {
        activate(app.buttons["Backup"])
        activate(app.buttons[name])
    }

    private func chooseBackup() {
        openAction("Restore backup…")
        activate(app.buttons["Choose backup…"])
        #if os(macOS)
        let files = app.tableRows
        #else
        let files = app.cells
        #endif
        let file = files.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic restore")
        ).firstMatch
        #if os(iOS)
        if !file.exists {
            let container = app.cells["Miledge UI Tests, Container"]
            if container.waitForExistence(timeout: 5) { activate(container) }
        }
        #endif
        activate(file)
        if app.buttons["Open"].exists { activate(app.buttons["Open"]) }
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Synthetic restore.miledge-backup")
        ).firstMatch.waitForExistence(timeout: 10))
    }

    private func enterPassphrase(_ value: String) {
        let field = app.secureTextFields["backup-passphrase"]
        activate(field)
        field.typeText(value)
    }

    private func preparePreview() {
        chooseBackup()
        enterPassphrase(phrase)
        activate(app.buttons["Open backup"])
        let selection = app.buttons["restore-backup-selection"]
        if !selection.exists || !selection.isHittable { makeReachable(selection, in: app) }
        XCTAssertTrue(selection.exists || selection.waitForExistence(timeout: 10))
    }

    private func confirmRestore() {
        activate(app.buttons["restore-backup-selection"])
        activate(app.buttons["confirm-backup-restore"].firstMatch)
    }

    private func toggleSelection(_ selection: XCUIElement) {
        #if os(macOS)
        activate(selection)
        #else
        makeReachable(selection, in: app)
        selection.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        #endif
    }

    private func inspection(_ action: String = "Inspect test history") throws -> String {
        activate(app.buttons["Test backup"])
        activate(app.buttons[action])
        return try XCTUnwrap(app.staticTexts["backup-inspection"].value as? String)
    }

    private func history() throws -> [[String: Any]] {
        let contents = try inspection()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [[String: Any]])
    }

    func testExportAccessibilityAuditAndCancellation() throws {
        openAction("Export backup…")
        try auditAccessibility(of: app, state: "backup export entry")
        enterPassphrase(phrase)
        let confirmation = app.secureTextFields["backup-confirmation"]
        activate(confirmation)
        confirmation.typeText(phrase + "\n")
        activate(app.buttons["Prepare backup"])
        XCTAssertTrue(app.buttons["Save backup…"].waitForExistence(timeout: 10))
        try auditAccessibility(of: app, state: "encrypted backup ready")
        activate(app.buttons["Cancel"])
        XCTAssertEqual(try history().count, 1)
    }

    func testRestoreAccessibilityAuditAndWholeItemSelection() throws {
        preparePreview()
        XCTAssertFalse(app.debugDescription.contains("Synthetic\r\nالعربية"))
        try auditAccessibility(of: app, state: "backup restore preview")
        #if os(macOS)
        let selection = app.checkBoxes["backup-record-20000000-0000-0000-0000-000000000002"]
        #else
        let selection = app.switches["backup-record-20000000-0000-0000-0000-000000000002"]
        #endif
        toggleSelection(selection)
        XCTAssertEqual(selection.value as? String, "0")
        XCTAssertFalse(app.buttons["restore-backup-selection"].isEnabled)
        toggleSelection(selection)
        XCTAssertEqual(selection.value as? String, "1")
        XCTAssertTrue(app.buttons["restore-backup-selection"].isEnabled)
        confirmRestore()
        XCTAssertTrue(app.staticTexts["Restoration complete"].waitForExistence(timeout: 10))
        try auditAccessibility(of: app, state: "backup restoration complete")
        activate(app.buttons["Done"])
        XCTAssertEqual(try history().count, 4)
    }

    func testRestoreUsesNativeFilePickerAndKeepsCompleteHistoryAndActualAttachmentBytes() throws {
        preparePreview()
        XCTAssertFalse(app.debugDescription.contains("Synthetic\r\nالعربية"))
        confirmRestore()
        XCTAssertTrue(app.staticTexts["Restoration complete"].waitForExistence(timeout: 10))
        activate(app.buttons["Done"])
        XCTAssertTrue(app.buttons["restore-backup-selection"].waitForNonExistence(timeout: 5))
        let revisions = try history()
        XCTAssertEqual(revisions.count, 4)
        XCTAssertEqual(revisions.first?["title"] as? String, "Synthetic original")
        let root = try XCTUnwrap(revisions.first {
            $0["revisionId"] as? String == "20000000-0000-0000-0000-000000000003"
        })
        XCTAssertEqual(root["tags"] as? [String], ["  Exact Case  "])
        XCTAssertEqual((root["linkedRecordIds"] as? [String])?.count, 2)
        XCTAssertEqual(root["future"] as? NSNumber, NSNumber(value: Int64(9007199254740993)))
        XCTAssertEqual(try inspection("Inspect test attachment"), Data([0, 1, 2, 254, 255]).base64EncodedString())
        preparePreview()
        confirmRestore()
        XCTAssertTrue(app.staticTexts["Restoration complete"].waitForExistence(timeout: 10))
        activate(app.buttons["Done"])
        XCTAssertEqual(try history().count, 4)
    }

    func testPartialRestoreCanBeRetriedWithoutDuplicateRevisions() throws {
        app.terminate()
        app.launchArguments[0] = "backup-retry"
        app.launch()
        openAllItems()
        preparePreview()
        confirmRestore()
        XCTAssertTrue(app.alerts["Backup unavailable"].waitForExistence(timeout: 10))
        activate(app.alerts.buttons["OK"])
        XCTAssertTrue(app.staticTexts["Already added in this attempt"].exists)
        confirmRestore()
        XCTAssertTrue(app.staticTexts["Restoration complete"].waitForExistence(timeout: 10))
        activate(app.buttons["Done"])
        XCTAssertEqual(try history().count, 4)
    }

    func testWrongPassphraseAndCancelDoNotRestoreAnything() throws {
        chooseBackup()
        enterPassphrase(phrase + "-wrong")
        activate(app.buttons["Open backup"])
        XCTAssertTrue(app.alerts["Backup unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Check the passphrase and backup file. Nothing was restored."].exists)
        activate(app.alerts.buttons["OK"])
        activate(app.buttons["Cancel"])
        XCTAssertEqual(try history().count, 1)
        preparePreview()
        activate(app.buttons["Cancel"])
        XCTAssertEqual(try history().count, 1)
    }

    func testBackgroundLockDiscardsPassphraseAndDecryptedPreview() throws {
        preparePreview()
        #if os(macOS)
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["restore-backup-selection"].exists)
        activate(app.buttons["Unlock"])
        XCTAssertEqual(try history().count, 1)
    }

    func testExportUsesNativeSaveDialogAndWritesOnlyDecryptableEncryptedData() throws {
        openAction("Export backup…")
        enterPassphrase(phrase)
        let confirmation = app.secureTextFields["backup-confirmation"]
        activate(confirmation)
        confirmation.typeText(phrase)
        activate(app.buttons["Prepare backup"])
        activate(app.buttons["Save backup…"])
        let save = app.buttons["Save"].firstMatch
        activate(save)
        XCTAssertTrue(app.staticTexts["Backup saved"].waitForExistence(timeout: 10))
        activate(app.buttons["Done"])
        let contents = try inspection("Inspect exported backup")
        let revisions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [[String: Any]])
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?["title"] as? String, "Synthetic original")
    }

    func testGeneratedPassphraseRequiresConfirmationAndIsDiscardedOnCancel() throws {
        openAction("Export backup…")
        activate(app.buttons["Generate passphrase"])
        XCTAssertTrue(app.textFields["backup-passphrase"].exists)
        XCTAssertFalse(app.buttons["Prepare backup"].isEnabled)
        activate(app.buttons["Hide"])
        XCTAssertTrue(app.secureTextFields["backup-passphrase"].exists)
        activate(app.buttons["Cancel"])
        openAction("Export backup…")
        XCTAssertFalse(app.buttons["Prepare backup"].isEnabled)
        activate(app.buttons["Cancel"])
        XCTAssertEqual(try history().count, 1)
    }
}
