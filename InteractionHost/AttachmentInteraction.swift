import Foundation
import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import SwiftUI

/// Actual encrypted attachment storage, confined to a unique synthetic directory.
@MainActor
struct SyntheticAttachmentLedger: View {
    @State private var session: VaultSession
    @State private var inspected: String?
    @State private var fixture: SyntheticAttachmentFixture

    init() {
        do {
            let fixture = try SyntheticAttachmentFixture()
            _fixture = State(initialValue: fixture)
            _session = State(initialValue: VaultSession(
                authenticate: {}, load: { fixture.history },
                append: { data, _, _ in fixture.history.append(data) }
            ))
        } catch { fatalError("Synthetic attachments could not be prepared: \(error)") }
    }

    var body: some View {
        VStack {
            LedgerView(session: session, attachments: fixture.service)
                .fileDialogDefaultDirectory(fixture.directory)
                .task {
                    do { try await session.unlock() }
                    catch { fatalError("Synthetic attachments could not open: \(error)") }
                }
            Menu("Test files") {
                Button("Inspect attachment history") {
                    do {
                        let revisions = try fixture.history.map(RevisionCodec.decode)
                        let oldBytes = try fixture.service.read(fixture.original)
                        inspected = "revisions=\(revisions.count);current=\(revisions.last?.attachments.count ?? -1);original=\(oldBytes == SyntheticAttachmentFixture.pdf ? "intact" : "changed")"
                    } catch { fatalError("Synthetic file inspection failed: \(error)") }
                }
                Button("Inspect exported PDF") {
                    let url = fixture.directory.appendingPathComponent("Synthetic document.pdf")
                    inspected = (try? Data(contentsOf: url)) == SyntheticAttachmentFixture.pdf ? "Export matches original bytes" : "No matching export"
                }
            }
            if let inspected {
                Text("Synthetic file inspection")
                    .accessibilityIdentifier("attachment-inspection")
                    .accessibilityValue(inspected)
            }
        }
    }
}

@MainActor
private final class SyntheticAttachmentFixture {
    let directory: URL
    let service: AttachmentService
    let original: AttachmentMetadata
    var history: [Data]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiledgeAttachmentInteraction-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = AttachmentService(store: try EncryptedBlobStore(
            directory: directory.appendingPathComponent("Blobs", isDirectory: true)
        ))
        let blob = EncryptedBlob(
            blobId: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            key: Data(repeating: 41, count: 32), plaintextSize: Self.pdf.count
        )
        try service.restore(Self.pdf, as: blob, scope: .deviceLocal)
        original = AttachmentMetadata(blob: blob, filename: "Synthetic document.pdf", mediaType: "com.adobe.pdf")
        let imageBlob = EncryptedBlob(
            blobId: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            key: Data(repeating: 42, count: 32), plaintextSize: Self.png.count
        )
        try service.restore(Self.png, as: imageBlob, scope: .deviceLocal)
        let image = AttachmentMetadata(blob: imageBlob, filename: "Synthetic image.png", mediaType: "public.png")
        let revision = VaultRevision(templateId: "document", title: "Synthetic files", attachments: [original.json, image.json])
        history = [try RevisionCodec.encode(revision)]
    }

    // A generated 240 x 120 image containing two solid color panels.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAPAAAAB4CAIAAABD1OhwAAAB3UlEQVR4nO3SQQ2AMADAwBnijTXkoARX/OdiS7pL6qA3rvfRgv7v1oLG9tOHtP30IQENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUEzBSHj5pin5TAAAAAElFTkSuQmCC")!

    static var pdf: Data {
        let stream = "BT /F1 22 Tf 40 140 Td (Synthetic document) Tj 0 -32 Td /F1 12 Tf (No personal information.) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 360 220] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        var result = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(result.utf8.count)
            result += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = result.utf8.count
        result += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets { result += String(format: "%010d 00000 n \n", offset) }
        result += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(result.utf8)
    }
}
