import Darwin
import Foundation
import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import Observation

enum BackupMode: String {
    case export
    case restore
}

@MainActor
@Observable
final class BackupFlow: Identifiable {
    enum Stage: Equatable {
        case entry, encrypting, decrypting, exportReady, preview, restoring, finished
    }

    struct PartialProgress {
        let revisions: Int
        let blobs: Int
    }

    let id = UUID()
    let mode: BackupMode
    var passphrase = ""
    var confirmation = ""
    var revealing = false
    var issue: String?
    private(set) var stage = Stage.entry
    private(set) var file: URL?
    private(set) var ciphertext: Data?
    private(set) var backup: VaultBackup?
    private(set) var preview: RestorationPreview?
    private(set) var skippedRecords: Set<UUID> = []
    private(set) var partial: PartialProgress?
    private(set) var restored: BackupRestoreResult?
    private(set) var attempt = UUID()
    private let session: VaultSession
    private let service: BackupService
    private let accessGeneration: Int
    private let encrypt: @Sendable (VaultBackup, String) async throws -> Data
    private let decrypt: @Sendable (URL, String) async throws -> VaultBackup
    private let generate: () throws -> String
    private var operation: Task<Void, Never>?

    init(
        mode: BackupMode, session: VaultSession, service: BackupService,
        encrypt: @escaping @Sendable (VaultBackup, String) async throws -> Data = { backup, phrase in
            try await BackupFlow.offMain { try backup.encrypted(passphrase: phrase) }
        },
        decrypt: @escaping @Sendable (URL, String) async throws -> VaultBackup = { url, phrase in
            try await BackupFlow.offMain {
                try VaultBackup.decrypt(BackupFile.read(url), passphrase: phrase)
            }
        },
        generate: @escaping () throws -> String = PasswordArchive.generatePassphrase
    ) {
        self.mode = mode
        self.session = session
        self.service = service
        accessGeneration = session.accessGeneration
        self.encrypt = encrypt
        self.decrypt = decrypt
        self.generate = generate
    }

    var working: Bool {
        stage == .encrypting || stage == .decrypting || stage == .restoring
    }

    var validPassphrase: Bool {
        passphrase.utf8.count >= PasswordArchive.minimumPassphraseBytes
            && passphrase.utf8.count <= PasswordArchive.maximumPassphraseBytes
            && !passphrase.contains("\0")
    }

    var validationMessage: String? {
        if !passphrase.isEmpty && !validPassphrase {
            return String(localized: "Use 24–128 UTF-8 bytes, without NUL.")
        }
        if mode == .export && !confirmation.isEmpty
            && !passphrase.utf8.elementsEqual(confirmation.utf8) {
            return String(localized: "The passphrases must match exactly.")
        }
        return nil
    }

    var canPrepare: Bool {
        authorized && stage == .entry && validPassphrase
            && (mode == .export ? passphrase.utf8.elementsEqual(confirmation.utf8) : file != nil)
    }

    var recordIds: [UUID] {
        Array(Set(backup?.revisions.map(\.recordId) ?? [])).sorted { $0.uuidString < $1.uuidString }
    }

    func title(for recordId: UUID) -> String {
        backup?.revisions.first { $0.recordId == recordId }?.title ?? recordId.uuidString
    }

    func needsCloudFiles(_ recordId: UUID) -> Bool {
        backup?.revisions.contains {
            $0.recordId == recordId && $0.storageScope == .synchronizable && !$0.attachments.isEmpty
        } == true
    }

    var canRestore: Bool {
        authorized && stage == .preview && preview != nil
            && recordIds.contains { !skippedRecords.contains($0) }
            && !recordIds.contains { !skippedRecords.contains($0) && needsCloudFiles($0) }
    }

    func generatePassphrase() {
        guard mode == .export, stage == .entry, authorized else {
            issue = String(localized: "Unlock the ledger and reopen the backup action.")
            return
        }
        do {
            passphrase = try generate()
            confirmation = ""
            revealing = true
            issue = nil
        } catch {
            issue = String(localized: "A passphrase could not be generated. Try again.")
        }
    }

    func selectFile(_ result: Result<URL, any Error>) {
        guard authorized else { cancel(); return }
        cancel()
        do { file = try result.get() }
        catch { issue = String(localized: "The backup file could not be opened. Choose it again.") }
    }

    @discardableResult
    func prepare() -> Task<Void, Never>? {
        guard canPrepare else {
            issue = validationMessage ?? String(localized: "Choose a file and enter its passphrase, or confirm a new passphrase.")
            return nil
        }
        let phrase = passphrase
        clearCredentials()
        return run(stage: mode == .export ? .encrypting : .decrypting) { [self] identifier in
            await Task.yield()
            try check(identifier)
            if mode == .export {
                let snapshot = try service.snapshot()
                let data = try await encrypt(snapshot, phrase)
                try check(identifier)
                ciphertext = data
                stage = .exportReady
            } else {
                guard let file else { throw BackupError.invalidContents }
                let contents = try await decrypt(file, phrase)
                try check(identifier)
                _ = try service.preview(contents)
                backup = contents
                stage = .preview
                refreshPreview()
            }
        }
    }

    func include(_ recordId: UUID, _ included: Bool) {
        guard stage == .preview, recordIds.contains(recordId) else {
            issue = String(localized: "Reload the restore preview before selecting items.")
            return
        }
        if included { skippedRecords.remove(recordId) }
        else { skippedRecords.insert(recordId) }
        refreshPreview()
    }

    func refreshPreview() {
        guard authorized, stage == .preview, let backup else {
            issue = String(localized: "Unlock the ledger and reopen the backup action.")
            preview = nil
            return
        }
        do {
            _ = try service.preview(backup)
            preview = try session.previewRestoration(
                backup.revisions.filter { !skippedRecords.contains($0.recordId) }
            )
            issue = nil
        } catch {
            preview = nil
            issue = String(localized: "The backup conflicts with existing data or could not be reviewed. Reload the preview.")
        }
    }

    @discardableResult
    func restoreSelected() -> Task<Void, Never>? {
        guard canRestore, let backup else {
            issue = String(localized: "Select items to restore. Skip items whose cloud files are unavailable.")
            return nil
        }
        let skipped = skippedRecords
        partial = nil
        return run(stage: .restoring) { [self] identifier in
            try check(identifier)
            let result = try await service.restoreCooperatively(backup, skippingRecords: skipped)
            try check(identifier)
            restored = result
            self.backup = nil
            file = nil
            preview = nil
            skippedRecords = []
            stage = .finished
        }
    }

    func stopRestoration() {
        guard stage == .restoring else { return }
        operation?.cancel()
    }

    func exportCompleted(_ result: Result<URL, any Error>, attempt identifier: UUID) {
        guard identifier == attempt, stage == .exportReady, authorized else { return }
        ciphertext = nil
        do {
            _ = try result.get()
            stage = .finished
        } catch {
            stage = .entry
            issue = String(localized: "The encrypted backup could not be saved. Prepare it again.")
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        attempt = UUID()
        clearCredentials()
        ciphertext = nil
        backup = nil
        file = nil
        preview = nil
        skippedRecords = []
        partial = nil
        restored = nil
        issue = nil
        stage = .entry
    }

    private func clearCredentials() {
        passphrase = ""
        confirmation = ""
        revealing = false
    }

    private func check(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard identifier == attempt, authorized else { throw SessionError.interrupted }
    }

    private var authorized: Bool {
        session.state == .unlocked && session.accessGeneration == accessGeneration
    }

    private func run(
        stage nextStage: Stage, action: @escaping @MainActor (UUID) async throws -> Void
    ) -> Task<Void, Never> {
        operation?.cancel()
        let identifier = UUID()
        attempt = identifier
        stage = nextStage
        issue = nil
        let task = Task {
            do { try await action(identifier) }
            catch {
                guard identifier == attempt else { return }
                guard authorized else { cancel(); return }
                stage = nextStage == .restoring ? .preview : .entry
                if let failure = error as? BackupRestoreFailure {
                    partial = PartialProgress(
                        revisions: failure.revisionFailure?.result.addedRevisionIds.count ?? 0,
                        blobs: failure.restoredBlobIds.count
                    )
                    issue = String(localized: "Restoration stopped. Added data remains; retrying will not duplicate it.")
                } else if nextStage == .restoring {
                    issue = String(localized: "Restoration could not start. Reload the preview and try again.")
                } else if error is CancellationError {
                    issue = String(localized: "The backup operation was cancelled.")
                } else if (error as? PasswordArchiveError) == .oversized || (error as? BackupError) == .oversized {
                    issue = String(localized: "The backup exceeds the supported size limits.")
                } else if nextStage == .decrypting {
                    issue = String(localized: "Check the passphrase and backup file. Nothing was restored.")
                } else {
                    issue = String(localized: "A complete backup could not be prepared. Check that all attached files are available.")
                }
            }
            if identifier == attempt { operation = nil }
        }
        operation = task
        return task
    }

    nonisolated private static func offMain<Value: Sendable>(
        _ action: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try action()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum BackupFile {
    static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw BackupError.invalidContents }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let descriptor = try coordinated.withUnsafeFileSystemRepresentation { path in
                    guard let path else { throw BackupError.invalidContents }
                    return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let contents = Result<Data, any Error> {
                    var status = stat()
                    guard fstat(descriptor, &status) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    guard status.st_mode & S_IFMT == S_IFREG else { throw BackupError.invalidContents }
                    guard status.st_size >= 0, status.st_size <= PasswordArchive.maximumEncryptedBytes else {
                        throw BackupError.oversized
                    }
                    var data = Data()
                    while true {
                        try Task.checkCancellation()
                        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        guard chunk.count <= PasswordArchive.maximumEncryptedBytes - data.count else {
                            throw BackupError.oversized
                        }
                        data.append(chunk)
                    }
                    try Task.checkCancellation()
                    return data
                }
                try handle.close()
                return try contents.get()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackupError.invalidContents }
        return try result.get()
    }
}
