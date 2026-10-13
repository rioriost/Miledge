import MiledgeApplication
import MiledgeDomain
import Observation
import SwiftUI

@MainActor
@Observable
final class ConflictReview {
    private(set) var versions: [VaultRevision]
    var path: [UUID]
    var confirming: UUID?
    var issue: String?
    private let reload: () throws -> [VaultRevision]
    private let resolve: (UUID, Set<UUID>) throws -> Void

    init(
        versions: [VaultRevision], selected: UUID? = nil,
        reload: @escaping () throws -> [VaultRevision],
        resolve: @escaping (UUID, Set<UUID>) throws -> Void
    ) {
        self.versions = versions.sorted { $0.revisionId.uuidString < $1.revisionId.uuidString }
        path = selected.map { [$0] } ?? []
        self.reload = reload
        self.resolve = resolve
    }

    var canResolve: Bool {
        versions.count > 1 && !versions.contains(where: \.isReadOnly)
            && Set(versions.map(\.storageScope)).count == 1
    }

    func resolveVersion(_ identifier: UUID) {
        confirming = nil
        do {
            try resolve(identifier, Set(versions.map(\.revisionId)))
            issue = nil
        } catch SessionError.staleRevision {
            issue = String(localized: "Versions changed. Reload before resolving.")
        } catch {
            issue = String(localized: "The conflict could not be resolved. No versions were removed.")
        }
    }

    func reloadVersions() {
        do {
            versions = try reload().sorted { $0.revisionId.uuidString < $1.revisionId.uuidString }
            path = []
            confirming = nil
            issue = nil
        } catch {
            issue = String(localized: "Versions could not be reloaded. Try again.")
        }
    }
}

struct ConflictResolver: View {
    @State private var review: ConflictReview
    @Environment(\.dismiss) private var dismiss

    init(
        versions: [VaultRevision], selected: UUID? = nil,
        reload: @escaping () throws -> [VaultRevision],
        resolve: @escaping (UUID, Set<UUID>) throws -> Void
    ) {
        _review = State(initialValue: ConflictReview(
            versions: versions, selected: selected, reload: reload, resolve: resolve
        ))
    }

    var body: some View {
        @Bindable var review = review
        NavigationStack(path: $review.path) {
            List {
                if review.versions.count > 1 {
                    if !review.canResolve {
                        Label("These versions cannot be resolved by this app.", systemImage: "lock")
                    }
                    ForEach(review.versions) { revision in
                        NavigationLink(value: revision.revisionId) {
                            VStack(alignment: .leading) {
                                Text(verbatim: revision.title)
                                if revision.deleted { Text("Deletion revision") }
                                Text(revision.modifiedAt, format: .dateTime.year().month().day().hour().minute())
                                    .ledgerFont(.caption).foregroundStyle(.secondary)
                                Text(verbatim: revision.revisionId.uuidString)
                                    .ledgerFont(.caption2).foregroundStyle(.secondary)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                        }
                        .accessibilityIdentifier("conflict-version-\(revision.revisionId.uuidString)")
                    }
                }
            }
            .overlay {
                if review.versions.count < 2 {
                    ContentUnavailableView("No conflicting versions", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Resolve conflict")
            .navigationDestination(for: UUID.self) { identifier in
                if let revision = review.versions.first(where: { $0.revisionId == identifier }) {
                    ItemDetailView(
                        revision: revision, conflicted: false, edit: {}, delete: {}, reviewingVersion: true
                    )
                    .navigationTitle("Review version")
                    .toolbar {
                        reviewControls
                        ToolbarItem(placement: .confirmationAction) {
                            Button(LocalizedStringKey(revision.deleted ? "Keep deleted" : "Use this version")) {
                                review.confirming = revision.revisionId
                            }
                            .accessibilityIdentifier("resolve-version")
                            .disabled(!review.canResolve)
                        }
                    }
                }
            }
            .toolbar {
                reviewControls
            }
        }
        .confirmationDialog("Make this version current?", isPresented: Binding(
            get: { review.confirming != nil }, set: { if !$0 { review.confirming = nil } }
        ), titleVisibility: .visible) {
            if let revision = review.versions.first(where: { $0.revisionId == review.confirming }) {
                Button(
                    LocalizedStringKey(revision.deleted ? "Keep deleted" : "Use this version"),
                    role: revision.deleted ? .destructive : nil
                ) {
                    review.resolveVersion(revision.revisionId)
                }
                .accessibilityIdentifier("confirm-conflict-version")
            }
        } message: {
            Text("The entire selected version will be used. Other versions remain in revision history.")
        }
        .alert("Unable to resolve conflict", isPresented: Binding(
            get: { review.issue != nil }, set: { if !$0 { review.issue = nil } }
        )) {
            Button("OK") { review.issue = nil }
        } message: {
            Text(review.issue ?? "")
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 500)
        #endif
    }

    @ToolbarContentBuilder
    private var reviewControls: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        ToolbarItem {
            Button("Reload versions", systemImage: "arrow.clockwise") { review.reloadVersions() }
        }
    }
}
