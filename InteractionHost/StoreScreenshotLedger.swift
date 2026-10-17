import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import SwiftUI

/// Store artwork uses production views with isolated, fictional records only.
@MainActor
struct StoreScreenshotLedger: View {
    private let automaticallyUnlock: Bool
    @State private var session: VaultSession
    @State private var clipboard = SecureClipboard(write: { _, _, _ in }, clear: { _ in })
    private let attachments: AttachmentService
    static let wifiID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    init(automaticallyUnlock: Bool = true, synchronizable: Bool = false) {
        self.automaticallyUnlock = automaticallyUnlock
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
        var records = try! revisions.map(RevisionCodec.encode)
        _session = State(initialValue: VaultSession(
            authenticate: {}, load: { records }, append: { data, _, _ in records.append(data) },
            defaultStorageScope: synchronizable ? .synchronizable : .deviceLocal
        ))
        attachments = AttachmentService(store: try! EncryptedBlobStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("store-artwork-\(UUID().uuidString)")
        ))
    }

    var body: some View {
        LedgerView(session: session, attachments: attachments, clipboard: clipboard)
            .task {
                if automaticallyUnlock { try? await session.unlock() }
            }
    }
}

#if os(macOS)
/// A fresh window avoids reusing closed-window restoration state during artwork capture.
@MainActor
final class StoreArtworkAppDelegate: NSObject, NSApplicationDelegate {
    private var artworkWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let accessibilityTest = ProcessInfo.processInfo.environment["MILEDGE_ACCESSIBILITY_TEST"] == "1"
        guard ProcessInfo.processInfo.arguments.contains("store-screenshots") || accessibilityTest else { return }
        let language = ProcessInfo.processInfo.environment["MILEDGE_UI_LOCALE"] ?? "en"
        let dark = ProcessInfo.processInfo.environment["MILEDGE_UI_APPEARANCE"] == "dark"
        let scenario = ProcessInfo.processInfo.arguments.dropFirst().first ?? "store-screenshots"
        let root = InteractionView(scenario: scenario)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
            .preferredColorScheme(accessibilityTest ? nil : (dark ? .dark : .light))
            .displayPreferences()
            .accessibilityTestConfiguration()
            .frame(minWidth: 800, minHeight: 520)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Miledge"
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        window.contentViewController = controller
        let highContrast = ProcessInfo.processInfo.environment["MILEDGE_AX_CONTRAST"] == "1"
        window.appearance = NSAppearance(named: highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        artworkWindow = window
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            var frame = window.frame
            frame.size = NSSize(width: 1280, height: 800)
            window.setFrame(frame, display: true)
        }
    }
}
#endif
