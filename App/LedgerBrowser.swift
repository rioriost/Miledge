import MiledgeDomain
import SwiftUI

enum LedgerCategory: String, CaseIterable, Identifiable {
    case all, favorites, credentials, finances, records, conflicts

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .credentials: "Credentials"
        case .finances: "Finances"
        case .records: "Records"
        case .conflicts: "Conflicts"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up.fill"
        case .favorites: "star.fill"
        case .credentials: "key.fill"
        case .finances: "creditcard.fill"
        case .records: "doc.text.fill"
        case .conflicts: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .all: .accentColor
        case .favorites: .yellow
        case .credentials: .green
        case .finances: .orange
        case .records: .cyan
        case .conflicts: .red
        }
    }

    static func group(for templateId: String) -> Self {
        switch templateId {
        case "api-credential", "affiliate-account", "database", "email-account", "ssh-key",
             "server", "software-license", "wireless-router", "recovery-kit", "signing-certificate", "oauth-client":
            .credentials
        case "credit-card", "bank-account", "crypto-wallet", "insurance-policy", "tax-record":
            .finances
        default: .records
        }
    }

    func contains(_ item: LedgerItem) -> Bool {
        switch self {
        case .all: true
        case .favorites: item.versions.contains { $0.favorite }
        case .conflicts: item.isConflicted
        default: item.versions.contains { Self.group(for: $0.templateId) == self }
        }
    }

    var templates: [ItemTemplate] {
        TemplateCatalog.all.filter { template in
            switch self {
            case .all, .favorites, .conflicts: true
            default: Self.group(for: template.id) == self
            }
        }
    }
}

struct LedgerItem: Identifiable {
    let id: UUID
    let versions: [VaultRevision]

    var isConflicted: Bool { versions.count > 1 }
    var favorite: Bool { versions.contains { $0.favorite } }
    var revision: VaultRevision? { isConflicted ? nil : versions.first }
    var title: String {
        Set(versions.map(\.title)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.joined(separator: " / ")
    }

    func matches(_ query: String, locale: Locale = .current) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || versions.contains {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.templateId.localizedCaseInsensitiveContains(query)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || (TemplateCatalog.template(id: $0.templateId).map {
                    CatalogLocalization.templateName($0, locale: locale)
                        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
                        || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
                } ?? false)
        }
    }
}

struct LedgerBrowser {
    var category = LedgerCategory.all
    var selectedRecordId: UUID?
    var query = ""
    var descending = false

    static func items(from heads: [VaultRevision]) -> [LedgerItem] {
        Dictionary(grouping: heads, by: \.recordId).compactMap { id, versions in
            guard versions.count > 1 || versions.first?.deleted == false else { return nil }
            return LedgerItem(id: id, versions: versions.sorted { $0.revisionId.uuidString < $1.revisionId.uuidString })
        }
    }

    func visibleItems(from heads: [VaultRevision]) -> [LedgerItem] {
        Self.items(from: heads).filter { category.contains($0) && $0.matches(query) }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            if comparison == .orderedSame { return $0.id.uuidString < $1.id.uuidString }
            return comparison == (descending ? .orderedDescending : .orderedAscending)
        }
    }

    mutating func selectCategory(_ category: LedgerCategory, heads: [VaultRevision]) {
        self.category = category
        reconcileSelection(heads: heads)
    }

    mutating func reconcileSelection(heads: [VaultRevision]) {
        if let selectedRecordId, !visibleItems(from: heads).contains(where: { $0.id == selectedRecordId }) {
            self.selectedRecordId = nil
        }
    }

    mutating func show(recordId: UUID, heads: [VaultRevision]) {
        if !visibleItems(from: heads).contains(where: { $0.id == recordId }) {
            category = .all
            query = ""
        }
        selectedRecordId = recordId
        reconcileSelection(heads: heads)
    }

    mutating func reset() {
        category = .all
        selectedRecordId = nil
        query = ""
        descending = false
    }
}

struct LedgerSidebar: View {
    let items: [LedgerItem]
    let selection: LedgerCategory
    let select: (LedgerCategory) -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                    count: textSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                ForEach(LedgerCategory.allCases) { category in
                    let count = items.filter { category.contains($0) }.count
                    let selected = selection == category
                    Button { select(category) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: category.symbol)
                                    .foregroundStyle(category.color)
                                    .accessibilityHidden(true)
                                Spacer(minLength: 4)
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.primary)
                                        .accessibilityHidden(true)
                                }
                                Text(count, format: .number).ledgerFont(.caption, weight: .semibold)
                            }
                            Text(category.title).ledgerFont(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? (contrast == .increased ? Color.primary : Color.accentColor) : .clear, lineWidth: 2)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(category.title))
                    .accessibilityValue(Text("\(count) items"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("category-\(category.rawValue)")
                }
            }
            .padding(12)
        }
        .navigationTitle("Miledge")
        .accessibilityIdentifier("ledger-categories")
    }
}

struct LedgerItemRow: View {
    let item: LedgerItem
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            if !textSize.isAccessibilitySize {
                Image(systemName: LedgerCategory.group(for: item.revision?.templateId ?? "").symbol)
                    .ledgerFont(.title3)
                    .frame(width: iconSize, height: iconSize)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).ledgerFont(.headline)
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if item.isConflicted {
                    Text("Conflicting changes").ledgerFont(.caption)
                } else if let revision = item.revision {
                    Text(LocalizedStringKey(TemplateCatalog.template(id: revision.templateId)?.name ?? "Unsupported item"))
                        .ledgerFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.favorite { Label("Favorite", systemImage: "star.fill").labelStyle(.iconOnly) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
