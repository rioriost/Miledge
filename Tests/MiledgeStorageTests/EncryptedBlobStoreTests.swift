import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MiledgeStorage

final class EncryptedBlobStoreTests: XCTestCase {
    func testRestorePreservesIdentityKeyAndBytesAcrossStoresAndRetries() throws {
        try withDirectory { directory in
            let source = try EncryptedBlobStore(directory: directory.appendingPathComponent("source"))
            let target = try EncryptedBlobStore(directory: directory.appendingPathComponent("target"))
            for bytes in [Data(), Data([0, 255]) + Data("Synthetic\r\nالعربية e\u{301}".utf8)] {
                let blob = try source.write(bytes)
                try target.restore(bytes, as: blob)
                XCTAssertEqual(try target.read(blob), bytes)
                let restoredURL = blobURL(blob, directory.appendingPathComponent("target"))
                let ciphertext = try Data(contentsOf: restoredURL)
                try target.restore(bytes, as: blob)
                XCTAssertEqual(try Data(contentsOf: restoredURL), ciphertext)
                XCTAssertNotEqual(ciphertext, try Data(contentsOf: blobURL(
                    blob, directory.appendingPathComponent("source")
                )))
            }
        }
    }

    func testRestoreRejectsDifferentExistingBytesCorruptionAndInvalidMetadata() throws {
        let files = MemoryBlobFiles()
        let store = try EncryptedBlobStore(files: files, maximumBytes: 3)
        let blob = try store.write(Data([1, 2, 3]))
        assertError(.duplicateIntegrity) { try store.restore(Data([3, 2, 1]), as: blob) }
        assertError(.invalidPlaintextSize) { try store.restore(Data([1]), as: blob) }
        assertError(.invalidKey) {
            try store.restore(Data(), as: EncryptedBlob(blobId: UUID(), key: Data(), plaintextSize: 0))
        }
        assertError(.oversized) {
            try store.restore(Data(count: 4), as: EncryptedBlob(blobId: UUID(), key: blob.key, plaintextSize: 4))
        }
        files.values[EncryptedBlobStore.filename(for: blob.blobId)] = Data([0])
        assertError(.corrupt) { try store.restore(Data([1, 2, 3]), as: blob) }
        files.error = .fileSystem(operation: .openFile, code: Int(EACCES))
        assertError(.fileSystem(operation: .openFile, code: Int(EACCES))) {
            try store.restore(Data([1, 2, 3]), as: blob)
        }
    }

    func testRestoreVerifiesAConcurrentExclusiveCreationInsteadOfOverwritingIt() throws {
        let files = RacingRestoreFiles()
        let store = try EncryptedBlobStore(files: files, maximumBytes: 3)
        let blob = EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: 3)
        try store.restore(Data([1, 2, 3]), as: blob)
        XCTAssertEqual(try store.read(blob), Data([1, 2, 3]))
        XCTAssertEqual(files.writes, 1)
        files.values.removeAll()
        files.failure = .fileSystem(operation: .writeFile, code: Int(ENOSPC))
        assertError(.fileSystem(operation: .writeFile, code: Int(ENOSPC))) {
            try store.restore(Data([1, 2, 3]), as: blob)
        }
    }

    func testRealCryptoRoundTripsEmptyTextAndBinaryAndMetadata() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory)
            XCTAssertEqual(store.maximumBytes, 20 * 1024 * 1024)
            for plaintext in [Data(), Data("Synthetic document 日本語".utf8), Data((0...255).map(UInt8.init))] {
                let blob = try store.write(plaintext)
                XCTAssertEqual(blob.key.count, 32)
                XCTAssertEqual(blob.plaintextSize, plaintext.count)
                XCTAssertEqual(blob.algorithm, "AES-GCM")
                XCTAssertEqual(blob.formatVersion, 1)
                XCTAssertEqual(try store.read(blob), plaintext)
                let restored = try JSONDecoder().decode(EncryptedBlob.self, from: JSONEncoder().encode(blob))
                XCTAssertEqual(restored, blob)
                XCTAssertEqual(try store.read(restored), plaintext)
                let file = blobURL(blob, directory)
                XCTAssertEqual(try Data(contentsOf: file).count, plaintext.count + EncryptedBlobStore.overhead)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testFreshKeysIDsAndNoncesAndImmutableWrites() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory)
            let plaintext = Data(repeating: 0xA5, count: 4096)
            let first = try store.write(plaintext)
            let second = try store.write(plaintext)
            XCTAssertNotEqual(first.blobId, second.blobId)
            XCTAssertNotEqual(first.key, second.key)
            let bytes1 = try Data(contentsOf: blobURL(first, directory))
            let bytes2 = try Data(contentsOf: blobURL(second, directory))
            XCTAssertNotEqual(bytes1, bytes2)
            XCTAssertNotEqual(bytes1[21..<33], bytes2[21..<33])
            XCTAssertFalse(bytes1.range(of: plaintext) != nil)
            XCTAssertEqual(try store.read(first), plaintext)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
            XCTAssertEqual(try Data(contentsOf: blobURL(first, directory)), bytes1)
        }
    }

    func testMetadataEncodingIncludesFormatAndRejectsUnsupportedFormats() throws {
        let blob = EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: 3)
        let encoded = try JSONEncoder().encode(blob)
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(dictionary["formatVersion"] as? Int, 1)
        XCTAssertEqual(dictionary["algorithm"] as? String, "AES-GCM")
        for (key, value) in [("formatVersion", 2 as Any), ("algorithm", "unsupported" as Any)] {
            var changed = dictionary
            changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(
                EncryptedBlob.self, from: JSONSerialization.data(withJSONObject: changed)
            ))
        }
        var missing = dictionary
        missing.removeValue(forKey: "formatVersion")
        XCTAssertThrowsError(try JSONDecoder().decode(
            EncryptedBlob.self, from: JSONSerialization.data(withJSONObject: missing)
        ))
    }

    func testWrongKeysAndTamperingEveryEnvelopeRegion() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory)
            let blob = try store.write(Data("synthetic secret".utf8))
            let file = blobURL(blob, directory)
            let original = try Data(contentsOf: file)
            let wrong = EncryptedBlob(
                blobId: blob.blobId,
                key: Data(repeating: 0xFF, count: 32),
                plaintextSize: blob.plaintextSize
            )
            assertError(.corrupt) { try store.read(wrong) }
            for index in [0, 4, 5, 20, 21, 32, 33, original.count - 1] {
                var changed = original
                changed[index] ^= 1
                try changed.write(to: file)
                assertError(.corrupt) { try store.read(blob) }
            }
            try original.write(to: file)
            XCTAssertEqual(try store.read(blob), Data("synthetic secret".utf8))
        }
    }

    func testBlobIdentityIsAuthenticatedEvenIfHeaderIsRewritten() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory)
            let first = try store.write(Data("synthetic".utf8))
            let altered = EncryptedBlob(blobId: UUID(), key: first.key, plaintextSize: first.plaintextSize)
            let source = try Data(contentsOf: blobURL(first, directory))
            try source.write(to: blobURL(altered, directory))
            assertError(.corrupt) { try store.read(altered) }
            var rewritten = source
            var uuid = altered.blobId.uuid
            rewritten.replaceSubrange(5..<21, with: withUnsafeBytes(of: &uuid) { Data($0) })
            try rewritten.write(to: blobURL(altered, directory))
            assertError(.corrupt) { try store.read(altered) }
        }
    }

    func testLimitsAndInvalidMetadataBeforeFileAccess() throws {
        let files = MemoryBlobFiles()
        for limit in [-1, Int.max] {
            assertError(.invalidMaximumBytes) { try EncryptedBlobStore(files: files, maximumBytes: limit) }
        }
        let store = try EncryptedBlobStore(files: files, maximumBytes: 3)
        assertError(.oversized) { try store.write(Data(repeating: 1, count: 4)) }
        for length in [0, 1, 31, 33, 64] {
            let blob = EncryptedBlob(blobId: UUID(), key: Data(count: length), plaintextSize: 0)
            assertError(.invalidKey) { try store.read(blob) }
        }
        assertError(.invalidPlaintextSize) {
            try store.read(EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: -1))
        }
        for size in [4, Int.max] {
            assertError(.oversized) {
                try store.read(EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: size))
            }
        }
        XCTAssertEqual(files.reads, 0)
        XCTAssertTrue(files.values.isEmpty)
        let blob = try store.write(Data([1, 2, 3]))
        XCTAssertEqual(try store.read(blob), Data([1, 2, 3]))
        XCTAssertEqual(files.lastMaximum, 3 + EncryptedBlobStore.overhead)
        XCTAssertEqual(files.lastExpected, 3 + EncryptedBlobStore.overhead)
    }

    func testZeroLimitStillSupportsEmptyBlobsAndRealLimitBoundary() throws {
        try withDirectory { directory in
            let emptyStore = try EncryptedBlobStore(directory: directory, maximumBytes: 0)
            let blob = try emptyStore.write(Data())
            XCTAssertEqual(try emptyStore.read(blob), Data())
            assertError(.oversized) { try emptyStore.write(Data([1])) }
            let bounded = try EncryptedBlobStore(directory: directory, maximumBytes: 1024)
            let full = try bounded.write(Data(count: 1024))
            XCTAssertEqual(try bounded.read(full).count, 1024)
            assertError(.oversized) { try bounded.write(Data(count: 1025)) }
        }
    }

    func testConstructorCreatesExplicitAbsentDirectoryLeafAndIntermediateParents() throws {
        try withDirectory { directory in
            let absent = directory.appendingPathComponent("Miledge/DeviceLocalBlobs/ciphertext", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
            let store = try EncryptedBlobStore(directory: absent)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: absent.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let blob = try store.write(Data("synthetic attachment".utf8))
            XCTAssertEqual(try store.read(blob), Data("synthetic attachment".utf8))
        }
    }

    func testMissingDirectoryChildBehindCallerSelectedAncestorAlias() throws {
        try withDirectory { directory in
            let physical = directory.appendingPathComponent("physical", isDirectory: true)
            let alias = directory.appendingPathComponent("ancestor-alias", isDirectory: true)
            try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
            let parentName = "MiledgeAttachmentTests-\(UUID())"
            let parent = alias.appendingPathComponent(parentName, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let selected = parent.appendingPathComponent("Miledge/DeviceLocalBlobs/ciphertext", isDirectory: true)
            let store = try EncryptedBlobStore(directory: selected)
            let blob = try store.write(Data("synthetic attachment".utf8))
            XCTAssertEqual(try store.read(blob), Data("synthetic attachment".utf8))
            let destination = physical.appendingPathComponent(parentName, isDirectory: true)
                .appendingPathComponent("Miledge/DeviceLocalBlobs/ciphertext", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL(blob, destination).path))
            XCTAssertEqual(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testCorruptMetadataAndTruncationGrowthAndOversizeOnDisk() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory, maximumBytes: 64)
            let blob = try store.write(Data(repeating: 0x42, count: 10))
            let file = blobURL(blob, directory)
            let original = try Data(contentsOf: file)
            for size in [0, 9, 11, 64] {
                assertError(.corrupt) {
                    try store.read(EncryptedBlob(blobId: blob.blobId, key: blob.key, plaintextSize: size))
                }
            }
            for count in [0, 4, 21, 48, original.count - 1, original.count + 1] {
                try Data(repeating: 0, count: count).write(to: file)
                assertError(.corrupt) { try store.read(blob) }
            }
            try Data(count: 65 + EncryptedBlobStore.overhead).write(to: file)
            assertError(.oversized) { try store.read(blob) }
            // A sparse file is rejected by stat before any ciphertext allocation.
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 1 << 30)
            try handle.close()
            assertError(.oversized) { try store.read(blob) }
        }
    }

    func testMissingAndNonRegularFilesAndNoSymlinkTraversal() throws {
        try withDirectory { directory in
            let store = try EncryptedBlobStore(directory: directory)
            let metadata = EncryptedBlob(blobId: UUID(), key: Data(count: 32), plaintextSize: 0)
            assertError(.missing) { try store.read(metadata) }
            let path = blobURL(metadata, directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            assertError(.corrupt) { try store.read(metadata) }
            try FileManager.default.removeItem(at: path)
            let outside = directory.appendingPathComponent("unrelated-synthetic-data")
            let sentinel = Data(repeating: 0xCC, count: EncryptedBlobStore.overhead)
            try sentinel.write(to: outside)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
            assertFileError(.openFile) { try store.read(metadata) }
            XCTAssertEqual(try Data(contentsOf: outside), sentinel)
            try FileManager.default.removeItem(at: path)
            XCTAssertEqual(Darwin.mkfifo(path.path, 0o600), 0)
            assertError(.corrupt) { try store.read(metadata) }
        }
    }

    func testDirectoryValidationAndContainmentAndExclusiveFileCreation() throws {
        assertError(.invalidDirectory) { try EncryptedBlobStore(directory: URL(string: "https://example.invalid/blobs")!) }
        assertError(.invalidDirectory) { try EncryptedBlobStore(directory: URL(string: "file://remotehost/blobs")!) }
        assertError(.invalidDirectory) { try EncryptedBlobStore(directory: URL(string: "file:///blobs?query")!) }
        try withDirectory { directory in
            let file = directory.appendingPathComponent("not-directory")
            try Data().write(to: file)
            assertFileError(.openDirectory) { try EncryptedBlobStore(directory: file) }
            let alias = directory.appendingPathComponent("symlink-directory")
            let real = directory.appendingPathComponent("real-directory")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            assertFileError(.openDirectory) { try EncryptedBlobStore(directory: alias) }
            let throughAlias = try EncryptedBlobStore(directory: alias.appendingPathComponent("child", isDirectory: true))
            let aliasedBlob = try throughAlias.write(Data([3]))
            XCTAssertEqual(try throughAlias.read(aliasedBlob), Data([3]))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: blobURL(aliasedBlob, real.appendingPathComponent("child", isDirectory: true)).path
            ))
            let nested = directory.appendingPathComponent("new/nested")
            let files = try LocalBlobFiles(directory: nested)
            let filename = EncryptedBlobStore.filename(for: UUID())
            try files.write(Data([1]), filename: filename)
            assertFileError(.createFile) { try files.write(Data([2]), filename: filename) }
            XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent(filename)), Data([1]))
            for name in ["../escape.miledgeblob", "/escape", "not-a-uuid.miledgeblob", UUID().uuidString + ".miledgeblob"] {
                assertError(.invalidDirectory) { try files.write(Data([1]), filename: name) }
                assertError(.invalidDirectory) { try files.read(filename: name, maximumBytes: 1, expectedBytes: 1) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.miledgeblob").path))
        }
    }

    func testPinnedDirectoryDoesNotFollowLaterPathReplacement() throws {
        try withDirectory { directory in
            let selected = directory.appendingPathComponent("selected")
            let store = try EncryptedBlobStore(directory: selected)
            let moved = directory.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: selected, to: moved)
            let unrelated = directory.appendingPathComponent("unrelated")
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: unrelated)
            let blob = try store.write(Data([1, 2]))
            XCTAssertEqual(try store.read(blob), Data([1, 2]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL(blob, moved).path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unrelated.path), [])
        }
    }

    func testOpeningUsesPermittedExistingAnchorWithoutReadingParentDirectories() throws {
        try withDirectory { directory in
            let anchor = directory.appendingPathComponent("allowed", isDirectory: true)
            try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
            let canonicalAnchor = anchor.resolvingSymlinksInPath().path
            var openedPaths: [String] = []
            var calls = BlobSystemCalls()
            calls.openDirectory = { path, flags in
                openedPaths.append(path)
                guard path == canonicalAnchor else { errno = EPERM; return -1 }
                XCTAssertNotEqual(flags & O_NOFOLLOW_ANY, 0)
                return Darwin.open(path, flags)
            }
            let selected = anchor.appendingPathComponent("Miledge/DeviceLocalBlobs", isDirectory: true)
            let files = try LocalBlobFiles(directory: selected, calls: calls)
            let filename = EncryptedBlobStore.filename(for: UUID())
            try files.write(Data([1, 2, 3]), filename: filename)
            XCTAssertEqual(try files.read(filename: filename, maximumBytes: 3, expectedBytes: 3), Data([1, 2, 3]))
            XCTAssertEqual(openedPaths, [canonicalAnchor])
            let attributes = try FileManager.default.attributesOfItem(atPath: selected.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try selected.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

            calls.openDirectory = { _, _ in errno = EPERM; return -1 }
            assertError(.fileSystem(operation: .openDirectory, code: Int(EPERM))) {
                try LocalBlobFiles(directory: selected, calls: calls)
            }
        }
    }

    func testOpeningRejectsAnAncestorReplacedByASymlinkAfterCanonicalization() throws {
        try withDirectory { directory in
            let ancestor = directory.appendingPathComponent("ancestor", isDirectory: true)
            let selected = ancestor.appendingPathComponent("selected", isDirectory: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            let unrelated = directory.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(
                at: unrelated.appendingPathComponent("selected"), withIntermediateDirectories: true
            )
            var calls = BlobSystemCalls()
            calls.openDirectory = { path, flags in
                do {
                    try FileManager.default.moveItem(
                        at: ancestor, to: directory.appendingPathComponent("moved", isDirectory: true)
                    )
                    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: unrelated)
                } catch {
                    XCTFail("Unable to prepare the synthetic ancestor replacement")
                    errno = EIO
                    return -1
                }
                return Darwin.open(path, flags)
            }
            assertFileError(.openDirectory) { try LocalBlobFiles(directory: selected, calls: calls) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(
                atPath: unrelated.appendingPathComponent("selected").path
            ), [])
        }
    }

    func testCoreRejectsUntrustedFileAdapterOutputsAndPropagatesFileFailures() throws {
        let files = MemoryBlobFiles()
        let store = try EncryptedBlobStore(files: files, maximumBytes: 4)
        let blob = try store.write(Data([1]))
        let filename = EncryptedBlobStore.filename(for: blob.blobId)
        let original = try XCTUnwrap(files.values[filename])
        files.values[filename] = Data(count: 5 + EncryptedBlobStore.overhead)
        assertError(.oversized) { try store.read(blob) }
        files.values[filename] = Data()
        assertError(.corrupt) { try store.read(blob) }
        files.values[filename] = original
        files.error = .fileSystem(operation: .readFile, code: Int(EIO))
        assertError(.fileSystem(operation: .readFile, code: Int(EIO))) { try store.read(blob) }
        files.error = .fileSystem(operation: .writeFile, code: Int(ENOSPC))
        assertError(.fileSystem(operation: .writeFile, code: Int(ENOSPC))) { try store.write(Data()) }
    }

    func testShortAndInterruptedWritesAndReadsAndEOFProbe() throws {
        try withDirectory { directory in
            var calls = BlobSystemCalls()
            var writeCalls = 0
            calls.write = { fd, bytes, count in
                writeCalls += 1
                if writeCalls == 1 { errno = EINTR; return -1 }
                return Darwin.write(fd, bytes, min(count, 3))
            }
            var readCalls = 0
            calls.read = { fd, bytes, count in
                readCalls += 1
                if readCalls == 1 || count == 1 && readCalls == 4 { errno = EINTR; return -1 }
                return Darwin.read(fd, bytes, min(count, 2))
            }
            let files = try LocalBlobFiles(directory: directory, calls: calls)
            let filename = EncryptedBlobStore.filename(for: UUID())
            try files.write(Data([1, 2, 3, 4]), filename: filename)
            XCTAssertEqual(try files.read(filename: filename, maximumBytes: 4, expectedBytes: 4), Data([1, 2, 3, 4]))
            XCTAssertGreaterThan(writeCalls, 2)
            XCTAssertGreaterThan(readCalls, 3)
        }
    }

    func testWriteAndSyncFailureRemoveOnlyTheUncommittedSyntheticFile() throws {
        try withDirectory { directory in
            let sentinel = directory.appendingPathComponent("keep-synthetic")
            try Data([9]).write(to: sentinel)
            for returnValue in [-1, 0] {
                var calls = BlobSystemCalls()
                calls.write = { _, _, _ in errno = ENOSPC; return returnValue }
                let files = try LocalBlobFiles(directory: directory, calls: calls)
                let filename = EncryptedBlobStore.filename(for: UUID())
                assertError(.fileSystem(operation: .writeFile, code: Int(returnValue == 0 ? EIO : ENOSPC))) {
                    try files.write(Data([1]), filename: filename)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
            }
            var calls = BlobSystemCalls()
            calls.synchronize = { _ in errno = EIO; return -1 }
            let files = try LocalBlobFiles(directory: directory, calls: calls)
            let filename = EncryptedBlobStore.filename(for: UUID())
            assertError(.fileSystem(operation: .synchronizeFile, code: Int(EIO))) {
                try files.write(Data([1]), filename: filename)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))

            var cleanupFailure = BlobSystemCalls()
            let vanishedName = EncryptedBlobStore.filename(for: UUID())
            cleanupFailure.write = { _, _, _ in
                XCTAssertEqual(Darwin.unlink(directory.appendingPathComponent(vanishedName).path), 0)
                errno = EIO
                return -1
            }
            let cleanupFiles = try LocalBlobFiles(directory: directory, calls: cleanupFailure)
            assertError(.fileSystem(operation: .removeFailedFile, code: Int(ENOENT))) {
                try cleanupFiles.write(Data([1]), filename: vanishedName)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([9]))
        }
    }

    func testReadAndStatFailuresAndConcurrentTruncationOrGrowth() throws {
        try withDirectory { directory in
            let filename = EncryptedBlobStore.filename(for: UUID())
            let path = directory.appendingPathComponent(filename)
            try Data([1, 2]).write(to: path)
            var statCalls = BlobSystemCalls()
            statCalls.inspect = { _, _ in errno = EIO; return -1 }
            let statFiles = try LocalBlobFiles(directory: directory, calls: statCalls)
            assertError(.fileSystem(operation: .inspectFile, code: Int(EIO))) {
                try statFiles.read(filename: filename, maximumBytes: 2, expectedBytes: 2)
            }
            for failureAtEOF in [false, true] {
                var calls = BlobSystemCalls()
                calls.read = { fd, bytes, count in
                    if !failureAtEOF || count == 1 { errno = EIO; return -1 }
                    return Darwin.read(fd, bytes, count)
                }
                let files = try LocalBlobFiles(directory: directory, calls: calls)
                assertError(.fileSystem(operation: .readFile, code: Int(EIO))) {
                    try files.read(filename: filename, maximumBytes: 2, expectedBytes: 2)
                }
            }
            var truncation = BlobSystemCalls()
            truncation.read = { _, _, _ in 0 }
            let truncatedFiles = try LocalBlobFiles(directory: directory, calls: truncation)
            assertError(.corrupt) { try truncatedFiles.read(filename: filename, maximumBytes: 2, expectedBytes: 2) }
            var growth = BlobSystemCalls()
            growth.read = { fd, bytes, count in count == 1 ? 1 : Darwin.read(fd, bytes, count) }
            let growingFiles = try LocalBlobFiles(directory: directory, calls: growth)
            assertError(.corrupt) { try growingFiles.read(filename: filename, maximumBytes: 2, expectedBytes: 2) }

            var invalidStat = BlobSystemCalls()
            invalidStat.inspect = { fd, info in
                let result = Darwin.fstat(fd, info)
                info.pointee.st_size = -1
                return result
            }
            let invalidFiles = try LocalBlobFiles(directory: directory, calls: invalidStat)
            assertError(.corrupt) { try invalidFiles.read(filename: filename, maximumBytes: 2, expectedBytes: 2) }
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        #if SWIFT_PACKAGE && os(macOS)
        let parent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/storage-agent/test-data", isDirectory: true)
        #else
        let parent = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MiledgeStorageTestFixtures", isDirectory: true)
        #endif
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Unable to clean the uniquely generated synthetic test directory") }
        }
        try body(directory)
    }

    private func blobURL(_ blob: EncryptedBlob, _ directory: URL) -> URL {
        directory.appendingPathComponent(EncryptedBlobStore.filename(for: blob.blobId))
    }

    private func assertError<T>(
        _ expected: EncryptedBlobError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? EncryptedBlobError, expected, file: file, line: line)
        }
    }

    private func assertFileError<T>(
        _ operation: BlobFileOperation, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case .fileSystem(let actual, _) = $0 as? EncryptedBlobError else {
                return XCTFail("Expected an explicit file-system error", file: file, line: line)
            }
            XCTAssertEqual(actual, operation, file: file, line: line)
        }
    }
}

private final class RacingRestoreFiles: BlobFiles {
    var values: [String: Data] = [:]
    var writes = 0
    var failure: EncryptedBlobError?

    func write(_ data: Data, filename: String) throws {
        writes += 1
        if let failure { throw failure }
        values[filename] = data
        throw EncryptedBlobError.fileSystem(operation: .createFile, code: Int(EEXIST))
    }

    func read(filename: String, maximumBytes: Int, expectedBytes: Int) throws -> Data {
        guard let data = values[filename] else { throw EncryptedBlobError.missing }
        return data
    }
}

private final class MemoryBlobFiles: BlobFiles {
    var values: [String: Data] = [:]
    var reads = 0
    var lastMaximum = 0
    var lastExpected = 0
    var error: EncryptedBlobError?

    func write(_ data: Data, filename: String) throws {
        if let error { throw error }
        values[filename] = data
    }

    func read(filename: String, maximumBytes: Int, expectedBytes: Int) throws -> Data {
        reads += 1
        lastMaximum = maximumBytes
        lastExpected = expectedBytes
        if let error { throw error }
        guard let value = values[filename] else { throw EncryptedBlobError.missing }
        return value
    }
}
