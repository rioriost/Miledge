import CoreTransferable
import MiledgeApplication
import MiledgeDomain
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Export bytes remain revocable until the system requests them. The chosen exported copy belongs to the user.
@MainActor
final class AttachmentExportDocument: Transferable {
    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { document in
            try await document.snapshot()
        }
    }
    let lease: AttachmentDataLease
    init(bytes: Data) { lease = AttachmentDataLease(data: bytes) }
    init(lease: AttachmentDataLease) { self.lease = lease }
    func invalidate() { lease.invalidate() }
    func snapshot() async throws -> Data {
        try Task.checkCancellation()
        return try lease.snapshot()
    }
}

struct AttachmentRow: View {
    let attachment: JSONValue
    var service: AttachmentService?
    var remove: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: TemporaryAttachmentFile?
    @State private var previewURL: URL?
    @State private var document: AttachmentExportDocument?
    @State private var exporting = false
    @State private var confirmingRemoval = false
    @State private var failed = false

    private var metadata: AttachmentMetadata? { try? AttachmentMetadata(json: attachment) }

    var body: some View {
        Group {
            if let metadata {
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text(verbatim: metadata.filename).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "doc")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(metadata) }
                        VStack(alignment: .leading) { actions(metadata) }
                    }
                }
            } else {
                Label("Unsupported file", systemImage: "exclamationmark.triangle")
            }
        }
        .buttonStyle(.borderless)
        .quickLookPreview($previewURL)
        .fileExporter(
            isPresented: $exporting, item: document,
            contentTypes: [metadata.flatMap { UTType($0.mediaType) ?? UTType(mimeType: $0.mediaType) } ?? .data],
            defaultFilename: metadata.map { URL(fileURLWithPath: $0.filename).lastPathComponent } ?? "Attachment"
        ) { result in
            if case .failure = result { failed = true }
            clearExport()
        } onCancellation: { clearExport() }
        .confirmationDialog("Remove this attachment?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove attachment", role: .destructive) { cleanup(); remove?() }
                .accessibilityIdentifier("confirm-remove-attachment")
        } message: {
            Text("The file is removed from this version only. Saved history keeps its original attachment.")
        }
        .alert("Attachment unavailable", isPresented: $failed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The file could not be opened or exported. Try again.")
        }
        .onChange(of: previewURL) { _, value in
            if value == nil, let preview { service?.endPreview(preview); self.preview = nil }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cleanup() } }
        .onDisappear { cleanup() }
    }

    @ViewBuilder
    private func actions(_ metadata: AttachmentMetadata) -> some View {
        if let service {
            Button {
                do {
                    cleanup()
                    let lease = try service.preparePreview(metadata)
                    preview = lease
                    previewURL = lease.url
                } catch { failed = true }
            } label: { actionLabel("Preview file", systemImage: "doc.text.magnifyingglass") }
            .accessibilityIdentifier("preview-attachment-\(metadata.blob.blobId.uuidString)")
            .accessibilityLabel(Text("Preview file") + Text(verbatim: " " + metadata.filename))
            Button {
                do {
                    cleanup()
                    document = AttachmentExportDocument(lease: try service.prepareExport(metadata))
                    exporting = true
                } catch { failed = true }
            } label: { actionLabel("Export file…", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("export-attachment-\(metadata.blob.blobId.uuidString)")
            .accessibilityLabel(Text("Export file…") + Text(verbatim: " " + metadata.filename))
        }
        if remove != nil {
            Button(role: .destructive) { confirmingRemoval = true } label: {
                actionLabel("Remove attachment", systemImage: "minus.circle")
            }
                .accessibilityIdentifier("remove-attachment-\(metadata.blob.blobId.uuidString)")
                .accessibilityLabel(Text("Remove attachment") + Text(verbatim: " " + metadata.filename))
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(Rectangle())
    }

    private func clearExport() {
        if let document {
            service?.endExport(document.lease)
            document.invalidate()
        }
        document = nil
        exporting = false
    }

    private func cleanup() {
        previewURL = nil
        if let preview { service?.endPreview(preview); self.preview = nil }
        clearExport()
    }
}
