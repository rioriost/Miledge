import AppleArchive
import Foundation
import System

public enum PasswordArchiveError: Error, Equatable, Sendable {
    case invalidPassphrase
    case oversized
    case unsupportedArchive
    case authenticationFailed
    case invalidArchive
    case streamFailure
}

/// A narrow AEA password profile, not a general-purpose AEA importer.
public enum PasswordArchive {
    public static let maximumPlaintextBytes = 64 * 1024 * 1024
    public static let maximumEncryptedBytes = 72 * 1024 * 1024
    public static let minimumPassphraseBytes = 24
    public static let maximumPassphraseBytes = 128
    private static let blockSize = 64 * 1024
    // Native AEA1, profile 5, strength 0, and zero public authentication data.
    // Reject alternate KDF costs and prologue lengths before native initialization.
    internal static let prologue = Data([0x41, 0x45, 0x41, 0x31, 5, 0, 0, 0, 0, 0, 0, 0])
    private static var profile: ArchiveEncryptionContext.Profile {
        .hkdf_sha256_aesctr_hmac__scrypt__none
    }

    public static func generatePassphrase() throws -> String {
        let context = ArchiveEncryptionContext(profile: profile, compressionAlgorithm: .none)
        let passphrase = try context.generatePassword()
        try validatePassphrase(passphrase)
        return passphrase
    }

    public static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        try validatePassphrase(passphrase)
        guard plaintext.count <= maximumPlaintextBytes else { throw PasswordArchiveError.oversized }
        try Task.checkCancellation()
        let buffer = try ArchiveBuffer(limit: maximumEncryptedBytes)
        guard let output = ArchiveByteStream.customStream(instance: buffer) else {
            throw PasswordArchiveError.streamFailure
        }
        var outputOpen = true
        defer { if outputOpen { output.cancel() } }
        let context = ArchiveEncryptionContext(
            profile: profile, compressionAlgorithm: .none, compressionBlockSize: blockSize
        )
        try context.setPassword(passphrase)
        guard let stream = ArchiveByteStream.encryptionStream(
            writingTo: output, encryptionContext: context, threadCount: 1
        ) else { throw PasswordArchiveError.streamFailure }
        var streamOpen = true
        defer { if streamOpen { stream.cancel() } }
        try plaintext.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                try Task.checkCancellation()
                let end = min(position + blockSize, bytes.count)
                let count = try stream.write(from: UnsafeRawBufferPointer(rebasing: bytes[position..<end]))
                guard count > 0, count <= end - position else { throw PasswordArchiveError.streamFailure }
                position += count
            }
        }
        streamOpen = false
        try stream.close()
        outputOpen = false
        try output.close()
        guard buffer.data.starts(with: prologue) else { throw PasswordArchiveError.unsupportedArchive }
        return buffer.data
    }

    public static func decrypt(_ encrypted: Data, passphrase: String) throws -> Data {
        try validatePassphrase(passphrase)
        guard encrypted.count <= maximumEncryptedBytes else { throw PasswordArchiveError.oversized }
        guard encrypted.starts(with: prologue) else { throw PasswordArchiveError.unsupportedArchive }
        try Task.checkCancellation()
        let buffer = try ArchiveBuffer(encrypted, limit: maximumEncryptedBytes)
        guard let input = ArchiveByteStream.customStream(instance: buffer) else {
            throw PasswordArchiveError.streamFailure
        }
        var inputOpen = true
        defer { if inputOpen { input.cancel() } }
        guard let context = ArchiveEncryptionContext(from: input), context.profile == profile else {
            throw PasswordArchiveError.invalidArchive
        }
        try context.setPassword(passphrase)
        guard context.decryptAttributes() else { throw PasswordArchiveError.authenticationFailed }
        guard context.rawSize >= 0, context.rawSize <= maximumPlaintextBytes else {
            throw PasswordArchiveError.oversized
        }
        guard context.containerSize == encrypted.count else { throw PasswordArchiveError.invalidArchive }
        guard context.compressionAlgorithm == .none, context.compressionBlockSize == blockSize else {
            throw PasswordArchiveError.unsupportedArchive
        }
        guard let stream = ArchiveByteStream.randomAccessDecryptionStream(
            readingFrom: input, encryptionContext: context,
            allocationLimit: maximumPlaintextBytes, threadCount: 1
        ) else { throw PasswordArchiveError.invalidArchive }
        var streamOpen = true
        defer { if streamOpen { stream.cancel() } }
        var plaintext = Data()
        var chunk = [UInt8](repeating: 0, count: blockSize)
        while true {
            try Task.checkCancellation()
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count >= 0, count <= chunk.count else { throw PasswordArchiveError.streamFailure }
            if count == 0 { break }
            guard plaintext.count <= context.rawSize - count else { throw PasswordArchiveError.invalidArchive }
            plaintext.append(contentsOf: chunk.prefix(count))
        }
        guard plaintext.count == context.rawSize else { throw PasswordArchiveError.invalidArchive }
        streamOpen = false
        try stream.close()
        inputOpen = false
        try input.close()
        return plaintext
    }

    private static func validatePassphrase(_ passphrase: String) throws {
        guard passphrase.utf8.count >= minimumPassphraseBytes,
              passphrase.utf8.count <= maximumPassphraseBytes, !passphrase.contains("\0") else {
            throw PasswordArchiveError.invalidPassphrase
        }
    }
}

/// Memory-only I/O: decrypted backup contents never pass through temporary files.
internal final class ArchiveBuffer: ArchiveByteStreamProtocol {
    private(set) var data: Data
    private var position = 0
    private var closed = false
    private let limit: Int

    init(_ data: Data = Data(), limit: Int) throws {
        guard limit >= 0, data.count <= limit else { throw PasswordArchiveError.oversized }
        self.data = data
        self.limit = limit
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !closed else { throw PasswordArchiveError.streamFailure }
        guard position < data.count else { return 0 }
        let count = min(buffer.count, data.count - position)
        data.copyBytes(to: buffer, from: position..<(position + count))
        position += count
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        guard !closed else { throw PasswordArchiveError.streamFailure }
        guard buffer.count <= limit, position <= limit - buffer.count else {
            throw PasswordArchiveError.oversized
        }
        let end = position + buffer.count
        if end > data.count { data.append(Data(count: end - data.count)) }
        data.replaceSubrange(position..<end, with: buffer)
        position = end
        return buffer.count
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        let original = position
        defer { position = original }
        position = try checkedOffset(offset)
        return try read(into: buffer)
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        let original = position
        defer { position = original }
        position = try checkedOffset(offset)
        return try write(from: buffer)
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        guard !closed else { throw PasswordArchiveError.streamFailure }
        let base: Int64
        switch origin {
        case .start: base = 0
        case .current: base = Int64(position)
        case .end: base = Int64(data.count)
        default: throw PasswordArchiveError.streamFailure
        }
        let (next, overflow) = base.addingReportingOverflow(offset)
        guard !overflow else { throw PasswordArchiveError.invalidArchive }
        position = try checkedOffset(next)
        return next
    }

    func cancel() { closed = true }
    func close() throws { closed = true }

    private func checkedOffset(_ offset: Int64) throws -> Int {
        guard offset >= 0, offset <= limit else { throw PasswordArchiveError.invalidArchive }
        return Int(offset)
    }
}
