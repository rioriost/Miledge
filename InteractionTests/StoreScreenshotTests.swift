import XCTest

/// Captures the actual shared product UI, never the user's Keychain or files.
@MainActor
final class StoreScreenshotTests: XCTestCase {
    func testLocalizedStoreScreenshots() throws {
        continueAfterFailure = false
        let locales = ProcessInfo.processInfo.environment["MILEDGE_SCREENSHOT_LOCALES"]?.components(separatedBy: ",")
            ?? ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es", "pt-BR", "it", "ar", "hi"]
        for locale in locales {
            let app = XCUIApplication()
            app.launchArguments = ["store-screenshots", "-AppleLanguages", "(\(locale))", "-AppleLocale", locale]
            app.launchEnvironment["MILEDGE_UI_LOCALE"] = locale
            app.launchEnvironment["MILEDGE_UI_APPEARANCE"] = "light"
            app.launch()
            let all = app.buttons["category-all"]
            XCTAssertTrue(all.waitForExistence(timeout: 10))
            activate(all)
            let wifi = app.descendants(matching: .any).matching(identifier: "ledger-item-10000000-0000-0000-0000-000000000001").firstMatch
            XCTAssertTrue(wifi.waitForExistence(timeout: 5))
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { capture(app, name: "\(locale)__01-library") }
            #endif
            #if os(macOS)
            // The passive SwiftUI label is hosted inside an AppKit table row.
            // Selection belongs to the table, so click the label's row position.
            wifi.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            #else
            activate(wifi)
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["item-detail-form"].waitForExistence(timeout: 5))
            capture(app, name: "\(locale)__02-details")
            #if os(macOS)
            if locale == "ar" {
                activate(app.buttons["category-favorites"])
                capture(app, name: "\(locale)__03-favorites")
                app.terminate()
                continue
            }
            activate(app.buttons["ledger-add"])
            #else
            // Return to the list on compact layouts to reach the product add action.
            if UIDevice.current.userInterfaceIdiom == .phone { app.navigationBars.buttons.firstMatch.tap() }
            activate(app.buttons["ledger-add"])
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["template-picker-list"].waitForExistence(timeout: 5))
            capture(app, name: "\(locale)__03-templates")
            app.terminate()
        }
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
        #if os(macOS)
        app.activate()
        let image = app.windows.firstMatch.screenshot()
        #else
        let image = app.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "store__\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
