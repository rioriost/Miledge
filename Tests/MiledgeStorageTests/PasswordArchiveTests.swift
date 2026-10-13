import AppleArchive
import Foundation
import System
import XCTest
@testable import MiledgeStorage

final class PasswordArchiveTests: XCTestCase {
    private let passphrase = "Synthetic backup passphrase 0123456789"

    func testAuthenticatedExactBytesFreshRandomnessAndEmptyBackup() throws {
        let bytes = Data("  Synthetic\r\nالعربية e\u{301}\n".utf8) + Data([0, 255])
        for plaintext in [Data(), bytes, Data(repeating: 7, count: 130_001)] {
            let first = try PasswordArchive.encrypt(plaintext, passphrase: passphrase)
            let second = try PasswordArchive.encrypt(plaintext, passphrase: passphrase)
            XCTAssertTrue(first.starts(with: PasswordArchive.prologue))
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(try PasswordArchive.decrypt(first, passphrase: passphrase), plaintext)
            if !plaintext.isEmpty { XCTAssertNil(first.range(of: plaintext)) }
        }
        let generated = try PasswordArchive.generatePassphrase()
        XCTAssertGreaterThanOrEqual(generated.utf8.count, PasswordArchive.minimumPassphraseBytes)
        XCTAssertLessThanOrEqual(generated.utf8.count, PasswordArchive.maximumPassphraseBytes)
        XCTAssertNotEqual(generated, try PasswordArchive.generatePassphrase())
    }

    func testPassphrasePolicyPreservesWhitespaceAndUnicodeByteSpelling() throws {
        for password in ["", String(repeating: "a", count: 23), String(repeating: "a", count: 129),
                         String(repeating: "a", count: 24) + "\0"] {
            assertError(.invalidPassphrase) { try PasswordArchive.encrypt(Data(), passphrase: password) }
            assertError(.invalidPassphrase) { try PasswordArchive.decrypt(Data(), passphrase: password) }
        }
        for password in [String(repeating: "a", count: 24), String(repeating: "a", count: 128),
                         "  Synthetic whitespace password  ", String(repeating: "語", count: 8)] {
            let data = try PasswordArchive.encrypt(Data([255]), passphrase: password)
            XCTAssertEqual(try PasswordArchive.decrypt(data, passphrase: password), Data([255]))
        }
        let composed = String(repeating: "Synthetic-", count: 3) + "é"
        let decomposed = String(repeating: "Synthetic-", count: 3) + "e\u{301}"
        let data = try PasswordArchive.encrypt(Data([1]), passphrase: composed)
        assertError(.authenticationFailed) { try PasswordArchive.decrypt(data, passphrase: decomposed) }
        let whitespace = try PasswordArchive.encrypt(Data(), passphrase: "  \(passphrase)  ")
        assertError(.authenticationFailed) { try PasswordArchive.decrypt(whitespace, passphrase: passphrase) }
    }

    func testRejectsAlternateCostAndPrologueLengthBeforeNativePasswordDerivation() throws {
        let data = try PasswordArchive.encrypt(Data([1]), passphrase: passphrase)
        for index in 0..<12 {
            var altered = data
            altered[index] ^= 1
            assertError(.unsupportedArchive) { try PasswordArchive.decrypt(altered, passphrase: passphrase) }
        }
        for invalid in [Data(), Data("AEA1".utf8), PasswordArchive.prologue] {
            XCTAssertThrowsError(try PasswordArchive.decrypt(invalid, passphrase: passphrase))
        }
        assertError(.authenticationFailed) {
            try PasswordArchive.decrypt(data, passphrase: "Wrong synthetic passphrase 0123456789")
        }
    }

    func testRejectsTamperingTruncationAndExtraBytesWithoutReturningPartialPlaintext() throws {
        let data = try PasswordArchive.encrypt(Data(repeating: 3, count: 70_000), passphrase: passphrase)
        for index in [12, 40, 80, 140, 160, data.count / 2, data.count - 1] {
            var altered = data
            altered[index] ^= 1
            XCTAssertThrowsError(try PasswordArchive.decrypt(altered, passphrase: passphrase))
        }
        for count in [1, 16, 156, data.count - 1] {
            XCTAssertThrowsError(try PasswordArchive.decrypt(Data(data.prefix(count)), passphrase: passphrase))
        }
        XCTAssertThrowsError(try PasswordArchive.decrypt(data + Data([0]), passphrase: passphrase))
    }

    func testNativeAlternateCompressionAndBlockSizeAreNotAcceptedAsProductBackups() throws {
        for (algorithm, block): (ArchiveCompression, Int) in [(.zlib, 65_536), (.none, 1_048_576)] {
            let data = try nativeArchive(Data([0, 255]), compression: algorithm, block: block)
            assertError(.unsupportedArchive) { try PasswordArchive.decrypt(data, passphrase: passphrase) }
        }
    }

    func testExactMaximumAndUntrustedAdvertisedSizes() throws {
        let bytes = Data(repeating: 3, count: PasswordArchive.maximumPlaintextBytes)
        let data = try PasswordArchive.encrypt(bytes, passphrase: passphrase)
        XCTAssertEqual(try PasswordArchive.decrypt(data, passphrase: passphrase), bytes)
        assertError(.oversized) {
            try PasswordArchive.encrypt(bytes + Data([0]), passphrase: passphrase)
        }
        assertError(.oversized) {
            try PasswordArchive.decrypt(Data(count: PasswordArchive.maximumEncryptedBytes + 1), passphrase: passphrase)
        }
        let advertised = try nativeArchive(bytes + Data([0]))
        assertError(.oversized) { try PasswordArchive.decrypt(advertised, passphrase: passphrase) }
    }

    func testCancellationIsExplicitBeforeWork() async throws {
        let password = passphrase
        let task = Task {
            try await Task.sleep(for: .seconds(60))
            return try PasswordArchive.encrypt(Data(), passphrase: password)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation required") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PasswordArchive.encrypt(Data(), passphrase: password)
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation required") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cipher = try PasswordArchive.encrypt(Data(), passphrase: password)
        let cancelledDecode = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PasswordArchive.decrypt(cipher, passphrase: password)
        }
        do { _ = try await cancelledDecode.value; XCTFail("Cancellation required") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testBoundedMemoryAdapterOffsetsShortReadsCloseAndOverflow() throws {
        XCTAssertThrowsError(try ArchiveBuffer(Data([1]), limit: 0))
        let buffer = try ArchiveBuffer(limit: 4)
        XCTAssertEqual(try Data([1, 2]).withUnsafeBytes { try buffer.write(from: $0) }, 2)
        XCTAssertEqual(try buffer.seek(toOffset: 0, relativeTo: .start), 0)
        XCTAssertEqual(try buffer.seek(toOffset: 1, relativeTo: .current), 1)
        XCTAssertEqual(try buffer.seek(toOffset: 0, relativeTo: .end), 2)
        XCTAssertThrowsError(try buffer.seek(toOffset: Int64.max, relativeTo: .current))
        XCTAssertThrowsError(try buffer.seek(toOffset: -3, relativeTo: .end))
        XCTAssertThrowsError(try buffer.seek(toOffset: 5, relativeTo: .start))
        XCTAssertThrowsError(try buffer.seek(toOffset: 0, relativeTo: .init(rawValue: -1)))
        XCTAssertEqual(try Data([3]).withUnsafeBytes { try buffer.write(from: $0, atOffset: 1) }, 1)
        XCTAssertEqual(buffer.data, Data([1, 3]))
        var bytes = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(try bytes.withUnsafeMutableBytes { try buffer.read(into: $0, atOffset: 0) }, 2)
        XCTAssertEqual(Array(bytes.prefix(2)), [1, 3])
        XCTAssertEqual(try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }, 0)
        XCTAssertThrowsError(try Data([0]).withUnsafeBytes { try buffer.write(from: $0, atOffset: -1) })
        XCTAssertThrowsError(try Data(count: 5).withUnsafeBytes { try buffer.write(from: $0) })
        try buffer.close()
        XCTAssertThrowsError(try Data().withUnsafeBytes { try buffer.write(from: $0) })
        XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) })
        XCTAssertThrowsError(try buffer.seek(toOffset: 0, relativeTo: .start))
        buffer.cancel()
    }

    private func nativeArchive(
        _ bytes: Data, compression: ArchiveCompression = .none, block: Int = 65_536
    ) throws -> Data {
        let buffer = try ArchiveBuffer(limit: PasswordArchive.maximumEncryptedBytes)
        let output = try XCTUnwrap(ArchiveByteStream.customStream(instance: buffer))
        let context = ArchiveEncryptionContext(
            profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
            compressionAlgorithm: compression, compressionBlockSize: block
        )
        try context.setPassword(passphrase)
        let stream = try XCTUnwrap(ArchiveByteStream.encryptionStream(
            writingTo: output, encryptionContext: context, threadCount: 1
        ))
        XCTAssertEqual(try bytes.withUnsafeBytes { try stream.write(from: $0) }, bytes.count)
        try stream.close()
        try output.close()
        return buffer.data
    }

    private func assertError<T>(
        _ expected: PasswordArchiveError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? PasswordArchiveError, expected, file: file, line: line)
        }
    }
}
