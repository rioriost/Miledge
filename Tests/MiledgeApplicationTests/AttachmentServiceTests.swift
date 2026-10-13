import Foundation
import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import XCTest

final class AttachmentServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        #if SWIFT_PACKAGE && os(macOS)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/application-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #else
        let root = FileManager.default.temporaryDirectory
        #endif
        directory = root
            .appendingPathComponent("MiledgeAttachmentTests-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func service() throws -> AttachmentService {
        AttachmentService(store: try EncryptedBlobStore(
            directory: directory.appendingPathComponent("ciphertext", isDirectory: true)
        ))
    }

    func testActualFileBytesAndPrivateMetadataRoundTrip() throws {
        let source = directory.appendingPathComponent("Synthetic warranty.pdf")
        let contents = Data([0, 1, 3, 0, 255]) + Data("synthetic only".utf8)
        try contents.write(to: source)
        let service = try service()
        let metadata = try service.importFile(source, mediaType: "application/pdf", scope: .deviceLocal)
        XCTAssertEqual(metadata.filename, source.lastPathComponent)
        XCTAssertEqual(try service.read(metadata), contents)
        let decoded = try AttachmentMetadata(json: metadata.json)
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(try service.read(decoded), contents)
    }

    func testRejectsMissingNonFileDirectoryAndCloudScope() throws {
        let service = try service()
        XCTAssertThrowsError(try service.importFile(
            URL(string: "https://example.invalid/a")!, mediaType: "text/plain", scope: .deviceLocal
        ))
        XCTAssertThrowsError(try service.importFile(directory, mediaType: "text/plain", scope: .deviceLocal))
        XCTAssertThrowsError(try service.importFile(
            directory.appendingPathComponent("missing"), mediaType: "text/plain", scope: .deviceLocal
        ))
        XCTAssertThrowsError(try service.importFile(directory, mediaType: "text/plain", scope: .synchronizable)) {
            XCTAssertEqual($0 as? AttachmentError, .cloudFilesUnavailable)
        }
    }

    func testEmptyFileIsStillAnActualFile() throws {
        let source = directory.appendingPathComponent("empty.txt")
        try Data().write(to: source)
        let service = try service()
        let metadata = try service.importFile(source, mediaType: "text/plain", scope: .deviceLocal)
        XCTAssertEqual(metadata.blob.plaintextSize, 0)
        XCTAssertEqual(try service.read(metadata), Data())
    }

    func testRestoreRetainsOriginalBlobAndRejectsCloudScopeWithoutWriting() throws {
        let service = try service()
        let blob = EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: 2)
        XCTAssertThrowsError(try service.restore(Data([0, 255]), as: blob, scope: .synchronizable)) {
            XCTAssertEqual($0 as? AttachmentError, .cloudFilesUnavailable)
        }
        XCTAssertThrowsError(try service.read(AttachmentMetadata(
            blob: blob, filename: "Synthetic", mediaType: "application/octet-stream"
        )))
        try service.restore(Data([0, 255]), as: blob, scope: .deviceLocal)
        XCTAssertEqual(try service.read(AttachmentMetadata(
            blob: blob, filename: "Synthetic", mediaType: "application/octet-stream"
        )), Data([0, 255]))
    }

    @MainActor
    func testDocumentRevisionRetainsFileBytesAndKeyThroughSessionReload() async throws {
        let source = directory.appendingPathComponent("Synthetic contract.txt")
        let bytes = Data("Synthetic contract\nSecond line".utf8)
        try bytes.write(to: source)
        let service = try service()
        let metadata = try service.importFile(source, mediaType: "text/plain", scope: .deviceLocal)
        var stored: [Data] = []
        let session = VaultSession(
            authenticate: {}, load: { stored },
            append: { data, _, _ in stored.append(data) }
        )
        try await session.unlock()
        let template = try XCTUnwrap(TemplateCatalog.template(id: "document"))
        var draft = try session.newDraft(template: template)
        draft.title = "Synthetic contract"
        draft.attachments = [metadata.json]
        try session.save(draft)
        session.lock()
        try await session.unlock()
        let restored = try XCTUnwrap(session.heads.first?.attachments.first)
        let restoredMetadata = try AttachmentMetadata(json: restored)
        XCTAssertEqual(restoredMetadata.filename, source.lastPathComponent)
        XCTAssertEqual(try service.read(restoredMetadata), bytes)
    }

    func testOversizedFileRejectedBeforeImport() throws {
        let source = directory.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AttachmentService.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try service().importFile(
            source, mediaType: "application/octet-stream", scope: .deviceLocal
        )) {
            XCTAssertEqual($0 as? AttachmentError, .tooLarge)
        }
    }

    func testInvalidMetadataFailsExplicitly() throws {
        for json: JSONValue in [.null, .object([:]), .object(["blobId": .string("not-a-uuid")])] {
            XCTAssertThrowsError(try AttachmentMetadata(json: json))
        }
        let valid = AttachmentMetadata(
            blob: EncryptedBlob(blobId: UUID(), key: Data(repeating: 1, count: 32), plaintextSize: 1),
            filename: "synthetic", mediaType: "application/octet-stream"
        )
        guard case .object(let values) = valid.json else { return XCTFail("Object required") }
        for key in values.keys {
            var missing = values
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AttachmentMetadata(json: .object(missing)))
        }
        for (key, replacement): (String, JSONValue) in [
            ("key", .string("bad-key")), ("plaintextSize", .string("-1")),
            ("originalFilename", .string("")), ("mediaType", .string("")),
            ("formatVersion", .string("2")), ("algorithm", .string("unsupported"))
        ] {
            var broken = values
            broken[key] = replacement
            XCTAssertThrowsError(try AttachmentMetadata(json: .object(broken)))
        }
    }
    func testPrivatePreviewCleanupAndTraversalSafeFilename() throws {
        let service = try service()
        let bytes = Data([0, 255, 128, 42])
        let blob = EncryptedBlob(blobId: UUID(), key: Data(repeating: 7, count: 32), plaintextSize: bytes.count)
        try service.restore(bytes, as: blob, scope: .deviceLocal)
        let metadata = AttachmentMetadata(blob: blob, filename: "../../Synthetic.pdf", mediaType: "application/pdf")
        let preview = try service.preparePreview(metadata, temporaryRoot: directory)
        XCTAssertEqual(preview.url.lastPathComponent, "Synthetic.pdf")
        XCTAssertEqual(
            preview.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path,
            directory.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try Data(contentsOf: preview.url), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: preview.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try preview.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        service.clearTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.url.path))
        XCTAssertEqual(try service.read(metadata), bytes)
        service.endPreview(preview) // repeated cancel/lock cleanup is safe
    }

    func testLockRevokesPendingExportWithoutDeletingEncryptedHistory() throws {
        let service = try service()
        let source = directory.appendingPathComponent("Synthetic export.bin")
        let bytes = Data([0, 255, 1, 128])
        try bytes.write(to: source)
        let metadata = try service.importFile(source, mediaType: "application/octet-stream", scope: .deviceLocal)
        let lease = try service.prepareExport(metadata)
        XCTAssertEqual(try lease.snapshot(), bytes)
        service.clearTemporaryFiles()
        XCTAssertThrowsError(try lease.snapshot()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try service.read(metadata), bytes)
        service.endExport(lease)
    }

    func testPreviewFailureDoesNotLeaveAPlaintextDirectory() throws {
        let service = try service()
        let missing = AttachmentMetadata(
            blob: EncryptedBlob(blobId: UUID(), key: Data(repeating: 1, count: 32), plaintextSize: 1),
            filename: "Synthetic.pdf", mediaType: "application/pdf"
        )
        XCTAssertThrowsError(try service.preparePreview(missing, temporaryRoot: directory))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("MiledgePreview-") })
    }

    @MainActor
    func testRemovingReferenceRetainsHistoricalRevisionAndOriginalBlob() async throws {
        let source = directory.appendingPathComponent("Synthetic image.png")
        let bytes = Data([137, 80, 78, 71, 0, 255])
        try bytes.write(to: source)
        let service = try service()
        let metadata = try service.importFile(source, mediaType: "image/png", scope: .deviceLocal)
        var stored: [Data] = []
        let session = VaultSession(authenticate: {}, load: { stored }, append: { data, _, _ in stored.append(data) })
        try await session.unlock()
        var draft = try session.newDraft(template: XCTUnwrap(TemplateCatalog.template(id: "document")))
        draft.title = "Synthetic image"
        draft.attachments = [metadata.json]
        try session.save(draft)
        let original = try XCTUnwrap(session.heads.first)
        var edited = try session.editDraft(original)
        edited.attachments.removeAll()
        try session.save(edited)
        XCTAssertTrue(try XCTUnwrap(session.heads.first).attachments.isEmpty)
        let history = try stored.map(RevisionCodec.decode)
        XCTAssertTrue(history.contains { $0.attachments == [metadata.json] })
        XCTAssertEqual(try service.read(metadata), bytes)
    }

}
