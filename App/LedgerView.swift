import LocalAuthentication
import MiledgeApplication
import MiledgeDomain
import SwiftUI

struct LedgerView: View {
    @Bindable var session: VaultSession
    var attachments: AttachmentService?
    var clipboard: SecureClipboard?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale
    @State private var browser: LedgerBrowser
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var draft: VaultRevision?
    @State private var conflict: VaultRevision?
    @State private var choosingTemplate = false
    @State private var issue: String?
    @State private var backupFlow: BackupFlow?
    @State private var showingDisplaySettings = false

    init(
        session: VaultSession, attachments: AttachmentService? = nil, selected: UUID? = nil,
        clipboard: SecureClipboard? = nil, browser: LedgerBrowser? = nil
    ) {
        self.session = session
        self.attachments = attachments
        self.clipboard = clipboard
        var initial = browser ?? LedgerBrowser()
        if let selected, let revision = session.heads.first(where: { $0.revisionId == selected }) {
            initial.selectedRecordId = revision.recordId
        }
        _browser = State(initialValue: initial)
    }

    private var items: [LedgerItem] {
        browser.visibleItems(from: session.heads)
    }

    var body: some View {
        Group {
            if session.state == .unlocked {
                NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
                    LedgerSidebar(items: LedgerBrowser.items(from: session.heads), selection: browser.category) { category in
                        browser.selectCategory(category, heads: session.heads)
                        compactColumn = .content
                    }
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                    .toolbar {
                        if sizeClass == .compact {
                            ToolbarItem {
                                Button("Add", systemImage: "plus") { choosingTemplate = true }.accessibilityIdentifier("ledger-add")
                            }
                            ToolbarItem { lockButton }
                        }
                    }
                } content: {
                    ledgerList
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                } detail: {
                    ledgerDetail
                        .navigationSplitViewColumnWidth(min: 320, ideal: 500)
                }
                .navigationSplitViewStyle(.balanced)
                #if os(macOS)
                .searchable(text: $browser.query)
                #endif
            } else {
                lockedLedger
            }
        }
        .sheet(isPresented: $choosingTemplate) {
            ItemCreationView(category: browser.category, session: session, attachments: attachments, copy: editorCopy) { revision in
                browser.show(recordId: revision.recordId, heads: session.heads)
                compactColumn = .detail
                choosingTemplate = false
            }
        }
        .sheet(item: $draft) { revision in
            ItemEditor(revision: revision, attachments: attachments, relatedItems: session.visibleItems(), copy: editorCopy) { revision in
                do {
                    try session.save(revision)
                    browser.show(recordId: revision.recordId, heads: session.heads)
                    compactColumn = .detail
                    draft = nil
                } catch {
                    issue = String(localized: "The item could not be saved. Your changes are still open.")
                }
            }
        }
        .sheet(item: $conflict) { revision in
            ConflictResolver(
                versions: session.heads.filter { $0.recordId == revision.recordId },
                reload: {
                    try session.refresh()
                    return session.heads.filter { $0.recordId == revision.recordId }
                }, resolve: { chosen, expected in
                    let resolved = try session.resolveConflict(
                        recordId: revision.recordId, keeping: chosen, expectedHeads: expected
                    )
                    browser.show(recordId: resolved.recordId, heads: session.heads)
                    compactColumn = resolved.deleted ? .content : .detail
                    conflict = nil
                }
            )
        }
        .sheet(item: $backupFlow) { flow in
            BackupView(flow: flow)
        }
        .sheet(isPresented: $showingDisplaySettings) {
            NavigationStack { DisplaySettingsView() }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem {
                Button("Display", systemImage: "textformat.size") { showingDisplaySettings = true }
                    .accessibilityIdentifier("display-settings")
            }
        }
        #endif
        .alert("Unable to complete the action", isPresented: Binding(
            get: { issue != nil },
            set: { if !$0 { issue = nil } }
        )) {
            Button("OK") { issue = nil }
        } message: {
            Text(issue ?? "")
        }
        .alert("Clipboard unavailable", isPresented: Binding(
            get: { clipboard?.issue != nil }, set: { if !$0 { clipboard?.issue = nil } }
        )) {
            Button("OK") { clipboard?.issue = nil }
        } message: {
            Text(LocalizedStringKey(clipboard?.issue == .clearingFailed
                ? "The copied value could not be cleared. Clear the clipboard before leaving this device."
                : "The value could not be copied. Try again."))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clipboard?.expireIfNeeded() }
            if phase == .background || (phase == .inactive && session.state == .unlocked) {
                lock(clearClipboard: false)
            }
        }
        .onChange(of: session.accessGeneration) { _, _ in
            attachments?.clearTemporaryFiles()
            backupFlow?.cancel()
            backupFlow = nil
            browser.reset()
            compactColumn = .sidebar
            draft = nil
            conflict = nil
            choosingTemplate = false
        }
        .onChange(of: browser.query) { _, _ in browser.reconcileSelection(heads: session.heads) }
        .onChange(of: session.heads) { _, _ in browser.reconcileSelection(heads: session.heads) }
        #if os(macOS)
        .focusedSceneValue(\.backupActions, backupActions)
        .focusedSceneValue(\.ledgerActions, session.state == .unlocked
            ? LedgerActions(add: { choosingTemplate = true }, lock: { lock() }) : nil)
        #endif
    }

    private var ledgerList: some View {
        List(selection: $browser.selectedRecordId) {
            ForEach(items) { item in
                NavigationLink(value: item.id) {
                    LedgerItemRow(item: item)
                }
                .accessibilityIdentifier("ledger-item-\(item.id.uuidString)")
            }
        }
        .listStyle(.plain)
        .navigationTitle(browser.category.title)
        .navigationSubtitle(Text(verbatim: CatalogLocalization.itemCount(items.count, locale: locale)))
        #if os(iOS)
        .searchable(text: $browser.query)
        #endif
        .accessibilityIdentifier("ledger-items")
        .overlay {
            if items.isEmpty {
                if !browser.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: browser.query)
                } else {
                    ContentUnavailableView {
                        Label(browser.category == .favorites ? "No favorites" : "No items",
                              systemImage: browser.category.symbol)
                    } actions: {
                        Button("Add item", systemImage: "plus") { choosingTemplate = true }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem { backupMenu }
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $browser.descending) {
                        Text("Title, A–Z").tag(false)
                        Text("Title, Z–A").tag(true)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
                .help("Sort")
            }
            ToolbarItem {
                Button("Add", systemImage: "plus") { choosingTemplate = true }.accessibilityIdentifier("ledger-add")
            }
            ToolbarItem {
                lockButton
            }
        }
    }

    private var editorCopy: ((JSONValue) -> Bool)? {
        clipboard.map { clipboard in { value in
            guard session.state == .unlocked else { return false }
            let success = clipboard.copy(value)
            // The editor reports copy failure in its own active sheet.
            if !success, clipboard.issue == .copyFailed { clipboard.issue = nil }
            return success
        } }
    }

    @ViewBuilder
    private var ledgerDetail: some View {
        if let item = items.first(where: { $0.id == browser.selectedRecordId }), let revision = item.revision {
            ItemDetailView(
                revision: revision, conflicted: session.hasConflict(revision),
                edit: { edit(revision) }, delete: { delete(revision) },
                relatedItems: session.heads, openRelated: { revisionId in
                    if let target = session.heads.first(where: { $0.revisionId == revisionId }) {
                        browser.show(recordId: target.recordId, heads: session.heads)
                    }
                },
                copy: clipboard.map { clipboard in
                    { value in
                        guard session.state == .unlocked else {
                            clipboard.issue = .copyFailed
                            return false
                        }
                        return clipboard.copy(value)
                    }
                }, resolveConflict: { conflict = revision }, attachments: attachments
            ).navigationTitle(Text(verbatim: revision.title))
        } else if let item = items.first(where: { $0.id == browser.selectedRecordId }) {
            ContentUnavailableView {
                Label("Conflicting changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: item.title)
            } actions: {
                Button { conflict = item.versions.first } label: {
                    Text("Resolve conflict").frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("No item selected", systemImage: "square.stack.3d.up")
        }
    }

    private var lockedLedger: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").ledgerFont(.largeTitle).accessibilityHidden(true)
            Text("Miledge").ledgerFont(.title)
            Button("Unlock") { Task { await unlock() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.state == .unlocking)
            if session.state == .unlocking { ProgressView() }
            #if os(iOS)
            Button("Display", systemImage: "textformat.size") { showingDisplaySettings = true }
                .accessibilityIdentifier("display-settings")
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backupMenu: some View {
        Menu {
            Button("Export backup…") { openBackup(.export) }
            Button("Restore backup…") { openBackup(.restore) }
        } label: {
            Label("Backup", systemImage: "externaldrive")
        }
        .disabled(attachments == nil)
    }

    private var lockButton: some View {
        Button("Lock", systemImage: "lock") { lock() }
    }

    #if os(macOS)
    private var backupActions: BackupActions? {
        guard session.state == .unlocked, attachments != nil else { return nil }
        return BackupActions(export: { openBackup(.export) }, restore: { openBackup(.restore) })
    }
    #endif

    private func openBackup(_ mode: BackupMode) {
        guard session.state == .unlocked, let attachments else {
            issue = String(localized: "Unlock the ledger and reopen the backup action.")
            return
        }
        backupFlow = BackupFlow(
            mode: mode, session: session, service: BackupService(session: session, attachments: attachments)
        )
    }

    private func lock(clearClipboard: Bool = true) {
        attachments?.clearTemporaryFiles()
        backupFlow?.cancel()
        backupFlow = nil
        if clearClipboard { clipboard?.clearOwnedContents() }
        session.lock()
        browser.reset()
        compactColumn = .sidebar
        draft = nil
        conflict = nil
        choosingTemplate = false
        issue = nil
    }

    private func unlock() async {
        do {
            try await session.unlock()
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            session.lock()
        } catch is CancellationError {
            session.lock()
        } catch SessionError.interrupted {
            session.lock()
        } catch {
            issue = String(localized: "The ledger could not be unlocked or loaded. Try again.")
        }
    }

    private func edit(_ revision: VaultRevision) {
        do {
            draft = try session.editDraft(revision)
        } catch SessionError.conflictRequiresMerge {
            conflict = revision
        } catch {
            issue = String(localized: "This item is read-only or no longer available.")
        }
    }

    private func delete(_ revision: VaultRevision) {
        do {
            try session.delete(revision)
            browser.selectedRecordId = nil
            compactColumn = .content
        } catch {
            issue = String(localized: "The item could not be deleted. No history was removed.")
        }
    }
}

#if os(macOS)
struct LedgerActions {
    let add: () -> Void
    let lock: () -> Void
}

extension FocusedValues {
    @Entry var ledgerActions: LedgerActions?
}

struct LedgerCommands: Commands {
    @FocusedValue(\.ledgerActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New item") { actions?.add() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
        }
        CommandMenu("Ledger") {
            Button("Lock") { actions?.lock() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
#endif
