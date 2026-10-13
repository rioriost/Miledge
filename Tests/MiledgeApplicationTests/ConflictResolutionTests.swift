import Foundation
import MiledgeApplication
import MiledgeDomain
import XCTest

@MainActor
final class ConflictResolutionTests: XCTestCase {
    private enum Failure: Error { case storage }

    @MainActor
    private final class Fixture {
        let base: VaultRevision
        var first: VaultRevision
        var second: VaultRevision
        var records: [Data]
        var failRead = false
        var failAppend = false
        var accounts: [String] = []
        var scopes: [StorageScope] = []

        init(scope: StorageScope = .deviceLocal) throws {
            base = VaultRevision(
                storageScope: scope, title: "Synthetic base",
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
            first = base
            first.revisionId = UUID()
            first.parentRevisionIds = [base.revisionId]
            first.title = "Synthetic first"
            first.modifiedAt = Date(timeIntervalSince1970: 9_000)
            second = first
            second.revisionId = UUID()
            second.title = "Synthetic second"
            second.modifiedAt = Date(timeIntervalSince1970: 2_000)
            records = try [base, first, second].map(RevisionCodec.encode)
        }

        var expected: Set<UUID> { [first.revisionId, second.revisionId] }

        func session(identifier: @escaping @MainActor () -> UUID = UUID.init) -> VaultSession {
            VaultSession(authenticate: {}, load: {
                if self.failRead { throw Failure.storage }
                return self.records
            }, append: { data, account, scope in
                if self.failAppend { throw Failure.storage }
                self.records.append(data)
                self.accounts.append(account)
                self.scopes.append(scope)
            }, now: { Date(timeIntervalSince1970: 10_000) }, identifier: identifier)
        }
    }

    func testExplicitChoiceBecomesAnAllHeadSuccessorWithoutClockWinnerOrLostMetadata() async throws {
        let fixture = try Fixture(scope: .synchronizable)
        fixture.second.tags = ["B", "A", "A", "", "  Exact\r\n日本語  "]
        fixture.second.favorite = true
        let linked = UUID()
        fixture.second.linkedRecordIds = [linked, linked, fixture.base.recordId]
        fixture.second.sections = [VaultSection(id: "custom", fields: [
            VaultField(
                id: "precision", kind: "number", value: .string("9007199254740993.00000001"), concealed: true
            ),
            VaultField(id: "key", kind: "key-material", value: .string(" 001\r\nالعربية e\u{301} "), concealed: true),
            VaultField(id: "address", kind: "address", value: .object(["postalCode": .string("000001")])),
            VaultField(id: "codes", kind: "recovery-codes", value: .array([
                .object(["id": .string("stable"), "code": .string(" 0001 "), "used": .bool(true)])
            ]))
        ])]
        fixture.second.attachments = [.object([
            "blobId": .string(UUID().uuidString), "formatVersion": .number("1"),
            "algorithm": .string("AES-GCM"), "originalFilename": .string("Synthetic.txt"),
            "plaintextSize": .number("9007199254740993"), "key": .string("Synthetic")
        ])]
        fixture.records = try [fixture.base, fixture.first, fixture.second].map(RevisionCodec.encode)
        let originals = fixture.records
        let session = fixture.session()
        try await session.unlock()
        let resolved = try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.second.revisionId, expectedHeads: fixture.expected
        )
        XCTAssertEqual(Set(resolved.parentRevisionIds), fixture.expected)
        XCTAssertEqual(resolved.parentRevisionIds, fixture.expected.sorted { $0.uuidString < $1.uuidString })
        XCTAssertNotEqual(resolved.revisionId, fixture.second.revisionId)
        XCTAssertEqual(resolved.sections, fixture.second.sections)
        XCTAssertEqual(resolved.tags, fixture.second.tags)
        XCTAssertEqual(resolved.attachments, fixture.second.attachments)
        XCTAssertEqual(resolved.linkedRecordIds, fixture.second.linkedRecordIds)
        XCTAssertEqual(resolved.favorite, fixture.second.favorite)
        XCTAssertEqual(resolved.createdAt, fixture.second.createdAt)
        XCTAssertEqual(resolved.modifiedAt, Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(resolved.title, "Synthetic second")
        XCTAssertEqual(fixture.scopes, [.synchronizable])
        XCTAssertEqual(fixture.accounts, ["\(resolved.recordId.uuidString)/\(resolved.revisionId.uuidString)"])
        XCTAssertEqual(Array(fixture.records.prefix(3)), originals)
        XCTAssertEqual(session.heads, [resolved])
        XCTAssertFalse(session.hasConflict(resolved))
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads, [resolved])
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.second.revisionId, expectedHeads: fixture.expected
        ))
        XCTAssertEqual(fixture.records.count, 4)
    }

    func testEditDeletionConflictCanKeepEitherWholeVersionWithoutDeletingHistory() async throws {
        for keepDeleted in [true, false] {
            let fixture = try Fixture()
            fixture.second.deleted = true
            fixture.records[2] = try RevisionCodec.encode(fixture.second)
            let session = fixture.session()
            try await session.unlock()
            let resolved = try session.resolveConflict(
                recordId: fixture.base.recordId,
                keeping: keepDeleted ? fixture.second.revisionId : fixture.first.revisionId,
                expectedHeads: fixture.expected
            )
            XCTAssertEqual(resolved.deleted, keepDeleted)
            XCTAssertEqual(session.visibleItems().isEmpty, keepDeleted)
            XCTAssertEqual(fixture.records.count, 4)
            session.lock()
            try await session.unlock()
            XCTAssertEqual(session.heads, [resolved])
            XCTAssertEqual(session.visibleItems().isEmpty, keepDeleted)
        }
    }

    func testNewHeadArrivingBeforeConfirmationRequiresReloadAndExplicitReselection() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.unlock()
        let oldHeads = session.heads
        var remote = fixture.first
        remote.revisionId = UUID()
        remote.title = "Synthetic third"
        fixture.records.append(try RevisionCodec.encode(remote))
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.second.revisionId, expectedHeads: fixture.expected
        )) { XCTAssertEqual($0 as? SessionError, .staleRevision) }
        XCTAssertEqual(session.heads, oldHeads)
        XCTAssertEqual(fixture.records.count, 4)
        try session.refresh()
        XCTAssertEqual(session.heads.count, 3)
        let resolved = try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: remote.revisionId,
            expectedHeads: fixture.expected.union([remote.revisionId])
        )
        XCTAssertEqual(resolved.title, "Synthetic third")
        XCTAssertEqual(resolved.parentRevisionIds.count, 3)
        XCTAssertEqual(fixture.records.count, 5)
    }

    func testReadAndAppendFailuresLeaveReviewAndHistoryIntactForRetry() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.unlock()
        let heads = session.heads
        let records = fixture.records
        fixture.failRead = true
        XCTAssertThrowsError(try session.refresh())
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        ))
        fixture.failRead = false
        fixture.failAppend = true
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        ))
        XCTAssertEqual(session.heads, heads)
        XCTAssertEqual(fixture.records, records)
        fixture.failAppend = false
        let resolved = try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        )
        XCTAssertEqual(session.heads, [resolved])
        XCTAssertEqual(fixture.records.count, 4)
    }

    func testRefreshRetainsKnownHistoryAndRejectsCorruptionWithoutPublishingPartialState() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.unlock()
        let heads = session.heads
        fixture.records = [try RevisionCodec.encode(fixture.first)]
        try session.refresh()
        XCTAssertEqual(session.heads, heads)
        var changed = fixture.first
        changed.title = "Same ID, different content"
        fixture.records = [try RevisionCodec.encode(changed)]
        XCTAssertThrowsError(try session.refresh()) {
            XCTAssertEqual($0 as? RevisionError, .duplicateRevision(changed.revisionId))
        }
        fixture.records = [Data("malformed".utf8)]
        XCTAssertThrowsError(try session.refresh())
        XCTAssertEqual(session.heads, heads)
    }

    func testUnsupportedMalformedAndHealthVersionsBlockResolutionEvenWhenNotChosen() async throws {
        for mutation in 0..<5 {
            let fixture = try Fixture()
            switch mutation {
            case 0: fixture.second.schemaVersion = 999
            case 1: fixture.second.unknownProperties = ["future": .number("9007199254740993")]
            case 2: fixture.second.templateId = "medical-record"
            case 3: fixture.second.title = "  "
            default:
                fixture.second.sections = [VaultSection(id: "invalid", fields: [
                    VaultField(id: "number", kind: "number", value: .string("01"))
                ])]
            }
            fixture.records[2] = try RevisionCodec.encode(fixture.second)
            let session = fixture.session()
            try await session.unlock()
            XCTAssertThrowsError(try session.resolveConflict(
                recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
            ))
            XCTAssertEqual(fixture.records.count, 3)
            XCTAssertEqual(Set(session.heads.map(\.revisionId)), fixture.expected)
        }
    }

    func testDifferentStorageScopesCannotBeMergedOrConverted() async throws {
        let fixture = try Fixture()
        fixture.first.parentRevisionIds = []
        fixture.second.parentRevisionIds = []
        fixture.second.storageScope = .synchronizable
        fixture.records = try [fixture.first, fixture.second].map(RevisionCodec.encode)
        let session = fixture.session()
        try await session.unlock()
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        )) { XCTAssertEqual($0 as? SessionError, .changedStorageScope) }
        XCTAssertEqual(fixture.records.count, 2)
    }

    func testLockedStaleMissingChoiceAndReusedIdentityNeverReachAppend() async throws {
        let fixture = try Fixture()
        let session = fixture.session(identifier: { fixture.first.revisionId })
        XCTAssertThrowsError(try session.refresh()) { XCTAssertEqual($0 as? SessionError, .locked) }
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        )) { XCTAssertEqual($0 as? SessionError, .locked) }
        try await session.unlock()
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: []
        )) { XCTAssertEqual($0 as? SessionError, .staleRevision) }
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: UUID(), expectedHeads: fixture.expected
        )) { XCTAssertEqual($0 as? SessionError, .missingRecord) }
        XCTAssertThrowsError(try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        )) { XCTAssertEqual($0 as? RevisionError, .duplicateRevision(fixture.first.revisionId)) }
        session.lock()
        XCTAssertTrue(session.heads.isEmpty)
        XCTAssertEqual(fixture.records.count, 3)
    }

    func testLateArrivalAfterSnapshotRemainsAConflictOnReloadRatherThanBeingConsumed() async throws {
        let fixture = try Fixture()
        var late = fixture.first
        late.revisionId = UUID()
        late.title = "Late concurrent edit"
        let lateData = try RevisionCodec.encode(late)
        let session = VaultSession(authenticate: {}, load: { fixture.records }, append: { data, _, _ in
            fixture.records.append(lateData)
            fixture.records.append(data)
        })
        try await session.unlock()
        let resolved = try session.resolveConflict(
            recordId: fixture.base.recordId, keeping: fixture.first.revisionId, expectedHeads: fixture.expected
        )
        XCTAssertFalse(resolved.parentRevisionIds.contains(late.revisionId))
        session.lock()
        try await session.unlock()
        XCTAssertEqual(Set(session.heads.map(\.revisionId)), [resolved.revisionId, late.revisionId])
        XCTAssertTrue(session.hasConflict(resolved))
        XCTAssertEqual(fixture.records.count, 5)
    }
}
