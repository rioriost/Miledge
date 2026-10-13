import MiledgeDomain
import XCTest
@testable import MiledgeApp

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class SecureClipboardTests: XCTestCase {
    private enum SyntheticError: Error { case failed }

    @MainActor
    private final class Fixture {
        var text: String?
        var owner: UUID?
        var expiry: Date?
        var date = Date(timeIntervalSince1970: 1_000)
        var writes = 0
        var clears = 0
        var failWrite = false
        var failClear = false

        func clipboard(wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
            -> SecureClipboard {
            SecureClipboard(write: { text, token, expiry in
                if self.failWrite { throw SyntheticError.failed }
                self.text = text
                self.owner = token
                self.expiry = expiry
                self.writes += 1
            }, clear: { token in
                if self.failClear { throw SyntheticError.failed }
                if self.owner == token {
                    self.text = nil
                    self.owner = nil
                    self.clears += 1
                }
            }, now: { self.date }, wait: wait)
        }
    }

    func testCopyIsExplicitExactAndLocalLeaseIsSixtySeconds() {
        let fixture = Fixture()
        let clipboard = fixture.clipboard()
        XCTAssertNil(fixture.text)
        XCTAssertTrue(clipboard.copy(.string(" 001\nالعربية e\u{301} ")))
        XCTAssertEqual(fixture.text, " 001\nالعربية e\u{301} ")
        XCTAssertEqual(fixture.expiry, fixture.date.addingTimeInterval(60))
        XCTAssertNotNil(fixture.owner)
        XCTAssertNil(clipboard.issue)
        fixture.date += 59
        clipboard.expireIfNeeded()
        XCTAssertNotNil(fixture.text)
        fixture.date += 1
        clipboard.expireIfNeeded()
        XCTAssertNil(fixture.text)
        XCTAssertEqual(fixture.clears, 1)
        clipboard.clearOwnedContents()
        XCTAssertEqual(fixture.clears, 1)
    }

    func testCopiedStructuredValuePreservesExactJSONAndFalse() {
        let fixture = Fixture()
        let clipboard = fixture.clipboard()
        XCTAssertTrue(clipboard.copy(.bool(false)))
        XCTAssertEqual(fixture.text, "false")
        XCTAssertTrue(clipboard.copy(.object(["secret": .string(" 0001 ")])))
        XCTAssertEqual(fixture.text, "{\"secret\":\" 0001 \"}")
        clipboard.clearOwnedContents()
        XCTAssertNil(fixture.text)
    }

    func testEmptyInvalidAndWriteFailureReportErrorsWithoutSuccessOrReplacingExistingLease() {
        let fixture = Fixture()
        let clipboard = fixture.clipboard()
        XCTAssertTrue(clipboard.copy(.string("Keep original")))
        XCTAssertFalse(clipboard.copy(.string("")))
        XCTAssertEqual(clipboard.issue, .copyFailed)
        XCTAssertFalse(clipboard.copy(.number("01")))
        XCTAssertEqual(clipboard.issue, .copyFailed)
        fixture.failWrite = true
        XCTAssertFalse(clipboard.copy(.string("Failed value")))
        XCTAssertEqual(fixture.text, "Keep original")
        XCTAssertEqual(fixture.writes, 1)
        clipboard.clearOwnedContents()
        XCTAssertNil(fixture.text)
        fixture.failWrite = false
        XCTAssertTrue(clipboard.copy(.string("Retry")))
        XCTAssertNil(clipboard.issue)
    }

    func testAnotherCopyEvenWithIdenticalTextIsNotCleared() {
        let fixture = Fixture()
        let clipboard = fixture.clipboard()
        XCTAssertTrue(clipboard.copy(.string("Same value")))
        fixture.owner = UUID()
        fixture.date += 60
        clipboard.expireIfNeeded()
        XCTAssertEqual(fixture.text, "Same value")
        XCTAssertEqual(fixture.clears, 0)
    }

    func testFailedClearReportsAnIssueAndKeepsOwnershipForRetry() {
        let fixture = Fixture()
        let clipboard = fixture.clipboard()
        XCTAssertTrue(clipboard.copy(.string("Retry clearing")))
        fixture.failClear = true
        clipboard.clearOwnedContents()
        XCTAssertEqual(clipboard.issue, .clearingFailed)
        XCTAssertNotNil(fixture.text)
        fixture.failClear = false
        clipboard.clearOwnedContents()
        XCTAssertNil(fixture.text)
    }

    func testExpiryTaskClearsOnlyTheCurrentCopy() async throws {
        let fixture = Fixture()
        var pending: [CheckedContinuation<Void, any Error>] = []
        let clipboard = fixture.clipboard { _ in
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        XCTAssertTrue(clipboard.copy(.string("First")))
        while pending.count < 1 { await Task.yield() }
        XCTAssertTrue(clipboard.copy(.string("Second")))
        while pending.count < 2 { await Task.yield() }
        pending[0].resume()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(fixture.text, "Second")
        pending[1].resume()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(fixture.text)
        XCTAssertEqual(fixture.clears, 1)
    }

    func testCancelledWaitDoesNotClearAndUnexpectedWaitFailureIsReported() async {
        let fixture = Fixture()
        let cancelled = fixture.clipboard { _ in throw CancellationError() }
        XCTAssertTrue(cancelled.copy(.string("Cancelled timer")))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(fixture.text, "Cancelled timer")
        cancelled.clearOwnedContents()
        let failed = fixture.clipboard { _ in throw SyntheticError.failed }
        XCTAssertTrue(failed.copy(.string("Failed timer")))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(failed.issue, .clearingFailed)
        fixture.date += 60
        failed.expireIfNeeded()
        XCTAssertNil(fixture.text)
    }

    func testReleasedClipboardCancelsItsTimerWithoutRetainingTheOwner() async {
        let fixture = Fixture()
        var cancelled = false
        var clipboard: SecureClipboard? = fixture.clipboard { _ in
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                cancelled = error is CancellationError
                throw error
            }
        }
        weak var weakClipboard = clipboard
        XCTAssertTrue(clipboard!.copy(.string("Synthetic only")))
        await Task.yield()
        clipboard = nil
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(weakClipboard)
        XCTAssertTrue(cancelled)
    }

    func testNativePrivatePasteboardCopiesAndClearsOnlyItsOwnMarker() async throws {
        let exactText = " 001\r\nSynthetic العربية e\u{301} secret\n "
        #if os(macOS)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = SecureClipboard.using(pasteboard)
        XCTAssertTrue(clipboard.copy(.string(exactText)))
        XCTAssertEqual(Array(try XCTUnwrap(pasteboard.string(forType: .string)).utf8), Array(exactText.utf8))
        XCTAssertNotNil(pasteboard.data(forType: .init(SecureClipboard.ownerType)))
        try await Task.sleep(for: .milliseconds(100))
        clipboard.clearOwnedContents()
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(clipboard.copy(.string("Synthetic other copy")))
        pasteboard.clearContents()
        pasteboard.setString("Synthetic other copy", forType: .string)
        clipboard.clearOwnedContents()
        XCTAssertEqual(pasteboard.string(forType: .string), "Synthetic other copy")
        XCTAssertTrue(clipboard.copy(.string("Synthetic forwarded marker")))
        let marker = try XCTUnwrap(pasteboard.data(forType: .init(SecureClipboard.ownerType)))
        let forwarded = NSPasteboardItem()
        forwarded.setString("Synthetic replacement retaining marker", forType: .string)
        forwarded.setData(marker, forType: .init(SecureClipboard.ownerType))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([forwarded]))
        clipboard.clearOwnedContents()
        XCTAssertEqual(pasteboard.string(forType: .string), "Synthetic replacement retaining marker")
        #else
        let name = UIPasteboard.Name("com.miledge.test.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let clipboard = SecureClipboard.using(pasteboard)
        XCTAssertTrue(clipboard.copy(.string(exactText)))
        XCTAssertEqual(Array(try XCTUnwrap(pasteboard.string).utf8), Array(exactText.utf8))
        XCTAssertNotNil(pasteboard.data(forPasteboardType: SecureClipboard.ownerType))
        try await Task.sleep(for: .milliseconds(100))
        clipboard.clearOwnedContents()
        XCTAssertNil(pasteboard.string)
        XCTAssertTrue(clipboard.copy(.string("Synthetic other copy")))
        pasteboard.setItems([["public.utf8-plain-text": "Synthetic other copy"]], options: [.localOnly: true])
        clipboard.clearOwnedContents()
        XCTAssertEqual(pasteboard.string, "Synthetic other copy")
        #endif
    }
}
