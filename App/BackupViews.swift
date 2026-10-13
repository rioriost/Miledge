import CoreTransferable
import MiledgeStorage
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let miledgeBackup = UTType(exportedAs: "com.miledge.encrypted-backup", conformingTo: .data)
}

@MainActor
final class EncryptedBackupDocument: Transferable {
    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .miledgeBackup) { document in
            try await document.snapshot()
        }
    }
    private var ciphertext: Data?
    let attempt: UUID

    init(ciphertext: Data, attempt: UUID) {
        self.ciphertext = ciphertext
        self.attempt = attempt
    }

    func invalidate() { ciphertext = nil }

    func snapshot() async throws -> Data {
        try Task.checkCancellation()
        guard let ciphertext else { throw CancellationError() }
        return ciphertext
    }
}

struct BackupView: View {
    @Bindable var flow: BackupFlow
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exporting = false
    @State private var document: EncryptedBackupDocument?
    @State private var confirmingRestore = false
    @State private var confirmingStop = false

    var body: some View {
        NavigationStack {
            Form {
                switch flow.stage {
                case .entry:
                    entry
                case .encrypting, .decrypting, .restoring:
                    ProgressView(LocalizedStringKey(flow.stage == .restoring
                        ? "Restoring…" : flow.stage == .decrypting ? "Opening backup…" : "Preparing backup…"))
                case .exportReady:
                    Label("Encrypted backup ready", systemImage: "lock.doc")
                    Button("Save backup…") {
                        if let ciphertext = flow.ciphertext {
                            document = EncryptedBackupDocument(ciphertext: ciphertext, attempt: flow.attempt)
                            exporting = true
                        }
                    }
                case .preview:
                    restorePreview
                case .finished:
                    Label(LocalizedStringKey(flow.mode == .export ? "Backup saved" : "Restoration complete"),
                          systemImage: "checkmark.circle")
                    if let restored = flow.restored {
                        count("Added revisions", restored.revisions.addedRevisionIds.count)
                        count("Existing revisions", restored.revisions.existingRevisionCount)
                        count("Skipped revisions", restored.revisions.skippedRevisionCount)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(LocalizedStringKey(flow.mode == .export ? "Export backup" : "Restore backup"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey(flow.stage == .finished ? "Done" : "Cancel")) {
                        if flow.stage == .restoring { confirmingStop = true }
                        else { flow.cancel(); dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if flow.stage == .preview {
                    ToolbarItem {
                        Button("Reload preview", systemImage: "arrow.clockwise") { flow.refreshPreview() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.working)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.miledgeBackup, .data]) { flow.selectFile($0) }
        .fileExporter(
            isPresented: $exporting, item: document, contentTypes: [.miledgeBackup],
            defaultFilename: "Miledge Backup.miledge-backup"
        ) { result in
            if let document {
                flow.exportCompleted(result, attempt: document.attempt)
                document.invalidate()
                self.document = nil
            }
        } onCancellation: {
            document?.invalidate()
            document = nil
            flow.cancel()
        }
        .confirmationDialog("Restore selected items?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore selected items") { flow.restoreSelected() }
                .accessibilityIdentifier("confirm-backup-restore")
        } message: {
            Text("Existing data and conflicting versions remain. If interrupted, already added data is kept.")
        }
        .confirmationDialog("Stop restoring?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop restoration", role: .destructive) { flow.stopRestoration() }
        } message: {
            Text("Already added data remains. You can retry without duplicating it.")
        }
        .alert("Backup unavailable", isPresented: Binding(
            get: { flow.issue != nil }, set: { if !$0 { flow.issue = nil } }
        )) {
            Button("OK") { flow.issue = nil }
        } message: { Text(flow.issue ?? "") }
        .onDisappear {
            document?.invalidate()
            document = nil
            importing = false
            exporting = false
            flow.cancel()
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 400)
        #endif
    }

    private var entry: some View {
        Section {
            if flow.mode == .restore {
                Button("Choose backup…") { importing = true }
                if let file = flow.file {
                    LabeledContent("Backup file") { Text(verbatim: file.lastPathComponent) }
                }
            }
            if flow.revealing {
                TextField("Passphrase", text: $flow.passphrase)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("backup-passphrase")
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                SecureField("Passphrase", text: $flow.passphrase)
                    .accessibilityIdentifier("backup-passphrase")
                    .textContentType(.password)
            }
            if flow.mode == .export {
                SecureField("Confirm passphrase", text: $flow.confirmation)
                    .accessibilityIdentifier("backup-confirmation")
                    .textContentType(.password)
                HStack {
                    Button("Generate passphrase") { flow.generatePassphrase() }
                    Spacer()
                    Button(LocalizedStringKey(flow.revealing ? "Hide" : "Reveal")) { flow.revealing.toggle() }
                }
                .buttonStyle(.borderless)
            }
            if let message = flow.validationMessage {
                Text(message).foregroundStyle(.red).accessibilityIdentifier("backup-validation")
            }
            Button(LocalizedStringKey(flow.mode == .export ? "Prepare backup" : "Open backup")) { flow.prepare() }
                .disabled(!flow.canPrepare)
        } footer: {
            Text(LocalizedStringKey(flow.mode == .export
                ? "Use a unique, strong passphrase and keep it safe. A lost passphrase cannot be recovered."
                : "The file is decrypted in memory. Nothing is added until you confirm."))
        }
    }

    private var restorePreview: some View {
        Group {
            if let preview = flow.preview {
                Section {
                    count("Selected items", preview.recordCount)
                    count("Revisions", preview.revisionCount)
                    count("Existing revisions", preview.existingRevisionCount)
                    count("Potential conflicts", preview.conflictingRecordCount)
                }
            }
            if let partial = flow.partial {
                Section("Already added in this attempt") {
                    count("Revisions", partial.revisions)
                    count("Files", partial.blobs)
                }
            }
            Section("Items to restore") {
                ForEach(flow.recordIds, id: \.self) { identifier in
                    Toggle(isOn: Binding(
                        get: { !flow.skippedRecords.contains(identifier) },
                        set: { flow.include(identifier, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(verbatim: flow.title(for: identifier))
                            Text(verbatim: identifier.uuidString)
                                .ledgerFont(.caption2).foregroundStyle(.secondary)
                                .environment(\.layoutDirection, .leftToRight)
                            if flow.needsCloudFiles(identifier) { Text("Cloud files unavailable. Skip this item.") }
                        }
                    }
                    .accessibilityIdentifier("backup-record-\(identifier.uuidString)")
                }
            }
            Button("Restore selected items") { confirmingRestore = true }
                .accessibilityIdentifier("restore-backup-selection")
                .disabled(!flow.canRestore)
        }
    }

    private func count(_ label: LocalizedStringKey, _ value: Int) -> some View {
        LabeledContent(label) { Text(value, format: .number) }
    }
}

#if os(macOS)
struct BackupActions {
    let export: () -> Void
    let restore: () -> Void
}

private struct BackupActionsKey: FocusedValueKey {
    typealias Value = BackupActions
}

extension FocusedValues {
    var backupActions: BackupActions? {
        get { self[BackupActionsKey.self] }
        set { self[BackupActionsKey.self] = newValue }
    }
}

struct BackupCommands: Commands {
    @FocusedValue(\.backupActions) private var actions

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export backup…") { actions?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Restore backup…") { actions?.restore() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
#endif
