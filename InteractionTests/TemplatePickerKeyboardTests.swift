import XCTest

#if os(macOS)
@MainActor
final class TemplatePickerKeyboardTests: XCTestCase {
    func testArrowKeysThenReturnCreateSelectedTypeWithoutRowClick() {
        let app = XCUIApplication()
        app.launchArguments = ["navigation", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launchEnvironment["MILEDGE_UI_LOCALE"] = "en"
        app.launch()
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let list = app.descendants(matching: .any).matching(identifier: "template-picker-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        // Native selection must move without creating a draft until Return.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertFalse(app.textFields["Title"].exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        let typeDisplay = app.descendants(matching: .any).matching(identifier: "item-type-display").firstMatch
        XCTAssertEqual(typeDisplay.value as? String, "Secure Note")
        XCTAssertFalse(list.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Keyboard-only selected template editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif
