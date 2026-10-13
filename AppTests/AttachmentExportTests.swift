import Foundation
import XCTest
@testable import MiledgeApp

final class AttachmentExportTests: XCTestCase {
    @MainActor
    func testExportPreservesBytesAndInvalidationRevokesLaterRequests() async throws {
        let bytes = Data([0, 255, 1, 128, 0]) + Data("Synthetic only\n".utf8)
        let document = AttachmentExportDocument(bytes: bytes)
        let exported = try await document.snapshot()
        XCTAssertEqual(exported, bytes)
        document.invalidate()
        do { _ = try await document.snapshot(); XCTFail("Invalidated export must fail") }
        catch is CancellationError { }
    }
}
