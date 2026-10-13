import XCTest

extension XCTestCase {
    @MainActor
    func replaceSingleLineInput(_ element: XCUIElement, with text: String) {
        #if os(macOS)
        element.typeKey("a", modifierFlags: .command)
        #else
        // Triple-tap selects the paragraph even when Select All is absent.
        element.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        #endif
        element.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }

    @MainActor
    func templateChoice(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.descendants(matching: .any).matching(identifier: "template-\(identifier)").firstMatch
        #else
        app.buttons["template-\(identifier)"]
        #endif
    }

    @MainActor
    func activateTemplate(_ identifier: String, in app: XCUIApplication) {
        let choice = templateChoice(identifier, in: app)
        makeReachable(choice, in: app)
        #if os(macOS)
        choice.doubleClick()
        #else
        choice.tap()
        #endif
    }

    @MainActor
    func makeReachable(_ element: XCUIElement, in app: XCUIApplication) {
        func reachable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            #if os(iOS)
            return app.frame.contains(element.frame)
            #else
            return true
            #endif
        }
        if element.waitForExistence(timeout: 2) && reachable() { return }
        #if os(iOS)
        for _ in 0..<6 {
            if reachable() { break }
            // Audits and keyboard presentation can leave an earlier input above
            // the viewport. Follow its observed position instead of only moving down.
            if element.exists, !element.frame.isEmpty, element.frame.maxY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        #endif
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(reachable())
    }

    @MainActor
    func auditAccessibility(of app: XCUIApplication, state: String) throws {
        let stopAfterFailure = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = stopAfterFailure }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Synthetic accessibility - \(state)"
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Synthetic accessibility tree - \(state)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        var types: XCUIAccessibilityAuditType = [.elementDetection, .hitRegion, .sufficientElementDescription]
        #if os(iOS)
        types.insert(.trait)
        #endif
        try app.performAccessibilityAudit(for: types) { issue in
            print("Accessibility audit [\(state)]: \(issue.auditType.rawValue) \(issue.detailedDescription)")
            if let element = issue.element { print(element.debugDescription) }
            return false
        }
    }
}
