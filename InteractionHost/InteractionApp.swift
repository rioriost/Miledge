import MiledgeApplication
import MiledgeDomain
import SwiftUI

@main
struct InteractionApp: App {
    private let scenario = ProcessInfo.processInfo.arguments.dropFirst().first ?? "validation"
    private let localeIdentifier = ProcessInfo.processInfo.environment["MILEDGE_UI_LOCALE"] ?? "en"
    private let minimumWindow = ProcessInfo.processInfo.environment["MILEDGE_UI_MINIMUM_WINDOW"] == "1"
    init() {
        let size = ProcessInfo.processInfo.arguments.contains("editor-copy-largest-font")
            || ProcessInfo.processInfo.arguments.contains("selection-largest") ? DisplayTextSize.largest : .standard
        UserDefaults.standard.set(size.rawValue, forKey: "displayTextSize")
        UserDefaults.standard.set(true, forKey: "concealValuesByDefault")
    }
    private var appearance: ColorScheme? {
        switch ProcessInfo.processInfo.environment["MILEDGE_UI_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        #if os(macOS)
        Window("Miledge", id: "ledger") { interactionContent }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: minimumWindow ? 800 : 1100, height: minimumWindow ? 520 : 760)
        .windowResizability(minimumWindow ? .contentSize : .contentMinSize)
        .commands { LedgerCommands() }
        Settings { DisplaySettingsView() }
        #else
        WindowGroup { interactionContent }
        #endif
    }

    private var interactionContent: some View {
        InteractionView(scenario: scenario)
            .environment(\.locale, Locale(identifier: localeIdentifier))
            .environment(\.layoutDirection, localeIdentifier.hasPrefix("ar") ? .rightToLeft : .leftToRight)
            .preferredColorScheme(appearance)
            .displayPreferences()
            .resizeForDisplayText()
        #if os(macOS)
            .frame(minWidth: 800, minHeight: 520)
            .frame(width: minimumWindow ? 800 : nil, height: minimumWindow ? 520 : nil)
        #endif
    }
}

struct InteractionView: View {
    let scenario: String
    @State private var result: String?
    @State private var showingSettings = false

    var body: some View {
        if scenario == "store-screenshots" {
            StoreScreenshotLedger()
        } else if let result {
            Text("Saved")
                .accessibilityIdentifier("saved-revision")
                .accessibilityValue(result)
        } else if scenario == "attachments" {
            SyntheticAttachmentLedger()
        } else if scenario.hasPrefix("selection-") {
            ItemEditor(revision: selectionFixture, creating: true, changeType: { draft, template, _ in
                try VaultEditor.replacingTypeFields(
                    in: draft, with: VaultRevision(templateId: template.id, sections: template.sections)
                )
            }) { revision in
                do { result = String(decoding: try RevisionCodec.encode(revision), as: UTF8.self) }
                catch { fatalError("Synthetic selection fixture encoding failed: \(error)") }
            }
            .environment(\.timeZone, CalendarFieldValue.calendar.timeZone)
        } else if scenario == "type-change-custom" {
            ItemEditor(revision: customTypeChangeFixture, creating: true, changeType: { draft, template, _ in
                try VaultEditor.replacingTypeFields(in: draft, with: VaultRevision(templateId: template.id, sections: template.sections))
            }) { revision in
                result = String(decoding: try! RevisionCodec.encode(revision), as: UTF8.self)
            }
        } else if scenario.hasPrefix("backup") {
            SyntheticBackupLedger(scenario: scenario)
        } else if scenario.hasPrefix("conflict") {
            SyntheticConflictLedger(scenario: scenario)
        } else if scenario.hasPrefix("navigation") {
            SyntheticNavigationLedger(
                failSave: scenario == "navigation-save-failure",
                longDetail: scenario == "navigation-long-detail"
            )
        } else if scenario == "clipboard" {
            SyntheticClipboardLedger()
        } else if scenario.hasPrefix("editor-copy") {
            SyntheticEditorClipboard(failCopy: scenario == "editor-copy-failure")
        } else if scenario == "display-settings" {
            LedgerView(session: VaultSession(authenticate: {}, load: { [] }, append: { _, _, _ in }))
        } else if scenario == "conceal-settings" {
            VStack {
                ItemEditor(revision: fixture()) { revision in
                    do {
                        result = String(decoding: try RevisionCodec.encode(revision), as: UTF8.self)
                    } catch {
                        fatalError("Synthetic settings fixture encoding failed: \(error)")
                    }
                }
                #if os(iOS)
                Button("Display") { showingSettings = true }
                    .accessibilityIdentifier("display-settings")
                #endif
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { DisplaySettingsView() }
            }
        } else if scenario == "organization-ledger" {
            SyntheticOrganizationLedger()
        } else if scenario == "related-ledger" {
            SyntheticOrganizationLedger(related: true)
        } else if scenario == "related-detail" {
            ItemDetailView(
                revision: RelatedInteractionFixture.source, conflicted: false, edit: {}, delete: {},
                relatedItems: RelatedInteractionFixture.targets, openRelated: { _ in
                    result = "Synthetic related navigation"
                }
            )
        } else if scenario == "reveal" {
            Form {
                FieldDetailRow(field: VaultField(
                    id: "secret", kind: "concealed", value: .string("Synthetic first secret"),
                    concealed: true, label: "First"
                )).accessibilityIdentifier("first-secret")
                FieldDetailRow(field: VaultField(
                    id: "secret", kind: "concealed", value: .string("Synthetic second secret"),
                    concealed: true, label: "Second"
                )).accessibilityIdentifier("second-secret")
            }
        } else {
            ItemEditor(
                revision: fixture(),
                relatedItems: scenario.hasPrefix("related") ? RelatedInteractionFixture.targets : [],
                creating: scenario == "new-secret"
            ) { revision in
                do {
                    result = String(decoding: try RevisionCodec.encode(revision), as: UTF8.self)
                } catch {
                    fatalError("Synthetic fixture encoding failed: \(error)")
                }
            }
        }
    }

    private var customTypeChangeFixture: VaultRevision {
        let card = TemplateCatalog.template(id: "credit-card")!
        return VaultRevision(templateId: card.id, title: "Synthetic custom draft", sections: card.sections + [
            VaultSection(id: "50000000-0000-0000-0000-000000000001", fields: [
                VaultField(id: "50000000-0000-0000-0000-000000000002", kind: "number", value: .string(""), concealed: false, label: "Custom decimal")
            ])
        ])
    }

    private var selectionFixture: VaultRevision {
        guard let registration = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z") else {
            fatalError("Synthetic registration timestamp is invalid.")
        }
        return VaultRevision(templateId: "passport", createdAt: registration, sections: [
            VaultSection(id: "synthetic", fields: [
                VaultField(id: "issuingCountry", kind: "string", value: .string("  historical issuer  "),
                           concealed: false),
                VaultField(id: "brand", kind: "select", value: .string("Private custom brand"), concealed: false),
                VaultField(id: "issueDate", kind: "date",
                           value: .string(scenario == "selection-dates" ? "2032-02-29" : ""), concealed: false),
                VaultField(id: "expiry", kind: "year-month", value: .string("2031-09"), concealed: false),
                VaultField(id: "currency", kind: "string", value: .string("USD"), concealed: false)
            ])
        ])
    }

    @MainActor
    struct SyntheticNavigationLedger: View {
        @State private var session: VaultSession

        init(failSave: Bool, longDetail: Bool = false) {
            do {
                let cardId = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
                let initial = [
                    VaultRevision(templateId: "api-credential", title: "Synthetic API", tags: ["Work"], sections: [
                        VaultSection(id: "credentials", fields: longDetail ? (1...50).map { index in
                            VaultField(
                                id: "review-field-\(index)", kind: "string",
                                value: .string("Synthetic value \(index)"), concealed: false,
                                label: "Review field \(index)"
                            )
                        } : [
                            VaultField(id: "credential", kind: "concealed",
                                       value: .string("Never search this secret"), concealed: true)
                        ])
                    ], linkedRecordIds: [cardId]),
                    VaultRevision(recordId: cardId, templateId: "credit-card", title: "Synthetic Card", favorite: true),
                    VaultRevision(templateId: "document", title: "Synthetic Document")
                ]
                var records = try initial.map(RevisionCodec.encode)
                var writes = 0
                _session = State(initialValue: VaultSession(authenticate: {}, load: { records }, append: { data, _, _ in
                    writes += 1
                    if failSave && writes == 1 { throw CocoaError(.fileWriteUnknown) }
                    records.append(data)
                }))
            } catch {
                fatalError("Synthetic navigation fixture encoding failed: \(error)")
            }
        }

        var body: some View {
            LedgerView(session: session)
                .task {
                    do { try await session.unlock() }
                    catch { fatalError("Synthetic navigation ledger could not open: \(error)") }
                }
        }
    }

    private func fixture() -> VaultRevision {
        if scenario.hasPrefix("related") {
            var source = RelatedInteractionFixture.source
            if scenario == "related-empty" { source.linkedRecordIds = [] }
            if scenario == "related-readonly" { source.schemaVersion = 999 }
            return source
        }
        let field: VaultField
        switch scenario {
        case "organization", "organization-empty", "organization-readonly":
            field = VaultField(id: "note", kind: "multiline", value: .string("Synthetic untouched value"),
                               concealed: false, label: "Notes")
        case "validation", "validation-concealed":
            field = VaultField(id: "amount", kind: "number", value: .string("1.0"),
                               concealed: scenario == "validation-concealed", label: "Amount")
        case "multiline", "new-secret":
            field = VaultField(id: "key", kind: "key-material",
                               value: .string(scenario == "new-secret" ? "" : "Synthetic existing key"),
                               concealed: true, label: "Key")
        case "address":
            field = VaultField(id: "address", kind: "address", value: .object([
                "alpha": .string("001"), "beta": .string("002")
            ]), concealed: false, label: "Address")
        case "choices", "choices-concealed", "conceal-settings":
            field = VaultField(id: "choices", kind: "multi-select", value: .array([
                .string("B"), .string("A"), .string("A")
            ]), concealed: scenario != "choices", label: "Choices")
        case "recovery":
            field = VaultField(id: "codes", kind: "recovery-codes", value: .array([
                .object(["id": .string("stable-code-id"), "code": .string(" 0001 "), "used": .bool(false)])
            ]), concealed: false, label: "Codes")
        default:
            fatalError("Unknown synthetic UI test scenario: \(scenario)")
        }
        var revision = VaultRevision(templateId: "custom-item", title: "Synthetic item", sections: [
            VaultSection(id: "synthetic", fields: [field])
        ])
        if scenario == "organization" || scenario == "organization-readonly" {
            revision.tags = ["B", "A", "A", "  Keep Case  "]
            revision.linkedRecordIds = [UUID(uuidString: "11111111-2222-3333-4444-555555555555")!]
        }
        if scenario == "organization-readonly" { revision.schemaVersion = 999 }
        return revision
    }
}

struct SyntheticOrganizationLedger: View {
    @State private var session: VaultSession

    init(related: Bool = false) {
        do {
            var source = RelatedInteractionFixture.source
            source.linkedRecordIds = []
            source.tags = []
            source.favorite = false
            let initial = related ? [source] + RelatedInteractionFixture.targets : [
                VaultRevision(title: "Synthetic Alpha", tags: ["Alpha Tag"]),
                VaultRevision(title: "Synthetic Bravo", tags: ["Work"], favorite: true)
            ]
            var records = try initial.map(RevisionCodec.encode)
            _session = State(initialValue: VaultSession(
                authenticate: {}, load: { records },
                append: { data, _, _ in records.append(data) }
            ))
        } catch {
            fatalError("Synthetic ledger fixture encoding failed: \(error)")
        }
    }

    var body: some View {
        LedgerView(session: session)
            .task {
                do { try await session.unlock() }
                catch { fatalError("Synthetic ledger could not open: \(error)") }
            }
    }
}

enum RelatedInteractionFixture {
    static let sourceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let bravoId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let charlieId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let deletedId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let conflictId = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let missingId = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    static var source: VaultRevision {
        VaultRevision(
            recordId: sourceId, title: "Synthetic Alpha", tags: ["Keep tags"], favorite: true,
            sections: [
                VaultSection(
                    id: "synthetic",
                    fields: [
                        VaultField(
                            id: "note", kind: "multiline",
                            value: .string("Synthetic untouched value"),
                            concealed: false, label: "Notes")
                    ])
            ],
            linkedRecordIds: [bravoId, bravoId, missingId, sourceId, deletedId, conflictId]
        )
    }

    static var targets: [VaultRevision] {
        let bravo = VaultRevision(
            recordId: bravoId, title: "Synthetic Bravo", tags: ["Work"],
            sections: [
                VaultSection(
                    id: "synthetic",
                    fields: [
                        VaultField(
                            id: "note", kind: "multiline",
                            value: .string("Never search this secret"),
                            concealed: true, label: "Notes")
                    ])
            ]
        )
        var charlie = VaultRevision(recordId: charlieId, title: "Synthetic Charlie")
        charlie.schemaVersion = 999
        let deleted = VaultRevision(recordId: deletedId, title: "Synthetic Deleted", deleted: true)
        let first = VaultRevision(recordId: conflictId, title: "Synthetic Conflict One")
        var second = first
        second.revisionId = UUID()
        second.title = "Synthetic Conflict Two"
        return [bravo, charlie, deleted, first, second]
    }
}

@MainActor
struct SyntheticClipboardLedger: View {
    @State private var session: VaultSession
    @State private var clipboard: SecureClipboard
    @State private var inspected: String?
    private let fixture: SyntheticClipboardFixture

    init() {
        let fixture = SyntheticClipboardFixture()
        self.fixture = fixture
        _clipboard = State(initialValue: SecureClipboard(
            write: { text, token, _ in
                if fixture.failCopy { throw CocoaError(.fileWriteUnknown) }
                fixture.text = text
                fixture.owner = token
            },
            clear: { token in
                if fixture.owner == token { fixture.text = nil; fixture.owner = nil }
            }, now: { fixture.date }
        ))
        do {
            let source = VaultRevision(title: "Synthetic copy source", sections: [
                VaultSection(id: "copy", fields: [
                    VaultField(
                        id: "secret", kind: "key-material",
                        value: .string("  Exact Case\n0001\nالعربية e\u{301} \n"),
                        concealed: true, label: "Synthetic key"
                    ),
                    VaultField(
                        id: "metadata", kind: "address",
                        value: .object(["postalCode": .string("000001"), "future": .number("9007199254740993")]),
                        concealed: true, label: "Synthetic structured"
                    )
                ])
            ])
            var records = [try RevisionCodec.encode(source)]
            _session = State(initialValue: VaultSession(
                authenticate: {}, load: { records }, append: { data, _, _ in records.append(data) }
            ))
        } catch {
            fatalError("Synthetic copy fixture encoding failed: \(error)")
        }
    }

    var body: some View {
        VStack {
            LedgerView(session: session, clipboard: clipboard)
                .task {
                    do { try await session.unlock() }
                    catch { fatalError("Synthetic copy ledger could not open: \(error)") }
                }
            Menu("Test clipboard") {
                Button("Inspect test clipboard") { inspected = fixture.text ?? "Empty" }
                Button("Replace test clipboard") {
                    fixture.text = "Synthetic other clipboard"
                    fixture.owner = UUID()
                }
                Button("Expire test clipboard") {
                    fixture.date += SecureClipboard.lifetime
                    clipboard.expireIfNeeded()
                }
                Button("Fail next copy") { fixture.failCopy = true }
            }
            if let inspected {
                Text("Synthetic clipboard inspection")
                    .accessibilityIdentifier("test-clipboard")
                    .accessibilityValue(inspected)
            }
        }
    }
}

@MainActor
private final class SyntheticClipboardFixture {
    var text: String?
    var owner: UUID?
    var date = Date()
    var failCopy = false
}
