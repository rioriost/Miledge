import CryptoKit
import Darwin
import Foundation

/// Keep this metadata (especially the key) inside the protected revision payload.
/// Neither original filenames nor keys are part of the on-disk filename.
public struct EncryptedBlob: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1
    public static let encryptionAlgorithm = "AES-GCM"

    public let blobId: UUID
    public let key: Data
    public let plaintextSize: Int
    public var formatVersion: Int { Self.currentFormatVersion }
    public var algorithm: String { Self.encryptionAlgorithm }

    public init(blobId: UUID, key: Data, plaintextSize: Int) {
        self.blobId = blobId
        self.key = key
        self.plaintextSize = plaintextSize
    }

    private enum CodingKeys: String, CodingKey {
        case blobId, key, plaintextSize, formatVersion, algorithm
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .formatVersion) == Self.currentFormatVersion,
              try container.decode(String.self, forKey: .algorithm) == Self.encryptionAlgorithm else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion, in: container, debugDescription: "Unsupported encrypted blob format"
            )
        }
        blobId = try container.decode(UUID.self, forKey: .blobId)
        key = try container.decode(Data.self, forKey: .key)
        plaintextSize = try container.decode(Int.self, forKey: .plaintextSize)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blobId, forKey: .blobId)
        try container.encode(key, forKey: .key)
        try container.encode(plaintextSize, forKey: .plaintextSize)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(algorithm, forKey: .algorithm)
    }
}

public enum BlobFileOperation: String, Sendable {
    case openDirectory, createDirectory, excludeFromBackup, createFile
    case openFile, inspectFile, readFile, writeFile, synchronizeFile, removeFailedFile
}

public enum EncryptedBlobError: Error, Equatable, Sendable {
    case invalidDirectory
    case invalidMaximumBytes
    case invalidKey
    case invalidPlaintextSize
    case oversized
    case missing
    case corrupt
    case duplicateIntegrity
    case encryptionFailed
    case fileSystem(operation: BlobFileOperation, code: Int)
}

/// Local-only, ciphertext-only storage. It never copies or queues files for iCloud.
/// Instances are intentionally actor-confined, not Sendable. The directory must
/// be caller-owned; keep it stable for the lifetime of the store.
/// Format 1 is `MILD`, a version byte, 16 UUID bytes, and the AES-GCM combined
/// nonce/ciphertext/tag. The whole header is authenticated. This is not a
/// portable or passphrase-based backup format.
public final class EncryptedBlobStore {
    public let maximumBytes: Int
    private let files: any BlobFiles
    private static let magic = Data([0x4D, 0x49, 0x4C, 0x44, 0x01])
    internal static let overhead = 5 + 16 + 12 + 16

    /// Creates missing directories and resolves existing ancestor aliases using
    /// POSIX realpath. The selected directory itself and blob files cannot be symlinks.
    public init(directory: URL, maximumBytes: Int = 20 * 1024 * 1024) throws {
        try Self.validateMaximum(maximumBytes)
        self.maximumBytes = maximumBytes
        files = try LocalBlobFiles(directory: directory)
    }

    internal init(files: any BlobFiles, maximumBytes: Int) throws {
        try Self.validateMaximum(maximumBytes)
        self.maximumBytes = maximumBytes
        self.files = files
    }

    public func write(_ plaintext: Data) throws -> EncryptedBlob {
        guard plaintext.count <= maximumBytes else { throw EncryptedBlobError.oversized }
        let key = SymmetricKey(size: .bits256)
        let blob = EncryptedBlob(
            blobId: UUID(), key: key.withUnsafeBytes { Data($0) }, plaintextSize: plaintext.count
        )
        try persist(plaintext, as: blob)
        return blob
    }

    /// Restore the original identity and key without replacing existing ciphertext.
    /// Retrying an identical restored blob is a no-op; different contents are an error.
    public func restore(_ plaintext: Data, as blob: EncryptedBlob) throws {
        try validate(blob)
        guard plaintext.count == blob.plaintextSize else { throw EncryptedBlobError.invalidPlaintextSize }
        do {
            guard try read(blob) == plaintext else { throw EncryptedBlobError.duplicateIntegrity }
            return
        } catch EncryptedBlobError.missing {
            do {
                try persist(plaintext, as: blob)
            } catch EncryptedBlobError.fileSystem(operation: .createFile, code: Int(EEXIST)) {
                guard try read(blob) == plaintext else { throw EncryptedBlobError.duplicateIntegrity }
            }
        }
    }

    private func persist(_ plaintext: Data, as blob: EncryptedBlob) throws {
        let header = Self.header(for: blob.blobId)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: blob.key), authenticating: header)
        } catch {
            throw EncryptedBlobError.encryptionFailed
        }
        guard let combined = sealed.combined else { throw EncryptedBlobError.encryptionFailed }
        try files.write(header + combined, filename: Self.filename(for: blob.blobId))
    }

    public func read(_ blob: EncryptedBlob) throws -> Data {
        try validate(blob)
        let encoded = try files.read(
            filename: Self.filename(for: blob.blobId),
            maximumBytes: maximumBytes + Self.overhead,
            expectedBytes: blob.plaintextSize + Self.overhead
        )
        guard encoded.count <= maximumBytes + Self.overhead else { throw EncryptedBlobError.oversized }
        let header = Self.header(for: blob.blobId)
        guard encoded.count == blob.plaintextSize + Self.overhead,
              encoded.starts(with: header) else { throw EncryptedBlobError.corrupt }
        do {
            let sealed = try AES.GCM.SealedBox(combined: encoded.dropFirst(header.count))
            let plaintext = try AES.GCM.open(
                sealed, using: SymmetricKey(data: blob.key), authenticating: header
            )
            guard plaintext.count == blob.plaintextSize else { throw EncryptedBlobError.corrupt }
            return plaintext
        } catch {
            throw EncryptedBlobError.corrupt
        }
    }

    private func validate(_ blob: EncryptedBlob) throws {
        guard blob.key.count == 32 else { throw EncryptedBlobError.invalidKey }
        guard blob.plaintextSize >= 0 else { throw EncryptedBlobError.invalidPlaintextSize }
        guard blob.plaintextSize <= maximumBytes else { throw EncryptedBlobError.oversized }
    }

    private static func validateMaximum(_ value: Int) throws {
        guard value >= 0, value <= Int.max - overhead else {
            throw EncryptedBlobError.invalidMaximumBytes
        }
    }

    private static func header(for id: UUID) -> Data {
        var uuid = id.uuid
        return magic + withUnsafeBytes(of: &uuid) { Data($0) }
    }

    internal static func filename(for id: UUID) -> String {
        id.uuidString.lowercased() + ".miledgeblob"
    }
}

internal protocol BlobFiles {
    func write(_ data: Data, filename: String) throws
    func read(filename: String, maximumBytes: Int, expectedBytes: Int) throws -> Data
}

/// These hooks exercise short I/O, EINTR, and disk failures without filling a disk
/// or changing permissions on anything outside the synthetic test directory.
internal struct BlobSystemCalls {
    var openDirectory: (String, Int32) -> Int32 = { Darwin.open($0, $1) }
    var write: (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }
    var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = { Darwin.read($0, $1, $2) }
    var synchronize: (Int32) -> Int32 = { Darwin.fsync($0) }
    var inspect: (Int32, UnsafeMutablePointer<stat>) -> Int32 = { Darwin.fstat($0, $1) }
}

internal final class LocalBlobFiles: BlobFiles {
    private let directoryFD: Int32
    private let calls: BlobSystemCalls

    internal init(directory: URL, calls: BlobSystemCalls = BlobSystemCalls()) throws {
        guard directory.isFileURL, directory.host == nil || directory.host == "",
              !directory.path.contains("\0"), directory.query == nil,
              directory.fragment == nil else { throw EncryptedBlobError.invalidDirectory }
        self.calls = calls
        let location = try Self.canonicalDirectoryAnchor(directory.standardizedFileURL)
        let fd = try Self.openDirectory(
            location.url, missingComponents: location.missingComponents, calls: calls
        )
        do {
            var resourceURL = location.url
            for component in location.missingComponents {
                resourceURL.appendPathComponent(component, isDirectory: true)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resourceURL.setResourceValues(values)
        } catch {
            Darwin.close(fd)
            throw EncryptedBlobError.fileSystem(
                operation: .excludeFromBackup, code: (error as NSError).code
            )
        }
        directoryFD = fd
    }

    deinit {
        Darwin.close(directoryFD)
    }

    internal func write(_ data: Data, filename: String) throws {
        try Self.validateFilename(filename)
        let fd = Darwin.openat(
            directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard fd >= 0 else { throw Self.failure(.createFile) }
        defer { Darwin.close(fd) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = calls.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0, written <= bytes.count - offset else {
                        throw Self.failure(.writeFile, code: written == 0 ? EIO : errno)
                    }
                    offset += written
                }
            }
            guard calls.synchronize(fd) == 0 else { throw Self.failure(.synchronizeFile) }
            guard calls.synchronize(directoryFD) == 0 else { throw Self.failure(.synchronizeFile) }
        } catch {
            guard Darwin.unlinkat(directoryFD, filename, 0) == 0 else {
                throw Self.failure(.removeFailedFile)
            }
            throw error
        }
    }

    internal func read(filename: String, maximumBytes: Int, expectedBytes: Int) throws -> Data {
        try Self.validateFilename(filename)
        let fd = Darwin.openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw EncryptedBlobError.missing }
            throw Self.failure(.openFile)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard calls.inspect(fd, &info) == 0 else { throw Self.failure(.inspectFile) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw EncryptedBlobError.corrupt
        }
        guard info.st_size <= maximumBytes else { throw EncryptedBlobError.oversized }
        guard info.st_size == expectedBytes else { throw EncryptedBlobError.corrupt }
        // The bounded allocation follows fstat. Reading exactly that size plus an
        // EOF probe also detects concurrent truncation/growth without unbounded reads.
        var data = Data(count: expectedBytes)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = calls.read(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Self.failure(.readFile) }
                guard count > 0, count <= bytes.count - offset else { throw EncryptedBlobError.corrupt }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var count: Int
        repeat {
            count = calls.read(fd, &extra, 1)
        } while count < 0 && errno == EINTR
        guard count >= 0 else { throw Self.failure(.readFile) }
        guard count == 0 else { throw EncryptedBlobError.corrupt }
        return data
    }

    private static func validateFilename(_ filename: String) throws {
        guard filename.hasSuffix(".miledgeblob"),
              let id = UUID(uuidString: String(filename.dropLast(".miledgeblob".count))),
              filename == EncryptedBlobStore.filename(for: id) else {
            throw EncryptedBlobError.invalidDirectory
        }
    }

    private static func canonicalDirectoryAnchor(_ directory: URL) throws -> (url: URL, missingComponents: [String]) {
        var existing = directory
        var missingComponents: [String] = []
        var info = stat()
        while Darwin.lstat(existing.path, &info) != 0 {
            guard errno == ENOENT, existing.path != "/" else {
                throw failure(.openDirectory)
            }
            missingComponents.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        // Accept aliases in a caller-selected ancestor (including macOS /var),
        // but never a symlink replacing the selected directory itself.
        if missingComponents.isEmpty, (info.st_mode & S_IFMT) == S_IFLNK {
            throw failure(.openDirectory, code: ENOTDIR)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved: String = try buffer.withUnsafeMutableBufferPointer { bytes in
            guard let address = bytes.baseAddress,
                  Darwin.realpath(existing.path, address) != nil else {
                throw failure(.openDirectory)
            }
            guard let path = String(validatingCString: address) else {
                throw EncryptedBlobError.invalidDirectory
            }
            return path
        }
        return (URL(fileURLWithPath: resolved, isDirectory: true), missingComponents.reversed())
    }

    private static func openDirectory(
        _ anchor: URL, missingComponents: [String], calls: BlobSystemCalls
    ) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        // Sandbox access to the anchor does not grant read access to its parents.
        // Reject replacement symlinks throughout the canonical path in the kernel.
        var fd = calls.openDirectory(anchor.path, flags | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw failure(.openDirectory) }
        do {
            for component in missingComponents {
                var next = Darwin.openat(fd, component, flags | O_NOFOLLOW)
                if next < 0, errno == ENOENT {
                    guard Darwin.mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                        throw failure(.createDirectory)
                    }
                    next = Darwin.openat(fd, component, flags | O_NOFOLLOW)
                }
                guard next >= 0 else { throw failure(.openDirectory) }
                Darwin.close(fd)
                fd = next
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func failure(_ operation: BlobFileOperation, code: Int32 = errno) -> EncryptedBlobError {
        .fileSystem(operation: operation, code: Int(code))
    }
}
