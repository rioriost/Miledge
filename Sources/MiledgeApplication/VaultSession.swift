import Foundation
import MiledgeDomain
import Observation

public enum SessionState: Equatable, Sendable {
    case locked
    case unlocking
    case unlocked
}

public enum SessionError: Error, Equatable {
    case locked
    case interrupted
    case conflictRequiresMerge
    case staleRevision
    case missingRecord
    case changedStorageScope
    case invalidProfile
}

public enum RelatedItemResolution: Equatable, Sendable {
    case available(VaultRevision)
    case conflicted
    case unavailable

    public static func resolve(recordId: UUID, heads: [VaultRevision]) -> Self {
        let matches = heads.filter { $0.recordId == recordId }
        guard matches.count < 2 else { return .conflicted }
        guard let revision = matches.first, !revision.deleted else { return .unavailable }
        return .available(revision)
    }
}

public struct RevisionRestoreResult: Equatable, Sendable {
    public let addedRevisionIds: [UUID]
    public let existingRevisionCount: Int
    public let skippedRevisionCount: Int
}

public struct RevisionRestoreFailure: Error {
    public let result: RevisionRestoreResult
    public let failedRevisionId: UUID
    public let cause: any Error
}

public struct RestorationPreview: Equatable, Sendable {
    public let recordCount: Int
    public let revisionCount: Int
    public let existingRevisionCount: Int
    public let conflictingRecordCount: Int
}

@MainActor
@Observable
public final class VaultSession {
    public private(set) var state = SessionState.locked
    public private(set) var heads: [VaultRevision] = []
    public var accessGeneration: Int { generation }
    private var revisions: [VaultRevision] = []
    private var generation = 0
    private var cooperativeRestoreId: UUID?
    private let authenticate: @MainActor () async throws -> Void
    private let cancelAuthentication: @MainActor () -> Void
    private let load: @MainActor () throws -> [Data]
    private let append: @MainActor (Data, String, StorageScope) throws -> Void
    private let now: @MainActor () -> Date
    private let identifier: @MainActor () -> UUID

    public init(
        authenticate: @escaping @MainActor () async throws -> Void,
        cancelAuthentication: @escaping @MainActor () -> Void = {},
        load: @escaping @MainActor () throws -> [Data],
        append: @escaping @MainActor (Data, String, StorageScope) throws -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        identifier: @escaping @MainActor () -> UUID = UUID.init
    ) {
        self.authenticate = authenticate
        self.cancelAuthentication = cancelAuthentication
        self.load = load
        self.append = append
        self.now = now
        self.identifier = identifier
    }

    public func unlock() async throws {
        guard state == .locked else { throw SessionError.interrupted }
        let attempt = generation
        state = .unlocking
        var completed = false
        defer {
            if !completed, generation == attempt {
                lock()
            }
        }
        try await authenticate()
        try Task.checkCancellation()
        guard generation == attempt, state == .unlocking else {
            throw SessionError.interrupted
        }
        let loaded = try load().map(RevisionCodec.decode)
        let loadedHeads = try RevisionGraph.heads(in: loaded)
        revisions = loaded
        heads = loadedHeads
        state = .unlocked
        completed = true
    }

    public func lock() {
        generation += 1
        cooperativeRestoreId = nil
        state = .locked
        cancelAuthentication()
        revisions.removeAll()
        heads.removeAll()
    }

    public func visibleItems(query: String = "", favoritesOnly: Bool = false) -> [VaultRevision] {
        guard state == .unlocked else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return heads.filter { head in
            let related = heads.filter { $0.recordId == head.recordId }
            guard !head.deleted || related.count > 1 else { return false }
            guard !favoritesOnly || head.favorite else { return false }
            return query.isEmpty
                || head.title.localizedCaseInsensitiveContains(query)
                || head.templateId.localizedCaseInsensitiveContains(query)
                || head.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            if $0.title == $1.title {
                return $0.revisionId.uuidString < $1.revisionId.uuidString
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func hasConflict(_ revision: VaultRevision) -> Bool {
        heads.filter { $0.recordId == revision.recordId }.count > 1
    }

    public func newDraft(template: ItemTemplate, affiliateProfileId: String? = nil) throws -> VaultRevision {
        guard state == .unlocked else { throw SessionError.locked }
        var sections = template.sections
        if let affiliateProfileId {
            guard template.id == "affiliate-account",
                  let profile = TemplateCatalog.affiliateProfile(id: affiliateProfileId) else {
                throw SessionError.invalidProfile
            }
            sections = profile.sections + [
                VaultSection(id: "profile", fields: [
                    VaultField(id: "profileId", kind: "string", value: .string(profile.id), concealed: false),
                    VaultField(id: "profileVersion", kind: "string", value: .string(String(profile.version)), concealed: false)
                ])
            ]
            if !sections.contains(where: { $0.id == "notes" }) {
                sections.append(VaultSection(id: "notes", fields: [
                    VaultField(id: "notes", kind: "multiline", value: .string(""), concealed: true, label: "Notes")
                ]))
            }
        }
        return VaultRevision(
            recordId: identifier(),
            revisionId: identifier(),
            templateId: template.id,
            templateVersion: template.version,
            storageScope: .deviceLocal,
            title: "",
            createdAt: now(),
            modifiedAt: now(),
            sections: sections
        )
    }

    public func editDraft(_ revision: VaultRevision) throws -> VaultRevision {
        guard state == .unlocked else { throw SessionError.locked }
        guard heads.contains(where: { $0.revisionId == revision.revisionId }) else {
            throw SessionError.missingRecord
        }
        guard !hasConflict(revision) else { throw SessionError.conflictRequiresMerge }
        try VaultPolicy.validateForWrite(revision)
        var draft = revision
        draft.revisionId = identifier()
        draft.parentRevisionIds = [revision.revisionId]
        draft.modifiedAt = now()
        return draft
    }

    public func save(_ draft: VaultRevision) throws {
        guard state == .unlocked else { throw SessionError.locked }
        try VaultPolicy.validateForWrite(draft)
        let current = heads.filter { $0.recordId == draft.recordId }
        if current.count > 1 { throw SessionError.conflictRequiresMerge }
        guard Set(draft.parentRevisionIds) == Set(current.map(\.revisionId)) else {
            throw SessionError.staleRevision
        }
        if let previous = current.first, previous.storageScope != draft.storageScope {
            throw SessionError.changedStorageScope
        }
        try persist(draft, revisions: revisions)
    }

    public func refresh() throws {
        guard state == .unlocked else { throw SessionError.locked }
        let snapshot = try readSnapshot()
        revisions = snapshot.revisions
        heads = snapshot.heads
    }

    public func revisionsForBackup() throws -> [VaultRevision] {
        guard state == .unlocked else { throw SessionError.locked }
        return try readSnapshot().revisions
    }

    public func previewRestoration(_ incoming: [VaultRevision]) throws -> RestorationPreview {
        let prepared = try prepareRestore(incoming, skippingRecords: [])
        let combinedHeads = try RevisionGraph.heads(in: prepared.current + incoming)
        let records = Set(incoming.map(\.recordId))
        let grouped = Dictionary(grouping: combinedHeads, by: \.recordId)
        return RestorationPreview(
            recordCount: records.count, revisionCount: incoming.count,
            existingRevisionCount: prepared.existingCount,
            conflictingRecordCount: records.filter { (grouped[$0]?.count ?? 0) > 1 }.count
        )
    }

    public func restoreRevisions(
        _ incoming: [VaultRevision], skippingRecords: Set<UUID> = []
    ) throws -> RevisionRestoreResult {
        let prepared = try prepareRestore(incoming, skippingRecords: skippingRecords)
        var current = prepared.current
        var added: [UUID] = []
        for (revision, data) in prepared.pending {
            do {
                try Task.checkCancellation()
                guard state == .unlocked else { throw SessionError.locked }
                let next = current + [revision]
                let nextHeads = try RevisionGraph.heads(in: next)
                try append(
                    data, "\(revision.recordId.uuidString)/\(revision.revisionId.uuidString)", revision.storageScope
                )
                added.append(revision.revisionId)
                guard state == .unlocked else { throw SessionError.interrupted }
                current = next
                revisions = next
                heads = nextHeads
            } catch {
                throw RevisionRestoreFailure(
                    result: RevisionRestoreResult(
                        addedRevisionIds: added, existingRevisionCount: prepared.existingCount,
                        skippedRevisionCount: prepared.skippedCount
                    ), failedRevisionId: revision.revisionId, cause: error
                )
            }
        }
        revisions = current
        heads = try RevisionGraph.heads(in: current)
        return RevisionRestoreResult(
            addedRevisionIds: added, existingRevisionCount: prepared.existingCount,
            skippedRevisionCount: prepared.skippedCount
        )
    }

    public func restoreRevisionsCooperatively(
        _ incoming: [VaultRevision], skippingRecords: Set<UUID> = []
    ) async throws -> RevisionRestoreResult {
        let operation = try prepareCooperativeRestore(incoming, skippingRecords: skippingRecords)
        defer { finishCooperativeRestore(operation) }
        return try await restoreRevisionsCooperatively(operation, cooperate: { await Task.yield() })
    }

    internal struct RevisionRestorePlan {
        let current: [VaultRevision]
        let incoming: [VaultRevision]
        let pending: [(VaultRevision, Data)]
        let existingCount: Int
        let skippedCount: Int
    }

    internal struct CooperativeRestoreOperation {
        let id: UUID
        let generation: Int
        let plan: RevisionRestorePlan
    }

    internal func prepareCooperativeRestore(
        _ incoming: [VaultRevision], skippingRecords: Set<UUID>
    ) throws -> CooperativeRestoreOperation {
        try Task.checkCancellation()
        guard cooperativeRestoreId == nil else { throw SessionError.interrupted }
        let attempt = generation
        let plan = try prepareRestore(incoming, skippingRecords: skippingRecords)
        guard generation == attempt, state == .unlocked else { throw SessionError.interrupted }
        let operation = CooperativeRestoreOperation(id: UUID(), generation: attempt, plan: plan)
        cooperativeRestoreId = operation.id
        return operation
    }

    internal func finishCooperativeRestore(_ operation: CooperativeRestoreOperation) {
        if cooperativeRestoreId == operation.id { cooperativeRestoreId = nil }
    }

    internal func checkCooperativeRestore(_ operation: CooperativeRestoreOperation) throws {
        try Task.checkCancellation()
        guard generation == operation.generation, cooperativeRestoreId == operation.id,
              state == .unlocked else { throw SessionError.interrupted }
    }

    internal func cooperativeRestoreSnapshot(
        _ operation: CooperativeRestoreOperation,
        validating: @MainActor ([VaultRevision]) throws -> Void = { _ in }
    ) throws -> (revisions: [VaultRevision], heads: [VaultRevision]) {
        try checkCooperativeRestore(operation)
        let latest = try readSnapshot()
        try checkCooperativeRestore(operation)
        let snapshot = try snapshot(of: operation.plan.current + latest.revisions + revisions)
        let combined = snapshot.revisions + operation.plan.incoming
        _ = try RevisionGraph.heads(in: combined)
        try validating(combined)
        return snapshot
    }

    internal func restoreRevisionsCooperatively(
        _ operation: CooperativeRestoreOperation,
        cooperate: @MainActor () async -> Void,
        validating: @MainActor ([VaultRevision]) throws -> Void = { _ in }
    ) async throws -> RevisionRestoreResult {
        let plan = operation.plan
        var added: [UUID] = []
        var existingCount = plan.existingCount
        for (revision, data) in plan.pending {
            do {
                await cooperate()
                let latest = try cooperativeRestoreSnapshot(operation, validating: validating)
                if latest.revisions.contains(where: { $0.revisionId == revision.revisionId }) {
                    existingCount += 1
                    revisions = latest.revisions
                    heads = latest.heads
                    continue
                }
                let next = try snapshot(of: latest.revisions + [revision])
                try append(
                    data, "\(revision.recordId.uuidString)/\(revision.revisionId.uuidString)", revision.storageScope
                )
                added.append(revision.revisionId)
                try checkCooperativeRestore(operation)
                // Storage callbacks can also save or refresh; never publish an older snapshot over them.
                let published = try snapshot(of: next.revisions + revisions)
                _ = try RevisionGraph.heads(in: published.revisions + plan.incoming)
                try validating(published.revisions + plan.incoming)
                revisions = published.revisions
                heads = published.heads
            } catch {
                throw RevisionRestoreFailure(
                    result: RevisionRestoreResult(
                        addedRevisionIds: added, existingRevisionCount: existingCount,
                        skippedRevisionCount: plan.skippedCount
                    ), failedRevisionId: revision.revisionId, cause: error
                )
            }
        }
        if plan.pending.isEmpty {
            let latest = try cooperativeRestoreSnapshot(operation, validating: validating)
            revisions = latest.revisions
            heads = latest.heads
        }
        return RevisionRestoreResult(
            addedRevisionIds: added, existingRevisionCount: existingCount, skippedRevisionCount: plan.skippedCount
        )
    }

    private func prepareRestore(
        _ incoming: [VaultRevision], skippingRecords: Set<UUID>
    ) throws -> RevisionRestorePlan {
        guard state == .unlocked else { throw SessionError.locked }
        for revision in incoming { try VaultPolicy.validateForRestore(revision) }
        let snapshot = try readSnapshot()
        _ = try RevisionGraph.heads(in: snapshot.revisions + incoming)
        guard skippingRecords.isSubset(of: Set(incoming.map(\.recordId))) else {
            throw SessionError.missingRecord
        }
        var seen = Set<UUID>()
        let unique = incoming.filter { seen.insert($0.revisionId).inserted }
        let skipped = unique.filter { skippingRecords.contains($0.recordId) }
        let selected = unique.filter { !skippingRecords.contains($0.recordId) }
        let existing = Set(snapshot.revisions.map(\.revisionId))
        let missing = selected.filter { !existing.contains($0.revisionId) }
        let byId = Dictionary(uniqueKeysWithValues: missing.map { ($0.revisionId, $0) })
        var waiting: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for revision in missing {
            let absentParents = revision.parentRevisionIds.filter { !existing.contains($0) }
            waiting[revision.revisionId] = absentParents.count
            for parent in absentParents { children[parent, default: []].append(revision.revisionId) }
        }
        var ready = missing.filter { waiting[$0.revisionId] == 0 }.map(\.revisionId)
            .sorted { $0.uuidString < $1.uuidString }
        var ordered: [(VaultRevision, Data)] = []
        var position = 0
        while position < ready.count {
            let id = ready[position]
            position += 1
            guard let revision = byId[id] else { throw SessionError.missingRecord }
            ordered.append((revision, try RevisionCodec.encode(revision)))
            for child in (children[id] ?? []).sorted(by: { $0.uuidString < $1.uuidString }) {
                waiting[child, default: 0] -= 1
                if waiting[child] == 0 { ready.append(child) }
            }
        }
        guard ordered.count == missing.count else { throw SessionError.missingRecord }
        return RevisionRestorePlan(
            current: snapshot.revisions, incoming: incoming, pending: ordered,
            existingCount: selected.count - missing.count, skippedCount: skipped.count
        )
    }

    public func resolveConflict(
        recordId: UUID, keeping revisionId: UUID, expectedHeads: Set<UUID>
    ) throws -> VaultRevision {
        guard state == .unlocked else { throw SessionError.locked }
        let snapshot = try readSnapshot()
        let current = snapshot.heads.filter { $0.recordId == recordId }
        guard current.count > 1, Set(current.map(\.revisionId)) == expectedHeads else {
            throw SessionError.staleRevision
        }
        guard var resolved = current.first(where: { $0.revisionId == revisionId }) else {
            throw SessionError.missingRecord
        }
        guard current.allSatisfy({ $0.storageScope == resolved.storageScope }) else {
            throw SessionError.changedStorageScope
        }
        for version in current { try VaultPolicy.validateForWrite(version) }
        resolved.revisionId = identifier()
        resolved.parentRevisionIds = current.map(\.revisionId).sorted { $0.uuidString < $1.uuidString }
        resolved.modifiedAt = now()
        try VaultPolicy.validateForWrite(resolved)
        try persist(resolved, revisions: snapshot.revisions)
        return resolved
    }

    private func readSnapshot() throws -> (revisions: [VaultRevision], heads: [VaultRevision]) {
        let combined = revisions + (try load().map(RevisionCodec.decode))
        return try snapshot(of: combined)
    }

    private func snapshot(of combined: [VaultRevision]) throws -> (revisions: [VaultRevision], heads: [VaultRevision]) {
        let currentHeads = try RevisionGraph.heads(in: combined)
        var seen = Set<UUID>()
        return (combined.filter { seen.insert($0.revisionId).inserted }, currentHeads)
    }

    private func persist(_ draft: VaultRevision, revisions: [VaultRevision]) throws {
        let next = revisions + [draft]
        let nextHeads = try RevisionGraph.heads(in: next)
        let data = try RevisionCodec.encode(draft)
        try append(data, "\(draft.recordId.uuidString)/\(draft.revisionId.uuidString)", draft.storageScope)
        self.revisions = next
        heads = nextHeads
    }

    public func delete(_ revision: VaultRevision) throws {
        var tombstone = try editDraft(revision)
        tombstone.deleted = true
        try save(tombstone)
    }
}
