import Foundation
import MiledgeDomain
import MiledgeStorage

public enum BackupError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidContents
    case oversized
    case missingAttachment
    case inconsistentAttachment
    case cloudAttachmentUnavailable
}

public struct BackupBlob: Equatable, Sendable {
    public let metadata: EncryptedBlob
    public let bytes: Data
    public let scope: StorageScope

    public init(metadata: EncryptedBlob, bytes: Data, scope: StorageScope) {
        self.metadata = metadata
        self.bytes = bytes
        self.scope = scope
    }
}

public struct VaultBackup: Sendable {
    public static let maximumRevisions = 10_000
    public static let maximumBlobs = 1_000
    public static let maximumRevisionBytes = 1024 * 1024
    public let revisions: [VaultRevision]
    public let blobs: [BackupBlob]

    public init(revisions: [VaultRevision], blobs: [BackupBlob]) throws {
        self.revisions = revisions
        self.blobs = blobs
        try validate()
    }

    public func encrypted(passphrase: String) throws -> Data {
        try validate()
        let payload = BackupPayload(
            formatVersion: 1, revisions: try revisions.map(RevisionCodec.encode),
            blobs: blobs.map { .init(metadata: $0.metadata, bytes: $0.bytes, scope: $0.scope) }
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(payload)
        return try PasswordArchive.encrypt(plaintext, passphrase: passphrase)
    }

    public static func decrypt(_ data: Data, passphrase: String) throws -> VaultBackup {
        let plaintext = try PasswordArchive.decrypt(data, passphrase: passphrase)
        guard plaintext.starts(with: Data("bplist00".utf8)) else { throw BackupError.unsupportedFormat }
        let payload = try PropertyListDecoder().decode(BackupPayload.self, from: plaintext)
        guard payload.formatVersion == 1 else { throw BackupError.unsupportedFormat }
        return try VaultBackup(
            revisions: payload.revisions.map(RevisionCodec.decode),
            blobs: payload.blobs.map { BackupBlob(metadata: $0.metadata, bytes: $0.bytes, scope: $0.scope) }
        )
    }

    internal static func references(in revisions: [VaultRevision]) throws -> [UUID: (EncryptedBlob, StorageScope)] {
        var references: [UUID: (EncryptedBlob, StorageScope)] = [:]
        for revision in revisions {
            for attachment in revision.attachments {
                let metadata = try AttachmentMetadata(json: attachment)
                if let previous = references[metadata.blob.blobId] {
                    guard previous.0 == metadata.blob, previous.1 == revision.storageScope else {
                        throw BackupError.inconsistentAttachment
                    }
                } else { references[metadata.blob.blobId] = (metadata.blob, revision.storageScope) }
            }
        }
        return references
    }

    private func validate() throws {
        guard blobs.count <= Self.maximumBlobs else {
            throw BackupError.oversized
        }
        var bytes = try Self.validateRevisions(revisions)
        let references = try Self.references(in: revisions)
        var blobIds = Set<UUID>()
        for blob in blobs {
            guard blobIds.insert(blob.metadata.blobId).inserted,
                  let reference = references[blob.metadata.blobId],
                  reference.0 == blob.metadata, reference.1 == blob.scope else {
                throw BackupError.inconsistentAttachment
            }
            guard blob.metadata.key.count == 32, blob.metadata.plaintextSize == blob.bytes.count else {
                throw BackupError.inconsistentAttachment
            }
            guard blob.bytes.count <= AttachmentService.maximumBytes,
                  blob.bytes.count <= PasswordArchive.maximumPlaintextBytes - bytes else {
                throw BackupError.oversized
            }
            bytes += blob.bytes.count
        }
        guard blobIds == Set(references.keys) else { throw BackupError.missingAttachment }
    }

    internal static func validateRevisions(_ revisions: [VaultRevision]) throws -> Int {
        guard revisions.count <= maximumRevisions else { throw BackupError.oversized }
        _ = try RevisionGraph.heads(in: revisions)
        var revisionIds = Set<UUID>()
        var bytes = 0
        for revision in revisions {
            try VaultPolicy.validateForRestore(revision)
            guard revisionIds.insert(revision.revisionId).inserted else { throw BackupError.invalidContents }
            let size = try RevisionCodec.encode(revision).count
            guard size <= maximumRevisionBytes,
                  size <= PasswordArchive.maximumPlaintextBytes - bytes else { throw BackupError.oversized }
            bytes += size
        }
        return bytes
    }
}

internal struct BackupPayload: Codable {
    let formatVersion: Int
    let revisions: [Data]
    let blobs: [Blob]

    init(formatVersion: Int, revisions: [Data], blobs: [Blob]) {
        self.formatVersion = formatVersion
        self.revisions = revisions
        self.blobs = blobs
    }

    init(from decoder: any Decoder) throws {
        try Self.validateKeys(decoder, expected: ["formatVersion", "revisions", "blobs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == 1 else { throw BackupError.unsupportedFormat }
        var revisionValues = try values.nestedUnkeyedContainer(forKey: .revisions)
        guard let revisionCount = revisionValues.count, revisionCount <= VaultBackup.maximumRevisions else {
            throw BackupError.oversized
        }
        var decodedRevisions: [Data] = []
        var totalBytes = 0
        while !revisionValues.isAtEnd {
            let data = try revisionValues.decode(Data.self)
            guard data.count <= VaultBackup.maximumRevisionBytes,
                  data.count <= PasswordArchive.maximumPlaintextBytes - totalBytes else {
                throw BackupError.oversized
            }
            totalBytes += data.count
            decodedRevisions.append(data)
        }
        var blobValues = try values.nestedUnkeyedContainer(forKey: .blobs)
        guard let blobCount = blobValues.count, blobCount <= VaultBackup.maximumBlobs else {
            throw BackupError.oversized
        }
        var decodedBlobs: [Blob] = []
        while !blobValues.isAtEnd {
            let blob = try blobValues.decode(Blob.self)
            guard blob.bytes.count <= PasswordArchive.maximumPlaintextBytes - totalBytes else {
                throw BackupError.oversized
            }
            totalBytes += blob.bytes.count
            decodedBlobs.append(blob)
        }
        revisions = decodedRevisions
        blobs = decodedBlobs
    }

    struct Blob: Codable {
        let metadata: EncryptedBlob
        let bytes: Data
        let scope: StorageScope

        init(metadata: EncryptedBlob, bytes: Data, scope: StorageScope) {
            self.metadata = metadata
            self.bytes = bytes
            self.scope = scope
        }

        init(from decoder: any Decoder) throws {
            try BackupPayload.validateKeys(decoder, expected: ["metadata", "bytes", "scope"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try BackupPayload.validateKeys(
                values.superDecoder(forKey: .metadata),
                expected: ["blobId", "key", "plaintextSize", "formatVersion", "algorithm"]
            )
            metadata = try values.decode(EncryptedBlob.self, forKey: .metadata)
            guard metadata.key.count == 32, metadata.plaintextSize >= 0 else {
                throw BackupError.inconsistentAttachment
            }
            guard metadata.plaintextSize <= AttachmentService.maximumBytes else { throw BackupError.oversized }
            bytes = try values.decode(Data.self, forKey: .bytes)
            guard bytes.count == metadata.plaintextSize else { throw BackupError.inconsistentAttachment }
            scope = try values.decode(StorageScope.self, forKey: .scope)
        }
    }

    private static func validateKeys(_ decoder: any Decoder, expected: Set<String>) throws {
        let keys = try decoder.container(keyedBy: BackupCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == expected else { throw BackupError.unsupportedFormat }
    }
}

private struct BackupCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct BackupRestoreFailure: Error {
    public let restoredBlobIds: [UUID]
    public let revisionFailure: RevisionRestoreFailure?
    public let cause: any Error
}

public struct BackupRestoreResult: Equatable, Sendable {
    public let restoredBlobIds: [UUID]
    public let revisions: RevisionRestoreResult
}

@MainActor
public final class BackupService {
    private let session: VaultSession
    private let readBlob: @MainActor (EncryptedBlob) throws -> Data
    private let restoreBlob: @MainActor (BackupBlob) throws -> Void
    private let cooperate: @MainActor () async -> Void

    public convenience init(session: VaultSession, attachments: AttachmentService) {
        self.init(
            session: session, readBlob: { try attachments.read($0) },
            restoreBlob: { try attachments.restore($0.bytes, as: $0.metadata, scope: $0.scope) }
        )
    }

    internal init(
        session: VaultSession, readBlob: @escaping @MainActor (EncryptedBlob) throws -> Data,
        restoreBlob: @escaping @MainActor (BackupBlob) throws -> Void,
        cooperate: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        self.session = session
        self.readBlob = readBlob
        self.restoreBlob = restoreBlob
        self.cooperate = cooperate
    }

    public func snapshot() throws -> VaultBackup {
        try Task.checkCancellation()
        let revisions = try session.revisionsForBackup()
        var totalBytes = try VaultBackup.validateRevisions(revisions)
        let references = try VaultBackup.references(in: revisions)
        guard references.count <= VaultBackup.maximumBlobs else { throw BackupError.oversized }
        var blobs: [BackupBlob] = []
        for id in references.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard session.state == .unlocked else { throw SessionError.locked }
            guard let (metadata, scope) = references[id] else { throw BackupError.invalidContents }
            guard metadata.plaintextSize <= AttachmentService.maximumBytes,
                  metadata.plaintextSize <= PasswordArchive.maximumPlaintextBytes - totalBytes else {
                throw BackupError.oversized
            }
            let bytes = try readBlob(metadata)
            guard session.state == .unlocked else { throw SessionError.interrupted }
            guard bytes.count == metadata.plaintextSize else { throw BackupError.inconsistentAttachment }
            totalBytes += bytes.count
            blobs.append(BackupBlob(metadata: metadata, bytes: bytes, scope: scope))
        }
        return try VaultBackup(revisions: revisions, blobs: blobs)
    }

    public func preview(_ backup: VaultBackup) throws -> RestorationPreview {
        try Task.checkCancellation()
        let preview = try session.previewRestoration(backup.revisions)
        _ = try VaultBackup.references(in: session.revisionsForBackup() + backup.revisions)
        return preview
    }

    public func restore(
        _ backup: VaultBackup, skippingRecords: Set<UUID> = []
    ) throws -> BackupRestoreResult {
        try Task.checkCancellation()
        _ = try preview(backup)
        let needed = try blobsForRestore(backup, skippingRecords: skippingRecords)
        var restored: [UUID] = []
        do {
            for blob in needed {
                try Task.checkCancellation()
                guard session.state == .unlocked else { throw SessionError.locked }
                try restoreBlob(blob)
                restored.append(blob.metadata.blobId)
            }
            let result = try session.restoreRevisions(backup.revisions, skippingRecords: skippingRecords)
            return BackupRestoreResult(restoredBlobIds: restored, revisions: result)
        } catch let error as RevisionRestoreFailure {
            throw BackupRestoreFailure(restoredBlobIds: restored, revisionFailure: error, cause: error.cause)
        } catch {
            throw BackupRestoreFailure(restoredBlobIds: restored, revisionFailure: nil, cause: error)
        }
    }

    public func restoreCooperatively(
        _ backup: VaultBackup, skippingRecords: Set<UUID> = []
    ) async throws -> BackupRestoreResult {
        let operation = try session.prepareCooperativeRestore(backup.revisions, skippingRecords: skippingRecords)
        defer { session.finishCooperativeRestore(operation) }
        _ = try VaultBackup.references(in: operation.plan.current + backup.revisions)
        let needed = try blobsForRestore(backup, skippingRecords: skippingRecords)
        let validateAttachments: @MainActor ([VaultRevision]) throws -> Void = {
            _ = try VaultBackup.references(in: $0)
        }
        var restored: [UUID] = []
        do {
            for blob in needed {
                await cooperate()
                _ = try session.cooperativeRestoreSnapshot(operation, validating: validateAttachments)
                try restoreBlob(blob)
                restored.append(blob.metadata.blobId)
                try session.checkCooperativeRestore(operation)
            }
            let result = try await session.restoreRevisionsCooperatively(
                operation, cooperate: cooperate, validating: validateAttachments
            )
            return BackupRestoreResult(restoredBlobIds: restored, revisions: result)
        } catch let error as RevisionRestoreFailure {
            throw BackupRestoreFailure(restoredBlobIds: restored, revisionFailure: error, cause: error.cause)
        } catch {
            throw BackupRestoreFailure(restoredBlobIds: restored, revisionFailure: nil, cause: error)
        }
    }

    private func blobsForRestore(_ backup: VaultBackup, skippingRecords: Set<UUID>) throws -> [BackupBlob] {
        guard skippingRecords.isSubset(of: Set(backup.revisions.map(\.recordId))) else {
            throw SessionError.missingRecord
        }
        let selected = backup.revisions.filter { !skippingRecords.contains($0.recordId) }
        let references = try VaultBackup.references(in: selected)
        let needed = backup.blobs.filter { references[$0.metadata.blobId] != nil }
        guard needed.allSatisfy({ $0.scope == .deviceLocal }) else {
            throw BackupError.cloudAttachmentUnavailable
        }
        return needed
    }
}
