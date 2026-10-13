import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import SwiftUI

@MainActor
struct SyntheticBackupLedger: View {
    @State private var session: VaultSession
    @State private var inspected: String?
    private let attachments: AttachmentService
    private let history: BackupInteractionHistory
    private let documents: URL

    init(scenario: String) {
        do {
            let history = BackupInteractionHistory()
            self.history = history
            #if os(macOS)
            let documents = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiledgeBackupInteraction-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let directory = documents.appendingPathComponent("Blobs", isDirectory: true)
            #else
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("SyntheticBackupBlobs", isDirectory: true).resolvingSymlinksInPath()
            #endif
            self.documents = documents
            let exported = documents.appendingPathComponent("Miledge Backup.miledge-backup")
            if FileManager.default.fileExists(atPath: exported.path) {
                try FileManager.default.removeItem(at: exported)
            }
            let attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
            self.attachments = attachments
            let original = VaultRevision(
                recordId: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                title: "Synthetic original"
            )
            history.bytes = [try RevisionCodec.encode(original)]
            history.failAt = scenario == "backup-retry" ? 2 : nil
            let blob = EncryptedBlob(
                blobId: UUID(uuidString: "20000000-0000-0000-0000-000000000009")!,
                key: Data(repeating: 19, count: 32), plaintextSize: 5
            )
            var root = VaultRevision(
                recordId: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                revisionId: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                title: "Synthetic restored item", tags: ["  Exact Case  "],
                sections: [VaultSection(id: "synthetic", fields: [
                    VaultField(
                        id: "secret", kind: "multiline", value: .string("Synthetic\r\nالعربية e\u{301}\n"),
                        concealed: true
                    )
                ])], attachments: [
                    AttachmentMetadata(blob: blob, filename: "../../../Synthetic", mediaType: "public.data").json
                ], linkedRecordIds: [original.recordId, original.recordId]
            )
            root.unknownProperties = ["future": .number("9007199254740993")]
            var alpha = root
            alpha.revisionId = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
            alpha.parentRevisionIds = [root.revisionId]
            alpha.title = "Synthetic restored Alpha"
            var beta = alpha
            beta.revisionId = UUID(uuidString: "20000000-0000-0000-0000-000000000005")!
            beta.title = "Synthetic restored Beta"
            let backup = try VaultBackup(
                revisions: [beta, alpha, root],
                blobs: [BackupBlob(metadata: blob, bytes: Data([0, 1, 2, 254, 255]), scope: .deviceLocal)]
            )
            try backup.encrypted(passphrase: BackupInteractionHistory.passphrase)
                .write(to: documents.appendingPathComponent("Synthetic restore.miledge-backup"))
            _session = State(initialValue: VaultSession(
                authenticate: {}, load: { history.bytes }, append: { data, _, _ in try history.append(data) }
            ))
        } catch {
            fatalError("Synthetic backup fixture could not be prepared: \(error)")
        }
    }

    var body: some View {
        VStack {
            LedgerView(session: session, attachments: attachments)
                .fileDialogDefaultDirectory(documents)
                .task {
                    do { try await session.unlock() }
                    catch { fatalError("Synthetic backup ledger could not open: \(error)") }
                }
            Menu("Test backup") {
                Button("Inspect test history") {
                    do {
                        inspected = "[" + (try history.bytes.map {
                            String(decoding: try RevisionCodec.encode(RevisionCodec.decode($0)), as: UTF8.self)
                        }).joined(separator: ",") + "]"
                    } catch { fatalError("Synthetic history inspection failed: \(error)") }
                }
                Button("Inspect test attachment") {
                    do {
                        let revisions = try history.bytes.map(RevisionCodec.decode)
                        guard let metadata = revisions.flatMap(\.attachments).first else {
                            inspected = "No restored attachment"
                            return
                        }
                        let bytes = try attachments.read(AttachmentMetadata(json: metadata))
                        inspected = bytes.base64EncodedString()
                    } catch { fatalError("Synthetic attachment inspection failed: \(error)") }
                }
                Button("Inspect exported backup") {
                    do {
                        let url = documents.appendingPathComponent("Miledge Backup.miledge-backup")
                        let backup = try VaultBackup.decrypt(Data(contentsOf: url), passphrase: BackupInteractionHistory.passphrase)
                        inspected = "[" + (try backup.revisions.map {
                            String(decoding: try RevisionCodec.encode($0), as: UTF8.self)
                        }).joined(separator: ",") + "]"
                    } catch { fatalError("Synthetic exported backup inspection failed: \(error)") }
                }
            }
            if let inspected {
                Text("Synthetic backup inspection")
                    .accessibilityIdentifier("backup-inspection")
                    .accessibilityValue(inspected)
            }
        }
    }
}

@MainActor
private final class BackupInteractionHistory {
    static let passphrase = "Synthetic-backup-passphrase-0123456789"
    var bytes: [Data] = []
    var writes = 0
    var failAt: Int?

    func append(_ data: Data) throws {
        writes += 1
        if writes == failAt { throw CocoaError(.fileWriteOutOfSpace) }
        bytes.append(data)
    }
}
