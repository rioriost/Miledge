import MiledgeDomain
import SwiftUI

struct SyntheticEditorClipboard: View {
    let failCopy: Bool
    @State private var copied: String?

    var body: some View {
        VStack {
            ItemEditor(revision: VaultRevision(templateId: "custom-item", title: "Synthetic editor", sections: [
                VaultSection(id: "synthetic", fields: [
                    VaultField(id: "name", kind: "string", value: .string("Synthetic Name"), concealed: false, label: "Name"),
                    VaultField(id: "amount", kind: "number", value: .string("9007199254740993.000001"), concealed: false, label: "Amount"),
                    VaultField(id: "key", kind: "key-material",
                               value: .string("  Exact Case\n0001\nالعربية e\u{301} \n"), concealed: true, label: "Key")
                ])
            ]), copy: { value in
                guard !failCopy else { return false }
                do { copied = try value.plainTextForCopy() }
                catch { fatalError("Synthetic copy encoding failed: \(error)") }
                return true
            }, save: { _ in })
            if let copied {
                Text("Synthetic copied value")
                    .accessibilityIdentifier("editor-copied-value")
                    .accessibilityValue(copied)
            }
        }
    }
}
