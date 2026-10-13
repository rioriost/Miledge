import SwiftUI
import XCTest
@testable import MiledgeApp

#if os(macOS)
import AppKit
#endif

@MainActor
final class DisplaySettingsTests: XCTestCase {
    func testAvailableFontSizesHaveStablePersistenceAndIncreasingScale() {
        let sizes = DisplayTextSize.allCases
        XCTAssertEqual(DisplayTextSize.standard.scale, 1)
        XCTAssertEqual(sizes.map(\.rawValue), sizes.map(\.rawValue).sorted())
        for size in sizes {
            XCTAssertEqual(DisplayTextSize(rawValue: size.rawValue), size)
            XCTAssertGreaterThan(size.scale, 0)
        }
        XCTAssertNil(DisplayTextSize(rawValue: 0))
        XCTAssertNil(DisplayTextSize(rawValue: 999))
    }

    func testInitialVisibilityHonorsGlobalPreferenceWithoutMaskingNewOrPublicInputs() {
        for concealed in [false, true] {
            for initiallyVisible in [false, true] {
                for concealByDefault in [false, true] {
                    XCTAssertEqual(
                        FieldVisibility.initiallyRevealed(
                            concealed: concealed, initiallyVisible: initiallyVisible, concealByDefault: concealByDefault
                        ),
                        !concealed || initiallyVisible || !concealByDefault
                    )
                }
            }
        }
        XCTAssertTrue(EnvironmentValues().concealValuesByDefault)
    }

    #if os(macOS)
    func testFontChangesResizeTheActualWindowAndStayInsideTheDisplay() throws {
        let sizing = WindowFontSizer.FontSizingView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.contentView = sizing
        window.center()
        window.orderFront(nil)
        defer { window.close() }
        sizing.applySize()
        let original = window.frame
        sizing.requestedScale = DisplayTextSize.large.scale
        sizing.applySize()
        XCTAssertGreaterThan(window.frame.width, original.width)
        XCTAssertGreaterThan(window.frame.height, original.height)
        XCTAssertTrue(try XCTUnwrap(window.screen).visibleFrame.contains(window.frame))
        let larger = window.frame
        sizing.requestedScale = DisplayTextSize.small.scale
        sizing.applySize()
        XCTAssertLessThan(window.frame.width, larger.width)
        XCTAssertGreaterThanOrEqual(window.contentRect(forFrameRect: window.frame).width, 560)
        sizing.requestedScale = 100
        sizing.applySize()
        XCTAssertTrue(try XCTUnwrap(window.screen).visibleFrame.contains(window.frame))
        let full = window.frame
        sizing.applySize()
        XCTAssertEqual(window.frame, full)
    }
    #endif
}
