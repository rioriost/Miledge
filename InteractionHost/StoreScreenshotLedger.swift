import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import SwiftUI

/// Store artwork uses production views with isolated, fictional records only.
@MainActor
struct StoreScreenshotLedger: View {
    @State private var session: VaultSession
    @State private var clipboard = SecureClipboard.system()
    private let attachments: AttachmentService
    static let wifiID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    init() {
        let language = ProcessInfo.processInfo.environment["MILEDGE_UI_LOCALE"] ?? "en"
        let titles: [String: [String]] = [
            "en": ["Home Wi-Fi", "Travel passport", "Cloud API", "Design software", "Home insurance", "Library membership", "Project notes", "Recovery kit"],
            "ja": ["自宅のWi-Fi", "旅行用パスポート", "クラウドAPI", "デザインソフト", "住まいの保険", "図書館の会員証", "プロジェクトメモ", "復旧キット"],
            "zh-Hans": ["家庭 Wi-Fi", "旅行护照", "云服务 API", "设计软件", "住房保险", "图书馆会员卡", "项目笔记", "恢复工具包"],
            "zh-Hant": ["家用 Wi-Fi", "旅行護照", "雲端 API", "設計軟體", "住宅保險", "圖書館會員證", "專案筆記", "復原套件"],
            "ko": ["집 Wi-Fi", "여행용 여권", "클라우드 API", "디자인 소프트웨어", "주택 보험", "도서관 회원증", "프로젝트 메모", "복구 키트"],
            "fr": ["Wi-Fi de la maison", "Passeport de voyage", "API cloud", "Logiciel de création", "Assurance habitation", "Carte de bibliothèque", "Notes de projet", "Kit de récupération"],
            "de": ["WLAN zu Hause", "Reisepass", "Cloud-API", "Designsoftware", "Hausratversicherung", "Bibliotheksausweis", "Projektnotizen", "Wiederherstellung"],
            "es": ["Wi-Fi de casa", "Pasaporte de viaje", "API en la nube", "Software de diseño", "Seguro del hogar", "Carné de biblioteca", "Notas del proyecto", "Kit de recuperación"],
            "pt-BR": ["Wi-Fi de casa", "Passaporte", "API na nuvem", "Software de design", "Seguro residencial", "Cartão da biblioteca", "Notas do projeto", "Kit de recuperação"],
            "it": ["Wi-Fi di casa", "Passaporto", "API cloud", "Software di grafica", "Assicurazione casa", "Tessera della biblioteca", "Note del progetto", "Kit di recupero"],
            "ar": ["واي فاي المنزل", "جواز السفر", "واجهة سحابية", "برنامج التصميم", "تأمين المنزل", "بطاقة المكتبة", "ملاحظات المشروع", "مجموعة الاسترداد"],
            "hi": ["घर का Wi-Fi", "यात्रा का पासपोर्ट", "क्लाउड API", "डिज़ाइन सॉफ़्टवेयर", "घर का बीमा", "पुस्तकालय सदस्यता", "प्रोजेक्ट नोट्स", "रिकवरी किट"]
        ]
        let names = titles[language] ?? titles["en"]!
        let types = ["wireless-router", "passport", "api-credential", "software-license", "insurance-policy", "membership", "secure-note", "recovery-kit"]
        let date = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!
        let revisions = types.enumerated().map { index, type in
            let template = TemplateCatalog.template(id: type)!
            var sections = template.sections
            let values = ["deviceName": "Miledge Home", "administrationUsername": "admin", "administrationPassword": "example-only", "ssid": "Miledge Home", "networkPassword": "example-only"]
            for s in sections.indices {
                for f in sections[s].fields.indices {
                    if let value = values[sections[s].fields[f].id], index == 0 {
                        sections[s].fields[f].value = .string(value)
                    }
                }
            }
            return VaultRevision(recordId: index == 0 ? Self.wifiID : UUID(), templateId: type,
                                 title: names[index], favorite: index == 0 || index == 1,
                                 createdAt: date, sections: sections)
        }
        let records = try! revisions.map(RevisionCodec.encode)
        _session = State(initialValue: VaultSession(authenticate: {}, load: { records }, append: { _, _, _ in }))
        attachments = AttachmentService(store: try! EncryptedBlobStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("store-artwork-\(UUID().uuidString)")
        ))
    }

    var body: some View {
        LedgerView(session: session, attachments: attachments, clipboard: clipboard)
            .task {
                try? await session.unlock()
                #if os(macOS)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Miledge" }) {
                    var frame = window.frame
                    frame.size = NSSize(width: 1280, height: 800)
                    window.setFrame(frame, display: true)
                }
                #endif
            }
    }
}
