import Foundation
import MiledgeDomain
import MiledgeStorage
import XCTest
@testable import MiledgeApplication

@MainActor
final class CooperativeRestoreTests: XCTestCase {
    enum Failure: Error, Equatable { case append, blob, read }

    @MainActor
    final class MemoryStore {
        var records: [Data] = []
        var accounts: [String] = []
        var scopes: [StorageScope] = []
        var failAppendAt: Int?
        var readFails = false
        var appendAttempts = 0
        var afterAppend: (() throws -> Void)?

        func read() throws -> [Data] {
            if readFails { throw Failure.read }
            return records
        }

        func append(_ data: Data, _ account: String, _ scope: StorageScope) throws {
            appendAttempts += 1
            if appendAttempts == failAppendAt { throw Failure.append }
            let revision = try RevisionCodec.decode(data)
            XCTAssertFalse(try records.map(RevisionCodec.decode).contains { $0.revisionId == revision.revisionId })
            XCTAssertEqual(account, "\(revision.recordId.uuidString)/\(revision.revisionId.uuidString)")
            XCTAssertEqual(scope, revision.storageScope)
            records.append(data)
            accounts.append(account)
            scopes.append(scope)
            try afterAppend?()
        }
    }

    @MainActor
    final class Checkpoint {
        private let pauseAt: Int
        private var count = 0
        private var arrived = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?

        init(pauseAt: Int) { self.pauseAt = pauseAt }

        func cooperate() async {
            count += 1
            guard count == pauseAt else { await Task.yield(); return }
            await withCheckedContinuation {
                release = $0
                arrived = true
                arrival?.resume()
                arrival = nil
            }
        }

        func waitUntilPaused() async {
            if arrived { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func resume() {
            release?.resume()
            release = nil
        }
    }

    private func session(_ store: MemoryStore) -> VaultSession {
        VaultSession(authenticate: {}, load: { try store.read() }, append: { try store.append($0, $1, $2) })
    }

    private func revision(title: String = "Synthetic item", scope: StorageScope = .deviceLocal) -> VaultRevision {
        VaultRevision(
            templateId: "secure-note", storageScope: scope, title: title,
            tags: ["  Exact Tag  "], favorite: true, createdAt: Date(timeIntervalSince1970: 0),
            sections: [.init(id: "synthetic", fields: [
                .init(id: "secret", kind: "multiline", value: .string("  0001\r\nالعربية e\u{301}\n"), concealed: true)
            ])], linkedRecordIds: [UUID(), UUID()]
        )
    }

    private func child(_ parent: VaultRevision, title: String = "Synthetic child") -> VaultRevision {
        var revision = parent
        revision.revisionId = UUID()
        revision.parentRevisionIds = [parent.revisionId]
        revision.title = title
        return revision
    }

    private func blob(_ bytes: Data, scope: StorageScope = .deviceLocal, id: UUID = UUID()) -> BackupBlob {
        BackupBlob(
            metadata: EncryptedBlob(blobId: id, key: Data(repeating: 7, count: 32), plaintextSize: bytes.count),
            bytes: bytes, scope: scope
        )
    }

    private func metadata(_ blob: BackupBlob) -> JSONValue {
        AttachmentMetadata(blob: blob.metadata, filename: "../../../Synthetic", mediaType: "application/octet-stream").json
    }

    private func service(
        _ session: VaultSession, checkpoint: Checkpoint? = nil,
        restore: @escaping @MainActor (BackupBlob) throws -> Void = { _ in }
    ) -> BackupService {
        BackupService(session: session, readBlob: { _ in Data() }, restoreBlob: restore, cooperate: {
            if let checkpoint { await checkpoint.cooperate() } else { await Task.yield() }
        })
    }

    private func restore(
        _ incoming: [VaultRevision], in session: VaultSession, checkpoint: Checkpoint
    ) async throws -> RevisionRestoreResult {
        let operation = try session.prepareCooperativeRestore(incoming, skippingRecords: [])
        defer { session.finishCooperativeRestore(operation) }
        return try await session.restoreRevisionsCooperatively(operation, cooperate: { await checkpoint.cooperate() })
    }

    func testAccessGenerationChangesOnEveryLockButNotUnlockSaveOrRefresh() async throws {
        let store = MemoryStore()
        let session = session(store)
        let initial = session.accessGeneration
        try await session.unlock()
        XCTAssertEqual(session.accessGeneration, initial)
        try session.save(revision())
        try session.refresh()
        XCTAssertEqual(session.accessGeneration, initial)
        session.lock()
        XCTAssertEqual(session.accessGeneration, initial + 1)
        try await session.unlock()
        XCTAssertEqual(session.accessGeneration, initial + 1)
        session.lock()
        session.lock()
        XCTAssertEqual(session.accessGeneration, initial + 3)
    }

    func testPublicCooperativeAPIsPreserveParentOrderScopesUnknownPayloadAndRetry() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let attachment = blob(Data([0, 255, 1]))
        var root = revision()
        root.attachments = [metadata(attachment)]
        let descendant = child(root)
        var unknown = revision(title: "", scope: .synchronizable)
        unknown.schemaVersion = 99
        unknown.templateId = "future-non-health"
        unknown.unknownProperties = ["future": .number("9007199254740993")]
        unknown.sections[0].fields[0].kind = "future-kind"
        unknown.sections[0].fields[0].value = .object(["number": .number("1e999")])
        let backup = try VaultBackup(revisions: [descendant, unknown, root], blobs: [attachment])
        var restored: [BackupBlob] = []
        let service = service(session) { restored.append($0) }
        let result = try await service.restoreCooperatively(backup)
        XCTAssertEqual(result.restoredBlobIds, [attachment.metadata.blobId])
        XCTAssertEqual(restored, [attachment])
        let added = result.revisions.addedRevisionIds
        XCTAssertLessThan(try XCTUnwrap(added.firstIndex(of: root.revisionId)),
                          try XCTUnwrap(added.firstIndex(of: descendant.revisionId)))
        XCTAssertEqual(Set(store.scopes), [.deviceLocal, .synchronizable])
        XCTAssertEqual(Set(session.heads.map(\.revisionId)), [descendant.revisionId, unknown.revisionId])
        XCTAssertEqual(try store.records.map(RevisionCodec.decode).first { $0.revisionId == unknown.revisionId }, unknown)
        let originalBytes = store.records
        let retry = try await service.restoreCooperatively(backup)
        XCTAssertTrue(retry.revisions.addedRevisionIds.isEmpty)
        XCTAssertEqual(retry.revisions.existingRevisionCount, 3)
        XCTAssertEqual(store.records, originalBytes)
        let direct = child(descendant, title: "Direct async append")
        let appended = try await session.restoreRevisionsCooperatively([direct])
        XCTAssertEqual(appended.addedRevisionIds, [direct.revisionId])
        XCTAssertTrue(session.heads.contains(direct))
        let empty = try await session.restoreRevisionsCooperatively([])
        XCTAssertTrue(empty.addedRevisionIds.isEmpty)
        XCTAssertTrue(session.heads.contains(direct))
    }

    func testCancellationAfterPersistedRevisionReportsExactProgressAndRetryDoesNotRewrite() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let grandchild = child(descendant, title: "Synthetic grandchild")
        let backup = try VaultBackup(revisions: [grandchild, descendant, root], blobs: [])
        let checkpoint = Checkpoint(pauseAt: 2)
        let service = service(session, checkpoint: checkpoint)
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        XCTAssertEqual(session.heads, [root])
        let persistedBytes = try XCTUnwrap(store.records.first)
        task.cancel()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("Cancelled restore must fail")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertTrue(failure.cause is CancellationError)
            XCTAssertTrue(failure.revisionFailure?.cause is CancellationError)
            XCTAssertEqual(failure.revisionFailure?.failedRevisionId, descendant.revisionId)
            XCTAssertEqual(failure.revisionFailure?.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.restoredBlobIds, [])
        }
        XCTAssertEqual(store.records.count, 1)
        let retry = try await service.restoreCooperatively(backup)
        XCTAssertEqual(retry.revisions.addedRevisionIds, [descendant.revisionId, grandchild.revisionId])
        XCTAssertEqual(retry.revisions.existingRevisionCount, 1)
        XCTAssertEqual(store.records.first, persistedBytes)
        XCTAssertEqual(session.heads, [grandchild])
    }

    func testCancellationBetweenBlobsReportsOnlyCompletedBlobsAndNoRevisions() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let first = blob(Data([1]))
        let second = blob(Data([2]))
        var root = revision()
        root.attachments = [metadata(first), metadata(second)]
        let backup = try VaultBackup(revisions: [root], blobs: [first, second])
        let checkpoint = Checkpoint(pauseAt: 2)
        var restored: [UUID: Data] = [:]
        let service = service(session, checkpoint: checkpoint) { restored[$0.metadata.blobId] = $0.bytes }
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        task.cancel()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("Cancelled blob restore must fail")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.restoredBlobIds, [first.metadata.blobId])
            XCTAssertNil(failure.revisionFailure)
            XCTAssertTrue(failure.cause is CancellationError)
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(restored, [first.metadata.blobId: first.bytes])
        let retry = try await service.restoreCooperatively(backup)
        XCTAssertEqual(retry.restoredBlobIds, [first.metadata.blobId, second.metadata.blobId])
        XCTAssertEqual(retry.revisions.addedRevisionIds, [root.revisionId])
        XCTAssertEqual(restored.count, 2)
    }

    func testLockBetweenRevisionWritesNeverRepopulatesLockedSession() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let checkpoint = Checkpoint(pauseAt: 2)
        let task = Task { try await self.restore([descendant, root], in: session, checkpoint: checkpoint) }
        await checkpoint.waitUntilPaused()
        session.lock()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("Lock must interrupt restoration")
        } catch {
            let failure = try XCTUnwrap(error as? RevisionRestoreFailure)
            XCTAssertEqual(failure.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.failedRevisionId, descendant.revisionId)
            XCTAssertEqual(failure.cause as? SessionError, .interrupted)
        }
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.heads.isEmpty)
        XCTAssertEqual(store.records.count, 1)
        try await session.unlock()
        XCTAssertEqual(session.heads, [root])
    }

    func testLockThenUnlockDoesNotResumeOldRestoreOrClearNewRestoreLease() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let grandchild = child(descendant)
        let backup = try VaultBackup(revisions: [grandchild, descendant, root], blobs: [])
        let oldCheckpoint = Checkpoint(pauseAt: 2)
        let oldService = service(session, checkpoint: oldCheckpoint)
        let oldTask = Task { try await oldService.restoreCooperatively(backup) }
        await oldCheckpoint.waitUntilPaused()
        session.lock()
        try await session.unlock()
        let newCheckpoint = Checkpoint(pauseAt: 2)
        let newService = service(session, checkpoint: newCheckpoint)
        let newTask = Task { try await newService.restoreCooperatively(backup) }
        await newCheckpoint.waitUntilPaused()
        XCTAssertEqual(session.heads, [descendant])
        oldCheckpoint.resume()
        do {
            _ = try await oldTask.value
            XCTFail("A new unlock must not revive the old restore")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.revisionFailure?.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.cause as? SessionError, .interrupted)
        }
        do {
            _ = try await service(session).restoreCooperatively(backup)
            XCTFail("Old completion must not release the new operation's lease")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        XCTAssertEqual(session.heads, [descendant])
        newCheckpoint.resume()
        let result = try await newTask.value
        XCTAssertEqual(result.revisions.addedRevisionIds, [descendant.revisionId, grandchild.revisionId])
        XCTAssertEqual(session.heads, [grandchild])
        XCTAssertEqual(store.records.count, 3)
    }

    func testLockThenUnlockBetweenBlobAndRevisionWritesDoesNotAppendOldOperation() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let attachment = blob(Data([1]))
        var root = revision()
        root.attachments = [metadata(attachment)]
        let backup = try VaultBackup(revisions: [root], blobs: [attachment])
        let checkpoint = Checkpoint(pauseAt: 2)
        var blobWrites = 0
        let service = service(session, checkpoint: checkpoint) { _ in blobWrites += 1 }
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        session.lock()
        try await session.unlock()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("Unlocking must not resume an old restore")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.restoredBlobIds, [attachment.metadata.blobId])
            XCTAssertEqual(failure.revisionFailure?.failedRevisionId, root.revisionId)
            XCTAssertEqual(failure.cause as? SessionError, .interrupted)
        }
        XCTAssertEqual(blobWrites, 1)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testConcurrentNormalSaveAndIncomingRefreshPreserveEveryRevisionAndOriginalBytes() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let backup = try VaultBackup(revisions: [descendant, root], blobs: [])
        let checkpoint = Checkpoint(pauseAt: 2)
        let service = service(session, checkpoint: checkpoint)
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        var edit = try session.editDraft(root)
        edit.title = "Normal save during restore"
        try session.save(edit)
        let independent = revision(title: "New normal record")
        try session.save(independent)
        let remote = revision(title: "Incoming refresh")
        let wireObject = try JSONSerialization.jsonObject(with: RevisionCodec.encode(remote))
        let originalWireBytes = try JSONSerialization.data(withJSONObject: wireObject, options: [.prettyPrinted])
        store.records.append(originalWireBytes)
        try session.refresh()
        // Previously observed incoming history must survive even if the next load no longer returns it.
        store.records.removeLast()
        checkpoint.resume()
        let result = try await task.value
        XCTAssertEqual(result.revisions.addedRevisionIds, [root.revisionId, descendant.revisionId])
        XCTAssertEqual(Set(session.heads.map(\.revisionId)),
                       [edit.revisionId, descendant.revisionId, independent.revisionId, remote.revisionId])
        XCTAssertTrue(session.hasConflict(descendant))
        XCTAssertEqual(Set(try session.revisionsForBackup().map(\.revisionId)),
                       [root.revisionId, edit.revisionId, descendant.revisionId, independent.revisionId, remote.revisionId])
        XCTAssertEqual(store.records.count, 4)
        XCTAssertEqual(try RevisionCodec.decode(store.records[1]), edit)
        XCTAssertEqual(try RevisionCodec.decode(store.records[2]), independent)
        store.records.insert(originalWireBytes, at: 3)
        _ = try await service.restoreCooperatively(try VaultBackup(revisions: [remote], blobs: []))
        XCTAssertEqual(store.records[3], originalWireBytes)
    }

    func testIncomingSameContentAtCheckpointCountsAsExistingWithoutRewritingBytes() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let backup = try VaultBackup(revisions: [descendant, root], blobs: [])
        let checkpoint = Checkpoint(pauseAt: 2)
        let service = service(session, checkpoint: checkpoint)
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        let wireObject = try JSONSerialization.jsonObject(with: RevisionCodec.encode(descendant))
        let originalWireBytes = try JSONSerialization.data(withJSONObject: wireObject, options: [.prettyPrinted])
        store.records.append(originalWireBytes)
        try session.refresh()
        checkpoint.resume()
        let result = try await task.value
        XCTAssertEqual(result.revisions.addedRevisionIds, [root.revisionId])
        XCTAssertEqual(result.revisions.existingRevisionCount, 1)
        XCTAssertEqual(store.appendAttempts, 1)
        XCTAssertEqual(store.records.last, originalWireBytes)
        XCTAssertEqual(session.heads, [descendant])
    }

    func testChangedIncomingIdentityAfterPartialProgressFailsInsteadOfRewriting() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let backup = try VaultBackup(revisions: [descendant, root], blobs: [])
        let checkpoint = Checkpoint(pauseAt: 2)
        let service = service(session, checkpoint: checkpoint)
        let task = Task { try await service.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        var altered = descendant
        altered.title = "Different content, same identity"
        let alteredBytes = try RevisionCodec.encode(altered)
        store.records.append(alteredBytes)
        try session.refresh()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("A changed identity must not be appended over existing data")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.revisionFailure?.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.revisionFailure?.failedRevisionId, descendant.revisionId)
            XCTAssertEqual(failure.cause as? RevisionError, .duplicateRevision(descendant.revisionId))
        }
        XCTAssertEqual(store.appendAttempts, 1)
        XCTAssertEqual(store.records.last, alteredBytes)
        XCTAssertEqual(session.heads, [altered])
    }

    func testSynchronousStorageCallbackSaveAndRefreshAreNotOverwrittenByAsyncPublication() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let independent = revision(title: "Callback normal save")
        let incoming = revision(title: "Callback incoming refresh")
        store.afterAppend = {
            store.afterAppend = nil
            try session.save(independent)
            store.records.append(try RevisionCodec.encode(incoming))
            try session.refresh()
        }
        let result = try await session.restoreRevisionsCooperatively([root])
        XCTAssertEqual(result.addedRevisionIds, [root.revisionId])
        XCTAssertEqual(Set(session.heads.map(\.revisionId)), [root.revisionId, independent.revisionId, incoming.revisionId])
        XCTAssertEqual(store.records.count, 3)
    }

    func testDuplicateCooperativeRestoreAcrossServicesIsRejectedAndCancellationReleasesLease() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let backup = try VaultBackup(revisions: [root], blobs: [])
        let checkpoint = Checkpoint(pauseAt: 1)
        let first = service(session, checkpoint: checkpoint)
        let task = Task { try await first.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        do {
            _ = try await service(session).restoreCooperatively(backup)
            XCTFail("A second service must not start an overlapping restore")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        do {
            _ = try await session.restoreRevisionsCooperatively([root])
            XCTFail("A direct revision restore must share the backup operation's lease")
        } catch {
            XCTAssertEqual(error as? SessionError, .interrupted)
        }
        XCTAssertTrue(store.records.isEmpty)
        task.cancel()
        checkpoint.resume()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the first restore")
        } catch {
            XCTAssertTrue((error as? BackupRestoreFailure)?.cause is CancellationError)
        }
        let retry = try await service(session).restoreCooperatively(backup)
        XCTAssertEqual(retry.revisions.addedRevisionIds, [root.revisionId])
        XCTAssertEqual(store.records.count, 1)
    }

    func testPreflightRejectsInvalidSkipCloudAttachmentsAndIdentityCollisionBeforeAnyWrites() async throws {
        let store = MemoryStore()
        let existing = revision()
        store.records = [try RevisionCodec.encode(existing)]
        let session = session(store)
        try await session.unlock()
        let attachment = blob(Data([1]), scope: .synchronizable)
        var cloud = revision(scope: .synchronizable)
        cloud.attachments = [metadata(attachment)]
        let descendant = child(cloud)
        let local = revision()
        let backup = try VaultBackup(revisions: [descendant, cloud, local], blobs: [attachment])
        var blobWrites = 0
        let service = service(session) { _ in blobWrites += 1 }
        do {
            _ = try await service.restoreCooperatively(backup, skippingRecords: [UUID()])
            XCTFail("Invalid skip must fail")
        } catch { XCTAssertEqual(error as? SessionError, .missingRecord) }
        do {
            _ = try await service.restoreCooperatively(backup)
            XCTFail("Cloud attachments must fail preflight")
        } catch { XCTAssertEqual(error as? BackupError, .cloudAttachmentUnavailable) }
        var altered = existing
        altered.title = "Changed identity"
        do {
            _ = try await service.restoreCooperatively(try VaultBackup(revisions: [altered, cloud], blobs: [attachment]))
            XCTFail("Combined identity collision must fail")
        } catch { XCTAssertEqual(error as? RevisionError, .duplicateRevision(existing.revisionId)) }
        XCTAssertEqual(blobWrites, 0)
        XCTAssertEqual(store.records.count, 1)
        let skipped = try await service.restoreCooperatively(backup, skippingRecords: [cloud.recordId])
        XCTAssertEqual(skipped.revisions.skippedRevisionCount, 2)
        XCTAssertEqual(skipped.revisions.addedRevisionIds, [local.revisionId])
        XCTAssertTrue(skipped.restoredBlobIds.isEmpty)
        XCTAssertEqual(blobWrites, 0)
    }

    func testAllMissingRevisionsAreEncodedAndGraphValidatedBeforeFirstAppend() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        var invalid = child(root)
        invalid.unknownProperties = ["future": .number("not-a-number")]
        do {
            _ = try await session.restoreRevisionsCooperatively([invalid, root])
            XCTFail("Encoding the later child must fail before the first append")
        } catch { XCTAssertEqual(error as? RevisionError, .invalidNumber("not-a-number")) }
        var health = root
        health.templateId = "medical-record"
        do {
            _ = try await session.restoreRevisionsCooperatively([health], skippingRecords: [health.recordId])
            XCTFail("Skipping must not bypass validation of prohibited contents")
        } catch { XCTAssertEqual(error as? RevisionError, .healthInformationProhibited("medical-record")) }
        do {
            _ = try await session.restoreRevisionsCooperatively([child(root)])
            XCTFail("Missing parents must fail before any write")
        } catch {
            guard case .missingParent = error as? RevisionError else { return XCTFail("Expected missing parent") }
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testAppendFailureAndReadFailureKeepExactCompletedRevisionIdsAndUnderlyingCauses() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let descendant = child(root)
        let backup = try VaultBackup(revisions: [descendant, root], blobs: [])
        store.failAppendAt = 2
        let service = service(session)
        do {
            _ = try await service.restoreCooperatively(backup)
            XCTFail("Append failure must be reported")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.revisionFailure?.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.revisionFailure?.failedRevisionId, descendant.revisionId)
            XCTAssertEqual(failure.cause as? Failure, .append)
            XCTAssertEqual(failure.revisionFailure?.cause as? Failure, .append)
        }
        XCTAssertEqual(session.heads, [root])
        store.failAppendAt = nil
        let checkpoint = Checkpoint(pauseAt: 1)
        let retryService = self.service(session, checkpoint: checkpoint)
        let retry = Task { try await retryService.restoreCooperatively(backup) }
        await checkpoint.waitUntilPaused()
        store.readFails = true
        checkpoint.resume()
        do {
            _ = try await retry.value
            XCTFail("Intervening read failure must not be ignored")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.revisionFailure?.result.addedRevisionIds, [])
            XCTAssertEqual(failure.revisionFailure?.result.existingRevisionCount, 1)
            XCTAssertEqual(failure.revisionFailure?.failedRevisionId, descendant.revisionId)
            XCTAssertEqual(failure.cause as? Failure, .read)
        }
        XCTAssertEqual(store.records.count, 1)
        store.readFails = false
        let result = try await service.restoreCooperatively(backup)
        XCTAssertEqual(result.revisions.addedRevisionIds, [descendant.revisionId])
        XCTAssertEqual(session.heads, [descendant])
    }

    func testBlobFailureKeepsCompletedBlobIdsAndPrecedesAllRevisionWrites() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let first = blob(Data([1]))
        let second = blob(Data([2]))
        var root = revision()
        root.attachments = [metadata(first), metadata(second)]
        let backup = try VaultBackup(revisions: [root], blobs: [first, second])
        let service = service(session) {
            if $0.metadata.blobId == second.metadata.blobId { throw Failure.blob }
        }
        do {
            _ = try await service.restoreCooperatively(backup)
            XCTFail("Blob failure must be reported")
        } catch {
            let failure = try XCTUnwrap(error as? BackupRestoreFailure)
            XCTAssertEqual(failure.restoredBlobIds, [first.metadata.blobId])
            XCTAssertNil(failure.revisionFailure)
            XCTAssertEqual(failure.cause as? Failure, .blob)
        }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testLockInsideAppendCallbackReportsCompletedWriteWithoutPublishingIt() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        store.afterAppend = { session.lock() }
        do {
            _ = try await session.restoreRevisionsCooperatively([root])
            XCTFail("Lock inside storage must interrupt")
        } catch {
            let failure = try XCTUnwrap(error as? RevisionRestoreFailure)
            XCTAssertEqual(failure.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(failure.failedRevisionId, root.revisionId)
            XCTAssertEqual(failure.cause as? SessionError, .interrupted)
        }
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(session.heads.isEmpty)
        XCTAssertEqual(session.state, .locked)
    }
}
