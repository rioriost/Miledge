import MiledgeApplication
import MiledgeDomain
import SwiftUI

/// Simulates arrival from another device without accessing any real Keychain items.
@MainActor
struct SynchronizationLayoutFixture: View {
    @MainActor
    final class Model {
        let session: VaultSession
        let passportID: UUID
        private let arrive: () -> Void

        init() {
            let passport = VaultRevision(templateId: "passport", storageScope: .synchronizable,
                                         title: "旅券（パスポート）2026-10-14")
            let license = VaultRevision(templateId: "driver-license", storageScope: .synchronizable,
                                        title: "運転免許証2026-10-17")
            var records = [try! RevisionCodec.encode(passport)]
            passportID = passport.recordId
            arrive = { records.append(try! RevisionCodec.encode(license)) }
            session = VaultSession(authenticate: {}, load: { records },
                                   append: { data, _, _ in records.append(data) })
        }

        func receive() { arrive() }
    }

    @State private var model = Model()
    @State private var arrived = false
    @State private var textSize = DisplayTextSize.small

    var body: some View {
        LedgerView(session: model.session, browser: LedgerBrowser(selectedRecordId: model.passportID))
            .toolbar {
                ToolbarItemGroup(placement: .status) {
                    Button(arrived ? "テスト用データ到着済み" : "別端末からの追加を再現") {
                        model.receive()
                        arrived = true
                    }
                    .disabled(arrived)
                    Button("文字サイズを切り替え") { textSize = textSize == .small ? .largest : .small }
                }
            }
            .environment(\.locale, Locale(identifier: "ja"))
            .environment(\.displayTextSize, textSize)
            .frame(minWidth: 840, minHeight: 650)
            .task { try? await model.session.unlock() }
    }
}
