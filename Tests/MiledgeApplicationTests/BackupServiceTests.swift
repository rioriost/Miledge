import Foundation
@testable import MiledgeDomain
import MiledgeStorage
import XCTest
@testable import MiledgeApplication

@MainActor
final class BackupServiceTests: XCTestCase {
    private let passphrase = "Synthetic backup passphrase 0123456789"
    enum Failure: Error { case read, append, blob }

    final class MemoryStore {
        var records: [Data] = []
        var appendCount = 0
        var failureAt: Int?
        var readFails = false
        var blobFails = false
        var scopes: [StorageScope] = []
        var afterAppend: (() -> Void)?

        func read() throws -> [Data] {
            if readFails { throw Failure.read }
            return records
        }

        func append(_ data: Data, account: String, scope: StorageScope) throws {
            appendCount += 1
            if appendCount == failureAt { throw Failure.append }
            let revision = try RevisionCodec.decode(data)
            XCTAssertEqual(account, "\(revision.recordId.uuidString)/\(revision.revisionId.uuidString)")
            XCTAssertFalse(try records.map(RevisionCodec.decode).contains(where: { $0.revisionId == revision.revisionId }))
            records.append(data)
            scopes.append(scope)
            afterAppend?()
        }
    }

    private func session(_ store: MemoryStore) -> VaultSession {
        VaultSession(authenticate: {}, load: { try store.read() }, append: { try store.append($0, account: $1, scope: $2) })
    }

    private func revision(title: String = "Synthetic backup item", scope: StorageScope = .deviceLocal) -> VaultRevision {
        VaultRevision(
            storageScope: scope, title: title, tags: ["  Exact Tag "], favorite: true,
            createdAt: Date(timeIntervalSince1970: 0),
            sections: [.init(id: "synthetic", fields: [
                .init(id: "secret", kind: "multiline", value: .string("  0001\r\nالعربية e\u{301}\n"), concealed: true)
            ])], linkedRecordIds: [UUID(), UUID()]
        )
    }

    private func branch(_ parent: VaultRevision, title: String, deleted: Bool = false) -> VaultRevision {
        var child = parent
        child.revisionId = UUID()
        child.parentRevisionIds = [parent.revisionId]
        child.title = title
        child.deleted = deleted
        return child
    }

    private func attachment(_ bytes: Data, id: UUID = UUID()) -> AttachmentMetadata {
        AttachmentMetadata(
            blob: EncryptedBlob(blobId: id, key: Data(repeating: 7, count: 32), plaintextSize: bytes.count),
            filename: "../../../Synthetic filename", mediaType: "application/octet-stream"
        )
    }

    private func service(
        _ session: VaultSession, bytes: [UUID: Data] = [:],
        restore: @escaping @MainActor (BackupBlob) throws -> Void = { _ in }
    ) -> BackupService {
        BackupService(session: session, readBlob: {
            guard let bytes = bytes[$0.blobId] else { throw EncryptedBlobError.missing }
            return bytes
        }, restoreBlob: restore)
    }

    func testSnapshotPreservesAllObservedHistoryAttachmentsUnknownValuesAndExactStrings() async throws {
        let store = MemoryStore()
        let bytes = Data([0, 255]) + Data("Synthetic\r\nالعربية e\u{301}".utf8)
        let metadata = attachment(bytes)
        var root = revision()
        root.attachments = [metadata.json, metadata.json]
        root.linkedRecordIds = [root.recordId, root.recordId, UUID()]
        let first = branch(root, title: "Synthetic first")
        let deletion = branch(root, title: "Synthetic deleted", deleted: true)
        var unknown = revision(title: "")
        unknown.schemaVersion = 99
        unknown.unknownProperties = ["future": .number("9007199254740993")]
        store.records = try [root, first, unknown].map(RevisionCodec.encode)
        let session = session(store)
        try await session.unlock()
        store.records = try [root, deletion].map(RevisionCodec.encode)
        let backup = try service(session, bytes: [metadata.blob.blobId: bytes]).snapshot()
        XCTAssertEqual(Set(backup.revisions.map(\.revisionId)), Set([root, first, deletion, unknown].map(\.revisionId)))
        XCTAssertEqual(backup.blobs.count, 1)
        XCTAssertEqual(backup.blobs.first?.bytes, bytes)
        let encoded = try backup.encrypted(passphrase: passphrase)
        XCTAssertNil(encoded.range(of: Data(root.title.utf8)))
        let decoded = try VaultBackup.decrypt(encoded, passphrase: passphrase)
        XCTAssertEqual(decoded.revisions, backup.revisions)
        XCTAssertEqual(decoded.blobs, backup.blobs)
        XCTAssertEqual(decoded.revisions.first?.linkedRecordIds, root.linkedRecordIds)
        XCTAssertEqual(decoded.revisions.first?.attachments, [metadata.json, metadata.json])
        XCTAssertEqual(decoded.revisions.first { $0.revisionId == unknown.revisionId }?
            .unknownProperties["future"], .number("9007199254740993"))
    }

    func testRestoreWholeGraphInParentOrderAndRetainConflictsThroughReloadAndRetry() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let first = branch(root, title: "Synthetic first")
        let second = branch(root, title: "Synthetic concurrent deletion", deleted: true)
        let backup = try VaultBackup(revisions: [second, first, root], blobs: [])
        let service = service(session)
        let preview = try service.preview(backup)
        XCTAssertEqual(preview.recordCount, 1)
        XCTAssertEqual(preview.revisionCount, 3)
        XCTAssertEqual(preview.conflictingRecordCount, 1)
        XCTAssertEqual(preview.existingRevisionCount, 0)
        let result = try service.restore(backup)
        XCTAssertEqual(result.revisions.addedRevisionIds.first, root.revisionId)
        XCTAssertEqual(store.records.count, 3)
        XCTAssertEqual(Set(session.heads.map(\.revisionId)), [first.revisionId, second.revisionId])
        session.lock()
        try await session.unlock()
        XCTAssertEqual(try session.revisionsForBackup().count, 3)
        XCTAssertEqual(try service.preview(backup).existingRevisionCount, 3)
        let retry = try service.restore(backup)
        XCTAssertTrue(retry.revisions.addedRevisionIds.isEmpty)
        XCTAssertEqual(retry.revisions.existingRevisionCount, 3)
        XCTAssertEqual(store.appendCount, 3)
    }

    func testAppendFailureReportsActualPartialHistoryAndRetryDoesNotDuplicate() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let root = revision()
        let child = branch(root, title: "Synthetic child")
        let grandchild = branch(child, title: "Synthetic grandchild")
        let backup = try VaultBackup(revisions: [grandchild, child, root], blobs: [])
        let service = service(session)
        store.failureAt = 2
        XCTAssertThrowsError(try service.restore(backup)) {
            let error = $0 as? BackupRestoreFailure
            XCTAssertEqual(error?.revisionFailure?.result.addedRevisionIds, [root.revisionId])
            XCTAssertEqual(error?.revisionFailure?.failedRevisionId, child.revisionId)
            XCTAssertTrue(error?.cause is Failure)
        }
        XCTAssertEqual(session.heads, [root])
        XCTAssertEqual(store.records.count, 1)
        store.failureAt = nil
        let retry = try service.restore(backup)
        XCTAssertEqual(retry.revisions.addedRevisionIds, [child.revisionId, grandchild.revisionId])
        XCTAssertEqual(retry.revisions.existingRevisionCount, 1)
        XCTAssertEqual(store.records.count, 3)
        XCTAssertEqual(session.heads, [grandchild])
    }

    func testBlobFailurePrecedesAllRevisionWritesAndIsRetryable() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        var root = revision()
        let first = attachment(Data([1]))
        let second = attachment(Data([2]))
        root.attachments = [first.json, second.json]
        let backup = try VaultBackup(revisions: [root], blobs: [
            .init(metadata: first.blob, bytes: Data([1]), scope: .deviceLocal),
            .init(metadata: second.blob, bytes: Data([2]), scope: .deviceLocal)
        ])
        store.blobFails = true
        var restored: [UUID: Data] = [:]
        let service = service(session) {
            if store.blobFails, $0.metadata.blobId == second.blob.blobId { throw Failure.blob }
            restored[$0.metadata.blobId] = $0.bytes
        }
        XCTAssertThrowsError(try service.restore(backup)) {
            XCTAssertEqual(($0 as? BackupRestoreFailure)?.restoredBlobIds, [first.blob.blobId])
            XCTAssertNil(($0 as? BackupRestoreFailure)?.revisionFailure)
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(restored.count, 1)
        store.blobFails = false
        XCTAssertEqual(try service.restore(backup).restoredBlobIds.count, 2)
        XCTAssertEqual(store.records.count, 1)
    }

    func testRealCiphertextAttachmentStoreRestoresOriginalIdentityWithoutUsingFilenames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiledgeBackupTests-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let bytes = Data([0, 255]) + Data("Synthetic only\r\n".utf8)
        let metadata = attachment(bytes)
        var root = revision()
        root.attachments = [metadata.json]
        let backup = try VaultBackup(revisions: [root], blobs: [
            .init(metadata: metadata.blob, bytes: bytes, scope: .deviceLocal)
        ])
        let service = BackupService(session: session, attachments: attachments)
        _ = try service.restore(backup)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.lastPathComponent, metadata.blob.blobId.uuidString.lowercased() + ".miledgeblob")
        let ciphertext = try Data(contentsOf: XCTUnwrap(files.first))
        _ = try service.restore(backup)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), ciphertext)
        XCTAssertEqual(try attachments.read(metadata), bytes)
        XCTAssertEqual(try service.snapshot().blobs, backup.blobs)
    }

    func testReadOnlyNonHealthFutureDataAndSynchronizationScopeArePreserved() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        var unknown = revision(title: "")
        unknown.templateId = "future-private-non-health"
        unknown.schemaVersion = 99
        unknown.sections[0].fields[0].kind = "future-kind"
        unknown.sections[0].fields[0].value = .object(["number": .number("1e999")])
        let sync = revision(scope: .synchronizable)
        let backup = try VaultBackup(revisions: [unknown, sync], blobs: [])
        _ = try service(session).restore(backup)
        XCTAssertEqual(Set(store.scopes), [.deviceLocal, .synchronizable])
        let restored = try store.records.map(RevisionCodec.decode)
        XCTAssertEqual(restored.first { $0.revisionId == unknown.revisionId }, unknown)
        XCTAssertTrue(restored.first { $0.revisionId == unknown.revisionId }?.isReadOnly == true)
    }

    func testCloudAttachmentsAreBlockedBeforeAnyWriteButWholeRecordCanBeSkipped() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let metadata = attachment(Data([1]))
        var sync = revision(scope: .synchronizable)
        sync.attachments = [metadata.json]
        let backup = try VaultBackup(revisions: [sync], blobs: [
            .init(metadata: metadata.blob, bytes: Data([1]), scope: .synchronizable)
        ])
        var blobWrites = 0
        let service = service(session) { _ in blobWrites += 1 }
        XCTAssertThrowsError(try service.restore(backup)) {
            XCTAssertEqual($0 as? BackupError, .cloudAttachmentUnavailable)
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(blobWrites, 0)
        let skipped = try service.restore(backup, skippingRecords: [sync.recordId])
        XCTAssertEqual(skipped.revisions.skippedRevisionCount, 1)
        XCTAssertTrue(skipped.restoredBlobIds.isEmpty)
        XCTAssertEqual(blobWrites, 0)
    }

    func testChangedRevisionIdentityAndMalformedHistoryAreRejectedBeforeAttachmentWrites() async throws {
        let store = MemoryStore()
        var root = revision()
        let metadata = attachment(Data([1]))
        root.attachments = [metadata.json]
        store.records = [try RevisionCodec.encode(root)]
        let session = session(store)
        try await session.unlock()
        var altered = root
        altered.title = "Altered identity"
        let backup = try VaultBackup(revisions: [altered], blobs: [
            .init(metadata: metadata.blob, bytes: Data([1]), scope: .deviceLocal)
        ])
        var writes = 0
        XCTAssertThrowsError(try service(session) { _ in writes += 1 }.restore(backup))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertThrowsError(try VaultBackup(revisions: [branch(root, title: "Missing parent")], blobs: []))
        XCTAssertThrowsError(try VaultBackup(revisions: [root, root], blobs: []))
    }

    func testPayloadVersionHealthUnknownScopeAndInvalidDataFailBeforeRestoration() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        let valid = try RevisionCodec.encode(revision())
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for payload in [
            BackupPayload(formatVersion: 99, revisions: [valid], blobs: []),
            BackupPayload(formatVersion: 1, revisions: [Data("invalid".utf8)], blobs: [])
        ] {
            let cipher = try PasswordArchive.encrypt(encoder.encode(payload), passphrase: passphrase)
            XCTAssertThrowsError(try VaultBackup.decrypt(cipher, passphrase: passphrase))
        }
        var health = revision()
        health.templateId = "medical-record"
        let payload = BackupPayload(formatVersion: 1, revisions: [try RevisionCodec.encode(health)], blobs: [])
        XCTAssertThrowsError(try VaultBackup.decrypt(
            PasswordArchive.encrypt(encoder.encode(payload), passphrase: passphrase), passphrase: passphrase
        ))
        guard case .object(var object) = try LosslessJSON.decode(valid) else { return XCTFail("Object required") }
        object["storageScope"] = .string("future-scope")
        let unknown = try RevisionCodec.decode(LosslessJSON.encode(.object(object)))
        XCTAssertThrowsError(try VaultBackup(revisions: [unknown], blobs: []))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertThrowsError(try session.restoreRevisions([health], skippingRecords: [health.recordId]))
    }

    func testMissingDuplicateMismatchedAndUnreferencedAttachmentsCannotBecomeCompleteBackups() throws {
        let metadata = attachment(Data([1]))
        var root = revision()
        root.attachments = [metadata.json]
        XCTAssertThrowsError(try VaultBackup(revisions: [root], blobs: [])) {
            XCTAssertEqual($0 as? BackupError, .missingAttachment)
        }
        let blob = BackupBlob(metadata: metadata.blob, bytes: Data([1]), scope: .deviceLocal)
        for blobs in [[blob, blob], [BackupBlob(metadata: metadata.blob, bytes: Data(), scope: .deviceLocal)],
                      [BackupBlob(metadata: metadata.blob, bytes: Data([1]), scope: .synchronizable)]] {
            XCTAssertThrowsError(try VaultBackup(revisions: [root], blobs: blobs))
        }
        XCTAssertThrowsError(try VaultBackup(revisions: [revision()], blobs: [blob]))
        var other = metadata.json
        guard case .object(var object) = other else { return XCTFail("Object required") }
        object["key"] = .string(Data(repeating: 8, count: 32).base64EncodedString())
        other = .object(object)
        root.attachments.append(other)
        XCTAssertThrowsError(try VaultBackup(revisions: [root], blobs: [blob]))
        root.attachments = [.null]
        XCTAssertThrowsError(try VaultBackup(revisions: [root], blobs: []))
    }

    func testCountAndSizeCapsAreEnforcedOnEncodedPayloadsAndSnapshots() async throws {
        let root = revision()
        XCTAssertThrowsError(try VaultBackup(revisions: Array(repeating: root, count: 10_001), blobs: []))
        let metadata = attachment(Data())
        let blob = BackupBlob(metadata: metadata.blob, bytes: Data(), scope: .deviceLocal)
        XCTAssertThrowsError(try VaultBackup(revisions: [], blobs: Array(repeating: blob, count: 1_001)))
        var large = root
        large.sections[0].fields[0].value = .string(String(repeating: "x", count: VaultBackup.maximumRevisionBytes))
        XCTAssertThrowsError(try VaultBackup(revisions: [large], blobs: []))
        let payload = BackupPayload(
            formatVersion: 1, revisions: [Data(count: VaultBackup.maximumRevisionBytes + 1)], blobs: []
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        XCTAssertThrowsError(try VaultBackup.decrypt(PasswordArchive.encrypt(
            encoder.encode(payload), passphrase: passphrase
        ), passphrase: passphrase)) { XCTAssertEqual($0 as? BackupError, .oversized) }
        let store = MemoryStore()
        store.records = [try RevisionCodec.encode(large)]
        let session = session(store)
        try await session.unlock()
        XCTAssertThrowsError(try service(session).snapshot())
    }

    func testAggregateSizeIsCheckedBeforeFetchingTheNextAttachment() async throws {
        let store = MemoryStore()
        var root = revision()
        let bytes = Data(count: 17 * 1024 * 1024)
        var blobs: [BackupBlob] = []
        for _ in 0..<4 {
            let metadata = attachment(bytes)
            root.attachments.append(metadata.json)
            blobs.append(.init(metadata: metadata.blob, bytes: bytes, scope: .deviceLocal))
        }
        XCTAssertThrowsError(try VaultBackup(revisions: [root], blobs: blobs)) {
            XCTAssertEqual($0 as? BackupError, .oversized)
        }
        store.records = [try RevisionCodec.encode(root)]
        let session = session(store)
        try await session.unlock()
        var reads = 0
        let service = BackupService(session: session, readBlob: { _ in reads += 1; return bytes }, restoreBlob: { _ in })
        XCTAssertThrowsError(try service.snapshot()) { XCTAssertEqual($0 as? BackupError, .oversized) }
        XCTAssertEqual(reads, 3)
    }

    func testMissingOrCorruptReadAndWrongPassphraseNeverProduceBackupSuccess() async throws {
        let store = MemoryStore()
        var root = revision()
        let metadata = attachment(Data([1]))
        root.attachments = [metadata.json]
        store.records = [try RevisionCodec.encode(root)]
        let session = session(store)
        try await session.unlock()
        XCTAssertThrowsError(try service(session).snapshot())
        let inconsistent = BackupService(session: session, readBlob: { _ in Data() }, restoreBlob: { _ in })
        XCTAssertThrowsError(try inconsistent.snapshot()) {
            XCTAssertEqual($0 as? BackupError, .inconsistentAttachment)
        }
        store.readFails = true
        XCTAssertThrowsError(try service(session).snapshot())
        store.readFails = false
        let backup = try service(session, bytes: [metadata.blob.blobId: Data([1])]).snapshot()
        let data = try backup.encrypted(passphrase: passphrase)
        XCTAssertThrowsError(try VaultBackup.decrypt(data, passphrase: "Wrong synthetic passphrase 0123456789"))
        XCTAssertThrowsError(try VaultBackup.decrypt(data.dropLast(), passphrase: passphrase))
        XCTAssertEqual(store.records.count, 1)
    }

    func testLockingAndInvalidSkipRequestsCannotWriteOrRepopulateTheSession() async throws {
        let store = MemoryStore()
        let session = session(store)
        let root = revision()
        let backup = try VaultBackup(revisions: [root], blobs: [])
        let service = service(session)
        XCTAssertThrowsError(try service.snapshot())
        XCTAssertThrowsError(try service.preview(backup))
        XCTAssertThrowsError(try service.restore(backup))
        try await session.unlock()
        XCTAssertThrowsError(try service.restore(backup, skippingRecords: [UUID()]))
        store.afterAppend = { session.lock() }
        XCTAssertThrowsError(try service.restore(backup)) {
            XCTAssertEqual(($0 as? BackupRestoreFailure)?.revisionFailure?.result.addedRevisionIds, [root.revisionId])
        }
        XCTAssertEqual(session.state, .locked)
        XCTAssertTrue(session.heads.isEmpty)
        XCTAssertEqual(store.records.count, 1)
        store.afterAppend = nil
        try await session.unlock()
        XCTAssertEqual(try service.restore(backup).revisions.existingRevisionCount, 1)
    }

    func testLockDuringBlobRestorationStopsBeforeRevisionWrites() async throws {
        let store = MemoryStore()
        let session = session(store)
        try await session.unlock()
        var root = revision()
        let metadata = attachment(Data([1]))
        root.attachments = [metadata.json]
        let backup = try VaultBackup(revisions: [root], blobs: [
            .init(metadata: metadata.blob, bytes: Data([1]), scope: .deviceLocal)
        ])
        let service = service(session) { _ in session.lock() }
        XCTAssertThrowsError(try service.restore(backup)) {
            XCTAssertEqual(($0 as? BackupRestoreFailure)?.restoredBlobIds, [metadata.blob.blobId])
        }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(session.heads.isEmpty)
    }

    func testRestorationRejectsBlobIdentityCollisionsWithExistingHistoryBeforeFilesAreWritten() async throws {
        let store = MemoryStore()
        let oldMetadata = attachment(Data([1]))
        var existing = revision()
        existing.attachments = [oldMetadata.json]
        store.records = [try RevisionCodec.encode(existing)]
        let session = session(store)
        try await session.unlock()
        let changed = AttachmentMetadata(
            blob: EncryptedBlob(blobId: oldMetadata.blob.blobId, key: Data(repeating: 8, count: 32), plaintextSize: 1),
            filename: "Synthetic changed", mediaType: "application/octet-stream"
        )
        var incoming = revision()
        incoming.attachments = [changed.json]
        let backup = try VaultBackup(revisions: [incoming], blobs: [
            .init(metadata: changed.blob, bytes: Data([2]), scope: .deviceLocal)
        ])
        var writes = 0
        XCTAssertThrowsError(try service(session) { _ in writes += 1 }.restore(backup)) {
            XCTAssertEqual($0 as? BackupError, .inconsistentAttachment)
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.records.count, 1)
    }

    func testSkippingWholeHistoriesAndExistingSemanticIdentityDoNotRewriteStoredBytes() async throws {
        let store = MemoryStore()
        let root = revision()
        let child = branch(root, title: "Synthetic child")
        let other = revision()
        let plain = try RevisionCodec.encode(root)
        let object = try JSONSerialization.jsonObject(with: plain)
        let originalWireBytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        store.records = [originalWireBytes]
        let session = session(store)
        try await session.unlock()
        let backup = try VaultBackup(revisions: [child, root, other], blobs: [])
        let result = try service(session).restore(backup, skippingRecords: [root.recordId])
        XCTAssertEqual(result.revisions.addedRevisionIds, [other.revisionId])
        XCTAssertEqual(result.revisions.skippedRevisionCount, 2)
        XCTAssertEqual(store.records.first, originalWireBytes)
        XCTAssertEqual(store.records.count, 2)
        let retry = try service(session).restore(backup)
        XCTAssertEqual(retry.revisions.addedRevisionIds, [child.revisionId])
        XCTAssertEqual(retry.revisions.existingRevisionCount, 2)
        XCTAssertEqual(store.records.first, originalWireBytes)
    }

    func testUnknownEnvelopeKeysAndNonbinaryPayloadsAreNotSilentlyDiscarded() throws {
        let revisionData = try RevisionCodec.encode(revision())
        let envelope: [String: Any] = [
            "formatVersion": 1, "revisions": [revisionData], "blobs": [], "future": "Do not discard"
        ]
        let binary = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        XCTAssertThrowsError(try VaultBackup.decrypt(
            PasswordArchive.encrypt(binary, passphrase: passphrase), passphrase: passphrase
        )) { XCTAssertEqual($0 as? BackupError, .unsupportedFormat) }
        let xmlEncoder = PropertyListEncoder()
        xmlEncoder.outputFormat = .xml
        let xml = try xmlEncoder.encode(BackupPayload(formatVersion: 1, revisions: [], blobs: []))
        XCTAssertThrowsError(try VaultBackup.decrypt(
            PasswordArchive.encrypt(xml, passphrase: passphrase), passphrase: passphrase
        )) { XCTAssertEqual($0 as? BackupError, .unsupportedFormat) }
        let metadata = attachment(Data([1]))
        let encodedMetadata = try PropertyListEncoder().encode(metadata.blob)
        let metadataObject = try PropertyListSerialization.propertyList(from: encodedMetadata, format: nil)
        let unknownBlob: [String: Any] = [
            "metadata": metadataObject, "bytes": Data([1]), "scope": "device-local", "future": true
        ]
        let envelopeWithBlob: [String: Any] = ["formatVersion": 1, "revisions": [], "blobs": [unknownBlob]]
        let encoded = try PropertyListSerialization.data(fromPropertyList: envelopeWithBlob, format: .binary, options: 0)
        XCTAssertThrowsError(try VaultBackup.decrypt(
            PasswordArchive.encrypt(encoded, passphrase: passphrase), passphrase: passphrase
        )) { XCTAssertEqual($0 as? BackupError, .unsupportedFormat) }
    }

    func testEncodedCountsAndReferencedByteAmplificationAreBoundedDuringDecode() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let valid = try RevisionCodec.encode(revision())
        let largeData = Data(count: VaultBackup.maximumRevisionBytes)
        let metadata = attachment(Data())
        let blob = BackupPayload.Blob(metadata: metadata.blob, bytes: Data(), scope: .deviceLocal)
        for payload in [
            BackupPayload(formatVersion: 1, revisions: Array(repeating: valid, count: 10_001), blobs: []),
            BackupPayload(formatVersion: 1, revisions: [], blobs: Array(repeating: blob, count: 1_001)),
            BackupPayload(formatVersion: 1, revisions: Array(repeating: largeData, count: 65), blobs: [])
        ] {
            let encoded = try encoder.encode(payload)
            // Binary plists may reuse equal Data objects: caps also apply after decoding.
            let cipher = try PasswordArchive.encrypt(encoded, passphrase: passphrase)
            XCTAssertThrowsError(try VaultBackup.decrypt(cipher, passphrase: passphrase)) {
                XCTAssertEqual($0 as? BackupError, .oversized)
            }
        }
    }

    func testSnapshotStopsIfReadLocksSessionAndRejectsOversizedMetadataBeforeRead() async throws {
        let store = MemoryStore()
        var root = revision()
        let metadata = attachment(Data([1]))
        root.attachments = [metadata.json]
        store.records = [try RevisionCodec.encode(root)]
        let session = session(store)
        try await session.unlock()
        let locking = BackupService(session: session, readBlob: { _ in session.lock(); return Data([1]) }, restoreBlob: { _ in })
        XCTAssertThrowsError(try locking.snapshot()) { XCTAssertEqual($0 as? SessionError, .interrupted) }
        let oversized = AttachmentMetadata(
            blob: EncryptedBlob(
                blobId: UUID(), key: Data(count: 32), plaintextSize: AttachmentService.maximumBytes + 1
            ), filename: "Synthetic", mediaType: "application/octet-stream"
        )
        root.attachments = [oversized.json]
        store.records = [try RevisionCodec.encode(root)]
        try await session.unlock()
        var reads = 0
        let service = BackupService(session: session, readBlob: { _ in reads += 1; return Data() }, restoreBlob: { _ in })
        XCTAssertThrowsError(try service.snapshot()) { XCTAssertEqual($0 as? BackupError, .oversized) }
        XCTAssertEqual(reads, 0)
    }
}
