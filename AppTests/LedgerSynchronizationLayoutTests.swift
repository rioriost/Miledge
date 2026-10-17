#if os(macOS)
import AppKit
import MiledgeApplication
import MiledgeDomain
import Observation
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import MiledgeApp

/// Exercises the production List with an isolated store, never the user's Keychain.
@MainActor
final class LedgerSynchronizationLayoutTests: XCTestCase {
    private final class Store {
        var records: [Data] = []
    }

    @Observable final class Presentation {
        var textSize = DisplayTextSize.small
        var width: CGFloat = 840
    }

    private struct Content: View {
        let session: VaultSession
        let browser: LedgerBrowser
        let presentation: Presentation
        var body: some View {
            LedgerView(session: session, browser: browser)
                .ledgerFont(.body)
                .environment(\.locale, Locale(identifier: "ja"))
                .environment(\.displayTextSize, presentation.textSize)
                .frame(width: presentation.width, height: 650)
        }
    }

    func testIncomingRecordKeepsFullRowHeightAndExistingSelection() async throws {
        try await incomingRecord(selected: true, exerciseResizing: true)
    }

    func testIncomingRecordKeepsFullRowHeightWithoutSelection() async throws {
        try await incomingRecord(selected: false)
    }

    func testAutomaticPollingAddsRecordInLightAppearance() async throws {
        try await incomingRecord(selected: true, poll: true, descending: true)
    }

    func testIncomingRecordDoesNotResetScrolledListOrKeyboardFocus() async throws {
        try await incomingRecord(selected: true, extraRecords: 30)
    }

    private func incomingRecord(
        selected: Bool, poll: Bool = false, descending: Bool = false,
        exerciseResizing: Bool = false, extraRecords: Int = 0
    ) async throws {
        let store = Store()
        let passport = VaultRevision(templateId: "passport", storageScope: .synchronizable,
                                     title: "旅券（パスポート）2026-10-14")
        let license = VaultRevision(templateId: "driver-license", storageScope: .synchronizable,
                                    title: "運転免許証2026-10-17")
        let extras = (0..<extraRecords).map {
            VaultRevision(templateId: "secure-note", storageScope: .synchronizable,
                          title: "資料 \($0) 長い名前のテスト用項目")
        }
        store.records = try ([passport] + extras).map(RevisionCodec.encode)
        let session = VaultSession(authenticate: {}, load: { store.records }, append: { _, _, _ in })
        try await session.unlock()
        let presentation = Presentation()
        if poll { presentation.textSize = .standard; presentation.width = 1100 }
        let browser = LedgerBrowser(selectedRecordId: selected ? passport.recordId : nil, descending: descending)
        let host = NSHostingController(rootView: Content(session: session, browser: browser, presentation: presentation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: presentation.width, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: presentation.width, height: 650))
        window.appearance = NSAppearance(named: poll ? .aqua : .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); session.lock() }
        try await settle()
        let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1 + extraRecords)
        if extraRecords > 0 { table.scrollRowToVisible(table.numberOfRows - 1); try await settle() }
        XCTAssertTrue(window.makeFirstResponder(table))
        let scrollOffset = table.enclosingScrollView?.contentView.bounds.minY ?? 0
        if extraRecords > 0 { XCTAssertGreaterThan(scrollOffset, 0) }
        let beforeRows = table.rows(in: table.visibleRect)
        let beforeItems = browser.visibleItems(from: session.heads)
        let firstVisibleID = beforeRows.location != NSNotFound ? beforeItems[beforeRows.location].id : nil
        record(table, name: "before-arrival")
        store.records.append(try RevisionCodec.encode(license))
        if poll {
            // Exercise the actual five-second task instead of calling refresh from the test.
            for _ in 0..<70 {
                if session.heads.contains(where: { $0.recordId == license.recordId }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } else { try session.refresh() }
        try await settle()
        XCTAssertEqual(table.numberOfRows, 2 + extraRecords)
        XCTAssertTrue(descendants(host.view).contains { $0 === table }, "Refresh must retain the native List")
        XCTAssertTrue(window.firstResponder === table, "Refresh must not steal keyboard focus")
        if extraRecords > 0 {
            XCTAssertGreaterThan(table.enclosingScrollView?.contentView.bounds.minY ?? 0, 0,
                                 "Incoming items must not jump a scrolled list back to the top")
            let afterRows = table.rows(in: table.visibleRect)
            let afterItems = browser.visibleItems(from: session.heads)
            XCTAssertEqual(afterItems[afterRows.location].id, firstVisibleID, "The visible scroll anchor must survive insertion")
        }
        try assertVisibleRowsFit(table)
        record(table, name: "after-arrival")
        let visible = LedgerBrowser(descending: descending).visibleItems(from: session.heads)
        if selected {
            XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
            if table.selectedRow >= 0 {
                XCTAssertEqual(visible[table.selectedRow].id, passport.recordId, "Incoming items must not change selection")
            }
        } else { XCTAssertEqual(table.selectedRow, -1) }
        if extraRecords == 0 { try await captureOwnWindow(window, named: poll ? "synced-standard-light" : "synced-small-dark") }

        if exerciseResizing {
            let smallHeight = table.rect(ofRow: 0).height
            presentation.textSize = .largest
            try await settle()
            XCTAssertGreaterThan(table.rect(ofRow: 0).height, smallHeight, "Text-size changes must update rows without resizing the window")
            try assertVisibleRowsFit(table)
            presentation.width = 1100
            window.setContentSize(NSSize(width: presentation.width, height: 650))
            try await settle()
            try assertVisibleRowsFit(table)
            let largestHeight = table.rect(ofRow: 0).height
            record(table, name: "largest-text")
            try await captureOwnWindow(window, named: "synced-largest-dark")
            presentation.textSize = .small
            try await settle()
            XCTAssertLessThan(table.rect(ofRow: 0).height, largestHeight, "Rows must shrink without resizing the window")
            presentation.width = 840
            window.setContentSize(NSSize(width: presentation.width, height: 650))
            try await settle()
            try assertVisibleRowsFit(table)
            XCTAssertLessThan(table.rect(ofRow: 0).height, largestHeight, "Rows must shrink after reducing text size")

            // A later revision can change wrapping and position without changing record identity.
            var edit = license
            edit.revisionId = UUID(); edit.parentRevisionIds = [license.revisionId]
            edit.title = "運転免許証 追加情報を含む長い表示名 2026-10-17"
            store.records.append(try RevisionCodec.encode(edit))
            try session.refresh()
            try await settle()
            try assertVisibleRowsFit(table)
            for _ in 0..<3 { try session.refresh() }
            try await settle()
            try assertVisibleRowsFit(table)
            XCTAssertEqual(table.numberOfRows, 2)
            record(table, name: "repeated-refresh-and-longer-title")
        }


    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertVisibleRowsFit(_ table: NSTableView, file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = table.rows(in: table.visibleRect)
        guard rows.location != NSNotFound else { return XCTFail("No visible rows", file: file, line: line) }
        for row in rows.location..<NSMaxRange(rows) {
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: false), file: file, line: line)
            XCTAssertGreaterThanOrEqual(table.rect(ofRow: row).height, 44, "Row \(row) collapsed after refresh", file: file, line: line)
            XCTAssertGreaterThanOrEqual(table.rect(ofRow: row).height + 1, cell.fittingSize.height,
                                       "Row \(row) must contain its multiline content", file: file, line: line)
        }
    }

    private func record(_ table: NSTableView, name: String) {
        let rows = table.rows(in: table.visibleRect)
        guard rows.location != NSNotFound else { return }
        let metrics = (rows.location..<NSMaxRange(rows)).map { row in
            "row=\(row) rect=\(table.rect(ofRow: row)) fitting=\(table.view(atColumn: 0, row: row, makeIfNecessary: false)?.fittingSize ?? .zero)"
        }.joined(separator: "\n")
        print("\(name): \(metrics)")
        let report = XCTAttachment(string: metrics); report.name = name; report.lifetime = .keepAlways; add(report)
    }

    private func captureOwnWindow(_ window: NSWindow, named name: String) async throws {
        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(bitmap)
            let capture = XCTAttachment(image: image)
            capture.name = "\(name)-hosted-bitmap"; capture.lifetime = .keepAlways; add(capture)
        }
        guard CGPreflightScreenCaptureAccess() else {
            let report = XCTAttachment(string: "Whole-window capture blocked by existing permission; no access requested.")
            report.name = "\(name)-capture-blocked"; report.lifetime = .keepAlways; add(report)
            return
        }
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(available.windows.first {
            $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }, "Capture only this test's synthetic window")
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * window.backingScaleFactor)
        configuration.height = Int(target.frame.height * window.backingScaleFactor)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: target.frame.size))
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
