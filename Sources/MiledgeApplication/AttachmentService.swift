import Foundation
import MiledgeDomain
import MiledgeStorage

public enum AttachmentError: Error, Equatable {
    case invalidMetadata
    case invalidFile
    case tooLarge
    case cloudFilesUnavailable
}

public struct AttachmentMetadata: Equatable, Sendable {
    public let blob: EncryptedBlob
    public let filename: String
    public let mediaType: String

    public init(blob: EncryptedBlob, filename: String, mediaType: String) {
        self.blob = blob
        self.filename = filename
        self.mediaType = mediaType
    }

    public var json: JSONValue {
        .object([
            "blobId": .string(blob.blobId.uuidString),
            "key": .string(blob.key.base64EncodedString()),
            "plaintextSize": .string(String(blob.plaintextSize)),
            "originalFilename": .string(filename),
            "mediaType": .string(mediaType),
            "formatVersion": .string("1"),
            "algorithm": .string("AES-GCM")
        ])
    }

    public init(json: JSONValue) throws {
        guard case .object(let values) = json,
              case .string(let id) = values["blobId"],
              let blobId = UUID(uuidString: id),
              case .string(let encodedKey) = values["key"],
              let key = Data(base64Encoded: encodedKey), key.count == 32,
              case .string(let size) = values["plaintextSize"],
              let plaintextSize = Int(size), plaintextSize >= 0,
              case .string(let filename) = values["originalFilename"], !filename.isEmpty,
              case .string(let mediaType) = values["mediaType"], !mediaType.isEmpty,
              case .string("1") = values["formatVersion"],
              case .string("AES-GCM") = values["algorithm"] else {
            throw AttachmentError.invalidMetadata
        }
        self.init(
            blob: EncryptedBlob(blobId: blobId, key: key, plaintextSize: plaintextSize),
            filename: filename,
            mediaType: mediaType
        )
    }
}

public final class AttachmentService {
    public static let maximumBytes = 20 * 1024 * 1024
    private let store: EncryptedBlobStore
    private var previews: [UUID: TemporaryAttachmentFile] = [:]
    private var exports: [UUID: AttachmentDataLease] = [:]

    public init(store: EncryptedBlobStore) {
        self.store = store
    }

    public func importFile(
        _ url: URL, mediaType: String,
        scope: StorageScope
    ) throws -> AttachmentMetadata {
        guard scope == .deviceLocal else { throw AttachmentError.cloudFilesUnavailable }
        guard url.isFileURL, !mediaType.isEmpty else { throw AttachmentError.invalidFile }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true else { throw AttachmentError.invalidFile }
        guard let size = properties.fileSize, size <= Self.maximumBytes else {
            throw AttachmentError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        var plaintext = Data()
        do {
            while plaintext.count <= Self.maximumBytes {
                guard let chunk = try handle.read(upToCount: Self.maximumBytes + 1 - plaintext.count),
                      !chunk.isEmpty else { break }
                plaintext.append(chunk)
            }
            try handle.close()
        } catch {
            try handle.close()
            throw error
        }
        guard plaintext.count <= Self.maximumBytes else { throw AttachmentError.tooLarge }
        let blob = try store.write(plaintext)
        return AttachmentMetadata(blob: blob, filename: url.lastPathComponent, mediaType: mediaType)
    }

    public func read(_ metadata: AttachmentMetadata) throws -> Data {
        try read(metadata.blob)
    }

    public func read(_ blob: EncryptedBlob) throws -> Data {
        try store.read(blob)
    }

    /// An explicit preview gets one private, backup-excluded directory. The original blob is immutable.
    public func preparePreview(_ metadata: AttachmentMetadata, temporaryRoot: URL? = nil) throws -> TemporaryAttachmentFile {
        let preview = try TemporaryAttachmentFile(
            data: read(metadata), filename: metadata.filename,
            root: temporaryRoot ?? FileManager.default.temporaryDirectory
        )
        previews[preview.id] = preview
        return preview
    }

    public func endPreview(_ preview: TemporaryAttachmentFile) {
        preview.invalidate()
        previews[preview.id] = nil
    }

    public func prepareExport(_ metadata: AttachmentMetadata) throws -> AttachmentDataLease {
        let lease = AttachmentDataLease(data: try read(metadata))
        exports[lease.id] = lease
        return lease
    }

    public func endExport(_ lease: AttachmentDataLease) {
        lease.invalidate()
        exports[lease.id] = nil
    }

    /// Called synchronously on lock as well as on presentation cleanup.
    public func clearTemporaryFiles() {
        for preview in previews.values { preview.invalidate() }
        previews.removeAll()
        for lease in exports.values { lease.invalidate() }
        exports.removeAll()
    }

    public func restore(_ plaintext: Data, as blob: EncryptedBlob, scope: StorageScope) throws {
        guard scope == .deviceLocal else { throw AttachmentError.cloudFilesUnavailable }
        try store.restore(plaintext, as: blob)
    }
}

/// Allows an explicit pending export to be revoked synchronously when the ledger locks.
public final class AttachmentDataLease {
    public let id = UUID()
    private var data: Data?
    private let lock = NSLock()
    public init(data: Data) { self.data = data }
    public func snapshot() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data else { throw CancellationError() }
        return data
    }
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}

public final class TemporaryAttachmentFile {
    public let id = UUID()
    public let url: URL
    private let directory: URL

    fileprivate init(data: Data, filename: String, root: URL) throws {
        directory = root.appendingPathComponent("MiledgePreview-\(UUID().uuidString)", isDirectory: true)
        // Attachment metadata is untrusted. It must never become a path outside this lease.
        let leaf = URL(fileURLWithPath: filename).lastPathComponent
        let safeName = leaf.isEmpty || leaf == "." || leaf == ".." ? "Attachment" : leaf
        url = directory.appendingPathComponent(safeName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
            )
            #endif
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func invalidate() { try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
