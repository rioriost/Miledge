import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import UniformTypeIdentifiers
import XCTest
@testable import MiledgeApp

@MainActor
final class BackupFlowTests: XCTestCase {
    private let phrase = "Synthetic-backup-passphrase-0123456789"

    @MainActor
    private final class History {
        var bytes: [Data] = []
        var writes = 0
        var failAt: Int?
        var afterWrite: (() -> Void)?

        func append(_ data: Data) throws {
            writes += 1
            if writes == failAt { throw CocoaError(.fileWriteOutOfSpace) }
            bytes.append(data)
            afterWrite?()
        }
    }

    private struct Fixture {
        let history: History
        let session: VaultSession
        let service: BackupService
        let directory: URL
    }

    private func fixture(_ revisions: [VaultRevision] = []) async throws -> Fixture {
        let history = History()
        history.bytes = try revisions.map(RevisionCodec.encode)
        let session = VaultSession(
            authenticate: {}, load: { history.bytes }, append: { data, _, _ in try history.append(data) }
        )
        try await session.unlock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return Fixture(
            history: history, session: session,
            service: BackupService(session: session, attachments: attachments), directory: directory
        )
    }

    private func authorize(_ flow: BackupFlow) {
        flow.passphrase = phrase
        flow.confirmation = phrase
    }

    private func open(_ backup: VaultBackup, in fixture: Fixture) async throws -> BackupFlow {
        let flow = BackupFlow(
            mode: .restore, session: fixture.session, service: fixture.service,
            decrypt: { _, _ in backup }
        )
        flow.selectFile(.success(fixture.directory.appendingPathComponent("Synthetic.miledge-backup")))
        flow.passphrase = phrase
        let task = try XCTUnwrap(flow.prepare())
        await task.value
        XCTAssertEqual(flow.stage, .preview)
        return flow
    }

    func testPassphraseValidationAndConfirmationCompareExactUTF8WithoutTrimming() async throws {
        let fixture = try await fixture()
        let flow = BackupFlow(mode: .export, session: fixture.session, service: fixture.service)
        XCTAssertFalse(flow.canPrepare)
        XCTAssertNil(flow.validationMessage)
        XCTAssertNil(flow.prepare())
        XCTAssertNotNil(flow.issue)
        for phrase in [String(repeating: "x", count: 23), String(repeating: "x", count: 129), phrase + "\0"] {
            flow.passphrase = phrase
            flow.confirmation = phrase
            XCTAssertFalse(flow.validPassphrase)
            XCTAssertNotNil(flow.validationMessage)
        }
        for phrase in [String(repeating: " ", count: 24), String(repeating: "é", count: 64)] {
            flow.passphrase = phrase
            flow.confirmation = phrase
            XCTAssertTrue(flow.canPrepare)
        }
        flow.passphrase = String(repeating: "x", count: 24) + "é"
        flow.confirmation = String(repeating: "x", count: 24) + "e\u{301}"
        XCTAssertEqual(flow.passphrase, flow.confirmation)
        XCTAssertFalse(flow.canPrepare)
        XCTAssertNotNil(flow.validationMessage)
        fixture.session.lock()
        XCTAssertFalse(flow.canPrepare)
        flow.generatePassphrase()
        XCTAssertNotNil(flow.issue)
    }

    func testGenerationRequiresSeparateConfirmationAndReportsFailures() async throws {
        let fixture = try await fixture()
        let generated = phrase + "generated"
        let flow = BackupFlow(
            mode: .export, session: fixture.session, service: fixture.service, generate: { generated }
        )
        flow.confirmation = "old"
        flow.generatePassphrase()
        XCTAssertEqual(flow.passphrase, generated)
        XCTAssertTrue(flow.revealing)
        XCTAssertEqual(flow.confirmation, "")
        XCTAssertFalse(flow.canPrepare)
        let failing = BackupFlow(
            mode: .export, session: fixture.session, service: fixture.service,
            generate: { throw PasswordArchiveError.streamFailure }
        )
        failing.generatePassphrase()
        XCTAssertNotNil(failing.issue)
        let restore = BackupFlow(mode: .restore, session: fixture.session, service: fixture.service)
        restore.generatePassphrase()
        XCTAssertNotNil(restore.issue)
    }

    func testExportClearsCredentialsAndProducesOnlyACompleteDecryptableArchive() async throws {
        let revision = VaultRevision(title: "Synthetic exact history")
        let fixture = try await fixture([revision])
        let flow = BackupFlow(mode: .export, session: fixture.session, service: fixture.service)
        authorize(flow)
        let task = try XCTUnwrap(flow.prepare())
        XCTAssertTrue(flow.working)
        XCTAssertEqual(flow.passphrase, "")
        XCTAssertEqual(flow.confirmation, "")
        await task.value
        XCTAssertEqual(flow.stage, .exportReady)
        XCTAssertFalse(flow.working)
        XCTAssertNil(flow.backup)
        XCTAssertNil(flow.issue)
        let ciphertext = try XCTUnwrap(flow.ciphertext)
        let restored = try VaultBackup.decrypt(ciphertext, passphrase: phrase)
        XCTAssertEqual(restored.revisions, [revision])
        let document = EncryptedBackupDocument(ciphertext: ciphertext, attempt: flow.attempt)
        let snapshot = try await document.snapshot()
        XCTAssertEqual(snapshot, ciphertext)
        XCTAssertEqual(UTType.miledgeBackup.identifier, "com.miledge.encrypted-backup")
        XCTAssertTrue(UTType.miledgeBackup.conforms(to: .data))
        document.invalidate()
        do { _ = try await document.snapshot(); XCTFail("Invalidated exports must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNativeTransferRepresentationContainsOnlyCiphertext() async throws {
        let fixture = try await fixture()
        let flow = BackupFlow(mode: .export, session: fixture.session, service: fixture.service)
        authorize(flow)
        try await XCTUnwrap(flow.prepare()).value
        let ciphertext = try XCTUnwrap(flow.ciphertext)
        let document = EncryptedBackupDocument(ciphertext: ciphertext, attempt: flow.attempt)
        let transferred = try await document.exported(as: .miledgeBackup)
        XCTAssertEqual(transferred, ciphertext)
        document.invalidate()
        var invalidatedExport: Data?
        do { invalidatedExport = try await document.exported(as: .miledgeBackup) }
        catch { XCTAssertNil(invalidatedExport) }
        XCTAssertNil(invalidatedExport, "Invalidated exports must not produce data")
    }

    func testExportCompletionRequiresMatchingAttemptAndActualFileDialogSuccess() async throws {
        let fixture = try await fixture()
        let flow = BackupFlow(mode: .export, session: fixture.session, service: fixture.service)
        authorize(flow)
        try await XCTUnwrap(flow.prepare()).value
        flow.exportCompleted(.success(fixture.directory), attempt: UUID())
        XCTAssertEqual(flow.stage, .exportReady)
        flow.exportCompleted(.failure(CocoaError(.fileWriteUnknown)), attempt: flow.attempt)
        XCTAssertEqual(flow.stage, .entry)
        XCTAssertNil(flow.ciphertext)
        XCTAssertNotNil(flow.issue)
        authorize(flow)
        try await XCTUnwrap(flow.prepare()).value
        let attempt = flow.attempt
        flow.exportCompleted(.success(fixture.directory), attempt: attempt)
        XCTAssertEqual(flow.stage, .finished)
        XCTAssertNil(flow.ciphertext)
        flow.cancel()
        flow.exportCompleted(.success(fixture.directory), attempt: attempt)
        XCTAssertEqual(flow.stage, .entry)
    }

    func testRealFileDecryptionPreviewsThenRestoresOnlyAfterConfirmation() async throws {
        let fixture = try await fixture()
        let revisions = [VaultRevision(title: "Synthetic first"), VaultRevision(title: "Synthetic second")]
        let backup = try VaultBackup(revisions: revisions, blobs: [])
        let url = fixture.directory.appendingPathComponent("Synthetic.miledge-backup")
        try backup.encrypted(passphrase: phrase).write(to: url)
        let flow = BackupFlow(mode: .restore, session: fixture.session, service: fixture.service)
        flow.selectFile(.success(url))
        XCTAssertEqual(flow.file, url)
        flow.passphrase = phrase
        XCTAssertTrue(flow.canPrepare)
        try await XCTUnwrap(flow.prepare()).value
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertEqual(flow.preview?.recordCount, 2)
        XCTAssertTrue(fixture.history.bytes.isEmpty)
        XCTAssertEqual(flow.passphrase, "")
        XCTAssertTrue(flow.canRestore)
        for id in flow.recordIds {
            XCTAssertFalse(flow.title(for: id).isEmpty)
            flow.include(id, false)
        }
        XCTAssertEqual(flow.preview?.recordCount, 0)
        XCTAssertFalse(flow.canRestore)
        XCTAssertNil(flow.restoreSelected())
        flow.include(revisions[0].recordId, true)
        XCTAssertEqual(flow.preview?.recordCount, 1)
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(flow.stage, .finished)
        XCTAssertNil(flow.backup)
        XCTAssertNil(flow.file)
        XCTAssertEqual(flow.restored?.revisions.addedRevisionIds, [revisions[0].revisionId])
        XCTAssertEqual(flow.restored?.revisions.skippedRevisionCount, 1)
        XCTAssertEqual(try fixture.history.bytes.map(RevisionCodec.decode), [revisions[0]])
    }

    func testUnknownItemsAndConflictsRemainWholeVersionsAndCanBeRetriedIdempotently() async throws {
        let first = VaultRevision(title: "Synthetic existing")
        var competitor = first
        competitor.revisionId = UUID()
        competitor.title = "Synthetic other"
        var future = VaultRevision(title: "Synthetic future")
        future.schemaVersion = 999
        future.unknownProperties = ["exact": .number("9007199254740993")]
        let backup = try VaultBackup(revisions: [competitor, future], blobs: [])
        let fixture = try await fixture([first])
        let flow = try await open(backup, in: fixture)
        XCTAssertEqual(flow.preview?.conflictingRecordCount, 1)
        flow.refreshPreview()
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(fixture.session.heads.count, 3)
        let retry = try await open(backup, in: fixture)
        XCTAssertEqual(retry.preview?.existingRevisionCount, 2)
        try await XCTUnwrap(retry.restoreSelected()).value
        XCTAssertEqual(retry.restored?.revisions.addedRevisionIds, [])
        XCTAssertEqual(fixture.history.bytes.count, 3)
        XCTAssertTrue(try fixture.history.bytes.map(RevisionCodec.decode).contains(future))
    }

    func testPartialWriteFailureShowsActualProgressAndRetryKeepsOriginalHistory() async throws {
        let first = VaultRevision(title: "Synthetic ancestor")
        var second = first
        second.revisionId = UUID()
        second.parentRevisionIds = [first.revisionId]
        let fixture = try await fixture()
        fixture.history.failAt = 2
        let flow = try await open(try VaultBackup(revisions: [second, first], blobs: []), in: fixture)
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertEqual(flow.partial?.revisions, 1)
        XCTAssertEqual(flow.partial?.blobs, 0)
        XCTAssertNotNil(flow.backup)
        XCTAssertNotNil(flow.issue)
        fixture.history.failAt = nil
        flow.refreshPreview()
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(flow.stage, .finished)
        XCTAssertEqual(flow.restored?.revisions.addedRevisionIds, [second.revisionId])
        XCTAssertEqual(try fixture.history.bytes.map(RevisionCodec.decode), [first, second])
    }

    func testCloudAttachmentsRequireWholeRecordSkippingBeforeAnyWrite() async throws {
        let local = VaultRevision(title: "Synthetic local")
        var cloud = VaultRevision(storageScope: .synchronizable, title: "Synthetic cloud")
        let blob = EncryptedBlob(blobId: UUID(), key: Data(repeating: 9, count: 32), plaintextSize: 1)
        cloud.attachments = [AttachmentMetadata(blob: blob, filename: "Synthetic", mediaType: "public.data").json]
        let backup = try VaultBackup(
            revisions: [local, cloud], blobs: [BackupBlob(metadata: blob, bytes: Data([1]), scope: .synchronizable)]
        )
        let fixture = try await fixture()
        let flow = try await open(backup, in: fixture)
        XCTAssertTrue(flow.needsCloudFiles(cloud.recordId))
        XCTAssertFalse(flow.canRestore)
        XCTAssertTrue(fixture.history.bytes.isEmpty)
        flow.include(cloud.recordId, false)
        XCTAssertTrue(flow.canRestore)
        XCTAssertEqual(flow.preview?.recordCount, 1)
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(try fixture.history.bytes.map(RevisionCodec.decode), [local])
    }

    func testBadFileAndWrongPasswordNeverExposeContentsOrAppendData() async throws {
        let fixture = try await fixture()
        let url = fixture.directory.appendingPathComponent("Synthetic.miledge-backup")
        let flow = BackupFlow(mode: .restore, session: fixture.session, service: fixture.service)
        for data in [
            Data("Not a backup".utf8),
            try VaultBackup(revisions: [VaultRevision(title: "Synthetic")], blobs: [])
                .encrypted(passphrase: phrase + "-different")
        ] {
            try data.write(to: url)
            flow.selectFile(.success(url))
            flow.passphrase = phrase
            try await XCTUnwrap(flow.prepare()).value
            XCTAssertEqual(flow.stage, .entry)
            XCTAssertNotNil(flow.issue)
            XCTAssertNil(flow.backup)
            XCTAssertNil(flow.preview)
            XCTAssertTrue(fixture.history.bytes.isEmpty)
            XCTAssertEqual(flow.passphrase, "")
        }
    }

    func testSelectionAndReviewFailuresAreExplicitAndInvalidateRestore() async throws {
        let fixture = try await fixture()
        let flow = BackupFlow(mode: .restore, session: fixture.session, service: fixture.service)
        flow.passphrase = phrase
        flow.selectFile(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertNil(flow.file)
        XCTAssertEqual(flow.passphrase, "")
        XCTAssertNotNil(flow.issue)
        flow.include(UUID(), false)
        XCTAssertNotNil(flow.issue)
        flow.refreshPreview()
        XCTAssertNil(flow.preview)
        let incoming = VaultRevision(title: "Synthetic source")
        let preview = try await open(try VaultBackup(revisions: [incoming], blobs: []), in: fixture)
        var changed = incoming
        changed.title = "Different data with same ID"
        fixture.history.bytes = [try RevisionCodec.encode(changed)]
        preview.refreshPreview()
        XCTAssertNil(preview.preview)
        XCTAssertFalse(preview.canRestore)
        XCTAssertNotNil(preview.issue)
        let invalid = try await self.fixture([changed])
        let decrypting = BackupFlow(
            mode: .restore, session: invalid.session, service: invalid.service,
            decrypt: { _, _ in try VaultBackup(revisions: [incoming], blobs: []) }
        )
        decrypting.selectFile(.success(invalid.directory))
        decrypting.passphrase = phrase
        try await XCTUnwrap(decrypting.prepare()).value
        XCTAssertEqual(decrypting.stage, .entry)
        XCTAssertNil(decrypting.backup)
    }

    func testEncryptionSizeAndSnapshotErrorsHaveSecretFreeFailureMessages() async throws {
        let fixture = try await fixture()
        for error in [PasswordArchiveError.oversized, .streamFailure] {
            let flow = BackupFlow(
                mode: .export, session: fixture.session, service: fixture.service,
                encrypt: { _, _ in throw error }
            )
            authorize(flow)
            try await XCTUnwrap(flow.prepare()).value
            XCTAssertEqual(flow.stage, .entry)
            XCTAssertNotNil(flow.issue)
            XCTAssertNil(flow.ciphertext)
        }
        let restore = BackupFlow(
            mode: .restore, session: fixture.session, service: fixture.service,
            decrypt: { _, _ in throw BackupError.oversized }
        )
        restore.selectFile(.success(fixture.directory))
        restore.passphrase = phrase
        try await XCTUnwrap(restore.prepare()).value
        XCTAssertEqual(restore.issue, String(localized: "The backup exceeds the supported size limits."))
        var missing = VaultRevision(title: "Synthetic missing attachment")
        missing.attachments = [AttachmentMetadata(
            blob: EncryptedBlob(blobId: UUID(), key: Data(repeating: 0, count: 32), plaintextSize: 1),
            filename: "Synthetic", mediaType: "public.data"
        ).json]
        let incomplete = try await self.fixture([missing])
        let export = BackupFlow(mode: .export, session: incomplete.session, service: incomplete.service)
        authorize(export)
        try await XCTUnwrap(export.prepare()).value
        XCTAssertNil(export.ciphertext)
        XCTAssertNotNil(export.issue)
    }

    func testCancellationAndLateResultCannotRepopulateDismissedFlow() async throws {
        let fixture = try await fixture()
        let gate = BackupFlowGate<Data>()
        let flow = BackupFlow(
            mode: .export, session: fixture.session, service: fixture.service,
            encrypt: { _, _ in await gate.wait() }
        )
        authorize(flow)
        let task = try XCTUnwrap(flow.prepare())
        await gate.waitUntilStarted()
        flow.cancel()
        await gate.finish(Data("Synthetic late ciphertext".utf8))
        await task.value
        XCTAssertEqual(flow.stage, .entry)
        XCTAssertNil(flow.ciphertext)
        XCTAssertNil(flow.issue)
        XCTAssertEqual(flow.passphrase, "")
        flow.stopRestoration()
    }

    func testLockAndReunlockRejectsResultsEvenWithoutAViewObservingIntermediateState() async throws {
        let fixture = try await fixture()
        let gate = BackupFlowGate<VaultBackup>()
        let flow = BackupFlow(
            mode: .restore, session: fixture.session, service: fixture.service,
            decrypt: { _, _ in await gate.wait() }
        )
        flow.selectFile(.success(fixture.directory))
        flow.passphrase = phrase
        let task = try XCTUnwrap(flow.prepare())
        await gate.waitUntilStarted()
        fixture.session.lock()
        try await fixture.session.unlock()
        await gate.finish(try VaultBackup(revisions: [VaultRevision(title: "Synthetic late")], blobs: []))
        await task.value
        XCTAssertEqual(flow.stage, .entry)
        XCTAssertNil(flow.backup)
        XCTAssertNil(flow.file)
        XCTAssertFalse(flow.canPrepare)
        flow.selectFile(.success(fixture.directory))
        XCTAssertNil(flow.file)
        XCTAssertTrue(fixture.history.bytes.isEmpty)
    }

    func testUnexpectedWorkerCancellationAndLockedExportCompletionAreNotSuccess() async throws {
        let fixture = try await fixture()
        let flow = BackupFlow(
            mode: .export, session: fixture.session, service: fixture.service,
            encrypt: { _, _ in throw CancellationError() }
        )
        authorize(flow)
        try await XCTUnwrap(flow.prepare()).value
        XCTAssertEqual(flow.issue, String(localized: "The backup operation was cancelled."))
        let ready = BackupFlow(mode: .export, session: fixture.session, service: fixture.service)
        authorize(ready)
        try await XCTUnwrap(ready.prepare()).value
        fixture.session.lock()
        ready.exportCompleted(.success(fixture.directory), attempt: ready.attempt)
        XCTAssertNotEqual(ready.stage, .finished)
        ready.cancel()
        XCTAssertNil(ready.ciphertext)
    }

    func testStoppingRestorationRetainsBackupAndReportsThePersistedPrefix() async throws {
        let fixture = try await fixture()
        let backup = try VaultBackup(
            revisions: [VaultRevision(title: "Synthetic A"), VaultRevision(title: "Synthetic B")], blobs: []
        )
        let flow = try await open(backup, in: fixture)
        fixture.history.afterWrite = { flow.stopRestoration() }
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertEqual(flow.partial?.revisions, 1)
        XCTAssertEqual(fixture.history.bytes.count, 1)
        fixture.history.afterWrite = nil
        flow.refreshPreview()
        try await XCTUnwrap(flow.restoreSelected()).value
        XCTAssertEqual(flow.stage, .finished)
        XCTAssertEqual(fixture.history.bytes.count, 2)
    }

    func testFileReaderIsBoundedCoordinatedAndRejectsNonregularOrUnavailablePaths() async throws {
        let fixture = try await fixture()
        let url = fixture.directory.appendingPathComponent("Synthetic.miledge-backup")
        let data = Data(repeating: 7, count: 64 * 1024 + 1)
        try data.write(to: url)
        let read = try await Task.detached { try BackupFile.read(url) }.value
        XCTAssertEqual(read, data)
        for url in [fixture.directory, fixture.directory.appendingPathComponent("missing"),
                    try XCTUnwrap(URL(string: "https://example.invalid/Synthetic"))] {
            do { _ = try await Task.detached { try BackupFile.read(url) }.value; XCTFail("Reject invalid file") }
            catch { XCTAssertFalse(String(describing: error).isEmpty) }
        }
        let large = fixture.directory.appendingPathComponent("Oversized.miledge-backup")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(PasswordArchive.maximumEncryptedBytes) + 1)
        try handle.close()
        do { _ = try await Task.detached { try BackupFile.read(large) }.value; XCTFail("Reject oversized file") }
        catch { XCTAssertEqual(error as? BackupError, .oversized) }
        let link = fixture.directory.appendingPathComponent("Symlink.miledge-backup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        do { _ = try BackupFile.read(link); XCTFail("Do not follow selected leaf symlinks") }
        catch { XCTAssertNotNil(error as NSError) }
    }
}

private actor BackupFlowGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
import CoreTransferable
