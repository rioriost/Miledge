import Foundation
import XCTest
@testable import MiledgeDomain

final class RevisionGraphTests: XCTestCase {
    private func root() -> VaultRevision { .init(title: "Synthetic", createdAt: Date(timeIntervalSince1970: 0)) }
    private func child(_ parent: VaultRevision, deleted: Bool = false, clock: Double = 0) -> VaultRevision {
        .init(recordId: parent.recordId, parentRevisionIds: [parent.id], title: "Synthetic child",
              createdAt: parent.createdAt, modifiedAt: Date(timeIntervalSince1970: clock), deleted: deleted)
    }

    func testEmptyRootsUnorderedLinearAndMultipleRecords() throws {
        XCTAssertEqual(try RevisionGraph.heads(in: []), [])
        let a = root(), b = root()
        let c = child(a), d = child(c)
        XCTAssertEqual(try RevisionGraph.heads(in: [d, a, b, c]), [d, b])
        XCTAssertEqual(try RevisionGraph.heads(in: [a, a]), [a])
    }

    func testNoClockBasedWinnerAndExplicitMerge() throws {
        let base = root()
        let ahead = child(base, clock: 99_999_999)
        let behind = child(base, clock: -99_999_999)
        XCTAssertEqual(try RevisionGraph.heads(in: [base, ahead, behind]), [ahead, behind])
        var merge = child(ahead)
        merge.parentRevisionIds = [ahead.id, behind.id]
        XCTAssertEqual(try RevisionGraph.heads(in: [merge, base, behind, ahead]), [merge])
    }

    func testDeleteEditAndEditFromTombstoneBranchesPreservedUntilMerge() throws {
        let base = root(), tombstone = child(base, deleted: true), edit = child(base)
        XCTAssertEqual(try RevisionGraph.heads(in: [base, tombstone, edit]), [tombstone, edit])
        let restoredEdit = child(tombstone)
        XCTAssertEqual(try RevisionGraph.heads(in: [base, tombstone, edit, restoredEdit]), [edit, restoredEdit])
        var merge = child(restoredEdit, deleted: true)
        merge.parentRevisionIds = [restoredEdit.id, edit.id]
        XCTAssertEqual(try RevisionGraph.heads(in: [base, tombstone, edit, restoredEdit, merge]), [merge])
        XCTAssertTrue(try RevisionGraph.heads(in: [base, tombstone])[0].deleted)
    }

    func testDuplicateRevisionIntegrityChecksEveryKnownAndUnknownValue() throws {
        let original = root()
        var changed = original
        changed.title = "Different"
        XCTAssertThrowsError(try RevisionGraph.heads(in: [original, changed])) {
            XCTAssertEqual($0 as? RevisionError, .duplicateRevision(original.id))
        }
        changed = original
        changed.deleted = true
        XCTAssertThrowsError(try RevisionGraph.heads(in: [original, changed]))
        changed = original
        changed.unknownProperties["unknown"] = .null
        XCTAssertThrowsError(try RevisionGraph.heads(in: [original, changed]))
        changed = original
        changed.recordId = UUID()
        XCTAssertThrowsError(try RevisionGraph.heads(in: [original, changed]))
        var preciseOriginal = original
        preciseOriginal.createdAt = Date(timeIntervalSinceReferenceDate: 0)
        changed = preciseOriginal
        changed.createdAt = preciseOriginal.createdAt.addingTimeInterval(0.0000000001)
        XCTAssertThrowsError(try RevisionGraph.heads(in: [preciseOriginal, changed]))
    }

    func testMissingCrossRecordCrossScopeAndDuplicateParents() throws {
        let base = root(), next = child(base), unrelated = root()
        XCTAssertThrowsError(try RevisionGraph.heads(in: [next])) {
            XCTAssertEqual($0 as? RevisionError, .missingParent(revision: next.id, parent: base.id))
        }
        var wrong = next
        wrong.parentRevisionIds = [unrelated.id]
        XCTAssertThrowsError(try RevisionGraph.heads(in: [wrong, unrelated])) {
            XCTAssertEqual($0 as? RevisionError, .invalidParent(revision: wrong.id, parent: unrelated.id))
        }
        wrong = next
        wrong.storageScope = .synchronizable
        XCTAssertThrowsError(try RevisionGraph.heads(in: [base, wrong]))
        wrong = next
        wrong.parentRevisionIds = [base.id, base.id]
        XCTAssertThrowsError(try RevisionGraph.heads(in: [base, wrong])) {
            XCTAssertEqual($0 as? RevisionError, .duplicateParent(base.id))
        }
    }

    func testSelfCycleLongCycleAndDiamondDAG() throws {
        var a = root()
        a.parentRevisionIds = [a.id]
        XCTAssertThrowsError(try RevisionGraph.heads(in: [a])) {
            XCTAssertEqual($0 as? RevisionError, .cycle(a.id))
        }
        a.parentRevisionIds = []
        let b = child(a), c = child(b)
        a.parentRevisionIds = [c.id]
        XCTAssertThrowsError(try RevisionGraph.heads(in: [a, b, c]))
        a.parentRevisionIds = []
        let d = child(a)
        var merge = child(c)
        merge.parentRevisionIds = [d.id, c.id, a.id]
        XCTAssertEqual(try RevisionGraph.heads(in: [merge, c, b, d, a]), [merge])
    }

    func testLongHistoryWithoutRecursionOrClockOrdering() throws {
        var history = [root()]
        for _ in 0..<2_000 { history.append(child(history.last!)) }
        XCTAssertEqual(try RevisionGraph.heads(in: Array(history.reversed())).map(\.id), [history.last!.id])
    }

    func testFutureRevisionAndTombstoneDataAreNotDiscarded() throws {
        var base = root()
        base.templateId = "future-technical"
        base.sections = [.init(id: "unknown", fields: [.init(id: "f", kind: "new-kind", value: .number("2e500"), concealed: true)])]
        var future = child(base, deleted: true)
        future.schemaVersion = 100
        future.unknownProperties = ["futureFlag": .array([.null])]
        XCTAssertEqual(try RevisionGraph.heads(in: [base, future]), [future])
        var futureLocal = try JSONObject(base.json, path: "revision").values
        futureLocal["storageScope"] = .string("future-scope")
        let unsupported = try RevisionCodec.decode(LosslessJSON.encode(.object(futureLocal)))
        XCTAssertThrowsError(try RevisionGraph.heads(in: [unsupported, future]))
    }
}
